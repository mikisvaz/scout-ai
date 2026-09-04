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

    # Open (or resume) one specialist conversation.
    #
    # This is the single conversation-open pipeline shared by every
    # delegation entry point (`ask_agent`, `load_chat`, and the `ask` tool
    # exposed by `socialize`). It runs five steps, in order:
    #
    # 1. Resolve the specialist: a pre-built `template:` wins when given;
    #    otherwise `load_agent(name, options)` normalizes/validates the name
    #    and returns the one immutable template cached in `@society`.
    # 2. Seed: clone the template (`clone_social_agent`) and build the
    #    initial chat exactly as `start_social_chat` does: copy of the
    #    specialist's own start_chat, then the inherited context selected by
    #    `inherit` (none = empty, tools = caller task tooling, conversation =
    #    caller task conversation), then the `preamble:` messages, then
    #    `agent.start(initial_chat)`. With `adopt: :current` the template's
    #    own progress (current_chat minus its start_chat) is folded in right
    #    after the start_chat copy, before the inherited context.
    # 3. Anchor: `agent.save_file = anchor || society_save_file(name,
    #    conversation)`, assigned at creation so auto-save and restart
    #    snapshots apply from the first round.
    # 4. Register: `@chats[social_chat_key(name, conversation)] ||= agent`.
    #    Identity is scoped per specialist; `inherit` is only used when the
    #    conversation is first created.
    # 5. Restart: when the conversation already exists and `restart:` is
    #    true, re-branch it in place (keep start_chat, drop what follows);
    #    no new key is minted.
    #
    # `job:` is reserved for later workflow anchoring and is accepted and
    # ignored for now.
    def open_conversation(name, conversation: 'default', inherit: 'tools',
                          options: {}, preamble: nil, anchor: nil,
                          restart: false, template: nil, adopt: nil, job: nil)
      agent_name = normalize_social_agent_name(name)
      conversation = normalize_social_conversation_name(conversation)
      inherit = normalize_social_inherit(inherit)
      adopt = normalize_social_adopt(adopt)

      @chats ||= {}
      key = social_chat_key(agent_name, conversation)

      agent = @chats[key]

      if agent
        # Restart an existing conversation in place: Agent#start snapshots
        # the prior chat (when a save_file is configured) and re-branches
        # from start_chat, dropping everything that followed it.
        agent.start if restart
        return agent
      end

      agent = start_social_chat(agent_name, options, inherit, template: template, preamble: preamble, adopt: adopt)
      agent.save_file = anchor || society_save_file(agent_name, conversation)

      @chats[key] ||= agent
    end

    # Ask one specialist with a plain-text prompt, opening (or resuming) the
    # conversation first. `conversation: nil` is the one-shot form: it maps
    # to the 'default' slot AFTER normalization, exactly like `ask_agent`.
    # The prompt must be a String; role-looking text cannot smuggle control
    # messages because the prompt is appended with Agent#user.
    def ask_conversation(name, prompt, conversation: nil, inherit: 'tools',
                         options: {}, preamble: nil, anchor: nil,
                         restart: false, template: nil, adopt: nil, job: nil)
      raise ParameterException, 'The delegated prompt must be a String' unless String === prompt

      conversation = 'default' if conversation.nil?

      agent = open_conversation(name, conversation: conversation, inherit: inherit,
                                             options: options, preamble: preamble,
                                             anchor: anchor, restart: restart,
                                             template: template, adopt: adopt,
                                             job: job)

      agent.user(prompt)

      agent
    end

    # The live conversation registered under a society key
    # (`social_chat_key(name, conversation)` => `"<name>/<conversation>"`).
    # Returns nil when no such conversation is open. Delegation callers that
    # hold their own agent object can use this to reach the conversation
    # holder that actually advanced: the pipeline clones instead of mutating
    # the passed object.
    def conversation_agent(key)
      (@chats || {})[key]
    end

    private

    # --- name/policy normalization -------------------------------------------

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

    # `adopt:` is nil (nothing is folded in) or :current (the template's own
    # progress becomes part of the seed).
    def normalize_social_adopt(adopt)
      return nil if adopt.nil?
      return :current if adopt == :current || adopt.to_s == 'current'

      raise ParameterException,
            "Unknown adoption policy #{adopt.inspect}; expected nil or :current"
    end

    # --- society caches ------------------------------------------------------

    def social_chat_key(agent_name, conversation)
      "#{agent_name}/#{conversation}"
    end

    def society_save_file(agent_name, conversation)
      # ScoutCoder: the society directory is derived with the CANONICAL rule
      # (Agent.society_dir_for / Agent#society_dir), never by string
      # substitution here. An earlier version did
      # `save_file.sub(/\.chat/, '.society')`: the sub had no anchor, so it
      # replaced the FIRST '.chat' occurrence and a CLI-shaped save_file like
      # `cli.chat.files/agent.chat` turned into
      # `cli.society.files/agent.chat/...`, growing a second `.files` tree
      # instead of `cli.chat.files/agent.society/...`.
      # society_dir_for is the single source of truth for the root
      # (name-derived) rule; society_dir adds the location rule for nested
      # chats.
      #
      # save.rb simply does not auto-save without a save_file; mirror that
      # here instead of raising on nil (a society conversation started by an
      # agent with no save_file just never persists).
      return nil if save_file.nil?

      File.join(society_dir(save_file), agent_name.to_s, conversation.to_s, SOCIETY_CHAT_FILE)
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

    # Seed one specialist conversation. `template:` (a pre-built Agent)
    # bypasses `load_agent`; `preamble:` messages are followed after the
    # inherited context and before `start`.
    def start_social_chat(agent_name, options, inherit, template: nil, preamble: nil, adopt: nil)
      template ||= load_agent(agent_name, options)
      agent = clone_social_agent(template)
      initial_chat = social_chat_copy(agent.start_chat)
      initial_chat.follow(social_context_delta(template)) if adopt == :current
      initial_chat.follow(social_inherited_context(inherit))
      initial_chat.follow(preamble) if preamble
      agent.start(initial_chat)
      agent
    end

    # Delta of one agent's current chat over its own start_chat: what that
    # agent has actually said and done since it began. In the usual
    # Agent#start branch, start-chat messages are the same Hash objects in
    # both arrays, which lets us remove the policy exactly even if Agent#ask
    # has removed control roles. The prefix fallback covers chats adopted
    # from an equivalent, separately parsed Chat.
    #
    # ONE rule serves both seeding directions: the caller context
    # (social_caller_context) and the adopted template progress
    # (`adopt: :current`).
    def social_context_delta(an_agent)
      current = an_agent.current_chat || []
      base = an_agent.start_chat || []
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

    def social_caller_context
      social_context_delta(self)
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
