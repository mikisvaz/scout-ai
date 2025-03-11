require_relative 'ask'

module LLM
  class Agent
    attr_accessor :system, :workflow, :knowledge_base
    def initialize(system = nil, workflow: nil, knowledge_base: nil, model: nil, **kwargs)
      @system = system
      @workflow = workflow
      @knowledge_base = knowledge_base
      @model = model
      @other_options = kwargs
    end

    def format_message(message, prefix = "user")
      message.split(/\n\n+/).reject{|line| line.empty? }.collect do |line|
        prefix + "\t" + line.gsub("\n", ' ')
      end * "\n"
    end

    def system_prompt
      system = @system
      system = [system] unless system.nil? || system.is_a?(Array)

      if @knowledge_base
        system << <<-EOF
You have access to the following databases associating entities:
        EOF

        knowledge_base.all_databases.each do |database|
          system << <<-EOF.strip + (knowledge_base.undirected(database) ? ". Undirected" : "")
* #{database}: #{knowledge_base.source(database)} => #{knowledge_base.target(database)}
          EOF
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
    def ask(messages, model = nil)
      messages = [messages] unless messages.is_a? Array
      model ||= @model

      tools = []
      tools += LLM.workflow_tools(workflow) if workflow
      tools += LLM.knowledge_base_tool_definition(knowledge_base) if knowledge_base

      LLM.ask prompt(messages), @other_options.merge(model: model, log_errors: true, tools: tools) do |name,parameters|
        case name
        when 'children'
          parameters = IndiferentHash.setup(parameters)
          database, entities = parameters.values_at "database", "entities"
          Log.high "Finding #{entities} children in #{database}"
          knowledge_base.children(database, entities).target
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
  end
end
