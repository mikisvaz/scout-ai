require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'rbbt/workflow'
require 'scout/knowledge_base'
class TestLLMTools < Test::Unit::TestCase
  def test_workflow_definition
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
    end

    LLM.task_tool_definition(m, :recipe_steps)
    LLM.task_tool_definition(m, :step_time)

    tool_definitions = LLM.workflow_tools(m)
    ppp JSON.pretty_generate tool_definitions
  end

  def test_knowledbase_definition
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :parents, datafile_test(:person).parents

      assert_include kb.all_databases, :brothers

      assert_equal Person, kb.target_type(:parents)

      knowledge_base_definition = LLM.knowledge_base_tool_definition(kb)
      ppp JSON.pretty_generate knowledge_base_definition
    end
  end
end

