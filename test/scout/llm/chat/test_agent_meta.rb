require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'tmpdir'

class TestChatAgentMeta < Test::Unit::TestCase
  def chat(text)
    Chat.setup(LLM.messages(text))
  end

  # Build persisted-style chat text with one paired tool call whose output
  # envelope carries an agent_meta receipt.
  def receipt_text(agent_meta: nil, name: 'ask', call_id: 'call-1', content: 'child answer')
    envelope = {name: name, content: content, id: call_id}
    envelope[:agent_meta] = agent_meta unless agent_meta.nil?
    <<-EOF
user: Run the worker
function_call: {"name":"#{name}","arguments":{"agent":"Worker"},"id":"#{call_id}"}
function_call_output: #{envelope.to_json}
    EOF
  end

  def valid_receipt
    receipt_text(agent_meta: [
      {role: 'meta', content: 'pt=100 ct=50 tt=150 inference_id=aaa'},
      {role: 'meta', content: 'job=Worker/ask/Default_x'}
    ])
  end

  def test_extracts_valid_receipt_entries
    evidence = Chat.agent_meta_evidence(chat(valid_receipt))
    assert_equal 2, evidence.length

    direct, projection = evidence

    assert_equal :agent_meta, direct[:origin]
    assert_equal 100, direct[:meta][:pt]
    assert_equal 50, direct[:meta][:ct]
    assert_equal 150, direct[:meta][:tt]
    assert_equal 'aaa', direct[:meta][:inference_id]
    assert_equal 'call-1', direct[:call_id]
    assert_equal 'ask', direct[:tool_name]
    assert_equal 0, direct[:agent_meta_index]
    assert_equal 3, direct[:output_address]
    assert_equal [3, :agent_meta, 0], direct[:evidence_address]
    assert_nil direct[:source]
    assert_equal({role: 'meta', content: 'pt=100 ct=50 tt=150 inference_id=aaa'}, direct[:raw_message])

    assert_equal 1, projection[:agent_meta_index]
    assert_equal [3, :agent_meta, 1], projection[:evidence_address]
    assert_equal 'Worker/ask/Default_x', projection[:meta][:job]
  end

  def test_extracts_receipt_entries_from_persisted_file_with_source
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'parent.chat')
      Open.write(path, valid_receipt)
      conversation = Chat.load(path)

      evidence = Chat.agent_meta_evidence(conversation, source: path)
      assert_equal 2, evidence.length

      direct = evidence.first
      assert_equal path, direct[:source]
      assert_equal [path, 3], direct[:output_address]
      assert_equal [path, 3, :agent_meta, 0], direct[:evidence_address]
      assert_equal 'call-1', direct[:call_id]
      assert_equal 'ask', direct[:tool_name]

      assert_equal [path, 3, :agent_meta, 1], evidence.last[:evidence_address]
    end
  end

  def test_absent_agent_meta_returns_empty_evidence
    plain = receipt_text
    assert_equal [], Chat.agent_meta_evidence(chat(plain))

    without_calls = chat(<<-EOF)
