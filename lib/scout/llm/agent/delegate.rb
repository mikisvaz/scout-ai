module LLM
  class Agent

    attr_accessor :society, :chats

    def load_agent(agent_name, options)
      raise ParameterException, 
        "Agent name must be a single word optionally including a few puntuation characters" unless agent_name =~ /^[a-z_.-]*$/i
      @society ||= {}
      @society[agent_name] ||= LLM.load_agent agent_name, options.merge(self.other_options)
    end

    def load_chat(agent_name, options, chat)
      @chats ||= {}
      @chats[chat] ||= load_agent(agent_name, options).clone
    end

    def socialize(options = {})
      @other_options[:tools] ||= {}
      @society ||= {}

      task_name = :ask
      block ||= Proc.new do |name, parameters|
        agent_name, prompt, chat_id = IndiferentHash.process_options parameters.dup, 
          :agent, :prompt, :chat, 
          chat: 'current'

        begin
          options = options.dup

          res = case chat_id
                when 'current'
                  agent = load_chat agent_name, options, 'current'
                  chat = self.current_chat - self.start_chat
                  agent.concat chat
                  agent.user prompt
                  agent.chat 
                when 'none', nil, 'false'
                  agent = load_agent agent_name, options
                  agent.prompt prompt
                else
                  agent = load_chat agent_name, options, chat_id
                  agent.user prompt
                  agent.chat
                end
          res
        rescue ScoutException
          next $!
        end
      end

      properties = {
        agent: {
          "type": :string,
          "description": "Name of the agent"
        },
        prompt: {
          "type": :string,
          "description": "Prompt to pass to the agent"
        },
        chat: {
          "type": :string,
          "description": "(Optional) Chat identifier used to keep conversation history. The default is 'current' uses the conversation that the caller agent is involved with",
          "default": 'current'
        }
      }

      required_inputs = [:agent, :prompt]

      description =<<-EOF

The 'ask' function is used to send a prompt to an agent, returning the agents
response. You can keep one-shot questions or keep running conversations with
the same agent by giving the chat an identifier. The chat id 'current' has the
special meaning of passing the entire conversation to the agent, not just the
prompt.

      EOF

      function = {
        name: task_name,
        description: description,
        parameters: {
          type: "object",
          properties: properties,
          required: required_inputs
        }
      }

      definition = IndiferentHash.setup function.merge(type: 'function', function: function)


      @other_options[:tools][task_name] = [block, definition]
    end
  end
    def delegate(agent, name, description, &block)
      @other_options[:tools] ||= {}
      task_name = "hand_off_to_#{name}".to_sym

      block ||= Proc.new do |name, parameters|
        message = parameters[:message]
        new_conversation = parameters[:new_conversation]
        Log.medium "Delegated to #{agent}: " + Log.fingerprint(message)
        if new_conversation
          agent.start
        else
          agent.purge
        end
        agent.user message
        agent.chat
      end

      properties = {
        message: {
          "type": :string,
          "description": "Message to pass to the agent"
        },
        new_conversation: {
          "type": :boolean,
          "description": "Erase conversation history and start a new conversation with this message",
          "default": false
        }
      }

      required_inputs = [:message]

      function = {
        name: task_name,
        description: description,
        parameters: {
          type: "object",
          properties: properties,
          required: required_inputs
        }
      }

      definition = IndiferentHash.setup function.merge(type: 'function', function: function)


      @other_options[:tools][task_name] = [block, definition]
    end

end
