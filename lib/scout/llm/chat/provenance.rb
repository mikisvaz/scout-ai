require 'set'

module Chat
  PROVENANCE_RELATIONS = %i[job dependency log result].freeze

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
  # chat -> producer job (:job), job -> dependency (:dependency), job -> log
  # chat (:log), and job -> result chat (:result).
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
                job = Step === reference ? reference : Step.load(reference)
                queue << [:job, job, :chat, object, :job]
              rescue StandardError => error
                provenance_error(on_error, error, :chat, object, :job, reference)
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

  def self.tokens(root, **options)
    chats = provenance_chat_files(root, **options).collect { |file| Chat.load(file) }
    Chat.token_totals(chats)
  end
end
