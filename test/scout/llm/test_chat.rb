require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestMessages < Test::Unit::TestCase

  def test_short

    question =<<-EOF
Hi
    EOF

    iii LLM.chat(question)
  end

  def test_inline
    question =<<-EOF
system:

you are a terse assistant that only write in short sentences

assistant:

Here is some stuff

user: feedback

that continues here
    EOF

    iii LLM.chat(question)
  end

  def test_messages
    question =<<-EOF
system:

you are a terse assistant that only write in short sentences

user:

What is the capital of France

assistant:

Paris

user:

is this the national anthem

[[
corous: Viva Espagna
]]

assistant:

no

user:

import: math.system

consider this file

<file name=foo_bar>
foo: bar
</file>

how many characters does it hold

assistant:

8
    EOF

    messages = LLM.messages question
    refute messages.collect{|i| i[:role] }.include?("corous")
    assert messages.collect{|i| i[:role] }.include?("import")
  end

  def test_chat_import
    file1 =<<-EOF
system: You are an assistant
    EOF

    file2 =<<-EOF
import: header
user: say something
    EOF

    TmpFile.with_path do |tmpdir|
      tmpdir.header.write file1
      tmpdir.chat.write file2

      chat = LLM.chat tmpdir.chat
    end
  end

  def test_clear
    question =<<-EOF
system:

you are a terse assistant that only write in short sentences

clear:

user:

What is the capital of France
    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      refute messages.collect{|m| m[:role] }.include?('system')
    end
  end

  def __test_job
    question =<<-EOF
system:

you are a terse assistant that only write in short sentences

job: Baking/bake_muffin_tray/Default_08a1812eca3a18dce2232509dabc9b41

How are muffins made

    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      ppp LLM.print messages
    end
  end


  def test_task
    question =<<-EOF
system:

you are a terse assistant that only write in short sentences

user:

task: Baking bake_muffin_tray blueberries=true title="This is a title" list=one,two,"and three"

How are muffins made?

    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      ppp LLM.print messages
    end
  end

  def test_structure
    require 'scout/llm/ask'
    sss 0
    question =<<-EOF
system:

Respond in json format with a hash of strings as keys and string arrays as values, at most three in length

endpoint: sambanova

What other movies have the protagonists of the original gost busters played on, just the top.

    EOF

    TmpFile.with_file question do |file|
      ppp LLM.ask file
    end
  end

  def test_tools
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

