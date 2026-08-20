require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  # Real remote MCP server version moved to
  # test/integration/scout/llm/tools/test_mcp.rb: LLM.mcp_tools needs a live
  # MCP server (no seam to fake). Stdio coverage stays unit-side in
  # test/scout/llm/test_mcp.rb.
  def _test_client
   c = LLM.mcp_tools("https://api.githubcopilot.com/mcp/")
   assert_include c.keys, "get_me"
  end
end
