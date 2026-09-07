require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestLLMChatAgentView < Test::Unit::TestCase
  # Same private workflow directory trick as TestLLMChatLiveWorkload:
  # Workflow.directory is reassigned by the shared setup in test_helper,
  # so point it lazily from the test bodies.
  def wfdir
    @wfdir ||= begin
      dir = Path.setup(Workflow.directory['agent-view-wf'])
      Workflow.directory = dir
      dir
    end
  end

  def agent_file
    @agent_file ||= begin
      sf = tmpdir['agent-view'].find + '.chat'
      Open.rm_rf sf
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

  def write_agent_chat(*messages)
    Open.rm_rf agent_file
    Open.write(agent_file, Chat.print(messages))
    agent_file
  end

  def dispatching_chat
    write_agent_chat({role: 'user', content: 'go'},
                     {role: 'meta', content: 'job=WF/ask/one'})
  end

  def test_trailing_user_message_is_active_dispatched
    write_agent_chat({role: 'user', content: 'go'})
    activity = Chat.agent_log_activity(agent_file)
    assert activity[:active]
    assert_equal :dispatched, activity[:reason]
    assert_equal 'user', activity[:last_role]
    assert_equal 1, activity[:message_count]
    assert_equal 0, activity[:rounds]
  end

  def test_trailing_function_call_without_output_is_tool_round_in_flight
    write_agent_chat({role: 'user', content: 'go'},
                     {role: 'assistant', content: 'hm'},
                     {role: 'function_call', content: {name: 'slow', arguments: {}, id: 'c1'}.to_json})
    activity = Chat.agent_log_activity(agent_file)
    assert activity[:active]
    assert_equal :tool_round_in_flight, activity[:reason]
    assert_equal 1, activity[:rounds]
  end

  def test_trailing_function_call_output_is_next_round_pending
    write_agent_chat({role: 'user', content: 'go'},
                     {role: 'function_call', content: {name: 'slow', arguments: {}, id: 'c1'}.to_json},
                     {role: 'function_call_output', content: 'slow done'})
    activity = Chat.agent_log_activity(agent_file)
    assert activity[:active]
    assert_equal :next_round_pending, activity[:reason]
    assert_equal 'function_call_output', activity[:last_role]
  end

  def test_trailing_assistant_without_open_call_is_idle
    write_agent_chat({role: 'user', content: 'go'},
                     {role: 'assistant', content: 'done'},
                     {role: 'meta', content: 'job=WF/ask/one'})
    activity = Chat.agent_log_activity(agent_file)
    refute activity[:active]
    assert_equal :idle, activity[:reason]
    # control roles (the trailing meta) are skipped when finding the last
    # conversational message
    assert_equal 'assistant', activity[:last_role]
    assert_equal 1, activity[:rounds]
  end

  def test_empty_file_and_missing_file_are_inactive
    Open.write(agent_file, '')
    activity = Chat.agent_log_activity(agent_file)
    refute activity[:active]
    assert_equal :no_messages, activity[:reason]

    activity = Chat.agent_log_activity(agent_file + '.missing')
    refute activity[:active]
    assert_equal :unreadable, activity[:reason]
  end

  def test_dangling_meta_followed_to_running_job
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    dispatching_chat
    entries = Chat.dangling_agent_job_metas(agent_file, captured: [])
    assert_equal 1, entries.length
    entry = entries.first
    assert_equal :dangling_job, entry[:kind]
    assert_equal 'WF/ask/one', entry[:reference]
    assert_equal :running, entry[:state]
    assert_equal agent_file, entry[:agent_file]
    assert entry[:step].is_a?(Step)
  end

  def test_dangling_meta_of_finished_job_is_not_reported
    write_info('WF/ask/one', 'done', 999999999, type: 'chat')
    dispatching_chat
    assert_equal [], Chat.dangling_agent_job_metas(agent_file, captured: [])
  end

  def test_meta_already_captured_is_not_reported_again
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    dispatching_chat
    assert_equal [], Chat.dangling_agent_job_metas(agent_file, captured: ['WF/ask/one'])
    # and by resolved path (the Step form the forensic traversal holds)
    dir = wfdir['WF/ask/one'].find
    assert_equal [], Chat.dangling_agent_job_metas(agent_file, captured: [dir.to_s])
  end

  def test_agent_view_live_combines_activity_and_dangling_job
    write_info('WF/ask/one', 'running', Process.pid, type: 'chat')
    dispatching_chat
    entries = Chat.agent_view_live(agent_file, captured: [])
    kinds = entries.collect { |e| e[:kind] }
    assert_equal %i(agent_activity dangling_job), kinds.sort
    activity = entries.find { |e| e[:kind] == :agent_activity }
    assert_equal :dispatched, activity[:reason]
    assert_equal agent_file, activity[:agent_file]
    job = entries.find { |e| e[:kind] == :dangling_job }
    assert_equal 'WF/ask/one', job[:reference]
    assert_equal :running, job[:state]
  end

  def test_agent_view_live_is_empty_when_idle_and_nothing_dangling
    write_info('WF/ask/one', 'done', 999999999, type: 'chat')
    write_agent_chat({role: 'user', content: 'go'},
                     {role: 'assistant', content: 'done'})
    assert_equal [], Chat.agent_view_live(agent_file, captured: [])
  end

  def test_agent_view_live_is_empty_for_missing_file
    assert_equal [], Chat.agent_view_live(agent_file + '.missing', captured: [])
  end
end
