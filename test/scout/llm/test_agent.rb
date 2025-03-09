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

  def test_workflow
    m = Module.new do
      extend Workflow
      self.name = "Registration"

      desc "Register a person"
      input :name, :string, "Last, first name"
      input :age, :integer, "Age"
      input :gender, :select, "Gender", nil, :select_options => %w(male female)
      task :person => :yaml do
        iii inputs.to_hash
        inputs.to_hash
      end
    end

    sss 0
    #ppp LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male", model: "Meta-Llama-3.3-70B-Instruct")
    ppp LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male, using a tool call to the tool provided", backend: 'ollama', model: "llama3")
  end

  def _test_openai
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      sss 3
      agent = LLM::Agent.new knowledge_base: kb, model: 'gpt-4o'

      agent.system = ""

      ppp agent.ask "Who is Miguel's brother-in-law"
    end
  end

  def _test_argonne
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      agent.system = ""

      ppp agent.ask "Who is Miguel's brother-in-law"
    end
  end

  def _test_nvidia
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      sss 0

      ppp LLM::OpenAI.ask "Say Hi", url: "https://integrate.api.nvidia.com/v1", model: "deepseek-ai/deepseek-r1"
      exit


      agent.system = ""

      ppp agent.ask "Who is Miguel's brother-in-law. Make use of the tools using tool_calls"
    end
  end

end

