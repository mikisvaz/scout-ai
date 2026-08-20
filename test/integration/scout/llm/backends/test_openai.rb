require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMOpenAI < Test::Unit::TestCase
  # ScoutCoder: Backend::ClassMethods#prepare_client honors options[:client],
  # so injecting one of the Fake*Client objects keeps the whole
  # prepare_client -> query -> process_response path offline. The fake records
  # the parameters it was called with, which lets tests assert on what the
  # backend actually sent (model, format, tools) instead of on provider data.
  def test_ask
    client = TestFixtures.openai_client('backends/openai_chat')
    fixture = TestFixtures.fixture('backends/openai_chat')
    answer = fixture.dig('choices', 0, 'message', 'content')

    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory
    EOF

    sss 0
    res = LLM::OpenAI.ask prompt, client: client, model: 'gpt-4.1-nano', persist: false

    assert_equal answer, res
    assert_equal 1, client.calls.length

    parameters = client.calls.first
    assert_equal 'gpt-4.1-nano', parameters[:model]
    assert parameters[:messages].any? { |m| m[:role].to_s == 'user' }
  end

  def test_ask_json_format
    client = TestFixtures.openai_client('backends/openai_chat')

    res = LLM::OpenAI.ask 'user: name three movies', client: client, format: :json, persist: false

    assert_equal TestFixtures.fixture('backends/openai_chat').dig('choices', 0, 'message', 'content'), res

    # ScoutCoder: OpenAI chat requests serialize the format as
    # `text: {format: ...}` rather than response_format; assert the key exists
    # in the recorded parameters.
    parameters = client.calls.first
    assert parameters.include?(:text) || parameters.include?('text')
  end

  def test_embeddings
    payload = { 'object' => 'list',
                'data' => [ { 'object' => 'embedding',
                              'index' => 0,
                              'embedding' => [0.1, 0.2, 0.3] } ],
                'model' => 'embedding-model',
                'usage' => { 'prompt_tokens' => 3, 'total_tokens' => 3 } }

    client = FakeOpenAIChatClient.new(payload)

    emb = LLM::OpenAI.embed 'Some text', client: client, model: 'embedding-model'

    assert(Float === emb.first)
    assert_equal [0.1, 0.2, 0.3], emb

    assert_equal 1, client.calls.length
    assert_equal 'embedding-model', client.calls.first[:model]
    # ScoutCoder: the embed path sends the text as `text:` (OpenAI legacy
    # embeddings parameter), not as `input:`.
    assert_equal 'Some text', client.calls.first[:text]
  end

  # Tool loop: first response carries a tool_call, the block answers it, the
  # second response gives the final answer. All replayed from fixtures.
  def test_tool_loop
    client = TestFixtures.openai_client('backends/openai_chat_tool_call',
                                        'backends/openai_chat')

    tools = [
      { "type": 'function',
        "function": {
          "name": 'get_current_temperature',
          "description": 'Get the current temperature and raining conditions for a specific location',
          "parameters": {
            "type": 'object',
            "properties": {
              "location": { "type": 'string', "description": 'The city and state, e.g., San Francisco, CA' },
              "unit": { "type": 'string', "enum": ['Celsius', 'Fahrenheit'],
                        "description": 'The temperature unit to use. Infer this from the user.' }
            },
            "required": ['location', 'unit']
          }
        } }
    ]

    sss 0
    response = LLM::OpenAI.ask 'user: What is the weather in London. Should I take my umbrella?',
                              tool_choice: 'required', tools: tools,
                              client: client, model: 'gpt-4.1-mini',
                              log_errors: true, persist: false do |_name, _arguments|
      "It's 15 degrees and raining."
    end

    assert_equal TestFixtures.fixture('backends/openai_chat').dig('choices', 0, 'message', 'content'), response
    assert_equal 2, client.calls.length

    # the tool definitions were serialized into the second request
    sent_tools = client.calls.last[:tools]
    assert sent_tools.any? { |t| t.dig('function', 'name') == 'get_current_temperature' ||
                                      t.dig(:function, :name) == 'get_current_temperature' }
  end

  def _test_tool_call_output
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"type":"function","function":{"name":"Baking-bake_muffin_tray","arguments":"{}"},"id":"Baking_bake_muffin_tray_Default"}

function_call_output:

{"id":"Baking_bake_muffin_tray_Default","role":"tool","content":"Baking batter (Mixing base (Whisking eggs from share/pantry/eggs) with mixer (share/pantry/flour))"}

user:

How do you bake muffins, according to the tool I provided you. Don't
tell me the recipe you already know, use the tool call output. Let me
know if you didn't get it.
    EOF
    ppp LLM::OpenAI.ask prompt, model: 'gpt-4.1-nano'
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
    ppp LLM::OpenAI.ask prompt, model: 'gpt-4.1-nano'
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
    ppp LLM::OpenAI.ask prompt, model: 'gpt-4.1-nano'
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
    ppp LLM::OpenAI.ask prompt, model: 'gpt-4.1-nano'
  end


  def _test_tool_gpt5
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "function": {
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
        }
      },
    ]

    respose = LLM::OpenAI.ask prompt, tool_choice: 'required', tools: tools, model: "gpt-5", log_errors: true do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp respose
  end

  def _test_tool
    prompt =<<-EOF
user:
What is the weather in London. Should I take my umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "function": {
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
        }
      },
    ]

    sss 0
    respose = LLM::OpenAI.ask prompt, tool_choice: 'required', tools: tools, model: "gpt-4.1-mini", log_errors: true do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp respose
  end

  def _test_json_output
    prompt =<<-EOF
system:

Respond in json format with a hash of strings as keys and string arrays as values, at most three in length

user:

What other movies have the protagonists of the original gost busters played on, just the top.
    EOF
    sss 0
    ppp LLM::OpenAI.ask prompt, format: :json
  end
end

