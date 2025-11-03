#require_relative 'parse'
require_relative 'utils'
require_relative 'tools'
require_relative 'chat/annotation'
require 'shellwords'

module LLM
  def self.content_tokens(message)
    Shellwords.split(message[:content].strip)
  end

  def self.messages(question, role = nil)
    default_role = "user"

    if Array === question
      return question.collect do |q|
        if String === q
          {role: default_role, content: q}
        else
          q
        end
      end
    end

    messages = []
    current_role = default_role
    current_content = ""
    in_protected_block = false
    protected_block_type = nil
    protected_stack = []

    role = default_role if role.nil?

    file_lines = question.split("\n")

    file_lines.each do |line|
      stripped = line.strip

      # Detect protected blocks
      if stripped.start_with?("```")
        if in_protected_block
          in_protected_block = false
          protected_block_type = nil
          current_content << "\n" << line unless line.strip.empty?
        else
          in_protected_block = true
          protected_block_type = :square
          current_content << "\n" << line unless line.strip.empty?
        end
        next
      elsif stripped.end_with?("]]") && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub("]]", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.start_with?("[[")
        in_protected_block = true
        protected_block_type = :square
        line = line.sub("[[", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.end_with?("]]") && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub("]]", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.match(/^.*:-- .* {{{/)
        in_protected_block = true
        protected_block_type = :square
        line = line.sub(/^.*:-- (.*) {{{.*/, '<cmd_output cmd="\1">')
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.match(/^.*:--.* }}}/) && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub(/^.*:-- .* }}}.*/, "</cmd_output>")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif in_protected_block

        if protected_block_type == :xml
          if stripped =~ %r{</(\w+)>}
            closing_tag = $1
            if protected_stack.last == closing_tag
              protected_stack.pop
            end
            if protected_stack.empty?
              in_protected_block = false
              protected_block_type = nil
            end
          end
        end
        current_content << "\n" << line
        next
      end

      # XML-style tag handling (protected content)
      if stripped =~ /^<(\w+)(\s+[^>]*)?>/
        tag = $1
        protected_stack.push(tag)
        in_protected_block = true
        protected_block_type = :xml
      end

      # Match a new message header
      if line =~ /^([a-z0-9_]+):(.*)$/
        role = $1
        inline_content = $2.strip

        current_content = current_content.strip if current_content
        # Save current message if any
        messages << { role: current_role, content: current_content }

        if inline_content.empty?
          # Block message
          current_role = role
          current_content = ""
        else
          # Inline message + next block is default role
          messages << { role: role, content: inline_content }
          current_role = 'user' if role == 'previous_response_id'
          current_content = ""
        end
      else
        if current_content.nil?
          current_content = line
        else
          current_content += "\n" + line
        end
      end
    end

    # Final message
    messages << { role: current_role || default_role, content: current_content.strip }

    messages
  end

  def self.find_file(file, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    path = Scout.chats[file]
    original = original.find if Path === original
    if original
      relative = File.join(File.dirname(original), file)
      relative_lib = File.join(caller_lib_dir, file)
    end

    if Open.exist?(file)
      file
    elsif Open.remote?(file)
      file
    elsif relative && Open.exist?(relative)
      relative
    elsif relative_lib && Open.exist?(relative_lib)
      relative_lib
    elsif path.exists?
      path
    end
  end

  def self.imports(messages, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    messages.collect do |message|
      if message[:role] == 'import' || message[:role] == 'continue' || message[:role] == 'last'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "Import not found: #{file}" if found_file.nil?

        new = LLM.messages Open.read(found_file)

        new = if message[:role] == 'continue'
                [new.reject{|msg| msg[:content].nil? || msg[:content].strip.empty? }.last]
              elsif message[:role] == 'last'
                [LLM.purge(new).reject{|msg| msg[:content].empty?}.last]
              else
                LLM.purge(new)
              end

        LLM.chat new, found_file
      else
        message
      end
    end.flatten
  end

  def self.files(messages, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    messages.collect do |message|
      if message[:role] == 'file' || message[:role] == 'directory'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "File not found: #{file}" if found_file.nil?

        target = found_file

        if message[:role] == 'directory'
          Path.setup target
          target.glob('**/*').
            reject{|file|
              Open.directory?(file)
            }.collect{|file|
              files([{role: 'file', content: file}])
            }
        else
          new = LLM.tag :file, Open.read(target), file
          {role: 'user', content: new}
        end
      elsif message[:role] == 'pdf' || message[:role] == 'image'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "File not found: #{file}" if found_file.nil?

        message[:content] = found_file
        message
      else
        message
      end
    end.flatten
  end

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

    Workflow.produce(jobs)

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

  def self.clear(messages)
    new = []

    messages.reverse.each do |message|
      if message[:role].to_s == 'clear'
        break
      elsif message[:role].to_s == 'previous_response_id'
        new << message
        break
      else
        new << message
      end
    end

    new.reverse
  end

  def self.clean(messages)
    messages.reject do |message|
      ((String === message[:content]) && message[:content].empty?) ||
        message[:role] == 'skip'
    end
  end

  def self.indiferent(messages)
    messages.collect{|msg| IndiferentHash.setup msg }
  end

  def self.chat(file, original = nil)
    original ||= (String === file and Open.exists?(file)) ? file : Path.setup($0.dup)
    caller_lib_dir = Path.caller_lib_dir(nil, 'chats')

    if Array === file
      messages = self.messages file
      messages = self.indiferent messages
      messages = self.imports messages, original, caller_lib_dir
    elsif Open.exists?(file)
      messages = self.messages Open.read(file)
      messages = self.indiferent messages
      messages = self.imports messages, original, caller_lib_dir
    else
      messages = self.messages file
      messages = self.indiferent messages
      messages = self.imports messages, original, caller_lib_dir
    end

    messages = self.clear messages
    messages = self.clean messages
    messages = self.tasks messages
    messages = self.jobs messages
    messages = self.files messages, original, caller_lib_dir

    Chat.setup messages
  end

  def self.options(chat)
    options = IndiferentHash.setup({})
    sticky_options = IndiferentHash.setup({})
    new = []

    # Most options reset after an assistant reply, but not previous_response_id
    chat.each do |info|
      if Hash === info
        role = info[:role].to_s
        if %w(endpoint model backend persist agent).include? role.to_s
          options[role] = info[:content]
          next
        elsif %w(previous_response_id).include? role.to_s
          sticky_options[role] = info[:content]
          next
        elsif %w(format).include? role.to_s
          format = info[:content]
          if Path.is_filename?(format)
            file = find_file(format)
            if file
              format = Open.json(file)
            end
          end
          options[role] = format
          next
        end

        if role.to_s == 'option'
          key, _, value = info[:content].partition(" ")
          options[key] = value
          next
        end

        if role.to_s == 'sticky_option'
          key, _, value = info[:content].partition(" ")
          sticky_options[key] = value
          next
        end

        if role == 'assistant'
          options.clear
        end
      end
      new << info
    end
    chat.replace new
    sticky_options.merge options
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

  def self.print(chat)
    return chat if String  === chat
    "\n" + chat.collect do |message|
      IndiferentHash.setup message
      case message[:content]
      when Hash, Array
        message[:role].to_s + ":\n\n" + message[:content].to_json
      when nil, ''
        message[:role].to_s + ":"
      else
        if %w(option previous_response_id function_call function_call_output).include? message[:role].to_s
          message[:role].to_s + ": " + message[:content].to_s
        else
          message[:role].to_s + ":\n\n" + message[:content].to_s
        end
      end
    end * "\n\n"
  end

  def self.purge(chat)
    chat.reject do |msg|
      IndiferentHash.setup msg
      msg[:role].to_s == 'previous_response_id'
    end
  end
end

