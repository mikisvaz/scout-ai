require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMOllama < Test::Unit::TestCase

  def test_ask
    client = TestFixtures.ollama_client('backends/ollama')
    res = LLM::OLlama.ask 'user: write a script that sorts files in a directory',
                          client: client, model: 'mistral', mode: 'chat', persist: false

    assert_equal 'Mock answer from Ollama', res
    assert_equal 1, client.calls.length
    assert_equal 'mistral', client.calls.first[:model]
    assert client.calls.first[:messages].any? { |m| m[:role].to_s == 'user' }
  end

  def test_tool
    prompt =<<-EOF
What is the weather in London. Should I take an umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "function": {
          "name": "get_current_temperature",
          "description": "Get the current temperature for a specific location",
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

    client = TestFixtures.ollama_client('backends/ollama_tool_call', 'backends/ollama')
    respose = LLM::OLlama.ask prompt, model: 'gpt-oss',
                              client: client, tool_choice: 'required',
                              tools: tools, persist: false do |name,arguments|
      "It's raining cats and dogs"
    end

    assert_equal 'Mock answer from Ollama', respose
    assert_equal 2, client.calls.length

    # ScoutCoder: LLM::OLlama#query calls client.chat(parameters) positionally
    # (no `parameters:` kwarg) and the API returns an Array of chunk hashes.
    sent_tools = client.calls.first[:tools]
    assert sent_tools.any? { |t| (t.dig(:function, :name) || t.dig('function', 'name')) == 'get_current_temperature' }
  end

  def test_embeddings
    payload = [{ 'embeddings' => [[0.1, 0.2, 0.3]] }]
    client = FakeOllamaClient.new(payload)

    emb = LLM::OLlama.embed 'Some text', client: client, model: 'mxbai-embed-large'

    assert(Float === emb.first)
    assert_equal [0.1, 0.2, 0.3], emb
    assert_equal 'Some text', client.calls.first[:input]
  end

  def _test_tool_call_output
    Log.severity = 0
    prompt =<<-EOF
function_call:

{"type":"function","function":{"name":"Baking-bake_muffin_tray","arguments":{}},"id":"Baking_bake_muffin_tray_Default"}

function_call_output:

{"id":"Baking_bake_muffin_tray_Default","content":"Baking batter (Mixing base (Whisking eggs from share/pantry/eggs) with mixer (share/pantry/flour))"}

user:

How do you bake muffins, according to the tool I provided you. Don't
tell me the recipe you already know, use the tool call output. Let me
know if you didn't get it.
    EOF
    ppp LLM::OLlama.ask prompt, model: 'mistral', mode: 'chat'
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
    ppp LLM::OLlama.ask prompt, model: 'mistral'
  end

  def _test_tool
    prompt =<<-EOF
What is the weather in London. Should I take an umbrella?
    EOF

    tools = [
      {
        "type": "function",
        "function": {
          "name": "get_current_temperature",
          "description": "Get the current temperature for a specific location",
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
    respose = LLM::OLlama.ask prompt, model: 'gpt-oss', url: 'http://localhost:3330', tool_choice: 'required', tools: tools do |name,arguments|
      "It's raining cats and dogs"
    end

    ppp respose
  end

  def test_embedding_array
    payload = [{ 'embeddings' => [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]] }]
    client = FakeOllamaClient.new(payload)

    emb = LLM::OLlama.embed ['Some text', 'More text'], client: client, model: 'mxbai-embed-large'

    assert(Float === emb.first.first)
    assert_equal [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]], emb
  end
end

