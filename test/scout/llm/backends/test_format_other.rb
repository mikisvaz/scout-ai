# Wire-format regression: strategy-injected bookkeeping keys (the
# epoch_tool_compactation record's `compacted` flag) must not reach the
# provider request payload, while the record's content stays intact.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/backends/default'
require 'scout/llm/backends/anthropic'
require 'scout/llm/backends/glm'

class TestBackendFormatOther < Test::Unit::TestCase
  def test_compaction_record_flag_is_dropped_on_the_wire
    record = IndiferentHash.setup(
      { role: :user, content: '[TOOL-COMPACTION-RECORD] body', compacted: true }
    )

    [LLM::Anthropic, LLM::GLM].each do |backend|
      formatted = backend.format_messages([{ role: 'user', content: 'hi' }, record])

      wire_record = formatted.last
      assert_not_nil wire_record
      assert_equal '[TOOL-COMPACTION-RECORD] body', wire_record[:content]
      assert_not_include wire_record.keys.collect(&:to_s), 'compacted'
      assert_equal %w[content role], wire_record.keys.collect(&:to_s).sort
    end
  end

  def test_format_other_does_not_mutate_the_original_message
    record = IndiferentHash.setup(
      { role: :user, content: 'meta-ish', compacted: true, something_else: 1 }
    )

    LLM::Anthropic.format_messages([record.dup])

    assert_equal %w[compacted content role something_else], record.keys.collect(&:to_s).sort
    assert_equal true, record[:compacted]
  end

  def test_plain_user_message_passes_through_equivalently
    plain = IndiferentHash.setup({ role: 'user', content: 'hello' })
    formatted = LLM::Anthropic.format_messages([plain])

    assert_equal({ role: 'user', content: 'hello' }, formatted.first)
  end
end
