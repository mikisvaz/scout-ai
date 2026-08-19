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

  # Provenance token aggregate: sum over all reachable chats (deduplicated by
  # provenance_chat_files).
  def self.tokens(root, **options)
    chats = provenance_chat_files(root, **options).collect { |file| Chat.load(file) }
    Chat.token_totals(chats)
  end

  def self.timestamp
    Time.now.utc.iso8601(3)
  end
end
