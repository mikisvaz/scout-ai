require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/backends/responses'
require 'scout/llm/backends/openai'

class TestLLMReasoning < Test::Unit::TestCase
  def responses(*items)
    { 'output' => items }
  end

  def reasoning_item(*texts)
    {
      'type' => 'reasoning',
      'summary' => texts.collect { |text| { 'type' => 'summary_text', 'text' => text } }
    }
  end

  def chat(message)
    { 'choices' => [{ 'message' => message }] }
  end

  def test_responses_summary_on_a_tool_call_turn
    response = responses(
      reasoning_item('Check the available data').merge('encrypted_content' => 'opaque-state'),
      { 'type' => 'function_call', 'name' => 'example', 'arguments' => '{}' }
    )
    assert_equal 'Check the available data', LLM::Responses.reasoning(response)
  end

  def test_responses_collects_all_summary_parts_in_order
    response = responses(
      reasoning_item("First\npoint", 'Second point'),
      { 'type' => 'message', 'content' => [{ 'type' => 'output_text', 'text' => 'Answer' }] },
      reasoning_item('Third point')
    )
    original = Marshal.dump(response)

    assert_equal 'First point Second point Third point', LLM::Responses.reasoning(response)
    assert_equal original, Marshal.dump(response)
  end

  def test_responses_with_only_encrypted_reasoning
    response = responses(reasoning_item.merge('encrypted_content' => 'opaque-state'))
    assert_nil LLM::Responses.reasoning(response)
  end

  def test_responses_without_reasoning
    response = responses(
      { 'type' => 'message', 'content' => [{ 'type' => 'output_text', 'text' => 'Answer' }] }
    )
    assert_nil LLM::Responses.reasoning(response)
  end

  def test_legacy_chat_reasoning_content
    response = chat('reasoning_content' => "Legacy\ntext")
    assert_equal 'Legacy text', LLM::OpenAI.reasoning(response)
  end

  def test_openrouter_chat_reasoning
    assert_equal 'Summary', LLM::OpenAI.reasoning(chat('reasoning' => 'Summary'))
  end

  def test_chat_does_not_duplicate_text_from_reasoning_details
    response = chat(
      'reasoning' => 'Summary',
      'reasoning_details' => [
        { 'type' => 'reasoning.summary', 'summary' => 'Summary' },
        { 'type' => 'reasoning.encrypted', 'data' => 'opaque-state' }
      ]
    )
    assert_equal 'Summary', LLM::OpenAI.reasoning(response)
  end

  def test_chat_falls_back_to_readable_reasoning_details
    response = chat('reasoning_details' => [
      { 'type' => 'reasoning.summary', 'summary' => 'Summary' },
      { 'type' => 'reasoning.encrypted', 'data' => 'opaque-state' },
      { 'type' => 'reasoning.text', 'text' => 'More text' }
    ])
    assert_equal 'Summary More text', LLM::OpenAI.reasoning(response)
  end

  def test_empty_legacy_chat_field_falls_back_to_reasoning
    response = chat('reasoning_content' => '', 'reasoning' => 'Summary')
    assert_equal 'Summary', LLM::OpenAI.reasoning(response)
  end

  def test_chat_with_only_encrypted_reasoning
    response = chat('reasoning_details' => [
      { 'type' => 'reasoning.encrypted', 'data' => 'opaque-state' }
    ])
    assert_nil LLM::OpenAI.reasoning(response)
  end

  def test_empty_response_shapes
    [nil, {}, { 'choices' => [] }, { 'choices' => [nil] }].each do |response|
      assert_nil LLM::Responses.reasoning(response)
    end
  end

  def test_unreadable_summary_entries_are_skipped
    response = responses(
      nil,
      { 'type' => 'reasoning', 'summary' => nil },
      { 'type' => 'reasoning', 'summary' => [
        nil, {},
        { 'type' => 'unknown', 'text' => 'Not a summary' },
        { 'type' => 'summary_text', 'text' => 123 },
        { 'type' => 'summary_text', 'text' => '  ' },
        { 'type' => 'summary_text', 'text' => 'Valid summary' }
      ] }
    )
    assert_equal 'Valid summary', LLM::Responses.reasoning(response)
  end
end
