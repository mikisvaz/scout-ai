require 'json'
require 'set'

module Chat

  # --- shorten_tools_epoch_increment strategy configuration ---

  # Existing epoch configuration is reused for the threshold, fidelity
  # windows, and initial epoch size. This makes switching from
  # shorten_tools_epoch to shorten_tools_epoch_increment less surprising.

  # Total tool-call count at or below which no compaction happens.
  DEFAULT_EPOCH_INCREMENT_TOOL_CALL_THRESHOLD = 50

  # Number of most-recent calls before the current epoch to keep at full
  # fidelity.
  DEFAULT_EPOCH_INCREMENT_FULL_TOOL_CALLS = 20

  # Initial number of calls before the full window to compact.
  DEFAULT_EPOCH_INCREMENT_COMPACTED_TOOL_CALLS = 80

  # Initial epoch size. This uses the existing EPOCH_SIZE setting.
  DEFAULT_EPOCH_INCREMENT_INITIAL_SIZE = 20

  # Grow the epoch after this many completed epochs.
  DEFAULT_EPOCH_INCREMENT_EPOCHS_PER_INCREASE = 3

  # Regular periodic epoch-size increase.
  DEFAULT_EPOCH_INCREMENT_SIZE_INCREASE = 10

  # Epoch-size increase caused by an epoch containing one or more repeated
  # calls. Only one repeat increase is applied per epoch.
  DEFAULT_EPOCH_INCREMENT_REPEAT_INCREASE = 10

  # Upper bound for both periodic and repeat-driven epoch growth.
  DEFAULT_EPOCH_INCREMENT_MAX_SIZE = 60

  # For each additional call in the effective epoch size, retain this many
  # additional older calls in compacted form rather than removing them.
  #
  # With the defaults:
  #
  #   epoch 20 -> compacted 80
  #   epoch 30 -> compacted 100
  #   epoch 40 -> compacted 120
  #   epoch 50 -> compacted 140
  #   epoch 60 -> compacted 160
  #
  DEFAULT_EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO = 2.0

  # Upper bound for the dynamically grown compacted window.
  DEFAULT_EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS = 160

  # --- configuration accessors ---

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

  # --- canonical repeated-call detection ---

  # Recursively normalize values so hashes with differently ordered or
  # symbol/string keys produce the same canonical representation.
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

  # The generated call ID is excluded because it changes between inferences.
  def self.epoch_increment_dedup_key(name, arguments)
    normalized = epoch_increment_sort_value(arguments || {})
    "#{name}\x00#{JSON.generate(normalized)}"
  rescue StandardError
    "#{name}\x00#{arguments.inspect}"
  end

  def self.epoch_increment_parse_tool_json(json)
    return nil if json.nil?

    JSON.parse(json)
  rescue JSON::ParserError, TypeError
    nil
  end

  # --- variable epoch schedule ---

  #
  # The nominal size of an epoch is:
  #
  #   initial_size
  #     + (completed_epoch_index / epochs_per_increase) * size_increase
  #     + completed_repeat_epochs * repeat_increase
  #
  # If the current epoch's nominal portion contains a repeated call, that
  # epoch is immediately extended by repeat_increase. Once that epoch
  # completes, its repeat increase becomes part of subsequent epoch sizes.
  #
  # Only the nominal, not-yet-extended portion of an epoch can initially
  # trigger its extension. This prevents a call beyond the old endpoint from
  # retroactively moving an already-observed boundary. Such a call belongs
  # to the next epoch instead.
  #
  # Multiple repeated calls in one epoch result in only one increase.
  #
  def self.build_epoch_increment_schedule(
    total_tool_outputs,
    threshold,
    repeated_forward_positions,
    initial_size:,
    epochs_per_increase:,
    size_increase:,
    repeat_increase:,
    max_size:
  )
    pinned_total = threshold
    epoch_index = 0
    completed_repeat_epochs = 0

    repeated_positions = repeated_forward_positions.sort
    repeat_cursor = 0

    loop do
      periodic_increases =
        if epochs_per_increase > 0
          epoch_index / epochs_per_increase
        else
          0
        end

      nominal_size =
        initial_size +
        (periodic_increases * size_increase) +
        (completed_repeat_epochs * repeat_increase)

      nominal_size = [nominal_size, max_size].min

      # Skip repeats belonging to previously completed epochs.
      while repeat_cursor < repeated_positions.length &&
            repeated_positions[repeat_cursor] <= pinned_total
        repeat_cursor += 1
      end

      nominal_visible_end = [
        pinned_total + nominal_size,
        total_tool_outputs
      ].min

      repeat_detected =
        repeat_cursor < repeated_positions.length &&
        repeated_positions[repeat_cursor] <= nominal_visible_end

      current_epoch_size = nominal_size

      if repeat_detected
        current_epoch_size = [
          current_epoch_size + repeat_increase,
          max_size
        ].min
      end

      # Calls in the current epoch are numbered 1..current_epoch_size.
      # The next epoch starts only after the current one is full.
      if total_tool_outputs <= pinned_total + current_epoch_size
        return {
          epoch_index: epoch_index,
          pinned_total: pinned_total,
          new_calls: total_tool_outputs - pinned_total,
          nominal_size: nominal_size,
          epoch_size: current_epoch_size,
          periodic_increases: periodic_increases,
          completed_repeat_epochs: completed_repeat_epochs,
          repeat_detected: repeat_detected
        }
      end

      pinned_total += current_epoch_size
      completed_repeat_epochs += 1 if repeat_detected
      epoch_index += 1
    end
  end

  # --- repeated-call pre-pass ---

  #
  # Returns:
  #
  #   protected_positions
  #     Reverse positions, one-based from the newest call, for the most recent
  #     instance of each repeated call. These calls are retained in full.
  #
  #   repeated_forward_positions
  #     Forward positions of every occurrence after the first occurrence of a
  #     canonical name/arguments pair. These positions drive epoch growth.
  #
  # Tool outputs define completed-call positions. A function_call is paired
  # with its output using the generated ID, but the ID is not part of the
  # repeated-call key.
  #
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
        # Position counting includes every output so it remains aligned with
        # total_tool_outputs, even when malformed messages are retained.
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

      # Every occurrence after the first is a repeat event.
      positions.drop(1).each do |position|
        repeated_forward_positions << position
      end

      # Only the most recent instance needs full-fidelity protection.
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

  # --- shorten_tools_epoch_increment strategy implementation ---

  #
  # Cache-friendly variable-epoch version of shorten_tools.
  #
  # Within an epoch, pinned_total is fixed. Calls arriving after pinned_total
  # are retained at full fidelity, so the compacted prefix remains stable.
  #
  # Layout, newest at the bottom:
  #
  #   [ dropped ]        calls older than the effective compacted window
  #   [ compacted ]      a window that grows with the epoch size
  #   [ full-recent ]    epoch_increment_full_tool_calls
  #   [ full-new ]       calls after pinned_total
  #
  # The effective compacted window is:
  #
  #   base_compacted
  #     + ((current_epoch_size - initial_epoch_size) * growth_ratio)
  #
  # capped by epoch_increment_max_compacted_tool_calls.
  #
  # This means periodic growth and repeat-triggered epoch growth both retain
  # additional older calls in compacted form instead of removing them.
  #
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

    # Preserve the fixed-epoch strategy's ability to disable itself with a
    # non-positive EPOCH_SIZE.
    return messages if initial_size <= 0

    # Configured maximums below their initial values must not shrink the
    # initial windows.
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

    # Grow the compacted window whenever the effective epoch size grows.
    #
    # A repeat-triggered extension therefore immediately restores some older
    # calls as compacted context, assuming this strategy receives the original
    # unmodified conversation history on each invocation.
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

    # From the end:
    #
    #   1..new_calls
    #     Full calls arriving during the current epoch.
    #
    #   new_calls+1..new_calls+full
    #     Full calls immediately preceding the current epoch.
    #
    #   new_calls+full+1..
    #     new_calls+full+effective_compacted
    #     Dynamically sized compacted-call window.
    #
    #   Anything older
    #     Dropped unless it is the protected latest repeated instance.
    #
    keep_full_count = new_calls + full
    truncate_to = keep_full_count + effective_compacted

    # One-based completed-tool-call position from the newest call.
    # It is incremented before output parsing so malformed outputs still
    # occupy the same position counted by total_tool_outputs.
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
          # Current epoch, recent window, or protected repeated call.
          kept_messages << msg

        elsif tool_position <= truncate_to
          new_content = shorten_string(
            content.to_s,
            DEFAULT_SHORT_STRING_LENGTH * 2,
            step: step
          )

          if new_content != content
            tool_call['content'] = new_content
            new_json = tool_call.to_json

            Log.low(
              "Epoch increment: truncated tool output " \
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

        # Under the normal call/output ordering, the paired output has already
        # been encountered during this reverse traversal, so tool_position is
        # the position shared by the call and its output.
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
        # Assistant, system, user, meta, and other non-tool messages.
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
          Compacted content is shown as '[CONTEXT-COMPACTED ...]'.

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
        # Preserves the placement behavior of shorten_tools_epoch.
        kept_messages.insert(index + 1, compaction_message)
      else
        kept_messages << compaction_message
      end
    end

    Chat.setup(kept_messages)
  end
end
