require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMAgentSave < Test::Unit::TestCase
  def setup
    super
    @dir = File.join(tmpdir, 'save_tests')
    FileUtils.mkdir_p @dir
  end

  def simple_agent(content = 'you are a robot')
    agent = LLM::Agent.new
    agent.start_chat.system content
    agent
  end

  def chat_files_under(dir)
    Dir.glob(File.join(dir, '**', '*.chat')).sort
  end

  def test_society_dir_for
    assert_equal 'a/b/c.society',
                 LLM::Agent.society_dir_for('a/b/c.chat')
    assert_equal 'a/b/worker.society',
                 LLM::Agent.society_dir_for('a/b/worker.chat')
    assert_equal './c.society',
                 LLM::Agent.society_dir_for('c.chat')
    agent = LLM::Agent.new
    assert_equal 'a/b/c.society',
                 agent.society_dir_for('a/b/c.chat')
  end

  def test_society_dir_by_location
    agent = LLM::Agent.new

    nested = 'a/society/Worker/w_1/agent.chat'
    # A nested agent.chat nests its society as a SIBLING directory, never a
    # second `.files` tree of its own, however the save was triggered.
    assert_equal 'a/society/Worker/w_1/society', agent.society_dir(nested)
    assert agent.nested_save?(nested)

    assert_equal 'a/b/c.society', agent.society_dir('a/b/c.chat')
    assert !agent.nested_save?('a/b/c.chat')
  end

  def test_save_explicit_path_writes_only_the_chat_file
    TmpFile.with_dir do |dir|
      agent = simple_agent
      agent.user 'hello'

      chat_file = File.join(dir, 'conversation.chat')
      written = agent.save(chat_file)

      assert_equal [File.expand_path(chat_file)], written
      assert Open.exist?(chat_file)
      assert_include Open.read(chat_file), 'hello'

      # Lazy: no society, so no .files sidecar tree at all
      assert !Open.exist?(chat_file + '.files')
    end
  end

  def test_save_without_path_uses_save_file
    TmpFile.with_dir do |dir|
      agent = simple_agent
      agent.user 'stored'

      chat_file = File.join(dir, 'auto.chat')
      agent.save_file = chat_file

      assert_equal [File.expand_path(chat_file)], agent.save
      assert_include Open.read(chat_file), 'stored'
    end
  end

  def test_save_without_path_raises_when_unconfigured
    agent = simple_agent
    agent.user 'orphan'

    assert_raise ScoutException do
      agent.save
    end
  end

  def test_save_nested_society
    TmpFile.with_dir do |dir|
      root = simple_agent('root')
      root.user 'root question'

      child = simple_agent('child')
      child.user 'child question'
      root.chats = { 'Worker/w_A' => child }

      grandchild = simple_agent('grandchild')
      grandchild.user 'grandchild question'
      child.chats = { 'Critic/c_1' => grandchild }

      chat_file = File.join(dir, 'root.chat')
      written = root.save(chat_file)

      expected_child = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Worker', 'w_A', 'agent.chat')
      expected_grandchild = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Worker', 'w_A', 'society', 'Critic', 'c_1', 'agent.chat')

      assert_equal [chat_file, expected_child, expected_grandchild].collect { |p| File.expand_path(p) }.sort, written

      assert_include Open.read(expected_child), 'child question'
      assert_include Open.read(expected_grandchild), 'grandchild question'

      # child learned its own save_file for later independent auto-saves
      assert_equal expected_child, child.save_file
      assert_equal expected_grandchild, grandchild.save_file
    end
  end

  def test_save_cyclic_society_terminates
    TmpFile.with_dir do |dir|
      a = simple_agent('a')
      a.user 'a question'
      b = simple_agent('b')
      b.user 'b question'

      a.chats = { 'Other/current' => b }
      b.chats = { 'First/current' => a }

      chat_file = File.join(dir, 'cycle.chat')
      written = a.save(chat_file)

      expected_b = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Other', 'current', 'agent.chat')
      assert_equal [chat_file, expected_b].collect { |p| File.expand_path(p) }.sort, written

      # The tree is finite: b was saved once and going back to a was cut by
      # the seen-agent check, so nothing was written twice.
      assert_equal 1, chat_files_under(chat_file.sub(/\.chat\z/, '.society')).length
    end
  end

  def test_save_skips_dead_entries
    TmpFile.with_dir do |dir|
      agent = simple_agent
      agent.chats = { 'Worker/w_1' => nil, 'no-slash' => simple_agent, '/lead' => simple_agent }

      chat_file = File.join(dir, 'dead.chat')
      written = agent.save(chat_file)

      assert_equal [File.expand_path(chat_file)], written
    end
  end

  def test_save_sanitizes_weird_names
    TmpFile.with_dir do |dir|
      agent = simple_agent
      bad = simple_agent('weird')
      bad.user 'weird question'

      agent.chats = { '../evil/name' => bad }

      chat_file = File.join(dir, 'sanitized.chat')
      written = agent.save(chat_file)

      # '..' collapses to '_' and the '/' inside the conversation is
      # replaced, so the file stays inside the society directory
      weird_file = File.join(chat_file.sub(/\.chat\z/, '.society'), '__', 'evil_name', 'agent.chat')
      assert_include written.collect { |p| File.expand_path(p) },
                     File.expand_path(weird_file)
      assert !Open.exist?(File.join(dir, 'name', 'agent.chat'))
    end
  end

  def test_auto_save_after_ask
    TmpFile.with_dir do |dir|
      LLM::Mock.script('mock answer')

      agent = simple_agent
      chat_file = File.join(dir, 'auto_save.chat')
      agent.save_file = chat_file

      agent.user 'auto question'
      res = agent.chat persist: false, backend: :mock

      assert_equal 'mock answer', res
      content = Open.read(chat_file)
      assert_include content, 'auto question'
      assert_include content, 'mock answer'
    end
  end

  def test_child_auto_save_keeps_canonical_layout
    TmpFile.with_dir do |dir|
      LLM::Mock.script('mock answer')

      root = simple_agent('root')
      root.user 'root question'

      child = simple_agent('child')
      child.user 'child question'
      root.chats = { 'Worker/w_A' => child }

      chat_file = File.join(dir, 'root.chat')
      root.save(chat_file)

      child_file = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Worker', 'w_A', 'agent.chat')
      assert_equal child_file, child.save_file

      # The child runs its own turn later (its own auto-save, no parent save):
      # the answer must land in the child chat file and the grandchild must
      # go to the SIBLING society dir, never to <child_file>.files/...
      grandchild = simple_agent('grandchild')
      grandchild.user 'grandchild question'
      child.chats = { 'Critic/c_1' => grandchild }

      child.chat persist: false, backend: :mock

      assert_include Open.read(child_file), 'mock answer'

      assert Open.exist?(File.join(File.dirname(child_file), 'society', 'Critic', 'c_1', 'agent.chat'))
      assert !Open.exist?(child_file + '.files')
      assert !Dir.glob(File.join(chat_file + '.files', '**', 'agent.chat.files')).any?
    end
  end

  # A bare agent.ask round does not grow current_chat, so it must NOT
  # auto-save: the auto-save hook fires on Agent#chat, not on ask.
  def test_no_auto_save_after_bare_ask
    TmpFile.with_dir do |dir|
      # Plain-string script: no tool calls, so the round is a single
      # assistant answer that never enters Agent#chat.
      LLM::Mock.script('mock answer')

      agent = simple_agent
      chat_file = File.join(dir, 'ask_save.chat')
      agent.save_file = chat_file
      agent.user 'bare question'

      assert_include agent.ask(agent.current_chat, persist: false, backend: :mock), 'mock answer'

      # Bare ask: the chat was not grown by Agent#chat, so no file anywhere
      assert !Open.exist?(chat_file)
      assert_equal [], Dir.glob(File.join(dir, '**', '*.chat'))
    end
  end

  # The chat path does persist growth: a round with a delegated tool call
  # grows current_chat inside Agent#chat (function_call /
  # function_call_output plus the answer), so the auto-save fires, and the
  # delegated child conversation is saved with it into the society tree.
  def test_auto_save_after_tool_round_via_chat
    TmpFile.with_dir do |dir|
      LLM::Mock.script([
        {tool_calls: [{name: 'ask', arguments: {agent: 'Worker', prompt: 'hi'}}]},
        'final answer'
      ])

      agent = simple_agent('root')
      worker = simple_agent('worker')
      # ScoutCoder: the specialist's round is launched by LLM.process_calls
      # as 'agent.chat return_messages: true' with NO call options, so only
      # its own other_options can keep it on the mock backend on a DIRECT
      # run where an account endpoint (env LLM/ASK_ENDPOINT or
      # ~/.scout/etc/AI/<endpoint>.yaml) would otherwise override the
      # test_helper config pin and send the child round to a real client.
      worker.other_options = IndiferentHash.setup(backend: :mock, persist: false)
      agent.society = { 'Worker' => worker }
      agent.socialize

      chat_file = File.join(dir, 'tool_round.chat')
      agent.save_file = chat_file
      agent.user 'tool question'

      assert_equal 'final answer', agent.chat(persist: false, backend: :mock)

      # The parent chat file holds the tool round and its answer
      content = Open.read(chat_file)
      assert_include content, 'tool question'
      assert_include content, 'function_call'
      assert_include content, 'final answer'

      # The delegated child conversation was saved with it, lazily, under the
      # canonical society layout
      child_file = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Worker', 'default', 'agent.chat')
      assert Open.exist?(child_file)
      assert_include Open.read(child_file), 'hi'
    end
  end

  # The dropped legacy layout: saving an agent (with society conversations)
  # must NOT create a `.files/log` tree at all, while still producing the
  # canonical files: the root chat copy and the society conversations.
  def test_save_produces_no_legacy_log_tree
    TmpFile.with_dir do |dir|
      LLM::Mock.script([
        {tool_calls: [{name: 'ask', arguments: {agent: 'Worker', prompt: 'hi'}}]},
        'final answer'
      ])

      agent = simple_agent('root')
      worker = simple_agent('worker')
      # ScoutCoder: the specialist's round is launched by LLM.process_calls
      # as 'agent.chat return_messages: true' with NO call options, so only
      # its own other_options can keep it on the mock backend on a DIRECT
      # run where an account endpoint (env LLM/ASK_ENDPOINT or
      # ~/.scout/etc/AI/<endpoint>.yaml) would otherwise override the
      # test_helper config pin and send the child round to a real client.
      worker.other_options = IndiferentHash.setup(backend: :mock, persist: false)
      agent.society = { 'Worker' => worker }
      agent.socialize

      chat_file = File.join(dir, 'root.chat')
      agent.save_file = chat_file
      agent.user 'root question'
      assert_equal 'final answer', agent.chat(persist: false, backend: :mock)
      agent.save

      legacy_dir = File.join(chat_file + '.files', 'log')
      refute Open.exist?(legacy_dir),
             'legacy .files/log tree must not be created by saving'

      # Canonical files are all there: the root chat itself (a plain
      # save_file owns no .files copy; only CLI/workflow-anchored save files
      # live inside a .files dir) and the society conversation.
      assert Open.exist?(chat_file), 'root chat file must be written'
      assert_include Open.read(chat_file), 'root question'
      society_chat = File.join(chat_file.sub(/\.chat\z/, '.society'), 'Worker', 'default', 'agent.chat')
      assert Open.exist?(society_chat),
             'canonical society conversation must be written'
      assert_include Open.read(society_chat), 'hi'
    end
  end

  def test_no_auto_save_without_save_file
    TmpFile.with_dir do |dir|
      LLM::Mock.script('mock answer')

      agent = simple_agent
      agent.user 'volatile question'
      agent.chat persist: false, backend: :mock

      assert !Open.exist?(File.join(dir, 'never.chat'))
      assert_equal [], Dir.glob(File.join(dir, '**', '*.chat'))
    end
  end

  def test_restart_snapshot
    TmpFile.with_dir do |dir|
      agent = simple_agent
      chat_file = File.join(dir, 'restarts.chat')
      agent.save_file = chat_file

      agent.user 'before restart'
      agent.save

      resets_dir = chat_file + '.files/resets'
      assert !Open.exist?(resets_dir)

      agent.start

      assert Open.exist?(resets_dir)
      snapshots = Dir.glob(File.join(resets_dir, '*.chat'))
      assert_equal 1, snapshots.length
      assert_include File.basename(snapshots.first), '.chat'
      assert_include Open.read(snapshots.first), 'before restart'
    end
  end

  def test_no_restart_snapshot_without_prior_chat
    TmpFile.with_dir do |dir|
      agent = simple_agent
      chat_file = File.join(dir, 'fresh.chat')
      agent.save_file = chat_file

      agent.start

      assert !Open.exist?(chat_file + '.files/resets')
      assert !Open.exist?(chat_file + '.files')
    end
  end
