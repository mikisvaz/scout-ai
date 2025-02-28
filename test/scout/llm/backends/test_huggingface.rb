require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMHF < Test::Unit::TestCase

  def test_ask
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and inline comments. No extra explanations or comentary
system: Avoid using backticks ``` to format code.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM::Huggingface.ask prompt, model: 'HuggingFaceTB/SmolLM2-135M-Instruct'
  end

  def test_embeddings
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::Huggingface.embed text, model: 'distilbert-base-uncased-finetuned-sst-2-english'
    assert(Float === emb.first)
  end

  def test_embedding_array
    Log.severity = 0
    text =<<-EOF
Some text
    EOF
    emb = LLM::Huggingface.embed [text], model: 'distilbert-base-uncased-finetuned-sst-2-english'
    assert(Float === emb.first.first)
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

    sss 0
    respose = LLM::Huggingface.ask prompt, model: 'HuggingFaceTB/SmolLM2-135M-Instruct', tool_choice: 'required', tools: tools do |name,arguments|
      "It's raining cats and dogs"
    end

    ppp respose
  end

end

