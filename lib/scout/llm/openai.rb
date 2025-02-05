require 'scout'
require 'openai'
require_relative 'parse'
require_relative 'tools'

module LLM
	module OpenAI

		def self.ask(question, options = {}, &block)

			role, model, dig, client, log_errors = IndiferentHash.process_options options, :role, :model, :dig, :client, :log_errors,
				model: 'gpt-3.5-turbo', dig: true

      client ||= begin
                   key = Scout::Config.get(:key, :openai)
                   Object::OpenAI::Client.new(access_token: key, log_errors: log_errors)
                 end

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
  end
end
