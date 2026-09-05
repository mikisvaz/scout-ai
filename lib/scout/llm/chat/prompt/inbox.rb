module Chat

  # --- inbox strategy configuration ---

  # Directory names, relative to the chat files dir (`save_file + '.files'`).
  # Both are invisible to the provenance globs (`'*.chat'`,
  # `'*.society/**/*.chat'` in Chat::DIRECT_LOG_CHAT_GLOBS), so inbox files are
  # never mistaken for chat logs.
  INBOX_DIR = 'inbox'
  INBOX_REMOVED_DIR = 'inbox_removed'

  # --- inbox strategy ---

  # Consume-once message inbox.
  #
  # Unlike the `shorten_*` strategies, `inbox` is NOT purely ephemeral: on
  # every real inference it consumes the regular files found in
  # `<save_file>.files/inbox/`, moving each into
  # `<save_file>.files/inbox_removed/` (mtime preserved, numeric suffix on
  # name collision) and appending one `{role: 'user'}` message carrying the
  # file content to the outgoing prompt.
  #
  # Ordering is deliberate: a file is moved BEFORE its content is read and
  # appended, so a crash between the two may drop a notice but can never
  # deliver the same notice twice.
  #
  # Injected messages are seen by the model but never persisted into the chat
  # transcript; `inbox_removed/` is the record of what was delivered.
  #
  # Gating: without a save_file, or when the files dir or the inbox dir do not
  # exist, this is a silent no-op that creates no directories (the read path
  # never creates the inbox; writers create it themselves).
  def self.inbox(messages, save_file: nil)
    return messages if save_file.nil? || save_file.to_s.empty?

    files_dir = save_file.to_s + '.files'
    inbox_dir = File.join(files_dir, INBOX_DIR)
    return messages unless File.directory?(inbox_dir)

    # Top-level regular files only (glob '*' skips dotfiles, subdirectories
    # are filtered out), sorted by filename so delivery order is
    # deterministic.
    files = Dir.glob(File.join(inbox_dir, '*')).select{|f| File.file?(f) }.sort
    return messages if files.empty?

    additions = []
    files.each do |file|
      begin
        # Unreadable files are skipped in place: moving one would take it out
        # of reach while failing to deliver it.
        next unless File.readable?(file)

        mtime = File.mtime(file)
        target = Chat.inbox_removed_target(file, files_dir)
        FileUtils.mv(file, target)
        File.utime(mtime, mtime, target)
        additions << { role: 'user', content: Open.read(target) }
      rescue Exception => e
        # One bad file must never break the ask path: skip it and continue
        # with the rest. The file stays wherever the failure caught it (in
        # inbox/ if the move failed, already in inbox_removed/ if the read
        # failed), so the next inference can still make progress.
        Log.low "Inbox: skipping unreadable/unmovable file #{file}: #{e.message}"
        next
      end
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

  # Return the `inbox_removed/` target path for `file`, appending a numeric
  # suffix on name collision so previous deliveries are never overwritten.
  # `inbox_removed/` is created lazily, only when a file is actually about to
  # be moved; the read path never creates directories on its own.
  def self.inbox_removed_target(file, files_dir)
    removed_dir = File.join(files_dir, INBOX_REMOVED_DIR)
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
