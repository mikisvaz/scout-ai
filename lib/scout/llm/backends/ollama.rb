require_relative 'default'
require 'ollama-ai'

module LLM
  module OLlama
    extend Backend
    TAG='ollama'

    def self.client(options, messages = nil)
      client, url, key, model, log_errors, format, previous_response_id, request_timeout = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :format, :previous_response_id, :request_timeout,
        log_errors: true, request_timeout: 1200

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = Ollama.new(
          credentials: {
            address: url,
            bearer_token: key
          }
        )
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-4.1")
      end

      options[:model] = model unless options.include?(:model)

      case format.to_sym
      when :json, :json_object
        options[:response_format] = {type: 'json_object'}
      else
        options[:response_format] = {type: format}
      end if format

      client
    end


    def self.query(client, messages, tools = [], parameters = {})
      parameters[:stream] = false
      parameters[:tools] = self.format_tool_definitions tools if tools && tools.any?
      parameters[:messages] = messages

      begin
        client.chat(parameters)
      rescue
        Log.debug 'Input parameters: ' + "\n" + JSON.pretty_generate(parameters)
        raise $!
      end
    end

    def self.process_response(messages, responses, tools, options, &block)
      Log.debug "Respose: #{Log.fingerprint responses}"
      output = responses.collect do |response|

        message = IndiferentHash.setup response['message']
        tool_calls = response.dig("tool_calls") ||
          response.dig("message", "tool_calls")

        next if message[:role] == 'assistant' && message[:content].empty? && tool_calls.nil?

        if tool_calls && tool_calls.any?
          LLM.process_calls tools, tool_calls, &block
        else
          [message]
        end
      end.flatten.compact

      output
    end

    def self.format_tool_definitions(tools)
      tools.values.collect do |obj,definition|
        definition = obj if Hash === obj
        definition = IndiferentHash.setup definition

        definition = case definition[:function]
                     when Hash
                       definition
                     else
                       {type: :function, function: definition}
                     end

        definition = IndiferentHash.add_defaults definition, type: :function

        definition
      end
    end

    def self.format_tool_call(message)
      tool_call = JSON.parse(message[:content])
      arguments = tool_call.delete('arguments') || {}
      id = tool_call.delete('id')
      name = tool_call.delete('name')
      tool_call['type'] = 'function'
      tool_call['function'] ||= {}
      tool_call['function']['name'] ||= name
      tool_call['function']['arguments'] ||= arguments
      {role: 'assistant', tool_calls: [tool_call]}
    end

    def self.format_tool_output(message)
      info = JSON.parse(message[:content])
      id = info.delete('id') || ''
      info['role'] = 'tool'
      info
    end

    def self.chain_tools(messages, output, tools, options = {}, &block)
      previous_response_id = options[:previous_response_id]

      output = if output.last[:role] == 'function_call_output'
                 case previous_response_id
                 when String
                   output + ask(output, options.except(:tool_choice).merge(return_messages: true, previous_response_id: previous_response_id), &block)
                 else
                   output + ask(messages + output, options.except(:tool_choice).merge(return_messages: true), &block)
                 end
               else
                 output
               end

      output = if output.last[:role] == :previous_response_id
                 output
               elsif previous_response_id
                 previous_response_message = {role: :previous_response_id, content: previous_response_id} if previous_response_id
                 output + [previous_response_message]
               else
                 output
               end
    end

    def self.embed(text, options = {})

      client, url, key, model = IndiferentHash.process_options options, :client, :url, :key, :model

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end

      parameters = { input: text, model: model }
      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
      embeddings = client.request('api/embed', parameters)

      Array === text ? embeddings.first['embeddings'] : embeddings.first['embeddings'].first
    end
  end
end
