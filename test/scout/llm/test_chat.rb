require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestMessages < Test::Unit::TestCase
  def _test_messages
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

  def _test_chat_import
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

  def _test_clear
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

  def test_job
    question =<<-EOF 
system 

you are a terse assistant that only write in short sentences

job: Baking/bake_muffin_tray/Default_08a1812eca3a18dce2232509dabc9b41

How are muffins made

    EOF

    TmpFile.with_file question do |file|
      messages = LLM.chat file
      ppp LLM.print messages
    end
  end

end

