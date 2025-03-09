require 'scout/workflow'
require 'scout/knowledge_base'
module LLM
  def self.tool_response(tool_call, &block)
    tool_call_id = tool_call.dig("id")
    function_name = tool_call.dig("function", "name")
    function_arguments = tool_call.dig("function", "arguments")
    function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments
    function_response = block.call function_name, function_arguments

    #content = String === function_response ? function_response : function_response.to_json,
    content = case function_response
              when String
                function_response
              when nil
                "success"
              else
                function_response.to_json
              end
    {
      tool_call_id: tool_call_id,
      role: "tool",
      content: content
    }
  end

  def self.task_tool_definition(workflow, task_name)
    task_info = workflow.task_info(task_name)

    properties = task_info[:inputs].inject({}) do |acc,input|
      type = task_info[:input_types][input]
      description = task_info[:input_descriptions][input]

      type = :string if type == :select

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
      task_info[:input_options].include?(input) && task_info[:input_options][:required]
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

  def self.workflow_tools(workflow)
    workflow.tasks.keys.collect{|task_name| self.task_tool_definition(workflow, task_name) }
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
end
