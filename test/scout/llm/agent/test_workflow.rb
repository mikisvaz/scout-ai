require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestWorkflowChatTaskSave < Test::Unit::TestCase
  # NOTE on setup order: test_helper's `setup do` callback runs AFTER this
  # `setup` method and does `Open.rm_rf tmpdir`, i.e. it deletes every
  # directory under tmp/test_tmpdir — including any cwd we adopted here. So
  # we must NOT Dir.chdir into a tmpdir-based directory, or every later
  # FileUtils.pwd / Path.follow call raises Errno::ENOENT (getcwd) once the
  # hook has removed it. The workflow does not depend on a particular cwd,
  # so we only point the module's job directory at a fresh work dir (created
  # with Open.mkdir so it exists regardless of Path semantics) and keep the
  # process cwd untouched.
  def setup
    @tmp_work = Path.setup(File.join(TmpFile.tmpdir, 'workflow_chat_task_save'))
    Open.mkdir @tmp_work
    TestWorkflowChatTaskSaveWF.directory = @tmp_work
  end

  def teardown
    FileUtils.rm_rf @tmp_work if File.exist?(@tmp_work)
  end

  def run_job(dir, task)
    TestWorkflowChatTaskSaveWF.directory = Path.setup(dir)
    job = TestWorkflowChatTaskSaveWF.job(task, chat: '')
    job.produce
    job
  end

  module TestWorkflowChatTaskSaveWF
    extend Workflow
    # `extend AgentWorkflow` alone does NOT copy the helper blocks into this
    # module's helpers hash, so Workflow#job would extend the Step with an
    # empty step_module and `log_agent` would be missing at run time.
    # include_workflow merges the helpers (and tasks) properly.
    include_workflow AgentWorkflow

    self.name = 'TestWorkflowChatTaskSaveWF'

    chat_task :plain do
      LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'You are a helper.'}, {role: :user, content: 'Say hi'}]))
    end

    chat_task :with_chat do
      agent = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'You are a helper.'}]))
      agent.user 'question one'
      agent.current_chat.push({role: :assistant, content: 'answer one'})
      agent
    end
  end

  def test_no_files_without_society
    job = run_job(TmpFile.tmpdir, :plain)
    path = job.path
    # The unified provenance save ALWAYS writes this job agent's own chat at
    # `<path>.files/log/agent.chat` (that is the point of the mechanism);
    # only the society subtree stays lazy and appears with a live society.
    assert File.exist?("#{path}.files/agent.chat")
    assert !File.exist?("#{path}.files/agent.society")
  end

  def test_canonical_layout_no_society
    job = run_job(TmpFile.tmpdir, :with_chat)
    path = job.path
    # files_dir is the SUFFIXED sibling `<path>.files`, not a subdirectory
    agent_chat = File.join("#{path}.files", 'agent.chat')
    assert Open.exist?(agent_chat)
    saved = LLM.chat(agent_chat)
    assert_equal 'You are a helper.', saved.first[:content]
    assert saved.any? { |m| m[:role] == 'assistant' && m[:content] == 'answer one' }
    assert !File.exist?(File.join("#{path}.files", 'agent.society'))
  end

  def test_nested_society_layout
    TmpFile.with_dir do |dir|
      # ask_agent builds the specialist from this agent's society when the
      # name is already there (LLM.load_agent would otherwise fail: there is
      # no 'Worker' installed anywhere for these tests).
      worker = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'child helper'}]))
      LLM::Mock.script('child answer')

      agent = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'parent'}]))
      agent.society = { 'Worker' => worker }
      agent.save_file = File.join(dir, 'agent.chat')
      agent.user 'question'
      child = agent.ask_agent('Worker', 'child prompt', options: {endpoint: 'mock'})
      agent.current_chat.push({role: :assistant, content: 'final answer'})

      written = agent.save
      # ask_agent without a conversation argument lands in the 'default'
      # conversation slot
      nested = File.join(dir, 'agent.society', 'Worker', 'default', 'agent.chat')
      assert_include written, File.expand_path(nested)
      assert Open.exist?(nested)
      assert !File.exist?(File.join(dir, 'nested.files'))
    end
  end

  def test_chat_task_result_delta_preserved
    job = run_job(TmpFile.tmpdir, :with_chat)
    result = LLM.chat(job.path)
    # The job result is a Chat projection: it legitimately starts with the
    # provenance meta header (job=...). The delta assertions apply to the
    # conversation messages themselves.
    delta = result.reject { |m| m[:role].to_s == 'meta' }
    assert_include delta.first[:content], 'question one'
    assert_include delta.last[:content], 'answer one'
  end
end
