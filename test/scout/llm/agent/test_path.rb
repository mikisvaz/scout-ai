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
    assert_raise(ArgumentError) do
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
    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
      @agent.path_move("kind" => "text", "path" => "source", "destination" => "escape/new")
    end
    assert File.file?(File.join(@tmpdir, "source"))
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_register_path_kind_rejects_invalid_default_location
    assert_raise(ArgumentError) do
      @agent.register_path_kind(
        "text",
        "locations" => ["project"],
        "default_location" => "tmp"
      )
    end
  end

  def test_register_path_kinds
    @agent.register_path_kinds(
      "text" => {
        "locations" => ["project"],
        "roots" => {"project" => @tmpdir}
      },
      "other" => {
        "locations" => ["project"],
        "roots" => {"project" => @tmpdir}
      }
    )

    assert @agent.path_kinds.key?("text")
    assert @agent.path_kinds.key?("other")
  end

  def test_path_kind_definition
    register_text_kind

    definition = @agent.path_kind_definition("text")

    assert_equal "text", definition["name"]
  end

  def test_path_kind_definition_rejects_unknown_kind
    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
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

    error = assert_raise(ArgumentError) do
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
    error = assert_raise(ArgumentError) do
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

    error = assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
      @agent.path_write(
        "kind" => "text",
        "path" => "hello.txt",
        "content" => "hello"
      )
    end
  end

  def test_path_read_rejects_missing_path
    register_text_kind

    assert_raise(ArgumentError) do
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
    assert_raise(ArgumentError) do
      @agent.path_apply_selector(
        "hello world",
        {"type" => "unknown"},
        "replacement"
      )
    end
  end

  def test_path_edit_rejects_invalid_line_range
    assert_raise(ArgumentError) do
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
    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
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

    assert_raise(ArgumentError) do
      @agent.path_validate(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_promote
    calls = []

    @agent.register_path_kind(
      "view",
      "locations" => ["tmp", "project"],
      "default_location" => "tmp",
      "roots" => {
        "tmp" => File.join(@tmpdir, "tmp"),
        "project" => File.join(@tmpdir, "project")
      },
      "capabilities" => {"promote" => true},
      "promote" => lambda do |agent, path, location, args|
        calls << [agent, path, location, args]
        {"promoted" => true, "path" => path}
      end
    )

    result = @agent.path_promote(
      "kind" => "view",
      "path" => "show.slim"
    )

    assert_equal true, result["promoted"]
    assert_equal "show.slim", result["path"]
    assert_equal @agent, calls.first[0]
    assert_equal "show.slim", calls.first[1]
    assert_equal "tmp", calls.first[2]
  end

  def test_path_promote_requires_capability
    register_text_kind

    assert_raise(ArgumentError) do
      @agent.path_promote(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_promote_requires_implementation
    @agent.register_path_kind(
      "view",
      "locations" => ["tmp", "project"],
      "default_location" => "tmp",
      "roots" => {
        "tmp" => File.join(@tmpdir, "tmp"),
        "project" => File.join(@tmpdir, "project")
      },
      "capabilities" => {"promote" => true}
    )

    assert_raise(ArgumentError) do
      @agent.path_promote(
        "kind" => "view",
        "path" => "show.slim"
      )
    end
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
end
