require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/tools/call'

# Lifecycle guards for the live-workload sidecar `<base>.jobs` written by
# LLM.process_calls while workflow jobs are in flight under a chat save_file.
#
# Semantics under test (canonical, fixed):
#   * the file is a SIBLING of the save_file, derived by Chat.jobs_file
#     (trailing '.chat' strip only);
#   * it is WRITTEN just before Workflow.produce with the short paths of the
#     jobs not yet done (newline-joined), one write per round: a snapshot of
#     the current in-flight set, not an append log;
#   * it is REMOVED in an ensure once Workflow.produce returns -- whether the
#     jobs finished or one of them failed;
#   * no file is created at all when save_file is nil.
#
# The observation trick: the child task runs in a fork under
# Workflow::LocalExecutor, so in-process globals do NOT propagate from it.
# Instead the task block itself appends a line to an observations file that
# lives next to the save_file; the writer has necessarily run before the task
# block starts (it runs before Workflow.produce).
class TestLLMToolCallJobsFile < Test::Unit::TestCase
  # SlowChildWF: a real (mock-free) workflow whose tasks sleep, then record
  # what the sidecar looked like from inside produce. Path.join is used so the
  # observations file does not depend on the workflow jobs directory.
  # Observation directory for the child tasks: set as a PROCESS GLOBAL
  # before run_round. The task block may run in a fork under
  # Workflow::LocalExecutor, but a fork copies the parent's memory, so the
  # child sees it; the reverse (child writing memory) does not propagate,
  # which is why observations go to FILES. A workflow INPUT would not work
  # here: Scout path-resolves plain string inputs and relocates absolute
  # tmpdir values under the workflow's file lookup paths.
  def self.obs_dir; @obs_dir; end
  def self.obs_dir=(v); @obs_dir = v; end

  SlowChildWF = Module.new do
    extend Workflow
    self.name = "SlowChildWF"

    task :slow => :string do
      sleep 0.2
      SlowChildWF.record_sidecar_observation(TestLLMToolCallJobsFile.obs_dir, 'slow')
      'done'
    end

    task :fail => :string do
      SlowChildWF.record_sidecar_observation(TestLLMToolCallJobsFile.obs_dir, 'fail')
      raise 'child failed'
    end

    # Each child writes its own marker (no lost-update race) snapshotting the
    # sidecar content it can see; it runs under Workflow.produce, i.e. after
    # the writer fired.
    def self.record_sidecar_observation(dir, name)
      dir = dir.to_s
      return if dir.empty?
      save_file = File.join(dir, 'agent.chat')
      jobs = Open.exists?(Chat.jobs_file(save_file)) ? Open.read(Chat.jobs_file(save_file)) : ''
      Open.write(File.join(dir, name.to_s + '.obs'), jobs)
      Open.write(File.join(dir, name.to_s + '.seen'), jobs)
    end
  end

  # `job` tool shape used by LLM.process_calls: {name => [obj, definition]}.
  # The Proc returns a Step (not-yet-done), exactly like LLM.call_workflow
  # for a non-exec workflow task; process_calls then produces them.
  def slow_child_tool(wf, task)
    proc do |_name, args|
      wf.job(task.to_sym, args[:jobname], {})
    end
  end

  # Point the fork-inherited observation variable at dir and yield. A class
  # ivar (not a const) so reassignment does not warn; forks still copy it.
  def with_obs_dir(dir)
    old = TestLLMToolCallJobsFile.obs_dir
    TestLLMToolCallJobsFile.obs_dir = dir
    yield
  ensure
    TestLLMToolCallJobsFile.obs_dir = old
  end

  def tool_call(id, name, arguments)
    IndiferentHash.setup({
      'id' => id, 'type' => 'function',
      'function' => {'name' => name, 'arguments' => arguments.to_json}
    })
  end

  def read_sidecar(save_file)
    path = Chat.jobs_file(save_file)
    Open.exists?(path) ? Open.read(path) : nil
  end

  # Drive one process_calls round directly (no LLM.ask, no mock backend): the
  # sidecar writer is inside process_calls, which is exactly the unit here.
  def run_round(save_file, tools, calls)
    LLM.process_calls(tools, calls, save_file: save_file)
  end

  def test_jobs_file_exists_while_child_in_flight_and_lists_its_short_path
    save_dir = File.join(tmpdir, 'jobs_single')
    FileUtils.mkdir_p save_dir
    save_file = File.join(save_dir, 'agent.chat')

    with_obs_dir(save_dir) do
      run_round(save_file,
                {'slow' => [slow_child_tool(SlowChildWF, :slow), nil]},
                [tool_call('c1', 'slow', {jobname: 'single'})])
    end

    # The child OBSERVED the sidecar from inside produce: a marker file was
    # written by the forked task (named after its Step, hence the glob).
    seen = Dir.glob(File.join(save_dir, '*.seen'))
    assert !seen.empty?, 'child task never ran (no *.seen marker)'

    # ... and it saw exactly the child's short path (newline-separated set,
    # single entry here, no extra decoration).
    assert_equal [SlowChildWF.job(:slow, 'single', {}).short_path],
                 Open.read(seen.first).split("\n")
  end

  def test_jobs_file_removed_after_children_complete
    save_dir = File.join(tmpdir, 'jobs_after')
    FileUtils.mkdir_p save_dir
    save_file = File.join(save_dir, 'agent.chat')

    with_obs_dir(save_dir) do
      run_round(save_file,
                {'slow' => [slow_child_tool(SlowChildWF, :slow), nil]},
                [tool_call('c1', 'slow', {jobname: 'after'})])
    end

    assert !Open.exists?(Chat.jobs_file(save_file)),
           "<base>.jobs must be removed once Workflow.produce returns"
  end

  def test_jobs_file_removed_when_produce_raises
    save_dir = File.join(tmpdir, 'jobs_fail')
    FileUtils.mkdir_p save_dir
    save_file = File.join(save_dir, 'agent.chat')

    # process_calls rescues around produce, so the round returns normally;
    # the child raised inside the task block (the failure surfaces as the
    # error envelope in the function_call_output).
    result = with_obs_dir(save_dir) do
      run_round(save_file,
                 {'fail' => [slow_child_tool(SlowChildWF, :fail), nil]},
                 [tool_call('c1', 'fail', {jobname: 'boom'})])
    end

    # The failing child still ran (and observed) before raising.
    assert !Dir.glob(File.join(save_dir, '*.seen')).empty?,
                 'failing child never ran'

    # The ensure removed the sidecar even though produce ended in an error.
    assert !Open.exists?(Chat.jobs_file(save_file)),
           "<base>.jobs must be removed when Workflow.produce fails"

    assert_equal 1, result.select{|m| m[:role].to_s == 'function_call_output' }.length
  end

  def test_jobs_file_lists_two_in_flight_children
    save_dir = File.join(tmpdir, 'jobs_two')
    FileUtils.mkdir_p save_dir
    save_file = File.join(save_dir, 'agent.chat')

    with_obs_dir(save_dir) do
      run_round(save_file,
                {'slow' => [slow_child_tool(SlowChildWF, :slow), nil]},
                [tool_call('c1', 'slow', {jobname: 'pair_a'}),
                 tool_call('c2', 'slow', {jobname: 'pair_b'})])
    end

    expected = [SlowChildWF.job(:slow, 'pair_a', {}).short_path,
                SlowChildWF.job(:slow, 'pair_b', {}).short_path].sort

    # BOTH children ran under produce (both marker files exist) and the
    # snapshot the LAST one to observe saw listed BOTH in-flight jobs (the
    # two forks write the same file name 'slow.seen'; each sees the full
    # pre-produce snapshot, which already contains both short paths).
    seen_files = Dir.glob(File.join(save_dir, '*.seen'))
    assert !seen_files.empty?, 'no child task ever ran (no *.seen marker)'
    seen_files.each do |file|
      assert_equal expected, Open.read(file).split("\n").sort,
                   "child snapshot #{File.basename(file)} did not list both in-flight jobs"
    end
  end

  def test_no_jobs_file_created_when_save_file_is_nil
    wf_dir = Workflow.directory['SlowChildWF']
    before = Open.exists?(wf_dir) ? Dir.glob(File.join(wf_dir, '**', '*.jobs')) : []

    obs = File.join(tmpdir, 'obs_nil')
    FileUtils.mkdir_p obs
    with_obs_dir(obs) do
      run_round(nil,
                {'slow' => [slow_child_tool(SlowChildWF, :slow), nil]},
                [tool_call('c1', 'slow', {jobname: 'nil_save'})])
    end

    after = Dir.glob(File.join(wf_dir, '**', '*.jobs'))

    # The child still ran (its marker file was written) but no .jobs file
    # was ever created anywhere in the jobs tree, since the writer is a
    # no-op without a save_file.
    assert !Dir.glob(File.join(obs, '*.obs')).empty?, 'child never ran'
    assert_equal before.sort, after.sort
    assert(!after.any?{|p| p.end_with?('.jobs') })
  end
end
