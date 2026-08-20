require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMBedrock < Test::Unit::TestCase
  # Offline Bedrock coverage: LLM::Bedrock.ask/embed accept options[:client]
  # (an object with invoke_model(model_id:, content_type:, body:) returning
  # something whose .body.string is JSON), so FakeBedrockClient exercises the
  # full request construction + response parsing path without AWS credentials.
  #
  # The old real-service versions are kept disabled below (_test_*).

  # ScoutCoder: LLM::Bedrock is not required by lib/scout-ai.rb; each test has
  # to require 'scout/llm/backends/bedrock' itself (same as LLM.ask does when
  # dispatching to the :bedrock backend).
  def test_ask
    require 'scout/llm/backends/bedrock'
    client = TestFixtures.bedrock_client('backends/bedrock')

    response = LLM::Bedrock.ask 'user: say hi to bedrock',
                                client: client,
                                model: 'anthropic.claude-3-sonnet-20240229-v1:0',
                                model_max_tokens: 100

    assert_equal 'Mock answer from Bedrock', response

    assert_equal 1, client.calls.length
    call = client.calls.first
    assert_equal 'anthropic.claude-3-sonnet-20240229-v1:0', call[:model_id]
    assert_equal 'application/json', call[:content_type]
    # ScoutCoder: IndiferentHash#pretty_print takes 0 args, so assert on
    # individual keys instead of pp-ing the recorded parameters.
    assert_equal 100, call[:body]['max_tokens']
    assert call[:body]['messages'].any? { |m| m['role'] == 'user' }
    assert call[:body]['messages'].any? { |m| m['content'].to_s.include?('say hi to bedrock') }
  end

  def test_ask_prompt_type
    require 'scout/llm/backends/bedrock'
    client = TestFixtures.bedrock_client('backends/bedrock')

    response = LLM::Bedrock.ask 'user: say hi through the prompt endpoint',
                                client: client, type: :prompt,
                                model: 'meta.llama3-8b-instruct-v1:0',
                                model_max_tokens: 100

    assert_equal 'Mock answer from Bedrock', response

    body = client.calls.first[:body]
    assert body.include?('prompt')
    assert body['prompt'].to_s.include?('say hi through the prompt endpoint')
  end

  def test_embeddings
    require 'scout/llm/backends/bedrock'
    client = TestFixtures.bedrock_client('backends/bedrock_embedding')

    emb = LLM::Bedrock.embed 'Some text', client: client,
                             model: 'amazon.titan-embed-text-v1'

    assert(Float === emb.first)
    assert_equal [0.1, 0.2, 0.3], emb
    assert_equal 1, client.calls.length

    call = client.calls.first
    assert_equal 'amazon.titan-embed-text-v1', call[:model_id]
    assert_equal 'Some text', call[:body]['inputText']
  end

  # Tool loop: the first payload carries a tool_call content entry, the block
  # answers it, and the second payload is the final text answer.
  def test_tool_loop
    require 'scout/llm/backends/bedrock'
    tools = [
      {
        "type": "function",
        "function": {
          "name": "get_current_temperature",
          "description": "Get the current temperature for a specific location",
          "parameters": {
            "type": "object",
            "properties": {
              "location": { "type": "string",
                            "description": "The city and state, e.g., San Francisco, CA" },
              "unit": { "type": "string", "enum": ["Celsius", "Fahrenheit"],
                        "description": "The temperature unit to use." }
            },
            "required": ["location", "unit"]
          }
        }
      }
    ]

    client = TestFixtures.bedrock_client('backends/bedrock_tool_use', 'backends/bedrock')

    calls_seen = []
    response = LLM::Bedrock.ask 'user: What is the weather in London? Should I take an umbrella? Use the tool.',
                                tools: tools, client: client,
                                model: 'anthropic.claude-3-sonnet-20240229-v1:0',
                                model_max_tokens: 100 do |name, arguments|
      calls_seen << [name, arguments]
      "It's 15 degrees and raining."
    end

    assert_equal 'Mock answer from Bedrock', response

    # the block was reached with the unwrapped tool call
    assert_equal 1, calls_seen.length
    assert_equal 'get_current_temperature', calls_seen.first.first
    assert_equal 'London', calls_seen.first.last['location']

    # two invoke_model rounds, the second one carrying the tool response
    assert_equal 2, client.calls.length
    sent = client.calls.last[:body]['messages']
    assert sent.any? { |m| m['role'] == 'tool' }
    tool_messages = sent.select { |m| m['role'] == 'tool' }
    assert_equal 'It\'s 15 degrees and raining.', tool_messages.last['content']
    assert_equal 'call_1', tool_messages.last['id']
  end

  def _test_ask
    # Real-service version: see the offline tests above. Requires AWS
    # credentials and network.
    prompt =<<-EOF
say hi
    EOF
    ppp LLM::Bedrock.ask prompt, model: "anthropic.claude-3-sonnet-20240229-v1:0", model_max_tokens: 100, model_anthropic_version: 'bedrock-2023-05-31'
  end

  def _test_embeddings
    # Real-service version: see test_embeddings above.
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::Bedrock.embed text, log_errors: true
    assert(Float === emb.first)
  end

  def __test_tool
    prompt =<<-EOF
What is the weather in London. Should I take my umbrella? Use the provided tool
    EOF

    tools = [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
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
    response = LLM::Bedrock.ask prompt, tool_choice: 'required', tools: tools, model: "anthropic.claude-3-sonnet-20240229-v1:0", model_max_tokens: 100, model_anthropic_version: 'bedrock-2023-05-31' do |name,arguments|
      "It's 15 degrees and raining."
    end

    ppp response
  end
end
