require_relative 'default'
require 'openai'

module LLM
  # OpenAI Chat Completions backend.
  #
  # Implemented as a module exposing singleton methods (`LLM::OpenAI.ask`, etc).
  # We compose the backend by:
  #   - prepending OpenAIMethods into the singleton class (overrides)
  #   - including Backend::ClassMethods into the singleton class (shared logic)
  module OpenAIMethods
    def query(client, messages, tools = [], parameters = {})
      parameters[:messages] = messages
      parameters[:tools] = format_tool_definitions(tools) if tools && tools.any?

      begin
        client.chat(parameters: parameters)
      rescue
        Log.debug 'Input parameters: ' + "\n" + JSON.pretty_generate(parameters)
        raise $!
      end
    end

    def format_tool_definitions(tools)
      tools.values.collect do |obj, definition|
        definition = obj if Hash === obj
        definition

        definition = case definition[:function]
                     when Hash
                       definition
                     else
                       { type: :function, function: definition }
                     end

        definition = IndiferentHash.add_defaults definition, type: :function

        definition[:parameters].delete :defaults if definition[:parameters]

        definition
      end
    end

    def format_tool_call(message)
      tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
      arguments = tool_call.delete('arguments') || {}
      name = tool_call[:name]
      tool_call['type'] = 'function'
      tool_call['function'] ||= {}
      tool_call['function']['name'] ||= name || 'function'
      tool_call['function']['arguments'] = arguments.to_json
      { role: 'assistant', tool_calls: [tool_call] }
    end

    def format_tool_output(message, last_id = nil)
      info = JSON.parse(message[:content])
      id = info.delete('call_id') || info.dig('id') || last_id
      info['role'] = 'tool'
      info['tool_call_id'] = id
      info
    end

    # Tool-calls in the Chat Completions API are shaped like:
    #   {"id":"call_...", "type":"function", "function": {"name":"...", "arguments":"{...}"}}
    def parse_tool_call(info)
      IndiferentHash.setup(info)

      function = info['function'] || info[:function] || {}
      IndiferentHash.setup(function)

      name = function[:name] || info[:name]
      id = info[:id] || info['id'] || info[:call_id] || info['call_id']

      arguments = function[:arguments] || info[:arguments] || info['arguments'] || '{}'
      arguments = begin
                    JSON.parse(arguments)
                  rescue
                    arguments
                  end if String === arguments

      { arguments: arguments, id: id, name: name }
    end

    def process_response(messages, response, tools, options, &block)
      Log.debug "Response: #{Log.fingerprint response}"

      raise Exception, response['error'] if response['error']

      message = response.dig('choices', 0, 'message')

      tool_calls = response.dig('choices', 0, 'tool_calls') ||
        response.dig('choices', 0, 'message', 'tool_calls')

      if tool_calls && tool_calls.any?
        tool_calls = tool_calls.collect { |tool_call| parse_tool_call(tool_call) }
        LLM.process_calls(tools, tool_calls, &block)
      else
        [IndiferentHash.setup(message)]
      end
    end
  end

  module OpenAI
    TAG = 'openai'
    DEFAULT_MODEL = 'gpt-5-nano'

    class << self
      prepend OpenAIMethods
      include Backend::ClassMethods
    end
  end
end
