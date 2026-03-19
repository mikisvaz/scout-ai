require_relative 'ask'

module LLM
  def self.agent(...)
    LLM::Agent.new(...)
  end

  def self.load_agent(...)
    LLM::Agent.load_agent(...)
  end

  class Agent
    attr_accessor :workflow, :knowledge_base, :start_chat, :process_exception, :other_options
    def initialize(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
      @workflow = workflow
      @workflow = Workflow.require_workflow @workflow if String === @workflow
      @knowledge_base = knowledge_base
      @other_options = IndiferentHash.setup(kwargs.dup)
      @start_chat = start_chat
    end

    def workflow(&block)
      if block_given?
        workflow = self.workflow

        workflow.instance_eval &block
      else
        @workflow ||= begin
                        m = Module.new
                        m = "ScoutAgent"
                        m.extend Workflow
                        m.tasks = {}
                        m
                      end
      end
    end

    def format_message(message, prefix = "user")
      message.split(/\n\n+/).reject{|line| line.empty? }.collect do |line|
        prefix + "\t" + line.gsub("\n", ' ')
      end * "\n"
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
      messages = current_chat if messages.nil?
      messages = [messages] unless messages.is_a? Array
      model ||= @model if model

      messages.delete_if{|info| info[:role] == 'agent' }
      if (list = messages.select{|info| info[:role] == 'socialize'}).any?
        socialize = list.last[:content]
        messages.delete_if{|info| info[:role] == 'socialize' }
        self.socialize(options.dup) if socialize && %w(true TRUE True T 1).include?(socialize.to_s)
      end

      tools = options[:tools] || {}
      if other_tools = @other_options[:tools]
        other_tools = JSON.parse other_tools if String === other_tools
        tools = tools.merge other_tools
      end

      begin

        if workflow || knowledge_base
          tools.merge!(LLM.workflow_tools(workflow)) if workflow
          tools.merge!(LLM.knowledge_base_tool_definition(knowledge_base)) if knowledge_base and knowledge_base.all_databases.any?
        end

        if workflow && workflow.tasks.include?(:ask)
          options.each do |key,value|
            messages.push(IndiferentHash.setup({role: :option, content: "#{key} #{value}"})) 
          end

          job = workflow.job(:ask, chat: Chat.print(messages))
          job.clean
          job.produce
          
          messages = LLM.chat job.path
          if options[:return_messages]
            messages
          else
            Chat.answer messages
          end
        else
          options[:tools] = tools
          LLM.ask messages, @other_options.merge(log_errors: true).merge(options).merge(agent: false)
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
          raise exception
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
      if agent_name && Path.is_filename?(agent_name) 
        if File.directory?(agent_name)
          dir = Path.setup(agent_name) unless Path === agent_name
          if dir.agent.find_with_extension("rb").exists?
            return load dir.agent.find_with_extension("rb")
          end
        else
          return load agent_name
        end
      end

      agent_name ||= 'default'

      workflow_path = Scout.workflows[agent_name]
      agent_path = Scout.var.Agent[agent_name]
      agent_path = Scout.chats[agent_name] unless agent_path.exists?
      agent_path = Scout.chats.Agent[agent_name] unless agent_path.exists?

      raise ScoutException, "No agent found with name #{agent_name}" unless workflow_path.exists? || agent_path.exists?

      workflow = if workflow_path.exists?
                   Workflow.require_workflow agent_name
                 elsif agent_path.workflow.find_with_extension("rb").exists?
                   Workflow.require_workflow_file agent_path.workflow.find_with_extension("rb")
                 elsif agent_path.python.exists? && agent_path.python.glob('*.py').any?
                   require 'scout/workflow/python'
                   PythonWorkflow.load_directory agent_path.python, 'ScoutAgent'
                 end

      knowledge_base = if agent_path.knowledge_base.exists?
                         KnowledgeBase.load agent_path.knowledge_base.find
                       elsif workflow_path.knowledge_base.exists?
                         KnowledgeBase.load workflow_path.knowledge_base.find
                       end

      chat = if agent_path.start_chat.exists?
               Chat.setup LLM.chat(agent_path.start_chat.find)
             elsif workflow_path.start_chat.exists?
               Chat.setup LLM.chat(workflow_path.start_chat.find)
             elsif agent_path.start_chat.exists?
               Chat.setup LLM.chat(agent_path.start_chat.find)
             elsif workflow && workflow.documentation[:description]
               Chat.setup([ {role: 'introduce', content: workflow.name} ])
             end

      LLM::Agent.new **options.merge(workflow: workflow, knowledge_base: knowledge_base, start_chat: chat)
    end
  end
end

require_relative 'agent/chat'
require_relative 'agent/iterate'
require_relative 'agent/delegate'
