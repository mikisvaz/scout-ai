require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'rbbt/workflow'
require 'scout/knowledge_base'

# Offline replacement for the remote `Baking` workflow used by the original
# task:/tool: tests. Chat directives resolve workflow names with
# Kernel.const_get first (see Chat.load_workflow), so a named module is
# reachable without any git clone.
TestBaking = Module.new do
  extend Workflow
  self.name = "TestBaking"

  desc "Bake a tray of muffins"
  input :blueberries, :boolean, "Add blueberries", true
  input :title, :string, "Recipe title"
  input :list, :array, "Ingredient list"
  task :bake_muffin_tray => :string do |blueberries, title, list|
    "Baking muffins: #{title} (#{list.to_a * ', '}) blueberries=#{blueberries}"
  end

  desc "List the steps to cook a recipe"
  input :recipe, :string, "Recipe for which to extract steps"
  task :recipe_steps => :array do |recipe|
    ["prepare batter", "bake"]
  end
end

class TestMessages < Test::Unit::TestCase

  def test_task
    question =<<-EOF
user:

task: TestBaking bake_muffin_tray blueberries=true title="This is a title" list=one,two,"and three"

How are muffins made?

    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      assert_include messages.collect{|m| m[:role] }, 'function_call'
      assert_include messages.find{|m| m[:role] == 'function_call' }[:content], 'TestBaking'
      assert_include messages.find{|m| m[:role] == 'function_call_output' }[:content], 'Baking muffins'
    end
  end

  def test_tool
    require 'scout/llm/ask'

    question =<<-EOF
user:

Use the provided tool to learn the instructions of baking a tray of muffins. Don't
give me your own recipe, return the one provided by the tool

tool: TestBaking bake_muffin_tray
    EOF

    LLM::Mock.script 'The instructions say: bake the muffin tray'

    TmpFile.with_file question do |file|
      res = LLM.ask file, endpoint: 'test', persist: false
      assert_equal 'The instructions say: bake the muffin tray', res

      # the tool:/directive reached the backend as a workflow tool definition
      assert_include LLM::Mock.tool_definitions.keys, 'bake_muffin_tray'
      obj, definition = LLM::Mock.tool_definitions['bake_muffin_tray']
      assert_equal TestBaking, obj
    end
  end

  def test_tools_with_task
    require 'scout/llm/ask'

    # ScoutCoder: LLM.ask wraps the backend call in Persist.persist even when
    # persist: false is passed, so two asks with the exact same question text
    # collide on the cache key and the second one is served from cache without
    # ever reaching the backend. Give each test a distinct question so every
    # ask really exercises the (mock) backend.
    question =<<-EOF
user:

Use the provided tool and then give me the answer you obtained from it. Don't
give me your own recipe, return the one provided by the tool

tool: TestBaking bake_muffin_tray
    EOF

    LLM::Mock.script(
      {tool_calls: [{name: 'bake_muffin_tray', arguments: {}}]},
      'The instructions say: bake the muffin tray'
    )

    TmpFile.with_file question do |file|
      res = LLM.ask file, endpoint: 'test', persist: false
      assert_equal 'The instructions say: bake the muffin tray', res

      # the scripted tool call actually ran the workflow task: the mock
      # backend saw the tool definition and returned the final answer
      assert_include LLM::Mock.tool_definitions.keys, 'bake_muffin_tray'

      # the task output was really executed and fed back to the model
      tool_input, _ = LLM::Mock.calls[1]
      output = tool_input.find { |m| m[:role].to_s == 'function_call_output' }
      assert_include output[:content].to_s, 'Baking muffins'
    end
  end

  def test_knowledge_base
    require 'scout/llm/ask'

    question =<<-EOF
system:

Query the knowledge base of familiar relationships to answer the question

user:

Who is Miki's brother in law? Use the associations.

association: brothers #{datafile_test(:person).brothers} undirected=true
association: marriages #{datafile_test(:person).marriages} undirected=true source="=>Alias" target="=>Alias"
    EOF

    LLM::Mock.script 'Guille is Miki\'s brother in law'

    TmpFile.with_file question do |file|
      res = LLM.ask file, endpoint: 'test', persist: false
      assert_equal "Guille is Miki's brother in law", res

      # the association: directives produced knowledge base tool definitions
      tool_names = LLM::Mock.tool_definitions.keys
      assert_include tool_names, 'brothers'
      assert_include tool_names, 'marriages'
    end
  end

  # Two-hop knowledge base tool chain over the association: directives: only
  # the inference is mocked (marriages Miki -> Clei, brothers Clei -> Guille),
  # the database queries run for real. See test/scout/llm/test_ask.rb for the
  # knowledge_base_ask variant.
  def test_knowledge_base_tool_execution
    require 'scout/llm/ask'

    question =<<-EOF
user:

Who is Miki's brother in law? Use the associations.

association: brothers #{datafile_test(:person).brothers} undirected=true
association: marriages #{datafile_test(:person).marriages} undirected=true source="=>Alias" target="=>Alias"
    EOF

    # entities must be a JSON array of entity identifiers, not a bare string
    # (call_knowledge_base JSON.parses it when it is a String)
    LLM::Mock.script(
      {tool_calls: [{name: 'marriages', arguments: {'entities' => '["Miki"]'}}]},
      {tool_calls: [{name: 'brothers', arguments: {'entities' => '["Clei"]'}}]},
      "Guille is Miki's brother in law"
    )

    res = LLM.ask question, endpoint: 'test', persist: false
    assert_include res, 'Guille'
    assert_include LLM::Mock.tool_definitions.keys, 'brothers'

    hop1_input, _ = LLM::Mock.calls[1]
    hop2_input, _ = LLM::Mock.calls[2]
    assert_include hop1_input.find { |m| m[:role].to_s == 'function_call_output' }[:content].to_s, 'Miki~Clei'
    assert_include hop2_input.select { |m| m[:role].to_s == 'function_call_output' }.last[:content].to_s, 'Clei~Guille'
  end
end
