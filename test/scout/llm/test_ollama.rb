require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMOllama < Test::Unit::TestCase
  def test_ask
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and inline comments. No extra explanations or comentary
system: Avoid using backticks ``` to format code.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM::OLlama.ask prompt, model: 'qwen2.5-coder', mode: 'chat'
  end

  def _test_gepeto
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM::OLlama.ask prompt, model: 'deepseek-r1:8b', url: "https://gepeto.bsc.es"
  end
end

