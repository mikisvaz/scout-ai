require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'

class TestChatToolCalls < Test::Unit::TestCase
  def chat(text)
    Chat.setup(LLM.messages(text))
  end

  def test_pairs_calls_and_outputs_and_preserves_addresses
    conversation = chat <<-EOF
function_call: {"name":"bash","arguments":{"cmd":"false"},"id":"call-1"}
function_call_output: {"id":"call-1","content":"{\\"exit_status\\":1}"}
    EOF

    call = Chat.tool_calls(conversation, source: '/tmp/example.chat').first
    assert_equal 'bash', call[:name]
    assert_equal ['/tmp/example.chat', 1], call[:call_address]
    assert_equal ['/tmp/example.chat', 2], call[:output_address]
    assert_equal({ success: false, reason: :exit_status, exit_status: 1 }, Chat.tool_call_status(call))
  end

  def test_missing_output_is_unknown
    conversation = chat('function_call: {"name":"write","id":"call-2"}')
    status = Chat.tool_call_status(Chat.tool_calls(conversation).first)
    assert_nil status[:success]
    assert_equal :missing_output, status[:reason]
  end

  def test_exception_output_fails
    conversation = chat <<-EOF
function_call: {"name":"read","id":"call-3"}
function_call_output: {"id":"call-3","content":"{\\"exception\\":\\"denied\\"}"}
    EOF
    status = Chat.tool_call_status(Chat.tool_calls(conversation).first)
    assert_equal false, status[:success]
    assert_equal 'denied', status[:exception]
  end
end
