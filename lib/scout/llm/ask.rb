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
end
