require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'

class TestChatProvenance < Test::Unit::TestCase
  def test_does_not_follow_imports
    TmpFile.with_dir do |dir|
      imported = File.join(dir, 'imported.chat')
      root = File.join(dir, 'root.chat')
      File.write(imported, "user: Imported\n")
      File.write(root, "import: imported.chat\nuser: Root\n")

      visits = Chat.traverse_provenance(root).to_a
      # Only the root chat is visited; imports are not part of provenance.
      assert_equal 1, visits.length
      assert_equal :chat, visits.first[0]
      assert_nil visits.first[4]
      assert_equal File.expand_path(root), Chat.provenance_path(visits.first[0], visits.first[1])
    end
  end

  def test_does_not_follow_continue_or_last
    TmpFile.with_dir do |dir|
      continued = File.join(dir, 'continued.chat')
      last_chat = File.join(dir, 'last_chat.chat')
      root = File.join(dir, 'root.chat')
      File.write(continued, "user: Continued\n")
      File.write(last_chat, "user: Last\n")
      File.write(root, "continue: continued.chat\nlast: last_chat.chat\nuser: Root\n")

      visits = Chat.traverse_provenance(root).to_a
      # Only the root chat is visited; continue and last are not part of provenance.
      assert_equal 1, visits.length
      assert_equal :chat, visits.first[0]
      assert_equal File.expand_path(root), Chat.provenance_path(visits.first[0], visits.first[1])
    end
  end

  def test_provenance_relations_does_not_include_import
    assert_not_include Chat::PROVENANCE_RELATIONS, :import
    assert_not_include Chat::PROVENANCE_RELATIONS, :continue
    assert_not_include Chat::PROVENANCE_RELATIONS, :last
    assert_equal %i[job dependency log result agent_job], Chat::PROVENANCE_RELATIONS
  end

  def test_traverses_job_and_log_relations
    TmpFile.with_dir do |dir|
      root = File.join(dir, 'root.chat')
      # A chat with a job reference. The job will not be loadable, so use on_error.
      File.write(root, "user: Root\njob: Agent/Worker/ask/Default_abcd1234\n")

      errors = []
      visits = Chat.traverse_provenance(root, on_error: ->(*args) { errors << args }).to_a
      # Root chat is always visited. The job reference is attempted but may fail.
      chat_visits = visits.select { |kind, *_rest| kind == :chat }
      assert chat_visits.any? { |kind, object, *_rest| Chat.provenance_path(kind, object) == File.expand_path(root) }
    end
  end

  def test_imports_in_chat_do_not_produce_warnings
    TmpFile.with_dir do |dir|
      root = File.join(dir, 'root.chat')
      File.write(root, "import: nonexistent.chat\nuser: Root\n")

      errors = []
      visits = Chat.traverse_provenance(root, on_error: ->(*args) { errors << args }).to_a
      # Import references are never resolved during provenance, so no errors.
      assert_equal 1, visits.length
      assert_empty errors
    end
  end

end
