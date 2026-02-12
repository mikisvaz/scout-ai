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

  def _test_ask
    prompt =<<-EOF
user: write a script that sorts files in a directory
    EOF
    sss 0
    ppp LLM::Anthropic.ask prompt
  end

  def test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::Anthropic.embed text, log_errors: true, model: 'embedding-model'

    assert(Float === emb.first)
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

