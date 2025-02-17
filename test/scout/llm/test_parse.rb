require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMParse < Test::Unit::TestCase
  def test_parse
    text=<<-EOF
system: you are an asistant
user: Given the contents of this file: [[ 
line 1: 1
line 2: 2
line 3: 3
]]
Show me the lines in reverse order
    EOF

    iii LLM.parse(text)
  end
end

