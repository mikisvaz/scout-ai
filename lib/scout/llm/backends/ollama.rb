require_relative 'default'
require 'ollama-ai'

module LLM
  module OLlama
    extend Backend

    TAG='ollama'
    DEFAULT_MODEL='llama3.1'

    def extra_options(options, messages = nil)
      format = IndiferentHash.process_options options, :format

      case format.to_sym
      when :json, :json_object
        options[:response_format] = {type: 'json_object'}
      else
        options[:response_format] = {type: format}
      end if format
    end

    def self.client(options, messages = nil)
      url, key = IndiferentHash.process_options options,
        :url, :key

      Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        }
      )
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

    def self.embed_query(client, text, parameters = {})
      parameters[:input] = text

      begin
        embeddings = client.request('api/embed', parameters)
      rescue
        Log.debug 'Input parameters: ' + "\n" + JSON.pretty_generate(parameters)
        raise $!
      end

      Array === text ? embeddings.first['embeddings'] : embeddings.first['embeddings'].first
    end

    def self.parse_tool_call(info)
      arguments, name = IndiferentHash.process_options info['function'], :arguments, :name
      id = name + "_" + Misc.digest(arguments)
      {arguments: arguments, id: id, name: name}
    end

    def self.process_response(messages, responses, tools, options, &block)
      Log.debug "Respose: #{Log.fingerprint responses}"
      output = responses.collect do |response|

        message = IndiferentHash.setup response['message']
        tool_calls = response.dig("tool_calls") ||
          response.dig("message", "tool_calls")

        next if message[:role] == 'assistant' && message[:content].empty? && tool_calls.nil?

        if tool_calls && tool_calls.any?
          tool_calls = tool_calls.collect{|tool_call| self.parse_tool_call tool_call }
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
  end
end
