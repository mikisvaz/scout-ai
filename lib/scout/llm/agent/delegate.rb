module LLM
  class Agent

    SOCIAL_INHERIT_MODES = %w[none tools conversation].freeze
    SOCIAL_AGENT_NAME = /\A[a-z_.-]+\z/i
    SOCIAL_CONVERSATION_NAME = /\A[a-z0-9][a-z0-9_.-]*\z/i
    SOCIAL_PRIVATE_OPTIONS = %i[
      agent client current_meta format messages no_ask_override previous_response_id
      process return_messages tool_choice tools
    ].freeze

    attr_accessor :society, :chats

    # Load one immutable template per specialist. Conversations clone this
    # template so that their current chats and start chats remain independent.
    def load_agent(agent_name, options = {})
      agent_name = normalize_social_agent_name(agent_name)
      @society ||= {}
      @society[agent_name] ||= LLM.load_agent(agent_name, social_agent_options(options))
    end

    # Return a persistent specialist conversation. Conversation identifiers are
    # scoped by specialist, so Worker/work_A and Critic/work_A cannot collide.
    # `inherit` is only used when the conversation is first created.
    def load_chat(agent_name, options = {}, conversation = nil, inherit: 'tools')
      agent_name = normalize_social_agent_name(agent_name)
      conversation = normalize_social_conversation_name(conversation)
      inherit = normalize_social_inherit(inherit)

      @chats ||= {}
      key = social_chat_key(agent_name, conversation)
      @chats[key] ||= start_social_chat(agent_name, options, inherit)
    end

    # Ask a specialist using a plain-text prompt.
    #
    # With no conversation identifier this is a one-shot call. With an
    # identifier, later calls continue the same specialist instance. The
    # inheritance policy seeds a new call or conversation after the
    # specialist's own start_chat:
    #
    # - none:         no context from the caller
    # - tools:        only declarative tooling from the caller's task chat
    # - conversation: the caller's complete task chat
    #
    # ScoutCoder: Agent#prompt parses String input as Scout chat-file syntax.
    # Delegated prompts must instead be appended with Agent#user so role-looking
    # text such as "tool:" cannot turn into a control message or grant tools.
    def ask_agent(agent_name, prompt, conversation: nil, inherit: 'tools', options: {})
      raise ParameterException, 'The delegated prompt must be a String' unless String === prompt

      agent_name = normalize_social_agent_name(agent_name)
      inherit = normalize_social_inherit(inherit)

      agent = if conversation.nil?
                load_chat(agent_name, options, 'default', inherit: inherit)
              else
                conversation = normalize_social_conversation_name(conversation)
                load_chat(agent_name, options, conversation, inherit: inherit)
              end

      agent.user(prompt)
      agent.chat
    end

    # Expose a deliberately narrow `ask` tool to this agent. The model can send
    # only a specialist name, a plain-text prompt, an optional persistent
    # conversation identifier, and an inheritance policy. It never receives or
    # edits the specialist's Chat object.
    def socialize(options = {})
      @other_options[:tools] ||= {}
      @society ||= {}
      social_options = social_duplicate(options || {})

      task_name = :ask
      block = Proc.new do |_name, parameters|
        begin
          agent_name, prompt, conversation, inherit = social_tool_parameters(parameters)
          ask_agent(agent_name, prompt,
                    conversation: conversation,
                    inherit: inherit,
                    options: social_options)
        rescue ScoutException => e
          e
        end
      end

      properties = {
        agent: {
          type: 'string',
          description: 'Name of the specialist agent to ask'
        },
        prompt: {
          type: 'string',
          description: 'Plain-text prompt sent as one user message to the specialist'
        },
        conversation: {
          type: 'string',
          pattern: '^[A-Za-z0-9][A-Za-z0-9_.-]*$',
          description: 'Optional conversation identifier. Omit it for a one-shot call; reuse it with the same agent to continue that conversation'
        },
        inherit: {
          type: 'string',
          enum: SOCIAL_INHERIT_MODES,
          default: 'tools',
          description: "Context copied only when starting the call or named conversation: 'none' uses only the specialist start_chat, 'tools' also copies caller task tooling, and 'conversation' copies the caller task conversation"
        }
      }

      description = <<-EOF
