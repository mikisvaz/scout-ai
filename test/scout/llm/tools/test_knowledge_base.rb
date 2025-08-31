require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMToolKB < Test::Unit::TestCase
  def test_knowledbase_definition
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :parents, datafile_test(:person).parents

      assert_include kb.all_databases, :brothers

      assert_equal Person, kb.target_type(:parents)

      knowledge_base_definition = LLM.knowledge_base_tool_definition(kb)
      ppp JSON.pretty_generate knowledge_base_definition

      assert_equal ['Isa~Miki', 'Miki~Isa', 'Guille~Clei'], LLM.call_knowledge_base(kb, :brothers, entities: %w(Isa Miki Guille))
    end
  end
end