user: Hello
assistant: Hi
    EOF
    assert_equal [], Chat.agent_meta_evidence(without_calls)
  end

  def test_agent_meta_not_an_array_is_skipped_with_warning
    warnings = []
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: 'oops')), warnings: warnings)
    assert_equal [], evidence
    assert_equal 1, warnings.length

    warning = warnings.first
    assert_equal :agent_meta, warning[:origin]
    assert_equal :not_an_array, warning[:reason]
    assert_equal 3, warning[:output_address]
    assert_equal 'call-1', warning[:call_id]
    assert_equal 'ask', warning[:tool_name]
    assert_nil warning[:agent_meta_index]
    assert_equal 'oops', warning[:raw_entry]
  end

  def test_non_hash_entry_is_skipped_with_warning
    warnings = []
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: ['nonsense'])), warnings: warnings)
    assert_equal [], evidence
    assert_equal 1, warnings.length
    assert_equal :not_a_hash, warnings.first[:reason]
    assert_equal 0, warnings.first[:agent_meta_index]
    assert_equal 'nonsense', warnings.first[:raw_entry]
  end

  def test_entry_with_wrong_role_is_skipped_with_warning
    warnings = []
    agent_meta = [
      {role: 'assistant', content: 'not a meta record'},
      {role: 'meta', content: 'pt=1 tt=1 inference_id=keep'}
    ]
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: agent_meta)), warnings: warnings)
    assert_equal 1, evidence.length
    assert_equal 1, warnings.length
    assert_equal :invalid_role, warnings.first[:reason]
    assert_equal 0, warnings.first[:agent_meta_index]
    assert_equal({ 'role' => 'assistant', 'content' => 'not a meta record' }, warnings.first[:raw_entry])
    assert_equal [3, :agent_meta, 1], evidence.first[:evidence_address]
  end

  def test_entry_without_string_content_is_skipped_with_warning
    warnings = []
    agent_meta = [
      {role: 'meta'},
      {role: 'meta', content: 42},
      {role: 'meta', content: 'pt=1 tt=1 inference_id=keep'}
    ]
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: agent_meta)), warnings: warnings)
    assert_equal 1, evidence.length
    assert_equal 2, warnings.length
    assert_equal %i[invalid_content invalid_content], warnings.collect { |w| w[:reason] }
    assert_equal 0, warnings.first[:agent_meta_index]
    assert_equal 1, warnings.last[:agent_meta_index]
  end

  def test_unparseable_content_is_skipped_with_warning
    warnings = []
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: [{role: 'meta', content: 'no key value pairs here'}])), warnings: warnings)
    assert_equal [], evidence
    assert_equal 1, warnings.length
    assert_equal :unparseable_meta, warnings.first[:reason]
    assert_equal 0, warnings.first[:agent_meta_index]
  end

  def test_malformed_entries_are_skipped_without_warnings_kwarg
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: [{role: 'assistant', content: 'x'}])))
    assert_equal [], evidence
  end

  def test_meta_evidence_combines_both_origins
    text = valid_receipt + "\nmeta: pt=10 tt=12 inference_id=local1\nassistant: done\n"
    conversation = chat(text)

    evidence = Chat.meta_evidence(conversation)
    assert_equal 3, evidence.length

    origins = evidence.collect { |record| record[:origin] }
    assert_equal %i[chat_meta agent_meta agent_meta], origins

    local = evidence.first
    assert_equal 10, local[:meta][:pt]
    assert_equal 12, local[:meta][:tt]
    assert_equal 4, local[:meta_address]
    assert_nil local[:source]
    assert_equal 'meta', local[:message][:role].to_s
    assert_equal 'pt=10 tt=12 inference_id=local1', local[:message][:content]

    assert evidence.last(2).all? { |record| record[:origin] == :agent_meta }
  end

  def test_meta_evidence_preserves_source_addresses
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'parent.chat')
      Open.write(path, valid_receipt + "\nmeta: pt=10 tt=12 inference_id=local1\nassistant: done\n")
      conversation = Chat.load(path)

      evidence = Chat.meta_evidence(conversation, source: path)
      assert_equal [path, 4], evidence.first[:meta_address]
      assert_equal [path, 3, :agent_meta, 0], evidence[1][:evidence_address]
      assert_equal [path, 3, :agent_meta, 1], evidence[2][:evidence_address]
      assert evidence.all? { |record| record[:source] == path }
    end
  end

  def test_extraction_does_not_change_chat_contents
    conversation = chat(valid_receipt + "\nmeta: pt=10 tt=12 inference_id=local1\nassistant: done\n")
    before = conversation.collect { |message| [message[:role].to_s, message[:content].to_s] }

    Chat.agent_meta_evidence(conversation)
    Chat.meta_evidence(conversation)
    Chat.agent_meta_job_references(conversation)

    after = conversation.collect { |message| [message[:role].to_s, message[:content].to_s] }
    assert_equal before, after
    assert_equal 6, conversation.length

    roles = conversation.collect { |message| message[:role].to_s }
    assert_equal %w[user user function_call function_call_output meta assistant], roles
  end

  def test_agent_meta_job_references_returns_only_job_records
    conversation = chat(valid_receipt)
    references = Chat.agent_meta_job_references(conversation)

    assert_equal 1, references.length
    reference = references.first
    assert_equal 'Worker/ask/Default_x', reference[:job]
    assert_equal 'Worker/ask/Default_x', reference[:meta][:job]
    assert_equal :agent_meta, reference[:origin]
    assert_equal 'call-1', reference[:call_id]
    assert_equal 'ask', reference[:tool_name]
    assert_equal 1, reference[:agent_meta_index]
    assert_equal [3, :agent_meta, 1], reference[:evidence_address]

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'parent.chat')
      Open.write(path, valid_receipt)
      with_source = Chat.agent_meta_job_references(Chat.load(path), source: path)
      assert_equal 1, with_source.length
      assert_equal 'Worker/ask/Default_x', with_source.first[:job]
      assert_equal [path, 3, :agent_meta, 1], with_source.first[:evidence_address]
    end
  end

  def test_agent_meta_job_references_empty_without_receipts
    assert_equal [], Chat.agent_meta_job_references(chat(receipt_text))
    assert_equal [], Chat.agent_meta_job_references(chat("user: Hello\nassistant: Hi\n"))
  end

  def test_chat_without_agent_meta_shows_no_regression
    conversation = chat(<<-EOF)
user: Hello
meta: pt=10 ct=5 tt=15 inference_id=solo
assistant: Hi
    EOF

    assert_equal [], Chat.agent_meta_evidence(conversation)

    evidence = Chat.meta_evidence(conversation)
    assert_equal 1, evidence.length
    assert_equal :chat_meta, evidence.first[:origin]

    assert_equal({pt: 10, ct: 5, tt: 15, cct: 0, cwt: 0, rt: 0}, Chat.token_totals([conversation]))
    assert_equal 1, conversation.role_messages(:meta).length
  end

  def test_agent_meta_is_not_limited_to_ask_tool
    agent_meta = [{role: 'meta', content: 'pt=7 tt=7 inference_id=other'}]
    evidence = Chat.agent_meta_evidence(chat(receipt_text(agent_meta: agent_meta, name: 'chat_task', call_id: 'call-9')))
    assert_equal 1, evidence.length
    assert_equal 'chat_task', evidence.first[:tool_name]
    assert_equal 'call-9', evidence.first[:call_id]
  end
end
