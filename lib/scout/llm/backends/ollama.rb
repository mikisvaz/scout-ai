require 'ollama-ai'
require_relative '../parse'
require_relative '../tools'
require_relative '../utils'
require_relative '../chat'

module LLM
  module OLlama
    def self.client(url, key = nil)
      Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        },
        options: { stream: false, debug: true }
      )
    end


    def self.process_response(responses, tools, &block)
      responses.collect do |response|
        Log.debug "Respose: #{Log.fingerprint response}"

        message = response['message']
        tool_calls = response.dig("tool_calls") ||
          response.dig("message", "tool_calls")

        if tool_calls && tool_calls.any?
          LLM.process_calls tools, tool_calls, &block
        else
          [message]
        end
      end.flatten
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages

      client, url, key, model, return_messages, format, stream, previous_response_id, tools = IndiferentHash.process_options options,
        :client, :url, :key, :model, :return_messages, :format, :stream, :previous_response_id, :tools,
        stream: false

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
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
        parameters[:tools] = LLM.tool_definitions_to_ollama tools
      end

      Log.low "Calling ollama #{url}: #{Log.fingerprint(parameters.except(:tools))}}"
      Log.medium "Tools: #{Log.fingerprint tools.keys}}" if tools

      parameters[:messages] = LLM.tools_to_ollama messages

      parameters[:stream] = stream

      response = self.process_response client.chat(parameters), tools, &block

      res = if response.last[:role] == 'function_call_output' 
              response + self.ask(messages + response, original_options.except(:tool_choice).merge(return_messages: true, tools: tools), &block)
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
