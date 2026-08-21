require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/ask'
require 'scout/knowledge_base'

class TestLLMAsk < Test::Unit::TestCase

  # Two-hop tool chain against the real test KnowledgeBase, with only the
  # inference mocked:
  #   marriages(Miki)      -> Miki~Clei   (Clei is Miki's wife)
  #   brothers(Clei)       -> Clei~Guille (Guille is Clei's brother)
  #   final answer: Guille is Miki's brother in law
  # The scripted tool calls are dispatched through LLM.process_calls, so the
  # KnowledgeBase lookups, argument handling and function_call_output
  # messages are all real; the mock only decides what the model "says" next.
  def test_knowledge_base_ask_tool_chain
    Log.severity = 0
    # ScoutCoder: KnowledgeBase.new needs a directory it can write its indices
    # into; registering the databases against TmpFile.with_dir keeps everything
    # inside the test tmpdir (and offline).
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"

      LLM::Mock.script(
        {tool_calls: [{name: 'marriages', arguments: {entities: ['Miki'], database: 'marriages'}}]},
        {tool_calls: [{name: 'brothers', arguments: {entities: ['Clei'], database: 'brothers'}}]},
        'Guille is Miki\'s brother in law'
      )

      res = LLM.knowledge_base_ask(kb, "Who is Miki's brother in law? call the tool marriages and then brothers, ignore the tolls that return association_details", persist: false, endpoint: :mock)

      assert_include res, 'Guille'

      # the tool definitions for both databases reached the (mock) backend
      assert_include LLM::Mock.tool_definitions.keys.collect(&:to_s), 'brothers'
      assert_include LLM::Mock.tool_definitions.keys.collect(&:to_s), 'marriages'

      # three rounds: marriages, brothers, final answer
      assert_equal 3, LLM::Mock.calls.length

      # hop 1: the marriages query for Miki really ran and its output was fed
      # back to the model as a function_call_output
      first_input, _first_options = LLM::Mock.calls[1]
      hop1_output = first_input.find { |m| m[:role].to_s == 'function_call_output' }
      assert_include hop1_output[:content].to_s, 'Miki~Clei'

      # hop 2: the brothers query for Clei (the marriage partner) ran next
      second_input, _second_options = LLM::Mock.calls[2]
      hop2_output = second_input.select { |m| m[:role].to_s == 'function_call_output' }.last
      assert_include hop2_output[:content].to_s, 'Clei~Guille'
    end
  end

  # Single-ask chain through the association: chat directive (no explicit kb
  # object), so the KnowledgeBase is built from the directive itself.
  def test_knowledge_base_association_tool_chain
    question =<<-EOF
user:

Who is Miki's brother in law?

association: brothers #{datafile_test(:person).brothers} undirected=true
association: marriages #{datafile_test(:person).marriages} undirected=true source="=>Alias" target="=>Alias"
    EOF

    LLM::Mock.script(
      {tool_calls: [{name: 'marriages', arguments: {entities: ['Miki']}}]},
      {tool_calls: [{name: 'brothers', arguments: {entities: ['Clei']}}]},
      'Guille is Miki\'s brother in law'
    )

    res = LLM.ask question, persist: false, endpoint: :mock

    assert_include res, 'Guille'

    tool_names = LLM::Mock.tool_definitions.keys
    assert_include tool_names, 'brothers'
    assert_include tool_names, 'marriages'

    # both hops produced their function_call_output messages
    hop1_input, _ = LLM::Mock.calls[1]
    hop2_input, _ = LLM::Mock.calls[2]
    assert_include hop1_input.find { |m| m[:role].to_s == 'function_call_output' }[:content].to_s, 'Miki~Clei'
    assert_include hop2_input.select { |m| m[:role].to_s == 'function_call_output' }.last[:content].to_s, 'Clei~Guille'
  end
end