end

# Step 3b: Agent#society_save_file (private, delegate.rb) must derive the
# society directory with the CANONICAL rule (Agent.society_dir_for /
# Agent#society_dir), never by unanchored string substitution on save_file.
#
# The bug: `"cli.chat.files/agent.chat".sub(/\.chat/, '.society')` replaces
# the FIRST '.chat' and yields `cli.society.files/agent.chat/...`, growing a
# second `.files` tree instead of `cli.chat.files/agent.society/...`.
class TestLLMAgentSocietySaveFile < Test::Unit::TestCase
  def simple_agent(content = 'you are a robot')
    agent = LLM::Agent.new
    agent.start_chat.system content
    agent
  end

  # --- direct (private method, called through send) -----------------------

  def test_society_save_file_is_nil_without_save_file
    agent = LLM::Agent.new
    # save.rb simply does not auto-save without a save_file; the delegation
    # must mirror that instead of raising on nil (assigning nil to
    # agent.save_file is harmless: it means "no auto-save").
    assert_nil agent.send(:society_save_file, 'Direct', 'harness_test')
  end

  def test_society_save_file_cli_shaped_save_file
    agent = LLM::Agent.new
    agent.save_file = 'dir/cli.chat.files/agent.chat'
    assert_equal 'dir/cli.chat.files/agent.society/Direct/harness_test/agent.chat',
                 agent.send(:society_save_file, 'Direct', 'harness_test')
  end

  def test_society_save_file_cli_shaped_named_agent
    agent = LLM::Agent.new
    agent.save_file = 'dir/job.chat.files/worker.chat'
    assert_equal 'dir/job.chat.files/worker.society/Direct/harness_test/agent.chat',
                 agent.send(:society_save_file, 'Direct', 'harness_test')
  end

  # CLI `ask --chat` builds its agent save file from the chat's files_dir
  # through Agent.canonical_chat_file (scout_commands/agent/ask and
  # scout_commands/llm/ask); these mirror the two layouts that CLI accepts.
  def test_canonical_chat_file_cli_shaped_save_file
    assert_equal 'dir/cli.chat.files/agent.chat',
                 LLM::Agent.canonical_chat_file('dir/cli.chat.files', nil)
  end

  def test_canonical_chat_file_cli_shaped_named_agent
    assert_equal 'dir/job.chat.files/worker.chat',
                 LLM::Agent.canonical_chat_file('dir/job.chat.files', 'worker')
  end

  def test_society_save_file_plain_root_chat
    agent = LLM::Agent.new
    agent.save_file = 'dir/root.chat'
    assert_equal 'dir/root.society/Direct/harness_test/agent.chat',
                 agent.send(:society_save_file, 'Direct', 'harness_test')
  end

  def test_society_save_file_nested_child_save_file
    agent = LLM::Agent.new
    # A child chat already living inside a society tree resolves through the
    # location rule: the society of a nested chat is a SIBLING 'society' dir.
    agent.save_file = 'dir/root.chat.files/root.society/Direct/harness_test/agent.chat'
    assert_equal 'dir/root.chat.files/root.society/Direct/harness_test/society/Nested/default/agent.chat',
                 agent.send(:society_save_file, 'Nested', 'default')
  end

  # --- public behavior ----------------------------------------------------

  # load_chat hands the specialist its save_file derived from the PARENT's
  # save_file: this is the path the CLI and chat_task jobs take.
  def test_load_chat_assigns_canonical_child_save_file
    TmpFile.with_dir do |dir|
      root = simple_agent('root')
      worker = simple_agent('worker')
      root.society = {'Worker' => worker}
      root.socialize

      root.save_file = File.join(dir, 'cli.chat.files', 'agent.chat')
      child = root.load_chat('Worker', {}, 'harness_test')

      expected = File.join(dir, 'cli.chat.files', 'agent.society',
                           'Worker', 'harness_test', 'agent.chat')
      assert_equal expected, child.save_file

      # Writing through the child must not grow any second `.files` tree and
      # must not leave a stray `cli.society.files` directory behind.
      LLM::Mock.script('mock answer')
      child.user 'child question'
      child.chat persist: false, backend: :mock

      assert_include Open.read(expected), 'mock answer'
      assert_empty Dir.glob(File.join(dir, '**', '*.society.files*'))
      assert_empty Dir.glob(File.join(dir, '**', 'cli.society*'))
      # The child auto-save is the only writer here (the root itself never
      # ran a round), so the canonical child file is the ONLY chat file.
      assert_equal [expected], Dir.glob(File.join(dir, '**', '*.chat')).sort
    end
  end
end
