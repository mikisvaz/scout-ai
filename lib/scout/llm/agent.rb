require_relative 'ask'

module LLM
  def self.agent(...)
    LLM::Agent.new(...)
  end

  class Agent
    attr_accessor :workflow, :knowledge_base, :start_chat, :process_exception
    def initialize(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
      @workflow = workflow
      @workflow = Workflow.require_workflow @workflow if String === @workflow
      @knowledge_base = knowledge_base
      @other_options = kwargs
      @start_chat = start_chat
    end

    def format_message(message, prefix = "user")
      message.split(/\n\n+/).reject{|line| line.empty? }.collect do |line|
        prefix + "\t" + line.gsub("\n", ' ')
      end * "\n"
    end

    def system_prompt
      system = @system
      system = [] if system.nil?
      system = [system] unless system.nil? || system.is_a?(Array)
      system = [] if system.nil?

      if @knowledge_base and @knowledge_base.all_databases.any?
        system << <<-EOF
You have access to the following databases associating entities:
        EOF

        knowledge_base.all_databases.each do |database|
          system << knowledge_base.markdown(database)
        end
      end

      system * "\n"
    end

    def prompt(messages)
      if system_prompt
        [format_message(system_prompt, "system"), messages.collect{|m| format_message(m)}.flatten] * "\n"
      else
        messages.collect{|m| format_message(m)}.flatten
      end
    end

    # function: takes an array of messages and calls LLM.ask with them
    def ask(messages, model = nil, options = {})
      messages = [messages] unless messages.is_a? Array
      model ||= @model if model

      tools = options[:tools] || {}
      tools = tools.merge @other_options[:tools] if @other_options[:tools]
      options[:tools] = tools
      begin
        if workflow || knowledge_base
          tools.merge!(LLM.workflow_tools(workflow)) if workflow
          tools.merge!(LLM.knowledge_base_tool_definition(knowledge_base)) if knowledge_base and knowledge_base.all_databases.any?
          options[:tools] = tools
          LLM.ask messages, @other_options.merge(log_errors: true).merge(options)
        else
          LLM.ask messages, @other_options.merge(log_errors: true).merge(options)
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
        end
      end
    end

    def self.load_from_path(path, workflow: nil, knowledge_base: nil, chat: nil)
      workflow_path = path['workflow.rb'].find
      knowledge_base_path = path['knowledge_base']
      chat_path = path['start_chat']

      workflow = Workflow.require_workflow workflow_path if workflow_path.exists?
      knowledge_base = KnowledgeBase.new knowledge_base_path if knowledge_base_path.exists?
      chat = LLM.chat chat_path if chat_path.exists?

      LLM::Agent.new workflow: workflow, knowledge_base: knowledge_base, start_chat: chat
    end
  end
end

require_relative 'agent/chat'
require_relative 'agent/iterate'
require_relative 'agent/delegate'
