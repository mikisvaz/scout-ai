require 'scout'
require_relative 'chat'

module LLM
  def self.ask(question, options = {}, &block)
    messages = LLM.chat(question)
    options = IndiferentHash.add_defaults LLM.options(messages), options

    agent = IndiferentHash.process_options options, :agent

    if agent
      agent_file = Scout.workflows[agent]

      agent_file = Scout.chats[agent] unless agent_file.exists?

      agent_file = agent_file.find_with_extension('rb') unless agent_file.exists?


      if agent_file.exists?
        if agent_file.directory?
          if agent_file.agent.find_with_extension('rb').exists?
            agent = load agent_file.agent.find_with_extension('rb')
          else
            agent = LLM::Agent.load_from_path agent_file
          end
        else
          agent = load agent_file
        end
      else
        raise "Agent not found: #{agent}"
      end
      return agent.ask(question, options)
    end

    endpoint, persist = IndiferentHash.process_options options, :endpoint, :persist, persist: true

    endpoint ||= Scout::Config.get :endpoint, :ask, :llm, env: 'ASK_ENDPOINT,LLM_ENDPOINT'
    if endpoint && Scout.etc.AI[endpoint].exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    elsif endpoint && endpoint != ""
      raise "Endpoint not found #{endpoint}"
    end

    Log.high Log.color :green, "Asking #{endpoint || 'client'}:\n" + LLM.print(messages) 
    tools = options[:tools]
    Log.high "Tools: #{Log.fingerprint tools.keys}}" if tools

    res = Persist.persist(endpoint, :json, prefix: "LLM ask", other: options.merge(messages: messages), persist: persist) do
      backend = IndiferentHash.process_options options, :backend
      backend ||= Scout::Config.get :backend, :ask, :llm, env: 'ASK_BACKEND,LLM_BACKEND', default: :openai

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
      when :openwebui, "openwebui"
        require_relative 'backends/openwebui'
        LLM::OpenWebUI.ask(messages, options, &block)
      when :relay, "relay"
        require_relative 'backends/relay'
        LLM::Relay.ask(messages, options, &block)
      when :bedrock, "bedrock"
        require_relative 'backends/bedrock'
        LLM::Bedrock.ask(messages, options, &block)
      else
        raise "Unknown backend: #{backend}"
      end
    end

    Log.high Log.color :blue, "Response:\n" + LLM.print(res) 

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
