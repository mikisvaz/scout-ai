module LLM

  def self.image(question, options = {}, &block)
    messages = LLM.chat(question)
    options = IndiferentHash.add_defaults LLM.options(messages), options

    endpoint, persist = IndiferentHash.process_options options, :endpoint, :persist, persist: true

    endpoint ||= Scout::Config.get :endpoint, :image, :ask, :llm, env: 'IMAGE_ENDPOINT,ASK_ENDPOINT,LLM_ENDPOINT,ENDPOINT,LLM,ASK,IMAGE'
    if endpoint && Scout.etc.AI[endpoint].find_with_extension(:yaml).exists?
      options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
    elsif endpoint && endpoint != ""
      raise "Endpoint not found #{endpoint}"
    end

    agent_name = IndiferentHash.process_options options, :agent
    agent_name = nil if %(none false nil).include?(agent_name.to_s)
    if agent_name
      options[:endpoint] ||= endpoint
      agent = LLM::Agent.load_agent agent_name
      agent.follow messages
      res = agent.ask options
      return res
    end

    meta = Chat.meta(messages)
    options[:current_meta] = meta if meta and meta.any?

    if options[:backend].to_s == 'responses' && options[:previous_response].to_s != 'false'
      messages = Chat.clear(messages, 'previous_response_id')
    else
      messages = Chat.clean(messages, 'previous_response_id')
      options.delete :previous_response_id
    end

    Log.high Log.color :green, "Asking #{endpoint || options[:endpoint] || 'client'}: #{options[:previous_response_id]}\n" + Chat.print_brief(messages)
    tools = options[:tools]
    Log.medium "Tools: #{Log.fingerprint tools.keys}" if tools
    Log.debug "#{Log.fingerprint tools}}" if tools

    res = Persist.persist(endpoint, :json, prefix: "LLM image", other: options.merge(messages: messages), persist: persist, dir: Scout.var.cache.ask) do
      backend = IndiferentHash.process_options options, :backend
      backend ||= Scout::Config.get :backend, :ask, :llm, env: 'ASK_BACKEND,LLM_BACKEND', default: :responses

      case backend
      when :openai, "openai"
        require_relative 'backends/openai'
        LLM::OpenAI.image(messages, options, &block)
      when :anthropic, "anthropic"
        require_relative 'backends/anthropic'
        LLM::Anthropic.image(messages, options, &block)
      when :responses, "responses"
        require_relative 'backends/responses'
        LLM::Responses.image(messages, options, &block)
      when :ollama, "ollama"
        require_relative 'backends/ollama'
        LLM::OLlama.image(messages, options, &block)
      when :vllm, "vllm"
        require_relative 'backends/vllm'
        LLM::VLLM.image(messages, options, &block)
      when :openwebui, "openwebui"
        require_relative 'backends/openwebui'
        LLM::OpenWebUI.image(messages, options, &block)
      when :huggingface, "huggingface"
        require_relative 'backends/huggingface'
        LLM::Huggingface.image(messages, options, &block)
      when :relay, "relay"
        require_relative 'backends/relay'
        LLM::Relay.image(messages, options, &block)
      when :bedrock, "bedrock"
        require_relative 'backends/bedrock'
        LLM::Bedrock.image(messages, options, &block)
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
end
