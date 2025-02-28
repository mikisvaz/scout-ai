require 'scout'
require 'openai'
require_relative '../parse'
require_relative '../tools'

module LLM
  module OpenAI

    def self.client(log_errors = false)
      key = Scout::Config.get(:key, :openai, env: 'OPENAI_API_KEY')
      Object::OpenAI::Client.new(access_token: key, log_errors: log_errors)
    end

    def self.ask(question, options = {}, &block)

      role, model, dig, client, log_errors = IndiferentHash.process_options options, :role, :model, :dig, :client, :log_errors,
        model: 'gpt-3.5-turbo', dig: true

      client ||= self.client(log_errors)

      messages = LLM.parse(question, role)

      parameters = options.merge(model: model, messages: messages)

      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

      response = client.chat(parameters: parameters)
      message = response.dig("choices", 0, "message")

      parameters.delete :tool_choice

      while message["role"] == "assistant" && message["tool_calls"]
        messages << message
        message["tool_calls"].each do |tool_call|
          response_message = LLM.tool_response(tool_call, &block)
          messages << response_message
        end

        parameters[:messages] = messages
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
        response = client.chat( parameters: parameters)

        message = response.dig("choices", 0, "message")
      end

      message.dig("content")
    end

    def self.embed(text, options = {})

      model, client, log_errors = IndiferentHash.process_options options, :model, :client, :log_errors,
        model: 'text-embedding-3-small'

      client ||= self.client(log_errors)

      response = client.embeddings(parameters: {input: text, model: model})
      response.dig('data', 0, 'embedding')
    end
  end
end
