require 'scout'
require_relative 'backends/openai'
require_relative 'backends/ollama'
require_relative 'backends/openwebui'
require_relative 'backends/bedrock'
require_relative 'backends/relay'

module LLM
  def self.ask(question, options = {}, &block)
    messages = LLM.chat(question)
    options = options.merge LLM.options messages

    endpoint, persist = IndiferentHash.process_options options, :endpoint, :persist, persist: true

    endpoint ||= Scout::Config.get :endpoint, :ask, :llm, env: 'ASK_ENDPOINT,LLM_ENDPOINT'
    if endpoint && Scout.etc.AI[endpoint].exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    end

    Persist.persist(endpoint, :json, prefix: "LLM ask", other: options.merge(messages: messages), persist: persist) do
      Log.low "Asking #{endpoint}: "  + LLM.print(question)

      backend = IndiferentHash.process_options options, :backend
      backend ||= Scout::Config.get :backend, :ask, :llm, env: 'ASK_BACKEND,LLM_BACKEND', default: :openai

      case backend
      when :openai, "openai"
        LLM::OpenAI.ask(messages, options, &block)
      when :ollama, "ollama"
        LLM::OLlama.ask(messages, options, &block)
      when :openwebui, "openwebui"
        LLM::OpenWebUI.ask(messages, options, &block)
      when :relay, "relay"
        LLM::Relay.ask(messages, options, &block)
      when :bedrock, "bedrock"
        LLM::Bedrock.ask(messages, options, &block)
      else
        raise "Unknown backend: #{backend}"
      end
    end
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
