require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMParse < Test::Unit::TestCase
  def test_parse
    text=<<-EOF
hi
system: you are an asistant
user: Given the contents of this file:[[
line 1: 1
line 2: 2
line 3: 3
]]
Show me the lines in reverse order
    EOF

    assert_include LLM.parse(text).first[:content], 'hi'
    assert_include LLM.parse(text).last[:content], 'reverse'
  end

  def test_code
    text=<<-EOF
hi
system: you are an asistant
user: Given the contents of this file:
```yaml
key: value
key2: value2
```
Show me the lines in reverse order
    EOF

    assert_include LLM.parse(text).last[:content], 'key2'
  end

  def test_lines
    text=<<-EOF
system: you are an asistant
user: I have a question
    EOF

    assert_include LLM.parse(text).last[:content], 'question'
  end

  def test_blocks
    text=<<-EOF
system:

you are an asistant

user:

I have a question

    EOF

    assert_include LLM.parse(text).last[:content], 'question'
  end

  def test_no_role
    text=<<-EOF
I have a question
    EOF

    assert_include LLM.parse(text).last[:content], 'question'
  end


  def test_cmd
    text=<<-EOF
How many files are there:

[[cmd list of files
echo "file1 file2"
]]
    EOF

    assert_equal :user, LLM.parse(text).last[:role]
    assert_include LLM.parse(text).first[:content], 'file1'
  end

  def test_directory
    TmpFile.with_path do |tmpdir|
      tmpdir.file1.write "foo"
      tmpdir.file2.write "bar"
      text=<<-EOF
How many files are there:

[[directory DIR
#{tmpdir}
]]
      EOF

      assert_include LLM.parse(text).first[:content], 'file1'
    end
  end
end

