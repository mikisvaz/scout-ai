# Low-level mechanics for creating an independent agent conversation.
#
# This module deliberately knows nothing about social inheritance, workflow
# introductions, or persistent workspace policy. Callers compose the seed and
# decide the anchor/job; this module only makes that composition safe and
# starts a fresh agent from it.
module LLM
  class Agent
    module Construction
      module_function

      # Duplicate the plain values used by agent options and Chat messages.
      # Agent options are deliberately not Marshal-copied: they can contain
      # Procs and other executable objects.
      def duplicate(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), copy|
            copy[duplicate(key)] = duplicate(item)
          end
        when Array
          value.collect { |item| duplicate(item) }
        when String
          value.dup
        else
          value
        end
      end

      def chat_copy(chat)
        Chat.setup(duplicate(chat || []))
      end

      # Clone an already-resolved template without sharing mutable seed,
      # option, society, or live-conversation state.
      def clone_agent(template)
        agent = template.clone
        agent.start_chat = chat_copy(template.start_chat)
        agent.other_options = IndiferentHash.setup(duplicate(template.other_options || {}))
        agent.society = nil
        agent.chats = nil
        agent.instance_variable_set(:@current_chat, nil)
        agent
      end

      # Construct the live agent after the caller has finished composing its
      # policy-specific seed. Anchoring and job attachment happen before the
      # first start/chat operation, preserving auto-save and provenance.
      def build(template, seed:, anchor: nil, job: nil)
        agent = clone_agent(template)
        agent.save_file = anchor unless anchor.nil?
        agent.job = job unless job.nil?
        agent.start(chat_copy(seed))
        agent
      end
    end
  end
end
