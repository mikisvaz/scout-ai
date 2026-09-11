require 'scout'
require_relative 'chat'

module LLM

  BACKENDS = IndiferentHash.setup({})

  def self.register_backend(name, mod)
    BACKENDS[name] = mod
  end

  def self.ask(question, options = {}, &block)
    messages = LLM.chat(question)
    options = IndiferentHash.add_defaults options, LLM.options(messages)

    agent_name, agent_save_file  = IndiferentHash.process_options options, :agent, :agent_save_file
    agent_name = nil if %(none false nil).include?(agent_name.to_s)
    if agent_name
      agent = LLM::Agent.load_agent agent_name
      agent.save_file = agent_save_file if agent_save_file
      agent.follow messages
      res = agent.chat options
      return res
    end

    endpoint, persist = IndiferentHash.process_options options, :endpoint, :persist, persist: true

    # ScoutCoder: an EXPLICIT persist:false must survive the config merge.
    # `persist ||= config_lookup` is falsy for false, so an explicit opt-out
    # was silently discarded and the round persisted anyway — into the SHARED
    # Scout.var.cache.ask store. Only fill in from config when the caller said
    # nothing (nil). This is what makes test-level `persist: false` hermetic
    # and keeps unit tests out of the account-wide cache.
    persist = Scout::Config.get :persist, :ask, :llm, env: 'ASK_PERSIST,LLM_PERSIST,PERSIST' if persist.nil?
    endpoint ||= Scout::Config.get :endpoint, :ask, :llm, env: 'ASK_ENDPOINT,LLM_ENDPOINT,ENDPOINT,LLM,ASK'
    if endpoint && Scout.etc.AI[endpoint].find_with_extension(:yaml).exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    elsif endpoint && endpoint != ""
      raise "Endpoint not found #{endpoint}"
    end

    job_paths = messages.job_paths
    meta = Chat.meta(messages)
    options[:current_meta] = meta if meta and meta.any?

    if options[:backend].to_s == 'responses' && options[:previous_response].to_s != 'false'
      messages = Chat.clear(messages, 'previous_response_id')
    else
      messages = Chat.clean(messages, 'previous_response_id')
      options.delete :previous_response_id
    end

    tools = options[:tools]
    if tools
      # ScoutCoder: options[:tools] may be either the internal Hash shape
      # ({name => [obj, definition]}) or a plain Array of provider-style
      # definitions (as in the tests and InfrastructureProbes); only the
      # Hash shape has #keys, so fingerprint accordingly.
      tool_names = Hash === tools ? tools.keys : tools.collect { |t| t[:name] || t.dig(:function, :name) }

      Log.high Log.color(:green, "Asking #{endpoint || options[:endpoint] || 'client'}: #{options[:previous_response_id]}\n" + Chat.print_brief(messages))
      Log.medium "Tools: #{Log.fingerprint tool_names}" if tool_names&.any?
      Log.debug "#{Log.fingerprint tools}}"
    else
      Log.high Log.color :green, "Asking #{endpoint || options[:endpoint] || 'client'}: #{options[:previous_response_id]}\n" + Chat.print_brief(messages)
    end

    persist = false if persist.to_s.downcase == 'false'
    res = Persist.persist(endpoint, :json, prefix: "LLM ask", other: options.merge(messages: messages), persist: persist, dir: Scout.var.cache.ask) do
      backend = IndiferentHash.process_options options, :backend
      backend ||= Scout::Config.get :backend, :ask, :llm, env: 'ASK_BACKEND,LLM_BACKEND', default: :responses

      job_paths.each do |job_path|
        begin
          job = Step.load Path.setup(job_path)
          jobs = [job] + job.rec_dependencies.to_a
          jobs.each do |job|
            Chat.allow_read_job job
          end
        rescue
          Log.exception $!
          Log.warn "Could not load #{job_path}"
        end
      end

      case backend
      when :openai, "openai"
        require_relative 'backends/openai'
        LLM::OpenAI.ask(messages, options, &block)
      when :anthropic, "anthropic"
        require_relative 'backends/anthropic'
        LLM::Anthropic.ask(messages, options, &block)
      when :responses, "responses"
        require_relative 'backends/responses'
        LLM::Responses.ask(messages, options, &block)
      when :ollama, "ollama"
        require_relative 'backends/ollama'
        LLM::OLlama.ask(messages, options, &block)
      when :vllm, "vllm"
        require_relative 'backends/vllm'
        LLM::VLLM.ask(messages, options, &block)
      when :openwebui, "openwebui"
        require_relative 'backends/openwebui'
        LLM::OpenWebUI.ask(messages, options, &block)
      when :huggingface, "huggingface"
        require_relative 'backends/huggingface'
        LLM::Huggingface.ask(messages, options, &block)
      when :relay, "relay"
        require_relative 'backends/relay'
        LLM::Relay.ask(messages, options, &block)
      when :bedrock, "bedrock"
        require_relative 'backends/bedrock'
        LLM::Bedrock.ask(messages, options, &block)
      when :glm, "glm"
        require_relative 'backends/glm'
        LLM::GLM.ask(messages, options, &block)
      else
        mod = BACKENDS[backend]
        raise "Unknown backend: #{backend}" if mod.nil?
        mod.ask(messages, options, &block)
      end
    end

    Chat.setup res if Array === res

    Log.high Log.color :blue, "Response:\n" + Chat.print_brief(res, %w(meta assistant)) if Array === res

    res
  end

  def self.workflow_ask(workflow, question, options = {})
    workflow_tools = LLM.workflow_tools(workflow)
    self.ask(question, options.merge(tools: workflow_tools)) do |task_name,parameters|
      workflow.job(task_name, parameters).run
    end
  end

  def self.knowledge_base_ask(knowledge_base, question, options = {})
    knowledge_base_tools = LLM.knowledge_base_tool_definition(knowledge_base)
    self.ask(question, options.merge(tools: knowledge_base_tools)) do |task_name,parameters|
      parameters = IndiferentHash.setup(parameters)
      database, entities = parameters.values_at "database", "entities"
      Log.info "Finding #{entities} children in #{database}"
      knowledge_base.children(database, entities).collect{|e| e.sub('~', '=>')}
    end
  end
end
