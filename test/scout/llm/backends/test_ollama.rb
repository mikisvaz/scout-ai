require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMOllama < Test::Unit::TestCase

  def _test_ask
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and inline comments. No extra explanations or comentary
system: Avoid using backticks ``` to format code.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM::OLlama.ask prompt, model: 'mistral', mode: 'chat'
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

  def _test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::OLlama.embed text, model: 'mxbai-embed-large', url: 'localhost:3331' 
    assert(Float === emb.first)
  end

  def test_embedding_array
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::OLlama.embed [text], model: 'mxbai-embed-large', url: 'localhost:3331' 
    assert(Float === emb.first.first)
  end
end

