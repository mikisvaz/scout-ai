module Chat
  def self.serialize_meta(meta) 
    keys = meta.keys

    keys = keys.sort_by do |k|
      v = meta[k]
      String === v ? v.length : 0
    end

    keys.collect{|k| [k,meta[k]] * "="} * " "  
  end  

  def self.parse_meta(str) 
    parts = str.split('=')    
    meta = IndiferentHash.setup({})   
    key = parts.shift 
    while next_part = parts.shift

      if parts.any?
        rnext_part = next_part.reverse
        rkey,_, rvalue = rnext_part.partition(/\s+/)
        next_key = rkey.reverse
        value = rvalue.reverse
      else
        value = next_part
      end

      case value      
      when /^-?\d+$/
        meta[key] = value.to_i 
      when /^-?\d+\.\d+$/ 
        meta[key] = value.to_f      
      else       
        meta[key] = value
      end

      key = next_key
    end 

    meta
  end  

  # Old chat files can contain a complete usage ledger in one meta message.
  # Keep its parser for backwards compatibility, but do not write this form:
  # new chats store one constant-size usage event per backend request.
  def self.parse_usage(value)
    return {} if value.nil? || value.to_s.empty?

    value.to_s.split(';').each_with_object({}) do |entry, usage|
      id, values = entry.split(':', 2)
      next if id.nil? || id.empty? || values.nil?

      prompt, completion, total = values.split(',', 3)
      usage[id] = [prompt.to_i, completion.to_i, total.to_i]
    end
  end

  def self.serialize_usage(usage)
    usage.sort.collect { |id, values| [id, values.join(',')] * ':' } * ';'
  end

  def self.usage(meta)
    return {} if meta.nil?
    parse_usage(meta[:usage] || meta['usage'])
  end

  # Return the set of actual requests represented by meta messages. A request
  # is stored exactly once in new chats as `usage_id` plus the per-call token
  # counts. This makes imported/branched histories deduplicable without
  # copying a growing ledger into every subsequent meta message.
  def self.usage_events(messages)
    messages = [messages] if Hash === messages

    Array(messages).each_with_object({}) do |message, events|
      meta = if message[:role].to_s == 'meta'
               parse_meta(message[:content])
             else
               message
             end

      # Workflow task summaries are aggregate records, not backend request
      # events. Their task identity is handled by usage_summaries below.
      next if (meta[:usage_scope] || meta['usage_scope']) == 'task'

      old_usage = usage(meta)
      if old_usage.any?
        events.merge! old_usage
      elsif usage_id = meta[:usage_id] || meta['usage_id']
        events[usage_id] = %w(pt ct tt).collect { |name| meta[name].to_i }
      end
    end
  end

  # Before usage_id existed, every call wrote a cumulative `*_c` snapshot.
  # Those snapshots are not independent calls: summing them creates exactly
  # the explosive totals this code is meant to prevent. Retain only the last
  # such snapshot as one opaque legacy base.
  def self.legacy_usage(messages)
    messages = [messages] if Hash === messages

    legacy = Array(messages).collect do |message|
      meta = if message[:role].to_s == 'meta'
               parse_meta(message[:content])
             else
               message
             end
      next if (meta[:usage_scope] || meta['usage_scope']) == 'task'
      next if meta[:usage_id] || meta['usage_id'] || usage(meta).any?
      next unless %w(pt_c ct_c tt_c).any? { |name| meta[name].to_i != 0 }
      meta
    end.compact.last

    return {} if legacy.nil?
    { "legacy_#{Misc.digest(serialize_meta(legacy))}" =>
      %w(pt_c ct_c tt_c).collect { |name| legacy[name].to_i } }
  end

  # Workflow Step results carry one summary for the work performed by that
  # task. `usage_job` makes repeated imports/follows of the same Step safe.
  def self.usage_summaries(messages)
    messages = [messages] if Hash === messages

    Array(messages).each_with_object({}) do |message, summaries|
      meta = if message[:role].to_s == 'meta'
               parse_meta(message[:content])
             else
               message
             end
      next unless (meta[:usage_scope] || meta['usage_scope']) == 'task'

      job = meta[:usage_job] || meta['usage_job'] || meta[:job] || meta['job']
      next if job.nil? || job.to_s.empty?

      summaries[job] = %w(pt_d ct_d tt_d).collect { |name| meta[name].to_i }
    end
  end

  # The delta (`*_d`) is used by AgentWorkflow while assembling a workflow
  # DAG. The cumulative values are for a normal chat that follows one or more
  # completed workflow task results.
  def self.usage_summary_cumulative(messages)
    messages = [messages] if Hash === messages

    Array(messages).each_with_object({}) do |message, summaries|
      meta = if message[:role].to_s == 'meta'
               parse_meta(message[:content])
             else
               message
             end
      next unless (meta[:usage_scope] || meta['usage_scope']) == 'task'

      job = meta[:usage_job] || meta['usage_job'] || meta[:job] || meta['job']
      next if job.nil? || job.to_s.empty?

      summaries[job] = %w(pt_c ct_c tt_c).collect { |name| meta[name].to_i }
    end
  end

  def self.usage_totals(usage)
    prompt, completion, total = usage.values.inject([0, 0, 0]) do |totals, values|
      totals.zip(values).collect { |a, b| a + b.to_i }
    end

    { 'pt_c' => prompt, 'ct_c' => completion, 'tt_c' => total }
  end

  def self.meta(messages)
    # Meta is local bookkeeping, never provider input. Work on the compiled
    # message array, so persistent chats retain their immutable usage events.
    meta_messages = []
    messages.reject! do |message|
      match = message[:role].to_s == 'meta'
      meta_messages << message if match
      match
    end

    return nil if meta_messages.empty?

    metas = meta_messages.collect { |message| parse_meta(message[:content]) }
    meta = IndiferentHash.setup(metas.last.dup)

    events = usage_events(meta_messages)
    legacy = legacy_usage(meta_messages)
    # A chat following a completed task needs the task's complete total, not
    # just its last task-local delta. AgentWorkflow itself uses
    # usage_summaries (the `*_d` values) to assemble overlapping task DAGs.
    summaries = usage_summary_cumulative(meta_messages)
    totals = legacy.merge(events).merge(summaries.transform_keys { |job| "task_#{job}" })
    if totals.any?
      # Do not carry the old, growing ledger forward after reading it.
      meta.delete 'usage'
      meta.merge! usage_totals(totals)
    end

    meta
  end

  def add_meta(key, value)
    meta_msg = self.select{|msg| msg[:role].to_s == 'meta' }.first
    if meta_msg.nil?
      meta = { }
    else
      meta = Chat.parse_meta meta_msg[:content] 
    end
    meta = {} if meta.nil?
    meta[key] = value
    if meta_msg
      meta_msg[:content] = Chat.serialize_meta(meta)
    else
      message :meta, Chat.serialize_meta(meta)
    end
  end
end
