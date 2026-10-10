require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require "tmpdir"

class TestClass < Test::Unit::TestCase
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

  def test_plugin_loading_installs_tools_on_llm_agent
    agent = LLM::Agent.new
    plugin = File.join(@tmpdir, "path_plugin.rb")
    FileUtils.mkdir_p(File.dirname(plugin))
    File.write(plugin, <<~RUBY)
      register_path_kind :plugin_text,
        "description" => "Plugin text paths",
        "locations" => ["project"],
        "roots" => {"project" => #{@tmpdir.inspect}}
    RUBY

    agent.load_path_plugins(plugin)

    tools = agent.other_options[:tools]
    assert tools.key?("path_kinds")
    assert tools.key?("path_read")
    callable, definition = tools.fetch("path_kinds")
    assert_equal "plugin_text", callable.call("path_kinds", {}).keys.first
    assert_equal "path_kinds", definition.dig(:function, :name)
  end

  def test_register_path_kind
    definition = register_text_kind

    assert_equal "text", definition["name"]
    assert_equal "Test text paths", definition["description"]
    assert_equal ["project", "tmp"], definition["locations"]
    assert_equal "project", definition["default_location"]

    assert_equal true, definition["capabilities"]["read"]
    assert_equal true, definition["capabilities"]["write"]
    assert_equal true, definition["capabilities"]["edit"]
    assert_equal true, definition["capabilities"]["list"]
    assert_equal true, definition["capabilities"]["move"]
    assert_equal true, definition["capabilities"]["rename"]
    assert_equal true, definition["capabilities"]["delete"]
    assert_equal false, definition["capabilities"]["validate"]
    assert_equal false, definition["capabilities"]["test"]
    assert_equal false, definition["capabilities"]["promote"]
  end

  def test_register_path_kind_rejects_empty_name
    assert_raise(ParameterException) do
      @agent.register_path_kind("")
    end
  end

  def test_sandbox_defaults_on_and_can_be_disabled
    assert_equal true, register_text_kind["sandbox"]
    assert_equal false, @agent.register_path_kind(
      "unsandboxed", "sandbox" => false, "locations" => ["project"],
      "roots" => {"project" => @tmpdir}
    )["sandbox"]
  end

  def test_register_path_kind_rejects_non_boolean_sandbox_setting
    assert_raise(ParameterException) do
      @agent.register_path_kind("invalid", "sandbox" => "false")
    end
  end

  def test_sandbox_denies_custom_operation_before_callback
    called = false
    outside = Dir.mktmpdir("path-outside")
    @agent.register_path_kind(
      "custom", "locations" => ["tmp"], "default_location" => "tmp",
      "roots" => {"tmp" => @tmpdir}, "capabilities" => {"validate" => true},
      "resolve" => ->(_agent, _path, _location) { outside },
      "validate" => ->(*) { called = true }
    )

    assert_raise(ParameterException) do
      @agent.path_validate("kind" => "custom", "path" => "item")
    end
    assert_false called
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_sandbox_disabled_skips_authorization
    @agent.register_path_kind(
      "custom", "sandbox" => false, "locations" => ["tmp"],
      "default_location" => "tmp", "roots" => {"tmp" => @tmpdir},
      "resolve" => ->(_agent, _path, _location) { File.join(@tmpdir, "item") }
    )
    assert_equal true, @agent.path_write("kind" => "custom", "path" => "item",
                                        "content" => "ok")["written"]
  end

  def test_sandbox_fails_closed_when_authorizer_is_unavailable
    register_text_kind
    sandbox = LLM::Sandbox
    original = sandbox.method(:authorize_path)
    sandbox.define_singleton_method(:authorize_path) { |*| raise NoMethodError, "unavailable" }

    assert_raise(ParameterException) do
      @agent.path_read("kind" => "text", "path" => "item")
    end
  ensure
    sandbox.define_singleton_method(:authorize_path, original) if sandbox && original
  end

  def test_move_authorizes_source_and_missing_destination
    register_text_kind
    calls = []
    sandbox = LLM::Sandbox
    original = sandbox.method(:authorize_path)
    sandbox.define_singleton_method(:authorize_path) do |path, **options|
      calls << [path, options[:mode]]
      original.call(path, **options)
    end
    @agent.path_write("kind" => "text", "path" => "source", "content" => "x")
    calls.clear

    @agent.path_move("kind" => "text", "path" => "source", "destination" => "new/target")

    assert_equal [[File.join(@tmpdir, "source"), :write],
                  [File.join(@tmpdir, "new/target"), :write]], calls
    assert File.file?(File.join(@tmpdir, "new/target"))
  ensure
    sandbox.define_singleton_method(:authorize_path, original) if sandbox && original
  end

  def test_move_denies_symlinked_destination_outside_root
    register_text_kind
    outside = Dir.mktmpdir("path-outside")
    FileUtils.mkdir_p(@tmpdir.to_s)
    File.symlink(outside, File.join(@tmpdir, "escape"))
    @agent.path_write("kind" => "text", "path" => "source", "content" => "x")

    assert_raise(ParameterException) do
      @agent.path_move("kind" => "text", "path" => "source", "destination" => "escape/new")
    end
    assert File.file?(File.join(@tmpdir, "source"))
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_register_path_kind_rejects_invalid_default_location
    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "text",
        "locations" => ["project"],
        "default_location" => "tmp"
      )
    end
  end

  def test_registering_multiple_kinds_in_sequence
    {
      "text" => {
        "locations" => ["project"],
        "roots" => {"project" => @tmpdir}
      },
      "other" => {
        "locations" => ["project"],
        "roots" => {"project" => @tmpdir}
      }
    }.each do |name, definition|
      @agent.register_path_kind(name, definition)
    end

    assert @agent.path_kinds.key?("text")
    assert @agent.path_kinds.key?("other")
  end

  def test_path_kind_definition
    register_text_kind

    definition = @agent.path_kind_definition("text")

    assert_equal "text", definition["name"]
  end

  def test_path_kind_definition_rejects_unknown_kind
    assert_raise(ParameterException) do
      @agent.path_kind_definition("missing")
    end
  end

  def test_path_kind_capable
    register_text_kind(
      "text",
      "validate" => true,
      "test" => true,
      "promote" => true
    )

    assert @agent.path_kind_capable?("text", "read")
    assert @agent.path_kind_capable?("text", "write")
    assert @agent.path_kind_capable?("text", "validate")
    assert @agent.path_kind_capable?("text", "test")
    assert @agent.path_kind_capable?("text", "promote")
  end

  def test_path_doc_id
    assert_equal "view::show.slim", @agent.path_doc_id("view", "show.slim")
    assert_equal "view::show.slim@3", @agent.path_doc_id("view", "show.slim", 3)
  end

  def test_resolve_path
    register_text_kind

    target = @agent.resolve_path("text", "hello.txt")

    assert_equal File.join(@tmpdir, "hello.txt"), target
  end

  def test_resolve_path_with_location
    register_text_kind

    target = @agent.resolve_path("text", "hello.txt", "tmp")

    assert_equal File.join(@tmpdir, "tmp", "hello.txt"), target
  end

  def test_resolve_path_rejects_invalid_location
    register_text_kind

    assert_raise(ParameterException) do
      @agent.resolve_path("text", "hello.txt", "missing")
    end
  end

  def test_path_write_and_read
    register_text_kind

    result = @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello world"
    )

    assert_equal true, result["written"]
    assert_equal "text::hello.txt", result["doc_id"]

    assert_equal(
      "hello world",
      @agent.path_read(
        "kind" => "text",
        "path" => "hello.txt"
      )["content"]
    )
  end

  def test_absolute_path_write_and_read_use_exact_target
    register_text_kind
    target = File.join(@tmpdir, "absolute/location.txt")

    result = @agent.path_write(
      "kind" => "text",
      "path" => target,
      "content" => "at the exact absolute target"
    )

    assert_equal true, result["written"]
    assert File.file?(target)
    assert_equal "at the exact absolute target", File.read(target)
    assert_equal "at the exact absolute target",
                 @agent.path_read("kind" => "text", "path" => target)["content"]
    assert_false File.exist?(File.join(@tmpdir, target))
  end

  def test_absolute_path_outside_configured_root_is_denied_without_side_effect
    register_text_kind
    outside = Dir.mktmpdir("path-outside")
    target = File.join(outside, "must-not-exist.txt")

    error = assert_raise(ParameterException) do
      @agent.path_write("kind" => "text", "path" => target, "content" => "denied")
    end

    assert_equal "Path access denied by sandbox (outside_grants)", error.message
    assert_false File.exist?(target)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_absolute_path_list_and_move_use_exact_endpoints
    register_text_kind
    subdir = File.join(@tmpdir, "listed")
    FileUtils.mkdir_p(subdir)
    source = File.join(subdir, "absolute-source.txt")
    destination = File.join(subdir, "absolute-destination.txt")
    @agent.path_write("kind" => "text", "path" => source, "content" => "move me")

    assert_equal ["listed/absolute-source.txt"],
                 @agent.path_list("kind" => "text", "path" => subdir)
    @agent.path_write("kind" => "text", "path" => File.join(@tmpdir, "sibling.txt"),
                       "content" => "not in the requested directory")
    result = @agent.path_move("kind" => "text", "path" => source,
                             "destination" => destination)

    assert_equal true, result["moved"]
    assert_false File.exist?(source)
    assert_equal "move me", File.read(destination)

    outside = Dir.mktmpdir("path-outside")
    denied_destination = File.join(outside, "must-not-exist.txt")
    @agent.path_write("kind" => "text", "path" => source, "content" => "stay put")
    error = assert_raise(ParameterException) do
      @agent.path_move("kind" => "text", "path" => source,
                       "destination" => denied_destination)
    end
    assert_equal "Path access denied by sandbox (outside_grants)", error.message
    assert_equal "stay put", File.read(source)
    assert_false File.exist?(denied_destination)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_path_write_success_is_at_the_authorized_target
    register_text_kind
    target = File.join(@tmpdir, "actual/location.txt")

    result = @agent.path_write(
      "kind" => "text",
      "path" => "actual/location.txt",
      "content" => "written at the authorized target"
    )

    assert_equal true, result["written"]
    assert File.file?(target)
    assert_equal "written at the authorized target", File.read(target)
  end

  def test_path_write_denies_resolver_target_outside_root
    outside = Dir.mktmpdir("path-outside")
    outside_target = File.join(outside, "must-not-exist.txt")
    @agent.register_path_kind(
      "custom", "locations" => ["project"], "default_location" => "project",
      "roots" => {"project" => @tmpdir},
      "resolve" => ->(_agent, _path, _location) { outside_target }
    )

    error = assert_raise(ParameterException) do
      @agent.path_write("kind" => "custom", "path" => "item", "content" => "denied")
    end

    assert_equal "Path access denied by sandbox (outside_grants)", error.message
    assert_false File.exist?(outside_target)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_path_write_creates_parent_directories
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "nested/hello.txt",
      "content" => "hello"
    )

    assert File.file?(File.join(@tmpdir, "nested/hello.txt"))
  end

  def test_path_write_filesystem_failure_does_not_return_success
    register_text_kind
    # The authorized target exists as a directory, so the filesystem rejects
    # File.write. This exercises the real write failure path without stubbing.
    assert_raise(Errno::EISDIR) do
      @agent.path_write("kind" => "text", "path" => ".", "content" => "cannot replace directory")
    end
  end

  def test_path_write_respects_write_capability
    register_text_kind("text", "write" => false)

    assert_raise(ParameterException) do
      @agent.path_write(
        "kind" => "text",
        "path" => "hello.txt",
        "content" => "hello"
      )
    end
  end

  def test_path_read_rejects_missing_path
    register_text_kind

    assert_raise(ParameterException) do
      @agent.path_read(
        "kind" => "text",
        "path" => "missing.txt"
      )
    end
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

  def test_path_list
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "one.txt",
      "content" => "one"
    )
    @agent.path_write(
      "kind" => "text",
      "path" => "nested/two.txt",
      "content" => "two"
    )

    result = @agent.path_list("kind" => "text")

    assert_equal ["nested/two.txt", "one.txt"], result
  end

  def test_path_list_with_prefix
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "nested/one.txt",
      "content" => "one"
    )
    @agent.path_write(
      "kind" => "text",
      "path" => "nested/two.txt",
      "content" => "two"
    )
    @agent.path_write(
      "kind" => "text",
      "path" => "other.txt",
      "content" => "other"
    )

    result = @agent.path_list(
      "kind" => "text",
      "path" => "nested"
    )

    assert_equal ["nested/one.txt", "nested/two.txt"], result
  end

  def test_path_move
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "one.txt",
      "content" => "hello"
    )

    result = @agent.path_move(
      "kind" => "text",
      "path" => "one.txt",
      "destination" => "two.txt"
    )

    assert_equal true, result["moved"]
    assert !File.exist?(File.join(@tmpdir, "one.txt"))
    assert_equal "hello", File.read(File.join(@tmpdir, "two.txt"))
  end

  def test_path_rename
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "one.txt",
      "content" => "hello"
    )

    result = @agent.path_rename(
      "kind" => "text",
      "path" => "one.txt",
      "name" => "two.txt"
    )

    assert_equal true, result["renamed"]
    assert !File.exist?(File.join(@tmpdir, "one.txt"))
    assert_equal "hello", File.read(File.join(@tmpdir, "two.txt"))
  end

  def test_path_rename_checks_rename_capability_independently
    @agent.register_path_kind(
      "text",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"move" => false, "rename" => true}
    )
    @agent.path_write(
      "kind" => "text",
      "path" => "one.txt",
      "content" => "hello"
    )

    result = @agent.path_rename(
      "kind" => "text",
      "path" => "one.txt",
      "name" => "two.txt"
    )

    assert_equal true, result["renamed"]
    assert !File.exist?(File.join(@tmpdir, "one.txt"))
    assert_equal "hello", File.read(File.join(@tmpdir, "two.txt"))
  end

  def test_path_rename_rejects_missing_rename_capability_even_when_move_is_supported
    register_text_kind("text", "rename" => false, "move" => true)

    assert_raise(ParameterException) do
      @agent.path_rename(
        "kind" => "text",
        "path" => "one.txt",
        "name" => "two.txt"
      )
    end
  end

  def test_path_delete
    register_text_kind

    @agent.path_write(
      "kind" => "text",
      "path" => "hello.txt",
      "content" => "hello"
    )

    result = @agent.path_delete(
      "kind" => "text",
      "path" => "hello.txt"
    )

    assert_equal true, result["deleted"]
    assert !File.exist?(File.join(@tmpdir, "hello.txt"))
  end

  # Review point 4 (Phase 0 fixes): deleting a nonexistent target is invalid
  # input and must surface as ParameterException using the engine's uniform
  # "does not exist" contract, not as a raw Errno::ENOENT escaping the tool
  # callable's ScoutException-only rescue.
  def test_custom_operation_registration_stores_normalized_spec
    register_text_kind

    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Precise edit",
          "parameters" => {"properties" => {"selector" => {"type" => "string"}}, "required" => ["selector"]},
          "implementation" => ->(_agent, _target, _args) { "ok" },
          "authorization" => :read,
          "type" => :content
        }
      }
    )

    spec = @agent.path_kind_definition("fancy")["operations"]["precise_edit"]
    assert_equal "precise_edit", spec["name"]
    assert_equal "Precise edit", spec["description"]
    assert_equal ["selector"], spec["parameters"]["required"]
    assert_equal :read, spec["authorization"]
    assert_equal :content, spec["type"]
    assert spec["implementation"].respond_to?(:call)

    assert_equal ["precise_edit"],
                 @agent.path_kind_registry.values
                        .flat_map { |d| d.fetch("operations", {}).keys }.uniq.sort
    assert @agent.path_operation_support?("fancy", "precise_edit")
    assert_equal :read,
                 @agent.path_kind_definition("fancy")["operation_table"]["precise_edit"]["authorization"]
    assert !@agent.path_operation_support?("text", "precise_edit")
  end

  def test_custom_operation_defaults_fail_closed_to_write_and_full_handler
    register_text_kind

    @agent.register_path_kind(
      "plain",
      "roots" => {"project" => @tmpdir},
      "operations" => {"noop" => ->(_a, _t, _args) { "ok" }}
    )

    spec = @agent.path_kind_definition("plain")["operations"]["noop"]
    assert_equal :write, spec["authorization"]
    assert_equal :full, spec["type"]
    assert_equal :write,
                 @agent.path_kind_definition("plain")["operation_table"]["noop"]["authorization"]
  end

  # ------------------------------------------------------------------
  # Step 4 — tool aggregation
  # ------------------------------------------------------------------

  def register_two_kinds_with_same_operation(first_description: "First kind operation", second_description: nil)
    @agent.register_path_kind(
      "alpha",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => first_description,
          "parameters" => {
            "properties" => {
              "selector" => {"type" => "object"},
              "replacement" => {"type" => "string"}
            },
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { "alpha:#{content}" },
          "authorization" => :write,
          "type" => :content
        }
      }
    )
    return if second_description.nil?

    @agent.register_path_kind(
      "beta",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => second_description,
          "parameters" => {
            "properties" => {
              "selector" => {"type" => "object"},
              "replacement" => {"type" => "string"}
            },
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { "beta:#{content}" },
          "authorization" => :write,
          "type" => :content
        }
      }
    )
  end

  def step4_tools
    @agent.instance_variable_get(:@other_options)[:tools]
  end

  def test_two_kinds_with_same_operation_install_exactly_one_shared_tool
    register_two_kinds_with_same_operation(
      first_description: "Alpha precise edit",
      second_description: "Beta precise edit"
    )

    tools = step4_tools
    assert tools.key?("precise_edit")
    assert_equal 1, tools.keys.count("precise_edit")

    schema = tools["precise_edit"][1][:function][:parameters]
    assert_equal %w[alpha beta], schema[:properties]["kind"]["enum"].sort
    assert_equal ["kind", "path", "replacement"].sort, schema[:required].sort
  end

  def test_conflicting_contracts_are_rejected_at_installation
    @agent.register_path_kind(
      "alpha",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Alpha precise edit",
          "parameters" => {
            "properties" => {"replacement" => {"type" => "string"}},
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { content }
        }
      }
    )

    # type mismatch on the same parameter
    error = assert_raise(ParameterException) do
      @agent.register_path_kind(
        "beta",
        "roots" => {"project" => @tmpdir},
        "operations" => {
          "precise_edit" => {
            "description" => "Beta precise edit",
            "parameters" => {
              "properties" => {"replacement" => {"type" => "integer"}},
              "required" => ["replacement"]
            },
            "implementation" => ->(content, args) { content }
          }
        }
      )
    end
    assert error.message.include?("precise_edit")
    assert error.message.include?("alpha")
    assert error.message.include?("beta")
    assert error.message.include?("replacement")

    # required-set mismatch
    error2 = assert_raise(ParameterException) do
      @agent.register_path_kind(
        "gamma",
        "roots" => {"project" => @tmpdir},
        "operations" => {
          "precise_edit" => {
            "description" => "Gamma precise edit",
            "parameters" => {
              "properties" => {"replacement" => {"type" => "string"}},
              "required" => []
            },
            "implementation" => ->(content, args) { content }
          }
        }
      )
    end
    assert error2.message.include?("required")
  end

  def test_failed_kind_registration_rolls_back_registry_and_tool_surface_recovers
    @agent.register_path_kind(
      "alpha",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Alpha precise edit",
          "parameters" => {
            "properties" => {"replacement" => {"type" => "string"}},
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { content }
        }
      }
    )

    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "beta",
        "roots" => {"project" => @tmpdir},
        "operations" => {
          "precise_edit" => {
            "description" => "Beta precise edit",
            "parameters" => {
              "properties" => {"replacement" => {"type" => "integer"}},
              "required" => ["replacement"]
            },
            "implementation" => ->(content, args) { content }
          }
        }
      )
    end

    # Atomic rollback: the failed kind leaves no partial registration behind
    assert_equal %w[alpha], @agent.path_kind_registry.keys

    # The next successful registration re-syncs the aggregated tool surface
    @agent.register_path_kind("gamma", "roots" => {"project" => @tmpdir})
    assert_equal %w[alpha gamma], @agent.path_kind_registry.keys.sort

    enum = step4_tools["path_kinds"][1][:function][:parameters][:properties]["kind"][:enum]
    assert_equal %w[alpha gamma], enum.sort
  end

  def test_description_resolves_by_registration_order
    register_two_kinds_with_same_operation(
      first_description: "Alpha precise edit",
      second_description: "Beta precise edit"
    )
    tools = step4_tools
    assert tools["precise_edit"][1][:function][:description].include?("Beta precise edit")

    # deterministic: swap the registration order in a fresh agent and the
    # other description wins.
    other = LLM.agent
    other.register_path_kind(
      "zeta",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Zeta precise edit",
          "parameters" => {
            "properties" => {"replacement" => {"type" => "string"}},
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { content }
        }
      }
    )
    other.register_path_kind(
      "alpha",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "precise_edit" => {
          "description" => "Alpha precise edit",
          "parameters" => {
            "properties" => {"replacement" => {"type" => "string"}},
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { content }
        }
      }
    )
    other_tools = other.instance_variable_get(:@other_options)[:tools]
    assert other_tools["precise_edit"][1][:function][:description].include?("Alpha precise edit")
  end

  def test_aggregated_tool_fails_cleanly_for_unsupported_kind
    register_two_kinds_with_same_operation(first_description: "Alpha precise edit")

    tools = step4_tools
    result = tools["precise_edit"][0].call(
      "precise_edit",
      {"kind" => "text", "path" => "a.txt", "replacement" => "x"}
    )
    payload = JSON.parse(result)
    assert payload["exception"].include?("Unknown Path kind")
  end

  def test_custom_tool_visible_immediately_and_not_dropped_by_later_registration
    register_two_kinds_with_same_operation(first_description: "Alpha precise edit")

    tools = step4_tools
    assert tools.key?("precise_edit")
    assert tools.key?("path_read")

    @agent.register_path_kind(
      "extra",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "other_op" => {
          "description" => "Other",
          "parameters" => {"properties" => {}, "required" => []},
          "implementation" => ->(content, args) { content }
        }
      }
    )

    tools = step4_tools
    assert tools.key?("precise_edit")
    assert tools.key?("other_op")
    assert tools.key?("path_read")
  end

  def test_builtin_schemas_unchanged_by_custom_registration
    before = {}
    @agent.register_path_kind("text", "roots" => {"project" => @tmpdir})
    @agent.install_path_tools
    step4_tools.each do |name, pair|
      before[name] = pair[1][:function]
    end

    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "overrides" => {"edit" => ->(a, t, args) { "overridden" }},
      "operations" => {
        "precise_edit" => {
          "description" => "Fancy precise edit",
          "parameters" => {
            "properties" => {"replacement" => {"type" => "string"}},
            "required" => ["replacement"]
          },
          "implementation" => ->(content, args) { content }
        }
      }
    )

    after = {}
    step4_tools.each do |name, pair|
      after[name] = pair[1][:function]
    end

    %w[path_kinds path_read path_write path_edit path_list path_move path_rename path_delete path_validate path_test path_promote path_smoke].each do |builtin|
      next unless before.key?(builtin)
      assert_equal before[builtin][:name], after[builtin][:name], builtin
      assert_equal before[builtin][:description], after[builtin][:description], builtin
      assert_equal before[builtin][:parameters].reject { |k, _| k == :properties },
                   after[builtin][:parameters].reject { |k, _| k == :properties },
                   builtin
      before_props = before[builtin][:parameters][:properties].dup
      after_props = after[builtin][:parameters][:properties].dup
      # kind property enum legitimately grows with new kinds; compare the rest.
      assert_equal before_props["kind"]["type"], after_props["kind"]["type"]
      before_props.delete("kind")
      after_props.delete("kind")
      assert_equal before_props, after_props, builtin
    end
  end

  def test_builtin_tools_still_call_engine_methods_directly
    register_text_kind
    @agent.path_write("kind" => "text", "path" => "hello.txt", "content" => "hello")

    tools = step4_tools
    result = tools["path_read"][0].call("path_read", {"kind" => "text", "path" => "hello.txt"})
    assert_equal "hello", result["content"]
  end


  # ------------------------------------------------------------------
  # Step 5: centralized dispatch with authorization
  # ------------------------------------------------------------------

  def step5_spy(calls)
    ->(*args) { calls << args; "SPY" }
  end

  def register_fancy_with_operation(operation_name, spec_extra = {}, &)
    spec = {
      "parameters" => {"properties" => {}, "required" => []},
      "implementation" => ->(content, args) { content }
    }.merge(spec_extra)
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "operations" => {operation_name => spec}
    )
  end

  def test_dispatch_custom_content_operation_reads_transforms_and_writes
    register_text_kind
    register_fancy_with_operation(
      "precise_edit",
      "implementation" => ->(content, args) { content + args.fetch("marker", "!") },
      "type" => :content
    )
    @agent.path_write("kind" => "fancy", "path" => "a.txt", "content" => "hello")

    result = @agent.path_dispatch(
      kind: "fancy", operation: "precise_edit",
      "path" => "a.txt", "marker" => "!!"
    )

    assert_equal "hello!!", result["content"]
    assert_equal "hello!!", File.read(File.join(@tmpdir, "a.txt"))
    assert_equal true, result["changed"]
  end

  def test_dispatch_custom_full_operation_receives_agent_and_target
    register_text_kind
    seen = []
    register_fancy_with_operation(
      "audit",
      "implementation" => ->(agent, target, args) {
        seen << [agent.class, target.to_s, args["path"]]
        "AUDIT #{File.basename(target.to_s)}"
      },
      "type" => :full
    )

    result = @agent.path_dispatch(
      kind: "fancy", operation: "audit", "path" => "x.txt"
    )

    assert_equal "AUDIT x.txt", result
    assert_equal 1, seen.length
    assert_equal LLM::Agent, seen.first.first
  end

  def test_dispatch_unsupported_kind_and_operation_fail_cleanly
    register_text_kind

    assert_raise(ParameterException) do
      @agent.path_dispatch(kind: "nope", operation: "read", "path" => "a")
    end

    assert_raise(ParameterException) do
      @agent.path_dispatch(kind: "text", operation: "smoke", "path" => "a")
    end

    # no cross-kind fallback: "precise_edit" on fancy is not reachable
    # through kind "text"
    register_fancy_with_operation("precise_edit")
    assert_raise(ParameterException) do
      @agent.path_dispatch(kind: "text", operation: "precise_edit", "path" => "a")
    end
  end

  def test_dispatch_authorization_failure_runs_no_callback_and_mutates_nothing
    register_text_kind
    calls = []
    register_fancy_with_operation(
      "rewrite",
      "implementation" => step5_spy(calls),
      "type" => :full
    )
    outside = File.join(Dir.tmpdir, "step5_outside_#{Process.pid}.txt")
    File.write(outside, "KEEP")

    assert_raise(ParameterException) do
      @agent.path_dispatch(
        kind: "fancy", operation: "rewrite",
        "path" => "../#{File.basename(outside)}"
      )
    end

    assert_empty calls
    assert_equal "KEEP", File.read(outside)
  ensure
    File.delete(outside) if outside && File.exist?(outside)
  end

  def test_dispatch_content_op_outside_sandbox_invokes_no_callback
    register_text_kind
    calls = []
    register_fancy_with_operation(
      "rewrite",
      "implementation" => step5_spy(calls),
      "type" => :content
    )

    assert_raise(ParameterException) do
      @agent.path_dispatch(
        kind: "fancy", operation: "rewrite",
        "path" => "../../etc/hostname"
      )
    end

    assert_empty calls
  end

  def test_dispatch_edit_override_authorization_failure_runs_no_override
    register_text_kind
    calls = []
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "overrides" => {"edit" => step5_spy(calls)}
    )
    @agent.path_write("kind" => "fancy", "path" => "keep.txt", "content" => "KEEP")
    before = File.read(File.join(@tmpdir, "keep.txt"))

    assert_raise(ParameterException) do
      @agent.path_edit(
        "kind" => "fancy",
        "path" => "../../etc/hostname",
        "selector" => {"type" => "lines", "start" => 1},
        "replacement" => "x"
      )
    end

    assert_empty calls
    assert_equal before, File.read(File.join(@tmpdir, "keep.txt"))
  end

  def test_dispatch_content_op_cannot_redirect_write_to_other_file
    register_text_kind
    register_fancy_with_operation(
      "stubborn_edit",
      "implementation" => ->(content, args) { "smuggled" },
      "type" => :content
    )
    @agent.path_write("kind" => "fancy", "path" => "one.txt", "content" => "original")

    @agent.path_dispatch(
      kind: "fancy", operation: "stubborn_edit", "path" => "one.txt"
    )

    assert_equal "smuggled", File.read(File.join(@tmpdir, "one.txt"))
    files = Dir.glob(File.join(@tmpdir, "**", "*")).select { |f| File.file?(f) }
    assert_equal ["#{File.join(@tmpdir.to_s, 'one.txt')}"], files.sort.map { |f| f }
  end

  def test_dispatch_edit_content_override_preserves_final_newline
    register_text_kind
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "overrides" => {
        # replaces the final line wherever it is; deliberately returns a
        # value with a trailing newline to prove engine-side preservation
        "edit" => ->(content, args) {
          content.sub(/b\n?\z/, "x\n")
        }
      }
    )

    @agent.path_write("kind" => "fancy", "path" => "plain.txt", "content" => "a\nb")
    @agent.path_edit(
      "kind" => "fancy", "path" => "plain.txt",
      "selector" => {"type" => "lines", "start" => 2},
      "replacement" => "x"
    )
    assert_equal "a\nx", File.read(File.join(@tmpdir, "plain.txt"))

    @agent.path_write("kind" => "fancy", "path" => "term.txt", "content" => "a\nb\n")
    @agent.path_edit(
      "kind" => "fancy", "path" => "term.txt",
      "selector" => {"type" => "lines", "start" => 2},
      "replacement" => "x"
    )
    # terminated original keeps its final newline even though the override
    # return value itself ends in one
    assert_equal "a\nx\n", File.read(File.join(@tmpdir, "term.txt"))
  end

  def test_dispatch_custom_op_authorization_modes
    register_text_kind
    write_calls = []
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "operations" => {
        "no_mode" => {
          "parameters" => {"properties" => {}, "required" => []},
          "implementation" => step5_spy(write_calls),
          "type" => :full
        },
        "read_mode" => {
          "parameters" => {"properties" => {}, "required" => []},
          "implementation" => step5_spy(write_calls),
          "authorization" => :read,
          "type" => :full
        }
      }
    )

    table = @agent.path_kind_definition("fancy")["operation_table"]
    assert_equal :write, table["no_mode"]["authorization"]
    assert_equal :read, table["read_mode"]["authorization"]

    @agent.path_write("kind" => "fancy", "path" => "ro.txt", "content" => "ok")
    result = @agent.path_dispatch(
      kind: "fancy", operation: "read_mode", "path" => "ro.txt"
    )
    assert_equal "SPY", result
  end

  def test_dispatch_builtin_without_override_uses_engine_default
    register_text_kind
    @agent.path_write("kind" => "text", "path" => "one.txt", "content" => "x")

    result = @agent.path_dispatch(
      kind: "text", operation: "read", "path" => "one.txt"
    )
    assert_equal "x", result["content"]
  end
  def test_override_does_not_resurrect_capability_disabled_builtin
    # The "kind" tool is agent-global and the capability gate lives inside the
    # engine method, so an override can never re-enable edit for a kind that
    # has the edit capability off. The direct engine call must still refuse.
    register_text_kind("locked", "edit" => false)
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"edit" => false},
      "overrides" => {
        "edit" => ->(agent, target, args) { "OVERRIDDEN" }
      }
    )

    assert_equal false, @agent.path_kind_capable?("fancy", "edit")

    exception = assert_raise(ParameterException) do
      @agent.path_edit(
        "kind" => "fancy",
        "path" => "a.txt",
        "selector" => {"type" => "lines", "start" => 1},
        "replacement" => "x"
      )
    end
    assert exception.message.include?("does not support edit")
  end

  def test_custom_operation_parameter_colliding_with_path_arguments_is_rejected
    error = assert_raise(ParameterException) do
      @agent.register_path_kind(
        "alpha",
        "roots" => {"project" => @tmpdir},
        "operations" => {
          "weird_op" => {
            "description" => "Weird",
            "parameters" => {
              "properties" => {"kind" => {"type" => "string"}},
              "required" => []
            },
            "implementation" => ->(content, args) { content }
          }
        }
      )
    end
    assert error.message.include?("weird_op")
    assert error.message.include?("kind")
  end

  def test_custom_operation_name_collision_with_builtin_is_rejected
    register_text_kind

    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "bad",
        "roots" => {"project" => @tmpdir},
        "operations" => {"edit" => ->(_a, _t, _args) { "x" }}
      )
    end

    assert !@agent.path_kind_registry.key?("bad")
  end

  def test_custom_operation_without_callable_is_rejected
    register_text_kind

    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "bad",
        "roots" => {"project" => @tmpdir},
        "operations" => {"noop" => {"implementation" => :not_callable}}
      )
    end
  end

  def test_override_registration_selects_override_implementation
    override_calls = []
    register_text_kind

    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "overrides" => {
        "edit" => ->(_agent, _target, _args) { override_calls << _args; "overridden" }
      }
    )

    assert @agent.path_kind_definition("fancy")["overrides"].key?("edit")
    assert !@agent.path_kind_definition("text").fetch("overrides", {}).key?("edit")
    assert_equal "overridden", @agent.path_operation_implementation("fancy", "edit").call(nil, nil, nil)
    impl = @agent.path_operation_implementation("fancy", "edit")
    assert_same impl, @agent.path_kind_definition("fancy")["overrides"]["edit"]["implementation"]
    assert_equal :write,
                 @agent.path_kind_definition("fancy")["operation_table"]["edit"]["authorization"]
    assert @agent.path_operation_support?("fancy", "edit")
  end

  def test_override_must_target_builtin_and_requires_callable
    register_text_kind

    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "bad",
        "roots" => {"project" => @tmpdir},
        "overrides" => {"precise_edit" => ->(_a, _t, _args) { "x" }}
      )
    end

    assert_raise(ParameterException) do
      @agent.register_path_kind(
        "bad2",
        "roots" => {"project" => @tmpdir},
        "overrides" => {"edit" => :not_callable}
      )
    end
  end

  def test_built_in_capability_queries_follow_defaults
    register_text_kind

    assert @agent.path_operation_support?("text", "read")
    assert @agent.path_operation_support?("text", "write")
    assert @agent.path_operation_support?("text", "edit")
    assert @agent.path_operation_support?("text", "list")
    assert @agent.path_operation_support?("text", "move")
    assert @agent.path_operation_support?("text", "rename")
    assert @agent.path_operation_support?("text", "delete")
    assert !@agent.path_operation_support?("text", "validate")
    assert !@agent.path_operation_support?("text", "test")
    assert !@agent.path_operation_support?("text", "promote")
    assert !@agent.path_operation_support?("text", "smoke")
    assert !@agent.path_operation_support?("text", "precise_edit")
    table = @agent.path_kind_definition("text")["operation_table"]
    assert_equal :read, table["read"]["authorization"]
    assert_equal :read, table["list"]["authorization"]
    assert_equal :write, table["write"]["authorization"]
    assert_equal :write, table["delete"]["authorization"]
    assert_nil table["validate"]
  end

  def test_registry_is_agent_local
    register_text_kind

    other = LLM.agent
    @agent.register_path_kind(
      "fancy",
      "roots" => {"project" => @tmpdir},
      "operations" => {"precise_edit" => ->(_a, _t, _args) { "ok" }}
    )

    assert @agent.path_kind_registry.key?("fancy")
    assert !other.path_kind_registry.key?("fancy")
    assert_equal ["precise_edit"],
                 @agent.path_kind_registry.values
                        .flat_map { |d| d.fetch("operations", {}).keys }.uniq.sort
    assert other.path_kind_registry.values
              .flat_map { |d| d.fetch("operations", {}).keys }.empty?

    assert_raise(ParameterException) do
      other.path_kind_definition("fancy")
    end
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

  def test_path_kinds
    register_text_kind

    result = @agent.path_kinds

    assert result.key?("text")
    assert_equal "Test text paths", result["text"]["description"]
    assert_equal ["project", "tmp"], result["text"]["locations"]
    assert_equal "project", result["text"]["default_location"]
    assert_equal true, result["text"]["capabilities"]["rename"]
  end

  def test_path_kind_specific_operation
    calls = []

    @agent.register_path_kind(
      "text",
      "locations" => ["project"],
      "default_location" => "project",
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"validate" => true},
      "validate" => lambda do |agent, path, location, args|
        calls << [agent, path, location, args]
        {"valid" => true, "path" => path}
      end
    )

    result = @agent.path_validate(
      "kind" => "text",
      "path" => "hello.txt"
    )

    assert_equal true, result["valid"]
    assert_equal "hello.txt", result["path"]
    assert_equal @agent, calls.first[0]
    assert_equal "hello.txt", calls.first[1]
    assert_equal "project", calls.first[2]
  end

  def test_path_kind_specific_operation_requires_capability
    register_text_kind

    assert_raise(ParameterException) do
      @agent.path_validate(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_kind_specific_operation_requires_implementation
    @agent.register_path_kind(
      "text",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"validate" => true}
    )

    assert_raise(ParameterException) do
      @agent.path_validate(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_promote
    tmp_root = File.join(@tmpdir, "promote_tmp")
    project_root = File.join(@tmpdir, "promote_project")
    [tmp_root, project_root].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(tmp_root, "show.slim"), "content h1 Hello\n")

    @agent.register_path_kind(
      "view",
      "locations" => ["tmp", "project"],
      "default_location" => "tmp",
      "roots" => {"tmp" => tmp_root, "project" => project_root},
      "capabilities" => {"promote" => true}
    )

    result = @agent.path_promote(
      "kind" => "view",
      "path" => "show.slim"
    )

    assert_equal true, result["promoted"]
    assert_equal "show.slim", result["path"]
    assert_equal "tmp", result["location"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "content h1 Hello\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_path_promote_requires_capability
    register_text_kind

    assert_raise(ParameterException) do
      @agent.path_promote(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_promote_promotes_without_a_mover_callback
    # Engine-controlled promotion: no "promote" mover callback is required or
    # consulted; the ENGINE performs the move to the authorized destination.
    definition = register_promotable_kind("promote" => nil)
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal true, result["promoted"]
    assert_equal "payload\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_path_promote_legacy_mover_callback_is_not_invoked
    # A legacy "promote" mover callback must NOT be invoked by the engine;
    # the engine is the only writer.  Any callback content must be absent.
    called = false
    definition = register_promotable_kind(
      "promote" => lambda do |_agent, _path, _location, _args|
        called = true
        {"promoted" => true}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert !called
    assert_equal "payload\n",
                 File.read(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_path_promote_callback_redirect_attack_writes_only_at_authorized_destination
    # REDIRECT ATTACK: a kind whose legacy mover callback tries to write
    # somewhere else.  Content must land ONLY at the engine-authorized
    # destination; the redirect target must not be created.
    outside = Dir.mktmpdir("path-outside")
    redirect_target = File.join(outside, "hijacked.txt")
    definition = register_promotable_kind(
      "promote" => lambda do |_agent, _path, _location, args|
        File.write(redirect_target, "hijacked")
        FileUtils.rm(args["promotion_source_target"])
        {"promoted" => true, "destination" => redirect_target}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    source = File.join(tmp_root, "show.slim")
    File.write(source, "legitimate\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    authorized = File.join(project_root, "show.slim")
    assert_equal true, result["promoted"]
    # The engine's authorized endpoint wins over any callback claim.
    assert_equal authorized, result["promotion_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "legitimate\n", File.read(authorized)
    assert !File.exist?(redirect_target)
    assert !File.exist?(source)
    # Nothing else was mutated: only the two authorized endpoints changed.
    assert_equal ["show.slim"], Dir.children(project_root).sort
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_path_promote_post_move_hook_receives_authorized_endpoints
    hook_calls = []
    definition = register_promotable_kind(
      "promotion_post_move" => lambda do |agent, path, location, args|
        hook_calls << [agent, path, location, args]
        {"extra" => "cleanup-done"}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal 1, hook_calls.length
    agent, path, location, args = hook_calls.first
    assert_equal @agent, agent
    assert_equal "show.slim", path
    assert_equal "tmp", location
    assert_equal File.join(definition["roots"]["project"], "show.slim"),
                 args["promotion_target"]
    assert_equal File.join(tmp_root, "show.slim"),
                 args["promotion_source_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 args["promotion_destination"])
    assert_equal false, args["overwrite"]
    # Hook extras merge into the result without overriding engine fields.
    assert_equal "cleanup-done", result["extra"]
    assert_equal true, result["promoted"]
  end

  def test_load_path_plugin
    plugin = File.join(@tmpdir, "plugin.rb")
    FileUtils.mkdir_p(File.dirname(plugin))

    File.write(
      plugin,
      <<~RUBY
        register_path_kind "plugin",
          "locations" => ["project"],
          "roots" => {"project" => #{@tmpdir.inspect}}
      RUBY
    )

    @agent.load_path_plugins(plugin)

    assert @agent.path_kinds.key?("plugin")
    tools = @agent.instance_variable_get(:@other_options)[:tools]
    assert tools.key?("path_kinds")
    assert_equal ["plugin"], tools["path_kinds"][1]["parameters"]["properties"]["kind"]["enum"]
  end

  def test_path_tool_definitions_are_installed
    register_text_kind

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    assert tools.key?("path_kinds")
    assert tools.key?("path_read")
    assert tools.key?("path_write")
    assert tools.key?("path_edit")
    assert tools.key?("path_list")
    assert tools.key?("path_move")
    assert tools.key?("path_rename")
    assert tools.key?("path_delete")

    # These should not be installed until at least one kind supports them.
    assert !tools.key?("path_validate")
    assert !tools.key?("path_test")
    assert !tools.key?("path_smoke")
    assert !tools.key?("path_promote")
  end

  def test_special_tool_definitions_are_installed_when_supported
    @agent.register_path_kind(
      "text",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir},
      "capabilities" => {
        "validate" => true,
        "test" => true,
        "promote" => true
      },
      "validate" => ->(*args) { true },
      "test" => ->(*args) { true },
      "promote" => ->(*args) { true }
    )

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    assert tools.key?("path_validate")
    assert tools.key?("path_test")
    assert tools.key?("path_promote")
  end

  def test_path_tool_definition_contains_registered_kind_enum
    register_text_kind

    definition = @agent.path_tool_definition("read")

    assert_equal ["text"],
                 definition["parameters"]["properties"]["kind"]["enum"]
  end

  def test_path_tool_definition_does_not_add_location_to_list
    register_text_kind

    definition = @agent.path_tool_definition("list")
    properties = definition["parameters"]["properties"]

    assert properties.key?("kind")
    assert properties.key?("path")
    assert !properties.key?("location")
  end

  def test_path_tool_definition_write_contains_content
    register_text_kind

    definition = @agent.path_tool_definition("write")
    properties = definition["parameters"]["properties"]

    assert properties.key?("content")
  end

  def test_path_tool_definition_edit_contains_selector_and_replacement
    register_text_kind

    definition = @agent.path_tool_definition("edit")
    properties = definition["parameters"]["properties"]

    assert properties.key?("selector")
    assert properties.key?("replacement")
  end

  def test_path_tool_definition_move_contains_destination
    register_text_kind

    definition = @agent.path_tool_definition("move")
    properties = definition["parameters"]["properties"]

    assert properties.key?("destination")
  end

  def test_path_tool_definition_rename_contains_name
    register_text_kind

    definition = @agent.path_tool_definition("rename")
    properties = definition["parameters"]["properties"]

    assert properties.key?("name")
  end

  # ------------------------------------------------------------------
  # Error normalization matrix
  #
  # Every expected invalid-input state must surface as the framework's
  # ParameterException, never as an incidental KeyError/ArgumentError
  # raised by an implementation detail.
  # ------------------------------------------------------------------

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

  def register_promotable_kind(overrides = {})
    tmp_root = File.join(@tmpdir, "ptmp")
    project_root = File.join(@tmpdir, "pproject")
    outside_root = File.join(@tmpdir, "poutside")
    [tmp_root, project_root, outside_root].each { |dir| FileUtils.mkdir_p(dir) }

    definition = {
      "locations" => %w[tmp project],
      "default_location" => "tmp",
      "roots" => {"tmp" => tmp_root, "project" => project_root},
      "capabilities" => {"promote" => true},
      "promotion_destination" => {"location" => "project"}
    }.merge(overrides)

    @agent.register_path_kind("view", definition)
    definition
  end

  def test_promotion_moves_content_to_project_location
    definition = register_promotable_kind
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    File.write(File.join(tmp_root, "show.slim"), "content h1 Hello\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal true, result["promoted"]
    assert_equal File.join(project_root, "show.slim"), result["promotion_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "content h1 Hello\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_promotion_denies_source_outside_roots
    definition = register_promotable_kind
    outside = File.join(@tmpdir, "poutside", "rogue.txt")
    File.write(outside, "rogue")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => outside)
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert_equal "rogue", File.read(outside)
    assert !File.exist?(File.join(definition["roots"]["project"], "rogue.txt"))
  end

  def test_promotion_denies_destination_location_without_configured_root
    definition = register_promotable_kind(
      "locations" => %w[tmp elsewhere],
      "promotion_destination" => {"location" => "elsewhere"}
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/No root configured for view at location elsewhere/, error.message)

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(@tmpdir, "elsewhere", "show.slim"))
  end

  def test_promotion_denies_destination_traversal
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "../escape.txt"}
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(File.join(@tmpdir, "escape.txt"))
  end

  def test_promotion_denies_absolute_destination_outside_roots
    definition = register_promotable_kind(
      "promotion_destination" => {
        "location" => "project",
        "path" => File.join(@tmpdir, "poutside", "absolute.txt")
      }
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(File.join(@tmpdir, "poutside", "absolute.txt"))
  end

  def test_promotion_denies_symlinked_destination_escape
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "link.slim"}
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")
    escape_target = File.join(@tmpdir, "poutside", "escape_target.txt")
    File.symlink(escape_target, File.join(definition["roots"]["project"], "link.slim"))

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(escape_target)
  end

  def test_promotion_denies_existing_destination_by_default
    definition = register_promotable_kind
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "new content")
    destination = File.join(definition["roots"]["project"], "show.slim")
    File.write(destination, "old content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Promotion destination already exists/, error.message)

    assert_equal "old content", File.read(destination)
    assert_equal "new content", File.read(source)
  end

  def test_promotion_overwrite_replaces_existing_destination
    definition = register_promotable_kind
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "new content")
    destination = File.join(definition["roots"]["project"], "show.slim")
    File.write(destination, "old content")

    result = @agent.path_promote(
      "kind" => "view", "path" => "show.slim", "overwrite" => true
    )

    assert_equal true, result["promoted"]
    assert_equal "new content", File.read(destination)
    assert !File.exist?(source)
  end

  def test_promotion_rejects_invalid_destination_specification
    definition = register_promotable_kind("promotion_destination" => 42)
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Invalid promotion destination for path kind view/, error.message)

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_promotion_callable_destination_spec_is_rejected
    # A Callable promotion destination would have to run BEFORE the
    # destination is authorized; a side-effecting callable could mutate
    # anywhere.  The declarative-only contract rejects it up front.
    called = false
    definition = register_promotable_kind(
      "promotion_destination" => lambda do |_agent, _path, _location, _args|
        called = true
        {"location" => "project"}
      end
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Invalid promotion destination for path kind view/, error.message)
    assert !called

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_promotion_string_destination_spec_selects_location
    definition = register_promotable_kind("promotion_destination" => "project")
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert File.exist?(File.join(definition["roots"]["project"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
  end

  def test_promotion_destination_path_renames_target
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "release.slim"}
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal File.join(definition["roots"]["project"], "release.slim"),
                 result["promotion_target"]
    assert File.exist?(File.join(definition["roots"]["project"], "release.slim"))
    assert !File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
  end

  def test_promotion_missing_source_is_rejected_before_anything_moves
    definition = register_promotable_kind

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "ghost.slim")
    end
    assert_match(/Path does not exist or is not readable/, error.message)

    assert !File.exist?(File.join(definition["roots"]["project"], "ghost.slim"))
  end

  # ------------------------------------------------------------------
  # Selector semantics regression matrix (lines + chars)
  #
  # Lines contract: 0-based start, exclusive end; a line includes its
  # terminator; untouched lines byte-identical; final newline preserved IFF
  # it existed before the edit; empty replacement deletes the span.
  # ------------------------------------------------------------------

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

  def test_registry_starts_empty_on_fresh_agent
    agent = LLM.agent
    assert_equal({}, agent.path_kind_registry)
  end

  def test_registry_registration_is_agent_local
    first = LLM.agent
    second = LLM.agent

    first.register_path_kind(
      "isolated",
      "description" => "Registered only on one agent",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir}
    )

    assert first.path_kind_registry.key?("isolated")
    refute second.path_kind_registry.key?("isolated")
  end

  def test_registry_has_no_class_level_surface_left
    assert !LLM::Agent.respond_to?(:register_path_kind)
    assert !LLM::Agent.const_defined?(:PATH_KINDS, false)
  end

  def test_registry_path_kinds_tool_reflects_instance_registrations
    register_text_kind

    kinds = @agent.path_kinds({})

    assert kinds.key?("text")
    assert_equal "Test text paths", kinds["text"]["description"]
  end

  # ------------------------------------------------------------------
  # smoke operation surface
  # ------------------------------------------------------------------

  def test_smoke_tool_absent_when_no_kind_enables_smoke
    register_text_kind

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    assert !tools.key?("path_smoke")
  end

  def test_smoke_tool_present_when_kind_enables_smoke
    register_text_kind("smoke", {"smoke" => true})

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    assert tools.key?("path_smoke")
    assert !tools.key?("path_test")
  end

  def test_smoke_operation_runs_kind_callback
    seen = []
    @agent.register_path_kind(
      "view",
      "description" => "Smoke views",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"smoke" => true},
      "smoke" => ->(agent, path, location, args) { seen << [path, location, args["kind"]] }
    )

    @agent.path_smoke("kind" => "view", "path" => "show.slim")

    assert_equal [["show.slim", "project", "view"]], seen
  end

  def test_smoke_is_denied_outside_grants
    called = false
    outside = Dir.mktmpdir("path-outside")
    @agent.register_path_kind(
      "smoke", "locations" => ["tmp"], "default_location" => "tmp",
      "roots" => {"tmp" => @tmpdir}, "capabilities" => {"smoke" => true},
      "resolve" => ->(_agent, _path, _location) { outside },
      "smoke" => ->(*) { called = true }
    )

    assert_raise(ParameterException) do
      @agent.path_smoke("kind" => "smoke", "path" => "item")
    end
    assert_false called
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_smoke_and_test_are_independently_enabled
    @agent.register_path_kind(
      "both",
      "description" => "Both smoke and test",
      "locations" => ["project"],
      "roots" => {"project" => @tmpdir},
      "capabilities" => {"smoke" => true, "test" => true}
    )

    tools = @agent.instance_variable_get(:@other_options)[:tools]

    assert tools.key?("path_smoke")
    assert tools.key?("path_test")
    assert !tools.key?("path_validate")
  end
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # Step 7 — edit-operation distinctness and compatibility
  # ------------------------------------------------------------------

  # Compare a built-in tool schema ignoring the kind property, which
  # legitimately grows as kinds register (enum, supported-kinds
  # description). Everything else must be identical.
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

  # Step 6: patch operation
  # ------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Whole-workflow PATH_KINDS incorporation (`tool: Workflow` chat semantic).
#
# Mirrors lib/scout/llm/agent.rb (the `tool:` hook inside Agent#ask) and
# lib/scout/llm/agent/path.rb (`integrate_workflow_path_kinds`).  Test-local
# workflow modules are defined at the bottom of the file and reused across
# these tests; the mock backend drives Agent#ask end to end offline
# (LLM::Mock, test/support/mock_backend.rb, backend :mock from
# test/test_helper.rb).  Every test uses a fresh agent so no kind ever leaks
# between tests.
# ---------------------------------------------------------------------------
class TestPathWorkflowKindIntegration < Test::Unit::TestCase
  def setup
    @tmpdir = Scout.tmp.agent_path_kind_test.find
    FileUtils.mkdir_p(@tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def fresh_agent
    LLM.agent
  end

  def ask_with(agent, chat_text)
    LLM::Mock.script('ok')
    agent.prompt LLM.chat(chat_text), persist: false, endpoint: 'mock', backend: :mock
  end

  # -- registration through whole-workflow `tool:` ---------------------------

  def test_whole_workflow_tool_line_registers_kinds_and_installs_tools
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\ndo things")

    assert agent.path_kind_registry.key?('wfa_kind')
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']

    tool_names = (agent.other_options[:tools] || {}).keys
    %w[path_kinds path_read path_write].each do |tool|
      assert tool_names.include?(tool), "expected #{tool} in #{tool_names.inspect}"
    end
  end

  def test_task_level_tool_line_registers_nothing
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowB t\nuser\ndo things")

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
    assert_empty (agent.other_options[:tools] || {}).keys
      .select { |name| name.start_with?('path_') }
  end

  def test_workflow_without_path_kinds_is_silent_noop
    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone)

    ask_with(agent, "tool: TestPathKindWorkflowNone\nuser\ndo things")
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_merely_defining_the_module_registers_nothing
    # Negative baseline: TestPathKindWorkflowA's PATH_KINDS exists in the
    # constant table, but a fresh agent that never incorporates the workflow
    # has an empty registry.
    agent = fresh_agent
    assert TestPathKindWorkflowA.const_defined?(:PATH_KINDS, false)
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
    assert_empty (agent.other_options[:tools] || {}).keys
  end

  # -- conflict / idempotence -------------------------------------------------

  def test_conflict_between_two_workflows_raises_naming_both
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nfirst")

    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowConflict)
    end

    assert_include error.message, 'wfa_kind'
    assert_include error.message, 'TestPathKindWorkflowA'
    assert_include error.message, 'TestPathKindWorkflowConflict'
    # the first registration survives the rejected second one
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']
  end

  def test_same_workflow_repeated_is_idempotent
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nfirst")
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nsecond")

    assert_equal ['wfa_kind'], agent.path_kind_registry.keys
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']

    tool_names = (agent.other_options[:tools] || {}).keys
    assert_equal tool_names, tool_names.uniq
    assert_equal 1, tool_names.count('path_kinds')
  end

  # -- shape validation --------------------------------------------------------

  def test_shape_error_names_workflow_and_class
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowBadShape)
    end

    assert_include error.message, 'TestPathKindWorkflowBadShape'
    assert_include error.message, 'String'
  end

  def test_array_of_definition_hashes_is_accepted
    agent = fresh_agent
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray)

    assert agent.path_kind_registry.key?('arr_first')
    assert agent.path_kind_registry.key?('arr_second')
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']
  end

  def test_entry_without_hash_definition_is_rejected
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowBadEntry)
    end
    assert_include error.message, 'TestPathKindWorkflowBadEntry'
  end

  # -- namespace locality -------------------------------------------------------

  def test_nested_module_does_not_inherit_parent_path_kinds
    agent = fresh_agent
    assert TestPathKindParent::PATH_KINDS.is_a?(Hash)
    # nesting: child has no namespace-local PATH_KINDS
    assert !TestPathKindParent::Child.const_defined?(:PATH_KINDS, false)

    assert_nil agent.integrate_workflow_path_kinds(TestPathKindParent::Child)
    assert_empty agent.path_kind_registry
  end

  def test_subclass_does_not_inherit_parent_path_kinds
    agent = fresh_agent
    # const_defined? without the inherit flag WOULD see the parent constant
    assert TestPathKindSubclassed.const_defined?(:PATH_KINDS)
    assert !TestPathKindSubclassed.const_defined?(:PATH_KINDS, false)

    assert_nil agent.integrate_workflow_path_kinds(TestPathKindSubclassed)
    assert_empty agent.path_kind_registry
  end

  def test_remote_workflow_namespace_returns_nil
    require 'rbbt'
    require 'scout/offsite/ssh'
    require 'rbbt/workflow/remote_workflow'

    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds(RemoteWorkflow)
    assert_empty agent.path_kind_registry
  end

  def test_anonymous_module_returns_nil
    agent = fresh_agent
    anonymous = Module.new { extend Workflow }
    assert_nil agent.integrate_workflow_path_kinds(anonymous)
    assert_empty agent.path_kind_registry
  end

  def test_non_module_object_returns_nil
    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds('TestPathKindWorkflowA')
    assert_nil agent.integrate_workflow_path_kinds(nil)
    assert_empty agent.path_kind_registry
  end

  # -- frozen constant isolation --------------------------------------------------

  def test_frozen_path_kinds_constant_is_never_mutated
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\ndo things")

    constant = TestPathKindWorkflowA::PATH_KINDS
    # --- nested-structure isolation (both directions) ---
    # Mutating the CONSTANT's nested structures after registration must not
    # reach the agent's registered copy...
    constant['wfa_kind']['description'] = 'CONST-NESTED-MUTATION'
    registered = agent.path_kind_registry['wfa_kind']
    assert_equal 'Kind exported by TestPathKindWorkflowA', registered['description']
    assert !registered['roots'].equal?(constant['wfa_kind']['roots'])
    assert !registered['locations'].equal?(constant['wfa_kind']['locations'])
    original = constant['wfa_kind'].dup

    registered = agent.path_kind_registry['wfa_kind']
    refute_same constant['wfa_kind'], registered
    refute_same constant, registered

    # mutating the registered copy leaves the constant untouched
    registered['description'] = 'mutated through the registry'
    assert_equal original['description'], constant['wfa_kind']['description']

    # re-registration does not write "name" or normalization back either
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nagain")
    assert_nil constant['wfa_kind']['name']
    assert_equal original, constant['wfa_kind']
  end

  # -- `path:` chat role removal ---------------------------------------------------

  def test_path_role_no_longer_installs_path_tools
    agent = fresh_agent
    ask_with(agent, "path: true\nuser\nhello")

    assert_empty agent.path_kind_registry
    assert_empty (agent.other_options[:tools] || {}).keys
  end

  def test_path_role_survives_in_messages_unconsumed
    # Observed behavior after the role removal: the capability loop ignores
    # `path:` lines, so the message stays in the chat and is delivered to the
    # backend together with the user message (the mock records every round).
    agent = fresh_agent
    LLM::Mock.script('ok')
    agent.prompt LLM.chat("path: true\nuser\nhello"),
                 persist: false, endpoint: 'mock', backend: :mock

    roles = LLM::Mock.calls.first.first.collect { |m| m[:role].to_s }
    assert_include roles, 'path'
  end

  def test_agent_path_is_a_plain_accessor_again
    agent = fresh_agent
    agent.path = File.join(@tmpdir, 'agent_path')
    assert_equal File.join(@tmpdir, 'agent_path'), agent.path
  end

  def test_capability_loop_still_handles_socialize_and_attachments
    # the array shrunk to exactly two capabilities; the dispatch helper
    # `path` is gone and `Agent#path` is the plain accessor again (its
    # source is the attr_accessor at agent.rb, not agent/path.rb)
    assert_equal ['lib/scout/llm/agent.rb'],
                 LLM::Agent.instance_method(:path).source_location[0..0]
                 .collect { |f| f.sub(%r{.*/scout-ai/}, '') }
    assert LLM::Agent.instance_methods.include?(:socialize)
    assert LLM::Agent.instance_methods.include?(:attachments)
  end

  # -- skipped incorporations --------------------------------------------------

  def test_unresolvable_workflow_name_is_skipped_silently
    # The hook itself rescues the lookup and skips PATH_KINDS handling; the
    # later backend tool resolution then legitimately raises because no such
    # workflow exists anywhere.  We drive only the hook (the same block
    # Agent#ask runs, lifted verbatim) to pin the skip behavior.
    agent = fresh_agent
    messages = Chat.setup(LLM.chat("tool: NoSuchWorkflowForPathKinds\nuser\ndo things"))
    hook = lambda do |msgs|
      Chat.find_role(msgs, :tool).each do |message|
        workflow_name, task_name, *_inputs = Chat.content_tokens(message)
        next if task_name
        next if workflow_name.nil? || workflow_name.empty?
        next if Open.remote? workflow_name
        begin
          workflow = Chat.load_workflow workflow_name
        rescue
          next
        end
        agent.integrate_workflow_path_kinds(workflow)
      end
    end
    assert_nothing_raised { hook.call(messages) }

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_remote_tool_line_is_skipped_by_path_kinds_hook
    agent = fresh_agent
    messages = Chat.setup(LLM.chat("tool: https://127.0.0.1:1/WF\nuser\ndo things"))
    hook = lambda do |msgs|
      Chat.find_role(msgs, :tool).each do |message|
        workflow_name, task_name, *_inputs = Chat.content_tokens(message)
        next if task_name
        next if workflow_name.nil? || workflow_name.empty?
        next if Open.remote? workflow_name
        begin
          workflow = Chat.load_workflow workflow_name
        rescue
          next
        end
        agent.integrate_workflow_path_kinds(workflow)
      end
    end
    assert_nothing_raised { hook.call(messages) }

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end
end

# Test-local workflow modules used above. They are defined OUTSIDE the test
# class (same technique as TestBaking in test/scout/llm/agent/test_workflow.rb
# and test/scout/llm/test_chat.rb): `tool:`/`introduce:` resolve names through
# Kernel.const_get first, so a named module is reachable without any file on
# disk and without touching the real workflow search path.
$test_path_kind_root ||= Path.setup(File.join(Scout.tmp.agent_path_kind_test.find.to_s, 'roots')).find

module TestPathKindWorkflowA
  extend Workflow
  self.name = 'TestPathKindWorkflowA'

  PATH_KINDS = {
    'wfa_kind' => {
      'description' => 'Kind exported by TestPathKindWorkflowA',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root},
      'capabilities' => {'read' => true, 'write' => true}
    }
  }.freeze
