require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMResponses < Test::Unit::TestCase
  def test_ask
    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory
    EOF
    sss 0
    ppp LLM::Responses.ask prompt, model: 'gpt-4.1-nano'
  end

  def _test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::OpenAI.embed text, log_errors: true
    assert(Float === emb.first)
  end

  def _test_tool_call_output
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

  def _test_tool
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

  def _test_news
    prompt =<<-EOF
websearch: true

user:

What was the top new in the US today?
    EOF
    ppp LLM::Responses.ask prompt
  end

  def _test_image
    prompt =<<-EOF
image: #{datafile_test 'cat.jpg'}

user:

What animal is represented in the image?
    EOF
    sss 0
    ppp LLM::Responses.ask prompt
  end

  def _test_image
    prompt =<<-EOF
image: #{datafile_test 'cat.jpg'}

user:

What animal is represented in the image?
    EOF
    sss 0
    ppp LLM::Responses.ask prompt
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

