require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/mcp'
require 'json'

module TestMCPServingWorkflow
  extend Workflow
  self.name = "TestMCPServingWorkflow"

  desc "Greet someone"
  input :name, :string, "string", "Who to greet"
  task :greet => :string do |name| "hello #{name}" end
  export :greet
end

class TestLLMToolMCP < Test::Unit::TestCase
  def setup
    @server = TestMCPServingWorkflow.mcp(:greet)
  end

  def request(method, params)
    JSON.parse @server.handle_json({'jsonrpc' => '2.0', 'id' => 1, 'method' => method, 'params' => params}.to_json)
  end

  def test_mcp_serves_task_as_string_named_tool
    response = request('tools/list', {})
    assert_equal ['greet'], response['result']['tools'].collect{|t| t['name']}
  end

  def test_mcp_tool_call_dispatches_to_workflow
    response = request('tools/call', {'name' => 'greet', 'arguments' => {'name' => 'World'}})
    assert_equal 'hello World', response['result']['content'].first['text']
    assert ! response['result']['isError']
  end

  def test_mcp_default_task_set_registers_string_names
    server = TestMCPServingWorkflow.mcp
    tool = server.instance_variable_get(:@tools)['greet']
    assert(tool, "default task set should register the greet tool by string name")
  end
end
