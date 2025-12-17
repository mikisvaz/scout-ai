module Chat
  def self.tasks(messages, original = nil)
    jobs =  []
    new = messages.collect do |message|
      if message[:role] == 'task' || message[:role] == 'inline_task' || message[:role] == 'exec_task'
        info = message[:content].strip

        workflow, task  = info.split(" ").values_at 0, 1

        options = IndiferentHash.parse_options info
        jobname = options.delete :jobname

        if String === workflow
          workflow = begin
                       Kernel.const_get workflow
                     rescue
                       Workflow.require_workflow(workflow)
                     end
        end

        job = workflow.job(task, jobname, options)

        jobs << job unless message[:role] == 'exec_task'

        if message[:role] == 'exec_task'
          begin
            {role: 'user', content: job.exec}
          rescue
            {role: 'exec_job', content: $!}
          end
        elsif message[:role] == 'inline_task'
          {role: 'inline_job', content: job.path.find}
        else
          {role: 'job', content: job.path.find}
        end
      else
        message
      end
    end.flatten

    Workflow.produce(jobs) if jobs.any?

    new
  end

  def self.jobs(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'job' || message[:role] == 'inline_job'
        file = message[:content].strip

        step = Step.load file

        id = step.short_path[0..39]
        id = id.gsub('/','-')

        if message[:role] == 'inline_job'
          path = step.path
          path = path.find if Path === path
          {role: 'file', content: step.path}
        else

          function_name = step.full_task_name.sub('#', '-')
          function_name = step.task_name
          tool_call = {
            function: {
              name: function_name,
              arguments: step.provided_inputs
            },
            id: id,
          }

          content = if step.done?
                      Open.read(step.path)
                    elsif step.error?
                      step.exception
                    end

          tool_output = {
            id: id,
            content: content
          }

          [
            {role: 'function_call', content: tool_call.to_json},
            {role: 'function_call_output', content: tool_output.to_json},
          ]
        end
      else
        message
      end
    end.flatten
  end

  def self.tools(messages)
    tool_definitions = IndiferentHash.setup({})
    new = messages.collect do |message|
      if message[:role] == 'mcp'
        url, *tools = content_tokens(message)

        if url == 'stdio'
          command = tools.shift
          mcp_tool_definitions = LLM.mcp_tools(url, command: command, url: nil, type: :stdio)
        else
          mcp_tool_definitions = LLM.mcp_tools(url)
        end

        if tools.any?
          tools.each do |tool|
            tool_definitions[tool] = mcp_tool_definitions[tool]
          end
        else
          tool_definitions.merge!(mcp_tool_definitions)
        end
        next
      elsif message[:role] == 'tool'
        workflow_name, task_name, *inputs = content_tokens(message)
        inputs = nil if inputs.empty?
        inputs = [] if inputs == ['none'] || inputs == ['noinputs']
        if Open.remote? workflow_name
          require 'rbbt'
          require 'scout/offsite/ssh'
          require 'rbbt/workflow/remote_workflow'
          workflow = RemoteWorkflow.new workflow_name
        else
          workflow = Workflow.require_workflow workflow_name
        end

        if task_name
          definition = LLM.task_tool_definition workflow, task_name, inputs
          tool_definitions[task_name] = [workflow, definition]
        else
          tool_definitions.merge!(LLM.workflow_tools(workflow))
        end
        next
      elsif message[:role] == 'kb'
        knowledge_base_name, *databases = content_tokens(message)
        databases = nil if databases.empty?
        knowledge_base = KnowledgeBase.load knowledge_base_name

        knowledge_base_definition = LLM.knowledge_base_tool_definition(knowledge_base, databases)
        tool_definitions.merge!(knowledge_base_definition)
        next
      elsif message[:role] == 'clear_tools'
        tool_definitions = {}
      else
        message
      end
    end.compact.flatten
    messages.replace new
    tool_definitions
  end

  def self.associations(messages, kb = nil)
    tool_definitions = {}
    new = messages.collect do |message|
      if message[:role] == 'association'
        name, path, *options = content_tokens(message)

        kb ||= KnowledgeBase.new Scout.var.Agent.Chat.knowledge_base
        kb.register name, Path.setup(path), IndiferentHash.parse_options(message[:content])

        tool_definitions.merge!(LLM.knowledge_base_tool_definition( kb, [name]))
        next
      elsif message[:role] == 'clear_associations'
        tool_definitions = {}
      else
        message
      end
    end.compact.flatten
    messages.replace new
    tool_definitions
  end
end
