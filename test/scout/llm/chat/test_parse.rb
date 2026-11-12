require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestParse < Test::Unit::TestCase
  def _test_parse_simple_text
    text = "Hello\nWorld"
    msgs = Chat.parse(text)
    assert_equal 1, msgs.size
    assert_equal 'user', msgs[0][:role]
    assert_equal "Hello\nWorld", msgs[0][:content]
  end

  def _test_parse_block_and_inline_headers
    text = <<~TXT
    assistant:
    This is a block
    with lines
    user: inline reply
    another line
    TXT

    msgs = Chat.parse(text)

    # Expect three messages: assistant block, inline user, and the final
    # block, which takes the default user role. No leading empty user
    # message is emitted any more.
    assert_equal 3, msgs.size

    assert_equal 'assistant', msgs[0][:role]
    assert_equal "This is a block\nwith lines", msgs[0][:content]

    assert_equal 'user', msgs[1][:role]
    assert_equal 'inline reply', msgs[1][:content]

    assert_equal 'user', msgs[2][:role]
    assert_equal 'another line', msgs[2][:content]
  end

  def _test_no_leading_empty_user_message
    # A chat whose whole content is an empty user block parses to no
    # messages: Chat.parse must not fabricate an empty leading message.
    assert_equal [], Chat.parse("user:\n")
    assert_equal [], Chat.parse("user: \n")

    # A chat starting with a block header keeps its real messages and
    # gains no empty user message in front of them.
    msgs = Chat.parse("user:\nRun the worker\nassistant: done\n")
    assert_equal 2, msgs.size
    assert_equal 'user', msgs[0][:role]
    assert_equal 'Run the worker', msgs[0][:content]
    assert_equal 'assistant', msgs[1][:role]
    assert_equal 'done', msgs[1][:content]
  end

  def _test_parse_code_fence_protection
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

  def _test_parse_xml_protection
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

  def _test_parse_square_brackets_protection
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

  def _test_parse_cmd_output_protection
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

  def _test_previous_response_id_behavior
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

  def _test_parse_json
    text = <<~TXT
Hi


```json
{
  "status": "PASS",
  "summary": "The worker successfully created the file `tmp/number` and wrote a random number (42) into it, satisfying the request.",
  "issues": [],
  "next_step": "",
  "search_needed": false
}
```
    TXT

    assert_nothing_raised do
      Chat.parse_json(text)
    end
    assert_nothing_raised do
      Chat.parse_json(text.chomp)
    end

  end

  def _test_protect_print
    content =<<-EOF
Hi this line is not a role
sections:
That was inside a content block
    EOF
    messages = [{role: 'assistant', content: content.strip}]

    txt = Chat.print messages
    m = Chat.parse txt
    assert_equal messages, m.reject{|msg| msg[:content].empty?}
  end

  def _test_path_kind_role_round_trips_verbatim
    # The `path_kind:` chat role (per-agent path-kind configuration, consumed
    # by Agent#ask; see lib/scout/llm/agent.rb) parses with the generic role
    # rule and must round-trip through print/parse: agent preparation files
    # are edited and re-saved as chat text.  print emits it as a block role
    # (like user/system), which parse reads back as the same one message.
    text = "path_kind: SomeWorkflow kind_a kind_b"
    messages = Chat.parse text
    assert_equal 1, messages.size
    assert_equal 'path_kind', messages[0][:role]
    assert_equal 'SomeWorkflow kind_a kind_b', messages[0][:content]

    printed = Chat.print(messages).strip
    assert_equal 'path_kind:', printed.split("\n").first
    assert_equal messages, Chat.parse(printed)
  end

  def test_parse_function_call
    text =<<-EOF
function_call: {"name":"bash","arguments":{"cmd":"git show HEAD:lib/scout/llm/chat/provenance.rb | wc -l; echo ---; ls ~/.rvm/gems/ruby-3.3.1/gems/ | grep -i scout"},"id":"call_-7100561051824943161"}

function_call_output: {"name":"bash","content":"{\"stdout\":\"1852\\n---\\nscout-ai-1.1.6\\nscout-ai-1.1.8\\nscout-ai-1.2.2\\nscout-ai-1.2.5\\nscout-ai-1.2.6\\nscout-ai-2.0.0\\nscout-ai-2.1.0\\nscout-camp-0.2.0\\nscout-camp-0.2.1\\nscout-essentials-1.8.5\\nscout-essentials-1.8.6\\nscout-essentials-1.8.7\\nscout-essentials-1.8.8\\nscout-essentials-1.9.0\\nscout-essentials-1.9.1\\nscout-essentials-1.9.3\\nscout-gear-10.11.10\\nscout-gear-10.11.6\\nscout-gear-10.12.1\\nscout-gear-10.12.2\\nscout-gear-10.13.1\\nscout-rig-0.2.0\\nscout-rig-0.2.6\\nscout-web-0.1.0\\n\",\"stderr\":\"\",\"exit_status\":0}","id":"call_-7100561051824943161","start_timestamp":"2026-11-06T22:12:29.479Z","timestamp":"2026-11-06T22:12:29.657Z"}

    EOF

    chat = Chat.parse text
    iii chat

  end
end
