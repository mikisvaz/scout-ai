require 'scout'
require 'anthropic'
require_relative '../chat'

module LLM
  module Anthropic

    def self.client(url = nil, key = nil, log_errors = false, request_timeout: 1200)
      url ||= Scout::Config.get(:url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_URL')
      key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_KEY')
      Object::Anthropic::Client.new(access_token:key, log_errors: log_errors, uri_base: url, request_timeout: request_timeout)
    end

    def self.process_input(messages)
      messages.collect do |message|
        if message[:role] == 'image'
          Log.warn "Endpoint 'anthropic' does not support images, try 'responses': #{message[:content]}"
          next
        else
          message
        end
      end.flatten.compact
    end

    def self.process_response(response, tools, &block)
      Log.debug "Respose: #{Log.fingerprint response}"

      response['content'].collect do |output|
        case output['type']
        when 'text'
          IndiferentHash.setup({role: :assistant, content: output['text']})
        when 'reasoning'
          next
        when 'tool_use'
          LLM.process_calls(tools, [output], &block)
        when 'web_search_call'
          next
        else
          eee response
          eee output
          raise 
        end
      end.compact.flatten
    end


    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages

      options = IndiferentHash.add_defaults options, max_tokens: 1000

      client, url, key, model, log_errors, return_messages, format, tool_choice_next, previous_response_id, tools = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format, :tool_choice_next, :previous_response_id, :tools,
        log_errors: true, tool_choice_next: :none

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :anthropic, env: 'ANTHROPIC_MODEL', default: "claude-sonnet-4-20250514")
      end

      case format.to_sym
      when :json, :json_object
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
        parameters[:tools] = tools.values.collect{|obj,definition| Hash === obj ? obj : definition}
      end
      
      parameters[:tools] = parameters[:tools].collect do |info|
        IndiferentHash.setup(info)
        info[:type] = 'custom' if info[:type] == 'function'
        info[:input_schema] = info.delete('parameters') if info["parameters"]
        info
      end if parameters[:tools]

      messages = self.process_input messages

      Log.low "Calling anthropic #{url}: #{Log.fingerprint parameters}}"

      parameters[:messages] = LLM.tools_to_anthropic messages

      response = self.process_response client.messages(parameters: parameters), tools, &block

      res = if response.last[:role] == 'function_call_output' 
              #response + self.ask(messages + response, original_options.merge(tool_choice: tool_choice_next, return_messages: true, tools: tools ), &block)
              response + self.ask(messages + response, original_options.merge(return_messages: true, tools: tools ), &block)
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
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :anthropic, env: 'ANTHROPIC_URL')
        key ||= LLM.get_url_config(:key, url, :openai_embed, :embed, :anthropic, env: 'ANTHROPIC_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :anthropic, env: 'ANTHROPIC_URL')
        model ||= LLM.get_url_config(:model, url, :openai_embed, :embed, :anthropic, env: 'ANTHROPIC_MODEL', default: "gpt-3.5-turbo")
      end

      response = client.embeddings(parameters: {input: text, model: model})
      response.dig('data', 0, 'embedding')
    end
  end
end
