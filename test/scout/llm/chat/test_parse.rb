require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestParse < Test::Unit::TestCase
  def test_parse_simple_text
    text = "Hello\nWorld"
    msgs = Chat.parse(text)
    assert_equal 1, msgs.size
    assert_equal 'user', msgs[0][:role]
    assert_equal "Hello\nWorld", msgs[0][:content]
  end

  def test_parse_block_and_inline_headers
    text = <<~TXT
    assistant:
    This is a block
    with lines
    user: inline reply
    another line
    TXT

    msgs = Chat.parse(text)

    # Expect a few messages: initial empty user, assistant block, inline user, and final user block
    assert_equal 'user', msgs[0][:role]
    assert_equal '', msgs[0][:content]

    assert_equal 'assistant', msgs[1][:role]
    assert_equal "This is a block\nwith lines", msgs[1][:content]

    assert_equal 'user', msgs[2][:role]
    assert_equal 'inline reply', msgs[2][:content]

    assert_equal 'assistant', msgs[3][:role]
    assert_equal 'another line', msgs[3][:content]
  end

  def test_parse_code_fence_protection
    text = <<~TXT
    assistant:
    Here is code:
    ```
    def foo
    end
    ```
    Done
    TXT

    msgs = Chat.parse(text)
    assert_equal 2, msgs.size # initial empty + assistant

    assistant_msg = msgs[1]
    assert_equal 'assistant', assistant_msg[:role]

    expected = "Here is code:\n```\ndef foo\nend\n```\nDone"
    assert_equal expected, assistant_msg[:content]
  end

  def test_parse_xml_protection
    text = <<~TXT
    assistant:
    Before xml
    <note>
    This is protected
    </note>
    After
    TXT

    msgs = Chat.parse(text)
    assistant_msg = msgs.find { |m| m[:role] == 'assistant' }
    assert assistant_msg
    assert_equal "Before xml\n<note>\nThis is protected\n</note>\nAfter", assistant_msg[:content]
  end

  def test_parse_square_brackets_protection
    text = <<~TXT
    assistant:
    Start
    [[This: has colon
    and lines]]
    End
    TXT

    msgs = Chat.parse(text)
    assistant_msg = msgs.find { |m| m[:role] == 'assistant' }
    assert assistant_msg
    assert_equal "Start\nThis: has colon\nand lines\nEnd", assistant_msg[:content]
  end

  def test_parse_cmd_output_protection
    text = <<~TXT
    assistant:
    Before
    shell:-- ls {{{
    file1
    shell:-- ls }}}
    After
    TXT

    msgs = Chat.parse(text)
    assistant_msg = msgs.find { |m| m[:role] == 'assistant' }
    assert assistant_msg

    expected = "Before\n<cmd_output cmd=\"ls\">\nfile1\n</cmd_output>\nAfter"
    assert_equal expected, assistant_msg[:content]
  end

  def test_previous_response_id_behavior
    text = <<~TXT
    previous_response_id:abc123
    Some block
    assistant: Got it
    TXT

    msgs = Chat.parse(text)

    # Find the previous_response_id message
    idx = msgs.index { |m| m[:role] == 'previous_response_id' }
    assert idx, 'previous_response_id message not found'
    assert_equal 'abc123', msgs[idx][:content]

    # The message after previous_response_id should be a user block containing "Some block"
    assert_equal 'user', msgs[idx + 1][:role]
    assert_equal 'Some block', msgs[idx + 1][:content]
  end
end
