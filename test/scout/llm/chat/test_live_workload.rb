# Tests for the live workload view: Chat.live_workload (and its helpers) in
# lib/scout/llm/chat/provenance.rb, plus the `--live` prov CLI flag.
#
# Fixtures are synthetic on purpose: the sidecar is a plain newline list and
# a job is just a directory + `.info` JSON, so running/finished/crashed are
# all writable without forking anything. The pid used for the "running"
# cases is the test process itself (guaranteed alive for the duration of
# the test); the "crashed/stale" case uses a pid that is dead by
# construction (a spawned + reaped child). One real end-to-end case
# (in-flight child workflow actually executing while the sidecar is read)
# lives at the bottom and reuses the mock-backend + slow-child harness of
# test_jobs_file.rb.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMChatLiveWorkload < Test::Unit::TestCase
  # Workflow.directory is (re)assigned by the shared setup block in
  # test_helper AFTER the subclass setup hook, so point it at a private
  # subdirectory lazily from the test bodies instead of from setup.
  def wfdir
    @wfdir ||= begin
      dir = Path.setup(Workflow.directory['live-wf'])
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

  # Write a synthetic job directory + `.info`.  `wfdir[x].find` returns the
  # path under the tmpdir path_map that Step.load and the Workflow.directory
  # fallback both resolve; writing with plain File.write against the raw
  # path object would silently write relative to PWD.
  def write_info(short_path, status, pid, type: 'string')
    dir = wfdir[short_path].find
    Open.rm_rf dir
    FileUtils.mkdir_p(dir)
    File.write(dir + '.info',
               JSON.dump({status: status, pid: pid, type: type,
                          workflow: short_path.split('/').first,
                          task_name: short_path.split('/')[1]}))
    dir
  end

  def write_sidecar(entries)
    sidecar = Chat.jobs_file(save_file)
    Open.rm_rf sidecar
    File.write(sidecar, entries.join("\n") + "\n")
    sidecar
  end

  def classify(short_path)
    Chat.live_workload(save_file).find { |e| e[:reference] == short_path }
  end

  def test_no_sidecar_is_silent
    assert_equal [], Chat.live_workload(save_file)
  end

  def test_running_chat_task_with_live_pid
    $stderr.puts "DBG-T0 wfdir=#{@wfdir} save=#{@save_file} dir_exists=#{File.directory?(@wfdir['WF/ask/one'].find) rescue 'NA'}"
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_sidecar(['WF/ask/one'])
    entry = classify('WF/ask/one')
    $stderr.puts "DBG-T1 entry=#{entry && entry[:path]} state=#{entry && entry[:state]} sidecar=#{File.read(Chat.jobs_file(@save_file)).inspect rescue $!.message} wfdir_now=#{Workflow.directory.respond_to?(:find) ? Workflow.directory.find : Workflow.directory} info=#{File.exist?(@wfdir['WF/ask/one'].find + ".info") rescue "NA"}"
    assert_equal :running, entry[:state]
    assert entry[:chat_task]
    assert_equal 'running', entry[:status]
  end

  def test_finished_job_has_terminal_status
    write_info('WF/ask/one', 'done', 999999999, type: 'chat')
    write_sidecar(['WF/ask/one'])
    entry = classify('WF/ask/one')
    assert_equal :finished, entry[:state]
    assert entry[:chat_task]
    assert_equal 'done', entry[:status]
  end

  def test_crashed_or_stale_when_non_terminal_and_pid_dead
    # dead pid by construction: spawn and reap a child
    pid = fork { exit! 0 }
    Process.wait(pid)
    write_info('WF/ask/one', 'running', pid, type: 'chat')
    write_sidecar(['WF/ask/one'])
    entry = classify('WF/ask/one')
    assert_equal :crashed, entry[:state]
    assert_equal 'running', entry[:status]
  end

  def test_non_chat_job_is_workflow_not_chat_task
    write_info('WF/load/one', 'running', Process.pid, type: 'string')
    write_sidecar(['WF/load/one'])
    entry = classify('WF/load/one')
    assert_equal :running, entry[:state]
    refute entry[:chat_task]
  end

  def test_all_in_flight_jobs_are_listed_and_classified
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_info('WF/load/two', 'done', 999999999, type: 'tsv')
    write_sidecar(['WF/ask/one', 'WF/load/two'])
    entries = Chat.live_workload(@save_file)
    assert_equal %w(WF/ask/one WF/load/two), entries.collect { |e| e[:reference] }
    assert entries.find { |e| e[:reference] == 'WF/ask/one' }[:chat_task]
    refute entries.find { |e| e[:reference] == 'WF/load/two' }[:chat_task]
  end

  def test_job_completed_between_reads_reports_what_was_seen
    # Snapshot race: sidecar still lists the job but `.info` already says
    # done. The consumer reports the observed state, it does not error.
    write_info('WF/ask/one', 'done', 999999999, type: 'chat')
    write_sidecar(['WF/ask/one'])
    entry = classify('WF/ask/one')
    assert_equal :finished, entry[:state]
  end

  def test_unresolvable_entry_is_reported_not_raised
    write_sidecar(['NoSuchWF/none/Default'])
    entries = Chat.live_workload(save_file)
    assert_equal 1, entries.length
    assert_equal :crashed, entries.first[:state]
    assert_equal '', entries.first[:status].to_s
    assert_equal 'NoSuchWF/none/Default', entries.first[:reference]
  end

  def test_end_to_end_real_in_flight_child
    # Real end-to-end: a slow child workflow is dispatched through the
    # backend tool round while the consumer reads the sidecar. Reuses the
    # slow_workflow / call_workflow harness from test_jobs_file.rb.
    wf = wfdir
    slow = Module.new do
      extend Workflow
      self.name = 'LiveE2EWF'
      self.directory = wf['LiveE2EWF']

      task :slow => :string do
        sleep 0.4
        'slow done'
      end
    end

    require 'scout/llm/tools/workflow'
    tools = LLM.workflow_tools(slow)

    pid = fork do
      LLM::Mock.script([{tool_calls: [{name: 'slow', arguments: {}}]}, 'done'])
      # The mock backend threads save_file through process_calls, so the
      # sidecar is written by the same code path as production.
      LLM::Mock.ask(Chat.setup([{role: 'user', content: 'run it'}]),
                    tools: tools, save_file: save_file)
    end

    entry = nil
    60.times do
      sleep 0.05
      entry = classify('LiveE2EWF/slow/Default')
      break if entry && entry[:state] == :running
    end
    Process.wait(pid)

    assert_not_nil entry, 'sidecar never showed the running child'
    assert entry[:chat_task] == false, 'non-chat task must classify as workflow'
    # After the round the sidecar is gone, so live view is silent again
    assert_equal [], Chat.live_workload(save_file)
  end
end
