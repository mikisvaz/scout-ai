module LLM
  class Agent

    def delegate(agent, name, description, &block)
      @other_options[:tools] ||= {}
      task_name = "hand_off_to_#{name}"

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
end
