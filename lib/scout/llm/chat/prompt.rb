module Chat

  DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools)
  DEFAULT_SHORT_STRING_LENGTH = 200
  DEFAULT_SHORT_JSON_LENGTH = 2000

  DEFAULT_FULL_TOOL_CALLS = 10
  DEFAULT_MAX_TOOL_CALLS = 40
  DEFAULT_MAX_TOOL_OUTPUTS = DEFAULT_MAX_TOOL_CALLS
  DEFAULT_MAX_TOOL_CHARS = 100_000

  def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH, warning = 'Truncated')
    new = Log.truncate_string(string, DEFAULT_SHORT_STRING_LENGTH)
    if new.length < string.length
      new = "#{warning} (#{string.length}): " + new
    end
    new
  end

  def self.full_tool_calls
    @@full_tool_calls ||= Scout::Config.get(:full_tool_calls, :prompt, :context, env: 'FULL_TOOL_CALLS')
  end

  def self.max_tool_calls
    @@max_tool_calls ||= Scout::Config.get(:max_tool_calls, :prompt, :context, env: 'MAX_TOOL_CALLS')
  end

  def self.max_tool_outputs
    @@max_tool_outputs ||= Scout::Config.get(:max_tool_outputs, :prompt, :context, env: 'MAX_TOOL_OUTPUTS', default: max_tool_calls)
  end

  def self.max_tool_chars
    @@max_tool_chars ||= Scout::Config.get(:max_tool_chars, :prompt, :context, env: 'MAX_TOOL_CHARS')
  end

  def self.shorten_tools(messages)
    tool_ids = []
    tool_chars = 0
    user_messages = 0
    assistant_messages = 0

    full_tool_calls = self.full_tool_calls || DEFAULT_FULL_TOOL_CALLS
    max_tool_calls = self.max_tool_calls || DEFAULT_MAX_TOOL_CALLS
    max_tool_outputs = self.max_tool_outputs || DEFAULT_MAX_TOOL_OUTPUTS
    max_tool_chars = self.max_tool_chars || DEFAULT_MAX_TOOL_CHARS

    full_tool_calls = full_tool_calls.to_i
    max_tool_calls = max_tool_calls.to_i
    max_tool_outputs = max_tool_outputs.to_i
    max_tool_chars = max_tool_chars.to_i

    messages.reverse.collect do |msg|
      case msg[:role].to_sym
      when :function_call
        json = msg[:content]
        next msg unless json

        tool_call = JSON.parse json
        name, arguments, id = tool_call.values_at 'name', 'arguments', 'id'

        if tool_ids.length < full_tool_calls || user_messages == 0 || tool_chars < max_tool_chars
          tool_chars += json.length
          msg
        elsif tool_ids.length > max_tool_calls
          Log.medium "Skipped tool call #{id} #{name} #{json.length}"
          next
        else
          new_arguments = {}
          arguments.each do |k,v|
            new_arguments[k] = String === v ? shorten_string(v) : v
          end if arguments

          next msg if arguments.values == new_arguments.values

          tool_call['arguments'] = new_arguments
          json = tool_call.to_json
          tool_chars += json.length
          Log.medium "Truncated tool call #{id} #{name} #{msg[:content].length} to #{json.length}"
          msg = msg.dup
          msg[:content] = json
          msg
        end
      when :function_call_output
        json = msg[:content]
        next msg unless json

        tool_call = JSON.parse json
        name, content, id = tool_call.values_at 'name', 'content', 'id'
        tool_ids << id

        if tool_ids.length < full_tool_calls || user_messages == 0 || tool_chars < max_tool_chars
          tool_chars += json.length
          msg
        elsif tool_ids.length > max_tool_outputs
          Log.medium "Skipped tool output #{id} #{name} #{json.length}"
          next 
        else
          tool_call['content'] = shorten_string(content, DEFAULT_SHORT_STRING_LENGTH*2)
          next msg if content == tool_call['content']
          json = tool_call.to_json
          tool_chars += json.length
          Log.medium "Truncated tool output #{id} #{name} #{msg[:content].length} to #{json.length}"
          msg = msg.dup
          msg[:content] = json
          msg
        end
      when :user
        user_messages += 1
        msg
      when :assistant
        assistant_messages += 1
        msg
      else
        msg
      end
    end.compact.reverse
  end

  def self.prepare_prompt(prompt, prompt_strategies = nil)
    return prompt_strategies.call(prompt) if Proc === prompt_strategies
    prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
    prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies
    prompt_strategies.each do |strategy|
      prompt = case strategy
               when 'shorten_tools'
                 Chat.shorten_tools(prompt)
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
