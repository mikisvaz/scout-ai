require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')
require 'scout/llm/backends/anthropic'

class TestPrompt < Test::Unit::TestCase

  def setup
    super
    Chat::REGISTERED_STRATEGIES.delete('probe_strategy')
  end

  def teardown
    Chat::REGISTERED_STRATEGIES.delete('probe_strategy')
    super
  end

  def base_messages
    Chat.setup([{ role: 'user', content: 'question' }])
  end

  def inbox_for(save_file, names_and_contents = {})
    inbox_dir = File.join(save_file.to_s + '.files', 'inbox')
    FileUtils.mkdir_p inbox_dir
    names_and_contents.each do |name, content|
      Open.write(File.join(inbox_dir, name), content)
    end
    inbox_dir
  end

  def user_tail(messages, count = nil)
    injected = messages.select{|m| m[:role].to_s == 'user' }
    injected = injected.last(count) if count
    injected.collect{|m| m[:content] }
  end

  def test_inbox_no_save_file_is_noop_and_creates_nothing
    messages = base_messages
    result = Chat.prepare_prompt(messages, ['inbox'])

    assert_equal 1, result.length
    assert !Open.exist?(File.join(Dir.pwd, 'inbox'))

    TmpFile.with_file do |save_file|
      result = Chat.prepare_prompt(messages, ['inbox'], save_file: nil)
      assert_equal 1, result.length
      # Nothing is created anywhere: not the files dir, not inbox/, not
      # inbox_removed/.
      assert !Open.exist?(save_file + '.files')
    end
  end

  def test_inbox_missing_inbox_dir_is_noop_and_creates_nothing
    TmpFile.with_file do |save_file|
      Open.mkdir(save_file + '.files')

      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert_equal 1, result.length
      # The read path never creates the inbox, nor the removed dir
      assert !Open.exist?(File.join(save_file + '.files', 'inbox'))
      assert !Open.exist?(File.join(save_file + '.files', 'inbox_removed'))
    end
  end

  def test_inbox_missing_files_dir_is_noop
    TmpFile.with_file do |save_file|
      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert_equal 1, result.length
      assert !Open.exist?(save_file + '.files')
    end
  end

  def test_inbox_appends_in_sorted_order_moves_files_and_preserves_mtime
    TmpFile.with_file do |save_file|
      mtimes = {}
      inbox_dir = inbox_for(save_file,
                            'b_second.md' => 'second notice',
                            'a_first.md' => 'first notice',
                            '10_numeric.md' => 'numeric ten',
                            'c_third.md' => 'third notice',
                            '2_numeric.md' => 'numeric two')
      Dir.glob(File.join(inbox_dir, '*')).sort.each do |file|
        mtimes[file] = Time.now - 100_000 - rand(1000)
        File.utime(mtimes[file], mtimes[file], file)
      end
      expected_order = Dir.glob(File.join(inbox_dir, '*')).collect{|f| File.basename(f) }.sort
      expected_contents = expected_order.collect{|n| Open.read(File.join(inbox_dir, n)) }

      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert_equal 6, result.length
      assert_equal 'question', result.first[:content]
      assert_equal expected_contents, user_tail(result, 5)

      assert_equal [], Dir.glob(File.join(inbox_dir, '*'))
      removed = File.join(save_file + '.files', 'inbox_removed')
      removed_files = Dir.glob(File.join(removed, '*')).sort
      assert_equal expected_order, removed_files.collect{|f| File.basename(f) }
      removed_files.each do |file|
        assert_equal mtimes.find{|k,_| File.basename(k) == File.basename(file) }.last, File.mtime(file)
      end
    end
  end

  def test_inbox_skips_directories_and_dotfiles
    TmpFile.with_file do |save_file|
      inbox_dir = inbox_for(save_file, 'a_msg.md' => 'real message')
      FileUtils.mkdir_p File.join(inbox_dir, 'subdir')
      Open.write(File.join(inbox_dir, '.hidden'), 'ignored')

      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert_equal 2, result.length
      assert_equal ['real message'], user_tail(result, 1)
      # Directories and dotfiles are left alone, not moved into inbox_removed/
      assert Open.directory?(File.join(inbox_dir, 'subdir'))
      assert_equal ['a_msg.md'], Dir.glob(File.join(save_file + '.files', 'inbox_removed', '*')).collect{|f| File.basename(f) }
      assert !Open.exist?(File.join(save_file + '.files', 'inbox_removed', 'subdir'))
    end
  end

  def test_inbox_is_consume_once
    TmpFile.with_file do |save_file|
      inbox_for(save_file, 'a_msg.md' => 'once')

      first = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)
      assert_equal 2, first.length

      second = Chat.prepare_prompt(first, ['inbox'], save_file: save_file)
      assert_equal 2, second.length
      assert_equal ['once'], user_tail(second, 1)
    end
  end

  def test_inbox_collision_in_removed_gets_numeric_suffix
    TmpFile.with_file do |save_file|
      inbox_for(save_file, 'a_msg.md' => 'original delivery')
      removed_dir = File.join(save_file + '.files', 'inbox_removed')
      FileUtils.mkdir_p removed_dir
      Open.write(File.join(removed_dir, 'a_msg.md'), 'previous delivery')
      previous_mtime = File.mtime(File.join(removed_dir, 'a_msg.md'))
      sleep 0.1

      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert_equal 2, result.length
      assert_equal ['original delivery'], user_tail(result, 1)

      files = Dir.glob(File.join(removed_dir, '*')).sort
      assert_equal ['a_msg.1.md', 'a_msg.md'], files.collect{|f| File.basename(f) }
      assert_equal 'previous delivery', Open.read(File.join(removed_dir, 'a_msg.md'))
      assert_equal 'original delivery', Open.read(File.join(removed_dir, 'a_msg.1.md'))
      assert_equal previous_mtime, File.mtime(File.join(removed_dir, 'a_msg.md'))
    end
  end

  def test_inbox_unreadable_file_is_skipped_without_raising
    return if Process.uid.zero? # chmod 000 does not stop root

    TmpFile.with_file do |save_file|
      inbox_dir = inbox_for(save_file,
                            'a_msg.md' => 'delivered',
                            'z_locked.md' => 'locked away')
      FileUtils.chmod(0000, File.join(inbox_dir, 'z_locked.md'))

      result = nil
      assert_nothing_raised do
        result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)
      end

      assert_equal ['delivered'], user_tail(result, 1)
      # The unreadable file stays in place for a later retry
      locked = File.join(inbox_dir, 'z_locked.md')
      assert Open.exist?(locked)
      # Only the readable file was delivered; the locked one was not moved
      assert_equal ['a_msg.md'], Dir.glob(File.join(save_file + '.files', 'inbox_removed', '*')).collect{|f| File.basename(f) }
    end
  end

  def test_inbox_returns_chat_annotated_array
    TmpFile.with_file do |save_file|
      inbox_for(save_file, 'a_msg.md' => 'message')

      result = Chat.prepare_prompt(base_messages, ['inbox'], save_file: save_file)

      assert Chat === result
      assert Chat === Chat.prepare_prompt(result, ['inbox'], save_file: save_file)
    end
  end

  def test_inbox_composes_with_shorten_tools_epoch_increment_in_both_orders
    messages = Chat.setup([
      { role: 'user', content: 'question' },
      { role: 'function_call', content: { 'name' => 'echo', 'arguments' => {}, 'call_id' => 'c1' }.to_json },
      { role: 'function_call_output', content: 'output' },
    ])

    TmpFile.with_file do |save_file|
      inbox_for(save_file, 'a_msg.md' => 'injected notice')

      inbox_first = Chat.prepare_prompt(messages, ['inbox', 'shorten_tools_epoch_increment'], save_file: save_file)
      # Inbox first: appended user message must survive the shortener and
      # remain the last message.
      assert Chat === inbox_first
      assert_equal 'injected notice', inbox_first.last[:content]
      assert_equal 'user', inbox_first.last[:role].to_s

      inbox_for(save_file, 'b_msg.md' => 'second notice')
      inbox_last = Chat.prepare_prompt(messages, ['shorten_tools_epoch_increment', 'inbox'], save_file: save_file)
      # Shortener first: still applies and the single-argument shorten
      # strategy is unaffected by the new save_file keyword.
      assert Chat === inbox_last
      assert_equal 'second notice', inbox_last.last[:content]
    end
  end

  def test_prepare_prompt_forwards_save_file_only_to_strategies_that_accept_it
    # A single-argument strategy must not see (nor choke on) the new keyword.
    assert_nothing_raised do
      Chat.prepare_prompt(base_messages, ['shorten_tools'], save_file: 'unused.chat')
    end
  end

  # The registered-proc form still receives only the prompt (documented
  # behavior), and does not break when save_file is forwarded.
  def test_prepare_prompt_registered_proc_ignores_save_file
    Chat::REGISTERED_STRATEGIES['probe_strategy'] = ->(messages) { messages }
    TmpFile.with_file do |save_file|
      assert_nothing_raised do
        result = Chat.prepare_prompt(base_messages, ['probe_strategy'], save_file: save_file)
        assert_equal 1, result.length
      end
    end
  end

  # prompt_strategies is extracted (deleted) from options inside
  # Backend#ask; chain_tools must re-thread it like save_file so a
  # user-specified list applies to tool-call re-entry rounds too, instead of
  # degrading to DEFAULT_CONTEXT_STRATEGY on round 2+.
  def test_prompt_strategies_survive_tool_call_re_entry
    probe_calls = []
    Chat::REGISTERED_STRATEGIES['probe_strategy'] = ->(messages) { probe_calls << messages.dup; messages }

    client = TestFixtures.anthropic_client('backends/anthropic_tool_use', 'backends/anthropic')
    assert_equal 2, client.responses.length

    LLM::Anthropic.ask 'user: call the tool', tools: [{ type: 'custom', name: 'get_current_temperature', description: 'w', input_schema: { type: 'object' } }],
                       client: client, persist: false, prompt_strategies: 'probe_strategy' do |name, arguments|
      'It is raining.'
    end

    assert_equal 2, client.calls.length, 'expected a tool-call round plus a final answer round'
    assert_equal 2, probe_calls.length, 'user prompt_strategies must apply on every round, re-entry included'
  end
end
