require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/chat'
require 'scout/llm/backends/responses'

class TestLLMUsageMeta < Test::Unit::TestCase
  def setup
    super
    Chat::TOKEN_KEYS.each { |name| Thread.current["#{name}_s"] = 0 }
  end

  def response(prompt: nil, completion: nil, total: nil,
               cached: nil, cache_write: nil, reasoning: nil)
    usage = {}
    usage['prompt_tokens'] = prompt unless prompt.nil?
    usage['completion_tokens'] = completion unless completion.nil?
    usage['total_tokens'] = total unless total.nil?
    usage['prompt_tokens_details'] = {}
    usage['prompt_tokens_details']['cached_tokens'] = cached unless cached.nil?
    usage['input_tokens_details'] = {} if cache_write || cached
    usage['input_tokens_details'] ||= {}
    usage['input_tokens_details']['cache_write_tokens'] = cache_write unless cache_write.nil?
    usage['completion_tokens_details'] = {}
    usage['completion_tokens_details']['reasoning_tokens'] = reasoning unless reasoning.nil?
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

  # === Cache token accounting tests ===

  def test_openai_responses_api_cache_tokens
    resp = { 'usage' => {
      'input_tokens' => 9,
      'input_tokens_details' => { 'cache_write_tokens' => 5, 'cached_tokens' => 3 },
      'output_tokens' => 174,
      'output_tokens_details' => { 'reasoning_tokens' => 128 },
      'total_tokens' => 183
    } }
    meta = LLM::Responses.update_meta(resp)

    assert_equal 9, meta['pt']
    assert_equal 174, meta['ct']
    assert_equal 183, meta['tt']
    assert_equal 3, meta['cct']
    assert_equal 5, meta['cwt']
    assert_equal 128, meta['rt']
    # cumulative variants
    assert_equal 9, meta['pt_c']
    assert_equal 3, meta['cct_c']
    assert_equal 5, meta['cwt_c']
    assert_equal 128, meta['rt_c']
    # session variants
    assert_equal 9, meta['pt_s']
    assert_equal 3, meta['cct_s']
    assert_equal 5, meta['cwt_s']
    assert_equal 128, meta['rt_s']
  end

  def test_glm_cache_tokens
    resp = { 'usage' => {
      'completion_tokens' => 97,
      'completion_tokens_details' => { 'reasoning_tokens' => 92 },
      'prompt_tokens' => 8,
      'prompt_tokens_details' => { 'cached_tokens' => 4 },
      'total_tokens' => 105
    } }
    meta = LLM::Responses.update_meta(resp)

    assert_equal 8, meta['pt']
    assert_equal 97, meta['ct']
    assert_equal 105, meta['tt']
    assert_equal 4, meta['cct']
    assert_nil meta['cwt']
    assert_equal 92, meta['rt']
    # cumulative variants
    assert_equal 4, meta['cct_c']
    assert_equal 92, meta['rt_c']
  end

  def test_anthropic_flat_cache_fields
    resp = { 'usage' => {
      'prompt_tokens' => 100,
      'completion_tokens' => 50,
      'cache_read_input_tokens' => 80,
      'cache_creation_input_tokens' => 20
    } }
    meta = LLM::Responses.update_meta(resp)

    assert_equal 100, meta['pt']
    assert_equal 50, meta['ct']
    assert_equal 150, meta['tt']  # computed
    assert_equal 80, meta['cct']
    assert_equal 20, meta['cwt']
    assert_nil meta['rt']
  end

  def test_cumulative_cache_tokens_across_requests
    first = LLM::Responses.update_meta(
      response(prompt: 10, completion: 5, total: 15, cached: 3, reasoning: 2)
    )
    second = LLM::Responses.update_meta(
      response(prompt: 8, completion: 4, total: 12, cached: 6, reasoning: 1),
      first
    )

    assert_equal 3, first['cct_c']
    assert_equal 2, first['rt_c']
    assert_equal 9, second['cct_c']   # 3 + 6
    assert_equal 3, second['rt_c']    # 2 + 1
    assert_equal 18, second['pt_c']   # 10 + 8
  end

  def test_normalize_usage_constants
    assert_equal %w[pt ct tt cct cwt rt], Chat::TOKEN_KEYS
    assert_equal %w[pt_c ct_c tt_c cct_c cwt_c rt_c], Chat::CUMULATIVE_KEYS
  end

  def test_normalize_usage_openai_chat_api
    usage = { 'prompt_tokens' => 9, 'completion_tokens' => 174, 'total_tokens' => 183 }
    result = Chat.normalize_usage(usage)
    assert_equal 9, result['pt']
    assert_equal 174, result['ct']
    assert_equal 183, result['tt']
    assert_nil result['cct']
    assert_nil result['cwt']
    assert_nil result['rt']
  end

  def test_normalize_usage_computes_total_when_missing
    usage = { 'prompt_tokens' => 10, 'completion_tokens' => 20 }
    result = Chat.normalize_usage(usage)
    assert_equal 30, result['tt']
  end

  def test_normalize_usage_handles_nil
    assert_equal({}, Chat.normalize_usage(nil))
    assert_equal({}, Chat.normalize_usage({}))
  end

  def test_direct_entries_includes_cache_tokens
    conversation = chat <<-EOF
user: Work
meta: pt=10 ct=5 tt=15 cct=3 rt=2
assistant: Done
    EOF

    entries = Chat.direct_entries([conversation])
    assert_equal 1, entries.length
    assert_equal 3, entries.first[:meta][:cct]
    assert_equal 2, entries.first[:meta][:rt]
  end

  def test_token_totals_aggregates_cache_fields
    c1 = chat <<-EOF
user: Work
meta: pt=10 ct=5 tt=15 cct=3 rt=2
assistant: Done
    EOF
    c2 = chat <<-EOF
user: More work
meta: pt=20 ct=10 tt=30 cct=7 rt=8
assistant: Done again
    EOF

    totals = Chat.token_totals([c1, c2])
    assert_equal 30, totals[:pt]
    assert_equal 15, totals[:ct]
    assert_equal 45, totals[:tt]
    assert_equal 10, totals[:cct]  # 3 + 7
    assert_equal 10, totals[:rt]   # 2 + 8
  end

  def test_print_tokens_shows_cache_fields
    totals = { pt: 100, ct: 50, tt: 150, cct: 30, cwt: 10, rt: 20 }
    output = Chat.print_tokens(totals)
    assert output.include?('cached=30')
    assert output.include?('cache_write=10')
    assert output.include?('reasoning=20')
  end
end
