require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/chat'
require 'scout/llm/backends/responses'

class TestNormalizeUsage < Test::Unit::TestCase
  def test_openai_chat_api
    usage = {
      "prompt_tokens" => 100,
      "completion_tokens" => 50,
      "total_tokens" => 150,
      "prompt_tokens_details" => {"cached_tokens" => 20},
      "completion_tokens_details" => {"reasoning_tokens" => 30}
    }
    result = Chat.normalize_usage(usage)
    assert_equal 100, result['pt']
    assert_equal 50, result['ct']
    assert_equal 150, result['tt']
    assert_equal 20, result['cct']
    assert_nil result['cwt']
    assert_equal 30, result['rt']
  end

  def test_openai_responses_api
    usage = {
      "input_tokens" => 9,
      "input_tokens_details" => {"cache_write_tokens" => 0, "cached_tokens" => 0},
      "output_tokens" => 174,
      "output_tokens_details" => {"reasoning_tokens" => 128},
      "total_tokens" => 183
    }
    result = Chat.normalize_usage(usage)
    assert_equal 9, result['pt']
    assert_equal 174, result['ct']
    assert_equal 183, result['tt']
    assert_equal 0, result['cct']
    assert_equal 0, result['cwt']
    assert_equal 128, result['rt']
  end

  def test_glm
    usage = {
      "completion_tokens" => 27,
      "completion_tokens_details" => {"reasoning_tokens" => 92},
      "prompt_tokens" => 8,
      "prompt_tokens_details" => {"cached_tokens" => 0},
      "total_tokens" => 105
    }
    result = Chat.normalize_usage(usage)
    assert_equal 8, result['pt']
    assert_equal 27, result['ct']
    assert_equal 105, result['tt']
    assert_equal 0, result['cct']
    assert_nil result['cwt']
    assert_equal 92, result['rt']
  end

  def test_anthropic_flat_fields
    usage = {
      "input_tokens" => 500,
      "output_tokens" => 200,
      "cache_read_input_tokens" => 150,
      "cache_creation_input_tokens" => 50
    }
    result = Chat.normalize_usage(usage)
    assert_equal 500, result['pt']
    assert_equal 200, result['ct']
    assert_equal 700, result['tt']
    assert_equal 150, result['cct']
    assert_equal 50, result['cwt']
    assert_nil result['rt']
  end

  def test_simple_usage_without_cache
    usage = {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    result = Chat.normalize_usage(usage)
    assert_equal 10, result['pt']
    assert_equal 5, result['ct']
    assert_equal 15, result['tt']
    extras = result.select { |k,_v| !%w[pt ct tt].include?(k) }
    assert_empty extras
  end

  def test_nil_usage
    result = Chat.normalize_usage(nil)
    assert_equal({}, result)
  end

  def test_empty_usage
    result = Chat.normalize_usage({})
    assert_equal({}, result)
  end

  def test_token_totals_with_cache
    usage1 = {
      "prompt_tokens" => 100,
      "completion_tokens" => 50,
      "total_tokens" => 150,
      "prompt_tokens_details" => {"cached_tokens" => 20},
      "completion_tokens_details" => {"reasoning_tokens" => 30}
    }
    meta_str1 = Chat.serialize_meta(Chat.normalize_usage(usage1))
    chat1 = Chat.setup([
      {role: :user, content: "hi"},
      {role: :assistant, content: "hello"},
      {role: :meta, content: meta_str1}
    ])

    totals = Chat.token_totals([chat1])
    assert_equal 100, totals[:pt]
    assert_equal 50, totals[:ct]
    assert_equal 150, totals[:tt]
    assert_equal 20, totals[:cct]
    assert_equal 0, totals[:cwt]
    assert_equal 30, totals[:rt]
  end

  def test_print_tokens_with_cache
    tokens = {pt: 100, ct: 50, tt: 150, cct: 20, cwt: 0, rt: 30}
    str = Chat.print_tokens(tokens)
    assert str.include?("prompt=100")
    assert str.include?("completion=50")
    assert str.include?("total=150")
    assert str.include?("cached=20")
    assert !str.include?("cache_write")
    assert str.include?("reasoning=30")
  end

  def test_token_keys_constant
    assert_equal %w[pt ct tt cct cwt rt], Chat::TOKEN_KEYS
    assert_equal %w[pt_c ct_c tt_c cct_c cwt_c rt_c], Chat::CUMULATIVE_KEYS
  end

  def test_update_meta_with_cache_fields
    %w(pt_s ct_s tt_s cct_s cwt_s rt_s).each { |name| Thread.current[name] = 0 }

    response = {
      'usage' => {
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "total_tokens" => 150,
        "prompt_tokens_details" => {"cached_tokens" => 20},
        "completion_tokens_details" => {"reasoning_tokens" => 30}
      }
    }
    meta = LLM::Responses.update_meta(response)
    assert_equal 100, meta['pt']
    assert_equal 50, meta['ct']
    assert_equal 150, meta['tt']
    assert_equal 20, meta['cct']
    assert_equal 30, meta['rt']
    assert_equal 20, meta['cct_s']
    assert_equal 30, meta['rt_s']
    assert_equal 20, meta['cct_c']
    assert_equal 30, meta['rt_c']
  end

  def test_update_meta_accumulates_cache_fields_across_requests
    %w(pt_s ct_s tt_s cct_s cwt_s rt_s).each { |name| Thread.current[name] = 0 }

    resp1 = { 'usage' => {
      "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15,
      "prompt_tokens_details" => {"cached_tokens" => 4},
      "completion_tokens_details" => {"reasoning_tokens" => 3}
    }}
    meta1 = LLM::Responses.update_meta(resp1)
    assert_equal 4, meta1['cct_s']
    assert_equal 3, meta1['rt_s']
    assert_equal 4, meta1['cct_c']
    assert_equal 3, meta1['rt_c']

    resp2 = { 'usage' => {
      "prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30,
      "prompt_tokens_details" => {"cached_tokens" => 8},
      "completion_tokens_details" => {"reasoning_tokens" => 6}
    }}
    meta2 = LLM::Responses.update_meta(resp2, meta1)
    assert_equal 12, meta2['cct_s']   # 4 + 8
    assert_equal 9, meta2['rt_s']    # 3 + 6
    assert_equal 12, meta2['cct_c']  # 4 + 8
    assert_equal 9, meta2['rt_c']    # 3 + 6
  end
end
