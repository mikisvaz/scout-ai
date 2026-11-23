require 'set'
require_relative 'epoch_tool_compactation'

module Chat
  # shorten_tools
  DEFAULT_FULL_TOOL_CALLS = 0
  DEFAULT_FULL_TOOL_OUTPUTS = 10
  DEFAULT_MAX_TOOL_CALLS = 40
  DEFAULT_MAX_TOOL_OUTPUTS = DEFAULT_MAX_TOOL_CALLS
  DEFAULT_MAX_TOOL_CHARS = 100_000

  def self.full_tool_calls
    @@full_tool_calls ||= Scout::Config.get(:full_tool_calls, :prompt, :context, env: 'FULL_TOOL_CALLS')
  end

  def self.full_tool_outputs
    @@full_tool_outputs ||= Scout::Config.get(:full_tool_outputs, :prompt, :context, env: 'FULL_TOOL_OUTPUTS')
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
    user_messages = 1
    assistant_messages = 0

    full_tool_calls = self.full_tool_calls || DEFAULT_FULL_TOOL_CALLS
    full_tool_outputs = self.full_tool_outputs || DEFAULT_FULL_TOOL_OUTPUTS
    max_tool_calls = self.max_tool_calls || DEFAULT_MAX_TOOL_CALLS
    max_tool_outputs = self.max_tool_outputs || DEFAULT_MAX_TOOL_OUTPUTS
    max_tool_chars = self.max_tool_chars || DEFAULT_MAX_TOOL_CHARS

    full_tool_calls = full_tool_calls.to_i
    full_tool_outputs = full_tool_outputs.to_i
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

        if tool_ids.length < full_tool_outputs || user_messages == 0 || tool_chars < max_tool_chars
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

  # shorten_tools_epoch
  DEFAULT_EPOCH_TOOL_CALL_THRESHOLD = 50

  DEFAULT_EPOCH_FULL_TOOL_CALLS = 20

  DEFAULT_EPOCH_COMPACTED_TOOL_CALLS = 80

  DEFAULT_EPOCH_SIZE = 20

  def self.epoch_tool_call_threshold
    @@epoch_tool_call_threshold ||= Scout::Config.get(:epoch_tool_call_threshold, :prompt, :context,
      env: 'EPOCH_TOOL_CALL_THRESHOLD', default: DEFAULT_EPOCH_TOOL_CALL_THRESHOLD)
  end

  def self.epoch_full_tool_calls
    @@epoch_full_tool_calls ||= Scout::Config.get(:epoch_full_tool_calls, :prompt, :context,
      env: 'EPOCH_FULL_TOOL_CALLS', default: DEFAULT_EPOCH_FULL_TOOL_CALLS)
  end

  def self.epoch_compacted_tool_calls
    @@epoch_compacted_tool_calls ||= Scout::Config.get(:epoch_compacted_tool_calls, :prompt, :context,
      env: 'EPOCH_COMPACTED_TOOL_CALLS', default: DEFAULT_EPOCH_COMPACTED_TOOL_CALLS)
  end

  def self.epoch_size
    @@epoch_size ||= Scout::Config.get(:epoch_size, :prompt, :context,
      env: 'EPOCH_SIZE', default: DEFAULT_EPOCH_SIZE)
  end

  def self.epoch_sort_value(obj)
    case obj
    when Hash
      obj.transform_keys(&:to_s).sort.to_h.transform_values { |v| epoch_sort_value(v) }
    when Array
      obj.map { |v| epoch_sort_value(v) }
    else
      obj
    end
  end

  def self.epoch_dedup_key(name, arguments)
    normalized = epoch_sort_value(arguments || {})
    "#{name}\x00#{JSON.generate(normalized)}"
  rescue
    "#{name}\x00#{arguments.inspect}"
  end

  def self.shorten_tools_epoch(messages)
    threshold = (self.epoch_tool_call_threshold || DEFAULT_EPOCH_TOOL_CALL_THRESHOLD).to_i
    full      = (self.epoch_full_tool_calls      || DEFAULT_EPOCH_FULL_TOOL_CALLS).to_i
    compacted = (self.epoch_compacted_tool_calls || DEFAULT_EPOCH_COMPACTED_TOOL_CALLS).to_i
    epoch_sz  = (self.epoch_size                 || DEFAULT_EPOCH_SIZE).to_i

    total_tool_outputs = messages.count { |m| m[:role].to_sym == :function_call_output }

    return messages if total_tool_outputs <= threshold
    return messages if full == 0 && compacted == 0
    return messages if epoch_sz <= 0

    overflow     = total_tool_outputs - threshold
    epoch_idx    = overflow > 0 ? (overflow - 1) / epoch_sz : 0
    pinned_total = threshold + (epoch_idx * epoch_sz)

    new_calls = total_tool_outputs - pinned_total

    keep_full_count = new_calls + full
    truncate_to     = keep_full_count + compacted

    protected_positions = build_protected_positions(messages, total_tool_outputs)

    tool_ids = []

    kept_messages = []
    dropped_count = 0
    compacted_count = 0

    messages.reverse.each do |msg|
      case msg[:role].to_sym
      when :function_call_output
        json = msg[:content]
        if json.nil?
          kept_messages << msg
          next
        end

        tool_call = JSON.parse json rescue nil
        unless tool_call
          kept_messages << msg
          next
        end

        name, content, id, step = tool_call.values_at 'name', 'content', 'id', 'step'
        tool_ids << id   # increment BEFORE check (mirrors original shorten_tools)

        if tool_ids.length <= keep_full_count || protected_positions.include?(tool_ids.length)
          kept_messages << msg
        elsif tool_ids.length <= truncate_to
          new_content = shorten_string(content.to_s, DEFAULT_SHORT_STRING_LENGTH * 2, step: step)
          if new_content != content
            tool_call['content'] = new_content
            new_json = tool_call.to_json
            Log.low "Epoch: truncated tool output #{id} #{name} #{json.length} to #{new_json.length}"
            new_msg = msg.dup
            new_msg[:content] = new_json
            new_msg[:compacted] = true
            kept_messages << new_msg
            compacted_count += 1
          else
            kept_messages << msg
          end
        else
          Log.low "Epoch: dropped tool output #{id} #{name} #{json.length}"
          dropped_count += 1
        end

      when :function_call
        json = msg[:content]
        if json.nil?
          kept_messages << msg
          next
        end

        tool_call = JSON.parse json rescue nil
        unless tool_call
          kept_messages << msg
          next
        end

        name, arguments, id = tool_call.values_at 'name', 'arguments', 'id'

        if tool_ids.length <= keep_full_count || protected_positions.include?(tool_ids.length)
          kept_messages << msg
        elsif tool_ids.length <= truncate_to
          if arguments && arguments.any?
            new_arguments = {}
            arguments.each do |k, v|
              new_arguments[k] = String === v ? shorten_string(v) : v
            end
            if arguments.values != new_arguments.values
              tool_call['arguments'] = new_arguments
              new_json = tool_call.to_json
              Log.low "Epoch: truncated tool call #{id} #{name} #{json.length} to #{new_json.length}"
              new_msg = msg.dup
              new_msg[:content] = new_json
              new_msg[:compacted] = true
              kept_messages << new_msg
              compacted_count += 1
            else
              kept_messages << msg
            end
          else
            kept_messages << msg
          end
        else
          Log.low "Epoch: dropped tool call #{id} #{name} #{json.length}"
          dropped_count += 1
        end
      else
        kept_messages << msg
      end
    end

    kept_messages = kept_messages.reverse

	if dropped_count > 0 || compacted_count > 0
      Log.medium "Epoch strategy: pinned_total=#{pinned_total} new_calls=#{new_calls} " \
        "full=#{full} compacted=#{compacted} truncated=#{compacted_count} dropped=#{dropped_count} " \
        "protected=#{protected_positions.length}"

	  compaction_message = {
		role: :user,
		content: <<~TEXT.chomp
	  === Context Management ===

      To fit within the model context window, this conversation has been
      compacted: some tool calls arguments and tool call outputs are shown with
      compacted content, and some have been hidden entirely. Compacted content
      is show as '[#{COMPACTATION_MESSAGE} ...]'. Don't try to reconstruct what
      happened involving tools that have been compacted.

      Remember that the real tool call did not suffer any compactation at the
      time it was issued, it's only compacted in the current context.

      Compacted: #{compacted_count}
      Removed: #{dropped_count}
      
      Earlier tool results may no longer be present in the visible conversation
      history. If information appears to be missing, it may have been removed
      during context compaction rather than never existing. The absence of an
      earlier tool result in the current conversation does not necessarily mean
      that the tool has not already been executed. And care must be had accessing
      older tool calls which may be compacted.

      Repeated tool calls with the same arguments will be flagged and the very
      last instance will be protected from removal or compactation.
        TEXT
	  }

      index = kept_messages.index do |msg|
        [:function_call, :function_call_output].include?(msg[:role].to_sym)
      end

      if index
        kept_messages.insert(index + 1, compaction_message)
      else
        kept_messages << compaction_message
      end
    end

    Chat.setup(kept_messages)
  end

  def self.build_protected_positions(messages, total_tool_outputs)
    protected = Set.new

    fwd_pos = 0
    pending_call_keys = {}  # id → dedup_key (set by function_call, consumed by output)
    key_positions = Hash.new { |h, k| h[k] = [] }

    messages.each do |msg|
      case msg[:role].to_sym
      when :function_call
        json = msg[:content]
        next unless json
        tool_call = JSON.parse json rescue nil
        next unless tool_call
        name      = tool_call['name']
        arguments = tool_call['arguments']
        id        = tool_call['id']
        pending_call_keys[id] = Chat.epoch_dedup_key(name, arguments)
      when :function_call_output
        json = msg[:content]
        next unless json
        tool_call = JSON.parse json rescue nil
        next unless tool_call
        fwd_pos += 1
        id   = tool_call['id']
        key  = pending_call_keys.delete(id)
        next unless key
        key_positions[key] << fwd_pos
      end
    end

    key_positions.each do |key, positions|
      next if positions.length <= 1
      most_recent_fwd = positions.max
      reverse_pos     = total_tool_outputs - most_recent_fwd + 1
      protected << reverse_pos
    end

    unless protected.empty?
      Log.low "Epoch: protecting #{protected.length} repeated call(s) from dropping"
    end

    protected
  end

  # shorten_tools_epoch_increment
  DEFAULT_EPOCH_INCREMENT_TOOL_CALL_THRESHOLD = 50

  DEFAULT_EPOCH_INCREMENT_FULL_TOOL_CALLS = 20

  DEFAULT_EPOCH_INCREMENT_COMPACTED_TOOL_CALLS = 80

  DEFAULT_EPOCH_INCREMENT_INITIAL_SIZE = 20

  DEFAULT_EPOCH_INCREMENT_EPOCHS_PER_INCREASE = 3

  DEFAULT_EPOCH_INCREMENT_SIZE_INCREASE = 10

  DEFAULT_EPOCH_INCREMENT_REPEAT_INCREASE = 10

  DEFAULT_EPOCH_INCREMENT_MAX_SIZE = 60

  DEFAULT_EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO = 2.0

  DEFAULT_EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS = 160

  def self.epoch_increment_tool_call_threshold
    @@epoch_increment_tool_call_threshold ||= Scout::Config.get(
      :epoch_tool_call_threshold, :prompt, :context,
      env: 'EPOCH_TOOL_CALL_THRESHOLD',
      default: DEFAULT_EPOCH_INCREMENT_TOOL_CALL_THRESHOLD
    )
  end

  def self.epoch_increment_full_tool_calls
    @@epoch_increment_full_tool_calls ||= Scout::Config.get(
      :epoch_full_tool_calls, :prompt, :context,
      env: 'EPOCH_FULL_TOOL_CALLS',
      default: DEFAULT_EPOCH_INCREMENT_FULL_TOOL_CALLS
    )
  end

  def self.epoch_increment_compacted_tool_calls
    @@epoch_increment_compacted_tool_calls ||= Scout::Config.get(
      :epoch_compacted_tool_calls, :prompt, :context,
      env: 'EPOCH_COMPACTED_TOOL_CALLS',
      default: DEFAULT_EPOCH_INCREMENT_COMPACTED_TOOL_CALLS
    )
  end

  def self.epoch_increment_initial_size
    @@epoch_increment_initial_size ||= Scout::Config.get(
      :epoch_size, :prompt, :context,
      env: 'EPOCH_SIZE',
      default: DEFAULT_EPOCH_INCREMENT_INITIAL_SIZE
    )
  end

  def self.epoch_increment_epochs_per_increase
    @@epoch_increment_epochs_per_increase ||= Scout::Config.get(
      :epoch_increment_epochs_per_increase, :prompt, :context,
      env: 'EPOCH_INCREMENT_EPOCHS_PER_INCREASE',
      default: DEFAULT_EPOCH_INCREMENT_EPOCHS_PER_INCREASE
    )
  end

  def self.epoch_increment_size_increase
    @@epoch_increment_size_increase ||= Scout::Config.get(
      :epoch_increment_size_increase, :prompt, :context,
      env: 'EPOCH_INCREMENT_SIZE_INCREASE',
      default: DEFAULT_EPOCH_INCREMENT_SIZE_INCREASE
    )
  end

  def self.epoch_increment_repeat_increase
    @@epoch_increment_repeat_increase ||= Scout::Config.get(
      :epoch_increment_repeat_increase, :prompt, :context,
      env: 'EPOCH_INCREMENT_REPEAT_INCREASE',
      default: DEFAULT_EPOCH_INCREMENT_REPEAT_INCREASE
    )
  end

  def self.epoch_increment_max_size
    @@epoch_increment_max_size ||= Scout::Config.get(
      :epoch_increment_max_size, :prompt, :context,
      env: 'EPOCH_INCREMENT_MAX_SIZE',
      default: DEFAULT_EPOCH_INCREMENT_MAX_SIZE
    )
  end

  def self.epoch_increment_compacted_growth_ratio
    @@epoch_increment_compacted_growth_ratio ||= Scout::Config.get(
      :epoch_increment_compacted_growth_ratio, :prompt, :context,
      env: 'EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO',
      default: DEFAULT_EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO
    )
  end

  def self.epoch_increment_max_compacted_tool_calls
    @@epoch_increment_max_compacted_tool_calls ||= Scout::Config.get(
      :epoch_increment_max_compacted_tool_calls, :prompt, :context,
      env: 'EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS',
      default: DEFAULT_EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS
    )
  end

  def self.epoch_increment_sort_value(obj)
    case obj
    when Hash
      normalized = {}

      obj.each do |key, value|
        normalized[key.to_s] = epoch_increment_sort_value(value)
      end

      normalized.sort.to_h
    when Array
      obj.map { |value| epoch_increment_sort_value(value) }
    else
      obj
    end
  end

  def self.epoch_increment_dedup_key(name, arguments)
    normalized = epoch_increment_sort_value(arguments || {})
    "#{name}\x00#{JSON.generate(normalized)}"
  rescue StandardError
    "#{name}\x00#{arguments.inspect}"
  end

  def self.epoch_increment_parse_tool_json(json)
    return nil if json.nil?

    IndiferentHash.setup(JSON.parse(json))
  rescue JSON::ParserError, TypeError
    nil
  end

  def self.build_epoch_increment_repeat_data(messages, total_tool_outputs)
    protected_positions = Set.new
    repeated_forward_positions = Set.new

    forward_position = 0
    pending_call_keys = {}
    key_positions = Hash.new { |hash, key| hash[key] = [] }

    messages.each do |msg|
      role = msg[:role]
      next unless role

      case role.to_sym
      when :function_call
        tool_call = epoch_increment_parse_tool_json(msg[:content])
        next unless tool_call.is_a?(Hash)

        name = tool_call['name']
        arguments = tool_call['arguments']
        id = tool_call['id']

        pending_call_keys[id] =
          epoch_increment_dedup_key(name, arguments)

      when :function_call_output
        forward_position += 1

        tool_call = epoch_increment_parse_tool_json(msg[:content])
        next unless tool_call.is_a?(Hash)

        id = tool_call['id']
        key = pending_call_keys.delete(id)
        next unless key

        key_positions[key] << forward_position
      end
    end

    key_positions.each_value do |positions|
      next if positions.length <= 1

      positions.drop(1).each do |position|
        repeated_forward_positions << position
      end

      most_recent_forward = positions.last
      reverse_position =
        total_tool_outputs - most_recent_forward + 1

      protected_positions << reverse_position
    end

    unless protected_positions.empty?
      Log.low(
        "Epoch increment: protecting " \
        "#{protected_positions.length} repeated call(s)"
      )
    end

    {
      protected_positions: protected_positions,
      repeated_forward_positions: repeated_forward_positions.to_a.sort
    }
  end

  def self.shorten_tools_epoch_increment(messages)
    threshold = [
      (
        self.epoch_increment_tool_call_threshold ||
        DEFAULT_EPOCH_INCREMENT_TOOL_CALL_THRESHOLD
      ).to_i,
      0
    ].max

    full = [
      (
        self.epoch_increment_full_tool_calls ||
        DEFAULT_EPOCH_INCREMENT_FULL_TOOL_CALLS
      ).to_i,
      0
    ].max

    base_compacted = [
      (
        self.epoch_increment_compacted_tool_calls ||
        DEFAULT_EPOCH_INCREMENT_COMPACTED_TOOL_CALLS
      ).to_i,
      0
    ].max

    initial_size = (
      self.epoch_increment_initial_size ||
      DEFAULT_EPOCH_INCREMENT_INITIAL_SIZE
    ).to_i

    epochs_per_increase = (
      self.epoch_increment_epochs_per_increase ||
      DEFAULT_EPOCH_INCREMENT_EPOCHS_PER_INCREASE
    ).to_i

    size_increase = [
      (
        self.epoch_increment_size_increase ||
        DEFAULT_EPOCH_INCREMENT_SIZE_INCREASE
      ).to_i,
      0
    ].max

    repeat_increase = [
      (
        self.epoch_increment_repeat_increase ||
        DEFAULT_EPOCH_INCREMENT_REPEAT_INCREASE
      ).to_i,
      0
    ].max

    configured_max_size = (
      self.epoch_increment_max_size ||
      DEFAULT_EPOCH_INCREMENT_MAX_SIZE
    ).to_i

    compacted_growth_ratio = (
      self.epoch_increment_compacted_growth_ratio ||
      DEFAULT_EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO
    ).to_f

    unless compacted_growth_ratio.finite? &&
           compacted_growth_ratio >= 0.0
      compacted_growth_ratio = 0.0
    end

    configured_max_compacted = (
      self.epoch_increment_max_compacted_tool_calls ||
      DEFAULT_EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS
    ).to_i

    return messages if initial_size <= 0

    max_size = [configured_max_size, initial_size].max

    max_compacted = [
      configured_max_compacted,
      base_compacted
    ].max

    total_tool_outputs = messages.count do |msg|
      role = msg[:role]
      role && role.to_sym == :function_call_output
    end

    return messages if total_tool_outputs <= threshold
    return messages if full.zero? && base_compacted.zero?

    repeat_data = build_epoch_increment_repeat_data(
      messages,
      total_tool_outputs
    )

    protected_positions = repeat_data[:protected_positions]

    schedule = build_epoch_increment_schedule(
      total_tool_outputs,
      threshold,
      repeat_data[:repeated_forward_positions],
      initial_size: initial_size,
      epochs_per_increase: epochs_per_increase,
      size_increase: size_increase,
      repeat_increase: repeat_increase,
      max_size: max_size
    )

    pinned_total = schedule[:pinned_total]
    new_calls = schedule[:new_calls]

    epoch_size_growth = [
      schedule[:epoch_size] - initial_size,
      0
    ].max

    compacted_growth = (
      epoch_size_growth * compacted_growth_ratio
    ).round

    effective_compacted = [
      base_compacted + compacted_growth,
      max_compacted
    ].min

    keep_full_count = new_calls + full
    truncate_to = keep_full_count + effective_compacted

    tool_position = 0

    kept_messages = []
    dropped_count = 0
    compacted_count = 0

    messages.reverse.each do |msg|
      role = msg[:role]

      unless role
        kept_messages << msg
        next
      end

      case role.to_sym
      when :function_call_output
        tool_position += 1

        json = msg[:content]

        if json.nil?
          kept_messages << msg
          next
        end

        tool_call = epoch_increment_parse_tool_json(json)

        unless tool_call.is_a?(Hash)
          kept_messages << msg
          next
        end

        name, content, id, step =
          tool_call.values_at('name', 'content', 'id', 'step')

        if tool_position <= keep_full_count ||
           protected_positions.include?(tool_position)
          kept_messages << msg

        elsif tool_position <= truncate_to
          new_content = shorten_string(
            content.to_s,
            DEFAULT_SHORT_STRING_LENGTH * 2,
            step: step
          )

          if new_content != content
            tool_call['content'] = new_content
            tool_call['name'] =  'compacted-' + tool_call['name']
            new_json = tool_call.to_json

            Log.low(
              "Epoch increment: compacted tool output " \
              "#{id} #{name} #{json.length} to #{new_json.length}"
            )

            new_msg = msg.dup
            new_msg[:content] = new_json
            new_msg[:compacted] = true
            kept_messages << new_msg
            compacted_count += 1
          else
            kept_messages << msg
          end

        else
          Log.low(
            "Epoch increment: dropped tool output " \
            "#{id} #{name} #{json.length}"
          )

          dropped_count += 1
        end

      when :function_call
        json = msg[:content]

        if json.nil?
          kept_messages << msg
          next
        end

        tool_call = epoch_increment_parse_tool_json(json)

        unless tool_call.is_a?(Hash)
          kept_messages << msg
          next
        end

        name, arguments, id =
          tool_call.values_at('name', 'arguments', 'id')

        if tool_position <= keep_full_count ||
           protected_positions.include?(tool_position)
          kept_messages << msg

        elsif tool_position <= truncate_to
          if arguments.is_a?(Hash) && !arguments.empty?
            new_arguments = {}

            arguments.each do |key, value|
              new_arguments[key] =
                value.is_a?(String) ? shorten_string(value) : value
            end

            if new_arguments != arguments
              tool_call['arguments'] = new_arguments
              tool_call['name'] =  'compacted-' + tool_call['name']
              new_json = tool_call.to_json

              Log.low(
                "Epoch increment: truncated tool call " \
                "#{id} #{name} #{json.length} to #{new_json.length}"
              )

              new_msg = msg.dup
              new_msg[:content] = new_json
              new_msg[:compacted] = true
              kept_messages << new_msg
              compacted_count += 1
            else
              kept_messages << msg
            end
          else
            kept_messages << msg
          end

        else
          Log.low(
            "Epoch increment: dropped tool call " \
            "#{id} #{name} #{json.length}"
          )

          dropped_count += 1
        end

      else
        kept_messages << msg
      end
    end

    kept_messages.reverse!

    if dropped_count > 0 || compacted_count > 0
      Log.medium(
        "Epoch increment strategy: " \
        "epoch=#{schedule[:epoch_index]} " \
        "pinned_total=#{pinned_total} " \
        "new_calls=#{new_calls} " \
        "nominal_epoch_size=#{schedule[:nominal_size]} " \
        "epoch_size=#{schedule[:epoch_size]} " \
        "periodic_increases=#{schedule[:periodic_increases]} " \
        "completed_repeat_epochs=#{schedule[:completed_repeat_epochs]} " \
        "repeat_in_epoch=#{schedule[:repeat_detected]} " \
        "full=#{full} " \
        "base_compacted=#{base_compacted} " \
        "compacted_growth=#{compacted_growth} " \
        "effective_compacted=#{effective_compacted} " \
        "truncated=#{compacted_count} " \
        "dropped=#{dropped_count} " \
        "protected=#{protected_positions.length}"
      )

      compaction_message = {
        role: :user,
        content: <<~TEXT.chomp
          === Context Management ===

          To fit within the model context window, this conversation has been
          compacted. Some tool-call arguments and tool-call outputs are shown
          with shortened content, and some have been hidden entirely.
          Compacted content is shown as '[#{COMPACTATION_MESSAGE} ...]'.

          Do not try to reconstruct details that were removed by context
          compaction. The actual tool execution was not compacted when it
          occurred; only its representation in the current context was changed.

          Compacted tool messages: #{compacted_count}
          Removed tool messages: #{dropped_count}

          Earlier tool results may no longer be present in the visible
          conversation. Their absence does not necessarily mean that the tool
          has never been executed.

          Repeated completed tool calls are detected using the tool name and
          canonical arguments, excluding the generated call ID. The most recent
          instance of each repeated call is retained at full fidelity. A repeat
          may also lengthen the current and subsequent cache epochs and retain
          more older calls in compacted form, up to the configured limits.

          Do not repeat a tool call solely because an older occurrence is no
          longer visible.
        TEXT
      }

      index = kept_messages.index do |msg|
        role = msg[:role]

        role &&
          [:function_call, :function_call_output].include?(role.to_sym)
      end

      if index
        kept_messages.insert(index + 1, compaction_message)
      else
        kept_messages << compaction_message
      end
    end

    Chat.setup(kept_messages)
  end
end
