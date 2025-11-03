require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/chat'
class TestProcess < Test::Unit::TestCase
  def setup
    super
    @tmp = tmpdir
  end

  def _test_imports_basic_and_continue_last
    TmpFile.with_file do |file|
      Open.write(file, "assistant: hello\nuser: from_import\n")

      messages = [{role: 'import', content: file}]
      out = Chat.imports(messages)

      # Should have replaced import with the messages from the file
      roles = out.collect{|m| m[:role]}
      assert_includes roles, 'assistant'
      assert_includes roles, 'user'

      # Test continue: only last non-empty message
      messages = [{role: 'continue', content: file}]
      out = Chat.imports(messages)
      assert_equal 1, out.size
      assert_equal 'user', out[0][:role]
      assert_equal 'from_import', out[0][:content].strip

      # Test last: should behave similarly but using purge
      messages = [{role: 'last', content: file}]
      out = Chat.imports(messages)
      assert_equal 1, out.size
    end
  end

  def _test_files_file_reads_and_tags_content
    TmpFile.with_file do |tmp|
      file = File.join(tmp, 'afile.txt')
      Open.write(file, "SOME_UNIQUE_CONTENT_12345")

      messages = [{role: 'file', content: file}]
      out = Chat.files(messages)

      assert_equal 1, out.size
      msg = out[0]
      assert_equal 'user', msg[:role]
      # content should include the file content and the filename
      assert_match /SOME_UNIQUE_CONTENT_12345/, msg[:content]
      assert_match /afile.txt/, msg[:content]
    end
  end

  def _test_options_extracts_and_resets
    chat = [
      {role: 'endpoint', content: 'http://api.example'},
      {role: 'option', content: 'k1 v1'},
      {role: 'sticky_option', content: 'sk sv'},
      {role: 'assistant', content: 'ok'},
      {role: 'option', content: 'k2 v2'},
      {role: 'user', content: 'do something'}
    ]

    opts = Chat.options(chat)

    # endpoint should be sticky
    assert_equal 'http://api.example', opts['endpoint']
    # sticky_option should be present
    assert_equal 'sv', opts['sk']
    # first option k1 should have been cleared after assistant
    assert_nil opts['k1']
    # second option should remain
    assert_equal 'v2', opts['k2']

    # chat should have been replaced and should not include option messages
    roles = chat.collect{|m| m[:role]}
    assert_includes roles, 'assistant'
    assert_includes roles, 'user'
    assert_not_includes roles, 'option'
    assert_not_includes roles, 'sticky_option'
  end

  def test_tasks_creates_jobs_and_calls_workflow_produce
    # define a minimal workflow class to be resolved by Kernel.const_get
    klass = Class.new do
      def self.job(task_name, jobname=nil, options={})
        # return a simple object with a path that responds to find
        path = Struct.new(:p) do
          def find; p; end
        end
        job = Struct.new(:path).new(path.new("/tmp/fake_job_#{task_name}"))
        job
      end
    end

    Object.const_set('TestWorkflow', klass)

    produced = nil
    # stub Workflow.produce to capture
    orig = Workflow.method(:produce)
    Workflow.define_singleton_method(:produce) do |jobs|
      produced = jobs
    end

    begin
      messages = [ {role: 'task', content: 'TestWorkflow mytask jobname=jn param=1'} ]
      out = Chat.tasks(messages)

      # Should have returned a job message pointing to our fake path
      assert_equal 1, out.size
      assert_equal 'job', out[0][:role]
      assert_match /fake_job_mytask/, out[0][:content]

      # produce should have been called with the job
      assert_not_nil produced
      assert_equal 1, produced.size
    ensure
      # restore original
      Workflow.define_singleton_method(:produce, orig)
      Object.send(:remove_const, 'TestWorkflow') rescue nil
    end
  end
end
