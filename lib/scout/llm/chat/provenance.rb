require 'set'
require 'time'

module Chat
  PROVENANCE_RELATIONS = %i[job dependency log result agent_job].freeze

  # Return only chat logs owned by this job. This method is deliberately not
  # recursive; recursion belongs to traverse_provenance.
  def self.direct_job_chat_files(job)
    job = Step.load(job) unless Step === job
    log = job.file('log')
    return [] unless log.directory?
    log.glob('**/*.chat').sort.collect { |file| Path.setup(File.expand_path(file.to_s)) }
  end

  # Return the persisted result as a chat file when the Step result type is
  # chat. A job and its result chat may have the same path; traversal identities
  # therefore always include the node kind.
  def self.job_result_chat_file(job)
    job = Step.load(job) unless Step === job
    return nil unless job.type.to_s == 'chat' && File.file?(job.path.to_s)
    Path.setup(File.expand_path(job.path.to_s))
  end

  def self.provenance_path(kind, object)
    path = File.expand_path(kind.to_sym == :job ? object.path.to_s : object.to_s)
    File.realpath(path)
  rescue SystemCallError
    path
  end

  def self.provenance_key(kind, object)
    [kind.to_sym, provenance_path(kind, object)]
  end

  def self.provenance_error(on_error, error, kind, object, relation, reference)
    raise error unless on_error
    on_error.call(error, kind, object, relation, reference)
  end

  # Resolve a job reference from a chat meta message into a Step. References
  # like "Planned/ask/Default_abc.chat" are relative workflow paths. Step.load
  # may resolve them to a Scout-specific directory that does not contain the
  # actual job data, so we fall back to checking Rbbt.var.jobs and Scout.var.jobs.
  def self.load_job_reference(reference)
    return reference if Step === reference
    ref_str = reference.to_s

    step = Step.load(ref_str)
    return step if File.exist?(step.path.to_s) || File.exist?(step.path.to_s + '.info')

    # Step.load resolves relative workflow paths (e.g. Planned/ask/Default_xyz.chat)
    # via Path.find, which may point to a directory that does not contain the
    # actual job data (e.g. ~/.scout/ instead of ~/.rbbt/var/jobs/). Try the
    # standard Rbbt workflow storage location as a fallback.
    rbbt_candidate = File.expand_path(File.join('~/.rbbt/var/jobs', ref_str))
    return Step.load(rbbt_candidate) if File.exist?(rbbt_candidate) || File.exist?(rbbt_candidate + '.info')

    step
  end

  # Resolve one job reference into a usable Step.  Returns [step, nil] when the
  # job data is loadable (path or .info sidecar exists) and [nil, step] when the
  # reference resolves to a directory without job data, keeping the would-be
  # step for diagnostics.  Used by the :agent_job relation so unresolved
  # receipt references are reported instead of enqueued.
  def self.resolve_job_reference(reference)
    step = load_job_reference(reference)
    path = step.path.to_s
    if File.exist?(path) || File.exist?(path + '.info')
      [step, nil]
    else
      [nil, step]
    end
  end

  # Diagnostics for agent_meta receipt problems found while expanding one chat
  # node: malformed receipts collected by Chat.agent_meta_job_references plus
  # outputs whose raw text mentions agent_meta but that Chat.tool_calls cannot
  # even parse (Chat.agent_meta_unparseable_outputs).  Each record becomes one
  # Chat.provenance_error call with relation :agent_job and kind/object
  # :chat + the chat path, so strict mode (no on_error) raises
  # Chat::AgentMetaError while warning mode keeps going.  Returns the valid job
  # references so the caller can enqueue them afterwards.
  def self.report_agent_meta_problems(chat, object, on_error = nil)
    warnings = []
    references = agent_meta_job_references(chat, source: object, warnings: warnings)
    warnings.concat(agent_meta_unparseable_outputs(chat, source: object))

    warnings.each do |warning|
      error = AgentMetaError.build(warning[:reason],
                                   chat_path: object.to_s,
                                   output_address: warning[:output_address],
                                   call_id: warning[:call_id],
                                   tool_name: warning[:tool_name],
                                   reference: warning[:reference] || warning[:raw_entry])
      reference = agent_meta_error_reference(reason: warning[:reason],
                                             source: warning[:source] || object.to_s,
                                             output_address: warning[:output_address],
                                             evidence_address: warning[:evidence_address],
                                             call_id: warning[:call_id],
                                             tool_name: warning[:tool_name],
                                             agent_meta_index: warning[:agent_meta_index],
                                             raw_entry: warning[:raw_entry],
                                             reference: warning[:reference])
      provenance_error(on_error, error, :chat, object, :agent_job, reference)
    end

    references
  end

  # Traverse the heterogeneous provenance graph using native Path and Step
  # values. The block receives:
  #
  #   kind, object, parent_kind, parent, relation, first_visit
  #
  # `kind` is :chat or :job. Chat objects are persisted file Paths; jobs are
  # Steps. The root has nil parent/relation. Every structural edge is yielded,
  # including an edge to a node visited through another branch; first_visit is
  # false in that case and the node is not expanded again.
  #
  # Relations describe root-outward discovery, not diagram arrow direction:
  # chat -> producer job (:job), chat -> delegated-agent producer job
  # (:agent_job, from agent_meta receipts), job -> dependency (:dependency),
  # job -> log chat (:log), and job -> result chat (:result).
  #
  # Imported and continued chats are a chat-compilation concern, not a
  # provenance concern. They are resolved during Chat.parse and their content
  # is already inlined in the persisted chat file. Provenance traversal
  # therefore never follows import, continue, or last references.
  def self.traverse_provenance(root, root_type: nil, follow: :all, on_error: nil, &block)
    return enum_for(__method__, root, root_type: root_type, follow: follow, on_error: on_error) unless block

    relations = follow == :all ? PROVENANCE_RELATIONS : Array(follow).collect(&:to_sym)
    unknown = relations - PROVENANCE_RELATIONS
    raise ParameterException, "Unknown provenance relations: #{unknown * ', '}" if unknown.any?

    root_kind = root_type && root_type.to_sym
    root_kind ||= Step === root ? :job : :chat
    root_object = if root_kind == :job
                    Step === root ? root : Step.load(root)
                  else
                    path = File.expand_path(root.to_s)
                    raise ParameterException, "Chat not found: #{root}" unless File.file?(path)
                    Path.setup(path)
                  end

    queue = [[root_kind, root_object, nil, nil, nil]]
    seen = Set.new

    until queue.empty?
      kind, object, parent_kind, parent, relation = queue.shift
      key = provenance_key(kind, object)
      first_visit = !seen.include?(key)
      block.call(kind, object, parent_kind, parent, relation, first_visit)
      next unless first_visit
      seen << key

      begin
        if kind == :chat
          chat = Chat.load(object)

          if relations.include?(:job)
            chat.jobs.each do |reference|
              begin
                job = load_job_reference(reference)
                queue << [:job, job, :chat, object, :job]
              rescue StandardError => error
                provenance_error(on_error, error, :chat, object, :job, reference)
              end
            end
          end

          if relations.include?(:agent_job)
            # Malformed receipts and unparsable outputs are diagnostics, never
            # provenance; they are reported through provenance_error and skipped.
            references = begin
                           report_agent_meta_problems(chat, object, on_error)
                         rescue AgentMetaError
                           raise
                         rescue StandardError => error
                           provenance_error(on_error, error, :chat, object, :agent_job, object)
                           []
                         end

            references.each do |record|
              reference = record[:job]
              begin
                job, _unresolved = resolve_job_reference(reference)
                if job
                  queue << [:job, job, :chat, object, :agent_job]
                else
                  error = AgentMetaError.build(:unresolved_job_reference,
                                               chat_path: object.to_s,
                                               output_address: record[:output_address],
                                               call_id: record[:call_id],
                                               tool_name: record[:tool_name],
                                               reference: reference)
                  provenance_error(on_error, error, :chat, object, :agent_job,
                                   agent_meta_error_reference(reason: :unresolved_job_reference,
                                                              source: object.to_s,
                                                              output_address: record[:output_address],
                                                              evidence_address: record[:evidence_address],
                                                              call_id: record[:call_id],
                                                              tool_name: record[:tool_name],
                                                              reference: reference))
                end
              rescue AgentMetaError
                raise
              rescue StandardError => error
                provenance_error(on_error, error, :chat, object, :agent_job,
                                 agent_meta_error_reference(reason: :unresolved_job_reference,
                                                            source: object.to_s,
                                                            reference: reference,
                                                            call_id: record[:call_id],
                                                            tool_name: record[:tool_name]))
              end
            end
          end
        else
          if relations.include?(:dependency)
            object.dependencies.each do |dependency|
              queue << [:job, dependency, :job, object, :dependency]
            end
          end

          if relations.include?(:log)
            direct_job_chat_files(object).each do |file|
              queue << [:chat, file, :job, object, :log]
            end
          end

          if relations.include?(:result) && (file = job_result_chat_file(object))
            queue << [:chat, file, :job, object, :result]
          end
        end
      rescue StandardError => error
        provenance_error(on_error, error, kind, object, relation, object)
      end
    end

    nil
  end

  # Flat structural edges suitable for JSON reports and renderers. Objects are
  # intentionally retained as native values; presentation code can shorten or
  # serialize paths as needed.
  def self.provenance_edges(root, **options)
    edges = []
    traverse_provenance(root, **options) do |kind, object, parent_kind, parent, relation, _first|
      next unless parent
      edge = {
        from_kind: parent_kind,
        from: parent,
        relation: relation,
        to_kind: kind,
        to: object
      }
      edges << edge unless edges.any? do |other|
        other[:relation] == relation &&
          provenance_key(other[:from_kind], other[:from]) == provenance_key(parent_kind, parent) &&
          provenance_key(other[:to_kind], other[:to]) == provenance_key(kind, object)
      end
    end
    edges
  end

  def self.provenance_chat_files(root, **options)
    files = []
    traverse_provenance(root, **options) do |kind, object, _pk, _parent, _relation, first|
      files << provenance_path(kind, object) if first && kind == :chat
    end
    files
  end

  def self.provenance_jobs(root, **options)
    jobs = []
    traverse_provenance(root, **options) do |kind, object, _pk, _parent, _relation, first|
      jobs << object if first && kind == :job
    end
    jobs
  end

  # Compatibility collector for the former chat-to-chat provenance Hash. New
  # code should use traverse_provenance or provenance_edges, which retain job
  # nodes and relation types.
  def self.provenance(chat_file, prov = {})
    traverse_provenance(chat_file) do |kind, object, parent_kind, parent, _relation, _first|
      next unless parent && kind == :chat
      parent_path = provenance_path(parent_kind, parent)
      prov[parent_path] ||= []
      path = provenance_path(kind, object)
      prov[parent_path] << path unless prov[parent_path].include?(path)
    end
    prov
  end

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
  #   * traversal-stage agent_meta problems (Chat::AgentMetaError, i.e.
  #     malformed receipts and unresolved job references) arrive as the
  #     agent_meta_error_reference Hash plus `message:`; the traversal keeps
  #     going so one bad receipt never hides the rest of the provenance;
  #   * identity_conflict records (see below).
  # Unrelated traversal errors keep strict semantics: they raise, both with and
  # without a warnings Array.  Without the Array, agent_meta problems raise
  # exactly like Chat.traverse_provenance strict mode.
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
  #     conflict: true|false
  #   }
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
  # provider_response_id (missing vs present counts as disagreement), the
  # event keeps every evidence record, counts only the canonical one, sets
  # conflict: true, and - when a warnings Array was supplied - appends one
  # Hash per conflicting event:
  #
  #   {reason: :identity_conflict, inference_id:, identity:,
  #    fields: <Array of disputed field symbols>,
  #    values: <Hash field => the raw meta values in evidence order>,
  #    evidence: <the event evidence records>}
  #
  # Checkpoint fields (*_c, *_s) are never read or summed here.
  def self.provenance_token_events(root, warnings: nil, **traversal_options)
    # Route traversal-stage agent_meta problems into the caller's warnings
    # Array instead of letting them raise.  Other traversal errors stay strict
    # (raise), and an explicitly supplied on_error keeps being called.
    if Array === warnings
      caller_on_error = traversal_options[:on_error]
      traversal_options = traversal_options.merge(
        on_error: lambda do |error, kind, object, relation, reference|
          if relation == :agent_job && AgentMetaError === error
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

    files = provenance_chat_files(root, **traversal_options)
    sources = {}
    files.each { |file| sources[file] = Chat.load(file) }

    evidences = []

    # Chat-side direct events.  One trace_chat_sources call over the whole
    # source list keeps the existing global lineage/inference_id dedup, which
    # is exactly the previous Chat.token_totals behavior (a copied chat in two
    # discovered locations still yields one legacy event).
    trace_chat_sources(sources).each do |entry|
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
      if evidence[:inference_id]
        identity = [:inference_id, evidence[:inference_id]]
        deduplication = :inference_id
      elsif meta[:provider_response_id]
        identity = [:provider_response_id, meta[:provider_response_id]]
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

      fields = []
      values = {}
      TOKEN_KEYS.each do |key|
        next unless ordered.collect { |evidence| evidence[:meta][key].to_i }.uniq.length > 1
        fields << key.to_sym
        values[key.to_sym] = ordered.collect { |evidence| evidence[:meta][key] }
      end
      if ordered.collect { |evidence| evidence[:meta][:provider_response_id] }.uniq.length > 1
        fields << :provider_response_id
        values[:provider_response_id] = ordered.collect { |evidence| evidence[:meta][:provider_response_id] }
      end

      next unless fields.any?
      event[:conflict] = true
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
        conflict: event[:conflict] || false
      }
    end
  end

  # Aggregate token totals over deduplicated provenance events.  The result is
  # symbol keyed and zero initialized exactly like Chat.token_totals:
  # {pt:, ct:, tt:, cct:, cwt:, rt:}.
  #
  # Scopes:
  #   * :aggregate - every event counted once (default);
  #   * :local     - only events with at least one :chat_meta evidence;
  #   * :receipt   - only events with at least one :agent_meta evidence.
  def self.provenance_token_totals(root, scope: :aggregate, warnings: nil, **traversal_options)
    events = provenance_token_events(root, warnings: warnings, **traversal_options)

    selected = case scope.to_sym
               when :aggregate
                 events
               when :local
                 events.select { |event| event[:evidence].any? { |e| e[:origin] == :chat_meta } }
               when :receipt
                 events.select { |event| event[:evidence].any? { |e| e[:origin] == :agent_meta } }
               else
                 raise ParameterException, "Unknown token scope: #{scope}"
               end

    totals = TOKEN_KEYS.each_with_object({}) { |key, hash| hash[key.to_sym] = 0 }
    selected.each do |event|
      TOKEN_KEYS.each { |key| totals[key.to_sym] += event[:tokens][key.to_sym] }
    end
    totals
  end

  # Provenance token aggregate.  Receipt (agent_meta) child usage is now
  # included through the event collector, so child inference paid inside a
  # parent tool call is no longer invisible when the child chat was not saved.
  def self.tokens(root, **options)
    provenance_token_totals(root, **options)
  end

  def self.timestamp
    Time.now.utc.iso8601(3)
  end
end
