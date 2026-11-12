require 'json'
require 'set'
require_relative 'shorten_tools_epoch_increment'

module Chat

  # Marker for the pairwise tool-compaction strategy. Distinct from
  # COMPACTATION_MESSAGE on purpose: epoch_tool_compactation removes the
  # whole function_call/function_call_output pair and inserts an ordinary
  # user-role metadata record, so its records must not look like the
  # in-place '[CONTEXT-COMPACTED ...]' previews produced by the
  # shorten_tools* strategies.
  TOOL_COMPACTATION_MESSAGE = 'TOOL-COMPACTION-RECORD'

  # Fixed, counter-free global notice. Deterministic text only: per-call
  # counters would change between inferences and defeat prefix caching.
  EPOCH_TOOL_COMPACTATION_NOTICE = {
    role: :user,
    content: <<~TEXT.chomp
      === Context Management ===

      Some older tool interactions are not present in this conversation:
      each had its function_call and function_call_output pair removed and
      replaced either by a short metadata record or by nothing at all. A
      compaction record is metadata about a tool interaction, not its
      result, and never contains the tool output. Recent tool interactions
      are preserved in full.

      Do not treat a compaction record as a tool result. If a value is
      needed, run the tool again.
    TEXT
  }

  # --- pairwise tool compaction helpers ---

  # Whether a paired interaction is oversized, mirroring the rewrite
  # triggers of shorten_tools_epoch_increment exactly:
  #
  #   output side: content.to_s longer than DEFAULT_SHORT_STRING_LENGTH * 2
  #                (the size passed to shorten_string at
  #                shorten_tools_epoch_increment.rb:575-579)
  #
  #   call side:   any argument value that is a String longer than
  #                DEFAULT_SHORT_STRING_LENGTH (the default size of the
  #                per-value shorten_string call at
  #                shorten_tools_epoch_increment.rb:638-640)
  #
  # Non-Hash arguments (including JSON-string arguments) are never
  # oversized on the call side, exactly like the mirrored strategy, which
  # only rewrites Hash argument values.
  def self.epoch_tool_compactation_oversized?(call_parsed, output_parsed)
    output_oversized =
      output_parsed.is_a?(Hash) &&
      output_parsed['content'].to_s.length > DEFAULT_SHORT_STRING_LENGTH * 2

    call_oversized = false

    if call_parsed.is_a?(Hash)
      arguments = call_parsed['arguments']

      if arguments.is_a?(Hash)
        call_oversized = arguments.any? do |_key, value|
          value.is_a?(String) && value.length > DEFAULT_SHORT_STRING_LENGTH
        end
      end
    end

    output_oversized || call_oversized
  end

  # One argument entry of a compaction record. Exact or omitted, nothing in
  # between: a value is emitted verbatim only when it is a short String or
  # a scalar, so no truncated, executable-looking fragment of a long value
  # can ever appear in a record.
  def self.epoch_tool_compactation_argument_line(key, value)
    case value
    when String
      if value.length <= DEFAULT_SHORT_STRING_LENGTH
        "#{key}=#{value}"
      else
        "#{key}=<omitted, #{value.length} chars>"
      end
    when Integer, Float, Symbol, TrueClass, FalseClass, NilClass
      rendered =
        case value
        when NilClass then 'nil'
        when Symbol then value.to_s
        else value.to_s
        end

      "#{key}=#{rendered}"
    else
      text =
        begin
          value.to_json
        rescue StandardError
          value.to_s
        end

      "#{key}=<omitted, #{text.length} chars>"
    end
  end

  # The user-role metadata record that replaces one oversized
  # function_call/function_call_output pair. Contains no substring
  # 'Preview:' and no renaming: the original tool name and call id are
  # reported exactly as they appeared.
  def self.epoch_tool_compactation_record(call_parsed, output_parsed)
    name =
      if call_parsed.is_a?(Hash) && call_parsed['name']
        call_parsed['name']
      else
        'unknown'
      end

    call_id =
      if call_parsed.is_a?(Hash) && call_parsed['id']
        call_parsed['id']
      elsif output_parsed.is_a?(Hash)
        output_parsed['id']
      end

    arguments = call_parsed.is_a?(Hash) ? call_parsed['arguments'] : nil
    content =
      if output_parsed.is_a?(Hash) && output_parsed['content']
        output_parsed['content']
      else
        ''
      end
    step = output_parsed.is_a?(Hash) ? output_parsed['step'] : nil

    argument_chars =
      if arguments.is_a?(Hash)
        begin
          arguments.to_json.length
        rescue StandardError
          arguments.to_s.length
        end
      else
        arguments.to_s.length
      end

    lines = []
    lines << "[#{TOOL_COMPACTATION_MESSAGE}] This is metadata about a removed tool interaction, not a tool result."
    lines << ''
    lines << 'A function_call / function_call_output pair was removed from the conversation at this position.'
    lines << 'The tool was executed when the interaction happened; this record describes it and does not reproduce its output.'
    lines << ''
    lines << "Tool: #{name}"
    lines << "Call id: #{call_id}"
    lines << "Original sizes: arguments #{argument_chars} chars, output #{content.to_s.length} chars"
    lines << 'Arguments:'

    if arguments.is_a?(Hash) && !arguments.empty?
      arguments.each do |key, value|
        lines << "  #{epoch_tool_compactation_argument_line(key, value)}"
      end
    else
      lines << '  (no argument entries recorded)'
    end

    if step && !step.to_s.empty?
      lines << "Full output found in job: #{step}"
    end

    lines << ''
    lines << 'The original pair was removed; this record is metadata, not a tool result. If the value of this interaction is needed, run the tool again.'

    {
      role: :user,
      compacted: true,
      content: lines * "\n"
    }
  end

  # --- epoch_tool_compactation strategy implementation ---

  #
  # Pairwise tool compaction on the epoch_increment schedule.
  #
  # The schedule, windows and early returns are identical to
  # shorten_tools_epoch_increment; only the treatment of the compact band
  # differs. Where the mirrored strategy rewrites an oversized interaction
  # in place (shortened content, 'compacted-' name prefix, and a
  # '[CONTEXT-COMPACTED ...]' preview that models mistake for a real tool
  # result), this strategy removes BOTH messages of the pair and inserts
  # one ordinary user-role metadata record immediately after the position
  # where the pair's function_call_output stood. Inserting after an output
  # is the protocol-safe position in both backends: it never places a user
  # message between a function_call and its own function_call_output.
  #
  # Interactions older than the effective compacted window are dropped
  # entirely, exactly like the mirrored strategy.
  #
  def self.epoch_tool_compactation(messages, 
                                   threshold: nil, full: nil, base_compacted: nil, initial_size: nil, 
                                   epochs_per_increase: nil,  size_increase: nil, repeat_increase: nil,
                                   configured_max_size: nil, compacted_growth_ratio: nil, configured_max_compacted: nil)
    threshold ||= [
      (
        self.epoch_increment_tool_call_threshold ||
        DEFAULT_EPOCH_INCREMENT_TOOL_CALL_THRESHOLD
      ).to_i,
      0
    ].max

    full ||= [
      (
        self.epoch_increment_full_tool_calls ||
        DEFAULT_EPOCH_INCREMENT_FULL_TOOL_CALLS
      ).to_i,
      0
    ].max

    base_compacted ||= [
      (
        self.epoch_increment_compacted_tool_calls ||
        DEFAULT_EPOCH_INCREMENT_COMPACTED_TOOL_CALLS
      ).to_i,
      0
    ].max

    initial_size ||= (
      self.epoch_increment_initial_size ||
      DEFAULT_EPOCH_INCREMENT_INITIAL_SIZE
    ).to_i

    epochs_per_increase ||= (
      self.epoch_increment_epochs_per_increase ||
      DEFAULT_EPOCH_INCREMENT_EPOCHS_PER_INCREASE
    ).to_i

    size_increase ||= [
      (
        self.epoch_increment_size_increase ||
        DEFAULT_EPOCH_INCREMENT_SIZE_INCREASE
      ).to_i,
      0
    ].max

    repeat_increase ||= [
      (
        self.epoch_increment_repeat_increase ||
        DEFAULT_EPOCH_INCREMENT_REPEAT_INCREASE
      ).to_i,
      0
    ].max

    configured_max_size ||= (
      self.epoch_increment_max_size ||
      DEFAULT_EPOCH_INCREMENT_MAX_SIZE
    ).to_i

    compacted_growth_ratio ||= (
      self.epoch_increment_compacted_growth_ratio ||
      DEFAULT_EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO
    ).to_f

    unless compacted_growth_ratio.finite? &&
           compacted_growth_ratio >= 0.0
      compacted_growth_ratio = 0.0
    end

    configured_max_compacted ||= (
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

    # --- Phase A: index interactions by id ---
    #
    # ScoutCoder: real chat layouts are strictly adjacent pairs
    # (function_call immediately followed by its function_call_output,
    # interleaved with meta); across all var/jobs chats there are zero
    # call-run/output-run batches, so id pairing with an
    # immediately-preceding-unpaired-call fallback covers every real
    # history. Orphans stay untouched but still count toward
    # total_tool_outputs, keeping the schedule identical to the one
    # shorten_tools_epoch_increment computes on the same input.

    interactions = []
    interaction_of_call = {}
    interaction_of_output = {}
    pending_calls_by_id = {}
    output_forward_position = 0

    messages.each_with_index do |msg, index|
      role = msg[:role]
      next unless role

      case role.to_sym
      when :function_call
        parsed = epoch_increment_parse_tool_json(msg[:content])

        interaction = {
          call_index: index,
          call_parsed: parsed,
          output_index: nil,
          output_parsed: nil,
          output_position: nil,
          disposition: :keep
        }

        interactions << interaction
        interaction_of_call[index] = interaction

        id = parsed.is_a?(Hash) ? parsed['id'] : nil
        id = id.to_s unless id.nil?

        if id && !id.empty?
          pending_calls_by_id[id] ||= interaction
        end

      when :function_call_output
        # Every output counts, even malformed ones, so positions stay
        # aligned with total_tool_outputs.
        output_forward_position += 1

        parsed = epoch_increment_parse_tool_json(msg[:content])

        id = parsed.is_a?(Hash) ? parsed['id'] : nil
        id = id.to_s unless id.nil?

        partner =
          if id && !id.empty?
            pending_calls_by_id.delete(id)
          end

        # Fallback for an output with a missing or blank id: pair it with
        # the immediately preceding message when that is an unpaired call.
        if partner.nil? && (id.nil? || id.empty?) && index > 0
          previous = messages[index - 1]

          if previous &&
             previous[:role] &&
             previous[:role].to_sym == :function_call

            candidate = interaction_of_call[index - 1]

            if candidate && candidate[:output_index].nil?
              if candidate[:call_parsed].is_a?(Hash) &&
                 candidate[:call_parsed]['id']
                pending_calls_by_id.delete(
                  candidate[:call_parsed]['id'].to_s
                )
              end

              partner = candidate
            end
          end
        end

        next unless partner

        partner[:output_index] = index
        partner[:output_parsed] = parsed
        partner[:output_position] = output_forward_position
        interaction_of_output[index] = partner
      end
    end

    # --- Phase B: schedule and windows, identical to the mirrored strategy ---

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

    # --- Phase C: classify each paired interaction ---

    replaced_count = 0
    dropped_count = 0

    interactions.each do |interaction|
      next unless interaction[:output_index]

      # Malformed tool messages are kept unconditionally, mirroring the
      # mirrored strategy, which keeps outputs with nil or unparseable
      # content (554-563) and calls with nil or unparseable content
      # (612-621) regardless of their position.
      if !interaction[:call_parsed].is_a?(Hash) ||
         !interaction[:output_parsed].is_a?(Hash)
        interaction[:disposition] = :keep
        next
      end

      # One-based position from the newest output. protected_positions is
      # reverse-1-based on outputs too, so the same number identifies the
      # same output message in both schemes.
      reverse_position =
        total_tool_outputs - interaction[:output_position] + 1

      if protected_positions.include?(reverse_position) ||
         reverse_position <= keep_full_count
        interaction[:disposition] = :keep

      elsif reverse_position <= truncate_to
        if epoch_tool_compactation_oversized?(
          interaction[:call_parsed],
          interaction[:output_parsed]
        )
          interaction[:disposition] = :replace
          replaced_count += 1
        else
          interaction[:disposition] = :keep
        end

      else
        interaction[:disposition] = :drop
        dropped_count += 1
      end
    end

    # --- Phase D: rebuild ---

    rebuilt = []

    messages.each_with_index do |msg, index|
      interaction = interaction_of_call[index] || interaction_of_output[index]

      if interaction.nil?
        rebuilt << msg
        next
      end

      case interaction[:disposition]
      when :replace
        if index == interaction[:output_index]
          rebuilt << epoch_tool_compactation_record(
            interaction[:call_parsed],
            interaction[:output_parsed]
          )
        end

        # The call message and the original output message are both skipped.
      when :drop
        # Both messages of the pair are removed, with no record.
      else
        rebuilt << msg
      end
    end

    if replaced_count > 0 || dropped_count > 0
      Log.medium(
        "Epoch tool compactation strategy: " \
        "epoch=#{schedule[:epoch_index]} " \
        "pinned_total=#{pinned_total} " \
        "new_calls=#{new_calls} " \
        "epoch_size=#{schedule[:epoch_size]} " \
        "keep_full=#{keep_full_count} " \
        "truncate_to=#{truncate_to} " \
        "replaced=#{replaced_count} " \
        "dropped=#{dropped_count} " \
        "protected=#{protected_positions.length}"
      )

      rebuilt.unshift(EPOCH_TOOL_COMPACTATION_NOTICE)
    end

    Chat.setup(rebuilt)
  end
end
