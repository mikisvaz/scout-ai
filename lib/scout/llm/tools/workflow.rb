require 'scout/workflow'
module LLM
  def self.task_tool_definition(workflow, task_name, inputs = nil)
    task_info = workflow.task_info(task_name)

    if inputs
      names = []
      defaults = {}

      inputs.each do |i|
        if String === i && i.include?('=')
          name,_ , value = i.partition("=")
          defaults[name] = value
        else
          names << i.to_sym
        end
      end

    end

    properties = task_info[:inputs].inject({}) do |acc,input|
      next acc if names and not names.include?(input)
      type = task_info[:input_types][input]
      description = task_info[:input_descriptions][input]

      type = :string if type == :text
      type = :string if type == :select
      type = :string if type == :path
      type = :number if type == :float
      type = :array if type.to_s.end_with?('_array')

      acc[input] = {
        "type": type,
        "description": description
      }

      if type == :array
        acc[input]['items'] = {type: :string}
      end

      if input_options = task_info[:input_options][input]
        if select_options = input_options[:select_options]
          select_options = select_options.values if Hash === select_options
          acc[input]["enum"] = select_options
        end
      end

      acc
    end

    required_inputs = task_info[:inputs].select do |input|
      next if names and not names.include?(input.to_sym)
      task_info[:input_options].include?(input) && task_info[:input_options][input][:required]
    end

    function = {
      name: task_name,
      description: task_info[:description],
      parameters: {
        type: "object",
        properties: properties,
        required: required_inputs,
      }
    }

    function[:parameters][:defaults] = defaults if defaults

    #IndiferentHash.setup function.merge(type: 'function', function: function)
    IndiferentHash.setup function
  end

  def self.workflow_tools(workflow, tasks = nil)
    tasks = workflow.all_exports if tasks.nil?
    tasks = workflow.all_tasks if tasks.empty?

    tasks.inject({}){|tool_definitions,task_name|
      definition = self.task_tool_definition(workflow, task_name)
      tool_definitions.merge(task_name => [workflow, definition])
    }
  end

  def self.call_workflow(workflow, task_name, parameters={})
    jobname = parameters.delete :jobname
    begin
      job = workflow.job(task_name, jobname, parameters)
      if workflow.exec_exports.include? task_name.to_sym
        job.exec
      else
        raise ScoutException, 'Potential recurisve call' if job.running? and job.info[:pid] == Process.pid
        job.run
      end
    rescue ScoutException
      return $!
    end
  end
end
