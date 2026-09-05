require_relative 'prompt/shorten_tools'
require_relative 'prompt/shorten_tools_epoch'
require_relative 'prompt/shorten_tools_epoch_increment'
require_relative 'prompt/inbox'

module Chat

  REGISTERED_STRATEGIES = {}
  DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools_epoch_increment inbox)
  DEFAULT_SHORT_STRING_LENGTH = 200
  DEFAULT_SHORT_JSON_LENGTH = 2000

  # --- Shared utility used by all strategies ---

  def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH, step: nil)
    new = Log.truncate_string(string, size)
    if new.length < string.length
      new = ['CONTEXT-COMPACTED', 'Historical account compacted for context efficiency; it does not faithfully represent what happened',  "Original content length: #{string.length}"]
      if step
        new << "Full output found in job: #{step}"
      end
      new << 'Do not execute, copy or otherwise use this string as-is.'
      new << "Preview: <<#{new}>>"
      new = "[#{new * ' - '}]"
    end
    new
  end

  # --- Prompt strategy dispatcher ---

  # `save_file` is an optional chat-level context: the file the chat is saved
  # to, from which a strategy derives the chat files dir. It is forwarded
  # arity-aware, so strategies declared with a single `messages` argument
  # (all of the shorten_* strategies) are unaffected by this signature
  # extension; only strategies that accept the keyword (e.g. `inbox`) receive
  # it. The Proc form gets the full prompt only, as before.
  def self.prepare_prompt(prompt, prompt_strategies = nil, save_file: nil)
    return prompt_strategies.call(prompt) if Proc === prompt_strategies
    prompt_strategies = Scout::Config.get(:prompt_strategies, :chat, :scout_ai, env:'PROMPT_STRATEGY', default: DEFAULT_CONTEXT_STRATEGY) if prompt_strategies.nil?
    prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies
    prompt_strategies.each do |strategy|
      prompt = case strategy
               when 'shorten_tools'
                 Chat.shorten_tools(prompt)
               when 'shorten_tools_epoch'
                 Chat.shorten_tools_epoch(prompt)
               when 'shorten_tools_epoch_increment'
                 Chat.shorten_tools_epoch_increment(prompt)
               when 'inbox'
                 Chat.inbox(prompt, save_file: save_file)
               when 'none'
                 prompt
               else
                 strategy_proc = REGISTERED_STRATEGIES[strategy]
                 if strategy_proc
                   strategy_proc.call(prompt)
                 else
                   Chat.send(strategy.to_sym, prompt)
                 end
               end
    end
    return prompt
  end
end
