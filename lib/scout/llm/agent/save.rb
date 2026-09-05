require 'set'

module LLM
  class Agent
    # Directory holding the saved conversations of every nested specialist
    # (the "society") reachable from this agent.
    SOCIETY_DIR = 'society'.freeze

    # File name used for every saved conversation inside the society tree.
    SOCIETY_CHAT_FILE = 'agent.chat'.freeze

    # Hard recursion cap while saving nested societies. Object cycles are
    # already cut by the visited sets; the cap is belt and braces against
    # pathological trees that keep minting fresh agents and paths.
    SAVE_DEPTH_LIMIT = 32

    # Conservative fallback for society key parts that do not match the
    # socialization name patterns. No dots, so '.'/'..' can never survive.
    SAVE_SANITIZER = /[^a-zA-Z0-9_-]/

    # Chat file this agent appends to / auto-saves to. Setting it makes `save`
    # work with no arguments and makes every successful chat round auto-save
    # this agent's full state (chat + nested society) there.
    attr_accessor :save_file

    class << self
      # Society directory of a ROOT chat saved at `chat_path`:
      # `.../<name>.society` for a chat file `.../<name>.chat`
      # (`agent.chat` -> `agent.society`; `worker.chat` -> `worker.society`).
      #
      # ScoutCoder: this is the NAME-DERIVED rule, used at depth 0 only. A
      # path that does not end in `.chat` is normalized by dropping its last
      # component (defensive: `society_dir_for(dir)` still yields a directory
      # sibling, never `<dir>.files/...`); both Path and String inputs are
      # accepted and the result is always a plain String.
      #
      # This is the ROOT rule only. The general rule (Agent#society_dir) is
      # decided from the location of the chat being written, so a nested
      # agent.chat never grows a second `.files` tree of its own:
      #
      #   chat.chat
      #   chat.chat.society/<agent>/<conversation>/agent.chat
      #   chat.chat.society/<agent>/<conversation>/society/<agent>/<conversation>/agent.chat
      def society_dir_for(chat_path)
        p = chat_path.to_s
        p = File.dirname(p) unless p =~ /\.chat\z/
        File.join(File.dirname(p), File.basename(p).sub(/\.chat\z/, '.society'))
      end

      # Canonical chat file of an agent run inside a workflow job (or any
      # other files_dir owner): `<files_dir>/<agent_name || 'agent'>.chat`.
      #
      # ScoutCoder: this rule was duplicated in AgentWorkflow#log_agent and
      # restated in a comment at scout_commands/agent/ask; it lives here now,
      # beside the other layout rules, as the single source of truth. Both
      # Path and String files_dir are accepted and the result is always a
      # plain String.
      def canonical_chat_file(files_dir, agent_name = nil)
        File.join(files_dir.to_s, "#{agent_name || 'agent'}.chat")
      end

      # ScoutCoder: LEGACY root society directory (`<path>.files/log/society`)
      # from before the flat layout change. Kept read-only: nothing writes
      # here anymore, but provenance traversal must still glob it so chats
      # saved by older versions remain visible (see
      # Chat.direct_chat_sidecar_files).
      def legacy_society_dir_for(chat_path)
        "#{chat_path}.files/log/#{SOCIETY_DIR}"
      end

      # Is `path` the chat file of a NESTED conversation, i.e. does it already
      # live inside a society tree? A nested chat file sits at
      # <society>/<agent>/<conversation>/<file>, so the directory three levels
      # up from the file is the society directory itself.
      # (Two levels up would be <agent>, one level up <conversation>.)
      #
      # The society directory of a depth-0 chat is named after it
      # (<name>.society), while every deeper level keeps the plain 'society'
      # sibling dir, so BOTH basenames count here.
      def nested_save?(path)
        parent = File.basename(File.dirname(File.dirname(File.dirname(path.to_s))))
        parent == SOCIETY_DIR || parent.end_with?('.' + SOCIETY_DIR)
      end
    end

    def society_dir_for(chat_path)
      self.class.society_dir_for(chat_path)
    end

    # Society directory for the chat written at `path`, whatever the entry
    # point was (root save, recursion, or a later standalone auto-save of a
    # child that had its save_file assigned by a parent):
    #
    # - root chat (`.../conversation.chat`):        sibling `<name>.society`
    # - nested chat (`.../society/<a>/<c>/<file>`): sibling `<dirname>/society`
    #
    # Deciding by LOCATION (not by recursion depth) is what keeps the layout
    # canonical: a nested agent.chat never produces `<nested>.files/...`, no
    # matter who triggered the save.
    def society_dir(path)
      if self.class.nested_save?(path)
        File.join(File.dirname(path), SOCIETY_DIR)
      else
        self.class.society_dir_for(path)
      end
    end

    def nested_save?(path)
      self.class.nested_save?(path)
    end

    # Save the current conversation of this agent and of every nested
    # specialist conversation (`chats`) reachable from it.
    #
    # `path` defaults to the configured `save_file`; when both are nil a
    # ScoutException is raised explaining how to configure the target.
    #
    # Serialization: the FULL current_chat is written, not the delta against
    # start_chat. These files are recovery/restart artifacts, so the saved
    # conversation must be complete. AgentWorkflow#chat_task keeps its own
    # delta semantics (result = current_chat - start_chat) for job results.
    #
    # Layout: this agent's chat is written at `path`; each society entry is
    # written at `<society_dir(path)>/<agent_name>/<conversation>/agent.chat`,
    # where society_dir is computed from the LOCATION of `path` (see
    # Agent#society_dir), so nested societies always sit next to their
    # agent.chat and the tree nests one level deeper each time.
    #
    # Children are saved by recursing into `child.save(child_path, ...)`, and
    # each child's `save_file` is assigned so a later independent ask by that
    # child auto-saves to exactly the same place.
    #
    # Cycle safety: `visited` (resolved target paths) and `seen_agents`
    # (agent objects) are threaded through the recursion; a target path or an
    # agent already saved by this run is skipped with a debug log, and
    # SAVE_DEPTH_LIMIT stops (with a warning, not an exception) anything that
    # still runs away.
    #
    # Lazy: nothing is created eagerly. Open.sensible_write makes parent
    # directories on demand, so an agent with no live society writes ONLY its
    # chat file and no `.files` tree appears.
    #
    # Returns the sorted Array of absolute paths whose content is now on disk
    # and current, whether this call just wrote them or found them already up
    # to date (an unchanged file is not rewritten but IS reported, because the
    # useful contract is "these files now hold this state").
    def save(path = nil, visited: nil, seen_agents: nil, depth: 0)
      path ||= save_file
      raise ScoutException,
            "No save file for agent. Pass a path or configure agent.save_file = <chat file>" if path.nil?

      path = path.to_s
      visited ||= Set.new
      seen_agents ||= Set.new
      resolved = File.expand_path(path)

      if depth > SAVE_DEPTH_LIMIT
        Log.warn "Agent save deeper than #{SAVE_DEPTH_LIMIT} levels under #{resolved}; stopping recursion"
        return []
      end

      if visited.include?(resolved)
        Log.debug "Agent save: conversation already saved at #{resolved}"
        return []
      end
      if seen_agents.include?(self)
        Log.debug "Agent save: agent already saved in this run, skipping #{resolved}"
        return []
      end

      # current_chat is normally never nil (it lazily builds from start_chat),
      # but be explicit: an agent asked to save before any conversation exists
      # saves its (possibly empty) start-based chat rather than crashing.
      chat = current_chat || start
      content = chat.print

      # Recovery artifact: always complete, so refresh it when it changed
      # (Open.sensible_write alone would keep the first version forever).
      if Open.exist?(path) && Open.read(path) == content
        Log.debug "Agent save: #{resolved} is up to date"
      else
        Open.sensible_write(path, content, force: true)
      end

      visited << resolved
      seen_agents << self
      written = []

      # Report only files that verifiably hold the expected content.
      written << resolved if Open.exist?(path)
      save_society(path, visited, seen_agents, depth, written)

      written.sort
    end

    # Auto-save after a turn that changed this agent's conversation. Only
    # fires on agents with a configured save_file and is never fatal (a save
    # failure is logged and the agent run continues). It is a full recursive
    # save, so the tree stays complete after any turn anywhere in it.
    def save_if_configured
      return if save_file.nil?
      save
    end

    # Snapshot the conversation as it stood before a restart, so a restarted
    # conversation can still be recovered. Writes only when there is a prior,
    # non-empty current_chat (lazy: no empty resets), and never lets a save
    # problem break the restart. Timestamp collisions (two restarts within
    # the same millisecond) get a _1, _2, ... suffix instead of clobbering.
    def save_restart_snapshot
      return if save_file.nil?
      prior = @current_chat
      return unless Chat === prior && prior.any?

      dir = File.join("#{save_file}.files", 'resets')
      # Colons are legal on unix but hostile to portability and tooling
      base = Chat.timestamp.gsub(':', '')
      file = File.join(dir, "#{base}.chat")
      suffix = 0
      while Open.exist?(file)
        suffix += 1
        file = File.join(dir, "#{base}_#{suffix}.chat")
      end
      Open.sensible_write(file, prior.print)
      nil
    end

    private

    # Save every live nested conversation of this agent under its society
    # directory. Non-Agent values are ignored; keys are expected to look like
    # `agent_name/conversation` but are sanitized defensively so a malformed
    # key can never escape the society directory.
    def save_society(path, visited, seen_agents, depth, written)
      chats = @chats
      return unless Hash === chats && chats.any?

      society_dir = society_dir(path)

      # Keys are normally Strings but nothing forbids Symbols (or mixed
      # hashes); coerce to String so the sort can never raise a TypeError.
      chats.sort_by { |key, _agent| key.to_s }.each do |key, agent|
        next unless LLM::Agent === agent

        agent_name, conversation = save_split_social_key(key)
        next if agent_name.nil? || conversation.nil?

        child_path = File.join(society_dir, agent_name, conversation, SOCIETY_CHAT_FILE)
        next if Open.exists?(child_path) && Path.newer?(child_path, save_file)
        # The child remembers its own file so a later independent ask by that
        # child auto-saves in place instead of needing the parent save.
        agent.save_file = child_path
        written.concat(agent.save(child_path, visited: visited,
                                               seen_agents: seen_agents,
                                               depth: depth + 1))
      end
    end

    # Split an `agent_name/conversation` society key into its sanitized parts.
    # Both parts must be non-empty; names matching the socialization regexes
    # are kept verbatim, anything else falls back to a conservative sanitizer
    # (path-traversal characters replaced by '_').
    def save_split_social_key(key)
      key = key.to_s
      return [nil, nil] unless key.include?('/')

      raw_agent, raw_conversation = key.split('/', 2)
      return [nil, nil] if raw_agent.to_s.empty? || raw_conversation.to_s.empty?

      [
        save_sanitize_part(raw_agent, SOCIAL_AGENT_NAME),
        save_sanitize_part(raw_conversation, SOCIAL_CONVERSATION_NAME)
      ]
    end

    def save_sanitize_part(part, pattern)
      part = part.to_s
      return part if !part.empty? && !part.include?('/') &&
                     part != '.' && part != '..' && pattern.match?(part)

      sanitized = part.gsub(SAVE_SANITIZER, '_')
      sanitized.empty? ? '_' : sanitized
    end
  end
end
