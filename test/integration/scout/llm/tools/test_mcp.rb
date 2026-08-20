require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/tools/mcp'

# Integration (real infrastructure) copy of test/scout/llm/tools/test_mcp.rb:
# test_client connects to https://api.githubcopilot.com/mcp/, which requires
# a GitHub token; the stdio MCP server coverage stays in the unit suite
# (test/scout/llm/test_mcp.rb). Run with `rake test_integration`.
#
# Conditional omission: only runs when a GitHub Copilot token is configured
# and the MCP endpoint accepts the connection; the host itself is reachable
# for anyone but answers 400 without credentials, which used to surface as
# an error instead of a skip.

class TestClass < Test::Unit::TestCase
  URL = "https://api.githubcopilot.com/mcp/"

  def test_client
    key = ENV['GITHUB_COPILOT_TOKEN'] || ENV['GITHUB_TOKEN'] ||
          Scout::Config.get(:key, :github, :copilot, default: nil)
    omit "no GitHub Copilot token configured (set GITHUB_COPILOT_TOKEN)" if key.to_s.strip.empty?

    omit "#{URL} unreachable" unless host_reachable?

    c = LLM.mcp_tools(URL, key: key)
    assert_include c.keys, "get_me"
  end

  private

  def host_reachable?
    require 'uri'
    require 'socket'
    uri = URI.parse(URL)
    begin
      Timeout.timeout(5) { TCPSocket.open(uri.host, uri.port) { |s| s.close } }
      true
    rescue Exception
      false
    end
  end
end
