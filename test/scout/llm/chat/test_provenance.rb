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

require_relative 'agent_meta_fixtures'

# NEW save-layout (step 3) provenance expectations.  The producer step changed
# the on-disk location of delegated agent chats:
#
#   direct delegated chat   <chat>.files/agent.chat (or <name>.chat)
#   society chats           <chat>.files/agent.society/<Agent>/<conv>/agent.chat
# The legacy `.files/log/**` tree is no longer read.
#
# These tests only exercise the traversal/read side; writing the new layout is
# covered by test/scout/llm/agent/test_save.rb.
class TestNewLayoutProvenance < Test::Unit::TestCase
  include AgentMetaFixtures

  ROOT_CHAT = "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n"

  def visits_paths(root, root_type: nil)
    opts = {}
    opts[:root_type] = root_type if root_type
    Chat.traverse_provenance(root, **opts).to_a.collect { |_k, object, _pk, _p, _r, _f| object.to_s }
  end

  # (a) new-layout society sidecar traversed with :log from a saved chat root
  def test_new_layout_society_sidecar_is_traversed_with_log_relation
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat', ROOT_CHAT)

      society = File.expand_path(File.join(chat + '.files', 'agent.society', 'Direct', 'harness_test'))
      FileUtils.mkdir_p(society)
      File.write(File.join(society, 'agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a
      assert_empty errors

      found = visits.find do |_kind, object, _pk, _parent, _relation, _first|
        object.to_s == File.join(society, 'agent.chat')
      end
      assert found, 'new-layout society chat not visited'
      kind, object, parent_kind, parent, relation, first = found
      assert_equal :chat, kind
      assert_equal :chat, parent_kind
      assert_equal File.expand_path(chat), parent.to_s
      assert_equal :log, relation
      assert first

      # Aggregation is preserved across layouts.
      assert_equal({pt: 12, ct: 6, tt: 18, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(chat))
    end
  end

  # (b) canonical root copy not traversed; legacy .files/log tree invisible
  def test_new_layout_root_copy_is_not_traversed
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat', ROOT_CHAT)

      files = File.expand_path(chat + '.files')
      FileUtils.mkdir_p(File.join(files, 'agent.society', 'Direct', 'harness_test'))
      # Leftover legacy tree: full root copy plus an old society projection.
      FileUtils.mkdir_p(File.join(files, 'log', 'society', 'Worker', 'default'))
      File.write(File.join(files, 'agent.chat'), ROOT_CHAT)
      File.write(File.join(files, 'log', 'agent.chat'), ROOT_CHAT)
      File.write(File.join(files, 'agent.society', 'Direct', 'harness_test', 'agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")
      File.write(File.join(files, 'log', 'society', 'Worker', 'default', 'agent.chat'),
                 "user: work2\nmeta: pt=20 ct=10 tt=30 inference_id=w2\nassistant: ok\n")

      paths = visits_paths(chat)

      new_root_copy = File.join(files, 'agent.chat')
      assert_not_include paths, new_root_copy,
                          'canonical root copy must not become its own node'
      assert_include paths, File.join(files, 'agent.society', 'Direct', 'harness_test', 'agent.chat')

      # The legacy tree is no longer read at all: neither its root copy nor
      # its society projections appear anywhere in the traversal.
      assert_empty paths.select { |path| path.include?(File.join(files, 'log')) },
                   'legacy .files/log tree must be invisible to traversal'

      edges = Chat.provenance_edges(chat).collect { |e| [e[:from].to_s, e[:to].to_s, e[:relation]] }
      assert_empty edges.select { |_from, to, _r| to == new_root_copy }
    end
  end

  # (c) a leftover legacy tree contributes nothing: no duplicate visits and
  #     no tokens from the legacy files.
  def test_both_layouts_coexist_without_duplicates
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat', ROOT_CHAT)

      files = File.expand_path(chat + '.files')
      FileUtils.mkdir_p(File.join(files, 'agent.society', 'Direct', 'harness_test'))
      FileUtils.mkdir_p(File.join(files, 'log', 'society', 'Worker', 'default'))

      File.write(File.join(files, 'agent.society', 'Direct', 'harness_test', 'agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")
      File.write(File.join(files, 'log', 'society', 'Worker', 'default', 'agent.chat'),
                 "user: work2\nmeta: pt=20 ct=10 tt=30 inference_id=w2\nassistant: ok\n")

      visits = Chat.traverse_provenance(chat).to_a
      paths = visits.collect { |_k, object, _pk, _p, _r, _f| object.to_s }
      assert_equal paths.uniq.length, paths.length, 'duplicate visits'

      # Only the canonical society chat was traversed; the legacy file was
      # never swept and contributes no tokens.
      assert_include paths, File.join(files, 'agent.society', 'Direct', 'harness_test', 'agent.chat')
      assert_not_include paths, File.join(files, 'log', 'society', 'Worker', 'default', 'agent.chat')
      assert_equal({pt: 12, ct: 6, tt: 18, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(chat))
    end
  end

  # Jobs are the other root type that owns a .files sidecar.
  def test_new_layout_job_files_are_traversed
    TmpFile.with_dir do |dir|
      job = make_job(dir, 'Worker/ask/Default_w')
      files = job + '.files'
      FileUtils.mkdir_p(File.join(files, 'agent.society', 'Critic', 'default'))

      # A job's own top-level chat IS traversed (renderers hide it).
      File.write(File.join(files, 'agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")
      File.write(File.join(files, 'agent.society', 'Critic', 'default', 'agent.chat'),
                 "user: critic\nmeta: pt=4 ct=2 tt=6 inference_id=c1\nassistant: ok\n")

      # A bare job path is only treated as a job with root_type: :job (the
      # CLI decides job vs chat through the .info sidecar).
      paths = visits_paths(job, root_type: :job)
      assert_include paths, File.expand_path(File.join(files, 'agent.chat'))
      assert_include paths, File.expand_path(File.join(files, 'agent.society', 'Critic', 'default', 'agent.chat'))

      # The collector also keeps both (a bare job path needs root_type: :job
      # here too; without it the traversal would treat it as a chat file).
      assert_equal({pt: 14, ct: 7, tt: 21, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(job, root_type: :job))
    end
  end

  # Nothing outside the three glob families may be swept.
  def test_files_outside_the_glob_families_are_not_swept
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat', ROOT_CHAT)

      files = File.expand_path(chat + '.files')
      resets = File.join(files, 'agent.chat.files', 'resets')
      FileUtils.mkdir_p(resets)
      File.write(File.join(resets, 'reset-1.chat'),
                 "user: reset\nmeta: pt=9 ct=9 tt=18 inference_id=r1\nassistant: ok\n")
      # Second-order .files tree that must stay invisible.
      other = File.join(files, 'other.files', 'agent.chat')
      FileUtils.mkdir_p(File.dirname(other))
      File.write(other, "user: other\nmeta: pt=9 ct=9 tt=18 inference_id=o1\nassistant: ok\n")

      assert_not_include visits_paths(chat), File.join(resets, 'reset-1.chat')
      assert_not_include visits_paths(chat), other
      assert_equal({pt: 2, ct: 1, tt: 3, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(chat))
    end
  end
end
