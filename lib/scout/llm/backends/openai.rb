require 'scout'
require 'openai'
require_relative '../parse'
require_relative '../tools'
require_relative '../utils'

module LLM
  module OpenAI

    def self.client(url, key, log_errors = false)
      Object::OpenAI::Client.new(access_token:key, log_errors: log_errors, uri_base: url)
    end

    def self.ask(question, options = {}, &block)

      client, url, key, model, log_errors = IndiferentHash.process_options options, :client, :url, :key, :model, :log_errors

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-3.5-turbo")
      end

      role = IndiferentHash.process_options options, :role

      messages = LLM.messages(question, role)

      parameters = options.merge(model: model, messages: messages)

      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

      response = client.chat(parameters: parameters)
      Log.debug "Respose: #{Log.fingerprint response}"
      message = response.dig("choices", 0, "message")
      tool_calls = response.dig("choices", 0, "tool_calls") ||
        response.dig("choices", 0, "message", "tool_calls")

      parameters.delete :tool_choice

      while tool_calls && tool_calls.any?
        messages << message

        cpus = Scout::Config.get :cpus, :tool_calling, default: 3
        tool_calls.each do |tool_call|
          response_message = LLM.tool_response(tool_call, &block)
          messages << response_message
        end

        parameters[:messages] = messages.compact
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
        response = client.chat( parameters: parameters)
        Log.debug "Respose: #{Log.fingerprint response}"

        message = response.dig("choices", 0, "message")
        tool_calls = response.dig("choices", 0, "tool_calls") ||
          response.dig("choices", 0, "message", "tool_calls")
      end

      message.dig("content")
    end

    def self.embed(text, options = {})

      client, url, key, model, log_errors = IndiferentHash.process_options options, :client, :url, :key, :model, :log_errors

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_embed, :embed, :openai, env: 'OPENAI_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_embed, :embed, :openai, env: 'OPENAI_MODEL', default: "gpt-3.5-turbo")
      end

      response = client.embeddings(parameters: {input: text, model: model})
      response.dig('data', 0, 'embedding')
    end
  end
end
