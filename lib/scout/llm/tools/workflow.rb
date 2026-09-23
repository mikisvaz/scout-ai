require 'scout/workflow'
require_relative '../request_context'
module LLM
  def self.scout_to_tool_input_type(type)
    type = :text if type == :chat
    type = :text if type == :json
    type = :string if type == :text
    type = :string if type == :select
    type = :string if type == :path
    type = :number if type == :float
    type = :array if type.to_s.end_with?('_array')
    type
  end

  def self.task_tool_definition(workflow, task_name, inputs = nil)
    task_info = workflow.task_info(task_name)
    return nil if task_info.nil?

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
      options = task_info[:input_options][input]

      type = scout_to_tool_input_type(type) 
      type = :array if type.to_s.end_with?('_array')

      acc[input] = {
        type: type,
        description: description || ''
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

      if options && options[:file].to_s == 'true'
        acc[input] = {
          oneOf: [
            acc[input],
            {
              type: :string,
              description: 'Path to a file containing the input values'
            }
          ],
          description: description || ''
        }
      end

      acc
    end

    if not workflow.exec_exports.include?(task_name.to_sym)
      properties[:return_path] = {
        type: 'boolean',
        description: 'Instead of returning the result, return the path where the result is persisted. Use this when you want to pass the result to another tool or script, move it, or process it as a file without loading its contents into the conversation.',
        default: false
      }
      properties[:refresh] = {
        type: 'string',
        enum: ['false', 'refresh', 'deep_refresh'],
        description: 'Control whether cached results may be reused. Use "refresh" to recompute this task; use "deep_refresh" when results used by this task may also be stale and should be refreshed.',
        default: 'false'
      }
    else
      properties[:return_path] = {
        type: 'boolean',
        description: 'Instead of returning the result, write it to a temporary file and return its path. Use this when you want to pass the result to another tool or script, move it, or process it as a file without loading its contents into the conversation.',
        default: false
      }
    end

    required_inputs = task_info[:inputs].select do |input|
      next if names and not names.include?(input.to_sym)
      task_info[:input_options].include?(input) && task_info[:input_options][input][:required]
    end

    LLM.tool_definition(task_name, task_info[:description] || '', properties,
                        required: required_inputs, defaults: defaults, envelope: false)
  end

  def self.workflow_tools(workflow, tasks = nil)
    if Array === workflow
      workflow.inject({}){|tool_definitions,wf| tool_definitions.merge(workflow_tools(wf, tasks)) }

    else
      tasks = workflow.all_exports if tasks.nil?
      tasks = workflow.all_tasks if tasks.empty? && workflow.all_tasks
      tasks = [] if tasks.nil?

      tasks.inject({}){|tool_definitions,task_name|
        definition = self.task_tool_definition(workflow, task_name)
        next if definition.nil?
        tool_definitions.merge(task_name => [workflow, definition])
      }
    end
  end

  def self.call_workflow(workflow, task_name, parameters={}, request_context: nil, **keyword_parameters)
    parameters = (parameters || {}).merge(keyword_parameters)
    jobname, return_path, exec_type, allow_recursive, refresh = IndiferentHash.process_options parameters, :jobname, :return_path, :exec_type, :allow_recursive, :refresh
    begin
      job = workflow.job(task_name.to_sym, jobname, parameters)
      if workflow.exec_exports.include?(task_name.to_sym) || exec_type.to_s == 'exec'
        if return_path
          result = job.exec
          file = TmpFile.tmp_file
          case result
          when Chat
            Open.write(file, Chat.print(result))
          else
            Open.write(file, result.to_s)
          end
          file
        else
          job.exec
        end
      else
        case refresh
        when 'refresh'
          job.clean
        when 'deep_refresh'
          job.recursive_clean
        end
        if return_path
          was_done = job.done?
          job.run(true)
          RequestContext.write_producer_context(job, request_context, produced: !was_done) if request_context
          Chat.allow_read_job job
          job.path
        else
          raise ScoutException, 'Potential recursive call' if allow_recursive != 'true' &&
            (job.running? and job.info[:pid] == Process.pid)
          job
        end
      end
    rescue ScoutException
      return $!
    end
  end
end
