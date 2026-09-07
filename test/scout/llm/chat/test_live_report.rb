# Tests for the unified live report: Chat.live_report and the dependency
# expansion helpers (expand_live_jobs / walk_live_job) in
# lib/scout/llm/chat/provenance.rb.
#
# Fixtures are synthetic, in the style of test_live_workload.rb: a job is a
# directory + `.info` JSON, running is a live pid (this test process).
# Dependencies are written INTO the `.info` (the same place a real job
# records them, read back by Step#dependencies) rather than stubbed on an
# instance, because live_report loads its own Step objects from the paths
# in the sidecar; an instance stub would never be seen.  The cycle/depth
# tests use the same `.info` mechanism, which lets a real cycle be
# expressed (real Step#rec_dependencies is cycle-safe by construction;
# the guards in walk_live_job are the second line of defense).
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMChatLiveReport < Test::Unit::TestCase
  def wfdir
    @wfdir ||= begin
      dir = Path.setup(Workflow.directory['live-report-wf'])
      Workflow.directory = dir
      dir
    end
  end

  def save_file
    @save_file ||= begin
      sf = tmpdir['agent.chat'].find
      Open.rm_rf sf
      FileUtils.mkdir_p(File.dirname(sf))
      FileUtils.touch(sf)
      sf
    end
  end

  # Synthetic job directory + `.info`.  `deps` lists the job DIRECTORIES
  # this job depends on, exactly like a produced job's info does.
  def write_info(short_path, status, pid, type: 'string', deps: [])
    dir = wfdir[short_path].find
    Open.rm_rf dir
    FileUtils.mkdir_p(dir)
    File.write(dir + '.info',
               JSON.dump({status: status, pid: pid, type: type,
                          workflow: short_path.split('/').first,
                          task_name: short_path.split('/')[1],
                          dependencies: deps}))
    dir
  end

  def write_sidecar(entries)
    sidecar = Chat.jobs_file(save_file)
    Open.rm_rf sidecar
    File.write(sidecar, entries.join("\n") + "\n")
    sidecar
  end

  # The chat_task machinery anchors the running agent under <job>.files.
  def write_agent_log(job_short_path, content)
    files_dir = wfdir[job_short_path + '.files'].find
    FileUtils.mkdir_p(files_dir)
    log = File.join(files_dir, 'agent.chat')
    File.write(log, content)
    log
  end

  def chat_text(*messages)
    "\n" + messages.collect { |m| "#{m[:role]}:\n\n#{m[:content]}" } * "\n\n" + "\n"
  end

  def test_wrapper_dependency_yields_one_inference_entry
    chat_dir = write_info('WF/continue/one', 'running', Process.pid, type: 'chat')
    write_info('WF/cortex_continue/one', 'running', Process.pid,
               deps: [chat_dir])
    write_agent_log('WF/continue/one', chat_text({role: 'user', content: 'go'}))
    write_sidecar(['WF/cortex_continue/one'])

    report = Chat.live_report(save_file, captured: [])
    inference = report[:entries].select { |e| e[:kind] == :inference }
    assert_equal 1, inference.length, 'expected exactly one inference entry'
    entry = inference.first
    assert_equal wfdir['WF/continue/one'].find.to_s, entry[:path]
    assert_equal wfdir['WF/continue/one.files/agent.chat'].find.to_s,
                 entry[:agent_log], 'expected the agent log path to be attached'
    assert entry[:activity][:active], 'expected activity on the agent log'
    assert_equal [:sidecar], [entry[:source]].flatten.uniq

    # The wrapper is kept as workload context, never as a second inference.
    wrapper_entries = report[:entries].select do |e|
      e[:path] == wfdir['WF/cortex_continue/one'].find.to_s
    end
    assert wrapper_entries.any? { |e| e[:kind] == :workload_context }
    assert wrapper_entries.all? { |e| e[:kind] == :workload_context }
  end

  def test_same_job_double_arrival_merges_to_one_entry
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_sidecar(['WF/ask/one'])
    # The same job also dangles as an immediate `job=` meta in the agent
    # save file (agent.rb writes it before job.produce).
    Open.write(save_file, chat_text({role: 'user', content: 'go'},
                                    {role: 'meta', content: 'job=WF/ask/one'}))

    report = Chat.live_report(save_file, captured: [])
    same = report[:entries].select { |e| e[:path] == wfdir['WF/ask/one'].find.to_s }
    assert_equal 1, same.length, 'same job must yield ONE merged entry'
    sources = [same.first[:source]].flatten
    assert_includes sources, :sidecar
    assert_includes sources, :agent_view
    assert_equal :inference, same.first[:kind]
  end

  def test_captured_job_is_dropped_in_all_passes
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_sidecar(['WF/ask/one'])
    Open.write(save_file, chat_text({role: 'user', content: 'go'},
                                    {role: 'meta', content: 'job=WF/ask/one'}))
    # A running societal child whose job is captured.
    child = File.join(save_file.sub(/\.chat\z/, '') + '.society', 'Worker', 'run', 'agent.chat')
    FileUtils.mkdir_p(File.dirname(child))
    Open.write(child, chat_text({role: 'user', content: 'go'},
                                {role: 'meta', content: 'job=WF/ask/one'}))

    report = Chat.live_report(save_file, captured: ['WF/ask/one'])
    assert_equal [], report[:entries]
  end

  def test_cycle_and_depth_guards_terminate
    a_dir = write_info('WF/a/one', 'running', Process.pid, type: 'chat')
    b_dir = write_info('WF/b/one', 'running', Process.pid, type: 'chat')
    File.write(a_dir + '.info',
               JSON.dump({status: 'running', pid: Process.pid, type: 'chat',
                          workflow: 'WF', task_name: 'a',
                          dependencies: [b_dir]}))
    File.write(b_dir + '.info',
               JSON.dump({status: 'running', pid: Process.pid, type: 'chat',
                          workflow: 'WF', task_name: 'b',
                          dependencies: [a_dir]}))

    expanded = Chat.expand_live_jobs(['WF/a/one'])
    assert_equal 2, expanded.length,
                 'cycle must terminate, visiting each job once'

    # Depth cap: a 10-link chain expands LIVE_DEPENDENCY_DEPTH_LIMIT + 1
    # nodes (the entry itself plus 5 dependency levels).
    dirs = (0..9).collect do |i|
      write_info("WF/chain_#{i}/one", 'running', Process.pid, type: 'chat')
    end
    dirs.each_cons(2) do |parent, child|
      info = JSON.parse(File.read(parent + '.info'))
      info['dependencies'] = [child]
      File.write(parent + '.info', JSON.dump(info))
    end

    expanded = Chat.expand_live_jobs(['WF/chain_0/one'])
    assert_equal Chat::LIVE_DEPENDENCY_DEPTH_LIMIT + 1, expanded.length
  end

  def test_nothing_anywhere_is_silent
    Open.rm_rf save_file
    assert_equal({entries: [], scanned: {sidecar: false, agent_view: false,
                                         society: false}},
                 Chat.live_report(save_file, captured: []))
  end

  def test_running_non_chat_job_is_workload_context
    write_info('WF/load/one', 'running', Process.pid)
    write_sidecar(['WF/load/one'])

    report = Chat.live_report(save_file, captured: [])
    assert_equal [:workload_context], report[:entries].collect { |e| e[:kind] }
    assert !report[:entries].first[:chat_task]
  end

  def test_waiting_wrapper_finds_running_dependency
    # The p4 shape: while the chat_task dependency runs, the WRAPPER's
    # `.info` is still `{"status":"waiting"}` — no pid, no `dependencies`
    # key (scout-gear records them only after run_dependencies returns).
    dep_dir = write_info('WF/continue/one', 'start', Process.pid, type: 'chat')
    wrap_dir = write_info('WF/cortex_continue/one', 'waiting', nil)
    # erase the dependencies key entirely, like init_info's pre-persist state
    File.write(wrap_dir + '.info', JSON.dump({status: 'waiting'}))
    write_agent_log('WF/continue/one', chat_text({role: 'user', content: 'go'}))
    write_sidecar(['WF/cortex_continue/one'])

    report = Chat.live_report(save_file, captured: [])
    inference = report[:entries].select { |e| e[:kind] == :inference }
    assert_equal 1, inference.length, 'fallback must surface the dependency'
    assert_equal dep_dir, inference.first[:path]
    assert_equal wfdir['WF/continue/one.files/agent.chat'].find.to_s,
                 inference.first[:agent_log]

    # The waiting wrapper itself is reported once, as workload context,
    # state :waiting (not crashed).
    wrappers = report[:entries].select do |e|
      e[:path] == wrap_dir
    end
    assert_equal 1, wrappers.length, 'wrapper appears exactly once'
    assert_equal :workload_context, wrappers.first[:kind]
    assert_equal :waiting, wrappers.first[:state]
  end

  def test_done_wrapper_uses_recorded_dependencies
    # A DONE-shaped wrapper carries dependencies in `.info`: the normal
    # path must be taken; the fallback must contribute nothing.
    dep_dir = write_info('WF/continue/one', 'start', Process.pid, type: 'chat')
    wrap_dir = write_info('WF/cortex_continue/one', 'waiting', nil,
                          deps: [dep_dir])
    write_sidecar(['WF/cortex_continue/one'])

    expanded = Chat.expand_live_jobs(['WF/cortex_continue/one'])
    assert expanded.any? { |e| e[:path] == dep_dir },
           'recorded dependencies are still walked'
    assert expanded.none? { |e| e[:state] == :waiting },
           'recorded path never marks the wrapper waiting'
  end

  def test_unresolvable_namespace_is_fail_soft
    # A wrapper whose task namespace has no other job directories: the
    # fallback finds nothing and must not raise.
    write_info('WF/solo/one', 'waiting', nil)
    sidecar_only = Chat.jobs_file(save_file)
    Open.rm_rf sidecar_only
    File.write(sidecar_only, "WF/solo/one\n")

    expanded = Chat.expand_live_jobs(['WF/solo/one'])
    assert_equal [], expanded

    report = Chat.live_report(save_file, captured: [])
    assert_equal [], report[:entries]
  end

  def test_dependency_candidates_skip_finished_and_captured
    # Sibling jobs that are finished (done) or crashed (dead pid) are not
    # candidates; only a live sibling is.
    write_info('WF/continue/old', 'done', 999_999_999, type: 'chat')
    dep_dir = write_info('WF/continue/one', 'start', Process.pid, type: 'chat')
    wrap_dir = write_info('WF/cortex_continue/one', 'waiting', nil)

    cands = Chat.live_dependency_candidates(Step.load(wrap_dir))
    assert_equal [dep_dir], cands.collect { |s| s.path.to_s },
                 'only the running sibling qualifies'

    # Captured ids still dedup: the dependency already in the main report
    # is dropped everywhere.
    report = Chat.live_report(save_file, captured: ['WF/continue/one'])
    assert_equal [], report[:entries]
  end

  def test_scanned_flags_reflect_what_was_present
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_sidecar(['WF/ask/one'])
    Open.write(save_file, chat_text({role: 'user', content: 'go'}))

    report = Chat.live_report(save_file, captured: [])
    assert report[:scanned][:sidecar], 'sidecar was present'
    assert report[:scanned][:agent_view], 'agent save file existed'
    assert !report[:scanned][:society], 'no society tree existed'
  end
end
