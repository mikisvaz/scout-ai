require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'rbbt-util'
class TestLLMAgent < Test::Unit::TestCase
  def _test_system
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      agent = LLM::Agent.new knowledge_base: kb

      agent.system = ""

      sss 0
      ppp agent.ask "Who is Miguel's brother-in-law. Brother in law is your spouses sibling or your sibling's spouse"
      #ppp agent.ask "Who is Guille's brother-in-law. Brother in law is your spouses sibling or your sibling's spouse"
    end
  end

  def _test_system_gepeto
    TmpFile.with_dir do |dir|
      Scout::Config.set(:backend, :ollama, :ask)
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      agent = LLM::Agent.new knowledge_base: kb, model: 'mistral', url: "https://gepeto.bsc.es/"

      agent.system = ""

      sss 0
      ppp agent.ask "Who is Guille's brother-in-law. Brother in law is your spouses sibling or your sibling's spouse"
    end
  end


end

