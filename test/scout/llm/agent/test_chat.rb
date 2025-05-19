require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/agent'
class TestAgent < Test::Unit::TestCase
  def test_true
    a = LLM::Agent.new
    a.start_chat.system 'you are a robot'
    a.user "hi"
    ppp a.print
  end
end

