require 'scout/knowledge_base'
require_relative 'tools/mcp'
require_relative 'tools/workflow'
require_relative 'tools/knowledge_base'
require_relative 'tools/call'
module LLM
  def self.call_tools(tool_calls, &block)
    tool_calls.collect{|tool_call|
      response_message = LLM.tool_response(tool_call, &block)
      function_call = tool_call
      function_call['id'] = tool_call.delete('call_id') if tool_call.dig('call_id')
      [
        {role: "function_call", content: tool_call.to_json},
        {role: "function_call_output", content: response_message.to_json},
      ]
    }.flatten
  end

  def self.tool_response(tool_call, &block)
    tool_call_id = tool_call.dig("call_id") || tool_call.dig("id")
    if tool_call['function']
      function_name = tool_call.dig("function", "name")
      function_arguments = tool_call.dig("function", "arguments")
    else
      function_name = tool_call.dig("name")
      function_arguments = tool_call.dig("arguments")
    end

    function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments

    Log.high "Calling function #{function_name} with arguments #{Log.fingerprint function_arguments}"

    function_response = begin
                          block.call function_name, function_arguments
                        rescue
                          $!
                        end

    content = case function_response
              when String
                function_response
              when nil
                "success"
              when Exception
                {exception: function_response.message, stack: function_response.backtrace }.to_json
              else
                function_response.to_json
              end
    content = content.to_s if Numeric === content
    {
      id: tool_call_id,
      role: "tool",
      content: content
    }
  end

  def self.run_tools(messages)
    messages.collect do |info|
      IndiferentHash.setup(info)
      role = info[:role]
      if role == 'cmd'
        {
          role: 'tool',
          content: CMD.cmd(info[:content]).read
        }
      else
        info
      end
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

  def self.tools_to_anthropic(messages)
    messages.collect do |message|
      if message[:role] == 'function_call'
        tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
        arguments = tool_call.delete('arguments') || tool_call[:function].delete('arguments') || "{}"
        arguments = JSON.parse arguments if String === arguments
        name = tool_call[:name]
        id = tool_call.delete('call_id') || tool_call.delete('id') || tool_call.delete('tool_use_id')
        tool_call['id'] = id
        tool_call['type'] = 'tool_use'
        tool_call['name'] ||= name
        tool_call['input'] = arguments
        tool_call.delete :function
        {role: 'assistant', content: [tool_call]}
      elsif message[:role] == 'function_call_output'
        info = JSON.parse(message[:content])
        id = info.delete('call_id') || info.delete('id') || info.delete('tool_use_id') || info[:function].delete('id')
        info.delete "role"
        info['tool_use_id'] = id
        info['type'] = 'tool_result'
        {role: 'user', content: [info]}
      else
        message
      end
    end.flatten
  end

  def self.tools_to_ollama(messages)
    messages.collect do |message|
      if message[:role] == 'function_call'
        tool_call = JSON.parse(message[:content])
        arguments = tool_call.delete('arguments') || {}
        id = tool_call.delete('id')
        name = tool_call.delete('name')
        tool_call['type'] = 'function'
        tool_call['function'] ||= {}
        tool_call['function']['name'] ||= name
        tool_call['function']['arguments'] ||= arguments
        {role: 'assistant', tool_calls: [tool_call]}
      elsif message[:role] == 'function_call_output'
        info = JSON.parse(message[:content])
        id = info.delete('id') || ''
        info['role'] = 'tool'
        info
      else
        message
      end
    end.flatten
  end

  def self.tool_definitions_to_reponses(tools)
    tools.values.collect do |obj,definition|
      definition = obj if Hash === obj
      definition

      definition = case definition[:function]
                   when Hash
                     definition.merge(definition.delete :function)
                   else
                     definition
                   end

      definition = IndiferentHash.add_defaults definition, type: :function

      definition[:parameters].delete :defaults if definition[:parameters]

      definition
    end
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

  def self.tool_definitions_to_ollama(tools)
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
end
