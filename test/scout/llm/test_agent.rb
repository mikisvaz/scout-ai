require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/knowledge_base'
class TestLLMAgent < Test::Unit::TestCase
  def test_system
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      agent = LLM::Agent.new knowledge_base: kb

      ppp agent.ask "Who is Miguel's brother-in-law. Brother in law is your spouses sibling or your sibling's spouse"
    end
  end

  def test_workflow_eval
    agent = LLM::Agent.new
    agent.workflow do
      input :c_degrees, :float, "Degrees Celsius"

      task :c_to_f => :float do |c_degrees|
        (c_degrees * 9.0 / 5.0) + 32.0
      end

      export :c_to_f
    end

    agent.user "Convert 30 celsius into faranheit"
    res = agent.json_format({conversion: {type: :number}})
    assert_equal 86.0, res['conversion']
  end
end

