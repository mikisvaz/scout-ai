require 'scout'
require_relative 'backends/openai'
require_relative 'backends/ollama'
require_relative 'backends/openwebui'
require_relative 'backends/relay'

module LLM
  def self.ask(question, options = {}, &block)
    backend = IndiferentHash.process_options options, :backend
    backend ||= Scout::Config.get :backend, :llm, :ask, env: 'ASK_BACKEND,LLM_BACKEND', default: :openai

    case backend
    when :openai, "openai"
      LLM::OpenAI.ask(question, options, &block)
    when :ollama, "ollama"
      LLM::OLlama.ask(question, options, &block)
    when :openwebui, "openwebui"
      LLM::OpenWebUI.ask(question, options, &block)
    when :relay, "relay"
      LLM::Relay.ask(question, options, &block)
    else
      raise "Unknown backend: #{backend}"
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
      knowledge_base.children(database, entities)
    end
  end
end
