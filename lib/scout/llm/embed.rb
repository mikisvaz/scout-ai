require 'scout'
require_relative 'backends/ollama'
require_relative 'backends/openai'
require_relative 'backends/openwebui'
require_relative 'backends/relay'

module LLM
  def self.embed(text, options = {})
    backend = IndiferentHash.process_options options, :backend
    backend ||= Scout::Config.get :backend, :llm, :ask, env: 'EMBED_BACKEND,LLM_BACKEND', default: :openai
    case backend
    when :openai, "openai"
      LLM::OpenAI.embed(text, options)
    when :ollama, "ollama"
      LLM::OLlama.embed(text, options)
    when :openwebui, "openwebui"
      LLM::OpenWebUI.embed(text, options)
    when :relay, "relay"
      LLM::Relay.embed(text, options)
    else
      raise "Unknown backend: #{backend}"
    end
  end
end
