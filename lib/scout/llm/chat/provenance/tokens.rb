# Extracted from the existing provenance token-accounting implementation.
module Chat
  # ------------------------------------------------------------------
  # Provenance-aware token accounting
  # ------------------------------------------------------------------

  # Canonical-evidence rule for grouped token events, applied in this order:
  #
  #   1. prefer :chat_meta evidence over :agent_meta evidence (a saved child
  #      log chat is the richer, primary representation of the same request);
  #   2. within the same origin, the first evidence in discovery order
  #      (provenance_chat_files order, then message index, then receipt
  #      index).
  #
  # Event tokens always come from the canonical evidence only.  Duplicate
  # evidence records are retained (never summed), so a total can always be
  # explained from the evidence list.

  # One event Hash per deduplicated direct inference event reachable from
  # `root`.  A `job=` projection meta is never a token event, and only
  # evidence carrying at least one TOKEN_KEYS field becomes an event.
  #
  # Warning routing: when the caller supplies a `warnings` Array, two kinds of
  # problems are reported into it instead of raising:
  #   * traversal-stage agent_meta problems (malformed receipts and unresolved
  #     job references) arrive as the agent_meta_error_reference Hash plus
  #     `message:`; the traversal keeps going so one bad receipt never hides
  #     the rest of the provenance;
  #   * identity_conflict records (see below).
  # Unrelated traversal errors keep strict semantics: they raise, both with and
  # without a warnings Array.  Without the Array, agent_meta problems raise
  # exactly like Chat.traverse_provenance strict mode.
  #
  # Identity conflicts never raise here; pass `strict: true` to make them
  # raise instead of being reported (see below).
  #
  # Event shape:
  #
  #   {
  #     inference_id: <String or nil>,
  #     identity: <the Array used for grouping, e.g. [:inference_id, "w1"]>,
  #     deduplication: :inference_id | :provider_response_id |
  #                    :legacy_lineage | :receipt_unresolved,
  #     meta: <canonical parsed meta>,
  #     tokens: {pt:, ct:, tt:, cct:, cwt:, rt:} (symbols, zero-filled,
  #             canonical evidence only),
  #     evidence: [
  #       {origin: :chat_meta, source:, meta_address:, meta:, call_id: nil,
  #        tool_name: nil},
  #       {origin: :agent_meta, source:, evidence_address:, output_address:,
  #        agent_meta_index:, call_id:, tool_name:, meta:}
  #     ],
  #     conflict: true|false,
  #     incomplete_evidence: true|false
  #   }
  #
  # `evidence` holds EVERY persisted location of the event (the same
  # inference copied into several saved chats/logs appears once per chat plus
  # once per receipt).  Only the canonical evidence supplies `meta` and
  # `tokens`.
  #
  # Identity (grouping) rules, in priority order:
  #
  #   * meta[:inference_id]                    -> [:inference_id, id]
  #   * meta[:provider_response_id] otherwise  -> [:provider_response_id, id]
  #   * chat-side legacy (neither)             -> [:lineage, lineage_id], the
  #     existing global lineage dedup of Chat.trace_chat_sources is preserved
  #   * receipt-side legacy (neither)          -> [:receipt, evidence_address];
  #     there is no exact rule, so a receipt legacy meta is never merged with
  #     anything (documented possible overcount for legacy data)
  #
  # Identity conflicts: when evidence sharing an identity disagree on any
  # TOKEN_KEYS value (compared as integers, missing counts as 0) or on
  # provider_response_id (two DIFFERENT non-empty values), the event keeps
  # every evidence record, counts only the canonical one, sets conflict: true,
  # and - when a warnings Array was supplied - appends one Hash per conflicting
  # event:
  #
  #   {reason: :identity_conflict, inference_id:, identity:,
  #    fields: <Array of disputed field symbols>,
  #    values: <Hash field => the raw meta values in evidence order>,
  #    evidence: <the event evidence records>}
  #
  # A missing provider_response_id in one record and a present one in another
  # is INCOMPLETE EVIDENCE, not a conflict: one copy simply carries richer
  # metadata (e.g. across a metadata-format migration). Such events set
  # incomplete_evidence: true, are counted normally, and are never warned about
  # as conflicts.  The same leniency applies to optional detailed usage fields
  # (cct/cwt/rt): only the immutable core (inference identity, pt/ct/tt,
  # non-empty provider_response_id) can conflict.
  #
  # A conflicting event is counted once from its canonical evidence, but that
  # number is NOT authoritative: reports must label any total containing
  # conflicts as unresolved (see Chat.provenance_token_totals `conflicts:`).
  # Pass `strict: true` to raise ScoutException on the first conflict instead.
  #
  # Checkpoint fields (*_c, *_s) are never read or summed here.
  def self.provenance_token_events(root, warnings: nil, strict: false, chats: nil, **traversal_options)
    unless Thread.current[:scout_ai_provenance_run_cache]
      return with_provenance_run_cache do
        provenance_token_events(root, warnings: warnings, strict: strict, chats: chats, **traversal_options)
      end
    end
    # Route traversal-stage agent_meta problems into the caller's warnings
    # Array instead of letting them raise.  Other traversal errors stay strict
    # (raise), and an explicitly supplied on_error keeps being called.
    if Array === warnings
      caller_on_error = traversal_options[:on_error]
      traversal_options = traversal_options.merge(
        on_error: lambda do |error, kind, object, relation, reference|
          if relation == :agent_job && reference.is_a?(Hash) && reference[:reason] &&
             error.message.to_s.include?('agent_meta receipt')
            warnings << reference.merge(message: error.message)
            caller_on_error.call(error, kind, object, relation, reference) if caller_on_error
          elsif caller_on_error
            caller_on_error.call(error, kind, object, relation, reference)
          else
            raise error
          end
        end
      )
    end

    sources = chats || provenance_chat_files(root, **traversal_options).to_h do |file|
      [file.to_s, provenance_chat_load(file)]
    end

    evidences = []

    # Chat-side direct events.  `deduplicate: false` keeps one entry per
    # persisted location: an inference copied into several saved chats/logs
    # (or projected into several places) yields several evidence records, one
    # per address.  Grouping by identity happens exactly once, below, so the
    # resulting event can list every location.
    trace_chat_sources(sources, false).each do |entry|
      meta = entry[:meta]
      next if meta[:job]
      next unless TOKEN_KEYS.any? { |key| meta.include?(key) }
      address = entry[:meta_address]
      evidences << {
        origin: :chat_meta,
        discovery: evidences.length,
        source: address ? address[0] : nil,
        meta_address: address,
        meta: meta,
        call_id: nil,
        tool_name: nil,
        inference_id: entry[:inference_id],
        lineage_id: entry[:lineage_id]
      }
    end

    # Receipt-side direct events.  Malformed receipts are reported through a
    # private buffer and merged into the caller's warnings Array only when the
    # traversal stage has not already reported the same problem (it reports
    # with the richer reference + message shape whenever :agent_job is
    # followed); without an Array, agent_meta_evidence skips them silently.
    receipt_problems = Array === warnings ? [] : nil
    sources.each do |path, chat|
      agent_meta_evidence(chat, source: path, warnings: receipt_problems).each do |record|
        meta = record[:meta]
        next if meta[:job]
        next unless TOKEN_KEYS.any? { |key| meta.include?(key) }
        evidences << {
          origin: :agent_meta,
          discovery: evidences.length,
          source: path,
          evidence_address: record[:evidence_address],
          output_address: record[:output_address],
          agent_meta_index: record[:agent_meta_index],
          meta: meta,
          call_id: record[:call_id],
          tool_name: record[:tool_name],
          inference_id: meta[:inference_id],
          lineage_id: nil
        }
      end
    end

    if receipt_problems && !receipt_problems.empty?
      reported = Set.new(warnings.collect do |warning|
        next if warning[:reason] == :identity_conflict
        [warning[:reason], warning[:output_address], warning[:agent_meta_index]]
      end)
      receipt_problems.each do |problem|
        key = [problem[:reason], problem[:output_address], problem[:agent_meta_index]]
        warnings << problem unless reported.include?(key)
      end
    end

    origin_rank = { chat_meta: 0, agent_meta: 1 }
    events = []
    by_identity = {}

    evidences.each do |evidence|
      meta = evidence[:meta]
      # Blank identifiers are not identity evidence: a truthy-but-empty
      # inference_id / provider_response_id ("") must fall through to the
      # lineage / receipt rules instead of keying DISTINCT inferences onto
      # one shared blank identity.  Same blank normalization the conflict
      # detection below applies to provider_response_id.
      inference_id = evidence[:inference_id]
      inference_id = nil if inference_id.to_s.strip.empty?
      provider_response_id = meta[:provider_response_id]
      provider_response_id = nil if provider_response_id.to_s.strip.empty?

      if inference_id
        identity = [:inference_id, inference_id]
        deduplication = :inference_id
      elsif provider_response_id
        identity = [:provider_response_id, provider_response_id]
        deduplication = :provider_response_id
      elsif evidence[:origin] == :chat_meta
        identity = [:lineage, evidence[:lineage_id]]
        deduplication = :legacy_lineage
      else
        identity = [:receipt, evidence[:evidence_address]]
        deduplication = :receipt_unresolved
      end

      event = by_identity[identity]
      unless event
        event = { identity: identity, deduplication: deduplication, _evidence: [] }
        by_identity[identity] = event
        events << event
      end
      event[:_evidence] << evidence
    end

    events.each do |event|
      ordered = event.delete(:_evidence).sort_by do |evidence|
        [origin_rank[evidence[:origin]], evidence[:discovery]]
      end
      canonical = ordered.first

      event[:evidence] = ordered.collect do |evidence|
        record = {
          origin: evidence[:origin],
          source: evidence[:source],
          meta: evidence[:meta],
          call_id: evidence[:call_id],
          tool_name: evidence[:tool_name]
        }
        if evidence[:origin] == :chat_meta
          record[:meta_address] = evidence[:meta_address]
        else
          record[:evidence_address] = evidence[:evidence_address]
          record[:output_address] = evidence[:output_address]
          record[:agent_meta_index] = evidence[:agent_meta_index]
        end
        record
      end

      event[:inference_id] = canonical[:inference_id]
      event[:meta] = canonical[:meta]
      event[:tokens] = TOKEN_KEYS.each_with_object({}) do |key, hash|
        hash[key.to_sym] = canonical[:meta][key].to_i
      end

      # Immutable core only: pt/ct/tt and a genuinely different non-empty
      # provider_response_id.  Optional detail fields (cct, cwt, rt) and a
      # missing-vs-present provider_response_id are incomplete evidence, not
      # conflicts.
      core_fields = %i[pt ct tt]
      fields = []
      values = {}
      core_fields.each do |key|
        next unless ordered.collect { |evidence| evidence[:meta][key].to_i }.uniq.length > 1
        fields << key
        values[key] = ordered.collect { |evidence| evidence[:meta][key] }
      end
      provider_ids = ordered.collect { |evidence| evidence[:meta][:provider_response_id].to_s }
                                 .reject { |value| value.strip.empty? }.uniq
      if provider_ids.length > 1
        fields << :provider_response_id
        values[:provider_response_id] = ordered.collect { |evidence| evidence[:meta][:provider_response_id] }
      end

      # Incomplete evidence: exactly one non-empty provider_response_id value
      # while at least one copy lacks it (metadata-format migration), so there
      # is nothing to disagree about.
      present_ids = ordered.collect { |evidence| evidence[:meta][:provider_response_id].to_s }
                            .reject { |value| value.strip.empty? }
      if present_ids.uniq.length <= 1 &&
         present_ids.length != ordered.length && !present_ids.empty?
        event[:incomplete_evidence] = true
      end

      next unless fields.any?
      event[:conflict] = true
      if strict
        raise ScoutException, "agent_meta identity conflict on #{event[:identity] * '='}: disputed #{fields * ','}"
      end
      next unless Array === warnings
      warnings << {
        reason: :identity_conflict,
        inference_id: event[:inference_id],
        identity: event[:identity],
        fields: fields,
        values: values,
        evidence: event[:evidence]
      }
    end

    # Reorder keys readably; conflict defaults to false.
    events.collect do |event|
      {
        inference_id: event[:inference_id],
        identity: event[:identity],
        deduplication: event[:deduplication],
        meta: event[:meta],
        tokens: event[:tokens],
        evidence: event[:evidence],
        conflict: event[:conflict] || false,
        incomplete_evidence: event[:incomplete_evidence] || false
      }
    end
  end

  # Aggregate token totals over deduplicated provenance events.  The result is
  # symbol keyed and zero initialized exactly like Chat.token_totals:
  # {pt:, ct:, tt:, cct:, cwt:, rt:}.
  #
  # Scopes.  These are EVIDENCE COVERAGE descriptions, not a partition of cost:
  # an event represented both in a saved child log and in a receipt belongs to
  # :chat_evidence AND to :receipt_evidence, so the two are not additive and
  # must never be summed together.  Only :deduplicated_total and :receipt_only
  # are safe to compare additively.
  #
  #   * :deduplicated_total - every event counted once (default);
  #   * :chat_evidence      - events with at least one :chat_meta evidence
  #                           (physically stored in a chat/log file);
  #   * :receipt_evidence   - events with at least one :agent_meta evidence
  #                           (embedded in a function_call_output receipt);
  #   * :receipt_only       - events with receipt evidence and NO saved-chat
  #                           evidence (the disjoint delegated contribution).
  #
  # Conflict handling: a conflicting event still contributes its canonical
  # tokens, so a total containing conflicts is a best-effort view, not an
  # authoritative cost.  The `conflicts:` keyword makes that explicit in
  # machine readable form; with `strict: true` conflicts raise instead (the
  # keyword is forwarded to provenance_token_events).
  def self.provenance_token_totals(root, scope: :deduplicated_total, warnings: nil,
                                   conflicts: nil, **traversal_options)
    events = provenance_token_events(root, warnings: warnings, **traversal_options)

    selected = case scope.to_sym
               when :deduplicated_total
                 events
               when :chat_evidence
                 events.select { |event| event[:evidence].any? { |e| e[:origin] == :chat_meta } }
               when :receipt_evidence
                 events.select { |event| event[:evidence].any? { |e| e[:origin] == :agent_meta } }
               when :receipt_only
                 events.select do |event|
                   event[:evidence].any? { |e| e[:origin] == :agent_meta } &&
                     event[:evidence].none? { |e| e[:origin] == :chat_meta }
                 end
               else
                 raise ParameterException, "Unknown token scope: #{scope}"
               end

    totals = TOKEN_KEYS.each_with_object({}) { |key, hash| hash[key.to_sym] = 0 }
    selected.each do |event|
      TOKEN_KEYS.each { |key| totals[key.to_sym] += event[:tokens][key.to_sym] }
    end

    if conflicts.is_a?(Hash)
      conflicting = events.select { |event| event[:conflict] }
      incomplete = events.select { |event| event[:incomplete_evidence] }
      conflicts[:events] = conflicting.length
      conflicts[:incomplete_evidence_events] = incomplete.length
      conflicts[:authoritative] = conflicting.empty?
    end

    totals
  end

  # Provenance token aggregate.  Receipt (agent_meta) child usage is now
  # included through the event collector, so child inference paid inside a
  # parent tool call is no longer invisible when the child chat was not saved.
  def self.tokens(root, **options)
    provenance_token_totals(root, **options)
  end

end
