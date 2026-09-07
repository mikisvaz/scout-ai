module Chat

  # --- inbox strategy configuration ---

  # Suffixes naming the inbox directories. Both are SIBLINGS of the chat's
  # save_file, in that file's own directory: the save_file basename's LAST
  # extension is stripped and the suffix appended.
  #
  #   '<X>.files/agent.chat' -> '<X>.files/agent.inbox'
  #                          -> '<X>.files/agent.inbox_removed'
  #   'a.b.chat'             -> 'a.b.inbox' / 'a.b.inbox_removed' (multi-dot
  #                              basenames strip only the last extension)
  #   'agent' (no extension) -> 'agent.inbox' / 'agent.inbox_removed'
  #
  # The same sibling rule derives the live-workload sidecar `<base>.jobs` (see
  # `Chat.jobs_file`), so all chat-state siblings of a save_file share ONE
  # stem derivation (`Chat.inbox_stem`).
  #
  # Both are invisible to the provenance globs (`'*.chat'`,
  # `'*.society/**/*.chat'` in Chat::DIRECT_LOG_CHAT_GLOBS), so inbox files are
  # never mistaken for chat logs.
  INBOX_SUFFIX = '.inbox'
  INBOX_REMOVED_SUFFIX = '.inbox_removed'

  # Live-workload sidecar suffix: `<base>.jobs` is a SIBLING FILE of the chat
  # save_file listing the workflow jobs currently in flight under it.
  JOBS_SUFFIX = '.jobs'

  # Reserved inbox filename. When pickup reaches a regular file with exactly
  # this name it is consumed exactly once (moved into `.inbox_removed` like
  # any other file, mtime preserved) and the inference is aborted by raising
  # the framework-native `Aborted` exception; the file content NEVER reaches
  # the model -- instead it becomes the abort reason. Files sorted before it
  # in the same pickup are processed normally first; files sorted after it
  # stay in the inbox for the next run.
  INBOX_ABORT_FILE = 'abort'

  # --- inbox strategy ---

  # Consume-once message inbox.
  #
  # Unlike the `shorten_*` strategies, `inbox` is NOT purely ephemeral: on
  # every real inference it consumes the regular files found in the inbox
  # sibling of the chat's save_file (see `Chat.inbox_dir`), moving each into
  # the matching `.inbox_removed` sibling (mtime preserved, numeric suffix on
  # name collision) and appending one `{role: 'user'}` message carrying the
  # file content to the outgoing prompt.
  #
  # The filename `abort` (see INBOX_ABORT_FILE) is reserved: reaching it ends
  # the pickup by raising `Aborted` (the framework-native user-interrupt
  # exception, see scout-essentials exceptions.rb / scout-gear step.rb, which
  # records the job as :aborted instead of :error), with the file content as
  # the abort reason. Messages collected from files sorted before it are
  # appended first, but never sent anywhere because the raise happens before
  # the strategy returns; files after it are not touched.
  #
  # Ordering is deliberate: a file is moved BEFORE its content is read and
  # appended, so a crash between the two may drop a notice but can never
  # deliver the same notice twice.
  #
  # Injected messages are seen by the model but never persisted into the chat
  # transcript; `.inbox_removed` is the record of what was delivered.
  #
  # Gating: without a save_file, or when the inbox directory does not exist,
  # this is a silent no-op that creates no directories (the read path never
  # creates the inbox; writers create it themselves).
  def self.inbox(messages, save_file: nil)
    return messages if save_file.nil? || save_file.to_s.empty?

    inbox_dir = Chat.inbox_dir(save_file)
    return messages unless File.directory?(inbox_dir)

    # Top-level regular files only (glob '*' skips dotfiles, subdirectories
    # are filtered out), sorted by filename so delivery order is
    # deterministic.
    files = Dir.glob(File.join(inbox_dir, '*')).select{|f| File.file?(f) }.sort
    return messages if files.empty?

    additions = []
    aborted_reason = nil
    files.each do |file|
      begin
        # Unreadable files are skipped in place: moving one would take it out
        # of reach while failing to deliver it.
        next unless File.readable?(file)

        mtime = File.mtime(file)
        target = Chat.inbox_removed_target(file, save_file)
        FileUtils.mv(file, target)
        File.utime(mtime, mtime, target)

        if File.basename(target) == INBOX_ABORT_FILE
          # Reserved filename: consumed once, content becomes the abort
          # reason, delivery of any remaining files is deferred to the next
          # run, and nothing else is appended to the prompt.
          content = Open.read(target)
          aborted_reason = content.strip.empty? ? "Inbox abort: #{target}" : "Inbox abort: #{content.strip}"
          break
        end
        additions << { role: 'user', content: Open.read(target) }
      rescue Exception => e
        # One bad file must never break the ask path: skip it and continue
        # with the rest. The file stays wherever the failure caught it (in
        # the inbox if the move failed, already in `.inbox_removed` if the
        # read failed), so the next inference can still make progress.
        Log.low "Inbox: skipping unreadable/unmovable file #{file}: #{e.message}"
        next
      end
    end

    if aborted_reason
      Log.low "Inbox: aborting inference (#{aborted_reason})"
      raise Aborted, aborted_reason
    end

    return messages if additions.empty?

    Log.low "Inbox: appended #{additions.length} message(s) from #{inbox_dir}"

    # ScoutCoder: Array#+ on a Chat-annotated array returns a plain Array --
    # the Chat annotation is not carried through +, concat or flatten, so any
    # strategy that rebuilds the message list must re-annotate with
    # Chat.setup or downstream code (Chat.clean/purge/format_messages) sees a
    # bare Array.
    Chat.setup(messages + additions)
  end

  # Inbox directory of a chat save_file: SIBLING of the save_file in its own
  # directory, named after the save_file basename with its LAST extension
  # stripped plus '.inbox'. An extension-less basename keeps the whole name
  # ('agent' -> 'agent.inbox'); a multi-dot basename strips only the last
  # extension ('a.b.chat' -> 'a.b.inbox').
  def self.inbox_dir(save_file)
    File.join(File.dirname(save_file.to_s), Chat.inbox_stem(save_file) + INBOX_SUFFIX)
  end

  # Directory holding the record of delivered files: same sibling derivation
  # as `Chat.inbox_dir`, with the '.inbox_removed' suffix.
  def self.inbox_removed_dir(save_file)
    File.join(File.dirname(save_file.to_s), Chat.inbox_stem(save_file) + INBOX_REMOVED_SUFFIX)
  end

  # Save_file basename with its LAST extension removed ('agent.chat' ->
  # 'agent', 'a.b.chat' -> 'a.b', 'agent' -> 'agent').
  def self.inbox_stem(save_file)
    base = File.basename(save_file.to_s)
    ext = File.extname(base)
    ext.empty? ? base : base[0...-ext.length]
  end

  # Live-workload sidecar of a chat save_file: SIBLING FILE in the save_file's
  # own directory, derived with the SAME trailing-strip rule as the inbox dirs
  # (`Chat.inbox_stem`, which uses File.extname -- never a first-match sub).
  #
  #   '<dir>/agent.chat'          -> '<dir>/agent.jobs'
  #   '<job>.chat.files/agent.chat' -> '<job>.chat.files/agent.jobs'
  #       (trailing strip only: a '.chat' in an ANCESTOR component is never
  #        touched, unlike the historical unanchored sub)
  #   'a.b.chat' / 'agent'        -> 'a.b.jobs' / 'agent.jobs'
  #
  # Writers (LLM.process_calls) rewrite the file per round and remove it in an
  # `ensure` once Workflow.produce returns; it is a snapshot, not an append log.
  def self.jobs_file(save_file)
    File.join(File.dirname(save_file.to_s), Chat.inbox_stem(save_file) + JOBS_SUFFIX)
  end

  # Return the `.inbox_removed/` target path for `file`, appending a numeric
  # suffix on name collision so previous deliveries are never overwritten.
  # `.inbox_removed/` is created lazily, only when a file is actually about to
  # be moved; the read path never creates directories on its own.
  def self.inbox_removed_target(file, save_file)
    removed_dir = Chat.inbox_removed_dir(save_file)
    FileUtils.mkdir_p(removed_dir) unless File.directory?(removed_dir)

    name = File.basename(file)
    target = File.join(removed_dir, name)
    return target unless File.exist?(target)

    ext = File.extname(name)
    stem = ext.empty? ? name : name[0...-ext.length]
    index = 1
    loop do
      target = File.join(removed_dir, "#{stem}.#{index}#{ext}")
      return target unless File.exist?(target)
      index += 1
    end
  end
end
