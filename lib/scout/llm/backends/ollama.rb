require 'ollama-ai'
require_relative '../parse'
require_relative '../tools'

module LLM
  module OLlama
    def self.client(options)
      url = IndiferentHash.process_options options, :url


      url ||= Scout::Config.get(:url, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
      server = url.match(/(?:https?:\/\/)?([^\/:]*)/)[1] || "NOSERVER"

      key = Scout::Config.get(:key, :ollama, server, server.split(".").first)

      Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        },
        options: { stream: false, debug: true }
      )
    end

    def self.ask(question, options = {}, &block)

      client = self.client options

      role, mode, model = IndiferentHash.process_options options, :role, :mode, :model

      model ||= Scout::Config.get(:model, :ollama, env: 'OLLAMA_MODEL', default: "mistral")

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

      client = self.client options

      role, model = IndiferentHash.process_options options, :role, :model

      model ||= Scout::Config.get(:model, :ollama, env: 'OLLAMA_MODEL', default: "mistral")

      parameters = { input: text, model: model }
      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
      embeddings = client.request('api/embed', parameters)

      Array === text ? embeddings.first['embeddings'] : embeddings.first['embeddings'].first
    end
  end
end
