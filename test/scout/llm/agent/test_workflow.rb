require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

# Offline replacement for the remote `Baking` workflow (same technique as
# test/scout/llm/test_chat.rb): the `introduce:`/`tool:` directives resolve
# workflow names through Kernel.const_get first, so a named module is
# reachable without any git clone.
TestBaking = Module.new do
  extend Workflow
  self.name = "TestBaking"

  desc "Bake a tray of muffins"
  input :blueberries, :boolean, "Add blueberries", true
  task :bake_muffin_tray => :string do |blueberries|
    "Baking muffins: blueberries=#{blueberries}"
  end
end

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
    $tooling_probe_agent = nil
    $tools_option_agent = nil
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
      LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'You are a helper.'}, {role: :user, content: 'Say hi'}]),
                     backend: :mock, persist: false)
    end

    chat_task :with_chat do
      agent = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'You are a helper.'}]),
                             backend: :mock, persist: false)
      agent.user 'question one'
      agent.current_chat.push({role: :assistant, content: 'answer one'})
      agent
    end

    # The agent is built through the `agent` helper and socializes (the
    # `ask` tool) DURING its first round. The round then ends in a
    # ScoutException raised by the block itself, so chat_task's rescue path
    # runs and log_agent (the end-of-task sweep) NEVER executes: the child
    # conversation can only be durable through its creation-time anchor.
    chat_task :socialize_in_first_round do
      # The specialist template carries the same options-level pins: the
      # child round is launched by LLM.process_calls as
      # 'agent.chat return_messages: true' with NO call options, so only the
      # agent's own other_options can keep it on the mock backend (and out
      # of the shared ask cache) on a direct run.
      worker = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'child helper'}]),
                              backend: :mock, persist: false)
      agent = self.agent nil
      agent.society = { 'Worker' => worker }
      agent.socialize
      agent.user 'delegate please'
      LLM::Mock.script({tool_calls: [{name: 'ask', arguments: {agent: 'Worker', prompt: 'child prompt'}}]},
                       'child answer',
                       'parent done')
      # ScoutCoder: hermetic fix (two layers, both required for a DIRECT
      # `ruby test/.../test_workflow.rb` run).
      #
      # 1. persist: false. LLM.ask persists every round under
      #    Scout.var.cache.ask (~/.scout/var/cache/ask), a SHARED cross-run
      #    store. On a warm cache the whole tool round below is served from
      #    a cached entry WITHOUT executing the ask tool, so the child
      #    conversation is never opened, anchored, or saved: the society
      #    subtree this test asserts on only materializes on a cache miss.
      #
      # 2. backend: :mock at the OPTIONS level (not via test_helper's
      #    Scout::Config pin). An account endpoint — `LLM`/`ASK_ENDPOINT`
      #    env or `~/.scout/etc/AI/<endpoint>.yaml`, resolved in
      #    LLM.ask AFTER the config lookup — merges its yaml into the ask
      #    options with add_defaults, and a yaml `backend: openai` (plus
      #    url/key/model) therefore overrides the config-pinned mock. The
      #    real backend then ignores the scripted tool call, so the child
      #    never socializes and the assertion at the bottom fails; worse,
      #    the round goes LIVE against the account endpoint. An explicit
      #    options value survives add_defaults, so this pin makes the task
      #    hermetic: it always runs the scripted mock round (which always
      #    emits the `ask` tool call) and never constructs a real client.
      agent.chat(return_messages: true, persist: false, backend: :mock)
      raise ScoutException, 'deliberate stop before log_agent'
    end

    # Hygiene probe: declarative workflow tooling from the job chat must
    # reach the seeded conversation, and the helper's own option handling
    # (which keeps :tools, unlike the social pipeline's private-option
    # strip) must still deliver an options-level tool to the agent.
    chat_task :tooling_probe do
      $tooling_probe_agent = self.agent nil
      extra = [Proc.new { |_name, _args| 'ok' },
               {'name' => 'extra_tool',
                'parameters' => {'type' => 'object', 'properties' => {}, 'required' => []}}]
      $tools_option_agent = self.agent nil, tools: {'extra_tool' => extra}
      $tooling_probe_agent.current_chat.push({role: :assistant, content: 'probe done'})
      $tooling_probe_agent
    end
  end

  def test_no_files_without_society
    job = run_job(TmpFile.tmpdir, :plain)
    path = job.path
    # The unified provenance save ALWAYS writes this job agent's own chat at
    # `<path>.files/agent.chat` (that is the point of the mechanism);
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
      child = agent.ask_agent('Worker', 'child prompt', options: {endpoint: 'mock', persist: false})
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

  # The fails-today guard of the A4 step: a chat_task agent that socializes
  # INSIDE its first round leaves a durable child society file, even though
  # the task then aborts before log_agent's end-of-task save sweep.
  def test_socialize_inside_first_round_persists_child_society
    job = run_job(TmpFile.tmpdir, :socialize_in_first_round)
    child = File.join(job.files_dir.to_s, 'agent.society', 'Worker', 'default', 'agent.chat')
    assert Open.exist?(child), "expected the socialized child chat at #{child}"
    parent = File.join(job.files_dir.to_s, 'agent.chat')
    assert Open.exist?(parent), "expected the job agent chat at #{parent}"
  end

  def test_agent_helper_seeds_tooling_and_keeps_tools_option
    chat = "tool: TestWorkflowChatTaskSaveWF\nintroduce: TestWorkflowChatTaskSaveWF\nuser: hi\n"
    TestWorkflowChatTaskSaveWF.directory = Path.setup(TmpFile.tmpdir)
    job = TestWorkflowChatTaskSaveWF.job(:tooling_probe, chat: chat)
    job.produce

    agent = $tooling_probe_agent
    refute_nil agent
    # Anchored and job-wired at creation, through the pipeline
    assert_equal File.join(job.files_dir.to_s, 'agent.chat'), agent.save_file.to_s
    assert_equal job.path.to_s, agent.job.path.to_s
    # Seed order preserved: declarative tooling first, then the cwd/job
    # system preamble, exactly where start_chat.follow tooling sat before
    roles = agent.start_chat.collect { |m| m[:role].to_s }
    assert_equal %w[tool introduce system], roles
    assert agent.start_chat.last[:content].include?('Your current working directory')
    # The declarative tooling seeded into the conversation still resolves
    # to real tool definitions. The chat inside a chat_task refers to this
    # workflow itself; here we resolve the directive against a module whose
    # constant IS reachable, to prove the seeded messages are well-formed
    # tooling rather than inert text (the same technique as
    # test/scout/llm/test_chat.rb's TestBaking).
    seeded = Chat.setup(agent.start_chat.dup)
    seeded.each { |m| m[:content] = m[:content].to_s.gsub('TestWorkflowChatTaskSaveWF', 'TestBaking') }
    definitions = LLM::Mock.tools(seeded, {})
    assert_include definitions.keys, :bake_muffin_tray
    assert_equal TestBaking, definitions[:bake_muffin_tray].first

    # Option hygiene: the helper's options reach the agent intact (the
    # pipeline does not strip :tools on this path)
    tools_option_agent = $tools_option_agent
    refute_nil tools_option_agent
    assert tools_option_agent.other_options[:tools]['extra_tool']
    assert_equal File.join(job.files_dir.to_s, 'agent.chat'), tools_option_agent.save_file.to_s
  end
end
