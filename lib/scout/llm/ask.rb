require 'scout'
require_relative 'openai'
require_relative 'ollama'

module LLM
  def self.ask(...)
    backend = Scout::Config.get :backend, :llm, :ask, default: :openai
    case backend
    when :openai, "openai"
      LLM::OpenAI.ask(...)
    when :ollama, "ollama"
      LLM::OLlama.ask(...)
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

  def self.knowledgebase_ask(knowledgebase, question, options = {})
    knowledgebase_tools = LLM.knowledgebase_tool_definition(knowledgebase)
    self.ask(question, options.merge(tools: knowledgebase_tools)) do |task_name,parameters|
      parameters = IndiferentHash.setup(parameters)
      database, entities = parameters.values_at "database", "entities"
      knowledgebase.children(database, entities)
    end
  end
end
