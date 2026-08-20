require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMAnthropic < Test::Unit::TestCase
  def _test_say_hi
    prompt =<<-EOF
user: say hi
    EOF
    sss 0
    ppp LLM::Anthropic.ask prompt
  end

  # ScoutCoder: Anthropic has no embeddings endpoint; the backend raises
  # from embed_query, so the offline contract is the exception, not a vector.
  def test_embeddings
    assert_raise(RuntimeError) { LLM::Anthropic.embed 'Some text', log_errors: false, model: 'embedding-model' }
  end

  def test_ask
    client = TestFixtures.anthropic_client('backends/anthropic')
    res = LLM::Anthropic.ask 'user: write a script that sorts files in a directory',
                             client: client, model: 'claude-sonnet-4-5', persist: false

    assert_equal 'Mock answer from Anthropic messages', res
    assert_equal 1, client.calls.length
    assert_equal 'claude-sonnet-4-5', client.calls.first[:model]
    assert client.calls.first[:messages].any? { |m| m[:role].to_s == 'user' }
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
    client = TestFixtures.anthropic_client('backends/anthropic')
    res = LLM::Anthropic.ask prompt, client: client, persist: false

    assert_equal 'Mock answer from Anthropic messages', res
    # ScoutCoder: the Anthropic backend rewrites the function_call /
    # function_call_output pair into content array items (tool_use /
    # tool_result) instead of separate messages.
    sent = client.calls.first[:messages]
    assert sent.any? { |m| m[:role].to_s == 'user' }
    assert sent.inspect.include?('tool_result')
  end

  def test_tool
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "custom",
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

    client = TestFixtures.anthropic_client('backends/anthropic_tool_use', 'backends/anthropic')
    respose = LLM::Anthropic.ask prompt, tools: tools,
                                 client: client, log_errors: true, persist: false do |name,arguments|
      "It's 15 degrees and raining."
    end

    assert_equal 'Mock answer from Anthropic messages', respose
    assert_equal 2, client.calls.length

    # ScoutCoder: LLM::Anthropic#format_tool_definitions renames
    # `parameters` -> `input_schema` and forces type 'custom'.
    sent_tools = client.calls.first[:tools]
    assert sent_tools.any? { |t| (t[:name] || t['name']) == 'get_current_temperature' }
    assert sent_tools.all? { |t| (t[:input_schema] || t['input_schema']) }
    assert sent_tools.all? { |t| (t[:type] || t['type']).to_s == 'custom' }
  end

  def test_json_output
    client = TestFixtures.anthropic_client('backends/anthropic')
    res = LLM::Anthropic.ask 'user: What other movies have the protagonists of the original gost busters played on, just the top.',
                             format: :json, client: client, persist: false

    assert_equal 'Mock answer from Anthropic messages', res
    # ScoutCoder: Anthropic takes a response_format hash, not the string key
    # the OpenAI backends use.
    assert client.calls.first.inspect.include?('json_object')
  end

  def _test_tool_call_output_2
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"name":"get_current_temperature", "arguments":{"location":"London","unit":"Celsius"},"id":"tNTnsQq2s6jGh0npOh43AwDD"}

function_call_output:

{"id":"tNTnsQq2s6jGh0npOh43AwDD", "content":"It's 15 degrees and raining."}

user:

should i take an umbrella?
    EOF
    ppp LLM::Anthropic.ask prompt
  end

  def _test_tool_call_output_features
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"name":"Baking-bake_muffin_tray","arguments":{},"id":"Baking_bake_muffin_tray_Default"}

function_call_output:

{"id":"Baking_bake_muffin_tray_Default","content":"Baking batter (Mixing base (Whisking eggs from share/pantry/eggs) with mixer (share/pantry/flour))"}

user:

How do you bake muffins, according to the tool I provided you. Don't
tell me the recipe you already know, use the tool call output. Let me
know if you didn't get it.
    EOF
    ppp LLM::Anthropic.ask prompt
  end

  def _test_tool_call_output_weather
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"name":"get_current_temperature", "arguments":{"location":"London","unit":"Celsius"},"id":"tNTnsQq2s6jGh0npOh43AwDD"}

function_call_output:

{"id":"tNTnsQq2s6jGh0npOh43AwDD", "content":"It's 15 degrees and raining."}

user:

should i take an umbrella?
    EOF
    ppp LLM::Anthropic.ask prompt
  end

  def _test_tool
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "custom",
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
    respose = LLM::Anthropic.ask prompt, tools: tools, log_errors: true do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp respose
  end

  def _test_json_output
    prompt =<<-EOF
user:

What other movies have the protagonists of the original gost busters played on, just the top.
    EOF
    sss 0
    ppp LLM::Anthropic.ask prompt, format: :json
  end
end

