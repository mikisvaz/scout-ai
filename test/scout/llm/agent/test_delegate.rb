require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMAgentDelegate < Test::Unit::TestCase
  def setup
    super
    @dir = File.join(tmpdir, 'delegate_tests')
    FileUtils.mkdir_p @dir
  end

  def worker_agent(content = 'worker helper')
    LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: content}]))
  end

  def parent_agent(content = 'parent')
    agent = LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: content}]))
    agent
  end

  # Run the delegate tool block exactly like process_calls would: tools hash
  # lookup then block.call(name, arguments).
  def invoke_hand_off(agent, tool_name, arguments = {})
    tools = agent.other_options[:tools]
    assert tools.key?(tool_name), "tool #{tool_name} not registered"
    block, _definition = tools[tool_name]
    block.call(tool_name, IndiferentHash.setup(arguments.dup))
  end

  def message_contents(chat, role)
    chat.select { |m| m[:role].to_s == role.to_s }.collect { |m| m[:content] }
  end

  def test_default_block_returns_an_agent
    root = parent_agent
    root.delegate worker_agent, 'Worker', 'Hand work to the worker'

    result = invoke_hand_off(root, :hand_off_to_Worker, message: 'do something')

    assert LLM::Agent === result
  end

  def test_parent_save_sweeps_the_hand_off_child
    TmpFile.with_dir do |dir|
      LLM::Mock.script('worker answer')

      root = parent_agent
      root.save_file = File.join(dir, 'root.chat')
      root.delegate worker_agent, 'Worker', 'Hand work to the worker'

      result = invoke_hand_off(root, :hand_off_to_Worker, message: 'first task')
      result.chat persist: false, endpoint: 'mock', backend: :mock

      root.save

      child_file = File.join(dir, 'root.society', 'Worker', 'Worker', 'agent.chat')
      assert Open.exist?(child_file)
      assert_include Open.read(child_file), 'first task'
      assert_include Open.read(child_file), 'worker answer'
    end
  end

  def test_state_persists_across_calls_and_rebranches_on_new_conversation
    root = parent_agent
    root.delegate worker_agent, 'Worker', 'Hand work to the worker'

    first = invoke_hand_off(root, :hand_off_to_Worker, message: 'first message')
    second = invoke_hand_off(root, :hand_off_to_Worker, message: 'second message')

    assert_same first, second
    assert_equal ['first message', 'second message'],
                 message_contents(second.current_chat, :user)

    # new_conversation re-branches: prior user messages dropped, start_chat kept
    third = invoke_hand_off(root, :hand_off_to_Worker,
                            message: 'fresh start', new_conversation: true)
    assert_same first, third
    assert_equal ['fresh start'], message_contents(third.current_chat, :user)
    assert_equal ['worker helper'], message_contents(third.current_chat, :system)
  end

  def test_conversation_agent_returns_the_live_registered_agent
    root = parent_agent
    worker = worker_agent
    before = worker.current_chat.length

    root.delegate worker, 'Worker', 'Hand work to the worker'
    registered = invoke_hand_off(root, :hand_off_to_Worker, message: 'task')

    # The registered holder is reachable by key and is the block's return
    assert_same registered, root.conversation_agent('Worker/Worker')
    assert_nil root.conversation_agent('Worker/missing')

    # The passed-in agent object is NOT the conversation holder anymore: its
    # chat does not advance (staleness is visible, not silent).
    assert_equal before, worker.current_chat.length
    assert message_contents(worker.current_chat, :user).empty?
    assert_include message_contents(registered.current_chat, :user), 'task'
  end

  def test_hyphenated_name_gives_a_sanitized_slot
    TmpFile.with_dir do |dir|
      LLM::Mock.script('worker answer')

      root = parent_agent
      root.save_file = File.join(dir, 'root.chat')
      root.delegate worker_agent, 'data-miner', 'Hand work to the miner'

      # The tool name keeps the raw hyphen; only the conversation slot is
      # sanitized (hyphens are legal in both, so slot == name here)
      result = invoke_hand_off(root, :'hand_off_to_data-miner', message: 'mine')
      result.chat persist: false, endpoint: 'mock', backend: :mock
      root.save

      child_file = File.join(dir, 'root.society', 'data-miner', 'data-miner', 'agent.chat')
      assert Open.exist?(child_file), "expected #{child_file}"
      assert_include Open.read(child_file), 'mine'
    end
  end

  def test_pre_registered_agent_is_the_society_template
    root = parent_agent
    worker = worker_agent

    root.delegate worker, 'Worker', 'Hand work to the worker'

    # The passed agent became the template for that name in @society
    assert_same worker, root.society['Worker']
    # A socialize ask of the same name clones THAT template, not an installed one
    root.socialize
    ask_result = invoke_hand_off(root, :ask,
                                 agent: 'Worker', prompt: 'via ask tool')
    assert_not_same worker, ask_result
  end

  def test_custom_block_receives_the_passed_agent_and_mutates_it
    root = parent_agent
    worker = worker_agent

    root.delegate worker, 'Worker', 'Hand work to the worker' do |_name, parameters|
      worker.user "custom: #{parameters[:message]}"
      worker
    end

    result = invoke_hand_off(root, :hand_off_to_Worker, message: 'custom work')

    assert_same worker, result
    assert_equal ['custom: custom work'], message_contents(worker.current_chat, :user)
  end

  def test_non_agent_duck_object_keeps_legacy_path
    duck = Object.new
    seen = []
    duck.define_singleton_method(:start) { seen << :start }
    duck.define_singleton_method(:user) { |message| seen << [:user, message]; self }

    root = parent_agent
    root.delegate duck, 'Duck', 'Hand work to the duck'

    result = invoke_hand_off(root, :hand_off_to_Duck,
                             message: 'quack', new_conversation: true)

    assert_same duck, result
    assert_equal [:start, [:user, 'quack']], seen
    assert_nil root.chats
  end

  def test_bad_hand_off_returns_the_exception_not_a_raise
    root = parent_agent

    root.delegate worker_agent, 'Worker', 'Hand work to the worker'

    # A message that is not a String raises ParameterException (a
    # ScoutException subclass) inside ask_conversation; the block must return
    # the exception rather than aborting the tool round.
    result = invoke_hand_off(root, :hand_off_to_Worker, message: nil)

    assert ParameterException === result
  end

  def test_adopt_current_folds_template_progress_into_the_seed
    template = worker_agent
    template.user 'template progress'
    template.current_chat.push({role: :assistant, content: 'template answer'})

    root = parent_agent
    root.delegate template, 'Worker', 'Hand work to the worker'
    registered = invoke_hand_off(root, :hand_off_to_Worker, message: 'new task')

    # Seed order: start_chat copy, adopted delta, then the delegated message
    assert_include message_contents(registered.current_chat, :user), 'template progress'
    assert_include message_contents(registered.current_chat, :assistant), 'template answer'
    assert_equal ['template progress', 'new task'],
                 message_contents(registered.current_chat, :user)
    assert_equal ['worker helper'], message_contents(registered.current_chat, :system)
    # The template itself is untouched
    assert_equal ['template progress'], message_contents(template.current_chat, :user)
  end

  def test_adopt_with_empty_template_current_chat_is_a_no_op
    template = worker_agent

    root = parent_agent
    root.delegate template, 'Worker', 'Hand work to the worker'
    registered = invoke_hand_off(root, :hand_off_to_Worker, message: 'only message')

    assert_equal ['worker helper'], message_contents(registered.current_chat, :system)
    assert_equal ['only message'], message_contents(registered.current_chat, :user)
  end
end
