require 'scout'

module LLM
  def self.embed(text, options = {})
    endpoint = IndiferentHash.process_options options, :endpoint
    endpoint ||= Scout::Config.get :endpoint, :embed, :llm, env: 'EMBED_ENDPOINT,LLM_ENDPOINT', default: :openai
    if endpoint && Scout.etc.AI[endpoint].exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    end

    backend = IndiferentHash.process_options options, :backend
    backend ||= Scout::Config.get :backend, :embed, :llm, env: 'EMBED_BACKEND,LLM_BACKEND', default: :openai

    case backend
    when :openai, "openai"
      require_relative 'backends/openai'
      LLM::OpenAI.embed(text, options)
    when :responses, "responses"
      require_relative 'backends/responses'
      LLM::OpenAI.embed(text, options)
    when :ollama, "ollama"
      require_relative 'backends/ollama'
      LLM::OLlama.embed(text, options)
    when :openwebui, "openwebui"
      require_relative 'backends/openwebui'
      LLM::OpenWebUI.embed(text, options)
    when :relay, "relay"
      require_relative 'backends/relay'
      LLM::Relay.embed(text, options)
    else
      raise "Unknown backend: #{backend}"
    end
  end
end
