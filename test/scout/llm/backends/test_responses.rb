require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMResponses < Test::Unit::TestCase
  def test_ask
    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory
    EOF
    ppp LLM::Responses.ask prompt, model: 'gpt-4.1-nano'
  end

  def test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::Responses.embed text, log_errors: true
    assert(Float === emb.first)
  end

  def test_tool_call_output_weather
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"name":"get_current_temperature", "arguments":{"location":"London","unit":"Celsius"},"id":"tNTnsQq2s6jGh0npOh43AwDD"}

function_call_output:

{"id":"tNTnsQq2s6jGh0npOh43AwDD", "content":"It's 15 degrees and raining."}

user:

should i take an umbrella?
    EOF
    ppp LLM::Responses.ask prompt, model: 'gpt-4.1-nano'
  end

  def test_tool
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "name": "get_current_temperature",
        "description": "Get the current temperature and raining conditions for a specific location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "The city and state, e.g., San Francisco, CA"
            },
            "unit": {
              "type": "string",
              "enum": ["Celsius", "Fahrenheit"],
              "description": "The temperature unit to use. Infer this from the user's location."
            }
          },
          "required": ["location", "unit"]
        }
      },
    ]

    sss 1
    respose = LLM::Responses.ask prompt, tool_choice: 'required', tools: tools, model: "gpt-4.1-nano", log_errors: true do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp respose
  end

  def test_news
    prompt =<<-EOF
websearch: true

user:

What was the top new in the US today?
    EOF
    ppp LLM::Responses.ask prompt
  end

  def test_image
    prompt =<<-EOF
image: #{datafile_test 'cat.jpg'}

user:

What animal is represented in the image?
    EOF
    sss 0
    ppp LLM::Responses.ask prompt
  end

  def test_json_output
    prompt =<<-EOF
system:

Respond in json format with a hash of strings as keys and string arrays as values, at most three in length

user:

What other movies have the protagonists of the original gost busters played on, just the top.
    EOF
    sss 0
    ppp LLM::Responses.ask prompt, format: :json
  end

  def test_json_format
    prompt =<<-EOF
user:

What other movies have the protagonists of the original gost busters played on.
Name each actor and the top movie they took part of
    EOF
    sss 0

    format = {
      name: 'actors_and_top_movies',
      type: 'object',
      properties: {},
      additionalProperties: {type: :string}
    }
    ppp LLM::Responses.ask prompt, format: format
  end

  def test_json_format_list
    prompt =<<-EOF
user:

What other movies have the protagonists of the original gost busters played on.
Name each actor as keys and the top 3 movies they took part of as values
    EOF
    sss 0

    format = {
      name: 'actors_and_top_movies',
      type: 'object',
      properties: {},
      additionalProperties: {type: :array, items: {type: :string}}
    }
    ppp LLM::Responses.ask prompt, format: format
  end

  def test_json_format_actor_list
    prompt =<<-EOF
user:

What other movies have the protagonists of the original gost busters played on.
Name each actor as keys and the top 3 movies they took part of as values
    EOF
    sss 0

    format = {
      name: 'actors_and_top_movies',
      type: 'object',
      properties: {},
      additionalProperties: false,
      items: {
        type: 'object', 
        properties: {
          name: {type: :string, description: 'actor name'}, 
          movies: {type: :array, description: 'list of top 3 movies', items: {type: :string, description: 'movie title plus year in parenthesis'} }, 
          additionalProperties: false
        }
      }
    }

    schema =  {
      "type": "object",
      "properties": {
        "people": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "name": { "type": "string" },
              "movies": {
                "type": "array",
                "items": { "type": "string" },
                "minItems": 3,
                "maxItems": 3
              }
            },
            "required": ["name", "movies"],
            additionalProperties: false
          }
        }
      },
      additionalProperties: false,
      "required": ["people"]
    }
    ppp LLM::Responses.ask prompt, format: schema
  end

  def test_tool_gpt5
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "name": "get_current_temperature",
        "description": "Get the current temperature and raining conditions for a specific location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "The city and state, e.g., San Francisco, CA"
            },
            "unit": {
              "type": "string",
              "enum": ["Celsius", "Fahrenheit"],
              "description": "The temperature unit to use. Infer this from the user's location."
            }
          },
          "required": ["location", "unit"]
        }
      },
    ]

    sss 0
    respose = LLM::Responses.ask prompt, tool_choice: 'required', tools: tools, model: "gpt-5", log_errors: true do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp respose
  end

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

