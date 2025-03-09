require 'ollama-ai'
require_relative '../parse'
require_relative '../tools'
require_relative '../utils'

module LLM
  module OLlama
    def self.client(url, key = nil)
      Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        },
        options: { stream: false, debug: true }
      )
    end

    def self.ask(question, options = {}, &block)

      client, url, key, model = IndiferentHash.process_options options, :client, :url, :key, :model

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end

      mode  = IndiferentHash.process_options options, :mode

      messages = LLM.parse(question)

      system = []
      prompt = []
      messages.each do |message|
        role, content = message.values_at :role, :content
        if role == 'system'
          system << content
        else
          prompt << content
        end
      end

      case mode
      when :chat, 'chat'
        parameters = options.merge(model: model, messages: messages)
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

        response = client.chat(parameters)
        response.collect do |choice|
          message=choice['message']
          while message["role"] == "assistant" && message["tool_calls"]
            messages << message

            message["tool_calls"].each do |tool_call|
              response_message = LLM.tool_response(tool_call, &block)
              messages << response_message
            end

            parameters[:messages] = messages
            Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
            response = client.chat(parameters)

            message = response[0]['message']
          end

          message["content"]
        end * ""
      else
        parameters = options.merge(model: model, prompt: prompt * "\n", system: system*"\n")
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
        response = client.generate(parameters)
        response.collect{|e| e['response']} * ""
      end
    end

    def self.embed(text, options = {})

      client, url, key, model = IndiferentHash.process_options options, :client, :url, :key, :model

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end

      parameters = { input: text, model: model }
      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
      embeddings = client.request('api/embed', parameters)

      Array === text ? embeddings.first['embeddings'] : embeddings.first['embeddings'].first
    end
  end
end
