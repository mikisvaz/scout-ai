require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"

class TestPathEditing < Test::Unit::TestCase
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

  def test_path_edit_with_line_selector
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "one\ntwo\nthree\n"
    )

    result = @agent.path_edit(
      "kind" => "text",
      "path" => "hello.txt",
      "selector" => {
        "type" => "lines",
        "start" => 1,
        "end" => 2
      },
      "replacement" => "changed\n"
    )

    assert_equal true, result["changed"]
    assert_equal "one\nchanged\nthree\n", result["content"]
  end

  def test_path_edit_with_character_selector
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello world"
    )

    result = @agent.path_edit(
      "kind" => "text",
      "path" => "hello.txt",
      "selector" => {
        "type" => "chars",
        "start" => 6,
        "end" => 11
      },
      "replacement" => "Scout"
    )

    assert_equal "hello Scout", result["content"]
  end

  def test_path_edit_with_regexp_selector
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello world"
    )

    result = @agent.path_edit(
      "kind" => "text",
      "path" => "hello.txt",
      "selector" => {
        "type" => "regexp",
        "pattern" => "world"
      },
      "replacement" => "Scout"
    )

    assert_equal "hello Scout", result["content"]
  end

  def test_path_edit_rejects_invalid_selector
    assert_raise(ParameterException) do
      @agent.path_apply_selector(
        "hello world",
        {"type" => "unknown"},
        "replacement"
      )
    end
  end

  # Review point 3 (Phase 0 fixes): a non-String regexp pattern is invalid
  # input and must surface as ParameterException at the operation boundary,
  # never as a TypeError escaping Regexp.new.
  def test_path_edit_regexp_selector_non_string_pattern_raises_parameter_exception
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello world"
    )

    [nil, 5, :x].each do |pattern|
      error = assert_raise(ParameterException) do
        @agent.path_edit(
          "kind" => "text",
          "path" => "hello.txt",
          "selector" => {"type" => "regexp", "pattern" => pattern},
          "replacement" => "Scout"
        )
      end

      assert_match(/pattern must be a String, got /, error.message)
    end
  end

  # Review point 3: the same normalization must hold through the
  # agent-facing tool callable, whose rescue serializes ScoutException
  # subclasses.  A raw TypeError would escape it entirely.
  def test_path_edit_regexp_selector_non_string_pattern_through_tool_callable
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello world"
    )

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    result = JSON.parse(
      tools["path_edit"].first.call(
        "path_edit",
        {
          "kind" => "text",
          "path" => "hello.txt",
          "selector" => {"type" => "regexp", "pattern" => nil},
          "replacement" => "Scout"
        }
      )
    )

    # Serialized ParameterException message, not a raw TypeError escape.
    assert_match(/pattern must be a String/, result["exception"])
    assert result.key?("exception_line")
  end

  def test_path_edit_rejects_invalid_line_range
    assert_raise(ParameterException) do
      @agent.path_apply_selector(
        "one\ntwo\n",
        {
          "type" => "lines",
          "start" => 2,
          "end" => 1
        },
        "replacement"
      )
    end
  end

  def test_path_edit_rejects_invalid_character_range
    assert_raise(ParameterException) do
      @agent.path_apply_selector(
        "hello",
        {
          "type" => "chars",
          "start" => 4,
          "end" => 2
        },
        "replacement"
      )
    end
  end

  def write_selector_fixture(content)
    register_text_kind
    @agent.path_write(
      "kind" => "text", "path" => "selector.txt", "content" => content
    )
  end

  def edit_lines(content, start, finish, replacement)
    write_selector_fixture(content)
    result = @agent.path_edit(
      "kind" => "text",
      "path" => "selector.txt",
      "selector" => {"type" => "lines", "start" => start, "end" => finish},
      "replacement" => replacement
    )
    [result["content"], File.read(File.join(@tmpdir, "selector.txt"))]
  end

  def edit_chars(content, start, finish, replacement)
    write_selector_fixture(content)
    result = @agent.path_edit(
      "kind" => "text",
      "path" => "selector.txt",
      "selector" => {"type" => "chars", "start" => start, "end" => finish},
      "replacement" => replacement
    )
    [result["content"], File.read(File.join(@tmpdir, "selector.txt"))]
  end

  def assert_edit_result(expected, got)
    reported, on_disk = got
    assert_equal expected, reported
    assert_equal expected, on_disk
  end

  def test_lines_selector_first_middle_final_line
    assert_edit_result "A\ntwo\nthree\n", edit_lines("one\ntwo\nthree\n", 0, 1, "A")
    assert_edit_result "one\nX\nthree\n", edit_lines("one\ntwo\nthree\n", 1, 2, "X")
    assert_edit_result "one\ntwo\nZ\n", edit_lines("one\ntwo\nthree\n", 2, 3, "Z")
  end

  def test_lines_selector_final_line_keeps_missing_final_newline
    assert_edit_result "one\ntwo\nZ", edit_lines("one\ntwo\nthree", 2, 3, "Z")
    assert_edit_result "one\nX\nthree", edit_lines("one\ntwo\nthree", 1, 2, "X")
  end

  def test_lines_selector_single_line_file_with_and_without_final_newline
    assert_edit_result "new\n", edit_lines("only\n", 0, 1, "new")
    assert_edit_result "new", edit_lines("only", 0, 1, "new")
  end

  def test_lines_selector_replacement_without_trailing_newline_is_corruption_fixed
    assert_edit_result "one\nX\nthree\n", edit_lines("one\ntwo\nthree\n", 1, 2, "X")
    assert_edit_result "a\nchanged\nc\n", edit_lines("a\nb\nc\n", 1, 2, "changed")
  end

  def test_lines_selector_replacement_with_trailing_newline_is_not_doubled
    assert_edit_result "a\nchanged\nc\n", edit_lines("a\nb\nc\n", 1, 2, "changed\n")
  end

  def test_lines_selector_eof_trailing_newline_in_replacement_is_stripped
    # Defect 2: the original has no final newline, so the replacement's
    # trailing newline must NOT introduce one at the EOF boundary.
    assert_edit_result "a\nx", edit_lines("a\nb", 1, 2, "x\n")
  end

  def test_lines_selector_eof_counterpart_keeps_final_newline
    assert_edit_result "a\nx\n", edit_lines("a\nb\n", 1, 2, "x\n")
  end

  def test_lines_selector_eof_repeated_trailing_newlines_are_stripped
    assert_edit_result "a\ny\nz", edit_lines("a\nb\nc", 1, 3, "y\nz\n\n")
  end

  def test_lines_selector_interior_repeated_newlines_collapse_to_one
    assert_edit_result "x\nb\nc", edit_lines("a\nb\nc", 0, 1, "x\n\n")
  end

  def test_lines_selector_eof_multiline_replacement_without_final_newline
    assert_edit_result "a\ny\nz", edit_lines("a\nb\nc", 1, 3, "y\nz")
    assert_edit_result "a\ny\nz\n", edit_lines("a\nb\nc\n", 1, 3, "y\nz")
  end

  def test_lines_selector_eof_more_lines_than_span
    assert_edit_result "a\ny\nz\nw\nq", edit_lines("a\nb\nc", 1, 3, "y\nz\nw\nq")
  end

  def test_lines_selector_eof_fewer_lines_than_span
    assert_edit_result "a\ny\nd", edit_lines("a\nb\nc\nd", 1, 3, "y")
  end

  def test_lines_selector_delete_final_line_at_eof
    assert_edit_result "a\nb", edit_lines("a\nb\nc", 2, 3, "")
    assert_edit_result "a\nb\n", edit_lines("a\nb\nc\n", 2, 3, "")
  end

  def test_lines_selector_delete_interior_line
    assert_edit_result "a\nc", edit_lines("a\nb\nc", 1, 2, "")
  end

  def test_lines_selector_replace_entire_file
    assert_edit_result "z", edit_lines("a\nb\nc", 0, 3, "z")
    assert_edit_result "z\n", edit_lines("a\nb\nc\n", 0, 3, "z\n")
    assert_edit_result "", edit_lines("a\nb\nc\n", 0, 3, "")
  end

  def test_lines_selector_one_line_file_with_and_without_final_newline
    assert_edit_result "new", edit_lines("only", 0, 1, "new")
    assert_edit_result "new\n", edit_lines("only\n", 0, 1, "new\n")
  end

  def test_lines_selector_multiline_replacement_spanning_two_lines
    assert_edit_result "a\nx\ny\nz\nd\n", edit_lines("a\nb\nc\nd\n", 1, 3, "x\ny\nz")
  end

  def test_lines_selector_replacement_with_more_lines_than_span
    assert_edit_result "a\np\nq\nr\nc\n", edit_lines("a\nb\nc\n", 1, 2, "p\nq\nr")
  end

  def test_lines_selector_replacement_with_fewer_lines_than_span
    assert_edit_result "a\nsingle\nd\n", edit_lines("a\nb\nc\nd\n", 1, 3, "single")
  end

  def test_lines_selector_empty_replacement_deletes_span
    assert_edit_result "a\nc\n", edit_lines("a\nb\nc\n", 1, 2, "")
  end

  def test_lines_selector_end_clamped_to_last_line
    assert_edit_result "a\nb\nc\nappend\n", edit_lines("a\nb\nc\n", 3, 5, "append")
  end

  def test_lines_selector_rejects_start_beyond_last_line
    register_text_kind
    @agent.path_write(
      "kind" => "text", "path" => "selector.txt", "content" => "a\nb\n"
    )

    error = assert_raise(ParameterException) do
      @agent.path_edit(
        "kind" => "text",
        "path" => "selector.txt",
        "selector" => {"type" => "lines", "start" => 5, "end" => 6},
        "replacement" => "x"
      )
    end
    assert_match(/is beyond the last index 2/, error.message)
  end

  def test_lines_selector_rejects_negative_start
    error = assert_raise(ParameterException) do
      @agent.path_apply_selector(
        "a\nb\n", {"type" => "lines", "start" => -1, "end" => 1}, "x"
      )
    end
    assert_match(/must be >= 0, got -1/, error.message)
  end

  def test_chars_selector_plain_offset_length
    assert_edit_result "hello Scout", edit_chars("hello world", 6, 11, "Scout")
  end

  def test_chars_selector_to_end_of_content
    assert_edit_result "hello", edit_chars("hello world", 5, 11, "")
  end

  def test_chars_selector_empty_replacement_deletes_exact_bytes
    assert_edit_result "helo", edit_chars("hello", 3, 4, "")
  end

  def test_chars_selector_zero_length_inserts
    assert_edit_result "aXbc", edit_chars("abc", 1, 1, "X")
  end

  def test_chars_selector_preserves_untouched_prefix_and_suffix
    assert_edit_result "aaXYbb", edit_chars("aaaabb", 2, 4, "XY")
    assert_edit_result "aaaab\nb\n", edit_chars("aaaab\nb\n", 0, 0, "")
  end

  def test_chars_selector_multibyte_character_boundaries
    # String#[]= operates on characters, not bytes; boundaries are safe.
    assert_edit_result "hÉllo", edit_chars("héllo", 1, 2, "É")
  end

  # ------------------------------------------------------------------
  # Registry authority (single instance registry)
  # ------------------------------------------------------------------

  def edit_schema_without_kind_enum(schema)
    copy = Marshal.load(Marshal.dump(schema))
    props = copy[:parameters][:properties]
    props.delete("kind") if props["kind"]
    props.delete(:kind) if props[:kind]
    fn = copy[:function] and fn[:parameters][:properties].delete(:kind) rescue nil
    copy
  end

  def test_edit_schema_unchanged_by_edit_override_registration
    register_text_kind
    before = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )

    @agent.register_path_kind(
      "override_kind",
      "roots" => {"project" => @tmpdir},
      "operations" => {},
      "overrides" => {
        "edit" => ->(content, args) { content }
      }
    )

    after = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )
    assert_equal before, after
  end

  def test_edit_schema_unchanged_by_custom_operation_registration
    register_text_kind
    before = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )

    @agent.register_path_kind(
      "specialized",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Replace exact occurrences of old with new",
          "parameters" => {
            "properties" => {
              "old_text" => {"type" => "string"},
              "new_text" => {"type" => "string"},
              "count" => {"type" => "integer"}
            },
            "required" => %w[old_text new_text]
          },
          "implementation" => ->(content, args) { content },
          "authorization" => :write,
          "type" => :content
        }
      }
    )

    after = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )
    assert_equal before, after
  end

  def test_edit_schema_matches_pre_architecture_reference
    register_text_kind
    # Reference recorded in tmp/path_recon.md (Phase-0 baseline and
    # Step-7 source comparison): HEAD's edit schema block is byte
    # identical to the live one (verified by diff); assert the exact
    # public shape here so future drift fails loudly.
    schema = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )
    props = schema[:parameters][:properties]
    assert_equal %w[path location selector replacement], props.keys
    assert_equal "string", props[:path][:type]
    assert_equal "string", props[:location][:type]
    assert_equal %w[lines chars regexp], props[:selector][:properties][:type][:enum]
    assert_equal "integer", props[:selector][:properties][:start][:type]
    assert_equal "integer", props[:selector][:properties][:end][:type]
    assert_equal "string", props[:selector][:properties][:pattern][:type]
    assert_equal "string", props[:replacement][:type]
    assert_equal "Replacement text.", props[:replacement][:description]
    assert_equal "Edit a textual Path using a line range, character range, or regular expression selector.",
      schema[:description]
  end

  def test_precise_edit_custom_operation_full_path
    register_text_kind
    edits = []
    @agent.register_path_kind(
      "special",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Replace exact occurrences",
          "parameters" => {
            "properties" => {
              "old_text" => {"type" => "string"},
              "new_text" => {"type" => "string"},
              "count" => {"type" => "integer"}
            },
            "required" => %w[old_text new_text]
          },
          "implementation" => ->(content, args) {
            edits << args
            content.gsub(args["old_text"], args["new_text"])
          },
          "type" => :content
        }
      }
    )

    tools = @agent.instance_variable_get(:@other_options)[:tools]
    assert tools.key?("precise_edit")
    assert_equal 1, tools.keys.count { |k| k == "precise_edit" }
    params = tools["precise_edit"][1][:parameters][:properties]
    assert_equal %w[kind path location old_text new_text count], params.keys

    @agent.path_write(
      "kind" => "special", "path" => "notes.txt", "content" => "one two one\n"
    )
    result = @agent.path_dispatch(
      kind: "special", operation: "precise_edit",
      "path" => "notes.txt", "old_text" => "one", "new_text" => "1"
    )
    assert_equal "1 two 1\n", File.read(File.join(@tmpdir, "notes.txt"))
    assert edits.any?, "callback must run after authorization"

    # Global edit schema untouched by the custom registration
    edit_after = edit_schema_without_kind_enum(
      @agent.instance_variable_get(:@other_options)[:tools]["path_edit"][1]
    )
    assert_equal %w[path location selector replacement],
      edit_after[:parameters][:properties].keys
  end


  # ------------------------------------------------------------------
  # Step 3 (DC-2) — type-aware edit dispatch
  # ------------------------------------------------------------------

  def register_edit_override_kind(spec, name = "fancy_edit")
    @agent.register_path_kind(
      name,
      "roots" => {"project" => @tmpdir},
      "overrides" => {"edit" => spec}
    )
  end

  def test_full_edit_override_fires_with_agent_target_and_args
    calls = []
    register_edit_override_kind(
      "implementation" => lambda { |agent, target, args|
        calls << [agent, target, args["path"]]
        original = File.read(target.to_s)
        File.write(target.to_s, original.sub("one", "ONE"))
        {"applied_count" => 1, "content" => "handler-lie"}
      },
      "type" => :full
    )

    @agent.path_write(
      "kind" => "fancy_edit", "path" => "note.txt", "content" => "one two\n"
    )

    result = @agent.path_edit(
      "kind" => "fancy_edit", "path" => "note.txt",
      "selector" => {"type" => "lines", "start" => 0, "end" => 0},
      "replacement" => "ignored"
    )

    target = File.join(@tmpdir, "note.txt")
    assert_equal 1, calls.length
    assert_same @agent, calls.first.first
    assert_equal target, calls.first[1]
    assert_equal "note.txt", calls.first[2]

    # Verified reality at the authorized target, not the handler's claim
    assert_equal "ONE two\n", File.read(target)
    assert_equal "ONE two\n", result["content"]
    assert_equal true, result["changed"]
    assert_equal 1, result["applied_count"]
  end

  def test_full_edit_override_non_hash_return_is_parameter_error_envelope
    register_edit_override_kind(
      "implementation" => ->(agent, target, args) { "NOT A HASH" },
      "type" => :full
    )

    @agent.path_write(
      "kind" => "fancy_edit", "path" => "note.txt", "content" => "body\n"
    )

    tools = @agent.instance_variable_get(:@other_options)[:tools]
    result = JSON.parse(
      tools["path_edit"].first.call(
        "path_edit",
        {"kind" => "fancy_edit", "path" => "note.txt",
         "selector" => {"type" => "lines", "start" => 0, "end" => 0},
         "replacement" => "x"}
      )
    )

    assert_match(/must return a Hash payload/, result["exception"])
    assert result.key?("exception_line")
    # The handler performed no write; the file is untouched
    assert_equal "body\n", File.read(File.join(@tmpdir, "note.txt"))
  end

  def test_content_edit_override_receives_content_and_args_and_writes_string
    calls = []
    register_edit_override_kind(
      lambda { |content, args|
        calls << [content, args["path"]]
        content.upcase
      }
    )

    @agent.path_write(
      "kind" => "fancy_edit", "path" => "note.txt", "content" => "body\n"
    )

    result = @agent.path_edit(
      "kind" => "fancy_edit", "path" => "note.txt",
      "selector" => {"type" => "lines", "start" => 0, "end" => 0},
      "replacement" => "ignored"
    )

    target = File.join(@tmpdir, "note.txt")
    assert_equal [["body\n", "note.txt"]], calls
    assert_equal "BODY\n", File.read(target)
    assert_equal "BODY\n", result["content"]
    assert_equal true, result["changed"]
  end

  def test_content_edit_override_selector_replacement_not_applied
    # PINNED CONTRACT (DC-2 decision): under a :content edit override the
    # selector/replacement arguments are validated but NOT applied; the
    # handler's returned content IS the edited file.  Documented in
    # doc/developer/PathEngine.md §5.
    register_edit_override_kind(
      lambda { |content, args| "REWRITTEN\n" }
    )

    @agent.path_write(
      "kind" => "fancy_edit", "path" => "note.txt",
      "content" => "line 0\nline 1\n"
    )

    # A selector that would, if applied, replace only line 1
    result = @agent.path_edit(
      "kind" => "fancy_edit", "path" => "note.txt",
      "selector" => {"type" => "lines", "start" => 1, "end" => 1},
      "replacement" => "SELECTOR APPLIED"
    )

    target = File.join(@tmpdir, "note.txt")
    assert_equal "REWRITTEN\n", File.read(target),
      "handler return must land in the file wholesale"
    refute File.read(target).include?("SELECTOR APPLIED"),
      "selector/replacement must not be applied under a content edit override"
    assert_equal "REWRITTEN\n", result["content"]
  end

  def test_full_edit_override_authorization_failure_runs_no_handler
    calls = []
    register_edit_override_kind(
      "implementation" => ->(agent, target, args) { calls << target },
      "type" => :full
    )

    assert_raise(ParameterException) do
      @agent.path_edit(
        "kind" => "fancy_edit", "path" => "../../etc/hostname",
        "selector" => {"type" => "lines", "start" => 0, "end" => 0},
        "replacement" => "denied"
      )
    end

    assert_empty calls
  end

  # Step 6: patch operation
  # ------------------------------------------------------------------


  # ------------------------------------------------------------------
  # H-011 regression (path-edit corruption cluster, step 2 of the fix plan).
  #
  # Incident: `path_edit` with a `lines` selector on a multi-line
  # single-quoted YAML scalar duplicated preceding lines in Research
  # Hypothesis record H-011 across v5-v12; sloppy repairs added further
  # duplication (v12->v13 appended `demonstration)` onto an existing list
  # item; v13->v14 cleaned a `the migration manifest. the migration
  # manifest.` duplication).
  #
  # Step-1 attribution evidence (probed exhaustively in a fresh process):
  # the generic `lines` splice alone NEVER duplicates a preceding/head line;
  # duplication arises exactly when the caller-supplied replacement itself
  # carries the preceding text (the agent re-pasted lines it had already
  # read).  These tests pin, through the PUBLIC path_edit operation:
  #
  #   1. the generic layer writes a corruption-shaped replacement
  #      FAITHFULLY (no YAML parsing, no duplicate-text heuristics may enter
  #      AgentPathEdit; `lines` keeps meaning "replace these physical
  #      lines"),
  #   2. the INTENDED edit is byte-exact and leaves unselected lines
  #      byte-identical,
  #   3. the same public operation against a kind registering the SAME
  #      `:full` edit override shape the Research `hypothesis` kind uses
  #      (records.rb L345-L353: re-apply the caller's selector/replacement
  #      through agent.path_apply_selector, then validate and re-serialize)
  #      commits the corruption end to end: the re-parse CONCATENATES the
  #      duplicated fragments into one statement value, which is how H-011
  #      v5-v12 corruption persisted through record validation.
  # ------------------------------------------------------------------

  # The reviewer's illustrative multi-line single-quoted scalar fixture
  # (commentary cL2785-2791), carried over from the step-1 reconstruction.
  H011_FIXTURE_LINES = [
    "statement: 'The initial interpretation remains provisional\n",
    "  because the shared response is also present in the control.\n",
    "  The final qualification must remain intact.'\n",
    "scope:\n",
    "  population: \"cohort A\"\n",
    "limitations:\n",
    "  - \"No biological replicates\"\n"
  ].freeze
  H011_FIXTURE = H011_FIXTURE_LINES.join.freeze

  def test_h011_generic_lines_edit_writes_duplication_faithfully_when_replacement_duplicates
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "doc.yaml",
      "content" => H011_FIXTURE
    )

    # Corruption-shaped edit: insert lines 0-1 verbatim between line 0 and
    # line 1 (start == end == 1 is a zero-length span, i.e. an insertion
    # point, per the documented exclusive-end semantics; the step-1
    # reconstruction's exact reproducer).  The public operation must write
    # it faithfully: the generic layer is a predictable text editor, not a
    # validator.  Pins candidate (a) as disproved and the fix constraint
    # that `lines` semantics stay untouched.
    result = @agent.path_edit(
      "kind" => "text",
      "path" => "doc.yaml",
      "selector" => {"type" => "lines", "start" => 1, "end" => 1},
      "replacement" => H011_FIXTURE_LINES[0, 2].join
    )

    # head = [line 0]; the span [1...1] is empty so the replacement is
    # inserted verbatim; tail = lines 1.. untouched.
    expected =
      H011_FIXTURE_LINES[0, 1].join +
      H011_FIXTURE_LINES[0, 2].join +
      H011_FIXTURE_LINES[1..].join

    assert_equal expected, result["content"],
      "the generic lines splice must reproduce the incident's duplication " \
      "signature verbatim when the replacement carries preceding text: this " \
      "pins the attribution that the generic layer is a faithful text " \
      "editor, never a silent repairer"
    assert_equal expected, File.read(File.join(@tmpdir, "doc.yaml"))
    assert_equal true, result["changed"]
  end

  def test_h011_generic_lines_edit_intended_replacement_is_byte_exact
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "doc.yaml",
      "content" => H011_FIXTURE
    )

    # The same public operation with the INTENDED replacement: replace the
    # single physical line 1 with its own text (span [1...2] is exactly that
    # line).  Byte-identical document, every unselected line untouched.
    result = @agent.path_edit(
      "kind" => "text",
      "path" => "doc.yaml",
      "selector" => {"type" => "lines", "start" => 1, "end" => 2},
      "replacement" => H011_FIXTURE_LINES[1]
    )

    assert_equal H011_FIXTURE, result["content"],
      "replacing line 1 with its own text must leave the document " \
      "byte-identical, including the folded single-quoted scalar"
    assert_equal H011_FIXTURE, File.read(File.join(@tmpdir, "doc.yaml"))
    assert_equal false, result["changed"]
  end

  # Minimal mirror of the Research records.rb `:full` edit override
  # (records.rb L345-L353 registration, L448-L522 transform, quoted verbatim
  # in the bout report): the override receives the resolved authorized
  # target, re-applies the caller's selector/replacement through
  # agent.path_apply_selector, re-parses the candidate, and - decisive for
  # the incident - RE-SERIALIZES AND COMMITS whatever still parses.  A :full
  # override must return a Hash payload (engine contract, edit.rb DC-2).
  #
  # The fixture is a serializer-format record whose `statement` is a
  # multi-line folded scalar - the shape whose physical-line edits can
  # duplicate folded content (the incident's single-quoted folded scalar is
  # covered by the Research-side regression, which drives the real kind).
  H011_RECORD = {
    "version" => 1,
    "statement" =>
      "The initial interpretation remains provisional because the shared " \
      "response is also present in the control. The final qualification " \
      "must remain intact.",
    "scope" => {"population" => "cohort A"},
    "status" => "proposed",
    "limitations" => ["No biological replicates"]
  }.freeze

  def register_h011_full_override_kind
    require "yaml"
    @agent.register_path_kind(
      "recordish",
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"edit" => true},
      "overrides" => {
        "edit" => {
          "type" => :full,
          "implementation" => lambda { |agent, target, args|
            current_text = File.read(target.to_s)
            candidate_text =
              agent.path_apply_selector(current_text,
                                        args["selector"], args["replacement"])
            candidate = YAML.safe_load(candidate_text,
                                       permitted_classes: [], aliases: false)
            return {"changed" => false} if candidate_text == current_text

            candidate["version"] += 1
            File.write(target.to_s, YAML.dump(candidate))
            {"changed" => true, "version" => candidate["version"]}
          }
        }
      }
    )
  end

  def h011_write_record(name)
    require "yaml"
    @agent.path_write(
      "kind" => "recordish",
      "path" => name,
      "content" => YAML.dump(H011_RECORD)
    )
    File.join(@tmpdir, name)
  end

  def h011_statement_line_index(path)
    File.readlines(path).index { |line| line.start_with?("statement:") }
  end

  def test_h011_full_override_commits_duplicated_folded_scalar_verbatim
    register_h011_full_override_kind
    record = h011_write_record("H-001.yaml")
    stmt_idx = h011_statement_line_index(record)
    body_lines = File.readlines(record)

    # The corruption-shaped edit the incident agent performed: replace the
    # statement VALUE line with the statement line plus its own continuation
    # line verbatim (re-pasting what it had just read).  The override
    # re-parses the candidate - and Psych folds the duplicated fragments
    # into ONE statement value with the text concatenated - so the record
    # layer commits the corruption and bumps the version.  This pins, at
    # engine level, the mechanism that let H-011 v5-v12 duplication persist
    # through record validation: the engine hands the override the caller's
    # selector/replacement verbatim, and the override's own validation is
    # the only gate.  The REJECTING regression lives in the Research checkout
    # (test/Research/path_kinds/test_h011_lines_edit.rb).
    # ScoutCoder: under a :full edit override the engine hands the override
    # the caller's selector/replacement VERBATIM (path_apply_selector inside
    # the handler) and the override's own validation is the ONLY gate - a
    # corruption-shaped `lines` edit that still YAML-parses is committed and
    # version-bumped, because Psych folds duplicated folded-scalar fragments
    # into one value.  Kinds owning :full edit overrides must reject, never
    # repair or commit, corruption-shaped candidates.
    result = @agent.path_edit(
      "kind" => "recordish",
      "path" => "H-001.yaml",
      "selector" => {"type" => "lines", "start" => stmt_idx, "end" => stmt_idx + 1},
      "replacement" => body_lines[stmt_idx, 2].join
    )

    parsed = YAML.safe_load(File.read(record), permitted_classes: [], aliases: false)
    assert_equal "The initial interpretation remains provisional because the " \
                 "shared response is also present in the control. The final " \
                 "qualification must remain intact. is also present in the " \
                 "control. The final qualification must remain intact.",
                 parsed["statement"],
      "the override-mediated edit must commit the duplication signature " \
      "verbatim (duplicated folded text concatenated into one value)"
    assert_equal 2, parsed["version"]
    assert_equal true, result["changed"]
  end

  def test_h011_full_override_intended_edit_preserves_scalar_value
    register_h011_full_override_kind
    record = h011_write_record("H-002.yaml")
    stmt_idx = h011_statement_line_index(record)

    # The INTENDED edit: replace the statement VALUE line with its own text.
    # The scalar VALUE must survive the parse/serialize round trip untouched
    # and the edit must be reported as a no-op.
    result = @agent.path_edit(
      "kind" => "recordish",
      "path" => "H-002.yaml",
      "selector" => {"type" => "lines", "start" => stmt_idx, "end" => stmt_idx + 1},
      "replacement" => File.readlines(record)[stmt_idx]
    )

    parsed = YAML.safe_load(File.read(record), permitted_classes: [], aliases: false)
    assert_equal H011_RECORD["statement"], parsed["statement"],
      "the intended edit must leave the folded scalar VALUE byte-identical " \
      "after the override's parse/serialize round trip"
    assert_equal false, result["changed"]
  end


end
