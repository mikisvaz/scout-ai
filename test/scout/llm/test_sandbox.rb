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

  # The grant-source layer composes the same lists the Workspace workflow
  # composes today. Pinned with raw thread/config manipulation so the
  # assertion holds regardless of the ambient environment.
  def test_grant_sources_compose_defaults_thread_and_config
    saved_allowed = Thread.current['allowed_paths']
    saved_read = Thread.current['allowed_read_paths']
    Thread.current['allowed_paths'] = ['/thread/grant']
    Thread.current['allowed_read_paths'] = ['/thread/read']

    writable = LLM::Sandbox.writable_grants(scope: 'Workspace')
    readable = LLM::Sandbox.readable_grants(scope: 'Workspace')

    assert_include writable, '/thread/grant'
    assert_include writable, '/tmp'
    assert_include readable, '/thread/read'
    assert_include readable, '/bin'
    assert_not_include writable, '/thread/read'
    assert_not_include readable, '/thread/grant'

    # Defaults resolve unlocated Scout spellings through the path maps. The
    # :home expansion is computed live as the oracle: when an earlier test
    # file in the same process has required 'rbbt' (test_chat.rb,
    # test_tools.rb), Scout's PKGDIR switches and the expansion spelling
    # changes with it. The grant composition follows the live maps either
    # way, which is the property under test.
    assert_include writable.map(&:to_s), Path.setup('tmp').find(:home).to_s
  ensure
    Thread.current['allowed_paths'] = saved_allowed
    Thread.current['allowed_read_paths'] = saved_read
  end

  def test_grant_scope_tokens_and_expand
    assert_equal ['Workspace', 'workspace', 'sandbox'], LLM::Sandbox.grant_scope_tokens('Workspace')
    assert_equal ['sandbox'], LLM::Sandbox.grant_scope_tokens(nil)

    located = LLM::Sandbox.expand_grant_path('/tmp')
    assert_true Path === located || String === located
    assert_equal '/tmp', located.to_s

    expanded = LLM::Sandbox.expand_grant_path('/tmp')
    assert_kind_of Array, LLM::Sandbox.expand_grant_path('etc')
  end

  def test_grant_paths_reads_config_and_env_overrides
    Scout::Config.with_config do
      Scout::Config.set({'dirs' => '/plain/dirs'})
      Scout::Config.set({'dirs' => '/workspace/dirs'}, 'workspace')
      assert_equal ['/workspace/dirs'], LLM::Sandbox.grant_paths('dirs', scope: 'Workspace')
    end

    Scout::Config.with_config do
      ENV['DIRS'] = '/env/dirs'
      assert_equal ['/env/dirs'], LLM::Sandbox.grant_paths('dirs', scope: 'Workspace')
    end
  ensure
    ENV.delete('DIRS')
  end

  def test_grant_origin_reports_the_first_source_listing_a_path
    saved = Thread.current['allowed_paths']
    Thread.current['allowed_paths'] = nil
    LLM::Sandbox.allow_path('/tmp/grant-origin-job')

    assert_equal :thread, LLM::Sandbox.grant_origin('/tmp/grant-origin-job', scope: 'Workspace')
    assert_equal :exec_paths, LLM::Sandbox.grant_origin('/bin', scope: 'Workspace')
    assert_nil LLM::Sandbox.grant_origin('/definitely/not/a/grant', scope: 'Workspace')
  ensure
    Thread.current['allowed_paths'] = saved
  end

  def test_describe_grants_annotates_and_includes_hint
    text = LLM::Sandbox.describe_grants(scope: 'Workspace', root: '/some/root',
                                        hint: "Run task 'sandbox_paths' for details")
    assert_include text, '/some/root (read-write)'
    assert_include text, '/tmp (read-write)'
    assert_include text, '/bin (read-only)'
    assert_include text, "Run task 'sandbox_paths' for details"
    # read-only lines come after writable ones, and root heads the list
    assert_true text.index('/bin (read-only)') > text.index('/tmp (read-write)')
    assert_equal 0, text.index('/some/root (read-write)')
  end

  private

  def assert_allowed(path, root:)
    decision = LLM::Sandbox.authorize_path(path, root: root, mode: :write)
    assert_true decision.allowed
    assert_equal :root, decision.grant
  end
end
