require_relative 'utils'
require_relative 'parse'
require_relative 'tools'

module LLM
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
    current_role = nil
    current_content = ""
    in_protected_block = false
    protected_block_type = nil
    protected_stack = []

    role = default_role if role.nil?

    file_lines = question.split("\n")

    file_lines.each do |line|
      stripped = line.strip

      # Detect protected blocks
      if stripped.start_with?("[[")
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

        # Save current message if any
        messages << { role: current_role, content: current_content.strip }

        if inline_content.empty?
          # Block message
          current_role = role
          current_content = ""
        else
          # Inline message + next block is default role
          messages << { role: role, content: inline_content }
          #current_role = default_role
          current_content = ""
        end
      else
        current_content << "\n" << line
      end
    end

    # Final message
    messages << { role: current_role || default_role, content: current_content.strip }

    messages
  end

  def self.imports(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'import' || message[:role] == 'continue'
        file = message[:content].to_s.strip
        path = Scout.chats[file]
        original = original.find if Path === original
        relative = File.join(File.dirname(original), file) if original

        new = if Open.exist?(file)
                LLM.chat file
              elsif relative && Open.exist?(relative)
                LLM.chat relative
              elsif path.exists?
                LLM.chat path
              else
                raise "Import not found: #{file}"
              end

        if message[:role] == 'continue'
          new.last
        else
          new
        end
      else
        message
      end
    end.flatten
  end

  def self.files(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'file' || message[:role] == 'directory'
        file = message[:content].strip
        path = Scout.root[file]
        original = original.find if Path === original
        relative = File.join(File.dirname(original), file) if original

        target = if Open.exist?(file)
                   file
                 elsif relative && Open.exist?(relative)
                   relative
                 elsif path.exists?
                   path
                 else
                   raise "Import not found: #{file}"
                 end

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
      else
        message
      end
    end.flatten
  end

  def self.jobs(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'job' || message[:role] == 'inline_job'
        file = message[:content].strip

        step = Step.load file

        if message[:role] == 'inline_job'
          {role: 'file', content: step.path}
        else
          tool_call = {
            type: "function",
            function: {
              name: step.full_task_name.sub('#', '-'),
              arguments: step.provided_inputs
            },
            id: step.short_path.gsub('/','_'),
          }

          tool_output = {
            tool_call_id: step.short_path.gsub('/','_'),
            role: "tool",
            content: step.path.read
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

  def self.tasks(messages, original = nil)
    jobs =  []
    new = messages.collect do |message|
      if message[:role] == 'task' || message[:role] == 'inline_task'
        info = message[:content].strip

        workflow, task  = info.split(" ").values_at 0, 1

        options = IndiferentHash.parse_options info
        jobname = options.delete :jobname

        job = Workflow.require_workflow(workflow).job(task, jobname, options)

        jobs << job

        if message[:role] == 'inline_task'
          {role: 'inline_job', content: job.short_path}
        else
          {role: 'job', content: job.short_path}
        end
      else
        message
      end
    end.flatten

    Workflow.produce(jobs)

    new
  end

  def self.clear(messages)
    new = []

    messages.reverse.each do |message|
      if message[:role] == 'clear'
        break
      else
        new << message
      end
    end

    new.reverse
  end

  def self.clean(messages)
    messages.reject do |message|
      message[:content] && message[:content].empty?
    end
  end

  def self.indiferent(messages)
    messages.collect{|msg| IndiferentHash.setup msg }
  end

  def self.chat(file)
    if Array === file
      messages = self.messages file
      messages = self.indiferent messages
      messages = self.imports messages, Path.caller_lib_dir
    elsif Open.exists?(file)
      messages = self.messages Open.read(file)
      messages = self.indiferent messages
      messages = self.imports messages, file
    else
      messages = self.messages file
      messages = self.indiferent messages
      messages = self.imports messages, nil
    end

    messages = self.clear messages
    messages = self.clean messages
    messages = self.tasks messages
    messages = self.jobs messages
    messages = self.files messages

    messages
  end

  def self.options(chat)
    options = IndiferentHash.setup({})
    new = []
    chat.each do |info|
      if Hash === info
        role = info[:role].to_s
        if %w(endpoint format model backend persist).include? role.to_s
          options[role] = info[:content]
          next
        end

        if role == 'assistant'
          options.clear
        end
      end
      new << info
    end
    chat.replace new
    options
  end

  def self.tools(messages)
    tool_definitions = {}
    new = messages.collect do |message|
      if message[:role] == 'tool'
        workflow_name, task_name, *inputs = message[:content].strip.split(/\s+/)
        if Open.remote? workflow_name
          require 'rbbt'
          require 'scout/offsite/ssh'
          require 'rbbt/workflow/remote_workflow'
          workflow = RemoteWorkflow.new workflow_name
        else
          workflow = Workflow.require_workflow workflow_name
        end
        definition = LLM.task_tool_definition workflow, task_name, inputs
        tool_definitions[task_name] = [workflow, definition]
        next
      else
        message
      end
    end.compact.flatten
    messages.replace new
    tool_definitions
  end

  def self.associations(messages)
    tool_definitions = {}
    kb = nil
    new = messages.collect do |message|
      if message[:role] == 'association'
        name, path, *options = message[:content].strip.split(/\s+/)

        kb ||= KnowledgeBase.new Scout.var.Agent.Chat.knowledge_base
        kb.register name, Path.setup(path), IndiferentHash.parse_options(message[:content])

        definition = LLM.association_tool_definition name
        tool_definitions[name] = [kb, definition]
        next
      else
        message
      end
    end.compact.flatten
    messages.replace new
    tool_definitions
  end

  def self.print(chat)
    return chat if String  === chat
    chat.collect do |message|
      IndiferentHash.setup message
      case message[:content]
      when Hash, Array
        message[:role].to_s + ":\n\n" + message[:content].to_json
      when nil
        message[:role].to_s + ":\n\n" + message.to_json
      else
        message[:role].to_s + ":\n\n" + message[:content].to_s
      end
    end * "\n\n"
  end
end

module Chat
  extend Annotation

  def message(role, content)
    self.append({role: role.to_s, content: content})
  end

  def user(content)
    message(:user, content)
  end

  def system(content)
    message(:system, content)
  end

  def assistant(content)
    message(:assistant, content)
  end

  def import(file)
    message(:import, file)
  end

  def continue(file)
    message(:continue, file)
  end

  def format(format)
    message(:format, format)
  end

  def tool(*parts)
    content = parts * "\n"
    message(:tool, content)
  end

  def ask(...)
    LLM.ask(LLM.chat(self), ...)
  end

  def tag(content, name=nil, tag=:file, role=:user)
    self.message role, LLM.tag(tag, content, name)
  end

  def chat text
    self.concat(LLM.chat text)
  end

  def json(...)
    self.format :json
    output = ask(...)
    JSON.parse output
  end
end
