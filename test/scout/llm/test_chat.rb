require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestMessages < Test::Unit::TestCase


  def test_task
    question =<<-EOF
user:

task: Baking bake_muffin_tray blueberries=true title="This is a title" list=one,two,"and three"

How are muffins made?

    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      assert_include messages.collect{|m| m[:role] }, 'function_call'
      assert_include messages.find{|m| m[:role] == 'function_call_output' }[:content], 'Baking'
    end
  end

  def test_tool
    require 'scout/llm/ask'

    sss 0
    question =<<-EOF
user:

Use the provided tool to learn the instructions of baking a tray of muffins. Don't
give me your own recipe, return the one provided by the tool

tool: Baking
    EOF

    TmpFile.with_file question do |file|
      ppp LLM.ask file, endpoint: :nano
    end
  end

  def test_tools_with_task
    require 'scout/llm/ask'

    question =<<-EOF
user:

Use the provided tool to learn the instructions of baking a tray of muffins. Don't
give me your own recipe, return the one provided by the tool

tool: Baking bake_muffin_tray
    EOF

    TmpFile.with_file question do |file|
      ppp LLM.ask file
    end
  end

  def test_knowledge_base
    require 'scout/llm/ask'
    sss 0
    question =<<-EOF
system:

Query the knowledge base of familiar relationships to answer the question

user:

Who is Miki's brother in law?

association: brothers #{datafile_test(:person).brothers} undirected=true
association: marriages #{datafile_test(:person).marriages} undirected=true source="=>Alias" target="=>Alias"
    EOF

    TmpFile.with_file question do |file|
      ppp LLM.ask file
    end
  end
end

