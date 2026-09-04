module LLM
  class Agent

    # Load one immutable template per specialist. Conversations clone this
    # template so that their current chats and start chats remain independent.
    # This is the template-resolution step of Agent#open_conversation; it is
    # kept public because callers (and tests) use it directly.
    def load_agent(agent_name, options = {})
      agent_name = normalize_social_agent_name(agent_name)
      @society ||= {}
      @society[agent_name] ||= begin
                                 agent = LLM.load_agent(agent_name, social_agent_options(options))
                                 agent
                               end
    end

    # Return a persistent specialist conversation. Conversation identifiers are
    # scoped by specialist, so Worker/work_A and Critic/work_A cannot collide.
    # `inherit` is only used when the conversation is first created.
    def load_chat(agent_name, options = {}, conversation = nil, inherit: 'tools')
      open_conversation(agent_name, conversation: conversation, inherit: inherit,
                                        options: options)
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
      ask_conversation(agent_name, prompt, conversation: conversation,
                                          inherit: inherit, options: options)
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
          description: 'Optional conversation or chat identifier; reuse it with the same agent to continue that conversation across several calls'
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

      definition = LLM.tool_definition(task_name, description, properties,
                                       required: [:agent, :prompt])
      @other_options[:tools][task_name] = [block, definition]
    end

    # Delegate work to a specialist through a `hand_off_to_<name>` tool.
    #
    # `agent` may be any object that answers `user` (duck-typed); only
    # LLM::Agent instances can go through the conversation pipeline.
    #
    # Registration: an LLM::Agent passed here is pre-registered in
    # `@society[name] ||= agent`. @society is ALSO socialize's template
    # cache, so a pre-registered live agent becomes the template for that
    # name; the clone copies only its start_chat (plus any adopted delta),
    # so drift between the two objects is contained to their chats.
    def delegate(agent, name, description, task_name = nil, &block)
      @other_options[:tools] ||= {}
      task_name = "hand_off_to_#{name}".to_sym if task_name.nil?
      @society ||= {}
      @society[name] ||= agent if LLM::Agent === agent

      block ||= Proc.new do |_name, parameters|
        message = parameters[:message]
        new_conversation = parameters[:new_conversation]
        Log.medium "Delegated to #{agent}: " + Log.fingerprint(message)

        begin
          if LLM::Agent === agent
            # The conversation slot is derived from the delegated name and
            # sanitized like a society conversation key, so any name that can
            # name a tool can name a conversation (save.rb's conservative
            # `[^a-zA-Z0-9_-]` sanitizer, never a raise).
            slot = name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
            slot = '_' if slot.empty?
            slot = '_' + slot unless slot =~ /\A[a-z0-9]/i

            ask_conversation(name, message,
                             conversation: slot,
                             inherit: 'none',
                             template: agent,
                             adopt: :current,
                             restart: new_conversation)
          else
            # Duck-typed objects keep the legacy direct-mutation behavior
            agent.start if new_conversation
            agent.user message
            agent
          end
        rescue ScoutException => e
          e
        end
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

      definition = LLM.tool_definition(task_name, description, properties,
                                       required: [:message])

      @other_options[:tools][task_name] = [block, definition]
    end
  end
end
