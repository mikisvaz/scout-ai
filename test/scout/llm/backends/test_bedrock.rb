require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMBedrock < Test::Unit::TestCase
  def _test_ask
    prompt =<<-EOF
say hi
    EOF
    ppp LLM::Bedrock.ask prompt, model: "anthropic.claude-3-sonnet-20240229-v1:0", model_max_tokens: 100, model_anthropic_version: 'bedrock-2023-05-31'
  end


  def _test_embeddings
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

