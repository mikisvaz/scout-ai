require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_client
   c = LLM.mcp_tools("https://api.githubcopilot.com/mcp/")
   assert_include c.keys, "get_me"
  end
end


