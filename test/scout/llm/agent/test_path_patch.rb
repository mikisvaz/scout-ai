require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"

class TestPathPatch < Test::Unit::TestCase
  def setup
    @tmpdir = Scout.tmp.agent_path_test.find
    FileUtils.mkdir_p(@tmpdir)
    @agent = LLM.agent
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def register_text_kind(name = "text", capabilities = {})
    @agent.register_path_kind(
      name,
      "description" => "Test text paths",
      "locations" => ["project", "tmp"],
      "default_location" => "project",
      "roots" => {
        "project" => @tmpdir,
        "tmp" => File.join(@tmpdir, "tmp")
      },
      "capabilities" => capabilities
    )
  end

  def register_patchy_kind(name = "text", capabilities = {})
    @agent.register_path_kind(
      name,
      "roots" => {
        "project" => @tmpdir,
        "tmp" => File.join(@tmpdir, "tmp")
      },
      "capabilities" => capabilities
    )
  end

  def simple_patch(original_line, replacement_line, line = 1)
    <<~PATCH
      --- a/f.txt
      +++ b/f.txt
      @@ -#{line} +#{line} @@
      -#{original_line}
      +#{replacement_line}
    PATCH
  end

  def test_patch_applies_simple_diff_and_preserves_untouched_bytes
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "f.txt",
                      "content" => "one\ntwo\nthree\n")
    result = @agent.path_patch(
      "kind" => "text", "path" => "f.txt",
      "patch" => simple_patch("two", "TWO", 2)
    )
    assert_equal "one\nTWO\nthree\n", result["content"]
    assert_equal "one\nTWO\nthree\n", File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_context_mismatch_writes_nothing
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "f.txt", "content" => "aaa\nbbb\n")
    assert_raise(ParameterException) do
      @agent.path_patch("kind" => "text", "path" => "f.txt",
                        "patch" => simple_patch("zzz", "y"))
    end
    assert_equal "aaa\nbbb\n", File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_malformed_text_rejected_before_mutation
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "f.txt", "content" => "a\n")
    ["", "not a diff", "--- a/f.txt\n+++ b/f.txt\ngarbage\n"].each do |bad|
      exception = assert_raise(ParameterException) do
        @agent.path_patch("kind" => "text", "path" => "f.txt", "patch" => bad)
      end
      assert exception.message.length > 0
    end
    assert_equal "a\n", File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_multi_file_rejected_before_mutation
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "f.txt", "content" => "a\n")
    multi = <<~PATCH
      --- a/f.txt
      +++ b/f.txt
      @@ -1 +1 @@
      -a
      +b
      --- a/other.txt
      +++ b/other.txt
      @@ -1 +1 @@
      -x
      +y
    PATCH
    exception = assert_raise(ParameterException) do
      @agent.path_patch("kind" => "text", "path" => "f.txt", "patch" => multi)
    end
    assert exception.message.include?("multi-file"), exception.message
    assert_equal "a\n", File.read(File.join(@tmpdir, "f.txt"))
    refute File.exist?(File.join(@tmpdir, "other.txt"))
  end

  def test_patch_header_filename_cannot_redirect_target
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "real.txt", "content" => "a\n")
    result = @agent.path_patch(
      "kind" => "text", "path" => "real.txt",
      "patch" => simple_patch("a", "b").gsub("f.txt", "evil.txt")
    )
    assert_equal "b\n", result["content"]
    assert_equal "b\n", File.read(File.join(@tmpdir, "real.txt"))
    refute File.exist?(File.join(@tmpdir, "evil.txt"))
  end

  def test_patch_multi_hunk_is_all_or_nothing
    register_patchy_kind("text", {"patch" => true})
    @agent.path_write("kind" => "text", "path" => "f.txt",
                      "content" => "one\ntwo\nthree\nfour\nfive\n")
    patch = <<~PATCH
      --- a/f.txt
      +++ b/f.txt
      @@ -1 +1 @@
      -one
      +ONE
      @@ -3 +3 @@
      -NOPE
      +X
    PATCH
    assert_raise(ParameterException) do
      @agent.path_patch("kind" => "text", "path" => "f.txt", "patch" => patch)
    end
    assert_equal "one\ntwo\nthree\nfour\nfive\n",
                 File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_final_newline_preserved_in_both_directions
    register_patchy_kind("text", {"patch" => true})

    @agent.path_write("kind" => "text", "path" => "plain.txt", "content" => "a\nb")
    @agent.path_patch("kind" => "text", "path" => "plain.txt",
                      "patch" => simple_patch("b", "x", 2))
    assert_equal "a\nx", File.read(File.join(@tmpdir, "plain.txt"))

    @agent.path_write("kind" => "text", "path" => "term.txt", "content" => "a\nb\n")
    @agent.path_patch("kind" => "text", "path" => "term.txt",
                      "patch" => simple_patch("b", "x", 2))
    assert_equal "a\nx\n", File.read(File.join(@tmpdir, "term.txt"))
  end

  def test_patch_no_newline_marker_adds_and_removes_final_newline
    register_patchy_kind("text", {"patch" => true})

    @agent.path_write("kind" => "text", "path" => "gain.txt", "content" => "a\nb")
    add_nl = <<~PATCH
      --- a/gain.txt
      +++ b/gain.txt
      @@ -2 +2 @@
      -b
      \\ No newline at end of file
      +b
    PATCH
    @agent.path_patch("kind" => "text", "path" => "gain.txt", "patch" => add_nl)
    assert_equal "a\nb\n", File.read(File.join(@tmpdir, "gain.txt"))

    @agent.path_write("kind" => "text", "path" => "drop.txt", "content" => "a\nb\n")
    drop_nl = <<~PATCH
      --- a/drop.txt
      +++ b/drop.txt
      @@ -2 +2 @@
      -b
      +b
      \\ No newline at end of file
    PATCH
    @agent.path_patch("kind" => "text", "path" => "drop.txt", "patch" => drop_nl)
    assert_equal "a\nb", File.read(File.join(@tmpdir, "drop.txt"))
  end

  def test_patch_default_off_and_capability_enables
    register_patchy_kind("text")
    @agent.path_write("kind" => "text", "path" => "f.txt", "content" => "a\n")
    assert_equal false, @agent.path_operation_support?("text", "patch")
    assert_raise(ParameterException) do
      @agent.path_patch("kind" => "text", "path" => "f.txt",
                        "patch" => simple_patch("a", "b"))
    end

    register_patchy_kind("patchy", {"patch" => true})
    assert_equal true, @agent.path_operation_support?("patchy", "patch")
    @agent.path_write("kind" => "patchy", "path" => "f.txt", "content" => "a\n")
    @agent.path_patch("kind" => "patchy", "path" => "f.txt",
                      "patch" => simple_patch("a", "b"))
    assert_equal "b\n", File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_content_override_runs_with_authorization
    register_patchy_kind("text", {"patch" => true})
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"patch" => true},
      "overrides" => {
        "patch" => ->(content, args) { "OVERRIDDEN:#{content}" }
      }
    )
    @agent.path_write("kind" => "fancy", "path" => "f.txt", "content" => "a\n")
    result = @agent.path_patch(
      "kind" => "fancy", "path" => "f.txt", "patch" => simple_patch("a", "b")
    )
    assert_equal "OVERRIDDEN:a\n", result["content"]
    assert_equal "OVERRIDDEN:a\n", File.read(File.join(@tmpdir, "f.txt"))
  end

  def test_patch_on_unauthorized_target_writes_nothing
    @agent.register_path_kind(
      "locked",
      "roots" => {"project" => "/nonexistent-root-xyz"},
      "capabilities" => {"patch" => true}
    )
    assert_raise(ParameterException) do
      @agent.path_patch("kind" => "locked", "path" => "f.txt",
                        "patch" => simple_patch("a", "b"))
    end
    refute File.exist?("/nonexistent-root-xyz/f.txt")
  end


end
