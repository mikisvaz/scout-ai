require 'set'

module Chat

  # --- shorten_tools_epoch strategy configuration ---

  # Total tool-call count at or below which no compaction happens.
  DEFAULT_EPOCH_TOOL_CALL_THRESHOLD = 50

  # Number of most-recent tool calls to keep at full fidelity.
  DEFAULT_EPOCH_FULL_TOOL_CALLS = 20

  # Number of tool calls (before the full window) to compact (truncate).
  DEFAULT_EPOCH_COMPACTED_TOOL_CALLS = 80

  # How many new tool calls are allowed before the compaction boundary
  # advances.  Within a single epoch window the compacted prefix is frozen,
  # maximising KV-cache / prompt-cache hits for consecutive inferences.
  DEFAULT_EPOCH_SIZE = 20

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

  # --- deduplication helpers (repeated-call protection) ---

  # Recursively normalise a value so that hashes with differently-ordered or
  # symbol/string keys produce the same canonical form.
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

  # Build a canonical deduplication key from a tool call's name + arguments.
  # The model-generated +id+ is deliberately excluded because it is not
  # stable across inferences.
  def self.epoch_dedup_key(name, arguments)
    normalized = epoch_sort_value(arguments || {})
    "#{name}\x00#{JSON.generate(normalized)}"
  rescue
    "#{name}\x00#{arguments.inspect}"
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
  # == Repeated-call protection
  #
  # When the agent loses visibility of a previous tool call (because it was
  # dropped or heavily compacted) it may re-issue the identical call,
  # creating infinite retry loops.  To prevent this the strategy detects
  # repeated calls — matched by (name, arguments) excluding the unstable
  # model-generated +id+ — and ensures the *most recent* instance of every
  # repeated call is never dropped: it is truncated instead.  Older duplicate
  # instances are dropped or compacted normally.
  #
  def self.shorten_tools_epoch(messages)
    threshold = (self.epoch_tool_call_threshold || DEFAULT_EPOCH_TOOL_CALL_THRESHOLD).to_i
    full      = (self.epoch_full_tool_calls      || DEFAULT_EPOCH_FULL_TOOL_CALLS).to_i
    compacted = (self.epoch_compacted_tool_calls || DEFAULT_EPOCH_COMPACTED_TOOL_CALLS).to_i
    epoch_sz  = (self.epoch_size                 || DEFAULT_EPOCH_SIZE).to_i

    # ---- count tool outputs in the message array ----
    total_tool_outputs = messages.count { |m| m[:role].to_sym == :function_call_output }

    return messages if total_tool_outputs <= threshold
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

    # ---- detect repeated tool calls to protect from dropping ----
    # Walk forward to identify the most-recent instance of each repeated
    # (name, arguments) pair.  Those reverse positions are added to
    # +protected_positions+ so that the main reverse walk truncates them
    # instead of dropping, preventing the agent from re-issuing a call it
    # no longer remembers.
    protected_positions = build_protected_positions(messages, total_tool_outputs)

    # tool_ids counter mirrors the original shorten_tools: incremented BEFORE
    # the check for function_call_output, so that a function_call and its
    # paired output see the same counter value.
    tool_ids = []

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

        if tool_ids.length <= keep_full_count || protected_positions.include?(tool_ids.length)
          # full-new or full-recent (or protected repeated call) → keep unchanged
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
        if tool_ids.length <= keep_full_count || protected_positions.include?(tool_ids.length)
          # full (or protected repeated call) → keep unchanged
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
      else
        # assistant, system, meta, etc. → always keep
        kept_messages << msg
      end
    end

    Log.medium "Epoch strategy: pinned_total=#{pinned_total} new_calls=#{new_calls} " \
               "full=#{full} compacted=#{compacted} truncated=#{truncated_count} dropped=#{dropped_count} " \
               "protected=#{protected_positions.length}"

    kept_messages = kept_messages.reverse

	if dropped_count > 0 || truncated_count > 0
	  compaction_message = {
		role: :user,
		content: <<~TEXT.chomp
	  === Context Management ===

      To fit within the model context window, this conversation has been compacted: some tool calls arguments and tool call outputs have been truncated, and some have been removed entirely.

      Compacted: #{truncated_count}
      Removed: #{dropped_count}
      
      Earlier tool results may no longer be present in the visible conversation history. If information appears to be missing, it may have been removed during context compaction rather than never existing. The absence of an earlier tool result in the current conversation does not necessarily mean that the tool has not already been executed.

      Repeated tool calls with the same arguments will be flagged and protected from removal or truncation.
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

  # --- repeated-call detection (forward pre-pass) ---

  #
  # Walk the message array forward and build a +Set+ of reverse positions
  # (1-based from the end, matching +tool_ids.length+ in the main reverse
  # walk) for the most-recent instance of every repeated (name, arguments)
  # pair.  Positions in this set should never be dropped.
  #
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
      Log.medium "Epoch: protecting #{protected.length} repeated call(s) from dropping"
    end

    protected
  end
end
