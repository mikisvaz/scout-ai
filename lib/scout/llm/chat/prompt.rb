require_relative 'prompt/shorten_tools'
require_relative 'prompt/shorten_tools_epoch'

module Chat

  REGISTERED_STRATEGIES = {}
  DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools_epoch)
  DEFAULT_SHORT_STRING_LENGTH = 200
  DEFAULT_SHORT_JSON_LENGTH = 2000

  # --- Shared utility used by all strategies ---

  def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH, warning = 'Truncated')
    new = Log.truncate_string(string, size)
    if new.length < string.length
      new = "#{warning} (#{string.length}): " + new
    end
    new
  end

  # --- Prompt strategy dispatcher ---

  def self.prepare_prompt(prompt, prompt_strategies = nil)
    return prompt_strategies.call(prompt) if Proc === prompt_strategies
    prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
    prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies
    prompt_strategies.each do |strategy|
      prompt = case strategy
               when 'shorten_tools'
                 Chat.shorten_tools(prompt)
               when 'shorten_tools_epoch'
                 Chat.shorten_tools_epoch(prompt)
               when 'none'
                 prompt
               else
                 strategy_proc = REGISTERED_STRATEGIES[strategy]
                 strategy_proc.call(prompt)
               end
    end
    return prompt
  end
end
