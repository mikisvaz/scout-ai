require 'openai'
require 'rest-client'
require_relative '../chat'
require_relative 'openai'

module LLM
  module OpenWebUI

    def self.rest(method, base_url, key, action, options = {})
      url = File.join(base_url, action.to_s)
      headers = IndiferentHash.setup({"Authorization" => "Bearer #{key}", "Content-Type" => "application/json"})
      response = case method.to_sym
                 when :post
                   #RestClient.send(method, url, options, {content_type: "application/json", accept: "application/json", Authorization: "Bearer #{key}"})
                   RestClient.post(url, options.to_json, headers)
                 else
                   RestClient.send(method, url, {content_type: "application/json", accept: "application/json", "Authorization" => "Bearer #{key}"})
                 end

      JSON.parse(response.body)
    end

    def self.ask(question, options = {}, &block)

      url, key, model, log_errors = IndiferentHash.process_options options, :url, :key, :model, :log_errors

      url ||= Scout::Config.get(:url, :openwebui_ask, :ask, :openwebui, env: 'OPENWEBUI_URL', default: "http://localhost:3000/api")
      key ||= LLM.get_url_config(:key, url, :openwebui_ask, :ask, :openwebui, env: 'OPENWEBUI_KEY')
      model ||= LLM.get_url_config(:model, url, :openwebui_ask, :ask, :openwebui, env: 'OPENWEBUI_MODEL')

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

  def self.ask(question, options = {}, &block)
    original_options = options.dup

    messages = LLM.chat(question)
    options = options.merge LLM.options messages

    client, url, key, model, log_errors, return_messages, format, tool_choice_next, previous_response_id, tools, = IndiferentHash.process_options options,
      :client, :url, :key, :model, :log_errors, :return_messages, :format, :tool_choice_next, :previous_response_id, :tools,
      log_errors: true, tool_choice_next: :none

    if client.nil?
      url ||= Scout::Config.get(:url, :openwebui_ask, :ask, :openwebui, env: 'OPENWEBUI_URL', default: "http://localhost:3000/api")
      key ||= LLM.get_url_config(:key, url, :openwebui_ask, :ask, :openwebui, env: 'OPENWEBUI_KEY')
    end

    if model.nil?
      url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
      model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-4.1")
    end

    case format
    when Hash
      options[:response_format] = format
    when 'json', 'json_object', :json, :json_object
      options[:response_format] = {type: 'json_object'}
    else
      options[:response_format] = {type: format}
    end if format

    parameters = options.merge(model: model)

    # Process tools

    case tools
    when Array
      tools = tools.inject({}) do |acc,definition|
        IndiferentHash.setup definition
        name = definition.dig('name') || definition.dig('function', 'name')
        acc.merge(name => definition)
      end
    when nil
      tools = {}
    end

    tools.merge!(LLM.tools messages)
    tools.merge!(LLM.associations messages)

    if tools.any?
      parameters[:tools] = LLM::OpenAI.tool_definitions_to_openai tools
    end

    messages = LLM::OpenAI.process_input messages

    Log.debug "Calling openai #{url}: #{Log.fingerprint(parameters.except(:tools))}}"
    Log.high "Tools: #{Log.fingerprint tools.keys}}" if tools

    parameters[:messages] = LLM::OpenAI.tools_to_openai messages

    response = LLM::OpenAI.process_response self.rest(:post, url, key, "chat/completions" , parameters), tools, &block

    res = if response.last[:role] == 'function_call_output' 
            response + self.ask(messages + response, original_options.merge(tool_choice: tool_choice_next, return_messages: true, tools: tools ), &block)
          else
            response
          end

    if return_messages
      res
    else
      res.last['content']
    end
  end

  end
end
