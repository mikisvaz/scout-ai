require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/chat'
require 'scout/llm/backends/responses'
class TestLLMUsageMeta < Test::Unit::TestCase
  def setup
    super
    %w(pt_s ct_s tt_s).each { |name| Thread.current[name] = 0 }
  end

  def response(id, prompt: nil, completion: nil, total: nil)
    usage = {}
    usage['prompt_tokens'] = prompt unless prompt.nil?
    usage['completion_tokens'] = completion unless completion.nil?
    usage['total_tokens'] = total unless total.nil?
    { 'id' => id, 'usage' => usage }
  end

  def meta_message(meta)
    { role: :meta, content: Chat.serialize_meta(meta) }
  end

  def test_call_session_and_chat_totals_are_not_mixed
    first = LLM::Responses.update_meta(response('one', prompt: 2, completion: 3, total: 5))
    second = LLM::Responses.update_meta(response('two', prompt: 7, total: 7), first)

    assert_equal 7, second['pt']
    assert_nil second['ct']
    assert_equal 9, second['pt_s']
    assert_equal 12, second['tt_s']
    assert_equal 9, second['pt_c']
    assert_equal 3, second['ct_c']
    assert_equal 12, second['tt_c']
  end

  def test_usage_event_is_constant_size
    first = LLM::Responses.update_meta(response('one', prompt: 2, completion: 3, total: 5))
    second = LLM::Responses.update_meta(response('two', prompt: 7, total: 7), first)

    assert_not_include first.keys, 'usage'
    assert_not_include second.keys, 'usage'
    assert_match(/^r_/, first['usage_id'])
    assert_match(/^r_/, second['usage_id'])
  end

  def test_shared_branch_history_is_counted_once
    prefix = LLM::Responses.update_meta(response('prefix', prompt: 2, completion: 3, total: 5))
    left = LLM::Responses.update_meta(response('left', prompt: 7, total: 7), prefix)
    right = LLM::Responses.update_meta(response('right', prompt: 11, completion: 13, total: 24), prefix)

    events = Chat.usage_events([meta_message(prefix), meta_message(left), meta_message(right)])
    totals = Chat.usage_totals(events)

    assert_equal 20, totals['pt_c']
    assert_equal 16, totals['ct_c']
    assert_equal 36, totals['tt_c']
  end

  def test_chat_meta_unions_events_and_removes_meta_messages
    first = LLM::Responses.update_meta(response('one', prompt: 2, completion: 3, total: 5))
    second = LLM::Responses.update_meta(response('two', prompt: 7, total: 7), first)
    messages = [
      meta_message(first),
      { role: :assistant, content: 'answer' },
      meta_message(second)
    ]

    meta = Chat.meta(messages)

    assert_equal 9, meta['pt_c']
    assert_equal 3, meta['ct_c']
    assert_equal 12, meta['tt_c']
    assert_nil meta['usage']
    assert_equal [:assistant], messages.collect { |message| message[:role] }
  end

  def test_task_summaries_are_deduplicated_without_becoming_usage_events
    request = {
      usage_scope: 'task', usage_job: 'Planned/request/one',
      pt_d: 2, ct_d: 3, tt_d: 5,
      pt_c: 2, ct_c: 3, tt_c: 5
    }
    plan = {
      usage_scope: 'task', usage_job: 'Planned/plan/one',
      pt_d: 7, ct_d: 0, tt_d: 7,
      pt_c: 7, ct_c: 0, tt_c: 7
    }
    messages = [meta_message(request), meta_message(plan), meta_message(request)]

    assert_empty Chat.usage_events(messages)
    totals = Chat.usage_totals(Chat.usage_summaries(messages))
    assert_equal 9, totals['pt_c']
    assert_equal 3, totals['ct_c']
    assert_equal 12, totals['tt_c']

    meta = Chat.meta(messages)
    assert_equal 9, meta['pt_c']
    assert_equal 3, meta['ct_c']
    assert_equal 12, meta['tt_c']
  end

  def test_following_a_task_uses_its_complete_total
    before = [
      meta_message(LLM::Responses.update_meta(response('one', prompt: 73, completion: 61, total: 134))),
      meta_message(LLM::Responses.update_meta(response('two', prompt: 114, completion: 153, total: 267)))
    ]
    task = meta_message(
      usage_scope: 'task', usage_job: 'Planned/ask/example',
      pt_d: 3002, ct_d: 405, tt_d: 3407,
      pt_c: 18_615, ct_c: 2526, tt_c: 21_141
    )

    current = Chat.meta(before + [task])
    next_call = LLM::Responses.update_meta(
      response('three', prompt: 670, completion: 423, total: 1093), current
    )

    assert_equal 19_472, next_call['pt_c']
    assert_equal 3_163, next_call['ct_c']
    assert_equal 22_635, next_call['tt_c']
  end

  def test_legacy_cumulative_snapshots_are_not_summed
    snapshots = [
      meta_message(pt_c: 10, ct_c: 1, tt_c: 11),
      meta_message(pt_c: 30, ct_c: 3, tt_c: 33),
      meta_message(pt_c: 60, ct_c: 6, tt_c: 66)
    ]

    assert_empty Chat.usage_events(snapshots)
    assert_equal [60, 6, 66], Chat.legacy_usage(snapshots).values.first

    meta = Chat.meta(snapshots)
    assert_equal 60, meta['pt_c']
    assert_equal 6, meta['ct_c']
    assert_equal 66, meta['tt_c']
  end
end
