require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"

class TestPathContracts < Test::Unit::TestCase
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

  def test_register_path_kind_rejects_non_boolean_sandbox_setting
    assert_raise(ParameterException) do
      @agent.register_path_kind("invalid", "sandbox" => "false")
    end
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

end
