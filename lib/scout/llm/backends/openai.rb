require 'scout'
require 'openai'
require_relative '../chat'

module LLM
  module OpenAI

    def self.client(url = nil, key = nil, log_errors = false, request_timeout: 1200)
      url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
      key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
      Object::OpenAI::Client.new(access_token:key, log_errors: log_errors, uri_base: url, request_timeout: request_timeout)
    end

    def self.process_input(messages)
      messages.collect do |message|
        if message[:role] == 'image'
          Log.warn "Endpoint 'openai' does not support images, try 'responses': #{message[:content]}"
          next
        else
          message
        end
      end.flatten.compact
    end

    def self.tool_definitions_to_openai(tools)
      tools.values.collect do |obj,definition|
        definition = obj if Hash === obj
        definition

        definition = case definition[:function]
                     when Hash
                       definition
                     else
                       {type: :function, function: definition}
                     end

        definition = IndiferentHash.add_defaults definition, type: :function

        definition[:parameters].delete :defaults if definition[:parameters]

        definition
      end
    end

    def self.tools_to_openai(messages)
      messages.collect do |message|
        if message[:role] == 'function_call'
          tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
          arguments = tool_call.delete('arguments') || {}
          name = tool_call[:name]
          tool_call['type'] = 'function'
          tool_call['function'] ||= {}
          tool_call['function']['name'] ||= name || 'function'
          tool_call['function']['arguments'] = arguments.to_json
          {role: 'assistant', tool_calls: [tool_call]}
        elsif message[:role] == 'function_call_output'
          info = JSON.parse(message[:content])
          id = info.delete('call_id') || info.dig('id')
          info['role'] = 'tool'
          info['tool_call_id'] = id
          info
        else
          message
        end
      end.flatten
    end

    def self.process_response(response, tools, &block)
      Log.debug "Respose: #{Log.fingerprint response}"
      raise Exception, response["error"] if response["error"]

      message = response.dig("choices", 0, "message")
      tool_calls = response.dig("choices", 0, "tool_calls") ||
        response.dig("choices", 0, "message", "tool_calls")

      if tool_calls && tool_calls.any?
        LLM.process_calls(tools, tool_calls, &block)
      else
        [message]
      end
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages

      client, url, key, model, log_errors, return_messages, format, tool_choice_next, previous_response_id, tools, = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format, :tool_choice_next, :previous_response_id, :tools,
        log_errors: true, tool_choice_next: :none

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = self.client url, key, log_errors
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

      messages = self.process_input messages

      Log.debug "Calling openai #{url}: #{Log.fingerprint(parameters.except(:tools))}}"
      Log.high "Tools: #{Log.fingerprint tools.keys}}" if tools

      parameters[:messages] = LLM::OpenAI.tools_to_openai messages

      response = self.process_response client.chat(parameters: parameters), tools, &block

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
      raise response['error']['message'] if response.include? 'error'
      response.dig('data', 0, 'embedding')
    end
  end
end
