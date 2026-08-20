require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMToolWorkflow < Test::Unit::TestCase
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

    # workflow_tools returns {task => [workflow, definition]}
    assert_equal %i(recipe_steps step_time).sort, tool_definitions.keys.sort
    assert_equal m, tool_definitions[:recipe_steps].first

    definition = tool_definitions[:recipe_steps].last
    assert_equal :recipe_steps, definition[:name]
    assert definition[:parameters][:properties].include?('recipe') || definition[:parameters][:properties].include?(:recipe)

    # ScoutCoder: call_workflow returns a Step (the job) for regular tasks; the
    # caller is expected to produce/read it. Only exec exports (or
    # exec_type: 'exec') return the literal job result inline.
    job = LLM.call_workflow(m, :recipe_steps)
    assert(Step === job)
    job.produce
    assert_equal ["prepare batter", "bake"], job.load

    exec_result = LLM.call_workflow(m, :recipe_steps, exec_type: 'exec')
    assert_equal ["prepare batter", "bake"], exec_result

    path = LLM.call_workflow(m, :recipe_steps, return_path: true)
    assert_equal ["prepare batter", "bake"], Open.read(path).split("\n")

    assert_equal "30 minutes", LLM.call_workflow(m, :step_time, step: 'bake', exec_type: 'exec')
  end
end

