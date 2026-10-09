require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'fileutils'
require 'tmpdir'
# sandbox is loaded through scout/llm/chat/process/tools in the public API path.
require 'scout/llm/chat'

class TestSandbox < Test::Unit::TestCase
  def setup
    super
    @root = Dir.mktmpdir('scout-ai-sandbox-')
    %w[root/nested read_grant write_grant outside].each do |directory|
      FileUtils.mkdir_p(File.join(@root, directory))
    end
  end

  def teardown
    FileUtils.rm_rf(@root) if @root
    super
  end

  def test_grant_registration_and_chat_compatibility
    Thread.current['allowed_paths'] = nil
    Thread.current['allowed_read_paths'] = nil

    Chat.allow_path('raw/path')
    Chat.allow_path('raw/path')
    Chat.allow_read_path('read/raw')
    Chat.allow_read_path('read/raw')

    assert_equal ['raw/path'], Thread.current['allowed_paths']
    assert_equal ['read/raw'], Thread.current['allowed_read_paths']

    job = Struct.new(:path, :info_file, :files_dir).new('job/path', 'job/info', 'job/files')
    Chat.allow_job(job)
    Chat.allow_read_job(job)
    assert_equal ['raw/path', 'job/path', 'job/info', 'job/files'], Thread.current['allowed_paths']
    assert_equal ['read/raw', 'job/path', 'job/info', 'job/files'], Thread.current['allowed_read_paths']
  ensure
    Thread.current['allowed_paths'] = nil
    Thread.current['allowed_read_paths'] = nil
  end

  def test_authorization_uses_root_and_nested_boundary_not_sibling_prefix
    root = File.join(@root, 'root')
    assert_allowed File.join(root, 'nested'), root: root
    assert_allowed root, root: root
    decision = LLM::Sandbox.authorize_path(File.join(@root, 'root-sibling'), root: root)
    assert_false decision.allowed
    assert_equal :outside_grants, decision.reason
  end

  def test_relative_paths_require_an_explicit_base
    assert_raise(ParameterException) do
      LLM::Sandbox.authorize_path('root/nested', root: File.join(@root, 'root'), mode: :write)
    end

    decision = LLM::Sandbox.authorize_path('nested', root: File.join(@root, 'root'),
                                           base_path: File.join(@root, 'root'), mode: :write)
    assert_true decision.allowed
  end

  def test_read_and_write_grants_have_distinct_semantics
    target = File.join(@root, 'read_grant', 'document.txt')
    File.write(target, 'read me')
    read_decision = LLM::Sandbox.authorize_path(target, root: File.join(@root, 'root'),
                                                read_paths: [File.join(@root, 'read_grant')], mode: :read)
    write_decision = LLM::Sandbox.authorize_path(target, root: File.join(@root, 'root'),
                                                 read_paths: [File.join(@root, 'read_grant')], mode: :write)
    assert_true read_decision.allowed
    assert_equal :read, read_decision.grant
    assert_false write_decision.allowed
  end

  def test_existing_symlink_cannot_escape_a_grant
    grant = File.join(@root, 'write_grant')
    link = File.join(grant, 'escape')
    File.symlink(File.join(@root, 'outside'), link)

    decision = LLM::Sandbox.authorize_path(File.join(link, 'secret.txt'), root: File.join(@root, 'root'),
                                           writable_paths: [grant], mode: :write)
    assert_false decision.allowed
    assert_equal File.join(@root, 'outside', 'secret.txt'), decision.canonical_path
  end

  def test_missing_target_under_symlinked_parent_is_resolved_before_authorization
    grant = File.join(@root, 'write_grant')
    link = File.join(grant, 'to_outside')
    File.symlink(File.join(@root, 'outside'), link)
    target = File.join(link, 'new.txt')

    decision = LLM::Sandbox.authorize_path(target, root: File.join(@root, 'root'),
                                           writable_paths: [grant], mode: :write)
    assert_false decision.allowed
    assert_false decision.exists
    assert_equal File.join(@root, 'outside', 'new.txt'), decision.canonical_path
  end

  def test_missing_descendant_within_grant_is_allowed_and_marked_missing
    root = File.join(@root, 'root')
    target = File.join(root, 'nested', 'not-yet-created')
    decision = LLM::Sandbox.authorize_path(target, root: root, mode: :write)
    assert_true decision.allowed
    assert_false decision.exists
    assert_equal :root, decision.grant
  end

  def test_parent_component_requires_existing_preceding_directory
    root = File.join(@root, 'root')
    file = File.join(root, 'regular-file')
    File.write(file, 'not a directory')

    invalid = LLM::Sandbox.authorize_path(File.join(file, '..', 'child'), root: root, mode: :write)
    assert_false invalid.allowed
    assert_nil invalid.canonical_path
    assert_equal :unresolvable, invalid.reason

    valid = LLM::Sandbox.authorize_path(File.join(root, 'nested', '..', 'child'), root: root, mode: :write)
    assert_true valid.allowed
    assert_equal File.join(root, 'child'), valid.canonical_path
  end

  def test_parent_component_checks_preceding_directory_without_rechecking_parent
    root = File.join(@root, 'root')
    nested = File.join(root, 'nested')
    directory_checks = []
    original_directory_check = Open.method(:directory?)
    Open.define_singleton_method(:directory?) do |path|
      directory_checks << path
      original_directory_check.call(path)
    end

    result = LLM::Sandbox.resolve_path(File.join(nested, '..', 'child'))

    assert_equal File.join(root, 'child'), result[:canonical_path]
    assert_equal [nested], directory_checks
  ensure
    Open.define_singleton_method(:directory?, original_directory_check) if original_directory_check
  end

  def test_missing_component_before_parent_component_is_not_collapsed
    root = File.join(@root, 'root')
    result = LLM::Sandbox.resolve_path(File.join(root, 'missing', '..', 'child'))

    assert_nil result[:canonical_path]
    assert_false result[:exists]
  end

  def test_unresolvable_dangling_symlink_is_denied
    grant = File.join(@root, 'write_grant')
    dangling = File.join(grant, 'dangling')
    File.symlink(File.join(@root, 'missing-target'), dangling)
    decision = LLM::Sandbox.authorize_path(dangling, root: File.join(@root, 'root'),
                                           writable_paths: [grant], mode: :write)
    assert_false decision.allowed
    assert_equal :unresolvable, decision.reason
  end

  private

  def assert_allowed(path, root:)
    decision = LLM::Sandbox.authorize_path(path, root: root, mode: :write)
    assert_true decision.allowed
    assert_equal :root, decision.grant
  end
end
