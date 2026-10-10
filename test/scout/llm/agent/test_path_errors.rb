require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"

class TestPathErrors < Test::Unit::TestCase
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

  def test_path_delete_missing_file_raises_parameter_exception
    register_text_kind

    error = assert_raise(ParameterException) do
      @agent.path_delete(
        "kind" => "text",
        "path" => "ghost.txt"
      )
    end

    assert_match(/Path does not exist or is not readable/, error.message)
    assert_match(/ghost\.txt/, error.message)
  end

  # Review point 4: the serialized error through the agent-facing tool
  # callable must be ParameterException, with no raw Errno::ENOENT escape.
  def test_path_delete_missing_file_through_tool_callable
    register_text_kind

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    result = JSON.parse(
      tools["path_delete"].first.call(
        "path_delete",
        {"kind" => "text", "path" => "ghost.txt"}
      )
    )

    # Serialized ParameterException message, not a raw Errno::ENOENT escape.
    assert_match(/Path does not exist or is not readable/, result["exception"])
    assert_match(/ghost\.txt/, result["exception"])
    assert result.key?("exception_line")
  end

  # Review point 4 control: the ENOENT normalization must not change the
  # happy path.  Deleting an existing file still works and the file is gone.
  def test_path_delete_existing_file_still_deletes_after_enoent_normalization
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "present.txt",
      "content" => "bye"
    )

    assert File.exist?(File.join(@tmpdir, "present.txt"))

    result = @agent.path_delete(
      "kind" => "text",
      "path" => "present.txt"
    )

    assert_equal true, result["deleted"]
    assert !File.exist?(File.join(@tmpdir, "present.txt"))
  end

  def test_error_matrix_unknown_kind
    error = assert_raise(ParameterException) do
      @agent.path_read("kind" => "nope", "path" => "hello.txt")
    end
    assert_match(/Unknown path kind: nope/, error.message)
  end

  def test_error_matrix_unknown_location
    register_text_kind
    error = assert_raise(ParameterException) do
      @agent.resolve_path("text", "hello.txt", "missing")
    end
    assert_match(/Location "missing" is not supported by path kind text/, error.message)
  end

  def test_error_matrix_location_without_configured_root
    @agent.register_path_kind(
      "orphan", "locations" => ["tmp", "custom"], "default_location" => "tmp",
      "roots" => {"tmp" => @tmpdir}
    )

    error = assert_raise(ParameterException) do
      @agent.path_read("kind" => "orphan", "path" => "hello.txt",
                       "location" => "custom")
    end
    assert_match(/No root configured for orphan at location custom/, error.message)
  end

  def test_error_matrix_missing_required_argument
    register_text_kind
    error = assert_raise(ParameterException) do
      @agent.path_read("kind" => "text")
    end
    assert_match(/Missing required argument "path"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_write("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Missing required argument "content"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_edit("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Missing required argument "selector"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_move("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Missing required argument "destination"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_rename("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Missing required argument "name"/, error.message)
  end

  def test_error_matrix_invalid_selector
    register_text_kind

    error = assert_raise(ParameterException) do
      @agent.path_apply_selector("hello world", {"type" => "unknown"}, "x")
    end
    assert_match(/Unknown selector type "unknown"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_apply_selector("hello world", {"start" => 1, "end" => 2}, "x")
    end
    assert_match(/Invalid selector: missing key "type"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_apply_selector("hello world", nil, "x")
    end
    assert_match(/Invalid selector: expected a mapping/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_apply_selector("hello world", {"type" => "lines"}, "x")
    end
    assert_match(/Invalid selector: missing key "start"/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_apply_selector("hello world", {"type" => "regexp"}, "x")
    end
    assert_match(/Invalid selector: missing key "pattern"/, error.message)
  end

  def test_error_matrix_malformed_selector_values_reject_and_never_mutate
    register_text_kind
    @agent.path_write(
      "kind" => "text", "path" => "keep.txt", "content" => "a\nb\nc\n"
    )
    target = File.join(@tmpdir, "keep.txt")
    before = File.read(target)

    malformed = [
      ["nil start", {"type" => "lines", "start" => nil, "end" => 1}],
      ["nil end", {"type" => "lines", "start" => 0, "end" => nil}],
      ["string start", {"type" => "lines", "start" => "1", "end" => 2}],
      ["float start", {"type" => "lines", "start" => 1.5, "end" => 2}],
      ["start beyond document", {"type" => "lines", "start" => 9, "end" => 10}],
      ["start > end", {"type" => "lines", "start" => 2, "end" => 1}],
      ["chars nil index", {"type" => "chars", "start" => nil, "end" => 2}],
      ["chars string index", {"type" => "chars", "start" => "0", "end" => 2}],
      ["chars out of range", {"type" => "chars", "start" => 99, "end" => 120}],
      ["invalid regexp", {"type" => "regexp", "pattern" => "["}]
    ]

    malformed.each do |label, selector|
      error = assert_raise(ParameterException) do
        @agent.path_edit(
          "kind" => "text", "path" => "keep.txt",
          "selector" => selector, "replacement" => "z"
        )
      end
      assert_equal "a\nb\nc\n", File.read(target),
                   "#{label}: file must stay byte-identical"
    end

    assert_equal before, File.read(target)
  end

  def test_error_matrix_path_outside_grant
    register_text_kind
    outside = Dir.mktmpdir("path-outside")
    target = File.join(outside, "escape.txt")

    error = assert_raise(ParameterException) do
      @agent.path_write("kind" => "text", "path" => target, "content" => "no")
    end
    assert_equal "Path access denied by sandbox (outside_grants)", error.message
    assert_false File.exist?(target)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_error_matrix_unsupported_operation
    register_text_kind("text", "validate" => false, "test" => false,
                       "promote" => false, "rename" => false)

    error = assert_raise(ParameterException) do
      @agent.path_validate("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Path kind text does not support validate/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "text", "path" => "hello.txt")
    end
    assert_match(/Path kind text does not support promote/, error.message)

    error = assert_raise(ParameterException) do
      @agent.path_rename("kind" => "text", "path" => "hello.txt", "name" => "x.txt")
    end
    assert_match(/Path kind text does not support rename/, error.message)
  end

  # ------------------------------------------------------------------
  # Promotion (ENGINE-CONTROLLED)
  #
  # The engine resolves the destination from a declarative spec, authorizes
  # BOTH endpoints, enforces no-clobber, and performs the move itself via
  # path_move_target.  A kind callback is never the writer.  Optional
  # post-move behavior hooks through "promotion_post_move".  Every
  # rejection case asserts that no filesystem mutation happened (source
  # unchanged, destination absent).
  # ------------------------------------------------------------------


end
