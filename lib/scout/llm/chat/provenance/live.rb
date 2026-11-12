# Extracted from the existing live-workload implementation.
module Chat
  # ------------------------------------------------------------------
  # Live workload: the transient <base>.jobs sidecar
  # ------------------------------------------------------------------
  # `LLM.process_calls` writes the short paths of the workflow jobs it is
  # currently producing (Workflow.produce blocking) to `Chat.jobs_file`,
  # rewriting per round and removing the file in an `ensure` when produce
  # returns.  This section turns that transient snapshot into the LIVE view
  # of an agent's workload, complementing the FORENSIC traversal above:
  # absent file is a non-event, never an error.

  # Terminal statuses as recorded in a job `.info` after Workflow.produce
  # returns (or an abort/clean sweep).  Anything else is in-flight or stale,
  # decided by pid liveness below.
  LIVE_TERMINAL_STATUSES = %w[done error aborted cleaned].freeze

  # Is `pid` a live process right now?  Mirrors Misc.pid_alive? but adds the
  # zombie guard: a child that exited without being reaped still answers
  # kill(0, 0), yet produces nothing, so a zombie is NOT running work.
  def self.live_pid?(pid)
    return false if pid.nil? || pid.to_s.empty?
    pid = pid.to_i
    return false unless pid > 0
    return true if pid == Process.pid
    stat = File.read("/proc/#{pid}/stat") rescue nil
    return false if stat.nil?
    # field 3 of /proc/<pid>/stat is the state; Z = zombie
    state = stat.split(')')[-1].split[0]
    state != 'Z'
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  # Classify one in-flight workload entry from its `.info`:
  #   [:running, status]    non-terminal status + live pid
  #   [:crashed, status]    non-terminal status + dead/absent pid
  #   [:finished, status]   terminal status (done/error/aborted/cleaned)
  #
  # Snapshot-contract caveats: `kill -9` leaves `.info` non-terminal forever
  # (pid liveness is the only way to distinguish running from crashed, and
  # the LocalExecutor retry can RESURRECT such a job by overwriting `.info`
  # with a new pid, so a :crashed verdict is valid only for the moment it
  # was computed); a listed job may complete between reading `<base>.jobs`
  # and its `.info` (the classification reports what was seen); a missing
  # `.info` reports :crashed with a nil status.
  def self.classify_live_job(step)
    info = begin
      step.info
    rescue StandardError
      nil
    end
    return [:crashed, nil] unless Hash === info

    state, status = classify_live_job_info(info)
    # classify_live_job_info returns the raw status value; this reader has
    # always reported it as a String, so normalize without changing any
    # observable verdict.
    [state, status.to_s]
  end

  # Resolve one short-path entry of the live sidecar to a Step.
  #
  # The Workflow jobs tree root (`Workflow.directory`) is tried FIRST because
  # that is where process_calls actually produced the job: the sidecar stores
  # SHORT paths, and Step.load rewrites a bare short path through
  # Path.find/Step.relocate, which can land on a different (empty) mirror of
  # the tree (e.g. `~/.scout/var/jobs/...` while the real job lives under the
  # run's Workflow.directory).  Falling back to the forensic
  # `load_job_reference` chain keeps unresolved entries diagnosable.
  def self.load_live_job_reference(reference)
    return reference if Step === reference
    ref_str = reference.to_s

    base = Workflow.directory.respond_to?(:find) ? Workflow.directory.find : Workflow.directory
    candidate = File.join(base.to_s, ref_str)
    return Step.load(candidate) if job_reference_candidate?(candidate)

    step = Step.load(ref_str)
    return step if job_reference_candidate?(step.path.to_s)

    load_job_reference(ref_str)
  end

  # Resolve each entry of the live sidecar of `save_file` (or the chat/job
  # path it stands for) into a Step with its live classification.  Returns an
  # Array of Hashes (one per sidecar entry, order preserved):
  #
  #   {reference: 'WF/task/name', step: Step, path: <job dir>,
  #    status: 'running'|..., state: :running/:crashed/:finished,
  #    chat_task: true|false}
  #
  # `chat_task` uses the LIVE discriminator `step.type.to_s == 'chat'`
  # (chat_task annotation; a hand-written task declaring :chat is inference
  # by definition).  The CONCLUDED discriminator (output JSON with exactly
  # `meta` and `content` keys) belongs to the forensic traversal and is NOT
  # re-checked here: the sidecar only ever lists in-flight jobs.  An
  # absent sidecar is a NON-EVENT: [].  Resolution uses the same
  # fallback chain as forensic job references (`load_job_reference`), so a
  # short path resolves against the workflow jobs tree.
  def self.live_workload(reference)
    base = reference.respond_to?(:path) ? reference.path.to_s : reference.to_s

    # Accept a chat file, a job path (result chat) or a bare save_file: the
    # sidecar is always derived from the save_file base via Chat.jobs_file.
    candidates = [base, base.sub(/\.chat\z/, '')]
    sidecar = candidates.collect { |c| Chat.jobs_file(c) }
                         .find { |f| File.exist?(f) }

    return [] if sidecar.nil?

    entries = Open.read(sidecar).split("\n")
                  .collect(&:strip).reject(&:empty?)

    entries.collect do |entry|
      step = load_live_job_reference(entry)
      state, status = classify_live_job(step)
      type = begin
        step.type.to_s
      rescue
        nil
      end
      {
        reference: entry,
        step: step,
        path: step.path.to_s,
        status: status,
        state: state,
        chat_task: type == 'chat'
      }
    end
  end

  # ------------------------------------------------------------------
  # Dependency expansion + unified live report
  # ------------------------------------------------------------------
  # expand_live_jobs below walks the dependencies a wrapper job RECORDS in
  # its `.info`; live_report folds the three live passes.  Between them
  # sits one repair: the waiting-wrapper fallback.

  # ------------------------------------------------------------------
  # Waiting-wrapper fallback: definition-blind dependency discovery
  # ------------------------------------------------------------------
  # A wrapper job whose chat_task dependency is still running sits at
  # `{"status":"waiting"}` with NO pid and NO `dependencies` key:
  # scout-gear's Step#run records the dependency list in `.info` only at
  # reset_info(status: :setup) inside the persist block, i.e. AFTER
  # run_dependencies returns — a file-based reader that only consults
  # `step.dependencies` is structurally blind in exactly the window the
  # live pass exists for.  Fallback: running sibling job directories in
  # the wrapper's own WORKFLOW namespace (`var/jobs/<Workflow>/<task>`,
  # where scout-gear materializes every dependency).  The workflow
  # definition is deliberately NOT loaded (require_workflow resolves
  # names through the `workflows` pathmap, which cannot see an arbitrary
  # jobs tree); only jobs in the same workflow directory are considered,
  # and captured ids keep their dedup role.

  # Candidate dependency jobs of a wrapper Step whose `.info` predates
  # dependency recording: running sibling job directories in the wrapper's
  # WORKFLOW namespace — where scout-gear materializes every dependency of
  # the wrapper.  Returns [] when the step is fine (has recorded
  # dependencies), is in a terminal phase, or nothing on disk qualifies.
  # Never raises.
  def self.live_dependency_candidates(step)
    return [] unless Step === step
    info = begin
      step.info
    rescue StandardError
      return []
    end
    return [] if Array === info[:dependencies] && !info[:dependencies].empty?

    status = info[:status].to_s
    return [] if LIVE_TERMINAL_STATUSES.include?(status)

    # Workflow namespace, one level ABOVE the wrapper's task dir:
    # dependencies materialize as sibling TASK directories under
    # var/jobs/<Workflow>/ (CortexWF/continue beside
    # CortexWF/cortex_continue), never inside the wrapper's own task dir.
    workflow_dir = begin
      File.dirname(File.dirname(step.path.to_s))
    rescue StandardError
      return []
    end
    return [] unless File.directory?(workflow_dir)

    step_path = step.path.to_s
    candidates = []
    # Glob `.info` files, not job directories: a chat_task's job path is
    # itself a FILE (`<name>.chat`, the result), with `.files` beside it;
    # a directory-only scan sees `<name>.chat.files` and misses the job.
    Dir.glob(File.join(workflow_dir, '*', '*.info')).sort.each do |info_file|
      entry = info_file.sub(/\.info\z/, '')
      next if entry == step_path

      begin
        dep_info = Step.load_info(info_file)
      rescue StandardError
        next
      end
      state, _status = classify_live_job_info(dep_info)
      next unless state == :running

      dep_step = begin
        Step.load(entry)
      rescue StandardError
        next
      end
      candidates << dep_step
    end
    candidates
  end

  # Same classification as classify_live_job but from an already-loaded
  # info Hash (no Step round-trip); used by live_dependency_candidates.
  def self.classify_live_job_info(info)
    return [:unknown, nil] unless Hash === info
    status = info[:status]
    if LIVE_TERMINAL_STATUSES.include?(status.to_s)
      return [:finished, status]
    end
    state = live_pid?(info[:pid]) ? :running : :crashed
    [state, status]
  end

  # ------------------------------------------------------------------
  # Unified live report: sidecar + agent view + society, deduplicated
  # ------------------------------------------------------------------
  # The `.jobs` sidecar lists the job the tool call RESOLVED (a plain
  # wrapper such as Cortex#cortex_continue), while the actually-running
  # inference lives in a DEPENDENCY job (the chat task Cortex#continue)
  # whose `.info` LLM.process_calls has already inited (tools/call.rb):
  # the dependency chain is exactly where the live inference is; the
  # sidecar entry alone is not.  live_report below folds the three live
  # passes into the one data-only report the CLI renders.

  # Depth cap for the dependency walk.  Step#rec_dependencies is itself
  # cycle-safe (it threads a seen-set through the recursion, scout-gear
  # lib/scout/workflow/step/dependencies.rb), so this cap is a second,
  # independent guard against a hand-built or stubbed dependency graph and
  # against pathological depth; it is not load-bearing for real graphs.
  LIVE_DEPENDENCY_DEPTH_LIMIT = 5

  # Agent log file of a running chat task: the chat_task machinery anchors
  # its agents under the JOB's files dir (AgentWorkflow log_agent,
  # agent/workflow.rb: `agent.save_file = Agent.canonical_chat_file(
  # files_dir, agent_name)`), so the log lives at
  # `<job>.files/<agent_name>.chat` and defaults to `agent.chat` when the
  # agent was unnamed.  Returns nil when no such file exists.
  def self.live_chat_task_agent_log(step, agent_name: nil)
    return nil unless Step === step
    files_dir = begin
      step.files_dir
    rescue
      return nil
    end
    return nil if files_dir.nil?

    names = agent_name ? [agent_name] : ['agent', nil]
    names.each do |name|
      begin
        candidate = LLM::Agent.canonical_chat_file(files_dir, name)
      rescue
        return nil
      end
      return candidate if File.exist?(candidate)
    end

    nil
  end

  # Expand sidecar job entries into the set of RUNNING jobs reachable from
  # them (each entry plus its dependencies), with cycle (visited-set) and
  # depth (LIVE_DEPENDENCY_DEPTH_LIMIT) guards.  Returns an Array of
  # Hashes:
  #
  #   {step: Step, path:, reference:, status:, state: :running,
  #    chat_task: true|false, agent_log: <path or nil>,
  #    activity: <agent_log_activity hash or nil>,
  #    via: <short path of the sidecar entry that reached it>}
  #
  # Only `classify_live_job == :running` jobs are kept (finished/crashed
  # dependencies are not live work); running non-chat dependencies stay
  # as workload CONTEXT (the unified report separates inference from
  # context, this method keeps both), and `via` records which sidecar
  # entry each job was reached through, so the wrapper's presence stays
  # visible without duplicating the inference.
  def self.expand_live_jobs(entries)
    entries = entries.respond_to?(:each) ? entries : [entries]
    collected = []
    visited = Set.new

    entries.each do |entry|
      step = Step === entry ? entry : load_live_job_reference(entry)
      # `via` is the sidecar ENTRY (short path) for a String entry, or the
      # job's own short path for a Step entry, so the reported `reference`
      # stays in the same form the sidecar and a `job=` meta both use.
      via = Step === entry ? begin
        step.short_path
      rescue StandardError
        step.path.to_s
      end : entry.to_s
      walk_live_job(step, via, 0, visited, collected)
    end

    collected
  end

  # One visited node of the dependency walk: classify, keep if running,
  # recurse into dependencies while under the depth cap.  Fail-soft per
  # job: an entry whose job cannot be loaded or classified is skipped
  # silently (the forensic traversal is the place to diagnose it).
  def self.walk_live_job(step, via, depth, visited, collected)
    return nil unless Step === step

    path = begin
      step.path.to_s
    rescue
      return nil
    end
    return nil if visited.include?(path)
    visited << path

    state, status = classify_live_job(step)
    if state == :running
      type = begin
        step.type.to_s
      rescue
        nil
      end
      chat_task = type == 'chat'
      agent_log = chat_task ? live_chat_task_agent_log(step) : nil
      reference = begin
        step.short_path
      rescue StandardError
        via
      end
      collected << {
        step: step,
        path: path,
        reference: reference,
        status: status,
        state: state,
        chat_task: chat_task,
        agent_log: agent_log,
        activity: agent_log ? agent_log_activity(agent_log) : nil,
        via: via
      }
    end

    return nil if depth >= LIVE_DEPENDENCY_DEPTH_LIMIT

    # One level at a time, NOT Step#rec_dependencies: rec_dependencies is
    # itself a recursive, cycle-safe flattener, so walking it would return
    # the whole transitive set on the first hop and make the depth cap
    # below meaningless (it can never fire past depth one).  Walking
    # `dependencies` (the direct, recorded edges) keeps BOTH guards of this
    # walk operative: the visited-set here and the depth cap, each an
    # independent second line of defense for stubbed or hand-built graphs.
    deps = begin
      step.dependencies
    rescue StandardError
      []
    end

    # Waiting-wrapper repair (see the fallback section above): a wrapper in
    # a pre-dependency phase (waiting, no `dependencies` key yet, no pid)
    # records nothing for `step.dependencies` to walk — fall back to the
    # definition-blind sibling scan of its task namespace.  Only invoked
    # when the recorded set is empty AND the step itself is in that phase,
    # so a DONE wrapper or a genuinely dependency-free task is unaffected.
    if Array(deps).empty?
      candidates = live_dependency_candidates(step)
      unless candidates.empty?
        collected << {
          step: step,
          path: path,
          reference: begin
            step.short_path
          rescue StandardError
            via
          end,
          status: status,
          state: :waiting,
          chat_task: false,
          agent_log: nil,
          activity: nil,
          via: via
        }
      end
      deps = candidates
    end
    Array(deps).each do |dep|
      walk_live_job(dep, via, depth + 1, visited, collected)
    end
    nil
  end

  # Merge two entries KNOWN to share one job identity (cross-pass: the
  # sidecar pass and a dangling `job=` meta naming the same job).  Keys
  # present in only one entry win as-is; keys present in both resolve to
  # the non-nil/non-empty side; :source tags union.  Job-derived fields
  # therefore keep the richest view, never two entries for one job.  The
  # per-agent-log kind/precedence rules live in
  # reconcile_agent_log_entries, which calls this for same-identity
  # entries ONLY — never across different references.
  def self.merge_live_entries(one, other)
    merged = one.dup
    other.each do |key, value|
      current = merged[key]
      if current.nil? || current.respond_to?(:empty?) && current.empty?
        merged[key] = value
      elsif value.is_a?(Hash) && current.is_a?(Hash)
        merged[key] = current.merge(value)
      end
    end
    merged[:source] = [one[:source], other[:source]].flatten.compact.uniq if one[:source] || other[:source]
    merged
  end

  # Reconcile ALL live entries of ONE agent log into the foldable list:
  # one entry per distinct outstanding job reference, plus (only when the
  # log has none) its bare activity entry.  Explicit rules:
  #
  #   1. Identity: entries sharing a job reference combine into one
  #      entry keeping that identity and its job-derived fields (:state,
  #      :status, :path, :step).
  #   2. DIFFERENT outstanding references never combine — each becomes
  #      its own entry carrying :references (its identity, deduplicated);
  #      no reference collapses to the first.
  #   3. Kind precedence: when the log also has live activity, the merged
  #      kind is :dangling_job and the activity hash rides on the FIRST
  #      reference's entry (first-seen order in the log, independent of
  #      caller push order).
  #   4. :source tags union through merge_live_entries.
  #
  # Accepts either producer shape: agent_view_live's per-reference
  # dangling entries, and society_live's single entry carrying :job plus
  # every reference in :dangling (expanded to one entry per reference,
  # so society children get the same rule 2 guarantee).
  def self.reconcile_agent_log_entries(entries)
    danglings = []
    activity = nil
    others = []
    entries.each do |entry|
      case entry[:kind]
      when :dangling_job
        refs = Array === entry[:dangling] && !entry[:dangling].empty? ? entry[:dangling] : [entry]
        danglings.concat(refs)
      when :agent_activity
        activity ||= entry
      else
        others << entry
      end
    end

    return others + (activity ? [activity] : []) if danglings.empty?

    # Group same-identity references (first-seen order).
    groups = {}
    order = []
    danglings.each do |entry|
      id = entry[:reference].to_s
      id = entry[:job].to_s if id.empty?
      id = entry[:path].to_s if id.empty?
      next if id.empty?
      order << id unless groups.key?(id)
      (groups[id] ||= []) << entry
    end

    order.each_with_index.collect do |id, index|
      group = groups[id]
      merged = group.first.dup
      group.drop(1).each { |entry| merged = merge_live_entries(merged, entry) }
      merged[:reference] = id
      merged[:references] = [id]
      if index.zero? && activity
        merged = merge_live_entries(merged,
                                    activity.reject { |key, _| key == :kind })
        merged[:kind] = :dangling_job
        merged[:activity] = activity
          .reject { |key, _| %i(kind agent_file).include?(key) }
      end
      merged
    end
  end

  # Unified LIVE report for the chat (or job) at `save_file`/`reference`,
  # the single data-only unit that folds the three live passes and that
  # the CLI renders.
  #
  #   Chat.live_report(save_file, captured: ids)
  #   # => {entries: [...], scanned: {sidecar: bool, agent_view: bool,
  #   #                              society: bool}}
  #
  # Entry schema (superset per kind; kind is one of :inference,
  # :workload_context, :agent_activity, :dangling_job):
  #
  #   {kind:, source: [:sidecar|:agent_view|:society|...],
  #    reference:, path:, state:, status:, chat_task:,
  #    agent_log:, activity:, agent:, conversation:, via:, parent:}
  #
  # Folding and dedup rules:
  #   * entries whose job id is in `captured` (live_captured_ids) are
  #     dropped in EVERY pass: the forensic main report already holds them;
  #   * cross-pass dedup is by job id (reference/path), merging facts
  #     (merge_live_entries), never emitting two entries for one job;
  #   * per agent-log file the entries are reconciled by
  #     reconcile_agent_log_entries: one entry per DISTINCT outstanding
  #     job reference (never collapsed to the first), and when the log
  #     also has live activity the dangling job wins as the kind with the
  #     activity hash riding on the first reference's entry;
  #   * a running sidecar job that is a chat task becomes an :inference
  #     entry; a running non-chat job becomes :workload_context (the plain
  #     information live_workload already reported must not disappear).
  #
  # Everything is fail-soft: absent sidecar, absent agent save file, absent
  # society tree and unreadable jobs each yield nothing and never raise.
  def self.live_report(save_file, captured: [])
    captured_ids = live_captured_ids(captured)
    base = save_file.respond_to?(:path) ? save_file.path.to_s : save_file.to_s

    # Entries are keyed by job id where one exists (the sidecar SHORT path,
    # the same form a `job=` meta stores, so cross-pass matches are plain
    # string equality) and by agent-log path otherwise.
    entries = {}

    # --- sidecar pass with dependency expansion ---
    # `live_workload` keeps its contract (entries only); the expansion
    # walks each entry plus its dependencies so the dependency job
    # actually running the inference is reported, not just the wrapper
    # the tool call resolved.
    sidecar_entries = begin
      expand_live_jobs(live_workload(base).collect { |e| e[:step] })
    rescue StandardError
      []
    end
    sidecar_entries.each do |entry|
      job_id = entry[:reference].to_s
      next if job_id.empty?
      next if captured_ids.include?(job_id) ||
              captured_ids.include?(entry[:path].to_s)

      folded = entry.merge(kind: entry[:chat_task] ? :inference : :workload_context,
                           source: [:sidecar])
      # A waiting wrapper surfaced only by the fallback is neither running
      # inference nor finished: report it as workload context (it is live
      # state — its dependency is running) instead of letting classify's
      # :crashed verdict drop it.
      if entry[:state] == :waiting && !entry[:chat_task]
        folded = folded.merge(kind: :workload_context,
                              state: :waiting,
                              status: entry[:status])
      end
      entries[job_id] = entries.key?(job_id) ?
                           merge_live_entries(entries[job_id], folded) : folded
    end
    scanned_sidecar = begin
      [base, base.sub(/\.chat\z/, '')].any? { |b| File.exist?(Chat.jobs_file(b)) }
    rescue StandardError
      false
    end

    # --- agent view pass on the root agent save file ---
    agent_entries = begin
      agent_view_live(base, captured: captured)
    rescue StandardError
      []
    end

    # --- society pass ---
    society_entries = begin
      society_live(base, captured: captured)
    rescue StandardError
      []
    end

    # Reconcile the live entries of each agent log (reconcile_agent_log_entries
    # owns the per-log rules) and merge the result into the job-id space, so
    # a job the sidecar already reported and a dangling `job=` meta name once.
    agent_side = Hash.new { |hash, key| hash[key] = [] }
    ([[:agent_view, agent_entries], [:society, society_entries]]).each do |source, list|
      list.each do |entry|
        log_file = entry[:agent_file] || entry[:path]
        next if log_file.nil?

        agent_side[log_file] << entry.merge(source: [source])
      end
    end

    agent_side.each do |log_file, log_entries|
      reconcile_agent_log_entries(log_entries).each do |entry|
        # A log file whose RUNNING `job=` references were all captured has
        # its liveness already represented by those jobs: drop the bare
        # activity entry too (the same rule society_live applies to its
        # children).  Files with no running reference at all (the
        # Clean-type gap) keep their activity entry.
        if entry[:kind] == :agent_activity
          running_refs = begin
                           live_chat_state(log_file)[:dangling]
                         rescue StandardError
                           []
                         end
          next if !running_refs.empty? &&
                  running_refs.all? { |ref| captured_ids.include?(ref[:reference].to_s) }
        end

        job_id = entry[:reference].to_s
        job_id = entry[:job].to_s if job_id.empty?
        next if !job_id.empty? && (captured_ids.include?(job_id) ||
                                   captured_ids.include?(entry[:path].to_s))

        folded = entry.merge(source: [entry[:source]].flatten.compact.uniq)
        if !job_id.empty? && entries.key?(job_id)
          entries[job_id] = merge_live_entries(entries[job_id], folded)
        elsif !job_id.empty?
          entries[job_id] = folded
        else
          entries[log_file] = folded
        end
      end
    end

    society_dir = begin
      society_dir_of(base)
    rescue StandardError
      nil
    end
    {
      entries: entries.values,
      scanned: {sidecar: scanned_sidecar,
                agent_view: begin
                  File.exist?(base)
                rescue StandardError
                  false
                end,
                society: !society_dir.nil? && Dir.exist?(society_dir)}
    }
  end

  # ------------------------------------------------------------------
  # Agent view: live state of the agent's own save file
  # ------------------------------------------------------------------
  # The `.jobs` sidecar above only sees jobs dispatched through the
  # backend tool round (Workflow.produce inside process_calls).  Two live
  # states never appear there:
  #
  #   * a "Clean"-type agent (no inference workflow) creates no workflow
  #     jobs at all; its only live state is its save file, rewritten at
  #     every round boundary by the backend (outgoing-transcript flush)
  #     and per completed round by Agent#chat's ensure hook
  #     (save_if_configured).
  #   * an agent backed by an AgentWorkflow `ask` task writes the
  #     immediate `job=` meta at dispatch (Agent#ask) and saves BEFORE
  #     producing the job, so the reference dangles in the save file for
  #     the whole duration of the running chat task.
  #
  # Save-file location (pinned for callers): a root chat `<base>` keeps
  # its agent conversation at `<base>.files/<agent>.chat`, derived by
  # LLM::Agent.canonical_chat_file(base + '.files', agent_name) where the
  # agent name comes from the chat's `agent:` line (nil means the plain
  # `agent.chat`).  This layer takes the save-file PATH as input; the
  # caller resolves it because only it knows the agent name.

  # Roles that annotate or steer a chat without marking inference state.
  # Trailing ones are skipped when the activity predicate looks for the
  # last conversational message: a file ending in `meta: job=...`
  # (dispatch in flight) still classifies by the prompt that triggered
  # it, and the job reference itself is reported separately by
  # dangling_agent_job_metas.
  AGENT_CONTROL_ROLES = %w[
    meta option sticky_option previous_response_id agent import socialize attachments
  ].freeze

  # Classify the live activity of one agent save file from its trailing
  # messages.  Predicate rules (user-approved heuristic, encoded exactly):
  #
  #   last message `user`                     -> active, :dispatched
  #   trailing `function_call` with no
  #   `function_call_output` after it         -> active, :tool_round_in_flight
  #   trailing `function_call_output`         -> active, :next_round_pending
  #   last message `assistant` with no
  #   unresolved function call                -> inactive, :idle
  #   empty file                              -> inactive, :no_messages
  #   unreadable/missing file                 -> inactive, :unreadable
  #
  # Control roles (AGENT_CONTROL_ROLES) are skipped when finding the
  # trailing conversational message; any other trailing role (system,
  # introduce, tool) yields inactive :no_inference.  Caveat, accepted by
  # design: an `assistant`-terminated file is classified idle during the
  # brief round-boundary window in which a completed round has been
  # saved but the next dispatch has not flushed yet (false negative,
  # never a false positive).
  #
  # ScoutCoder: this predicate is only sound because the backend rewrites
  # the save file with the OUTGOING transcript at every round boundary
  # (the ensure hooks of LLM::Backend::Default#ask) while the agent layer
  # rewrites it with the completed round afterwards (Agent#chat ensure ->
  # save_if_configured).  That write cadence is documented nowhere and
  # had to be derived from lib/scout/llm/backends/default.rb.
  def self.agent_log_activity(path)
    path = path.to_s

    messages = begin
      Chat.load(path)
    rescue StandardError
      return {active: false, reason: :unreadable, last_role: nil,
              message_count: 0, rounds: 0}
    end

    live_activity_of(messages)
  end

  # Message-only core of agent_log_activity (see above).  Split out so
  # live_chat_state can reuse the classification on a chat it has already
  # loaded; behavior is identical.
  def self.live_activity_of(messages)
    counts = {
      message_count: messages.length,
      rounds: messages.count { |message| message[:role].to_s == 'assistant' }
    }

    conversational = messages.reject do |message|
      AGENT_CONTROL_ROLES.include?(message[:role].to_s)
    end
    last = conversational.last

    return {active: false, reason: :no_messages, last_role: nil}.merge(counts) if last.nil?

    role = last[:role].to_s
    case role
    when 'user'
      {active: true, reason: :dispatched, last_role: role}.merge(counts)
    when 'function_call'
      {active: true, reason: :tool_round_in_flight, last_role: role}.merge(counts)
    when 'function_call_output'
      {active: true, reason: :next_round_pending, last_role: role}.merge(counts)
    when 'assistant'
      {active: false, reason: :idle, last_role: role}.merge(counts)
    else
      {active: false, reason: :no_inference, last_role: role}.merge(counts)
    end
  end

  # Normalize the forensic "captured" set into plain strings a live
  # reference can be compared against.  Entries may be Step objects (the
  # traversal's nodes), Path objects or strings; both the verbatim string
  # and its expanded form are kept, so a short path, a resolved path and
  # a Step all match the same job.
  def self.live_captured_ids(captured)
    entries = captured.respond_to?(:each) ? captured : [captured]
    ids = Set.new
    entries.each do |entry|
      next if entry.nil?
      case entry
      when Step
        path_str = entry.path.to_s
        ids << path_str
        ids << File.expand_path(path_str)
      else
        str = entry.to_s
        ids << str
        ids << File.expand_path(str)
      end
    end
    ids
  end

  # Collect the `job=` meta references recorded in one agent save file
  # that the forensic report has NOT captured and whose job is still
  # RUNNING (Agent#ask writes the immediate `job=` meta and saves before
  # `job.produce`, so while the chat task runs the reference dangles in
  # the save file, invisible to the `.jobs` sidecar — which never lists
  # the agent's own ask dispatch — and to the forensic traversal, whose
  # result chat does not exist yet).
  #
  # `captured` is the set of job identities the forensic main report
  # already contains (Step, Path or String entries; matched by verbatim
  # reference and by resolved path).  Only `:running` jobs survive:
  # finished, crashed, unresolvable and already-captured references are
  # silently dropped, so the method never raises and never reports
  # concluded work.  Receipt-borne references (the `meta` arrays inside
  # function_call_output JSON) are deliberately NOT scanned here; they
  # belong to the forensic `:agent_job` relation and describe work whose
  # answer was already consumed.
  def self.dangling_agent_job_metas(path, captured: [])
    path = path.to_s

    chat = begin
      Chat.load(path)
    rescue StandardError
      return []
    end

    live_dangling_entries(chat, path, captured: captured)
  end

  # Reference-only core of dangling_agent_job_metas: the job-references
  # resolution and `:running` reconciliation (everything after Chat.load),
  # split out so live_chat_state can reuse it on a chat it has already
  # loaded; behavior is identical.
  def self.live_dangling_entries(chat, path, captured: [])
    captured_ids = live_captured_ids(captured)

    references = begin
      chat.jobs
    rescue StandardError
      return []
    end

    references.collect do |reference|
      ref_str = reference.to_s
      next nil if ref_str.empty?
      next nil if captured_ids.include?(ref_str)

      step = begin
        load_live_job_reference(ref_str)
      rescue StandardError
        next nil
      end

      step_id = begin
        File.expand_path(step.path.to_s)
      rescue StandardError
        step.path.to_s
      end
      next nil if captured_ids.include?(step_id)

      state, status = begin
        classify_live_job(step)
      rescue StandardError
        next nil
      end
      next nil unless state == :running

      {
        kind: :dangling_job,
        agent_file: path,
        reference: ref_str,
        step: step,
        path: step.path.to_s,
        status: status,
        state: state
      }
    end.compact
  end

  # Live view of ONE agent save file: its trailing-message activity (the
  # Clean-type gap) plus its dangling `job=` metas reconciled to running
  # jobs (the Direct-type gap).  Returns a data-only Array, empty when
  # nothing is live.  Entry kinds:
  #
  #   :agent_activity -> {kind:, agent_file:, active: true, reason:,
  #                       last_role:, message_count:, rounds:}
  #   :dangling_job   -> {kind:, agent_file:, reference:, step:, path:,
  #                       status:, state:}
  #
  # An inactive agent contributes no activity entry, and a dangling
  # running job is reported on its own, so an agent mid-dispatch (file
  # ending in `meta: job=...`) yields the :dangling_job entry plus the
  # activity entry derived from its trailing conversational message.
  # Fail-soft everywhere: missing or malformed input yields [].
  def self.agent_view_live(save_file, captured: [])
    entries = []

    state = live_chat_state(save_file, captured: captured)
    activity = state[:activity]
    entries << {kind: :agent_activity, agent_file: save_file.to_s}.merge(activity) if activity[:active]

    entries.concat(state[:dangling])
    entries
  end

  # ------------------------------------------------------------------
  # Societal view: live state under <base>.society/
  # ------------------------------------------------------------------
  # ask/hand_off delegation runs in NESTED specialist conversations
  # whose only on-disk trace while running is the society tree written by
  # Agent#save_society
  # (<society_dir>/<agent>/<conversation>/agent.chat, save.rb:239).  The
  # forensic traversal deliberately excludes society files
  # (direct_chat_sidecar_files), so a running delegation is invisible to
  # the main report until it completes and its receipt lands in the parent
  # chat.  Societal agents have NO main chat to diff against: they are
  # reported whole (activity level), with the stronger dangling `job=`
  # detail added when the child is workflow-backed.

  # Conservative directory-depth cap for the society scan.  One nesting
  # level of society costs three directories (agent/conversation/society),
  # so 128 comfortably covers the agent layer's own SAVE_DEPTH_LIMIT of 32
  # while still bounding a pathological tree.
  SOCIETY_SCAN_DEPTH_LIMIT = 128

  # Society directory of the agent whose save file is `save_file`.
  #
  # Layout (mirrors LLM::Agent#society_dir, save.rb: the ROOT rule
  # <name>.chat -> <name>.society sibling, and the NESTED rule where a
  # chat already inside a society tree owns a plain `society` sibling, so
  # the tree nests instead of minting new `.files` trees):
  #
  #   <base>.files/<name>.chat                      -> <base>.files/<name>.society
  #   <base>.chat                                   -> <base>.society
  #   .../<agent>/<conversation>/agent.chat (nested) -> .../<agent>/<conversation>/society
  #
  # The derivation delegates to the agent class (LLM::Agent.society_dir_for
  # / LLM::Agent.nested_save?) so the two cannot drift; the literal mirror
  # below is the fallback when the agent layer is not loaded yet, because
  # chat/provenance is required before scout/llm/agent.  Returns nil only
  # when nothing can be derived (empty/nil input); a directory that does
  # not exist on disk is still returned, because existence is the scan's
  # concern, not the derivation's.
  def self.society_dir_of(save_file)
    path = save_file.to_s
    return nil if path.empty?

    if defined?(LLM::Agent)
      return File.join(File.dirname(path), LLM::Agent::SOCIETY_DIR) if LLM::Agent.nested_save?(path)
      return LLM::Agent.society_dir_for(path)
    end

    # Mirror of save.rb (keep in sync): nested chat -> sibling 'society';
    # root chat -> <name>.society sibling.
    parent = File.basename(File.dirname(File.dirname(File.dirname(path))))
    if parent == 'society' || parent.end_with?('.society')
      File.join(File.dirname(path), 'society')
    else
      p = path
      p = File.dirname(p) unless p =~ /\.chat\z/
      File.join(File.dirname(p), File.basename(p).sub(/\.chat\z/, '.society'))
    end
  end

  # Every saved specialist conversation under the society of `save_file`,
  # as a sorted Array of absolute agent.chat paths.  Silent [] when the
  # society directory is missing or unreadable.
  #
  # The scan is bounded and closed: it never follows symlinks (a link out
  # of the tree would report work that is not this agent's) and stops at
  # SOCIETY_SCAN_DEPTH_LIMIT directory levels.  Only files named
  # `agent.chat` (Agent::SOCIETY_CHAT_FILE, the sole name save_society
  # ever writes) are collected, so a renamed or foreign file is visible as
  # an omission rather than silently reinterpreted.
  def self.society_agent_chats(save_file)
    dir = society_dir_of(save_file)
    return [] if dir.nil? || !File.directory?(dir)

    chats = []
    scan = lambda do |directory, depth|
      return if depth > SOCIETY_SCAN_DEPTH_LIMIT

      entries = Dir.entries(directory)
      entries.each do |entry|
        next if entry == '.' || entry == '..'

        full = File.join(directory, entry)
        next if File.symlink?(full)

        if File.directory?(full)
          scan.call(full, depth + 1)
        elsif entry == 'agent.chat' && File.file?(full)
          chats << full
        end
      end
    rescue StandardError
      nil
    end

    scan.call(dir, 0)
    chats.sort
  end

  # Live view of every specialist conversation under the society of
  # `save_file`.  Data-only Array, empty when nothing is live.
  #
  # Per child (path shape <society>/<agent>/<conversation>/agent.chat, with
  # deeper societies nesting under <agent>/<conversation>/society):
  #
  #   {kind:, agent:, conversation:, path:, relative:, activity:,
  #    job:, job_path:, state:, dangling:}
  #
  # - kind is :dangling_job when the child is WORKFLOW-BACKED and holds a
  #   `job=` meta that resolves to a still-running job (the immediate
  #   dispatch meta written by Agent#ask before job.produce; the stronger
  #   signal, so it wins over activity when both hold), and
  #   :agent_activity otherwise.
  # - activity is always included (agent_log_activity of the child file):
  #   it is the ONLY signal for PLAIN (non-workflow) children, which
  #   dispatch through LLM.ask and never write a `job=` meta at all.
  # - A child is reported when it has a running dangling job OR an active
  #   activity classification; finished/idle children are silent.
  # - Dedup: job ids already in `captured` (the forensic main report's set,
  #   same matching as dangling_agent_job_metas) never produce a
  #   :dangling_job entry; a child whose only live job is captured and
  #   whose conversation has concluded is skipped entirely.
  # - Fail-soft: missing society dir, unreadable chats, malformed content
  #   and unresolvable job references all degrade to silence, never a
  #   raise.
  def self.society_live(save_file, captured: [])
    dir = society_dir_of(save_file)
    return [] if dir.nil?

    prefix = Regexp.quote(dir) + '/'
    captured_ids = live_captured_ids(captured)

    society_agent_chats(save_file).collect do |child|
      state = live_chat_state(child, captured: captured)
      activity = state[:activity]
      dangling = state[:dangling]

      # Dedup against the main report: a child whose job reference is
      # already captured IS that job (a workflow-backed child's whole
      # current turn is its ask job), so an entry here would report the
      # same work twice.  Skip the child entirely; its conversation is
      # represented by the captured job in the forensic traversal.
      child_chat = state[:chat]
      next nil if child_chat && (child_chat.jobs || []).any? { |ref| captured_ids.include?(ref.to_s) }

      next nil if dangling.empty? && !activity[:active]

      relative = child.sub(/\A#{prefix}/, '')
      parts = relative.split(File::SEPARATOR)

      entry = {
        kind: dangling.any? ? :dangling_job : :agent_activity,
        agent: parts.first,
        conversation: parts[1],
        path: child,
        relative: relative,
        activity: activity
      }

      unless dangling.empty?
        first = dangling.first
        entry[:job] = first[:reference]
        entry[:job_path] = first[:path]
        entry[:state] = first[:state]
        entry[:dangling] = dangling
      end

      entry
    end.compact
  end

  # Single-load live state of one agent save file: one Chat.load derives
  # BOTH the trailing-message activity (agent_log_activity's contract) and
  # the outstanding `job=` references (dangling_agent_job_metas' contract)
  # for the multi-child paths (society_live, live_report's captured-ref
  # re-check), where one load serves both consumers.
  #
  # Returns {activity: <agent_log_activity hash>, dangling: <Array>,
  #          chat: <Chat or nil>} where `chat` is the loaded object itself
  # (nil when unreadable; a Chat IS its message Array), because the society
  # captured-dedup pass also needs the raw job-reference list (chat.jobs)
  # of the SAME load.  Performs NO dedup decision of its own: `dangling`
  # and `chat` are raw inputs for the caller's existing rules.
  def self.live_chat_state(path, captured: [])
    path = path.to_s

    chat = begin
      Chat.load(path)
    rescue StandardError
      chat = nil
    end

    if chat.nil?
      {activity: {active: false, reason: :unreadable, last_role: nil,
                  message_count: 0, rounds: 0},
       dangling: [],
       chat: nil}
    else
      {activity: live_activity_of(chat),
       dangling: live_dangling_entries(chat, path, captured: captured),
       chat: chat}
    end
  end

  def self.timestamp
    Time.now.utc.iso8601(3)
  end
end
