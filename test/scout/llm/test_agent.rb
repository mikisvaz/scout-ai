require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/agent'

class TestLLMAgent < Test::Unit::TestCase
  def test_prompt
    agent = self.agent
    agent.start_chat.user <<-EOF
My name is Miguel
    EOF

    chat = LLM.chat <<-EOF
user:

What is my name?
    EOF

    # ScoutCoder: agent.prompt goes through LLM.ask, which persists its result;
    # persist: false keeps unit tests away from Scout.var.cache.ask, and the
    # mock backend records what the agent actually sent.
    LLM::Mock.script('Your name is Miguel')

    res = agent.prompt chat, persist: false, endpoint: 'mock'

    assert_equal 'Your name is Miguel', res

    # the agent pipeline carried its start_chat messages into the request
    messages, _options = LLM::Mock.calls.first
    assert_include messages.collect { |m| m[:role].to_s }, 'user'
  end
end
