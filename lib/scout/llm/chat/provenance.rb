require 'set'
require 'time'

module Chat
  PROVENANCE_RELATIONS = %i[job dependency log result agent_job].freeze
  DIRECT_LOG_CHAT_GLOBS = ['*.chat', '*.society/**/*.chat'].freeze
  PROVENANCE_CACHE_KEY = :scout_ai_provenance_run_cache

  # A cache lives for one top-level operation only. Nested operations reuse it.
  def self.with_provenance_run_cache
    previous = Thread.current[PROVENANCE_CACHE_KEY]
    Thread.current[PROVENANCE_CACHE_KEY] ||= {}
    yield
  ensure
    Thread.current[PROVENANCE_CACHE_KEY] = previous
  end

  # Prefer the block form (with_provenance_run_cache) whenever a scope is
  # expressible as a block.  The manual pair exists for callers that must
  # hold the cache across separate operations, like the `llm prov` CLI,
  # which opens it once and traverses several roots under it.
  def self.open_provenance_run_cache
    Thread.current[PROVENANCE_CACHE_KEY] ||= {}
  end

  def self.close_provenance_run_cache
    Thread.current[PROVENANCE_CACHE_KEY] = nil
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

  def self.provenance_chat_load(path)
    cache = Thread.current[PROVENANCE_CACHE_KEY]
    return Chat.load(path) unless cache
    cache[provenance_path(:chat, path)] ||= Chat.load(path)
  end

  def self.direct_log_chat_files(files_dir)
    return [] unless File.directory?(files_dir.to_s)

    DIRECT_LOG_CHAT_GLOBS.flat_map do |pattern|
      Dir.glob(File.join(files_dir.to_s, pattern))
    end.map { |file| File.expand_path(file) }
      .select { |file| File.file?(file) }
      .uniq.sort.map { |file| Path.setup(file) }
  end

  def self.direct_job_chat_files(job)
    job = Step.load(job) unless Step === job
    direct_log_chat_files(job.files_dir)
  end

  # A chat's top-level .files/*.chat transcript is included unless it is a
  # byte-identical copy of the root chat. Society descendants are independent.
  def self.direct_chat_sidecar_files(path)
    files_dir = path.to_s + '.files'
    return [] unless File.directory?(files_dir)

    top_level = Dir.glob(File.join(files_dir, '*.chat')).map { |f| File.expand_path(f) }.to_set
    root_path = File.expand_path(path.to_s)
    root_content = File.file?(root_path) ? Open.read(root_path) : nil

    direct_log_chat_files(files_dir).reject do |file|
      top_level.include?(file.to_s) && root_content &&
        File.file?(file.to_s) && Open.read(file.to_s) == root_content
    end
  end

  def self.job_result_chat_file(job)
    job = Step.load(job) unless Step === job
    return unless job.type.to_s == 'chat' && File.file?(job.path.to_s)
    Path.setup(File.expand_path(job.path.to_s))
  end

  def self.job_reference_fallback_bases
    ['~/.rbbt/var/jobs', Scout.var.jobs.find.to_s].map { |base| File.expand_path(base) }
  end

  def self.job_reference_candidate?(path)
    File.exist?(path.to_s) || File.exist?(path.to_s + '.info')
  end

  def self.load_job_reference(reference)
    return reference if Step === reference
    ref = reference.to_s
    step = Step.load(ref)
    return step if job_reference_candidate?(step.path)

    job_reference_fallback_bases.each do |base|
      candidate = File.join(base, ref)
      return Step.load(candidate) if job_reference_candidate?(candidate)
    end
    step
  end

  def self.resolve_job_reference(reference)
    step = load_job_reference(reference)
    job_reference_candidate?(step.path) ? [step, nil] : [nil, step]
  end

  def self.provenance_error(on_error, error, kind, object, relation, reference)
    raise error unless on_error
    on_error.call(error, kind, object, relation, reference)
  end

  def self.report_agent_meta_problems(chat, object, on_error = nil)
    warnings = []
    references = agent_meta_job_references(chat, source: object, warnings: warnings)
    warnings.each do |warning|
      error = ScoutException.new(
        agent_meta_error_message(warning[:reason],
          chat_path: object.to_s, output_address: warning[:output_address],
          call_id: warning[:call_id], tool_name: warning[:tool_name],
          reference: warning[:reference] || warning[:raw_entry])
      )
      detail = agent_meta_error_reference(
        reason: warning[:reason], source: warning[:source] || object.to_s,
        output_address: warning[:output_address], evidence_address: warning[:evidence_address],
        call_id: warning[:call_id], tool_name: warning[:tool_name],
        agent_meta_index: warning[:agent_meta_index], raw_entry: warning[:raw_entry],
        reference: warning[:reference])
      provenance_error(on_error, error, :chat, object, :agent_job, detail)
    end
    references
  end

  # ADVANCED entry point: breadth-first graph traversal for callers that
  # need manual control (streaming edges, custom first-visit handling).
  # Prefer provenance_graph (single-node index) or provenance_closure
  # (recursive closure) for inspection.  Every edge is yielded, including
  # edges to previously visited nodes; only first visits expand. Chat and
  # job identities remain distinct even when a chat-producing job and its
  # result share a path.
  def self.traverse_provenance(root, root_type: nil, follow: :all, on_error: nil, &block)
    return enum_for(__method__, root, root_type: root_type, follow: follow, on_error: on_error) unless block
    unless Thread.current[PROVENANCE_CACHE_KEY]
      return with_provenance_run_cache do
        traverse_provenance(root, root_type: root_type, follow: follow, on_error: on_error, &block)
      end
    end

    relations = follow == :all ? PROVENANCE_RELATIONS : Array(follow).map(&:to_sym).uniq
    unknown = relations - PROVENANCE_RELATIONS
    raise ParameterException, "Unknown provenance relations: #{unknown.join(', ')}" unless unknown.empty?

    root_kind = (root_type || (Step === root ? :job : :chat)).to_sym
    raise ParameterException, "Unknown provenance root type: #{root_kind}" unless %i[chat job].include?(root_kind)
    root_object = if root_kind == :job
                    Step === root ? root : Step.load(root)
                  else
                    path = File.expand_path(root.to_s)
                    raise ParameterException, "Chat not found: #{root}" unless File.file?(path)
                    Path.setup(path)
                  end

    queue = [[root_kind, root_object, nil, nil, nil, nil]]
    seen = Set.new
    cursor = 0
    wants_detail = block.arity == -1 || block.arity >= 7 ||
                   block.parameters.any? { |kind, _name| kind == :rest }

    while cursor < queue.length
      kind, object, parent_kind, parent, relation, detail = queue[cursor]
      cursor += 1
      key = provenance_key(kind, object)
      first = !seen.include?(key)
      args = [kind, object, parent_kind, parent, relation, first]
      args << detail if wants_detail
      block.call(*args)
      next unless first
      seen << key

      begin
        if kind == :chat
          chat = provenance_chat_load(object)
          if relations.include?(:job)
            chat.jobs.each do |reference|
              begin
                queue << [:job, load_job_reference(reference), :chat, object, :job, nil]
              rescue StandardError => error
                provenance_error(on_error, error, :chat, object, :job, reference)
              end
            end
          end

          if relations.include?(:agent_job)
            records = begin
              report_agent_meta_problems(chat, object, on_error)
            rescue StandardError => error
              provenance_error(on_error, error, :chat, object, :agent_job, object)
              []
            end
            records.each do |record|
              reference = record[:job]
              begin
                job, = resolve_job_reference(reference)
                if job
                  queue << [:job, job, :chat, object, :agent_job, record]
                else
                  error = ScoutException.new(agent_meta_error_message(
                    :unresolved_job_reference, chat_path: object.to_s,
                    output_address: record[:output_address], call_id: record[:call_id],
                    tool_name: record[:tool_name], reference: reference))
                  detail = agent_meta_error_reference(
                    reason: :unresolved_job_reference, source: object.to_s,
                    output_address: record[:output_address], evidence_address: record[:evidence_address],
                    call_id: record[:call_id], tool_name: record[:tool_name], reference: reference)
                  provenance_error(on_error, error, :chat, object, :agent_job, detail)
                end
              rescue StandardError => error
                detail = agent_meta_error_reference(
                  reason: :unresolved_job_reference, source: object.to_s,
                  reference: reference, call_id: record[:call_id], tool_name: record[:tool_name])
                provenance_error(on_error, error, :chat, object, :agent_job, detail)
              end
            end
          end

          if relations.include?(:log)
            direct_chat_sidecar_files(object).each do |file|
              queue << [:chat, file, :chat, object, :log, nil]
            end
          end
        else
          if relations.include?(:dependency)
            object.dependencies.each do |dependency|
              queue << [:job, dependency, :job, object, :dependency, nil]
            end
          end
          if relations.include?(:log)
            direct_job_chat_files(object).each do |file|
              queue << [:chat, file, :job, object, :log, nil]
            end
          end
          if relations.include?(:result) && (file = job_result_chat_file(object))
            queue << [:chat, file, :job, object, :result, nil]
          end
        end
      rescue StandardError => error
        provenance_error(on_error, error, kind, object, relation, object)
      end
    end
    nil
  end

  # COMPACT INDEX entry point: the immediate provenance of ONE chat or job
  # as lightweight data (strings, symbols, integers, arrays, hashes).
  #
  #   Chat.provenance_graph(chat_file)  # =>
  #   { type: :chat,
  #     chats: { 3 => 'Planned/work/Default_agdfg' },
  #     dependencies: [],
  #     delegation: { 5 => 'Workspace#default' },
  #     live: ['<abs>/session.chat.files/agent.chat'],
  #     warnings: [] }
  #
  # `chats` maps persisted message indexes (zero-based array positions) to
  # RESOLVED canonical absolute job paths, from BOTH a standalone
  # `meta: job=` message and a job reference lifted from an agent_meta
  # receipt inside a function_call_output envelope (anchored at the OUTER
  # output message index).  `dependencies` is the job's direct
  # Step#dependencies canonical paths, declared order, chat roots always
  # empty.  Both are directly usable with Step.load; short metadata
  # spellings and short_path values are never returned.  `delegation` maps the
  # index of an `ask` tool call message to '<agent>#<conversation>'.  `live`
  # lists supplementary sidecar chat paths (including a byte-identical
  # top-level copy); these are mutable work in flight, NOT authoritative
  # provenance nodes: nothing in them is loaded or followed here.  Callers
  # recurse by feeding any returned reference back in as the next root.
  # There is no `follow` option and no recursion: one node per call.
  def self.provenance_graph(root, root_type: nil, on_error: :collect)
    warnings = []
    report = lambda do |error, kind, object, relation, reference|
      warnings << provenance_warning(error, kind, object, relation, reference)
    end
    callback = on_error == :raise ? nil : (report if on_error == :collect)
    callback = lambda do |*args|
      report.call(*args)
      on_error.call(*args)
    end if callback.nil? && on_error.respond_to?(:call)

    root_kind = (root_type || (Step === root ? :job : :chat)).to_sym
    raise ParameterException, "Unknown provenance root type: #{root_kind}" unless %i[chat job].include?(root_kind)
    job = nil
    chat_path = nil
    if root_kind == :job
      job = Step === root ? root : Step.load(root)
    else
      chat_path = File.expand_path(root.to_s)
      raise ParameterException, "Chat not found: #{root}" unless File.file?(chat_path)
    end

    chats = {}
    delegation = {}
    receipt_warnings = []

    # The output chat is the transcript this node's own messages live in.
    # A chat root IS that transcript; a job root contributes one only when
    # the job is chat-producing and its result exists.  A job's input chat
    # is invocation context, never generated output, and is never read.
    transcript = chat_path || (job_result_chat_file(job) && job_result_chat_file(job).to_s)
    if transcript
      chat = provenance_chat_load(transcript)

      # Standalone meta: job= messages, anchored at their own message index.
      # Every value is the RESOLVED job's canonical absolute path, so the
      # reference is directly usable with Step.load; the original metadata
      # spelling (often a short path) is intentionally discarded.
      chat.each_with_index do |message, index|
        next unless message[:role].to_s == 'meta'
        job_ref = Chat.parse_meta(message[:content].to_s)[:job]
        next unless job_ref
        begin
          job_step, = resolve_job_reference(job_ref)
          if job_step
            add_indexed_reference(chats, index, provenance_path(:job, job_step))
          else
            provenance_error(callback, ScoutException.new(agent_meta_error_message(
              :unresolved_job_reference, chat_path: transcript, output_address: index,
              reference: job_ref)), :chat, transcript, :job, job_ref)
          end
        rescue StandardError => error
          provenance_error(callback, error, :chat, transcript, :job, job_ref)
        end
      end

      # agent_meta receipts: job references lifted from function_call_output
      # envelopes, anchored at the outer output message index.  Malformed
      # receipts follow the on_error policy; unresolved references are
      # reported, never silently dropped.
      begin
        records = agent_meta_job_references(chat, source: transcript, warnings: receipt_warnings)
      rescue StandardError => error
        provenance_error(callback, error, :chat, transcript, :agent_job, transcript)
        records = []
      end
      records.each do |record|
        reference = record[:job]
        index = Array === record[:output_address] ? record[:output_address].last : record[:output_address]
        begin
          job_step, = resolve_job_reference(reference)
          unless job_step
            provenance_error(callback, ScoutException.new(agent_meta_error_message(
              :unresolved_job_reference, chat_path: transcript,
              output_address: record[:output_address], call_id: record[:call_id],
              tool_name: record[:tool_name], reference: reference)), :chat, transcript, :agent_job, reference)
            next
          end
          add_indexed_reference(chats, index, provenance_path(:job, job_step))
        rescue StandardError => error
          provenance_error(callback, error, :chat, transcript, :agent_job, reference)
        end
      end

      # Actual ask calls only: an ask that produced no job= receipt is a
      # delegation relationship, not an inference-job one.
      begin
        tool_calls(chat).each do |call|
          next unless call[:name] == 'ask'
          arguments = call[:arguments]
          arguments = Chat.parse_json(arguments) if String === arguments
          next unless Hash === arguments && arguments['agent']
          agent = arguments['agent'].to_s
          conversation = arguments['conversation']
          conversation = 'default' if conversation.nil? || conversation.to_s.empty?
          add_indexed_reference(delegation, call[:call_index], "#{agent}##{conversation}")
        end
      rescue StandardError => error
        provenance_error(callback, error, :chat, transcript, :ask, transcript)
      end
    end
    receipt_warnings.each { |warning| warnings << {kind: :agent_meta, warning: warning} }

    # Direct dependencies as canonical absolute paths (realpath when
    # available), declared order preserved, directly loadable by Step.load.
    dependencies = []
    if job
      begin
        dependencies = job.dependencies.collect { |dependency| provenance_path(:job, dependency) }
      rescue StandardError => error
        provenance_error(callback, error, :job, job, :dependency, job)
      end
    end

    live = begin
      files_dir = root_kind == :job ? job.files_dir : chat_path + '.files'
      direct_log_chat_files(files_dir).collect(&:to_s)
    rescue StandardError => error
      provenance_error(callback, error, root_kind, root, :log, files_dir)
      []
    end

    {type: root_kind, chats: chats, dependencies: dependencies,
     delegation: delegation, live: live, warnings: warnings}
  end

  # Add +value+ at integer +index+, keeping an existing scalar distinct from
  # later values at the same index (both forms are then an Array).
  def self.add_indexed_reference(map, index, value)
    return unless Integer === index
    current = map[index]
    if current.nil?
      map[index] = value
    elsif current != value
      map[index] = Array === current ? (current.include?(value) ? current : current + [value]) : [current, value]
    end
  end

  # RECURSIVE closure entry point: one-pass materialized object graph over
  # the whole provenance tree, for collectors and cross-chat analysis.  The
  # default collects traversal errors in `warnings`; pass a callback to
  # receive them as well, or `on_error: :raise` for strict behavior.
  def self.provenance_closure(root, root_type: nil, follow: :all, on_error: :collect)
    warnings = []
    callback = if on_error == :raise
                 nil
               elsif on_error.respond_to?(:call)
                 lambda do |error, kind, object, relation, reference|
                   warnings << provenance_warning(error, kind, object, relation, reference)
                   on_error.call(error, kind, object, relation, reference)
                 end
               else
                 lambda do |error, kind, object, relation, reference|
                   warnings << provenance_warning(error, kind, object, relation, reference)
                 end
               end

    chats, jobs, edges, edge_keys = {}, {}, [], Set.new
    resolved_kind = (root_type || (Step === root ? :job : :chat)).to_sym
    resolved_root = if resolved_kind == :job
                      Step === root ? root : Step.load(root)
                    else
                      path = File.expand_path(root.to_s)
                      raise ParameterException, "Chat not found: #{root}" unless File.file?(path)
                      Path.setup(path)
                    end

    traverse_provenance(resolved_root, root_type: resolved_kind, follow: follow, on_error: callback) do |kind, object, parent_kind, parent, relation, first, detail|
      if first
        path = provenance_path(kind, object)
        (kind == :chat ? chats : jobs)[path] ||= (kind == :chat ? provenance_chat_load(object) : object)
      end
      next unless parent

      from = provenance_path(parent_kind, parent)
      to = provenance_path(kind, object)
      identity = [parent_kind, from, relation, kind, to]
      identity << (detail && detail[:evidence_address]) if relation == :agent_job
      next unless edge_keys.add?(identity)

      edges << {from_kind: parent_kind, from: parent, relation: relation,
                to_kind: kind, to: object, detail: detail}
    end

    {root_kind: resolved_kind, root: resolved_root, chats: chats,
     jobs: jobs, edges: edges, warnings: warnings}
  end

  def self.provenance_warning(error, kind, object, relation, reference)
    {kind: kind, path: provenance_path(kind, object), relation: relation,
     reference: reference, error: error.message}
  end

  # Compatibility collectors. They expose the recursive closure; prefer
  # provenance_graph for one node's immediate provenance.
  def self.provenance_edges(root, on_error: :raise, **options)
    provenance_closure(root, on_error: on_error, **options)[:edges]
  end

  def self.provenance_chat_files(root, on_error: :raise, **options)
    provenance_closure(root, on_error: on_error, **options)[:chats].keys
  end

  def self.provenance_jobs(root, on_error: :raise, **options)
    provenance_closure(root, on_error: on_error, **options)[:jobs].values
  end

  # Former chat-to-chat collector retained for existing callers.
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
end

require_relative 'provenance/tokens'
require_relative 'provenance/live'
