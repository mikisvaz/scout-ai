require 'ollama-ai'
require_relative '../parse'
require_relative '../tools'

module LLM
  module OLlama
    def self.ask(question, options = {}, &block)

      role, model, url, mode = IndiferentHash.process_options options, :role, :model, :url, :mode,
        model: 'mistral', mode: 'chat'
      
      url ||= Scout::Config.get(:url, :ollama, default: "http://localhost:11434")

      server = url.match(/https?:\/\/([^\/:]*)/)[1] || "NOSERVER"

      key = Scout::Config.get(:key, :ollama, server, server.split(".").first)
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

      client = Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        },
        system: system * "\n",
        options: { stream: false, debug: true }
      )

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
  end
end
