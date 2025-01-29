require 'scout'
require 'openai'
require_relative 'parse'

module LLM
  module OpenAI

    def self.ask(question, options = {})

      role, model, dig = IndiferentHash.process_options options, :role, :model, :dig,
        model: 'gpt-4o', dig: true

      key = Scout::Config.get(:key, :openai)
      client = Object::OpenAI::Client.new(access_token: key)

      messages = LLM.parse(question, role)

      parameters = options.merge(model: model, messages: messages)

      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
      response = client.chat(parameters: parameters)

      if dig
        response.dig("choices", 0, "message", "content")
      else
        response
      end
    end
  end
end
