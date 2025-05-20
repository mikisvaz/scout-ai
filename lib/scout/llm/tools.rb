require 'scout/workflow'
require 'scout/knowledge_base'
module LLM
  def self.tool_response(tool_call, &block)
    tool_call_id = tool_call.dig("id")
    function_name = tool_call.dig("function", "name")
    function_arguments = tool_call.dig("function", "arguments")
    function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments
    function_response = block.call function_name, function_arguments

    content = case function_response
              when String
                function_response
              when nil
                "success"
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

  def self.task_tool_definition(workflow, task_name, inputs = nil)
    task_info = workflow.task_info(task_name)

    inputs = inputs.collect{|i| i.to_sym } if inputs

    properties = task_info[:inputs].inject({}) do |acc,input|
      next acc if inputs and not inputs.include?(input)
      type = task_info[:input_types][input]
      description = task_info[:input_descriptions][input]

      type = :string if type == :select
      type = :string if type == :path
      type = :number if type == :float

      acc[input] = {
        "type": type,
        "description": description
      }

      if input_options = task_info[:input_options][input]
        if select_options = input_options[:select_options]
          select_options = select_options.values if Hash === select_options
          acc[input]["enum"] = select_options
        end
      end

      acc
    end

    required_inputs = task_info[:inputs].select do |input|
      next if inputs and not inputs.include?(input.to_sym)
      task_info[:input_options].include?(input) && task_info[:input_options][input][:required]
    end

    {
      type: "function",
      function: {
        name: task_name,
        description: task_info[:description],
        parameters: {
          type: "object",
          properties: properties,
          required: required_inputs
        }
      }
    }
  end

  def self.workflow_tools(workflow, tasks = nil)
    tasks = workflow.all_exports
    tasks.collect{|task_name| self.task_tool_definition(workflow, task_name) }
  end

  def self.knowledge_base_tool_definition(knowledge_base)

    databases = knowledge_base.all_databases.collect{|d| d.to_s }

    properties = {
      database: {
        type: "string",
        enum: databases,
        description: "Database to traverse"
      },
      entities: {
        type: "array",
        items: { type: :string },
        description: "Parent entities to find children for"
      }
    }

    [{
      type: "function",
      function: {
        name: 'children',
        description: "Find the graph children for a list of entities in a format like parent~child. Returns a list.",
        parameters: {
          type: "object",
          properties: properties,
          required: ['database', 'entities']
        }
      }
    }]
  end

  def self.association_tool_definition(name)
    properties = {
      entities: {
        type: "array",
        items: { type: :string },
        description: "Source entities in the association, or target entities if 'reverse' it true."
      },
      reverse: {
        type: "boolean",
        description: "Look for targets instead of sources, defaults to 'false'."
      }
    }

    {
      type: "function",
      function: {
        name: name,
        description: "Find associations for a list of entities. Returns a list in the format source~target.",
        parameters: {
          type: "object",
          properties: properties,
          required: ['entities']
        }
      }
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
        tool_call = JSON.parse(message[:content])
        tool_call['function']['arguments'] = (tool_call['function']['arguments'] || {}).to_json 
        {role: 'assistant', tool_calls: [tool_call]}
      elsif message[:role] == 'function_call_output'
        JSON.parse(message[:content])
      else
        message
      end
    end.flatten
  end

  def self.call_tools(tool_calls, &block)
    tool_calls.collect{|tool_call|
      response_message = LLM.tool_response(tool_call, &block)
      [
        {role: "function_call", content: tool_call.to_json},
        {role: "function_call_output", content: response_message.to_json},
      ]
    }.flatten
  end
end
