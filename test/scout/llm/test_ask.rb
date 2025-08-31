require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/workflow'
require 'scout/knowledge_base'

class TestLLM < Test::Unit::TestCase
  def _test_ask
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and comments without formatting so that it can work directly, avoid the initial and end commas ```.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM.ask prompt
    ppp LLM.ask prompt
  end

  def _test_workflow_ask
    m = Module.new do
      extend Workflow
      self.name = "RecipeWorkflow"

      desc "List the steps to cook a recipe"
      input :recipe, :string, "Recipe for which to extract steps"
      task :recipe_steps => :array do |recipe|
        ["prepare batter", "bake"]
      end

      desc "Calculate time spent in each step of the recipe"
      input :step, :string, "Cooking step"
      task :step_time => :string do |step|
        case step 
        when "prepare batter"
          "2 hours"
        when "bake"
          "30 minutes"
        else
          "1 minute"
        end
      end
      export :recipe_steps, :step_time
    end

    sss 0
    ppp LLM.workflow_ask(m, "How much time does it take to prepare a 'vanilla' cake recipe, use the tools provided to find out")
  end

  def test_knowledbase
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.format = {"Person" => "Alias"}
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
      kb.register :parents, datafile_test(:person).parents

      Scout::Config.set(:backend, :openai, :llm)
      ppp LLM.knowledge_base_ask(kb, "Who is Miki's brother in law?", log_errors: true, model: 'gpt-4o')
      ppp LLM.knowledge_base_ask(kb, "Who is Miki's father in law?", log_errors: true, model: 'gpt-4o')
      Scout::Config.set(:backend, :ollama, :llm)
      ppp LLM.knowledge_base_ask(kb, "Who is Miki's brother in law?")
      ppp LLM.knowledge_base_ask(kb, "Who is Miki's father in law?")
    end
  end

end

