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
    assert_equal 'a/b/c.chat.files/log/society',
                 LLM::Agent.society_dir_for('a/b/c.chat')
    agent = LLM::Agent.new
    assert_equal 'a/b/c.chat.files/log/society',
                 agent.society_dir_for('a/b/c.chat')
  end

  def test_society_dir_by_location
    agent = LLM::Agent.new

    nested = 'a/society/Worker/w_1/agent.chat'
    # A nested agent.chat nests its society as a SIBLING directory, never a
    # second `.files` tree of its own, however the save was triggered.
    assert_equal 'a/society/Worker/w_1/society', agent.society_dir(nested)
    assert agent.nested_save?(nested)

    assert_equal 'a/b/c.chat.files/log/society', agent.society_dir('a/b/c.chat')
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

      expected_child = File.join(chat_file + '.files', 'log', 'society', 'Worker', 'w_A', 'agent.chat')
      expected_grandchild = File.join(chat_file + '.files', 'log', 'society', 'Worker', 'w_A', 'society', 'Critic', 'c_1', 'agent.chat')

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

      expected_b = File.join(chat_file + '.files', 'log', 'society', 'Other', 'current', 'agent.chat')
      assert_equal [chat_file, expected_b].collect { |p| File.expand_path(p) }.sort, written

      # The tree is finite: b was saved once and going back to a was cut by
      # the seen-agent check, so nothing was written twice.
      assert_equal 1, chat_files_under(chat_file + '.files').length
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
      weird_file = File.join(chat_file + '.files', 'log', 'society', '__', 'evil_name', 'agent.chat')
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
      res = agent.chat persist: false, endpoint: 'mock'

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

      child_file = File.join(chat_file + '.files', 'log', 'society', 'Worker', 'w_A', 'agent.chat')
      assert_equal child_file, child.save_file

      # The child runs its own turn later (its own auto-save, no parent save):
      # the answer must land in the child chat file and the grandchild must
      # go to the SIBLING society dir, never to <child_file>.files/...
      grandchild = simple_agent('grandchild')
      grandchild.user 'grandchild question'
      child.chats = { 'Critic/c_1' => grandchild }

      child.chat persist: false, endpoint: 'mock'

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

      assert_include agent.ask(agent.current_chat, persist: false, endpoint: :mock), 'mock answer'

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
      agent.society = { 'Worker' => worker }
      agent.socialize

      chat_file = File.join(dir, 'tool_round.chat')
      agent.save_file = chat_file
      agent.user 'tool question'

      assert_equal 'final answer', agent.chat(persist: false, endpoint: 'mock')

      # The parent chat file holds the tool round and its answer
      content = Open.read(chat_file)
      assert_include content, 'tool question'
      assert_include content, 'function_call'
      assert_include content, 'final answer'

      # The delegated child conversation was saved with it, lazily, under the
      # canonical society layout
      child_file = File.join(chat_file + '.files', 'log', 'society', 'Worker', 'default', 'agent.chat')
      assert Open.exist?(child_file)
      assert_include Open.read(child_file), 'hi'
    end
  end

  def test_no_auto_save_without_save_file
    TmpFile.with_dir do |dir|
      LLM::Mock.script('mock answer')

      agent = simple_agent
      agent.user 'volatile question'
      agent.chat persist: false, endpoint: 'mock'

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
