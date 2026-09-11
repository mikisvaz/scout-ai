require 'scout'

module LLM
  def self.embed(text, options = {})
    # ScoutCoder: bug M4. The lookup used the extensionless
    # `Scout.etc.AI[endpoint].exists?`, so a standard
    # `etc/AI/<endpoint>.yaml` was NEVER merged — unlike ask.rb / image.rb,
    # which use `find_with_extension(:yaml)`. A missing endpoint also fell
    # through to the config defaults silently. ask/image raise in that case;
    # here the raise is scoped to endpoints that were actually requested
    # (options / env / config), because the `:embed` name below is a
    # synthesized fallback, not a user choice — raising on it would break
    # every backend-configured embed call.
    explicit_endpoint = IndiferentHash.process_options options, :endpoint
    explicit_endpoint ||= Scout::Config.get :endpoint, :embed, :llm, env: 'EMBED_ENDPOINT,LLM_ENDPOINT'
    endpoint = explicit_endpoint || :embed
    if endpoint && Scout.etc.AI[endpoint].find_with_extension(:yaml).exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    elsif explicit_endpoint && explicit_endpoint != ""
      raise "Endpoint not found #{explicit_endpoint}"
    end

    backend = IndiferentHash.process_options options, :backend
    backend ||= Scout::Config.get :backend, :embed, :llm, env: 'EMBED_BACKEND,LLM_BACKEND', default: :embed

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
    when :huggingface, "huggingface"
      require_relative 'backends/huggingface'
      LLM::Huggingface.embed(text, options)
    when :relay, "relay"
      require_relative 'backends/relay'
      LLM::Relay.embed(text, options)
    else
      # Fall back to the runtime backend registry (mirrors LLM.ask) so
      # test-only or plugin backends registered with LLM.register_backend
      # work for embeddings too, instead of only for ask.
      mod = LLM::BACKENDS[backend]
      raise "Unknown backend: #{backend}" if mod.nil?
      mod.embed(text, options)
    end
  end
end
