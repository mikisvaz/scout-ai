require_relative 'ask'

module LLM
  class Agent
    attr_accessor :workflow, :knowledge_base, :start_chat
    def initialize(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
      @workflow = workflow
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

      tools = []
      tools += LLM.workflow_tools(workflow) if workflow
      tools += LLM.knowledge_base_tool_definition(knowledge_base) if knowledge_base and knowledge_base.all_databases.any?

      LLM.ask prompt(messages), @other_options.merge(log_errors: true, tools: tools) do |name,parameters|
        case name
        when 'children'
          parameters = IndiferentHash.setup(parameters)
          database, entities = parameters.values_at "database", "entities"
          Log.high "Finding #{entities} children in #{database}"
          knowledge_base.children(database, entities)
        else
          if workflow
            begin
              Log.high "Calling #{workflow}##{name} with #{Log.fingerprint parameters}"
              workflow.job(name, parameters).run
            rescue
              $!.message
            end
          else
            raise "What?"
          end
        end
      end
    end

    def self.load_from_path(path, workflow: nil, knowledge_base: nil, chat: nil)
      workflow_path = path['workflow.rb']
      knowledge_base_path = path['knowledge_base']
      chat_path = path['start_chat']

      workflow = Workflow.require_workflow workflow_path if workflow_path.exists?
      knowledge_base = KnowledgeBase.new knowledge_base_path if knowledge_base_path.exists?
      chat = LLM.chat chat_path if chat_path.exists?

      LLM::Agent.new workflow, knowledge_base, chat
    end
  end
end
require_relative 'agent/chat'
