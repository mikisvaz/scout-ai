require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'tmpdir'
require 'fileutils'

# Focused tests for the recorded-payload fixture loader itself
# (TestFixtures.fixture / TestFixtures.fixture_path in
# test/support/fixtures.rb), covering the loader contract that the
# provider backend tests rely on:
#
#   * nested relative resolution rooted at test/fixtures
#   * traversal rejection (`../`, absolute references, symlink escapes)
#   * honest errors for missing files and invalid JSON
#
# The traversal cases run against a temporary root injected through the
# `root:` argument so no symlink or junk file is ever created inside
# test/fixtures; the real root is only read.
class TestFixturesLoader < Test::Unit::TestCase
  def write_fixture(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def with_fixture_root(&block)
    TmpFile.with_dir do |dir|
      block.yield File.join(dir, 'fixtures')
    end
  end

  # The real recorded payloads resolve through the shipped root.
  def test_real_root_is_test_fixtures
    assert_equal File.expand_path('test/fixtures', repo_root),
                 File.expand_path(TestFixtures::FIXTURES_DIR)
  end

  def test_loads_real_recorded_payload
    payload = TestFixtures.fixture('backends/openai_chat')
    assert_equal 'Mock answer from Chat Completions',
                 payload.dig('choices', 0, 'message', 'content')
  end

  def test_nested_relative_resolution
    with_fixture_root do |root|
      write_fixture(root, 'deep/nested/payload.json', '{"ok": true}')
      assert_equal({'ok' => true}, TestFixtures.fixture('deep/nested/payload', root: root))
      assert_equal File.join(root, 'deep', 'nested', 'payload.json'),
                   TestFixtures.fixture_path('deep/nested/payload', root: root)
    end
  end

  def test_fixture_path_appends_json_and_normalizes
    with_fixture_root do |root|
      assert_equal File.join(root, 'a', 'b.json'),
                   TestFixtures.fixture_path('a/b', root: root)
      # redundant-but-inside segments stay inside the root
      assert_equal File.join(root, 'a', 'b.json'),
                   TestFixtures.fixture_path('./a/b', root: root)
    end
  end

  def test_missing_file_raises_fixture_error_naming_the_path
    with_fixture_root do |root|
      e = assert_raise(TestFixtures::FixtureError) do
        TestFixtures.fixture('backends/no_such_fixture', root: root)
      end
      assert_include e.message, 'backends/no_such_fixture'
      assert_include e.message, File.join(root, 'backends', 'no_such_fixture.json')
    end
  end

  def test_invalid_json_raises_fixture_error_naming_the_path
    with_fixture_root do |root|
      write_fixture(root, 'broken.json', '{"a": [1, 2')
      e = assert_raise(TestFixtures::FixtureError) do
        TestFixtures.fixture('broken', root: root)
      end
      assert_include e.message, 'invalid JSON'
      assert_include e.message, File.join(root, 'broken.json')
    end
  end

  def test_empty_reference_rejected
    with_fixture_root do |root|
      e = assert_raise(TestFixtures::FixtureError) { TestFixtures.fixture_path('', root: root) }
      assert_include e.message, 'invalid fixture reference'
    end
  end

  def test_dot_dot_traversal_rejected
    with_fixture_root do |root|
      %w[../secret ../secret.json a/../.. backends/../../secret].each do |ref|
        e = assert_raise(TestFixtures::FixtureError) { TestFixtures.fixture_path(ref, root: root) }
        assert_include e.message, 'escapes the fixtures root'
      end
    end
  end

  def test_absolute_reference_rejected
    with_fixture_root do |root|
      [File.join(root, 'absolute'), '/etc/passwd'].each do |ref|
        e = assert_raise(TestFixtures::FixtureError) { TestFixtures.fixture_path(ref, root: root) }
        assert_include e.message, 'absolute fixture reference rejected'
      end
    end
  end

  # A `..` segment alone must be refused even when lexical normalization
  # would land back inside the root (e.g. `a/../b`): the loader's rule is
  # "no `..` segments at all", which is stricter and simpler to reason
  # about than tracking normalized escapes only.
  def test_dot_dot_segment_rejected_even_when_it_stays_inside
    with_fixture_root do |root|
      write_fixture(root, 'a/b.json', '{"ok": true}')
      assert_raise(TestFixtures::FixtureError) do
        TestFixtures.fixture('a/../a/b', root: root)
      end
    end
  end

  def test_symlink_escape_rejected
    with_fixture_root do |root|
      TmpFile.with_file do |outside|
        File.write(outside, '{"leaked": true}')
        FileUtils.mkdir_p(root)
        File.symlink(outside, File.join(root, 'leak.json'))
        e = assert_raise(TestFixtures::FixtureError) do
          TestFixtures.fixture('leak', root: root)
        end
        assert_include e.message, 'symlink'
      end
    end
  end

  def test_symlink_inside_the_root_is_allowed
    with_fixture_root do |root|
      write_fixture(root, 'real.json', '{"ok": true}')
      File.symlink('real.json', File.join(root, 'alias.json'))
      assert_equal({'ok' => true}, TestFixtures.fixture('alias', root: root))
    end
  end

  def test_directory_target_reports_missing_file
    with_fixture_root do |root|
      FileUtils.mkdir_p(File.join(root, 'dir.json'))
      e = assert_raise(TestFixtures::FixtureError) do
        TestFixtures.fixture('dir', root: root)
      end
      assert_include e.message, 'not found'
    end
  end

  def repo_root
    File.expand_path('../..', __dir__)
  end
end