end

module TestPathKindWorkflowB
  extend Workflow
  self.name = 'TestPathKindWorkflowB'

  desc 'Sample task'
  input :value, :string
  task :t => :string do |value| value end

  PATH_KINDS = {
    'wfb_kind' => {
      'description' => 'Kind exported by TestPathKindWorkflowB',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

module TestPathKindWorkflowNone
  extend Workflow
  self.name = 'TestPathKindWorkflowNone'

  desc 'Sample task'
  input :value, :string
  task :t => :string do |value| value end
end

module TestPathKindWorkflowConflict
  extend Workflow
  self.name = 'TestPathKindWorkflowConflict'

  PATH_KINDS = {
    'wfa_kind' => {
      'description' => 'Conflicting kind from another workflow',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

module TestPathKindWorkflowBadShape
  extend Workflow
  self.name = 'TestPathKindWorkflowBadShape'

  PATH_KINDS = 'not-a-mapping'
end

module TestPathKindWorkflowBadEntry
  extend Workflow
  self.name = 'TestPathKindWorkflowBadEntry'

  PATH_KINDS = {'broken' => 'not-a-hash'}
end

module TestPathKindWorkflowArray
  extend Workflow
  self.name = 'TestPathKindWorkflowArray'

  PATH_KINDS = [
    {
      'name' => 'arr_first',
      'description' => 'First array entry',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    },
    {
      'name' => 'arr_second',
      'description' => 'Second array entry',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  ].freeze
end

module TestPathKindParent
  PATH_KINDS = {
    'parent_kind' => {
      'description' => 'Parent constant, must not be discovered',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze

  module Child
    extend Workflow
    self.name = 'TestPathKindParent::Child'
  end
end

class TestPathKindBase
  PATH_KINDS = {
    'base_kind' => {
      'description' => 'Base class constant, must not be discovered',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

class TestPathKindSubclassed < TestPathKindBase
  extend Workflow
  self.name = 'TestPathKindSubclassed'
end
