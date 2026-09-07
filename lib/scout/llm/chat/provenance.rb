require 'set'
require 'time'

module Chat
  PROVENANCE_RELATIONS = %i[job dependency log result agent_job].freeze

  # Chat-log layout note. A job's own chat logs and a saved chat's .files
  # sidecar are globbed with exactly these families:
  #
  #   new     <x>.files/<name>.chat                        (agent.chat, worker.chat, ...)
  #   <x>.files/<name>.society/**/*.chat           (society tree; nested
  #           societies keep the plain 'society' basename deeper down)
  #
  # The legacy `.files/log/**` layout written by older scout-ai is no longer
  # read; such files are invisible to provenance traversal.  Exactly these
  # families may be swept: resets/, other *.files
  # subdirectories and second-order .files trees stay invisible.  Files matched
  # by more than one pattern are deduplicated and results are sorted so the
  # traversal order is deterministic.
  DIRECT_LOG_CHAT_GLOBS = ['*.chat', '*.society/**/*.chat'].freeze

  # Glob DIRECT_LOG_CHAT_GLOBS under `files_dir` and return a de-duplicated,
  # sorted list of existing chat files (Path objects).  Callers that must
  # exclude the root copy of the root conversation
  # (Chat.direct_chat_sidecar_files) filter afterwards.
  def self.direct_log_chat_glob(files_dir)
    files_dir = files_dir.to_s
    return [] unless File.directory?(files_dir)
    DIRECT_LOG_CHAT_GLOBS
      .flat_map { |pattern| Dir.glob(File.join(files_dir, pattern)) }
      .collect { |file| File.expand_path(file) }
      .select { |file| File.file?(file) }
      .uniq
      .sort
      .collect { |file| Path.setup(file) }
  end

  # Glob DIRECT_LOG_CHAT_GLOBS (see the constant): a job's own chat logs live
  # at <job>.files/<name>.chat and under <job>.files/<name>.society/**.
  # This method is deliberately not recursive; recursion belongs to
  # traverse_provenance.
  def self.direct_job_chat_files(job)
    job = Step.load(job) unless Step === job
    direct_log_chat_glob(job.files_dir)
  end

  # Return only chat logs owned by this persisted chat's .files sidecar.  The
  # save mechanism writes saved agent conversations into the chat's .files dir
  # exactly like a job does, so a chat with a sidecar is scanned the same way a
  # job is.  This method is deliberately not recursive; recursion belongs to
  # traverse_provenance.
  #
  # Glob DIRECT_LOG_CHAT_GLOBS (see the constant) plus the root-copy
  # exclusion.  The save mechanism writes a full copy of the ROOT conversation
  # at the TOP LEVEL of the files dir (<path>.files/<name>.chat, e.g.
  # agent.chat); such top-level copies must be excluded here or the chat would
  # get a self-edge duplicating the root node.  Note the asymmetry with
  # direct_job_chat_files: a JOB's own top-level agent.chat IS traversed
  # (renderers hide it), a CHAT's root copy is NOT.  Only TOP-LEVEL *.chat
  # files are excluded: society chats under <name>.society/ are independent
  # conversations and are included.
  def self.direct_chat_sidecar_files(path)
    files_dir = path.to_s + '.files'
    return [] unless File.directory?(files_dir)
    top_level = Dir.glob(File.join(files_dir, '*.chat')).collect { |file| File.expand_path(file) }
    direct_log_chat_glob(files_dir).reject do |file|
      top_level.include?(file.to_s)
    end
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

  # ------------------------------------------------------------------
  # Run-scoped, parse-once chat cache (review theme 04, stage s1)
  # ------------------------------------------------------------------
  # A provenance "run" is one top-level call to a public provenance entry
  # point (traverse_provenance, provenance_token_events,
  # provenance_token_totals / tokens, and the collectors delegating to them).
  # Inside a run every chat file is parsed at most once, keyed by the same
  # realpath discipline as node identity (provenance_path), so a file reached
  # through several addresses - symlinks, or a chat-typed job whose result
  # path equals a chat node path - is parsed once and never double counted.
  #
  # Guards:
  #   * lifetime: the cache exists only while a run is active and is dropped
  #     when it ends, so a live session that appends between two runs is
  #     always re-parsed (no cross-run persistence);
  #   * identity: realpath keyed, exactly like provenance nodes;
  #   * transparency: no envelope shape, traversal order or deduplication
  #     semantics change - the same Chat object is simply reused within the
  #     run, and everything downstream only reads it.
  def self.with_provenance_run_cache
    previous = Thread.current[:scout_ai_provenance_run_cache]
    Thread.current[:scout_ai_provenance_run_cache] ||= {}
    begin
      yield
    ensure
      Thread.current[:scout_ai_provenance_run_cache] = previous
    end
  end

  # Manual scope control for linear, top-level callers such as the `prov`
  # SOPT script, whose body cannot be wrapped in a block without reindenting
  # the whole file.  Open at the start of the run, close when it ends; an
  # open scope makes nested with_provenance_run_cache calls reuse it.
  def self.open_provenance_run_cache
    Thread.current[:scout_ai_provenance_run_cache] ||= {}
  end

  def self.close_provenance_run_cache
    Thread.current[:scout_ai_provenance_run_cache] = nil
  end

  # Chat.load with the run cache applied.  Outside a run this parses
  # directly, exactly like Chat.load.
  def self.provenance_chat_load(path)
    cache = Thread.current[:scout_ai_provenance_run_cache]
    return Chat.load(path) unless cache
    cache[provenance_path(:chat, path)] ||= Chat.load(path)
  end

  def self.provenance_error(on_error, error, kind, object, relation, reference)
    raise error unless on_error
    on_error.call(error, kind, object, relation, reference)
  end

  # Candidate filesystem bases, in priority order, used to resolve a relative
  # job reference (e.g. "Planned/ask/Default_abc.chat") when Step.load could
  # not locate the job data: first the standard Rbbt workflow storage
  # (~/.rbbt/var/jobs), then Scout's own workflow storage (Scout.var.jobs,
  # normally ~/.scout/var/jobs).  Exposed as a class method so tests can point
  # it at a tmp fixture tree instead of the real HOME.
  def self.job_reference_fallback_bases
    ['~/.rbbt/var/jobs', Scout.var.jobs.find.to_s].collect { |base| File.expand_path(base) }
  end

  # A reference is acceptable when the job file itself exists or its .info
  # sidecar does (a job whose payload was cleaned but whose .info survives
  # still carries provenance).
  def self.job_reference_candidate?(path)
    path = path.to_s
    File.exist?(path) || File.exist?(path + '.info')
  end

  # Resolve a job reference from a chat meta message into a Step. References
  # like "Planned/ask/Default_abc.chat" are relative workflow paths. Step.load
  # may resolve them to a Scout-specific directory that does not contain the
  # actual job data, so we fall back to the candidate bases in order.
  def self.load_job_reference(reference)
    return reference if Step === reference
    ref_str = reference.to_s

    step = Step.load(ref_str)
    return step if job_reference_candidate?(step.path.to_s)

    # Step.load resolves relative workflow paths (e.g. Planned/ask/Default_xyz.chat)
    # via Path.find, which may point to a directory that does not contain the
    # actual job data (e.g. ~/.scout/ instead of ~/.rbbt/var/jobs/). Try each
    # candidate base in priority order; the first base under which the file or
    # its .info sidecar exists wins. Order is preserved: Step.load first, then
    # the bases exactly as listed in job_reference_fallback_bases.
    job_reference_fallback_bases.each do |base|
      candidate = File.join(base, ref_str)
      return Step.load(candidate) if job_reference_candidate?(candidate)
    end

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
  # node: malformed receipts collected by Chat.agent_meta_job_references.
  # Provenance is only ever extracted from parsed function_call_output JSON
  # Hashes carrying an explicit receipt key (current `meta`, legacy
  # `agent_meta`); raw output text is never
  # inspected, so output content that merely mentions "agent_meta" cannot
  # produce a warning.  Each malformed record becomes one Chat.provenance_error
  # call with relation :agent_job and kind/object :chat + the chat path, so
  # strict mode (no on_error) raises ScoutException while warning mode keeps
  # going.  Returns the valid job references so the caller can enqueue them
  # afterwards.
  def self.report_agent_meta_problems(chat, object, on_error = nil)
    warnings = []
    references = agent_meta_job_references(chat, source: object, warnings: warnings)

    warnings.each do |warning|
      error = ScoutException.new(
        agent_meta_error_message(warning[:reason],
                                 chat_path: object.to_s,
                                 output_address: warning[:output_address],
                                 call_id: warning[:call_id],
                                 tool_name: warning[:tool_name],
                                 reference: warning[:reference] || warning[:raw_entry])
      )
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
  #   kind, object, parent_kind, parent, relation, first_visit, detail
  #
  # `kind` is :chat or :job. Chat objects are persisted file Paths; jobs are
  # Steps. The root has nil parent/relation. Every structural edge is yielded,
  # including an edge to a node visited through another branch; first_visit is
  # false in that case and the node is not expanded again.
  #
  # `detail` is nil for every ordinary edge. For an :agent_job edge it is the
  # agent_meta receipt record (Chat.agent_meta_job_references entry) that
  # produced the edge, so the originating function output address, receipt
  # address, call id and tool name stay auditable without re-parsing the parent
  # chat. Blocks accepting only the first six arguments keep working; the
  # trailing detail is only passed when the block can receive it (or accepts
  # any number of arguments).
  #
  # Relations describe root-outward discovery, not diagram arrow direction:
  # chat -> producer job (:job), chat -> delegated-agent producer job
  # (:agent_job, from agent_meta receipts), job -> dependency (:dependency),
  # job -> log chat (:log), job -> result chat (:result), and chat -> log chat
  # of its own .files sidecar (:log, saved agent conversations, excluding the
  # top-level root copy).
  #
  # Imported and continued chats are a chat-compilation concern, not a
  # provenance concern. They are resolved during Chat.parse and their content
  # is already inlined in the persisted chat file. Provenance traversal
  # therefore never follows import, continue, or last references.
  def self.traverse_provenance(root, root_type: nil, follow: :all, on_error: nil, &block)
    return enum_for(__method__, root, root_type: root_type, follow: follow, on_error: on_error) unless block
    unless Thread.current[:scout_ai_provenance_run_cache]
      return with_provenance_run_cache do
        traverse_provenance(root, root_type: root_type, follow: follow, on_error: on_error, &block)
      end
    end
    # Lambda blocks have strict arity; keep six-argument callbacks compatible
    # by only yielding the trailing detail when the block can receive it.
    detail_arity = lambda do
      return true if block.arity == -1
      block.arity >= 7
    end

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
      kind, object, parent_kind, parent, relation, detail = queue.shift
      key = provenance_key(kind, object)
      first_visit = !seen.include?(key)
      if detail_arity.call
        block.call(kind, object, parent_kind, parent, relation, first_visit, detail)
      else
        block.call(kind, object, parent_kind, parent, relation, first_visit)
      end
      next unless first_visit
      seen << key

      begin
        if kind == :chat
          chat = provenance_chat_load(object)

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
            # Malformed receipts are diagnostics, never provenance; they are
            # reported through provenance_error and skipped.
            references = begin
                           report_agent_meta_problems(chat, object, on_error)
                         rescue StandardError => error
                           provenance_error(on_error, error, :chat, object, :agent_job, object)
                           []
                         end

            references.each do |record|
              reference = record[:job]
              begin
                job, _unresolved = resolve_job_reference(reference)
                if job
                  # The receipt record travels with the edge as its detail so
                  # the traversal keeps the originating output address, call
                  # id and receipt index.
                  queue << [:job, job, :chat, object, :agent_job, record]
                else
                  error = ScoutException.new(
                    agent_meta_error_message(:unresolved_job_reference,
                                             chat_path: object.to_s,
                                             output_address: record[:output_address],
                                             call_id: record[:call_id],
                                             tool_name: record[:tool_name],
                                             reference: reference)
                  )
                  provenance_error(on_error, error, :chat, object, :agent_job,
                                   agent_meta_error_reference(reason: :unresolved_job_reference,
                                                              source: object.to_s,
                                                              output_address: record[:output_address],
                                                              evidence_address: record[:evidence_address],
                                                              call_id: record[:call_id],
                                                              tool_name: record[:tool_name],
                                                              reference: reference))
                end
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

          if relations.include?(:log)
            # A saved chat owns its .files sidecar logs (society
            # conversations) just like a job owns its job logs.
            direct_chat_sidecar_files(object).each do |file|
              queue << [:chat, file, :chat, object, :log]
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
  #
  # `:agent_job` edges carry the agent_meta receipt record that produced them
  # under `detail:` (call id, tool name, output address, receipt address, job
  # reference). Two distinct receipts pointing at the same job therefore remain
  # two distinguishable edges instead of collapsing into one; ordinary edges
  # keep `detail: nil`.
  def self.provenance_edges(root, **options)
    edges = []
    traverse_provenance(root, **options) do |kind, object, parent_kind, parent, relation, _first, detail|
      next unless parent
      edge = {
        from_kind: parent_kind,
        from: parent,
        relation: relation,
        to_kind: kind,
        to: object,
        detail: detail
      }
      same_edge = lambda do |other|
        other[:relation] == relation &&
          provenance_key(other[:from_kind], other[:from]) == provenance_key(parent_kind, parent) &&
          provenance_key(other[:to_kind], other[:to]) == provenance_key(kind, object) &&
          (relation != :agent_job ||
           (detail.nil? && other[:detail].nil?) ||
           (detail && other[:detail] && detail[:evidence_address] == other[:detail][:evidence_address]))
      end
      edges << edge unless edges.any?(&same_edge)
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
  def self.provenance_token_events(root, warnings: nil, strict: false, **traversal_options)
    unless Thread.current[:scout_ai_provenance_run_cache]
      return with_provenance_run_cache do
        provenance_token_events(root, warnings: warnings, strict: strict, **traversal_options)
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

    files = provenance_chat_files(root, **traversal_options)
    sources = {}
    files.each { |file| sources[file] = provenance_chat_load(file) }

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

  # ------------------------------------------------------------------
  # Live workload: the transient <base>.jobs sidecar
  # ------------------------------------------------------------------
  # `LLM.process_calls` writes the short paths of the workflow jobs it is
  # currently producing (Workflow.produce blocking) to `Chat.jobs_file`,
  # rewriting per round and removing the file in an `ensure` when produce
  # returns.  This section turns that transient snapshot into the LIVE view
  # of an agent's workload, complementing the FORENSIC traversal above:
  # absent file is a non-event, never an error.

  # Terminal statuses as recorded in a job `.info` after Workflow.produce
  # returns (or an abort/clean sweep).  Anything else is in-flight or stale,
  # decided by pid liveness below.
  LIVE_TERMINAL_STATUSES = %w[done error aborted cleaned].freeze

  # Is `pid` a live process right now?  Mirrors Misc.pid_alive? but adds the
  # zombie guard: a child that exited without being reaped still answers
  # kill(0, 0), yet produces nothing, so a zombie is NOT running work.
  def self.live_pid?(pid)
    return false if pid.nil? || pid.to_s.empty?
    pid = pid.to_i
    return false unless pid > 0
    return true if pid == Process.pid
    stat = File.read("/proc/#{pid}/stat") rescue nil
    return false if stat.nil?
    # field 3 of /proc/<pid>/stat is the state; Z = zombie
    state = stat.split(')')[-1].split[0]
    state != 'Z'
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  # Classify one in-flight workload entry from its `.info`:
  #   [:running, status]    non-terminal status + live pid
  #   [:crashed, status]    non-terminal status + dead/absent pid
  #   [:finished, status]   terminal status (done/error/aborted/cleaned)
  #
  # Reconciliation caveats (inherent to the snapshot contract):
  #   * `kill -9` leaves `.info` non-terminal forever; pid liveness is the
  #     only way to distinguish running from crashed.  The LocalExecutor
  #     retry can RESURRECT such a job by overwriting `.info` with a new
  #     pid, so a :crashed verdict is valid only for the moment it was
  #     computed.
  #   * a listed job may complete between reading `<base>.jobs` and reading
  #     its `.info`: the snapshot race is expected, and the classification
  #     simply reports what was seen (often :finished).
  #   * `.info` may be missing entirely (job cleaned between reads); the
  #     entry reports :crashed with a nil status.
  def self.classify_live_job(step)
    status = begin
      info = step.info
      info[:status].to_s
    rescue
      nil
    end

    return [:finished, status] if LIVE_TERMINAL_STATUSES.include?(status.to_s)
    pid = begin
      (step.info[:pid] rescue nil)
    end
    state = live_pid?(pid) ? :running : :crashed
    [state, status]
  end

  # Resolve one short-path entry of the live sidecar to a Step.
  #
  # The Workflow jobs tree root (`Workflow.directory`) is tried FIRST because
  # that is where process_calls actually produced the job: the sidecar stores
  # SHORT paths, and Step.load rewrites a bare short path through
  # Path.find/Step.relocate, which can land on a different (empty) mirror of
  # the tree (e.g. `~/.scout/var/jobs/...` while the real job lives under the
  # run's Workflow.directory).  Falling back to the forensic
  # `load_job_reference` chain keeps unresolved entries diagnosable.
  def self.load_live_job_reference(reference)
    return reference if Step === reference
    ref_str = reference.to_s

    base = Workflow.directory.respond_to?(:find) ? Workflow.directory.find : Workflow.directory
    candidate = File.join(base.to_s, ref_str)
    return Step.load(candidate) if job_reference_candidate?(candidate)

    step = Step.load(ref_str)
    return step if job_reference_candidate?(step.path.to_s)

    load_job_reference(ref_str)
  end

  # Resolve each entry of the live sidecar of `save_file` (or the chat/job
  # path it stands for) into a Step with its live classification.  Returns an
  # Array of Hashes (one per sidecar entry, order preserved):
  #
  #   {reference: 'WF/task/name', step: Step, path: <job dir>,
  #    status: 'running'|..., state: :running/:crashed/:finished,
  #    chat_task: true|false}
  #
  # `chat_task` uses the LIVE discriminator `step.type.to_s == 'chat'`
  # (chat_task annotation; a hand-written task declaring :chat is inference
  # by definition).  The CONCLUDED discriminator (output JSON with exactly
  # `meta` and `content` keys) belongs to the forensic traversal and is NOT
  # re-checked here: the sidecar only ever lists in-flight jobs.
  #
  # An absent sidecar is a NON-EVENT: returns [].  Resolution uses the same
  # fallback chain as forensic job references (`load_job_reference`), so a
  # short path resolves against the workflow jobs tree.
  def self.live_workload(reference)
    base = reference.respond_to?(:path) ? reference.path.to_s : reference.to_s

    # Accept a chat file, a job path (result chat) or a bare save_file: the
    # sidecar is always derived from the save_file base via Chat.jobs_file.
    candidates = [base, base.sub(/\.chat\z/, '')]
    sidecar = candidates.collect { |c| Chat.jobs_file(c) }
                         .find { |f| File.exist?(f) }

    return [] if sidecar.nil?

    entries = Open.read(sidecar).split("\n")
                  .collect(&:strip).reject(&:empty?)

    entries.collect do |entry|
      step = load_live_job_reference(entry)
      state, status = classify_live_job(step)
      type = begin
        step.type.to_s
      rescue
        nil
      end
      {
        reference: entry,
        step: step,
        path: step.path.to_s,
        status: status,
        state: state,
        chat_task: type == 'chat'
      }
    end
  end

  # ------------------------------------------------------------------
  # Dependency expansion + unified live report
  # ------------------------------------------------------------------
  # expand_live_jobs below walks the dependencies a wrapper job RECORDS in
  # its `.info`; live_report folds the three live passes.  Between them
  # sits one repair: the waiting-wrapper fallback.

  # ------------------------------------------------------------------
  # Waiting-wrapper fallback: definition-blind dependency discovery
  # ------------------------------------------------------------------
  # Gap-4 repair.  A wrapper job whose chat_task dependency is still
  # running sits at `{"status":"waiting"}` with NO pid and NO
  # `dependencies` key: scout-gear's Step#run records the dependency list
  # in `.info` only at reset_info(status: :setup) inside the persist
  # block, i.e. AFTER run_dependencies returns (probe: p4-fix-probe.md —
  # `dependencies` appears only after the dependency itself flipped to
  # done).  A file-based reader that only consults `step.dependencies`
  # is therefore structurally blind in exactly the window the live pass
  # exists for.
  #
  # Fallback used here (direction 1 in step 4's design): when a wrapper
  # Step carries no recorded dependencies, look for running jobs in the
  # wrapper's own TASK namespace on disk — `var/jobs/<Workflow>/<task>`.
  # Scout-gear materializes every dependency of a job under the SAME
  # workflow namespace (its job directory is <workflow_dir>/<task>), so a
  # sibling job directory in that namespace that is itself running is a
  # dependency candidate.  This deliberately does NOT try to load the
  # workflow definition (require_workflow resolves names through the
  # `workflows` pathmap, which points at ~/.scout/workflows and cannot
  # see an arbitrary jobs tree — probe (b)); the namespace scan is local
  # to the data the pass already owns.  Attribution stays bounded: only
  # jobs in the SAME workflow directory as the wrapper are considered,
  # and captured ids keep their dedup role.

  # Candidate dependency jobs of a wrapper Step whose `.info` predates
  # dependency recording: running job directories in the wrapper's WORKFLOW
  # namespace (`File.dirname(File.dirname(step.path))`), i.e. sibling task
  # directories — where scout-gear materializes every dependency of the
  # wrapper.  Returns [] when the step is fine (has recorded dependencies),
  # is in a terminal phase, or nothing on disk qualifies.  Never raises.
  def self.live_dependency_candidates(step)
    return [] unless Step === step
    info = begin
      step.info
    rescue StandardError
      return []
    end
    return [] if Array === info[:dependencies] && !info[:dependencies].empty?

    status = info[:status].to_s
    return [] if LIVE_TERMINAL_STATUSES.include?(status)

    # Workflow namespace, one level ABOVE the wrapper's task dir: probe (c)
    # confirmed dependencies materialize as sibling TASK directories under
    # var/jobs/<Workflow>/ (CortexWF/continue beside CortexWF/cortex_continue),
    # never inside the wrapper's own task dir.  Definition-driven resolution
    # (the first choice) is infeasible from a jobs tree: require_workflow
    # resolves names through the `workflows` pathmap (~/.scout/workflows),
    # which cannot see an arbitrary Workflow.directory (probe (b)).
    workflow_dir = begin
      File.dirname(File.dirname(step.path.to_s))
    rescue StandardError
      return []
    end
    return [] unless File.directory?(workflow_dir)

    step_path = step.path.to_s
    candidates = []
    # Glob `.info` files, not job directories: a chat_task's job path is
    # itself a FILE (`<name>.chat`, the result), with `.files` beside it;
    # a directory-only scan sees `<name>.chat.files` and misses the job.
    Dir.glob(File.join(workflow_dir, '*', '*.info')).sort.each do |info_file|
      entry = info_file.sub(/\.info\z/, '')
      next if entry == step_path

      begin
        dep_info = Step.load_info(info_file)
      rescue StandardError
        next
      end
      state, _status = classify_live_job_info(dep_info)
      next unless state == :running

      dep_step = begin
        Step.load(entry)
      rescue StandardError
        next
      end
      candidates << dep_step
    end
    candidates
  end

  # Same classification as classify_live_job but from an already-loaded
  # info Hash (no Step round-trip); used by live_dependency_candidates.
  def self.classify_live_job_info(info)
    return [:unknown, nil] unless Hash === info
    status = info[:status]
    if LIVE_TERMINAL_STATUSES.include?(status.to_s)
      return [:finished, status]
    end
    state = live_pid?(info[:pid]) ? :running : :crashed
    [state, status]
  end

  # ------------------------------------------------------------------
  # Unified live report: sidecar + agent view + society, deduplicated

  # ------------------------------------------------------------------
  # Closes the fourth live gap: the `.jobs` sidecar lists the job the tool
  # call RESOLVED (a plain wrapper such as Cortex#cortex_continue), while
  # the actually-running inference lives in a DEPENDENCY job (the chat task
  # Cortex#continue).  `LLM.process_calls` already walks
  # `job.rec_dependencies` to init their `.info` before producing
  # (tools/call.rb), so the dependency chain is exactly where the live
  # inference is; the sidecar entry alone is not.
  #
  # This section also folds the three live passes (sidecar, agent view,
  # society) into one data-only report, `Chat.live_report`, which is the
  # unit the CLI will render.

  # Depth cap for the dependency walk.  Step#rec_dependencies is itself
  # cycle-safe (it threads a seen-set through the recursion, scout-gear
  # lib/scout/workflow/step/dependencies.rb), so this cap is a second,
  # independent guard against a hand-built or stubbed dependency graph and
  # against pathological depth; it is not load-bearing for real graphs.
  LIVE_DEPENDENCY_DEPTH_LIMIT = 5

  # Agent log file of a running chat task: the chat_task machinery anchors
  # its agents under the JOB's files dir (AgentWorkflow log_agent,
  # agent/workflow.rb: `agent.save_file = Agent.canonical_chat_file(
  # files_dir, agent_name)`), so the log lives at
  # `<job>.files/<agent_name>.chat` and defaults to `agent.chat` when the
  # agent was unnamed.  Returns nil when no such file exists.
  def self.live_chat_task_agent_log(step, agent_name: nil)
    return nil unless Step === step
    files_dir = begin
      step.files_dir
    rescue
      return nil
    end
    return nil if files_dir.nil?

    names = agent_name ? [agent_name] : ['agent', nil]
    names.each do |name|
      begin
        candidate = LLM::Agent.canonical_chat_file(files_dir, name)
      rescue
        return nil
      end
      return candidate if File.exist?(candidate)
    end

    nil
  end

  # Expand sidecar job entries into the set of RUNNING jobs reachable from
  # them (each entry plus its rec_dependencies), with cycle (visited-set)
  # and depth (LIVE_DEPENDENCY_DEPTH_LIMIT) guards.  Returns an Array of
  # Hashes:
  #
  #   {step: Step, path:, reference:, status:, state: :running,
  #    chat_task: true|false, agent_log: <path or nil>,
  #    activity: <agent_log_activity hash or nil>,
  #    via: <short path of the sidecar entry that reached it>}
  #
  # Only `classify_live_job == :running` jobs are kept (finished/crashed
  # dependencies are not live work), and `chat_task` uses the same LIVE
  # discriminator as live_workload (`step.type.to_s == 'chat'`).  Running
  # non-chat dependencies are kept as workload CONTEXT (information the
  # sidecar view reported before must not disappear); the unified report
  # below separates inference from context, this method keeps both.
  #
  # `via` records which sidecar entry each job was reached through, so the
  # wrapper's presence stays visible without duplicating the inference.
  def self.expand_live_jobs(entries)
    entries = entries.respond_to?(:each) ? entries : [entries]
    collected = []
    visited = Set.new

    entries.each do |entry|
      step = Step === entry ? entry : load_live_job_reference(entry)
      # `via` is the sidecar ENTRY (short path) for a String entry, or the
      # job's own short path for a Step entry, so the reported `reference`
      # stays in the same form the sidecar and a `job=` meta both use.
      via = Step === entry ? begin
        step.short_path
      rescue StandardError
        step.path.to_s
      end : entry.to_s
      walk_live_job(step, via, 0, visited, collected)
    end

    collected
  end

  # One visited node of the dependency walk: classify, keep if running,
  # recurse into rec_dependencies while under the depth cap.  Fail-soft per
  # job: an entry whose job cannot be loaded or classified is skipped
  # silently (the forensic traversal is the place to diagnose it).
  def self.walk_live_job(step, via, depth, visited, collected)
    return nil unless Step === step

    path = begin
      step.path.to_s
    rescue
      return nil
    end
    return nil if visited.include?(path)
    visited << path

    state, status = classify_live_job(step)
    if state == :running
      type = begin
        step.type.to_s
      rescue
        nil
      end
      chat_task = type == 'chat'
      agent_log = chat_task ? live_chat_task_agent_log(step) : nil
      reference = begin
        step.short_path
      rescue StandardError
        via
      end
      collected << {
        step: step,
        path: path,
        reference: reference,
        status: status,
        state: state,
        chat_task: chat_task,
        agent_log: agent_log,
        activity: agent_log ? agent_log_activity(agent_log) : nil,
        via: via
      }
    end

    return nil if depth >= LIVE_DEPENDENCY_DEPTH_LIMIT

    # One level at a time, NOT Step#rec_dependencies: rec_dependencies is
    # itself a recursive, cycle-safe flattener, so walking it would return
    # the whole transitive set on the first hop and make the depth cap
    # below meaningless (it can never fire past depth one).  Walking
    # `dependencies` (the direct, recorded edges) keeps BOTH guards of this
    # walk operative: the visited-set here and the depth cap, each an
    # independent second line of defense for stubbed or hand-built graphs.
    deps = begin
      step.dependencies
    rescue StandardError
      []
    end

    # Waiting-wrapper repair (see the fallback section above): a wrapper in
    # a pre-dependency phase (waiting, no `dependencies` key yet, no pid)
    # records nothing for `step.dependencies` to walk — fall back to the
    # definition-blind sibling scan of its task namespace.  Only invoked
    # when the recorded set is empty AND the step itself is in that phase,
    # so a DONE wrapper or a genuinely dependency-free task is unaffected.
    if Array(deps).empty?
      candidates = live_dependency_candidates(step)
      unless candidates.empty?
        collected << {
          step: step,
          path: path,
          reference: begin
            step.short_path
          rescue StandardError
            via
          end,
          status: status,
          state: :waiting,
          chat_task: false,
          agent_log: nil,
          activity: nil,
          via: via
        }
      end
      deps = candidates
    end
    Array(deps).each do |dep|
      walk_live_job(dep, via, depth + 1, visited, collected)
    end
    nil
  end

  # Merge two same-job entries, keeping the union of their facts.  Keys
  # present in only one entry win as-is; keys present in both (e.g. nil vs
  # a real agent_log, or two different :source tags) resolve to the
  # non-nil/non-empty side, so a job reached by the sidecar pass AND by a
  # dangling `job=` meta keeps the richest view, never two entries.
  def self.merge_live_entries(one, other)
    merged = one.dup
    other.each do |key, value|
      current = merged[key]
      if current.nil? || current.respond_to?(:empty?) && current.empty?
        merged[key] = value
      elsif value.is_a?(Hash) && current.is_a?(Hash)
        merged[key] = current.merge(value)
      end
    end
    merged[:source] = [one[:source], other[:source]].flatten.compact.uniq if one[:source] || other[:source]
    merged
  end

  # Unified LIVE report for the chat (or job) at `save_file`/`reference`:
  # the single data-only unit that folds the three live passes and that the
  # CLI will render.
  #
  #   Chat.live_report(save_file, captured: ids)
  #   # => {entries: [...], scanned: {sidecar: bool, agent_view: bool,
  #   #                              society: bool}}
  #
  # Entry schema (superset per kind; kind is one of :inference,
  # :workload_context, :agent_activity, :dangling_job):
  #
  #   {kind:, source: [:sidecar|:agent_view|:society|...],
  #    reference:, path:, state:, status:, chat_task:,
  #    agent_log:, activity:, agent:, conversation:, via:, parent:}
  #
  # Folding and dedup rules:
  #   * entries whose job id is in `captured` (live_captured_ids) are
  #     dropped in EVERY pass: the forensic main report already holds them;
  #   * cross-pass dedup is by job id (reference/path), merging facts
  #     (merge_live_entries), never emitting two entries for one job;
  #   * per agent-log file the two agent-side signals (:agent_activity vs
  #     :dangling_job) collapse to one entry exactly like society_live does:
  #     the dangling job wins as the kind, the activity hash is carried
  #     either way;
  #   * a running sidecar job that is a chat task becomes an :inference
  #     entry; a running non-chat job becomes :workload_context (the plain
  #     information live_workload already reported must not disappear).
  #
  # Everything is fail-soft: absent sidecar, absent agent save file, absent
  # society tree and unreadable jobs each yield nothing and never raise.
  def self.live_report(save_file, captured: [])
    captured_ids = live_captured_ids(captured)
    base = save_file.respond_to?(:path) ? save_file.path.to_s : save_file.to_s

    # Entries are keyed by job id where one exists (the sidecar SHORT path,
    # the same form a `job=` meta stores, so cross-pass matches are plain
    # string equality) and by agent-log path otherwise.
    entries = {}

    # --- sidecar pass with dependency expansion (gap 4) ---
    # `live_workload` keeps its contract untouched: entries only, no
    # expansion.  The expansion walks each entry plus its rec_dependencies
    # so the dependency job actually running the inference is reported, not
    # just the wrapper the tool call resolved.
    sidecar_entries = begin
      expand_live_jobs(live_workload(base).collect { |e| e[:step] })
    rescue StandardError
      []
    end
    sidecar_entries.each do |entry|
      job_id = entry[:reference].to_s
      next if job_id.empty?
      next if captured_ids.include?(job_id) ||
              captured_ids.include?(entry[:path].to_s)

      folded = entry.merge(kind: entry[:chat_task] ? :inference : :workload_context,
                           source: [:sidecar])
      # A waiting wrapper surfaced only by the fallback is neither running
      # inference nor finished: report it as workload context (it is live
      # state — its dependency is running) instead of letting classify's
      # :crashed verdict drop it.
      if entry[:state] == :waiting && !entry[:chat_task]
        folded = folded.merge(kind: :workload_context,
                              state: :waiting,
                              status: entry[:status])
      end
      entries[job_id] = entries.key?(job_id) ?
                           merge_live_entries(entries[job_id], folded) : folded
    end
    scanned_sidecar = begin
      [base, base.sub(/\.chat\z/, '')].any? { |b| File.exist?(Chat.jobs_file(b)) }
    rescue StandardError
      false
    end

    # --- agent view pass (gaps 1-2) on the root agent save file ---
    agent_entries = begin
      agent_view_live(base, captured: captured)
    rescue StandardError
      []
    end

    # --- society pass (gap 3) ---
    society_entries = begin
      society_live(base, captured: captured)
    rescue StandardError
      []
    end

    # --- fold the agent-side passes: per agent-log file at most ONE entry
    #     (the dangling job wins as the kind, the activity hash rides
    #     along), then merge into the job-id space so a job the sidecar
    #     already reported and a dangling `job=` meta name once. ---
    agent_side = {}
    ([[:agent_view, agent_entries], [:society, society_entries]]).each do |source, list|
      list.each do |entry|
        log_file = entry[:agent_file] || entry[:path]
        next if log_file.nil?

        entry = entry.merge(source: [source])
        if agent_side.key?(log_file)
          agent_side[log_file] = merge_live_entries(agent_side[log_file], entry)
        else
          agent_side[log_file] = entry
        end
      end
    end

    agent_side.each_value do |entry|
      # A log file whose RUNNING `job=` references were all captured has
      # its liveness already represented by those jobs: drop the bare
      # activity entry too (the same rule society_live applies to its
      # children).  Files with no running reference at all (the
      # Clean-type gap) keep their activity entry.
      if entry[:kind] == :agent_activity
        running_refs = begin
          dangling_agent_job_metas(entry[:agent_file].to_s, captured: [])
        rescue StandardError
          []
        end
        next if !running_refs.empty? &&
                running_refs.all? { |ref| captured_ids.include?(ref[:reference].to_s) }
      end

      job_id = entry[:reference].to_s
      job_id = entry[:job].to_s if job_id.empty?
      next if !job_id.empty? && (captured_ids.include?(job_id) ||
                                 captured_ids.include?(entry[:path].to_s))

      folded = entry.merge(source: [entry[:source]].flatten.compact.uniq)
      if !job_id.empty? && entries.key?(job_id)
        entries[job_id] = merge_live_entries(entries[job_id], folded)
      elsif !job_id.empty?
        entries[job_id] = folded
      else
        entries[entry[:agent_file].to_s] = folded
      end
    end

    society_dir = begin
      society_dir_of(base)
    rescue StandardError
      nil
    end
    {
      entries: entries.values,
      scanned: {sidecar: scanned_sidecar,
                agent_view: begin
                  File.exist?(base)
                rescue StandardError
                  false
                end,
                society: !society_dir.nil? && Dir.exist?(society_dir)}
    }
  end

  # ------------------------------------------------------------------
  # Agent view: live state of the agent's own save file
  # ------------------------------------------------------------------
  # The `.jobs` sidecar above only sees jobs dispatched through the
  # backend tool round (Workflow.produce inside process_calls).  Two live
  # states never appear there:
  #
  #   * a "Clean"-type agent (no inference workflow) creates no workflow
  #     jobs at all; its only live state is its save file, rewritten at
  #     every round boundary by the backend (outgoing-transcript flush)
  #     and per completed round by Agent#chat's ensure hook
  #     (save_if_configured).
  #   * an agent backed by an AgentWorkflow `ask` task writes the
  #     immediate `job=` meta at dispatch (Agent#ask) and saves BEFORE
  #     producing the job, so the reference dangles in the save file for
  #     the whole duration of the running chat task.
  #
  # Save-file location (pinned for callers): a root chat `<base>` keeps
  # its agent conversation at `<base>.files/<agent>.chat`, derived by
  # LLM::Agent.canonical_chat_file(base + '.files', agent_name) where the
  # agent name comes from the chat's `agent:` line (nil means the plain
  # `agent.chat`).  This layer takes the save-file PATH as input; the
  # caller resolves it because only it knows the agent name.

  # Roles that annotate or steer a chat without marking inference state.
  # Trailing ones are skipped when the activity predicate looks for the
  # last conversational message: a file ending in `meta: job=...`
  # (dispatch in flight) still classifies by the prompt that triggered
  # it, and the job reference itself is reported separately by
  # dangling_agent_job_metas.
  AGENT_CONTROL_ROLES = %w[
    meta option sticky_option previous_response_id agent import socialize attachments
  ].freeze

  # Classify the live activity of one agent save file from its trailing
  # messages.  Predicate rules (user-approved heuristic, encoded
  # exactly):
  #
  #   last message `user`                     -> active, :dispatched
  #     (prompt flushed; the turn's first inference round is running or
  #     pending)
  #   trailing `function_call` with no
  #   `function_call_output` after it         -> active, :tool_round_in_flight
  #   trailing `function_call_output`         -> active, :next_round_pending
  #   last message `assistant` with no
  #   unresolved function call                -> inactive, :idle
  #   empty file                              -> inactive, :no_messages
  #   unreadable/missing file                 -> inactive, :unreadable
  #
  # Control roles (AGENT_CONTROL_ROLES) are skipped when finding the
  # trailing conversational message; any other trailing role (system,
  # introduce, tool) means no inference has been dispatched yet and
  # yields inactive :no_inference.  Caveat, accepted by design: an
  # `assistant`-terminated file is classified idle even during the brief
  # round-boundary window in which a completed round has been saved but
  # the next dispatch has not flushed yet, so a mid-conversation agent
  # can be missed for that instant (false negative, never a false
  # positive).
  #
  # ScoutCoder: this predicate is only sound because the backend rewrites
  # the save file with the OUTGOING transcript at every round boundary
  # (the ensure hooks of LLM::Backend::Default#ask) while the agent layer
  # rewrites it with the completed round afterwards (Agent#chat ensure ->
  # save_if_configured).  That write cadence is documented nowhere and
  # had to be derived from lib/scout/llm/backends/default.rb.
  def self.agent_log_activity(path)
    path = path.to_s

    messages = begin
      Chat.load(path)
    rescue StandardError
      return {active: false, reason: :unreadable, last_role: nil,
              message_count: 0, rounds: 0}
    end

    counts = {
      message_count: messages.length,
      rounds: messages.count { |message| message[:role].to_s == 'assistant' }
    }

    conversational = messages.reject do |message|
      AGENT_CONTROL_ROLES.include?(message[:role].to_s)
    end
    last = conversational.last

    return {active: false, reason: :no_messages, last_role: nil}.merge(counts) if last.nil?

    role = last[:role].to_s
    case role
    when 'user'
      {active: true, reason: :dispatched, last_role: role}.merge(counts)
    when 'function_call'
      {active: true, reason: :tool_round_in_flight, last_role: role}.merge(counts)
    when 'function_call_output'
      {active: true, reason: :next_round_pending, last_role: role}.merge(counts)
    when 'assistant'
      {active: false, reason: :idle, last_role: role}.merge(counts)
    else
      {active: false, reason: :no_inference, last_role: role}.merge(counts)
    end
  end

  # Normalize the forensic "captured" set into plain strings a live
  # reference can be compared against.  Entries may be Step objects (the
  # traversal's nodes), Path objects or strings; both the verbatim string
  # and its expanded form are kept, so a short path, a resolved path and
  # a Step all match the same job.
  def self.live_captured_ids(captured)
    entries = captured.respond_to?(:each) ? captured : [captured]
    ids = Set.new
    entries.each do |entry|
      next if entry.nil?
      case entry
      when Step
        path_str = entry.path.to_s
        ids << path_str
        ids << File.expand_path(path_str)
      else
        str = entry.to_s
        ids << str
        ids << File.expand_path(str)
      end
    end
    ids
  end

  # Collect the `job=` meta references recorded in one agent save file
  # that the forensic report has NOT captured and whose job is still
  # RUNNING.  This is the gap-2 reader: Agent#ask writes the immediate
  # `job=` meta and saves before `job.produce`, so while the chat task
  # runs the reference dangles in the save file, invisible both to the
  # `.jobs` sidecar (which never lists the agent's own ask dispatch) and
  # to the forensic traversal (whose result chat does not exist yet).
  #
  # `captured` is the set of job identities the forensic main report
  # already contains (Step, Path or String entries; matched by verbatim
  # reference and by resolved path).  Only `:running` jobs survive:
  # finished, crashed, unresolvable and already-captured references are
  # silently dropped, so the method never raises and never reports
  # concluded work.  Receipt-borne references (the `meta` arrays inside
  # function_call_output JSON) are deliberately NOT scanned here; they
  # belong to the forensic `:agent_job` relation and describe work whose
  # answer was already consumed.
  def self.dangling_agent_job_metas(path, captured: [])
    path = path.to_s
    captured_ids = live_captured_ids(captured)

    chat = begin
      Chat.load(path)
    rescue StandardError
      return []
    end

    references = begin
      chat.jobs
    rescue StandardError
      return []
    end

    references.collect do |reference|
      ref_str = reference.to_s
      next nil if ref_str.empty?
      next nil if captured_ids.include?(ref_str)

      step = begin
        load_live_job_reference(ref_str)
      rescue StandardError
        next nil
      end

      step_id = begin
        File.expand_path(step.path.to_s)
      rescue StandardError
        step.path.to_s
      end
      next nil if captured_ids.include?(step_id)

      state, status = begin
        classify_live_job(step)
      rescue StandardError
        next nil
      end
      next nil unless state == :running

      {
        kind: :dangling_job,
        agent_file: path,
        reference: ref_str,
        step: step,
        path: step.path.to_s,
        status: status,
        state: state
      }
    end.compact
  end

  # Live view of ONE agent save file: its trailing-message activity (the
  # Clean-type gap) plus its dangling `job=` metas reconciled to running
  # jobs (the Direct-type gap).  Returns a data-only Array, empty when
  # nothing is live.  Entry kinds:
  #
  #   :agent_activity -> {kind:, agent_file:, active: true, reason:,
  #                       last_role:, message_count:, rounds:}
  #   :dangling_job   -> {kind:, agent_file:, reference:, step:, path:,
  #                       status:, state:}
  #
  # An inactive agent contributes no activity entry, and a dangling
  # running job is reported on its own, so an agent mid-dispatch (file
  # ending in `meta: job=...`) yields the :dangling_job entry plus the
  # activity entry derived from its trailing conversational message.
  # Fail-soft everywhere: missing or malformed input yields [].
  def self.agent_view_live(save_file, captured: [])
    entries = []

    activity = agent_log_activity(save_file)
    entries << {kind: :agent_activity, agent_file: save_file.to_s}.merge(activity) if activity[:active]

    entries.concat(dangling_agent_job_metas(save_file, captured: captured))
    entries
  end

  # ------------------------------------------------------------------
  # Societal view: live state under <base>.society/
  # ------------------------------------------------------------------
  # Closes the third live gap: ask/hand_off delegation runs in NESTED
  # specialist conversations whose only on-disk trace while running is the
  # society tree written by Agent#save_society
  # (<society_dir>/<agent>/<conversation>/agent.chat, save.rb:239).  The
  # forensic traversal deliberately excludes society files
  # (direct_chat_sidecar_files), so a running delegation is invisible to
  # the main report until it completes and its receipt lands in the parent
  # chat.  Societal agents therefore have NO main chat to diff against:
  # they are reported whole (activity level), with the stronger dangling
  # `job=` detail added when the child is workflow-backed.

  # Conservative directory-depth cap for the society scan.  One nesting
  # level of society costs three directories (agent/conversation/society),
  # so 128 comfortably covers the agent layer's own SAVE_DEPTH_LIMIT of 32
  # while still bounding a pathological tree.
  SOCIETY_SCAN_DEPTH_LIMIT = 128

  # Society directory of the agent whose save file is `save_file`.
  #
  # Layout (mirrors LLM::Agent#society_dir, save.rb: the ROOT rule
  # <name>.chat -> <name>.society sibling, and the NESTED rule where a
  # chat already inside a society tree owns a plain `society` sibling, so
  # the tree nests instead of minting new `.files` trees):
  #
  #   <base>.files/<name>.chat                      -> <base>.files/<name>.society
  #   <base>.chat                                   -> <base>.society
  #   .../<agent>/<conversation>/agent.chat (nested) -> .../<agent>/<conversation>/society
  #
  # The derivation delegates to the agent class (LLM::Agent.society_dir_for
  # / LLM::Agent.nested_save?) so the two cannot drift; the literal mirror
  # below is the fallback when the agent layer is not loaded yet, because
  # chat/provenance is required before scout/llm/agent.  Returns nil only
  # when nothing can be derived (empty/nil input); a directory that does
  # not exist on disk is still returned, because existence is the scan's
  # concern, not the derivation's.
  def self.society_dir_of(save_file)
    path = save_file.to_s
    return nil if path.empty?

    if defined?(LLM::Agent)
      return File.join(File.dirname(path), LLM::Agent::SOCIETY_DIR) if LLM::Agent.nested_save?(path)
      return LLM::Agent.society_dir_for(path)
    end

    # Mirror of save.rb (keep in sync): nested chat -> sibling 'society';
    # root chat -> <name>.society sibling.
    parent = File.basename(File.dirname(File.dirname(File.dirname(path))))
    if parent == 'society' || parent.end_with?('.society')
      File.join(File.dirname(path), 'society')
    else
      p = path
      p = File.dirname(p) unless p =~ /\.chat\z/
      File.join(File.dirname(p), File.basename(p).sub(/\.chat\z/, '.society'))
    end
  end

  # Every saved specialist conversation under the society of `save_file`,
  # as a sorted Array of absolute agent.chat paths.  Silent [] when the
  # society directory is missing or unreadable.
  #
  # The scan is bounded and closed: it never follows symlinks (a link out
  # of the tree would report work that is not this agent's) and stops at
  # SOCIETY_SCAN_DEPTH_LIMIT directory levels.  Only files named
  # `agent.chat` (Agent::SOCIETY_CHAT_FILE, the sole name save_society
  # ever writes) are collected, so a renamed or foreign file is visible as
  # an omission rather than silently reinterpreted.
  def self.society_agent_chats(save_file)
    dir = society_dir_of(save_file)
    return [] if dir.nil? || !File.directory?(dir)

    chats = []
    scan = lambda do |directory, depth|
      return if depth > SOCIETY_SCAN_DEPTH_LIMIT

      entries = Dir.entries(directory)
      entries.each do |entry|
        next if entry == '.' || entry == '..'

        full = File.join(directory, entry)
        next if File.symlink?(full)

        if File.directory?(full)
          scan.call(full, depth + 1)
        elsif entry == 'agent.chat' && File.file?(full)
          chats << full
        end
      end
    rescue StandardError
      nil
    end

    scan.call(dir, 0)
    chats.sort
  end

  # Live view of every specialist conversation under the society of
  # `save_file`.  Data-only Array, empty when nothing is live.
  #
  # Per child (path shape <society>/<agent>/<conversation>/agent.chat, with
  # deeper societies nesting under <agent>/<conversation>/society):
  #
  #   {kind:, agent:, conversation:, path:, relative:, activity:,
  #    job:, job_path:, state:, dangling:}
  #
  # - kind is :dangling_job when the child is WORKFLOW-BACKED and holds a
  #   `job=` meta that resolves to a still-running job (the immediate
  #   dispatch meta written by Agent#ask before job.produce; the stronger
  #   signal, so it wins over activity when both hold), and
  #   :agent_activity otherwise.
  # - activity is always included (agent_log_activity of the child file):
  #   it is the ONLY signal for PLAIN (non-workflow) children, which
  #   dispatch through LLM.ask and never write a `job=` meta at all.
  # - A child is reported when it has a running dangling job OR an active
  #   activity classification; finished/idle children are silent.
  # - Dedup: job ids already in `captured` (the forensic main report's set,
  #   same matching as dangling_agent_job_metas) never produce a
  #   :dangling_job entry; a child whose only live job is captured and
  #   whose conversation has concluded is skipped entirely.
  #
  # Fail-soft: missing society dir, unreadable chats, malformed content and
  # unresolvable job references all degrade to silence, never a raise.
  def self.society_live(save_file, captured: [])
    dir = society_dir_of(save_file)
    return [] if dir.nil?

    prefix = Regexp.quote(dir) + '/'
    captured_ids = live_captured_ids(captured)

    society_agent_chats(save_file).collect do |child|
      activity = agent_log_activity(child)
      dangling = dangling_agent_job_metas(child, captured: captured)

      # Dedup against the main report: a child whose job reference is
      # already captured IS that job (a workflow-backed child's whole
      # current turn is its ask job), so an entry here would report the
      # same work twice.  Skip the child entirely; its conversation is
      # represented by the captured job in the forensic traversal.
      child_chat = begin
        Chat.load(child)
      rescue StandardError
        nil
      end
      next nil if child_chat && (child_chat.jobs || []).any? { |ref| captured_ids.include?(ref.to_s) }

      next nil if dangling.empty? && !activity[:active]

      relative = child.sub(/\A#{prefix}/, '')
      parts = relative.split(File::SEPARATOR)

      entry = {
        kind: dangling.any? ? :dangling_job : :agent_activity,
        agent: parts.first,
        conversation: parts[1],
        path: child,
        relative: relative,
        activity: activity
      }

      unless dangling.empty?
        first = dangling.first
        entry[:job] = first[:reference]
        entry[:job_path] = first[:path]
        entry[:state] = first[:state]
        entry[:dangling] = dangling
      end

      entry
    end.compact
  end

  def self.timestamp
    Time.now.utc.iso8601(3)
  end
end
