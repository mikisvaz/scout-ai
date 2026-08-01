require 'set'

module Chat
  # Canonical short keys for per-inference token fields written into meta
  # messages.  Every key has implicit <key>_s (session) and <key>_c (chat)
  # cumulative variants computed by update_meta.
  #
  #   pt  - prompt / input tokens
  #   ct  - completion / output tokens
  #   tt  - total tokens
  #   cct - cached (cache-hit) input tokens
  #   cwt - cache-write input tokens
  #   rt  - reasoning tokens
  TOKEN_KEYS = %w[pt ct tt cct cwt rt].freeze

  # Keys that carry cumulative totals across chat requests.  Used by
  # Chat.meta to restore the last checkpoint.
  CUMULATIVE_KEYS = TOKEN_KEYS.map { |k| "#{k}_c" }.freeze

  # Map known provider field names to the canonical short keys.
  # Each entry is [field_path, short_key] where field_path is an array
  # of keys suitable for IndiferentHash.dig.
  USAGE_FIELD_MAP = {
    # prompt / input
    %w[prompt_tokens]                  => 'pt',
    %w[input_tokens]                   => 'pt',
    # completion / output
    %w[completion_tokens]              => 'ct',
    %w[output_tokens]                  => 'ct',
    # total
    %w[total_tokens]                   => 'tt',
    # cache-hit (GLM prompt_tokens_details, OpenAI input_tokens_details)
    %w[prompt_tokens_details cached_tokens]   => 'cct',
    %w[input_tokens_details cached_tokens]    => 'cct',
    # cache-write (OpenAI input_tokens_details)
    %w[input_tokens_details cache_write_tokens] => 'cwt',
    # reasoning (GLM completion_tokens_details, OpenAI output_tokens_details)
    %w[completion_tokens_details reasoning_tokens] => 'rt',
    %w[output_tokens_details reasoning_tokens]    => 'rt',
    # Anthropic flat fields
    %w[cache_read_input_tokens]        => 'cct',
    %w[cache_creation_input_tokens]    => 'cwt',
  }.freeze

  # Normalise a provider usage hash into a flat hash keyed by TOKEN_KEYS.
  # Handles OpenAI Chat API (prompt_tokens/completion_tokens), Responses API
  # (input_tokens/output_tokens), GLM (prompt_tokens/completion_tokens), and
  # Anthropic (cache_read_input_tokens/cache_creation_input_tokens).
  #
  # Missing fields are simply omitted from the result.
  def self.normalize_usage(usage)
    return {} if usage.nil? || usage.empty?

    IndiferentHash.setup(usage) unless usage.respond_to?(:dig)

    result = {}
    USAGE_FIELD_MAP.each do |path, short_key|
      next if result.include?(short_key) # first match wins
      value = IndiferentHash.dig(usage, *path)
      result[short_key] = value.to_i if value
    end

    # Compute total if not provided but both prompt and completion are present
    if !result.include?('tt')
      pt = result['pt']
      ct = result['ct']
      result['tt'] = pt.to_i + ct.to_i if pt && ct
    end

    result
  end

  def self.serialize_meta(meta)
    keys = meta.keys.sort_by { |key| String === meta[key] ? meta[key].length : 0 }
    keys.collect { |key| [key, meta[key]] * '=' } * ' '
  end

  def self.parse_meta(str)
    parts = str.to_s.split('=')
    meta = IndiferentHash.setup({})
    key = parts.shift
    while next_part = parts.shift
      if parts.any?
        rnext_part = next_part.reverse
        rkey, _, rvalue = rnext_part.partition(/\s+/)
        next_key = rkey.reverse
        value = rvalue.reverse
      else
        value = next_part
      end

      meta[key] = case value
                  when /^-?\d+$/ then value.to_i
                  when /^-?\d+\.\d+$/ then value.to_f
                  else value
                  end
      key = next_key
    end

    meta
  end

  # Meta messages are local bookkeeping and are not sent to the provider.
  # The last direct inference checkpoint supplies the linear chat total for
  # the next request; job metadata deliberately contributes no token counts.
  def self.meta(messages)
    meta_messages = []
    messages.reject! do |message|
      match = message[:role].to_s == 'meta'
      meta_messages << message if match
      match
    end
    return nil if meta_messages.empty?

    metas = meta_messages.collect { |message| parse_meta(message[:content]) }
    current = IndiferentHash.setup(metas.last.dup)
    checkpoint = metas.reverse.find do |meta|
      CUMULATIVE_KEYS.any? { |name| meta.include?(name) }
    end
    if checkpoint
      CUMULATIVE_KEYS.each do |name|
        current[name] = checkpoint[name] if checkpoint.include?(name)
      end
    end
    current
  end

  def add_meta(key, value)
    meta_msg = role_messages(:meta).last
    meta = meta_msg ? Chat.parse_meta(meta_msg[:content]) : {}
    meta[key] = value
    if meta_msg
      meta_msg[:content] = Chat.serialize_meta(meta)
    else
      message :meta, Chat.serialize_meta(meta)
    end
  end

  def meta
    meta_msg = role_messages(:meta).last
    return {} if meta_msg.nil?
    Chat.parse_meta(meta_msg[:content])
  end

  def job_paths
    role_messages(:meta).collect do |message|
      Path.setup(Chat.parse_meta(message[:content])[:job])
    end.compact.uniq
  end

  alias jobs job_paths

  # Read a persisted chat without compiling it. Provenance inspection must not
  # execute task, job, file, or import roles again.
  def self.load(file)
    Chat.setup(LLM.messages(Open.read(file.to_s)))
  end

  def self.job_agent_chat_files(job)
    job = Step.load(job) unless Step === job
    job.file('log').glob('**/*.chat')
  end

  # Return the result and logged chats for a job and all its dependencies.
  # A job is visited only once, so shared dependencies and accidental cycles do
  # not duplicate evidence or recurse forever.
  def self.job_chat_files(job, seen = Set.new)
    job = Step.load(job) unless Step === job
    key = File.expand_path(job.path.to_s)
    return [] if seen.include?(key)
    seen << key

    chats = []
    chats << job.path if job.done? && job.type.to_s == 'chat'

    chats.concat job_agent_chat_files(job)

    job.dependencies.each do |dependency|
      chats.concat(job_chat_files(dependency, seen))
    end

    chats.collect(&:to_s).uniq
  rescue
    []
  end

  def job_chat_files
    jobs.flat_map { |job| Chat.job_chat_files(job) }.uniq
  end

  def job_agent_chat_files
    jobs.flat_map { |job| Chat.job_chat_files(job) }.uniq
  end

  def job_chats
    job_chat_files.collect { |file| Chat.load(file) }
  end

  def job_agent_chats
    jobs.flat_map { |job| Chat.job_agent_chat_files(job) }.uniq
  end

  # A lineage id identifies a message in its non-meta conversational history.
  # Meta is deliberately excluded from that history: it starts a response
  # segment but is not provider input.
  def message_index
    previous = nil
    collect do |message|
      role = message[:role].to_s
      content = message[:content].to_s
      id = Misc.digest([previous, role, content])
      info = {
        id: id,
        role: role.to_sym,
        prev: previous,
        fingerprint: Log.truncate_string(content)
      }
      if role == 'meta'
        info[:meta] = Chat.parse_meta(content)
      else
        previous = id
      end
      info
    end
  end

  # A meta starts a response segment. The segment continues until another meta,
  # a new user/system turn, or the end of the chat. Consecutive and final metas
  # with no covered messages remain as orphan records.
  def self.trace_indices(indices)
    seen = Set.new
    trace = []
    add = lambda do |pending|
      return if pending.nil? || seen.include?(pending[:id])
      seen << pending[:id]
      trace << {
        id: pending[:id],
        meta: IndiferentHash.setup(pending[:meta].except(:reas)),
        messages: pending[:messages],
        orphan: pending[:messages].empty?
      }
    end

    indices.each do |index|
      pending = nil
      index.each do |info|
        case info[:role]
        when :meta
          add.call(pending)
          pending = { id: info[:id], meta: info[:meta], messages: [] }
        when :user, :system
          add.call(pending)
          pending = nil
        else
          pending[:messages] << info[:id] if pending
        end
      end
      add.call(pending)
    end

    trace
  end

  def self.trace_chats(chats)
    trace_indices(chats.collect(&:message_index))
  end

  # Select trace entries that carry direct token counts (not job projections).
  def self.direct_entries(chat_list)
    trace_chats(chat_list).select do |entry|
      meta = entry[:meta]
      next false if meta[:job]
      TOKEN_KEYS.any? { |name| meta.include?(name) }
    end
  end

  # Sum direct token fields across a set of chats.  Returns a hash keyed
  # by symbol for every key in TOKEN_KEYS.
  def self.token_totals(chat_list)
    totals = TOKEN_KEYS.each_with_object({}) { |k, h| h[k.to_sym] = 0 }
    direct_entries(chat_list).each do |entry|
      meta = entry[:meta]
      TOKEN_KEYS.each { |name| totals[name.to_sym] += meta[name].to_i }
    end
    totals
  end

  # Human-readable token summary suitable for one-line CLI output.
  def self.print_tokens(tokens)
    tokens = tokens.transform_keys(&:to_sym) if Hash === tokens
    parts = []
    parts << "prompt=#{Misc.human_number(tokens[:pt])}" if tokens[:pt]
    parts << "completion=#{Misc.human_number(tokens[:ct])}" if tokens[:ct]
    parts << "total=#{Misc.human_number(tokens[:tt])}" if tokens[:tt]
    if tokens[:cct] && tokens[:cct].to_i > 0
      parts << "cached=#{Misc.human_number(tokens[:cct])}"
    end
    if tokens[:cwt] && tokens[:cwt].to_i > 0
      parts << "cache_write=#{Misc.human_number(tokens[:cwt])}"
    end
    if tokens[:rt] && tokens[:rt].to_i > 0
      parts << "reasoning=#{Misc.human_number(tokens[:rt])}"
    end
    parts * ' '
  end

  # A chat-task response is one segment projected from a job. The original
  # agent chat retains direct token metadata; the returned segment gets one
  # producer marker at its beginning.
  def self.project(job, messages)
    projected = Array(messages).reject { |message| message[:role].to_s == 'meta' }.collect(&:dup)
    return [] if projected.empty?
    [{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected
  end

end