Ask another agent and receive only its text answer. Omit `conversation` for an
independent one-shot call. Set `conversation` to a name and reuse the same name
with the same agent for follow-up turns. `inherit` controls only how a new call
or named conversation is initialized; follow-up turns retain their own history.
The specialist's own start_chat is always applied first.
      EOF

      function = {
        name: task_name,
        description: description,
        parameters: {
          type: 'object',
          properties: properties,
          required: [:agent, :prompt],
          additionalProperties: false
        }
      }

      definition = IndiferentHash.setup(function.merge(type: 'function', function: function))
      @other_options[:tools][task_name] = [block, definition]
    end

    def delegate(agent, name, description, task_name = nil, &block)
      @other_options[:tools] ||= {}
      task_name = "hand_off_to_#{name}".to_sym if task_name.nil?

      block ||= Proc.new do |_name, parameters|
        message = parameters[:message]
        new_conversation = parameters[:new_conversation]
        Log.medium "Delegated to #{agent}: " + Log.fingerprint(message)
        agent.start if new_conversation
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

    private

    def normalize_social_agent_name(agent_name)
      agent_name = agent_name.to_s if Symbol === agent_name
      unless String === agent_name && SOCIAL_AGENT_NAME.match?(agent_name)
        raise ParameterException,
              'Agent name must contain only letters, dots, underscores, or hyphens'
      end
      agent_name
    end

    def normalize_social_conversation_name(conversation)
      conversation = conversation.to_s if Symbol === conversation
      unless String === conversation && SOCIAL_CONVERSATION_NAME.match?(conversation)
        raise ParameterException,
              'Conversation identifier must start with a letter or number and contain only letters, numbers, dots, underscores, or hyphens'
      end
      conversation
    end

    def normalize_social_inherit(inherit)
      inherit = inherit.to_s
      return inherit if SOCIAL_INHERIT_MODES.include?(inherit)

      raise ParameterException,
            "Unknown inheritance policy #{inherit.inspect}; expected one of #{SOCIAL_INHERIT_MODES * ', '}"
    end

    def social_chat_key(agent_name, conversation)
      "#{agent_name}/#{conversation}"
    end

    # Provider session state and executable Ruby tool objects belong to the
    # caller. Model/backend defaults may flow to specialists, but capabilities
    # are inherited only through the specialist start_chat or an explicit
    # declarative inheritance policy.
    def social_agent_options(options)
      defaults = IndiferentHash.setup(social_duplicate(other_options || {}))
      supplied = IndiferentHash.setup(social_duplicate(options || {}))
      merged = defaults.merge(supplied)
      SOCIAL_PRIVATE_OPTIONS.each { |name| merged.delete(name) }
      merged
    end

    def social_duplicate(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[social_duplicate(key)] = social_duplicate(item)
        end
      when Array
        value.collect { |item| social_duplicate(item) }
      when String
        value.dup
      else
        value
      end
    end

    def social_chat_copy(chat)
      Chat.setup(social_duplicate(chat || []))
    end

    def clone_social_agent(template)
      agent = template.clone
      agent.start_chat = social_chat_copy(template.start_chat)
      agent.other_options = IndiferentHash.setup(social_duplicate(template.other_options || {}))
      agent.society = nil
      agent.chats = nil
      agent.instance_variable_set(:@current_chat, nil)
      agent
    end

    def start_social_chat(agent_name, options, inherit)
      template = load_agent(agent_name, options)
      agent = clone_social_agent(template)
      initial_chat = social_chat_copy(agent.start_chat)
      initial_chat.follow(social_inherited_context(inherit))
      agent.start(initial_chat)
      agent
    end

    # In the usual Agent#start branch, start-chat messages are the same Hash
    # objects in both arrays, which lets us remove the caller agent's policy
    # exactly even if Agent#ask has removed control roles. The prefix fallback
    # covers callers that adopted an equivalent, separately parsed Chat.
    def social_caller_context
      current = current_chat || []
      base = start_chat || []
      base_ids = base.each_with_object({}) { |message, ids| ids[message.object_id] = true }

      context = if current.any? { |message| base_ids[message.object_id] }
                  current.reject { |message| base_ids[message.object_id] }
                else
                  prefix = 0
                  limit = [current.length, base.length].min
                  prefix += 1 while prefix < limit && current[prefix] == base[prefix]
                  current.drop(prefix)
                end

      social_chat_copy(context)
    end

    def social_inherited_context(inherit)
      case inherit
      when 'none'
        Chat.setup([])
      when 'tools'
        #tooling = social_caller_context.tooling
        tooling = self.current_chat.tooling
        social_chat_copy(tooling)
      when 'conversation'
        social_caller_context
      end
    end

    # Accept the former `chat` argument when a stored tool call is replayed, but
    # do not advertise it in the schema. New calls keep conversation identity
    # and inheritance as independent concepts.
    def social_tool_parameters(parameters)
      parameters = IndiferentHash.setup((parameters || {}).dup)
      agent_name = parameters[:agent]
      prompt = parameters[:prompt]
      conversation = parameters[:conversation]
      inherit = parameters[:inherit]

      if parameters.include?(:chat)
        raise ParameterException, 'Use either conversation or the legacy chat argument, not both' if conversation

        legacy_chat = parameters[:chat]
        case legacy_chat.to_s
        when 'current'
          conversation = 'current'
          inherit ||= 'conversation'
        when '', 'none', 'false'
          conversation = nil
          inherit ||= 'none'
        else
          conversation = legacy_chat
          inherit ||= 'tools'
        end
      end

      inherit ||= 'tools'
      [agent_name, prompt, conversation, inherit]
    end
  end
end
