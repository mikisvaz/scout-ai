module LLM
  def self.call_id_name_and_arguments(tool_call)
    tool_call_id = tool_call.dig("call_id") || tool_call.dig("id")
    if tool_call['function']
      function_name = tool_call.dig("function", "name")
      function_arguments = tool_call.dig("function", "arguments")
    else
      function_name = tool_call.dig("name")
      function_arguments = tool_call.dig("arguments")
    end

    function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments

    [tool_call_id, function_name, function_arguments]
  end

  def self.process_calls(tools, calls, &block)
    IndiferentHash.setup tools
    calls.collect do |tool_call|
      tool_call_id, function_name, function_arguments = call_id_name_and_arguments(tool_call)

      function_arguments = IndiferentHash.setup function_arguments

      obj, definition = tools[function_name]

      definition = obj if Hash === obj

      defaults = definition[:parameters][:defaults] if definition[:parameters]
      function_arguments = function_arguments.merge(defaults) if defaults

      Log.high "Calling #{function_name} (#{Log.fingerprint function_arguments}): "
      function_response = case obj
                          when Proc
                            obj.call function_name, function_arguments
                          when Workflow
                            call_workflow(obj, function_name, function_arguments)
                          when KnowledgeBase
                            call_knowledge_base(obj, function_name, function_arguments)
                          else
                            if block_given?
                              block.call function_name, function_arguments
                            else
                              raise "Unkown executor #{Log.fingerprint obj} for function #{function_name}"
                            end
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

      Log.high "Called #{function_name}: " + Log.fingerprint(content)

      response_message = {
        id: tool_call_id,
        role: "tool",
        content: content
      }

      function_call = tool_call.dup

      function_call['id'] = function_call.delete('call_id') if function_call.dig('call_id')
      [
        {role: "function_call", content: function_call.to_json},
        {role: "function_call_output", content: response_message.to_json},
      ]
    end.flatten
  end
end
