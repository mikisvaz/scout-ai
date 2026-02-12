require_relative 'default'
require 'openai'

module LLM
  module OpenAI
    extend Backend
    TAG='openai'
    DEFAULT_MODEL='gpt-5-nano'

    def self.query(client, messages, tools = [], parameters = {})
      parameters[:messages] = messages

      parameters[:tools] = self.format_tool_definitions tools if tools && tools.any?

      begin
        client.chat(parameters: parameters)
      rescue
        Log.debug 'Input parameters: ' + "\n" + JSON.pretty_generate(parameters)
        raise $!
      end
    end

    def self.format_tool_definitions(tools)
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

    def self.format_tool_call(message)
      tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
      arguments = tool_call.delete('arguments') || {}
      name = tool_call[:name]
      tool_call['type'] = 'function'
      tool_call['function'] ||= {}
      tool_call['function']['name'] ||= name || 'function'
      tool_call['function']['arguments'] = arguments.to_json
      {role: 'assistant', tool_calls: [tool_call]}
    end

    def self.format_tool_output(message)
      info = JSON.parse(message[:content])
      id = info.delete('call_id') || info.dig('id')
      info['role'] = 'tool'
      info['tool_call_id'] = id
      info
    end

    def self.process_response(messages, response, tools, options, &block)
      Log.debug "Response: #{Log.fingerprint response}"

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
  end
end
