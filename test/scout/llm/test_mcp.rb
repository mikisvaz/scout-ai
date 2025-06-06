require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require "scout-ai"
class TestMCP < Test::Unit::TestCase
  def test_workflow_stdio
    require "mcp/server/transports/stdio_transport"
    wf = Module.new do
      extend Workflow
      self.name = "TestWorkflow"

      desc "Just say hi to someone"
      input :name, :string, "Name", nil, required: true
      task :hi => :string do |name|
        "Hi #{name}"
      end

      desc "Just say bye to someone"
      input :name, :string, "Name", nil, required: true
      task :bye => :string do |name|
        "Bye #{name}"
      end
    end

    transport = MCP::Server::Transports::StdioTransport.new(wf.mcp(:hi))
    transport.open
  end
end

