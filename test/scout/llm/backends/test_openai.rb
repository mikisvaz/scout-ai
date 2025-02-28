require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMOpenAI < Test::Unit::TestCase
  def test_ask
    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory
    EOF
    ppp LLM::OpenAI.ask prompt
  end

  def test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::OpenAI.embed text, log_errors: true
    assert(Float === emb.first)
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

    respose = LLM::OpenAI.ask prompt, tool_choice: 'required', tools: tools do |name,arguments|
      "It's raining cats and dogs"
    end

    ppp respose
  end
end

