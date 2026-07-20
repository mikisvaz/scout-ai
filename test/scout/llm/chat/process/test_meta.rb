require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/chat'
require 'scout/llm/backends/responses'

class TestLLMUsageMeta < Test::Unit::TestCase
  def setup
    super
    %w(pt_s ct_s tt_s).each { |name| Thread.current[name] = 0 }
  end

  def response(prompt: nil, completion: nil, total: nil)
    usage = {}
    usage['prompt_tokens'] = prompt unless prompt.nil?
    usage['completion_tokens'] = completion unless completion.nil?
    usage['total_tokens'] = total unless total.nil?
    { 'usage' => usage }
  end

  def chat(text)
    Chat.setup(LLM.messages(text))
  end

  def test_backend_records_direct_and_running_token_counts
    first = LLM::Responses.update_meta(response(prompt: 2, completion: 3, total: 5))
    second = LLM::Responses.update_meta(response(prompt: 7, total: 7), first)

    assert_equal 7, second['pt']
    assert_nil second['ct']
    assert_equal 9, second['pt_s']
    assert_equal 12, second['tt_s']
    assert_equal 9, second['pt_c']
    assert_equal 3, second['ct_c']
    assert_equal 12, second['tt_c']
    assert_nil second['usage_id']
  end

  def test_jobs_returns_all_projecting_jobs
    conversation = chat <<-EOF
user: First
meta: job=WF/ask/first.chat
assistant: First answer
user: Second
meta: job=WF/ask/second.chat
assistant: Second answer
    EOF

    assert_equal %w[WF/ask/first.chat WF/ask/second.chat], conversation.jobs
    assert_equal 'WF/ask/second.chat', conversation.meta[:job]
  end

  def test_message_identity_includes_non_meta_history
    first = chat <<-EOF
user: Question
meta: tt=5
assistant: Answer
    EOF
    same = chat <<-EOF
user: Question
assistant: Answer
    EOF
    different = chat <<-EOF
user: Different question
assistant: Answer
    EOF

    assert_equal first.message_index.last[:id], same.message_index.last[:id]
    assert_not_equal first.message_index.last[:id], different.message_index.last[:id]
  end

  def test_consecutive_meta_leaves_the_first_segment_orphaned
    conversation = chat <<-EOF
user: Work
meta: tt=2
meta: job=WF/ask/work.chat
assistant: Done
    EOF

    trace = Chat.trace_chats([conversation])
    assert_equal 2, trace.length
    assert trace.first[:orphan]
    assert_equal 2, trace.first[:meta][:tt]
    assert_equal 'WF/ask/work.chat', trace.last[:meta][:job]
    assert_equal 1, trace.last[:messages].length
  end

  def test_final_meta_is_an_orphan_segment
    conversation = chat <<-EOF
user: Work
meta: tt=2
assistant: Tool call removed
meta: tt=7
    EOF

    trace = Chat.trace_chats([conversation])
    assert_equal 2, trace.length
    assert_equal 7, trace.last[:meta][:tt]
    assert trace.last[:orphan]
    assert_empty trace.last[:messages]
  end

  def test_meta_covers_a_multi_tool_response_segment
    conversation = chat <<-EOF
user: Write two files
meta: tt=1000
function_call: {"name":"write","id":"one"}
function_call_output: {"id":"one","content":"done one"}
function_call: {"name":"write","id":"two"}
function_call_output: {"id":"two","content":"done two"}
assistant: Done
user: Next request
    EOF

    trace = Chat.trace_chats([conversation])
    assert_equal 1, trace.length
    assert_equal 1000, trace.first[:meta][:tt]
    assert_equal 5, trace.first[:messages].length
    assert !trace.first[:orphan]
  end

  def test_project_marks_the_whole_response_with_one_job_meta
    response = [
      { role: :meta, content: 'tt=2' },
      { role: :function_call, content: '{"name":"write"}' },
      { role: :function_call_output, content: '{"content":"done"}' },
      { role: :meta, content: 'tt=7' },
      { role: :assistant, content: 'Done' }
    ]

    projected = Chat.project('WF/ask/work.chat', response)
    assert_equal %i[meta function_call function_call_output assistant], projected.collect { |m| m[:role] }
    assert_equal 'WF/ask/work.chat', Chat.parse_meta(projected.first[:content])[:job]
    trace = Chat.trace_chats([Chat.setup(projected)])
    assert_equal 1, trace.length
    assert_equal 3, trace.first[:messages].length
  end

  def test_trace_keeps_distinct_segments_for_direct_and_projected_metadata
    direct = chat <<-EOF
user: Work
meta: tt=7
assistant: Done
    EOF
    projected = chat <<-EOF
user: Work
meta: job=WF/ask/work.chat
assistant: Done
    EOF

    trace = Chat.trace_chats([projected, direct])
    assert_equal 2, trace.length
    assert_equal ['WF/ask/work.chat', nil], trace.collect { |entry| entry[:meta][:job] }
    assert_equal [nil, 7], trace.collect { |entry| entry[:meta][:tt] }
  end

  def test_job_meta_does_not_reset_the_last_direct_chat_total
    messages = LLM.messages <<-EOF
user: Plan
meta: pt=10 ct=2 tt=12 pt_c=10 ct_c=2 tt_c=12
assistant: Plan complete
meta: job=WF/ask/work.chat
assistant: Work complete
    EOF

    current = Chat.meta(messages)
    assert_equal 'WF/ask/work.chat', current[:job]
    assert_equal 10, current[:pt_c]
    assert_equal 2, current[:ct_c]
    assert_equal 12, current[:tt_c]
  end
end
