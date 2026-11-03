require_relative 'ask'

module LLM
  def self.agent(...)
    LLM::Agent.new(...)
  end

  def self.load_agent(...)
    LLM::Agent.load_agent(...)
  end

  class Agent
    attr_accessor :workflow, :knowledge_base, :start_chat, :process_exception, :other_options, :path, :job, :request_context, :start_chat_file

    def initialize(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
      @workflow = workflow
      @workflow = Workflow.require_workflow @workflow if String === @workflow
      @knowledge_base = knowledge_base
      @other_options = IndiferentHash.setup(kwargs.dup)
      @start_chat = start_chat
    end

    # Whether this agent carries a start_chat that represents deliberate
    # preparation: a start_chat file found by LLM::Agent.load_agent, or any
    # chat explicitly supplied at construction.  load_agent's synthetic
    # `introduce` fallback (workflow documentation with no start_chat file)
    # sets this to false.  Agent#ask gates implicit path-kind loading on
    # this signal: a prepared agent registers kinds ONLY through explicit
    # `path_kind:` chat lines.
    def start_chat_file?
      return !!@start_chat_file unless @start_chat_file.nil?
      !@start_chat.nil? && !@start_chat.empty?
    end

    def workflow(&block)
      if block_given?
        workflow = self.workflow

        workflow.instance_eval &block
      else
        @workflow ||= begin
                        m = Module.new
                        m.extend Workflow
                        m.name = 'ScoutAgent'
                        m.tasks = {}
                        m.libdir = nil
                        # Pin the anonymous agent workflow's job directory to
                        # the checkout var/jobs (path-map leak fix, H2); see
                        # AgentWorkflow.pin_workflow_job_directory!.
                        #AgentWorkflow.pin_workflow_job_directory!(m) if AgentWorkflow.respond_to?(:pin_workflow_job_directory!)
                        m
                      end
      end
    end

    def format_message(message, prefix = "user")
      message.split(/\n\n+/).reject{|line| line.empty? }.collect do |line|
        prefix + "\t" + line.gsub("\n", ' ')
      end * "\n"
    end

    def agent_name
      workflow.to_s
    end

    #def system_prompt
    #  system = @system
    #  system = [] if system.nil?
    #  system = [system] unless system.nil? || system.is_a?(Array)
    #  system = [] if system.nil?

    #  if @knowledge_base and @knowledge_base.all_databases.any?
    #    system << <<-EOF
 # Youhave access to the following databases associating entities:
    #    EOF

    #    knowledge_base.all_databases.each do |database|
    #      system << knowledge_base.markdown(database)
    #    end
    #  end

    #  system * "\n"
    #end

    # function: takes an array of messages and calls LLM.ask with them
    def ask(messages = nil, options = {})
      messages, options = nil, messages if options.empty? && Hash === messages

      request_context = options.delete(:request_context) || @request_context || {}
      request_context[:caller] = self.save_file if self.save_file
      request_context = IndiferentHash.add_defaults request_context, main_chat: request_context[:caller]

      messages = current_chat if messages.nil?
      messages = [messages] unless messages.is_a? Array
      model ||= @model if model

      no_ask_override = @other_options[:no_ask_override]

      messages.delete_if{|info| info[:role] == 'agent' }
      begin

        if workflow && workflow.tasks.include?(:ask) && ! no_ask_override
          other_options.each do |key,value|
            messages.push(IndiferentHash.setup({role: :sticky_option, content: "#{key} #{value}"})) 
          end

          options.except(:return_messages).each do |key,value|
            messages.push(IndiferentHash.setup({role: :sticky_option, content: "#{key} #{value}"})) 
          end

          job = workflow.job(:ask, chat: Chat.print(messages))
          if request_context
            job.extend(RequestContext::StepExtension)
            job.register_request_context(request_context)
          end

          self.message(:meta, Chat.serialize_meta(job: job.short_path))
          self.save

          job.clean if ENV['SCOUT_NO_ASK_CACHE'] == 'true'
          job.recursive_clean if ENV['SCOUT_NO_ASK_CACHE'] == 'recursive'

          Open.mkdir job.files_dir
          Chat.allow_job job

          job.produce
          
          messages = Chat.load(job.path)
          if options[:return_messages]
            Chat.setup(messages)
          else
            Chat.setup(messages).answer
          end
        else

          # Path-kind configuration.  Two loading rules meet here:
          #
          # 1. Explicit `path_kind: <Workflow> [<kind>...]` lines are honored
          #    wherever they appear (start_chat or user chat): first token the
          #    workflow, the rest kind names; multiple kinds per line and
          #    multiple lines accumulate.  An empty kind list means every
          #    kind of that workflow.  Resolution reuses Chat.load_workflow;
          #    an unloadable workflow or an unknown kind raises loudly
          #    (ParameterException, the same step-1 behavior), and registration
          #    happens from the FULL message list BEFORE any stripping, so
          #    clear_tools or role removal never bypasses it.
          #
          # 2. Implicit loading happens ONLY when the agent carries no
          #    deliberate start_chat (`start_chat_file?` false): then the
          #    agent's own workflow loads its PATH_KINDS (today's fallback
          #    loaded none), and whole-workflow `tool:` lines keep their
          #    historical kind incorporation as back-compat.  With a start_chat
          #    present, `tool: W` configures tools only -- zero kinds load
          #    unless a `path_kind:` line says otherwise.
          path_kind_lines = Chat.find_role(messages, :path_kind)

          unless start_chat_file?
            # Own workflow first: when the agent's workflow declares
            # PATH_KINDS, an unprepared agent gets all of them (the
            # synthetic-introduce fallback used to load none).
            integrate_workflow_path_kinds(@workflow) if @workflow

            Chat.find_role(messages, :tool).each do |message|
              workflow_name, task_name, *_inputs = Chat.content_tokens(message)
              next if task_name
              next if workflow_name.nil? || workflow_name.empty?
              next if Open.remote? workflow_name

              begin
                workflow = Chat.load_workflow workflow_name
              rescue
                next
              end
              integrate_workflow_path_kinds(workflow)
            end
          end

          path_kind_lines.each do |message|
            tokens = Chat.content_tokens(message)
            next if tokens.empty?
            workflow_name = tokens.shift
            next if workflow_name.nil? || workflow_name.empty?
            # No kind names on the line: every kind of the workflow, the
            # same all-kinds semantics as a whole-workflow `tool:` line.
            selection = tokens.empty? ? nil : tokens

            begin
              workflow = Chat.load_workflow workflow_name
            rescue Exception
              raise ParameterException, "The workflow #{workflow_name.inspect} named by the path_kind line could not be loaded: #{$!.message}"
            end

            integrate_workflow_path_kinds(workflow, only: selection)
          end

          messages.remove_role(:path_kind)

          %w(socialize attachments).each do |capability|
            if (list = messages.remove_role(capability)).any?
              status = list.last[:content]
              next if status.nil?
              status = status.to_s
              next if %w(false FALSE False F 0).include?(status)
              next unless %w(true TRUE True T 1).include?(status)
              self.send(capability.to_sym, options.dup) 
            end
          end

          tools = options[:tools] || {}
          if other_tools = @other_options[:tools]
            other_tools = JSON.parse other_tools if String === other_tools
            tools = tools.merge other_tools
          end

          if workflow || knowledge_base
            tools.merge!(LLM.workflow_tools(workflow)) if workflow && workflow.tasks.any?
            tools.merge!(LLM.knowledge_base_tool_definition(knowledge_base)) if knowledge_base and knowledge_base.all_databases.any?
          end

          options[:tools] = tools

          ask_options = @other_options.except(:no_ask_override)
          IndiferentHash.setup(ask_options)
          ask_options= ask_options.merge(log_errors: true, save_file: self.save_file)
          ask_options = ask_options.merge(options)
          ask_options = ask_options.merge(request_context: request_context, agent: false)

          config_endpoint = Scout::Config.get('endpoint', agent_name)
          ask_options[:endpoint] = config_endpoint if config_endpoint

          LLM.ask messages, ask_options       
        end
      rescue
        exception = $!
        if Proc === self.process_exception
          try_again = self.process_exception.call exception
          if try_again
            retry
          else
            raise exception
          end
        else
          begin
            self.save if self.save_file
          rescue
            Log.exception $!
          ensure
            raise exception
          end
        end
      end
    end

    def prompt(messages, options = {})
      messages = LLM.chat messages if String === messages
      messages = Chat.follow start_chat, messages
      ask messages, options
    end

    def self.load_from_path(path, workflow: nil, knowledge_base: nil, chat: nil)
      workflow_path = path['workflow.rb'].find
      knowledge_base_path = path['knowledge_base']
      chat_path = path['start_chat']

      workflow ||= Workflow.require_workflow workflow_path if workflow_path.exists?
      knowledge_base ||= KnowledgeBase.new knowledge_base_path if knowledge_base_path.exists?
      chat ||= Chat.setup LLM.chat(chat_path.find) if chat_path.exists?

      LLM::Agent.new workflow: workflow, knowledge_base: knowledge_base, start_chat: chat
    end

    def self.load_agent(agent_name = nil, options = {})
      agent_name = agent_name.to_s if Symbol === agent_name
      if agent_name && ::Path.is_filename?(agent_name) 
        if File.directory?(agent_name)
          dir = Path.setup(agent_name)
          if dir.agent.find_with_extension("rb").exists?
            return load dir.agent.find_with_extension("rb")
          end
        else
          return load agent_name
        end
      end

      if agent_name

        agent_path = Scout.Agent[agent_name]
        workflow_path = agent_path['workflow.rb'].exists? ? agent_path : Scout.workflows[agent_name]
        agent_path = Scout.var.Agent[agent_name] unless agent_path.exists?
        agent_path = Scout.chats.Agent[agent_name] unless agent_path.exists?
        agent_path = Scout.chats[agent_name] unless agent_path.exists?

        raise ScoutException, "No agent found with name #{agent_name}" unless workflow_path.exists? || agent_path.exists?

        @@agent_workflow ||= {}
        workflow = @@agent_workflow[agent_name] ||= if agent_path.workflow.find_with_extension("rb").exists?
                                                      Workflow.require_workflow agent_path.workflow.find_with_extension("rb")
                                                    elsif workflow_path.exists?
                                                      agent_path = workflow_path
                                                      Workflow.require_workflow agent_name
                                                    elsif agent_path.python.exists? && agent_path.python.glob('*.py').any?
                                                      require 'scout/workflow/python'
                                                      PythonWorkflow.load_directory agent_path.python, 'ScoutAgent'
                                                    end

        knowledge_base = if agent_path.knowledge_base.exists?
                           KnowledgeBase.load agent_path.knowledge_base.find
                         elsif workflow_path.knowledge_base.exists?
                           KnowledgeBase.load workflow_path.knowledge_base.find
                         end

        chat = nil
        # Whether `chat` came from a real start_chat FILE (deliberate agent
        # preparation) or from the synthetic `introduce` documentation
        # fallback below.  Agent#ask gates implicit path-kind loading on
        # this (start_chat_file?): only an unprepared agent loads kinds
        # implicitly.
        start_chat_file = false
        if agent_path.start_chat.exists?
          chat = Chat.setup LLM.chat(agent_path.start_chat.find)
          start_chat_file = true
        elsif workflow_path.start_chat.exists?
          chat = Chat.setup LLM.chat(workflow_path.start_chat.find)
          start_chat_file = true
        elsif workflow && workflow.documentation[:description]
          chat = Chat.setup([ {role: 'introduce', content: workflow.name} ])
        end
      end

      agent = LLM::Agent.new **options.merge(workflow: workflow, knowledge_base: knowledge_base, start_chat: chat)
      agent.path = agent_path.find if agent_path
      agent.start_chat_file = start_chat_file if agent_name
      agent
    end
  end
end

require_relative 'agent/chat'
require_relative 'agent/construction'
require_relative 'agent/iterate'
require_relative 'agent/conversation'
require_relative 'agent/delegate'
require_relative 'agent/attach'
require_relative 'agent/save'
require_relative 'agent/workflow'
require_relative 'agent/path'
