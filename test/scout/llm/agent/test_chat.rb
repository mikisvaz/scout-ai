require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/agent'
class TestAgent < Test::Unit::TestCase
  def test_print
    a = LLM::Agent.new
    a.start_chat.system 'you are a robot'
    a.user "hi"

    output = a.print
    assert_kind_of String, output

    # ScoutCoder: Chat.print renders each message as "role:\n\ncontent" (roles in
    # the meta list are inlined instead); blocks are joined by a blank line and
    # the whole string starts with a newline.
    assert_equal "\nsystem:\n\nyou are a robot\n\nuser:\n\nhi", output
  end
end
