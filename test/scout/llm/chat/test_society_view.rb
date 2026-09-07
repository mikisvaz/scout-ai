require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMChatSocietyView < Test::Unit::TestCase
  def wfdir
    @wfdir ||= begin
      dir = Path.setup(Workflow.directory['society-view-wf'])
      Workflow.directory = dir
      dir
    end
  end

  def root_chat
    @root_chat ||= begin
      sf = tmpdir['society-view'].find + '.chat'
      Open.rm_rf(sf)
      FileUtils.mkdir_p(File.dirname(sf))
      FileUtils.touch(sf)
      sf
    end
  end

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

  def write_child(agent, conversation, *messages)
    dir = File.join(File.dirname(root_chat), File.basename(root_chat).sub(/\.chat\z/, '.society'), agent, conversation)
    FileUtils.mkdir_p(dir)
    file = File.join(dir, 'agent.chat')
    Open.write(file, Chat.print(messages))
    file
  end

  # ---------------------------------------------------------------
  # Society dir derivation
  # ---------------------------------------------------------------

  def test_society_dir_of_root_save_file
    assert_equal File.join(File.dirname(root_chat), 'society-view.society'),
                 Chat.society_dir_of(root_chat)
  end

  def test_society_dir_of_nested_child_matches_agent_rule
    nested = File.join(File.dirname(root_chat), 'society-view.society', 'Worker', 'run', 'agent.chat')
    assert_equal LLM::Agent.new.society_dir(nested),
                 Chat.society_dir_of(nested)
    assert_equal File.join(File.dirname(root_chat), 'society-view.society', 'Worker', 'run', 'society'),
                 Chat.society_dir_of(nested)
  end

  def test_missing_society_dir_is_silent
    assert_equal [], Chat.society_agent_chats(root_chat)
    assert_equal [], Chat.society_live(root_chat, captured: [])
  end

  # ---------------------------------------------------------------
  # Plain child: activity only (no job= meta ever written)
  # ---------------------------------------------------------------

  def test_active_plain_child_reports_agent_activity
    write_child('Worker', 'run', {role: 'user', content: 'hi'})
    entries = Chat.society_live(root_chat, captured: [])
    assert_equal 1, entries.length
    entry = entries.first
    assert_equal :agent_activity, entry[:kind]
    assert_equal 'Worker', entry[:agent]
    assert_equal 'run', entry[:conversation]
    assert_equal File.join('Worker', 'run', 'agent.chat'), entry[:relative]
    assert_equal :dispatched, entry[:activity][:reason]
    refute entry.key?(:job)
  end

  def test_tool_round_plain_child_reports_agent_activity
    write_child('Worker', 'run',
                {role: 'user', content: 'hi'},
                {role: 'assistant', content: 'hm'},
                {role: 'function_call', content: {name: 'slow', arguments: {}, id: 'c1'}.to_json})
    entries = Chat.society_live(root_chat, captured: [])
    assert_equal 1, entries.length
    assert_equal :agent_activity, entries.first[:kind]
    assert_equal :tool_round_in_flight, entries.first[:activity][:reason]
  end

  def test_finished_child_is_silent
    write_child('Worker', 'run',
                {role: 'user', content: 'hi'},
                {role: 'assistant', content: 'bye'})
    assert_equal [], Chat.society_live(root_chat, captured: [])
  end

  # ---------------------------------------------------------------
  # Workflow-backed child: dangling job wins, activity still included
  # ---------------------------------------------------------------

  def test_workflow_child_with_running_job_reports_dangling_job
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_child('Worker', 'run',
                {role: 'user', content: 'go'},
                {role: 'meta', content: 'job=WF/ask/one'})
    entries = Chat.society_live(root_chat, captured: [])
    assert_equal 1, entries.length
    entry = entries.first
    assert_equal :dangling_job, entry[:kind]
    assert_equal 'WF/ask/one', entry[:job]
    assert_equal :running, entry[:state]
    assert_equal 'Worker', entry[:agent]
    # the activity hash is present even when the dangling job wins
    assert_equal :dispatched, entry[:activity][:reason]
  end

  def test_captured_job_of_otherwise_finished_child_is_skipped
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    write_child('Worker', 'run',
                {role: 'user', content: 'go'},
                {role: 'meta', content: 'job=WF/ask/one'})
    assert_equal [], Chat.society_live(root_chat, captured: ['WF/ask/one'])
  end

  def test_multiple_children_report_sorted_by_path
    write_child('Zeta', 'run', {role: 'user', content: 'go'})
    write_child('Alpha', 'later', {role: 'user', content: 'go'})
    entries = Chat.society_live(root_chat, captured: [])
    assert_equal %w(Alpha Zeta), entries.collect { |e| e[:agent] }
  end

  # ---------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------

  def test_symlink_out_of_the_tree_is_not_followed
    outer = tmpdir['outer-society'].find
    FileUtils.mkdir_p(outer)
    Open.write(File.join(outer, 'agent.chat'), Chat.print([{role: 'user', content: 'outside'}]))
    link_dir = File.join(File.dirname(root_chat), 'society-view.society', 'Linked', 'run')
    FileUtils.mkdir_p(link_dir)
    File.symlink(outer, File.join(link_dir, 'agent.chat'))
    entries = Chat.society_live(root_chat, captured: [])
    assert_equal [], entries
  end

  def test_scan_depth_is_bounded
    deep = File.dirname(root_chat)
    200.times do
      deep = File.join(deep, 'society')
    end
    target = File.join(deep, 'a', 'b', 'agent.chat')
    FileUtils.mkdir_p(File.dirname(target))
    Open.write(target, Chat.print([{role: 'user', content: 'deep'}]))
    assert_equal [], Chat.society_agent_chats(root_chat)
  end
end
