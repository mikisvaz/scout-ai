require 'json'

module Chat
  TOOL_COMPACTATION_MESSAGE = 'TOOL-COMPACTION-RECORD'
  EPOCH_TOOL_COMPACTATION_NOTICE = {
    role: :assistant,
    content: "=== Context Management ===\nOlder tool interactions were shortened or removed. " \
             "Records describe calls that already ran. Use the recorded job to recover an output when available. " \
             "A missing result alone is no reason to repeat a call."
  }.freeze

  module ToolCompaction
    extend self

    # 20% for non-tool messages, schemas and generation. Full pairs are
    # estimated at 400 tokens each. Medium pairs budget four chars per token.
    SETTINGS = {
      threshold: :epoch_tool_call_threshold, full: :epoch_full_tool_calls,
      base_compacted: :epoch_compacted_tool_calls, initial_size: :epoch_size,
      epochs_per_increase: :epoch_increment_epochs_per_increase,
      size_increase: :epoch_increment_size_increase,
      repeat_increase: :epoch_increment_repeat_increase,
      configured_max_size: :epoch_increment_max_size,
      compacted_growth_ratio: :epoch_increment_compacted_growth_ratio,
      configured_max_compacted: :epoch_increment_max_compacted_tool_calls
    }.freeze

    def setting(key, default)
      Scout::Config.get(key, :prompt, :context, env: key.to_s.upcase, default: default)
    end

    def policy(context_tokens: nil, immediate_share: nil, max_chars: nil, **overrides)
      tokens = Integer(context_tokens || setting(:tool_context_tokens, 80_000))
      share = Float(immediate_share || setting(:tool_immediate_share, 0.5))
      chars = Integer(max_chars || setting(:tool_compaction_max_chars, 800))
      raise ArgumentError, 'context_tokens must be positive' unless tokens.positive?
      raise ArgumentError, 'immediate_share must be between 0 and 1 (exclusive)' unless share > 0 && share < 1
      raise ArgumentError, 'max_chars must be at least 32' unless chars >= 32
      unknown = overrides.keys - SETTINGS.keys
      raise ArgumentError, "Unknown tool compaction settings #{unknown.inspect}" unless unknown.empty?

      usable = tokens * 0.8
      hot = [(usable * share / 400).floor, 2].max
      medium = (usable * (1 - share) * 4 / chars).floor
      full = [hot / 4, 1].max
      epoch = [hot / 4, 1].max
      peak = hot - full
      base = medium / 2
      growth = [(epoch / 2.0).round, 1].max
      defaults = {
        threshold: hot * 5 / 8, full: full, initial_size: epoch,
        base_compacted: base, configured_max_compacted: medium,
        configured_max_size: peak, epochs_per_increase: 3,
        size_increase: growth, repeat_increase: growth,
        compacted_growth_ratio: (medium - base).to_f / [peak - epoch, 1].max
      }
      SETTINGS.each do |key, config_key|
        value = overrides[key] || setting(config_key, defaults.fetch(key))
        defaults[key] = if key == :compacted_growth_ratio
                          ratio = Float(value)
                          ratio.finite? && ratio.positive? ? ratio : 0.0
                        else
                          [Integer(value), 0].max
                        end
      end
      defaults.merge(max_chars: chars)
    end

    def role(msg)
      (msg[:role] || msg['role']).to_s
    end

    def content(msg)
      msg[:content] || msg['content']
    end

    def payload(msg)
      data = content(msg)
      parsed = JSON.parse(data) if data.is_a?(String)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def canonical(value)
      case value
      when Hash then value.sort.to_h.transform_values { |v| canonical(v) }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    Pair = Struct.new(:start, :finish, :position, :call, :output, :key)

    # Output order defines the clock, even when an output is malformed.
    # Unmatched messages never become eligible for compaction.
    def pairs(messages)
      pending = {}
      previous = nil
      position = 0
      completed = []
      messages.each_with_index do |msg, i|
        case role(msg)
        when 'function_call'
          call = payload(msg)
          next unless call
          previous = Pair.new(i, nil, nil, call)
          id = call['id'].to_s
          (pending[id] ||= []) << previous unless id.empty?
        when 'function_call_output'
          position += 1
          output = payload(msg)
          next unless output
          id = output['id'].to_s
          if id.empty?
            next unless previous && previous.start == i - 1
            pair = previous
            pending[pair.call['id'].to_s]&.delete(pair)
          else
            pair = pending[id]&.shift
            next unless pair
          end
          pair.finish = i
          pair.position = position
          pair.output = output
          pair.key = [pair.call['name'], canonical(pair.call['arguments'] || {})]
          completed << pair
        end
      end
      completed
    end

    def oversized?(pair, messages, chars)
      return true if content(messages[pair.start]).size + content(messages[pair.finish]).size > chars
      return true if pair.output['content'].to_s.size > chars / 2
      args = pair.call['arguments']
      args.is_a?(Hash) && args.any? { |_, v| v.is_a?(String) && v.size > chars / 4 }
    end

    # Add whole fields only. Never turn a partial command, id or path into
    # something the reader might mistake for the original.
    def record(pair, chars)
      args = pair.call['arguments']
      lines = ["[#{Chat::TOOL_COMPACTATION_MESSAGE}]"]
      used = lines.first.size
      add = lambda do |line|
        if used + line.size + 1 <= chars
          lines << line
          used += line.size + 1
        end
      end
      add.call("Tool: #{pair.call['name']}")
      add.call("Call id: #{pair.call['id'] || pair.output['id']}")
      step = pair.output['step']
      add.call("Full output found in job: #{step}") unless step.to_s.empty?
      add.call("Original sizes: arguments #{args.to_json.size} chars, output #{pair.output['content'].to_s.size} chars")
      if args.is_a?(Hash)
        args.each do |key, value|
          rendered = case value
                     when Hash, Array then "<omitted, #{value.to_json.size} chars>"
                     when String then value.size <= chars / 4 ? value : "<omitted, #{value.size} chars>"
                     when nil then 'nil'
                     else value.to_s
                     end
          add.call("  #{key}=#{rendered}")
        end
      end
      {role: :assistant, compacted: true, content: lines.join("\n")}
    end

    def compact(messages, policy)
      total = messages.count { |msg| role(msg) == 'function_call_output' }
      return messages if total <= policy[:threshold] || policy[:initial_size].zero?
      return messages if policy[:full].zero? && policy[:base_compacted].zero?
      completed = pairs(messages)
      seen = {}
      repeats = completed.filter_map do |pair|
        repeated = seen.key?(pair.key)
        seen[pair.key] = true
        pair.position if repeated
      end
      schedule = Chat.build_epoch_increment_schedule(total, policy[:threshold], repeats,
        **policy.slice(:initial_size, :epochs_per_increase, :size_increase, :repeat_increase),
        max_size: [policy[:configured_max_size], policy[:initial_size]].max)
      boundary = schedule[:pinned_total]
      full_after = boundary - policy[:full]
      growth = (schedule[:nominal_size] - policy[:initial_size]) * policy[:compacted_growth_ratio]
      medium = policy[:base_compacted] + growth.round
      medium = medium.clamp(policy[:base_compacted], [policy[:configured_max_compacted], policy[:base_compacted]].max)

      # A live repeat can extend this epoch. Only completed epochs affect
      # the medium window, and protection is computed at the frozen boundary.
      latest = {}
      protected = {}
      completed.each do |pair|
        break if pair.position > boundary
        protected[pair.key] = pair.position if latest.key?(pair.key)
        latest[pair.key] = true
      end
      changes = {}
      compacted = removed = 0
      completed.each do |pair|
        break if pair.position > full_after
        next if protected[pair.key] == pair.position
        if pair.position <= full_after - medium
          replacement = nil
          removed += 2
        elsif oversized?(pair, messages, policy[:max_chars])
          replacement = record(pair, policy[:max_chars])
          compacted += 2
        else
          next
        end
        changes[pair.start] = nil
        changes[pair.finish] = replacement
      end
      return messages if changes.empty?
      Log.medium(
        "Tool compaction: epoch=#{schedule[:epoch_index]} pinned_total=#{boundary} " \
        "live_calls=#{schedule[:new_calls]}/#{schedule[:epoch_size]} " \
        "full_before_epoch=#{policy[:full]} medium_window=#{medium} " \
        "compacted_messages=#{compacted} removed_messages=#{removed} " \
        "protected_calls=#{protected.size}"
      )
      notice = Chat::EPOCH_TOOL_COMPACTATION_NOTICE.merge(content:
        "#{Chat::EPOCH_TOOL_COMPACTATION_NOTICE[:content]}\nCompacted tool messages: #{compacted}\nRemoved tool messages: #{removed}")
      rebuild(messages, completed, changes, notice)
    end

    def rebuild(messages, completed, changes, notice)
      first = changes.keys.min
      marker = (first - 1).downto(0).find { |i| role(messages[i]) == 'meta' }
      anchor = marker ? marker + 1 : first
      # Preserve identity if preparation messages follow a leading meta.
      (anchor...first).each do |i|
        anchor = i + 1 if %w[system developer agent].include?(role(messages[i]))
      end

      # A retained sibling can straddle a removed call in a parallel batch.
      # Place the notice before the batch and flush records after its results.
      events = {}
      completed.each do |pair|
        next if changes.key?(pair.start)
        events[pair.start] = 1
        events[pair.finish] = -1
      end
      open = 0
      safe = 0
      (0...anchor).each do |i|
        open += events.fetch(i, 0)
        safe = i + 1 if open.zero?
      end
      anchor = safe
      open = 0
      pending = []
      result = []
      messages.each_with_index do |msg, i|
        result << notice if i == anchor
        open += events.fetch(i, 0)
        if changes.key?(i)
          pending << changes[i] if changes[i]
        else
          result << msg
        end
        if open.zero? && !pending.empty?
          result.concat(pending)
          pending.clear
        end
      end
      Chat.setup(result)
    end
  end

  def self.epoch_tool_compactation(messages, **options)
    ToolCompaction.compact(messages, ToolCompaction.policy(**options))
  end

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

end
