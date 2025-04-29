require 'scout'
require 'openai'
require 'rest-client'
require_relative '../parse'
require_relative '../tools'
require_relative '../utils'

module LLM
  module OpenWebUI

    def self.rest(method, base_url, key, action, options = {})
      url = File.join(base_url, action.to_s)
      headers = {"Authorization" => "Bearer #{key}", "Content-Type" => "application/json"}
      response = case method.to_sym
                 when :post
                   #RestClient.send(method, url, options, {content_type: "application/json", accept: "application/json", Authorization: "Bearer #{key}"})
                   iii [url, options, headers]
                   RestClient.post(url, options.to_json, headers)
                 else
                   RestClient.send(method, url, {content_type: "application/json", accept: "application/json", "Authorization" => "Bearer #{key}"})
                 end
      JSON.parse(response.body)
    end

    def self.ask(question, options = {}, &block)

      url, key, model, log_errors = IndiferentHash.process_options options, :url, :key, :model, :log_errors

      url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENWEBUI_URL', default: "http://localhost:3000/api")
      key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENWEBUI_KEY')
      model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENWEBUI_MODEL')

      role = IndiferentHash.process_options options, :role
      messages = LLM.messages(question, role)

      parameters = options.merge(model: model, messages: messages)

      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

      response = self.rest(:post, url, key, "chat/completions" , parameters)

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
