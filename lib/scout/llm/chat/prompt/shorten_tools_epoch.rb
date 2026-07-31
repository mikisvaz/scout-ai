module Chat

  # --- shorten_tools_epoch strategy configuration ---

  # Total tool-call count at or below which no compaction happens.
  DEFAULT_EPOCH_TOOL_CALL_THRESHOLD = 50

  # Number of most-recent tool calls to keep at full fidelity.
  DEFAULT_EPOCH_FULL_TOOL_CALLS = 10

  # Number of tool calls (before the full window) to compact (truncate).
  DEFAULT_EPOCH_COMPACTED_TOOL_CALLS = 40

  # How many new tool calls are allowed before the compaction boundary
  # advances.  Within a single epoch window the compacted prefix is frozen,
  # maximising KV-cache / prompt-cache hits for consecutive inferences.
  DEFAULT_EPOCH_SIZE = 10

  # --- shorten_tools_epoch strategy configuration accessors ---

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

  # --- shorten_tools_epoch strategy implementation ---

  #
  # Cache-friendly variant of +shorten_tools+.  Instead of recomputing the
  # truncation boundary on every single inference (which constantly shifts the
  # prefix and defeats KV-cache / prompt-cache), this strategy divides the
  # conversation into *epochs*.
  #
  # Within an epoch window of +epoch_size+ tool calls the compaction boundary
  # is frozen.  This means that the compacted prefix (the messages up to and
  # including the truncated region) is byte-for-byte identical for every
  # inference inside that window.
  #
  # == Layout (newest at the bottom)
  #
  #   [ dropped ]        tool calls older than (compacted + full) → removed
  #   [ compacted ]      up to +epoch_compacted_tool_calls+ tool calls, truncated
  #   [ full-recent ]    +epoch_full_tool_calls+ tool calls at full fidelity
  #   [ full-new ]       any tool calls that arrived after the epoch boundary
  #
  # The +compacted+ and +full-recent+ regions are pinned relative to the epoch
  # boundary, not the live tool-call count, so their content stays stable
  # until the boundary advances.
  #
  # == Epoch boundary calculation
  #
  #   overflow  = total_tool_calls - threshold        # how many beyond threshold
  #   epoch_idx = overflow > 0 ? (overflow - 1) / epoch_size : 0
  #   pinned_total = threshold + (epoch_idx * epoch_size)
  #
  # The pinned_total determines where the +full-recent+ region starts.  Any
  # tool calls beyond pinned_total are treated as "new" and kept at full
  # fidelity (they are the live portion of the prompt that changes each turn).
  #
  # == Example (threshold=100, full=10, compacted=40, epoch_size=10)
  #
  #   100 calls → compaction starts: keep 10 full, compact 40, drop 50
  #   101 calls → pinned_total = 100, keep 10 full-recent + 1 full-new
  #   105 calls → same pinned_total = 100, keep 10 full-recent + 5 full-new
  #   110 calls → pinned_total = 100, keep 10 full-recent + 10 full-new
  #   111 calls → pinned_total = 110, keep 10 full-recent + 1 full-new
  #
  def self.shorten_tools_epoch(messages)
    threshold = (self.epoch_tool_call_threshold || DEFAULT_EPOCH_TOOL_CALL_THRESHOLD).to_i
    full      = (self.epoch_full_tool_calls      || DEFAULT_EPOCH_FULL_TOOL_CALLS).to_i
    compacted = (self.epoch_compacted_tool_calls || DEFAULT_EPOCH_COMPACTED_TOOL_CALLS).to_i
    epoch_sz  = (self.epoch_size                 || DEFAULT_EPOCH_SIZE).to_i

    # ---- count tool outputs in the message array ----
    total_tool_outputs = messages.count { |m| m[:role].to_sym == :function_call_output }

    return messages if total_tool_outputs < threshold
    return messages if full == 0 && compacted == 0
    return messages if epoch_sz <= 0

    # ---- compute the pinned epoch boundary ----
    overflow     = total_tool_outputs - threshold
    epoch_idx    = overflow > 0 ? (overflow - 1) / epoch_sz : 0
    pinned_total = threshold + (epoch_idx * epoch_sz)

    # Number of tool calls that are "new" (arrived after the epoch boundary)
    new_calls = total_tool_outputs - pinned_total

    # From the end, the regions are:
    #   [1 .. new_calls]                              → full-new (keep unchanged)
    #   [new_calls+1 .. new_calls+full]                → full-recent (keep unchanged)
    #   [new_calls+full+1 .. new_calls+full+compacted] → compacted (truncate)
    #   everything older                              → dropped

    keep_full_count = new_calls + full
    truncate_to     = keep_full_count + compacted

    # tool_ids counter mirrors the original shorten_tools: incremented BEFORE
    # the check for function_call_output, so that a function_call and its
    # paired output see the same counter value.
    tool_ids = []
    user_messages = 1

    kept_messages = []
    dropped_count = 0
    truncated_count = 0

    # Walk in reverse so we can apply the position-based policy.
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

        name, content, id = tool_call.values_at 'name', 'content', 'id'
        tool_ids << id   # increment BEFORE check (mirrors original shorten_tools)

        if tool_ids.length <= keep_full_count
          # full-new or full-recent → keep unchanged
          kept_messages << msg
        elsif tool_ids.length <= truncate_to
          # compacted region → truncate the content
          new_content = shorten_string(content.to_s, DEFAULT_SHORT_STRING_LENGTH * 2)
          if new_content != content
            tool_call['content'] = new_content
            new_json = tool_call.to_json
            Log.medium "Epoch: truncated tool output #{id} #{name} #{json.length} to #{new_json.length}"
            new_msg = msg.dup
            new_msg[:content] = new_json
            kept_messages << new_msg
            truncated_count += 1
          else
            kept_messages << msg
          end
        else
          # beyond compacted → drop
          Log.medium "Epoch: dropped tool output #{id} #{name} #{json.length}"
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

        # tool_ids already includes the paired output (processed before us
        # in reverse), so we use the same boundary check.
        if tool_ids.length <= keep_full_count
          # full → keep unchanged
          kept_messages << msg
        elsif tool_ids.length <= truncate_to
          # compacted → truncate arguments
          if arguments && arguments.any?
            new_arguments = {}
            arguments.each do |k, v|
              new_arguments[k] = String === v ? shorten_string(v) : v
            end
            if arguments.values != new_arguments.values
              tool_call['arguments'] = new_arguments
              new_json = tool_call.to_json
              Log.medium "Epoch: truncated tool call #{id} #{name} #{json.length} to #{new_json.length}"
              new_msg = msg.dup
              new_msg[:content] = new_json
              kept_messages << new_msg
              truncated_count += 1
            else
              kept_messages << msg
            end
          else
            kept_messages << msg
          end
        else
          # beyond compacted → drop
          Log.medium "Epoch: dropped tool call #{id} #{name} #{json.length}"
          dropped_count += 1
        end

      when :user
        user_messages += 1
        kept_messages << msg

      else
        # assistant, system, meta, etc. → always keep
        kept_messages << msg
      end
    end

    Log.medium "Epoch strategy: pinned_total=#{pinned_total} new_calls=#{new_calls} " \
               "full=#{full} compacted=#{compacted} truncated=#{truncated_count} dropped=#{dropped_count}"

    kept_messages.reverse
  end
end
