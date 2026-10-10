# frozen_string_literal: true

# Agent-level virtual Path interface.
#
# A path is addressed by a kind and a path, e.g.:
#
#   view::studies/show.slim
#   task::sync.rb
#   cortex::briefs/current.md
#
# Kinds are deliberately represented as hashes.  A kind describes the
# namespace, where objects live, which generic operations are available, and
# optionally supplies kind-specific operations such as validation, testing,
# or promotion.
#
# Path plugins are loaded in the context of an Agent instance, so a plugin
# file can simply call `register_path_kind`; registration is agent-local
# (there is no class-wide registry).

require "fileutils"
require_relative "../sandbox"
require_relative "path/patch"
require_relative "path/edit"

module LLM
  class Agent
    include AgentPathEdit
    DEFAULT_CAPABILITIES = {
      "read" => true,
      "write" => true,
      "edit" => true,
      "list" => true,
      "move" => true,
      "rename" => true,
      "delete" => true,
      "validate" => false,
      "test" => false,
      "promote" => false,
      "smoke" => false,
      "patch" => false
    }.freeze

    GENERIC_OPERATIONS = %w[
        read write edit list move rename delete
    ].freeze

    SPECIAL_OPERATIONS = %w[
        validate test promote smoke patch
    ].freeze

    # All engine-owned built-in operations, in stable order.  Public tool
    # schemas for these stay engine-side (path_tool_definition); a kind can
    # replace an implementation via an override, never the schema.
    BUILT_IN_OPERATIONS = (GENERIC_OPERATIONS + SPECIAL_OPERATIONS).freeze

    # Handler types a custom operation implementation may declare:
    #   :content - content-transform handler: receives resolved content and
    #              args, returns transformed content; the ENGINE reads and
    #              writes the authorized target around it.
    #   :full    - full handler: receives the resolved authorized target and
    #              args, returns a result.  Trusted plugin code: the engine
    #              cannot constrain which files it touches.
    PATH_HANDLER_TYPES = %i[content full].freeze

    # Authorization modes a custom operation may request; the engine's
    # existing sandbox mode vocabulary.  Fail-closed default is :write.
    PATH_AUTHORIZATION_MODES = %i[read write].freeze

    # Authorization mode the ENGINE applies to its own built-in operations
    # (read/list are read-only; every other built-in mutates).  Recorded
    # into each kind's canonical operation table at registration.
    BUILTIN_OPERATION_AUTHORIZATION = {
      "read" => :read,
      "list" => :read
    }.freeze

    # Whole-workflow PATH_KINDS incorporation.  Invoked from Agent#ask when a
    # `tool: <workflow>` line (whole workflow, no task token) incorporates an
    # entire workflow; task-level `tool: <workflow> <task>` lines never reach
    # this.  `workflow` must be a loaded local workflow Module (not a
    # RemoteWorkflow, not an agent-fallback) that defines a `PATH_KINDS`
    # constant in its own namespace.
    #
    # A workflow without `PATH_KINDS` registers nothing and returns nil
    # silently.  With it, every entry is registered through the regular
    # `register_path_kind` (which dups the definition and reinstalls the tools
    # atomically); the shared `PATH_KINDS` constant is never mutated.
    #
    # Provenance bookkeeping (`path_kind_sources`, kind name => workflow
    # name) is kept beside the authoritative `path_kind_registry`: it records
    # WHICH whole-workflow incorporation supplied a kind name, so a second
    # DIFFERENT workflow reusing an existing kind name fails deterministically
    # instead of letting import order decide.  It is not a second registry:
    # kinds are always looked up in `path_kind_registry`; re-registering the
    # same kind from the same workflow overwrites idempotently.
    #
    # Kind definitions supplied by other callers (plugins, direct Ruby) do not
    # record a source; a later whole-workflow incorporation of the same kind
    # name simply re-registers it (the new source then owns the name).
    def integrate_workflow_path_kinds(workflow)
      # Only a local workflow Module qualifies: RemoteWorkflow instances
      # (remote `tool:` targets) and anything else without a resolvable
      # constant name are skipped entirely.
      return nil unless Module === workflow
      return nil if (workflow < RemoteWorkflow rescue false)
      return nil if workflow.name.nil?
      return nil unless workflow.const_defined?(:PATH_KINDS, false)

      kinds = workflow.const_get(:PATH_KINDS, false)
      workflow_name = workflow.name

      definitions = path_normalize_workflow_path_kinds(kinds, workflow_name)

      definitions.each do |name, definition|
        source = path_kind_sources[name]
        if source && source != workflow_name
          raise ParameterException,
            "Path kind #{name.inspect} is already provided by workflow " \
            "#{source.inspect}; workflow #{workflow_name.inspect} cannot " \
            "redefine it. Two workflows must not supply the same path kind."
        end

        # Deep-dup at this boundary: register_path_kind dups only one level,
        # and Hash#freeze is shallow, so a shared frozen PATH_KINDS constant
        # could otherwise be mutated through the registry (for instance by a
        # future definition mutation).  Copies are kept as plain unfrozen
        # Hashes; callables are shared by reference as everywhere else.
        register_path_kind(name, path_deep_copy(definition))
        path_kind_sources[name] = workflow_name
      end

      definitions
    end

    # Accept either a Hash of kind name => definition or an Array of
    # definition hashes (each carrying its own "name"), mirroring what
    # `register_path_kind` accepts per entry.  Always returns a normalized
    # Hash of kind name => definition.
    def path_normalize_workflow_path_kinds(kinds, workflow_name)
      if kinds.respond_to?(:each_pair)
        entries = kinds.collect{|name, definition| [name, definition] }
      elsif kinds.respond_to?(:each_with_index) && kinds.respond_to?(:first) && Hash === kinds.first
        entries = kinds.collect{|definition|
          [definition["name"] || definition[:name], definition]
        }
      else
        raise ParameterException,
          "Workflow #{workflow_name.inspect} declares PATH_KINDS as a " \
          "#{kinds.class}; expected a Hash of kind name => definition " \
          "(or an Array of definition Hashes with a \"name\" key)"
      end

      normalized = {}
      entries.each do |name, definition|
        name = name.to_s
        if name.empty?
          raise ParameterException,
            "Workflow #{workflow_name.inspect} declares a PATH_KINDS entry " \
            "with an empty kind name"
        end
        unless Hash === definition
          raise ParameterException,
            "Workflow #{workflow_name.inspect} PATH_KINDS entry " \
            "#{name.inspect} is a #{definition.class}, expected a Hash"
        end
        normalized[name] = definition
      end
      normalized
    end

    # Recursive copy for Hash/Array/Primitive structures used by path-kind
    # definitions.  Callables and other opaque values are shared by
    # reference, matching the rest of the engine.
    def path_deep_copy(value)
      case value
      when Hash
        value.each_with_object({}){|(k, v), acc| acc[k] = path_deep_copy(v) }
      when Array
        value.collect{|v| path_deep_copy(v) }
      when String, Symbol, Numeric, true, false, nil
        value
      else
        value.respond_to?(:call) || !value.respond_to?(:dup) ? value : value.dup
      end
    end

    # Per-agent provenance map recording which workflow supplied each
    # whole-workflow-incorporated kind name.  Bookkeeping only; the
    # authoritative registry remains `path_kind_registry`.
    def path_kind_sources
      @path_kind_sources ||= {}
    end

    # ------------------------------------------------------------------
    # Registry
    # ------------------------------------------------------------------

    # Agent-local registry.  This deliberately remains a plain Hash so
    # workflows/agent definitions can inspect or modify it without another
    # abstraction layer.  It is the single authoritative registry: kinds are
    # registered per agent instance and never shared between agents.
    def path_kind_registry
      @path_kinds ||= {}
    end

    # CANONICAL REPRESENTATION.  `register_path_kind` normalizes a kind
    # definition ONCE, at registration, into the form every later consumer
    # reads directly.  The normalized definition carries:
    #
    #   "name", "description", "sandbox" (boolean, default true),
    #   "locations" (Array, default ["project"]), "default_location",
    #   "capabilities" (full DEFAULT_CAPABILITIES-shaped Hash),
    #   "operations"  -> { op name -> normalized custom spec }  (a custom op
    #                    registers support implicitly; no capability flag),
    #   "overrides"   -> { built-in name -> {"implementation" => Callable} }
    #                    (implementation replacement only; capability
    #                    gating is never bypassed),
    #   "operation_table" -> { op name -> {"implementation" => Callable or
    #                    nil (engine default), "authorization" => :read/:write,
    #                    "type" => :content/:full } } for every SUPPORTED
    #                    operation of the kind: enabled built-ins, every
    #                    override target, and every custom operation.  An
    #                    override of a capability-disabled built-in IS in the
    #                    table (support), but the ENGINE method still gates on
    #                    capabilities, so the pair can never be executed.
    #
    # Callers keep authoring the declarative form (Hash of keys); the
    # engine is the only place that interpretation happens.
    def register_path_kind(name, definition = nil, &block)
      definition = block.call if definition.nil? && block
      definition ||= {}

      name = name.to_s
      raise ParameterException, "Path kind cannot be empty" if name.empty?

      definition = definition.dup
      definition["name"] = name
      definition["sandbox"] = true unless definition.key?("sandbox")
      unless [true, false].include?(definition["sandbox"])
        raise ParameterException, "Path kind sandbox setting must be boolean"
      end
      definition["description"] ||= "#{name} path"

      capabilities = definition.fetch("capabilities", {})
      capabilities = if Array === capabilities
                       hash = {}
                       capabilities.each{|c| hash[c] = true }
                       hash
                     else
                       capabilities
                     end
      definition["capabilities"] = DEFAULT_CAPABILITIES.merge(capabilities)

      definition["locations"] ||= ["project"]
      definition["default_location"] ||= definition["locations"].first

      definition["operations"] = path_normalize_custom_operations(definition)
      definition["overrides"] = path_normalize_operation_overrides(definition)

      unless definition["locations"].include?(definition["default_location"])
        raise ParameterException,
          "Default location #{definition['default_location'].inspect} " \
          "is not included in locations for #{name}"
      end

      definition["operation_table"] =
        path_operation_table(definition["capabilities"],
                             definition["operations"],
                             definition["overrides"])

      path_kind_registry[name] = definition
      begin
        install_path_tools
      rescue Exception
        # Registration is atomic: a failed install (for example a custom
        # operation contract conflict with an already-registered kind) must
        # not leave the half-registered kind behind.
        path_kind_registry.delete(name)
        raise
      end
      definition
    end

    # Build the per-kind operation table at registration time: one entry per
    # SUPPORTED operation, ready for direct reads.  Entry shape:
    #   {"implementation" => Callable or nil, "authorization" => :read/:write,
    #    "type" => :content/:full}
    # Precedence mirrors the engine contract: an override beats the engine
    # default; a custom operation carries its own registered callable; the
    # engine default for a built-in has implementation nil (dispatched to the
    # engine method).  Disabled built-ins are absent - support is exactly
    # `operation_table.key?(op)` after this point.
    def path_operation_table(capabilities, operations, overrides)
      table = {}

      capabilities.each_pair do |operation, enabled|
        next unless enabled
        operation = operation.to_s
        table[operation] = {
          "implementation" => overrides.dig(operation, "implementation"),
          "authorization" => BUILTIN_OPERATION_AUTHORIZATION.fetch(operation, :write),
          "type" => :full
        }
      end

      overrides.each_pair do |operation, spec|
        operation = operation.to_s
        next if table.key?(operation)
        table[operation] = {
          "implementation" => spec["implementation"],
          "authorization" => BUILTIN_OPERATION_AUTHORIZATION.fetch(operation, :write),
          "type" => :full
        }
      end

      operations.each_pair do |operation, spec|
        table[operation.to_s] = {
          "implementation" => spec["implementation"],
          "authorization" => spec["authorization"],
          "type" => spec["type"]
        }
      end

      table
    end

    # Load a plugin file in the context of this Agent instance.
    #
    # Example plugin:
    #
    #   register_path_kind :view,
    #     "description" => "A Slim web view",
    #     "locations" => ["tmp", "project"],
    #     # Roots MUST be absolute paths (build them with File.expand_path);
    #     # relative roots are rejected by the sandbox.  Plugin-author docs:
    #     # doc/developer/PathEngine.md.
    #     "roots" => {
    #       "tmp" => File.expand_path(".scout/var/path/views"),
    #       "project" => File.expand_path("share/views")
    #     },
    #     "capabilities" => {"promote" => true},
    #     "validate" => ->(path, content) { ... },
    #     # Promotion destination is DECLARATIVE: a location String, or a Hash
    #     # with "location" (plus optional "path"; default is the source path).
    #     # The ENGINE authorizes both endpoints and performs the move itself;
    #     # no mover callback exists.  A Callable destination is rejected.
    #     "promotion_destination" => "project",
    #     # Optional post-move hook: runs AFTER the engine-controlled move,
    #     # receives the authorized endpoints in args; never the writer.
    #     "promotion_post_move" => ->(agent, path, location, args) { ... }
    #
    # The file can therefore be a very small declarative definition rather
    # than a class hierarchy.
    def load_path_plugins(*files)
      files.flatten.each do |file|
        instance_eval(File.read(file), file.to_s, 1)
      end
      install_path_tools
      self
    end

    def path_kind_definition(kind)
      path_kind_registry.fetch(kind.to_s) do
        raise ParameterException, "Unknown path kind: #{kind}"
      end
    end

    # Direct read of the canonical representation: capability gating.
    def path_kind_capable?(kind, operation)
      !!path_kind_definition(kind).fetch("capabilities", {}).fetch(operation.to_s, false)
    end

    # ------------------------------------------------------------------
    # Operation registration contract
    # ------------------------------------------------------------------

    # Normalize the optional "operations" key of a kind definition into
    # validated custom-operation specs.  Registering a custom operation
    # ESTABLISHES support for it on that kind: no capability flag, no
    # second boolean.
    def path_normalize_custom_operations(definition)
      operations = definition["operations"] || {}
      unless operations.respond_to?(:each_pair)
        raise ParameterException,
          "Path kind operations must be a mapping of operation name to spec"
      end

      normalized = {}
      operations.each_pair do |name, spec|
        name = name.to_s
        raise ParameterException, "Custom operation name cannot be empty" if name.empty?

        if BUILT_IN_OPERATIONS.include?(name)
          raise ParameterException,
            "Custom operation #{name.inspect} collides with a built-in " \
            "operation; register an override instead"
        end

        spec = {"implementation" => spec} if spec.respond_to?(:call)
        unless spec.respond_to?(:[])
          raise ParameterException,
            "Custom operation #{name.inspect} must be a Callable or a spec Hash"
        end

        implementation = spec["implementation"]
        unless implementation.respond_to?(:call)
          raise ParameterException,
            "Custom operation #{name.inspect} requires an implementation Callable"
        end

        authorization = (spec["authorization"] || :write).to_sym
        unless PATH_AUTHORIZATION_MODES.include?(authorization)
          raise ParameterException,
            "Custom operation #{name.inspect} authorization must be one of " \
            "#{PATH_AUTHORIZATION_MODES.map(&:inspect).join(', ')}; got " \
            "#{authorization.inspect}"
        end

        handler = (spec["type"] || :full).to_sym
        unless PATH_HANDLER_TYPES.include?(handler)
          raise ParameterException,
            "Custom operation #{name.inspect} type must be one of " \
            "#{PATH_HANDLER_TYPES.map(&:inspect).join(', ')}; got #{handler.inspect}"
        end

        parameters = spec["parameters"] || {}
        unless parameters.respond_to?(:[])
          raise ParameterException,
            "Custom operation #{name.inspect} parameters must be a Hash"
        end

        normalized[name] = {
          "name" => name,
          "description" => spec["description"] || "Custom Path operation #{name}.",
          "parameters" => parameters,
          "implementation" => implementation,
          "authorization" => authorization,
          "type" => handler
        }
      end
      normalized
    end

    # ------------------------------------------------------------------
    # Operation registry queries
    # ------------------------------------------------------------------

    # One canonical table per kind ("operation_table") is built at
    # registration (path_operation_table); the queries below are direct
    # reads of it.  Support, authorization and implementation no longer
    # re-derive anything at lookup time.

    # Does this kind support the operation?  Support is established at
    # registration: enabled built-ins, their overrides, and custom
    # operations are all in the table; nothing else is.
    def path_operation_support?(kind, operation)
      path_kind_definition(kind).fetch("operation_table", {}).key?(operation.to_s)
    end

    # Implementation selection: a direct read of the table entry - an
    # override's callable, a custom operation's callable, or nil for the
    # engine default.  Nil when the operation is unsupported.
    def path_operation_implementation(kind, operation)
      entry = path_kind_definition(kind).fetch("operation_table", {})[operation.to_s]
      entry && entry["implementation"]
    end

    # Normalize the optional "overrides" key: built-in name -> implementation
    # Callable (or spec Hash with an "implementation" entry).  An override
    # replaces the implementation ONLY; the public tool schema stays
    # engine-owned, and capability gating is not bypassed.
    def path_normalize_operation_overrides(definition)
      overrides = definition["overrides"] || {}
      unless overrides.respond_to?(:each_pair)
        raise ParameterException,
          "Path kind overrides must be a mapping of built-in name to implementation"
      end

      normalized = {}
      overrides.each_pair do |name, spec|
        name = name.to_s
        unless BUILT_IN_OPERATIONS.include?(name)
          raise ParameterException,
            "Override #{name.inspect} must name a built-in operation " \
            "(#{BUILT_IN_OPERATIONS.join(', ')})"
        end

        spec = {"implementation" => spec} if spec.respond_to?(:call)
        implementation = spec["implementation"] if spec.respond_to?(:[])
        unless implementation.respond_to?(:call)
          raise ParameterException,
            "Override #{name.inspect} requires an implementation Callable"
        end

        normalized[name] = {"implementation" => implementation}
      end
      normalized
    end

    # ------------------------------------------------------------------
    # Tool installation
    # ------------------------------------------------------------------

    # One tool per operation name, derived from the canonical registry:
    #
    #   1. the `path_kinds` listing tool (kind enum live from the registry);
    #   2. one engine-owned tool per BUILT-IN operation supported by at
    #      least one registered kind (`path_tool_definition`);
    #   3. one aggregated tool per CUSTOM operation name across all kinds
    #      (`path_custom_tool_definition` contract-checks exact matches).
    #
    # `path_install_tool` is the single choke point every definition goes
    # through, so re-running this routine replaces the whole surface.
    def install_path_tools
      return if path_kind_registry.empty?

      path_install_tool("path_kinds",
                        "description" => <<~DESC.strip,
                          List the virtual Path kinds currently available to this agent.
                          Each kind identifies a namespace of textual objects and declares
                          its supported locations and operations.
                        DESC
                        "parameters" => {
                          "type" => "object",
                          "properties" => {
                            "kind" => {
                              "type" => "string",
                              "description" => "Registered Path kind to identify.",
                              "enum" => path_kind_registry.keys
                            }
                          },
                          "additionalProperties" => false
                        })

      BUILT_IN_OPERATIONS.each do |operation|
        next unless path_kind_registry.values.any? do |definition|
          definition.fetch("capabilities", {}).fetch(operation, false)
        end

        path_install_tool("path_#{operation}", path_tool_definition(operation))
      end

      path_kind_registry.values
        .flat_map { |definition| definition.fetch("operations", {}).keys }
        .uniq.sort.each do |operation|
        path_install_tool(operation, path_custom_tool_definition(operation))
      end
    end

    # ------------------------------------------------------------------
    # Custom-operation tool aggregation
    # ------------------------------------------------------------------

    # ONE public tool per custom operation name.  Kinds registering the same
    # operation must declare EXACTLY matching parameter contracts (after
    # normalization, see path_normalized_contract); invocation routes by the
    # "kind" argument.  Built-ins keep engine-owned schemas and are never
    # affected by custom registration.
    def path_custom_tool_definition(operation)
      kinds = []
      spec = nil
      description = nil

      path_kind_registry.each_pair do |kind, definition|
        candidate = definition.fetch("operations", {}).fetch(operation, nil)
        next unless candidate

        # Description resolution: the most recent registration wins.  The
        # registry is a plain Hash in insertion order, so iterating in order
        # and overwriting on every candidate keeps the last-registered
        # description, deterministically.
        description = candidate.fetch("description")

        if spec.nil?
          spec = candidate
        else
          differences = path_contract_differences(
            spec.fetch("parameters", {}),
            candidate.fetch("parameters", {})
          )
          unless differences.empty?
            raise ParameterException,
              "Custom operation #{operation.inspect} registered by kinds " \
              "#{kinds.first.inspect} and #{kind.inspect} with conflicting " \
              "parameter contracts: #{differences.join('; ')}"
          end
        end
        kinds << kind
      end

      properties = path_base_properties("Supported kinds: #{kinds.join(', ')}.")
      properties["kind"]["enum"] = kinds

      parameters = spec.fetch("parameters", {})
      own_properties = parameters["properties"] || parameters.fetch(:properties, {})
      required = parameters["required"] || parameters.fetch(:required, []) || []

      own_properties = own_properties.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value
      end
      own_properties.each_pair do |key, value|
        raise ParameterException,
          "Custom operation #{operation.inspect} declares parameter " \
          "#{key.inspect}, which collides with a path argument" if properties.key?(key)

        properties[key] = value
      end

      required = (["kind", "path"] + required.map(&:to_s)).uniq

      {
        "description" => description,
        "parameters" => {
          "type" => "object",
          "properties" => properties,
          "required" => required,
          "additionalProperties" => false
        },
        # The installed callable routes by the "kind" argument into the
        # single engine dispatch entry point.
        "implementation" => lambda do |arguments|
          args = arguments.dup || {}
          kind = args.delete("kind")
          dispatch = method(:path_dispatch)
          dispatch.call(kind: kind, operation: operation, **args)
        end
      }
    end

    # Normalized parameter-contract comparison.  Two contracts match iff,
    # recursively:
    #   - keys are compared STRINGIFIED (Symbol vs String are the same key);
    #   - "type" values are compared by ==;
    #   - "required" is compared as an UNORDERED SET;
    #   - "enum" lists are compared as UNORDERED SETS;
    #   - "default" values are compared by ==;
    #   - "description" is NOT compared (per-property descriptions are free
    #     text; the first kind's wording is kept);
    #   - Arrays and Hashes are compared element-wise recursively;
    #   - anything else is compared by ==.
    # Returns a list of human-readable difference strings (empty == match).
    def path_contract_differences(left, right, where = "parameters")
      differences = []

      # Contract parameters may use String or Symbol keys interchangeably;
      # normalization lives here so callers can pass hashes either way.
      left_keys = (left.respond_to?(:keys) ? left.keys : []).map(&:to_s)
      right_keys = (right.respond_to?(:keys) ? right.keys : []).map(&:to_s)

      (left_keys - right_keys).each do |key|
        differences << "#{where}.#{key} present only in the first contract"
      end
      (right_keys - left_keys).each do |key|
        differences << "#{where}.#{key} present only in the second contract"
      end

      (left_keys & right_keys).each do |key|
        # String/Symbol-agnostic fetch; the key always exists on both sides
        # because it comes from the key intersection above.
        l = left.each_pair { |k, v| break v if k.to_s == key }
        r = right.each_pair { |k, v| break v if k.to_s == key }

        case key.to_s
        when "description"
          next # not compared
        when "required"
          l_set = Array(l).map(&:to_s).sort
          r_set = Array(r).map(&:to_s).sort
          differences << "#{where}.#{key} differs: #{l_set.inspect} vs #{r_set.inspect}" if l_set != r_set
        when "enum"
          l_set = Array(l).map(&:to_s).sort
          r_set = Array(r).map(&:to_s).sort
          differences << "#{where}.#{key} differs: #{l_set.inspect} vs #{r_set.inspect}" if l_set != r_set
        else
          if l.is_a?(Hash) && r.is_a?(Hash)
            differences.concat(path_contract_differences(l, r, "#{where}.#{key}"))
          elsif l.is_a?(Array) && r.is_a?(Array)
            if l.length != r.length
              differences << "#{where}.#{key} length differs: #{l.length} vs #{r.length}"
            else
              l.each_with_index do |lv, i|
                rv = r[i]
                if lv.is_a?(Hash) && rv.is_a?(Hash)
                  differences.concat(path_contract_differences(lv, rv, "#{where}.#{key}[#{i}]"))
                elsif lv != rv
                  differences << "#{where}.#{key}[#{i}] differs: #{lv.inspect} vs #{rv.inspect}"
                end
              end
            end
          elsif l != r
            differences << "#{where}.#{key} differs: #{l.inspect} vs #{r.inspect}"
          end
        end
      end

      differences
    end

    # Store tools in the same [callable, definition] format consumed by Agent#ask.
    # When +definition+ carries an "implementation" key, that callable is used
    # instead of public_send(name); custom-operation tools use this to route
    # through the engine dispatch entry point.
    def path_install_tool(name, definition, implementation=nil)
      properties = definition.fetch("parameters").fetch("properties")
      required = definition.fetch("parameters").fetch("required", [])
      tool_definition = LLM.tool_definition(name, definition.fetch("description"), properties, required: required)
      implementation = definition["implementation"] if implementation.nil? && definition.key?("implementation")
      implementation = name.to_sym if implementation.nil?
      callable = Proc.new { |_tool_name, arguments|
        begin
          if implementation.respond_to?(:call)
            implementation.call(arguments)
          else
            public_send(implementation, arguments)
          end
        rescue ScoutException => e
          error = :scout
          stack = e.backtrace
          content = {exception: e.message, exception_line: e.backtrace&.first}.to_json
        end
      }

      @other_options ||= {}
      @other_options[:tools] ||= {}
      @other_options[:tools][name] = [callable, tool_definition]
    end

    # ------------------------------------------------------------------
    # Centralized dispatch entry point
    # ------------------------------------------------------------------

    # Single engine entry point for CUSTOM operations.  Every custom operation
    # flows through here; built-in tools keep calling their engine methods
    # directly, and those methods share the same funnel (resolve -> capability
    # -> authorize -> implement) inside themselves.
    #
    # Custom-operation flow:
    #   1. kind known?          -> ParameterException otherwise
    #   2. operation supported? -> ParameterException otherwise (support is
    #      looked up on THIS kind only; no cross-kind fallback)
    #   3. resolve target from args (kind, path, location)
    #   4. authorize target with the registered mode BEFORE any callback
    #      runs (unauthorized call: no callback, no mutation)
    #   5. execute by handler type:
    #      - :content -> engine read -> implementation.call(content, args)
    #                    -> engine writes the SAME authorized target
    #      - :full    -> implementation.call(self, target, args); trusted
    #                    plugin code, the engine cannot constrain what a
    #                    full handler touches (documented trust boundary)
    #
    # Built-ins with an OVERRIDE stay entered through their engine method
    # (public behavior and result shape unchanged); the override runs at
    # the read/transform/write boundary inside that method, after
    # authorization - see path_edit and path_apply_content_handler.
    def path_dispatch(kind:, operation:, **args)
      kind = kind.to_s
      operation = operation.to_s

      unless path_kind_registry.key?(kind)
        raise ParameterException,
          "Unknown Path kind: #{kind.inspect}"
      end

      definition = path_kind_definition(kind)
      entry = definition.fetch("operation_table", {})[operation]
      custom = definition.fetch("operations", {})[operation]

      unless entry
        raise ParameterException,
          "Path kind #{kind.inspect} does not support operation #{operation.inspect}"
      end

      if custom
        authorization = custom.fetch("authorization", :write)
        path = path_argument(args, "path")
        location = args["location"]
        target = resolve_path(kind, path, location)
        path_authorize!(kind, target, location, mode: authorization)

        implementation = custom.fetch("implementation")

        if custom.fetch("type", :full) == :content
          original = path_read_text(target)
          transformed = implementation.call(original, args)
          path_write_text(target, transformed)

          {
            "doc_id" => path_doc_id(kind, path, args["version"]),
            "kind" => kind,
            "path" => path,
            "changed" => original != transformed,
            "content" => transformed
          }
        else
          implementation.call(self, target, args)
        end
      else
        # Built-in reached through dispatch: delegate to the engine
        # method, which applies the same funnel and result shape. The
        # kind arrives as a dispatch keyword; engine methods take it as a
        # hash argument, so re-inject it here.
        public_send("path_#{operation}", args.merge("kind" => kind))
      end
    end

    # Shared kind/path(/location) property trio every Path tool starts
    # from.  Insertion order is part of the serialized schema.
    def path_base_properties(kind_description, with_location: true)
      properties = {
        "kind" => {
          "type" => "string",
          "description" => "Kind of path. #{kind_description}"
        },
        "path" => {
          "type" => "string",
          "description" => "Path within the selected kind."
        }
      }

      if with_location
        properties["location"] = {
          "type" => "string",
          "description" => "Storage location; defaults to the kind's default location."
        }
      end

      properties
    end

    def path_tool_definition(operation)
      kinds = path_kind_registry.keys
      kind_description = if kinds.empty?
                           "No Path kinds are currently registered."
                         else
                           "Supported kinds: #{kinds.join(', ')}."
                         end

      properties = path_base_properties(kind_description,
                                        with_location: operation != "list")

      case operation
      when "write"
        properties["content"] = {
          "type" => "string",
          "description" => "Complete textual content to write."
        }
      when "edit"
        properties["selector"] = {
          "type" => "object",
          "description" => "Text selector. Supports line, character, or regexp selectors.",
          "properties" => {
            "type" => {"type" => "string", "enum" => %w[lines chars regexp]},
            "start" => {"type" => "integer"},
            "end" => {"type" => "integer"},
            "pattern" => {"type" => "string"}
          },
          "additionalProperties" => false
        }
        properties["replacement"] = {
          "type" => "string",
          "description" => "Replacement text."
        }
      when "patch"
        properties["patch"] = {
          "type" => "string",
          "description" => "Unified diff for THIS file only (one ---/+++ pair, " \
                           "one or more @@ hunks). Header filenames are ignored; " \
                           "the target is the resolved kind/path/location."
        }
      when "move"
        properties["destination"] = {
          "type" => "string",
          "description" => "Destination path within the same kind/location."
        }
      when "rename"
        properties["name"] = {
          "type" => "string",
          "description" => "New path/name."
        }
      when "promote"
        properties["overwrite"] = {
          "type" => "boolean",
          "description" => "Allow replacing an existing promotion destination. " \
                           "Default false: an existing destination aborts the promotion."
        }
      when "validate", "test"
        # Kind-specific operations may extend this schema through the
        # optional `parameters` hash in the kind definition.
      end

      operation_descriptions = {
        "read" => "Read the textual content of a virtual Path.",
        "write" => "Write complete textual content to a virtual Path.",
        "edit" => "Edit a textual Path using a line range, character range, or regular expression selector.",
        "list" => "List paths in a virtual Path kind, optionally below a prefix.",
        "move" => "Move a virtual Path to another path in the same kind and location.",
        "rename" => "Rename a virtual Path.",
        "delete" => "Delete a virtual Path.",
        "validate" => "Run the kind-specific syntax or validity check for a virtual Path.",
        "test" => "Run the kind-specific integration test for a virtual Path.",
        "smoke" => "Run the kind-specific lightweight smoke check for a virtual Path.",
        "promote" => "Promote a virtual Path from its temporary location to its project location.",
        "patch" => "Apply a single-file unified diff to a virtual Path in memory and " \
                   "write it back atomically (no fuzz, no side files)."
      }

      definition = {
        "description" => operation_descriptions.fetch(operation, "Operate on a virtual Path."),
        "parameters" => {
          "type" => "object",
          "properties" => properties,
          "required" => operation == "list" ? ["kind"] : %w[kind path],
          "additionalProperties" => false
        }
      }

      # Dynamic enum is useful to models when kinds are known.  Do not add
      # an empty enum, since that makes some JSON-schema consumers reject the
      # tool.
      unless kinds.empty?
        definition["parameters"]["properties"]["kind"]["enum"] = kinds
      end

      definition
    end

    # ------------------------------------------------------------------
    # Path resolution
    # ------------------------------------------------------------------

    # Resolves a virtual path to the underlying Scout/File path.
    #
    # A kind can provide `resolve`, which receives `(agent, path, location)`
    # and returns the target object; the FS-boundary adapters use its String
    # representation (see the FS-boundary comment above path_read_text).
    # Otherwise `roots` are treated as filesystem roots.
    def resolve_path(kind, path, location = nil)
      definition = path_kind_definition(kind)
      location ||= definition["default_location"]

      locations = definition.fetch("locations", [])
      unless locations.include?(location.to_s)
        raise ParameterException,
          "Location #{location.inspect} is not supported by path kind #{kind}"
      end

      if definition["resolve"]
        return definition["resolve"].call(self, path.to_s, location.to_s)
      end

      roots = definition.fetch("roots", {})
      case location
      when nil, 'project', :project
        root = roots.fetch(location.to_s) { Scout.root.find(:current) }
      else
        root = roots.fetch(location.to_s) do
          raise ParameterException,
            "No root configured for #{kind} at location #{location}"
        end
      end

      # A Scout Path-like root may implement [] for child paths. Otherwise
      # use ordinary filesystem paths.
      # Absolute filesystem paths address their exact target. Authorization
      # below still limits them to the configured location root.
      return path.to_s if root.is_a?(String) && path.to_s.start_with?(File::SEPARATOR)

      if root.respond_to?(:[]) && !root.is_a?(String)
        root[path.to_s]
      else
        File.join(root.to_s, path.to_s)
      end
    end

    # Authorize the resolved primary target. Custom resolvers are sandboxed
    # only when their kind declares a root that can serve as the policy grant.
    def path_authorize!(kind, target, location, mode: :read)
      definition = path_kind_definition(kind)
      return true unless definition.fetch("sandbox", true)

      sandbox = LLM.const_get(:Sandbox)
      unless sandbox.respond_to?(:authorize_path)
        raise ParameterException, "Path sandbox authorization is unavailable"
      end

      location = (location || definition["default_location"]).to_s
      root = if location == "project" && !definition.fetch("roots", {}).key?(location)
               Scout.root.find(:current)
             else
               definition.fetch("roots", {}).fetch(location) do
                 raise ParameterException, "No sandbox root configured for #{kind} at #{location}"
               end
             end
      path_string = target.to_s
      root_string = root.to_s
      unless path_string.start_with?(File::SEPARATOR) && root_string.start_with?(File::SEPARATOR)
        raise ParameterException, "Path sandbox requires absolute filesystem paths"
      end

      decision = sandbox.authorize_path(path_string, root: root_string, mode: mode)
      raise ParameterException, "Path access denied by sandbox (#{decision.reason || 'unknown'})" unless decision.allowed
      true
    rescue NameError, NoMethodError => error
      raise ParameterException, "Path sandbox authorization is unavailable: #{error.message}"
    end

    def path_doc_id(kind, path, version = nil)
      id = "#{kind}::#{path}"
      version ? "#{id}@#{version}" : id
    end

    # ------------------------------------------------------------------
    # Argument and selector validation
    # ------------------------------------------------------------------

    # Fetch a required argument of a tool invocation.  Invalid input must
    # surface as the framework's parameter error, never an incidental
    # KeyError from Hash#fetch.
    def path_argument(args, argument)
      args.fetch(argument.to_s) do
        raise ParameterException,
          "Missing required argument #{argument.inspect} for path operation"
      end
    end

    # ------------------------------------------------------------------
    # Text adapter
    # ------------------------------------------------------------------

    # Apply a :content-typed override callable with the engine's
    # single-file content-transform guarantees:
    #   - the callable receives (original_content, args) and returns the
    #     transformed content; it gets NO path argument, so it cannot
    #     redirect the write - the engine writes the SAME authorized
    #     target it read;
    #   - final-newline preservation identical to the engine's own edits:
    #     the written file's final-newline state must match the ORIGINAL
    #     document's, regardless of trailing newlines in the callable's
    #     return value.
    def path_apply_content_handler(handler, target, original, args, kind)
      result = handler.call(original, args)

      original_terminated = original.end_with?("\n")
      result_terminated = result.end_with?("\n")

      if original_terminated == result_terminated
        result
      elsif original_terminated
        result.sub(/\n*\z/, "\n")
      else
        result.sub(/\n+\z/, "")
      end
    end

    # FS boundary (shared by path_read_text / path_write_text /
    # path_exists? / path_delete_target / path_move_target): resolve_path
    # and path_authorize! have already produced and AUTHORIZED the exact
    # target, so these adapters use plain File/FileUtils on target.to_s.
    # Scout Path#find/Open resolution is deliberately not applied here: its
    # fallback semantics (compressed .gz/.bgz/.zip alternatives, ~/.scout
    # default for unlocated paths) could move the target AFTER
    # authorization, and Open.read decompresses and fixes UTF-8 while
    # Open.write writes raw bytes (read/write asymmetry), breaking the
    # byte-exact contract.  A custom kind "resolve" may return any object;
    # only its String representation is used here.

    def path_read_text(target)
      target = target.to_s
      if File.file?(target)
        File.read(target)
      else
        raise ParameterException, "Path does not exist or is not readable: #{target}"
      end
    end

    def path_write_text(target, content)
      target = target.to_s
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content.to_s)
      content.to_s
    end

    def path_exists?(target)
      File.exist?(target.to_s)
    end

    def path_delete_target(target)
      # A resolved filesystem path is commonly a String, whose #delete
      # removes matching characters rather than the file. Only delegate to
      # a non-String path object that exposes the Path deletion protocol.
      begin
        if !target.is_a?(String) && target.respond_to?(:delete)
          target.delete
        else
          File.delete(target.to_s)
        end
      rescue Errno::ENOENT
        # Deleting a missing target is invalid input, not a system failure.
        # The rescue sits on the actual delete call (not a pre-existence
        # check, which would race) and reuses the engine's uniform
        # "does not exist" contract so the tool wrapper's
        # ScoutException-only rescue can serialize it to the agent.
        raise ParameterException,
              "Path does not exist or is not readable: #{target}"
      end
    end

    # ------------------------------------------------------------------
    # Tool implementations
    # ------------------------------------------------------------------

    def path_kinds(_args = {})
      path_kind_registry.transform_values do |definition|
        {
          "description" => definition["description"],
          "locations" => definition["locations"],
          "default_location" => definition["default_location"],
          "sandbox" => definition["sandbox"],
          "capabilities" => definition["capabilities"]
        }
      end
    end

    def path_read(args)
      kind = path_argument(args, "kind")
      path = path_argument(args, "path")
      location = args["location"]
      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :read)

      {
        "doc_id" => path_doc_id(kind, path, args["version"]),

        "kind" => kind,
        "path" => path,
        "location" => location || path_kind_definition(kind)["default_location"],
        "content" => path_read_text(target)
      }
    end

    def path_write(args)
      kind = path_argument(args, "kind")
      path = path_argument(args, "path")
      content = path_argument(args, "content")
      location = args["location"]

      unless path_kind_capable?(kind, "write")
        raise ParameterException, "Path kind #{kind} does not support write"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      path_write_text(target, content)

      {
        "doc_id" => path_doc_id(kind, path, args["version"]),
        "kind" => kind,
        "path" => path,
        "location" => location || path_kind_definition(kind)["default_location"],
        "written" => true
      }
    end

    # path_edit lives in lib/scout/llm/agent/path/edit.rb
    # (module AgentPathEdit, included above).

    # Generic single-file patch. Applies a unified diff in
    # memory with strict context verification and writes ONCE through
    # the authorized target: no subprocess, no .orig/.rej, no partial
    # writes, no fuzz. Default-off capability; overrides of :content
    # type receive (content, args) with the patch text in args["patch"].
    def path_patch(args)
      kind = path_argument(args, "kind")
      path = path_argument(args, "path")
      patch_text = path_argument(args, "patch")
      location = args["location"]

      unless path_kind_capable?(kind, "patch")
        raise ParameterException, "Path kind #{kind} does not support patch"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      original = path_read_text(target)

      hunks = PathPatch.parse(patch_text)

      override = path_operation_implementation(kind, "patch")
      patched =
        if override
          path_apply_content_handler(override, target, original, args, kind)
        else
          PathPatch.apply(original, hunks).first
        end
      path_write_text(target, patched)

      {
        "doc_id" => path_doc_id(kind, path, args["version"]),
        "kind" => kind,
        "path" => path,
        "changed" => original != patched,
        "content" => patched
      }
    end

    def path_list(args)
      kind = path_argument(args, "kind")
      definition = path_kind_definition(kind)
      location = args["location"] || definition["default_location"]
      prefix = args["path"].to_s
      target = resolve_path(kind, prefix, location)

      path_authorize!(kind, target, location, mode: :read)

      if definition["list"]
        return definition["list"].call(self, prefix, location)
      end

      if roots = definition.fetch('roots', nil)
        root = roots.fetch(location.to_s) do
          raise ParameterException, "No root configured for #{kind} at location #{location}"
        end.to_s
      else
        root = Scout.root.find(:current)
      end
      entries = if target.respond_to?(:glob)
                  target.glob("**/*")
                else
                  base = prefix.empty? ? root : target.to_s
                  Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH)
                    .reject { |entry| File.directory?(entry) }
                end
      # Listing has always returned paths relative to the configured kind root,
      # even when the prefix supplied by the caller is absolute.
      entries.map { |entry| entry.to_s.sub(%r{\A#{Regexp.escape(root)}/?}, "") }.sort
    end

    def path_move(args)
      kind = path_argument(args, "kind")
      source_path = path_argument(args, "path")
      destination = path_argument(args, "destination")
      location = args["location"]

      unless path_kind_capable?(kind, "move")
        raise ParameterException, "Path kind #{kind} does not support move"
      end

      path_relocate(kind, source_path, destination, location)

      {"kind" => kind, "path" => source_path, "destination" => destination, "moved" => true}
    end

    def path_rename(args)
      kind = path_argument(args, "kind")
      source_path = path_argument(args, "path")
      name = path_argument(args, "name")
      location = args["location"]

      unless path_kind_capable?(kind, "rename")
        raise ParameterException, "Path kind #{kind} does not support rename"
      end

      path_relocate(kind, source_path, name, location)

      {"kind" => kind, "path" => source_path, "name" => name, "renamed" => true}
    end

    # Shared same-kind relocation mechanics for path_move and path_rename:
    # resolve BOTH endpoints, authorize both for writing, perform the move.
    # The public wrappers keep their own argument validation, capability
    # errors and result keys.
    private def path_relocate(kind, source_path, target_path, location)
      source = resolve_path(kind, source_path, location)
      target = resolve_path(kind, target_path, location)
      path_authorize!(kind, source, location, mode: :write)
      path_authorize!(kind, target, location, mode: :write)
      path_move_target(source, target)
    end

    def path_delete(args)
      kind = path_argument(args, "kind")
      path = path_argument(args, "path")
      location = args["location"]

      unless path_kind_capable?(kind, "delete")
        raise ParameterException, "Path kind #{kind} does not support delete"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      path_delete_target(target)

      {"kind" => kind, "path" => path, "deleted" => true}
    end

    # The three kind-specific wrapper operations share one body: they only
    # differ in the operation name handed to path_kind_operation.  The
    # generated methods keep the exact names the tools and tests use.
    %w[validate test smoke].each do |operation|
      define_method("path_#{operation}") do |args|
        path_kind_operation(args, operation)
      end
    end

    # ENGINE-CONTROLLED PROMOTION.  The engine resolves the destination from
    # a purely declarative spec, authorizes BOTH endpoints, checks
    # no-clobber, and performs the move itself.  A kind callback is never
    # the writer: the legacy "promote" mover callback is no longer invoked
    # at all, and post-move behavior (if any) hooks through the narrow
    # "promotion_post_move" key, which receives the authorized endpoints in
    # args and runs only after the engine's move completed.
    def path_promote(args)
      kind = path_argument(args, "kind")
      unless path_kind_capable?(kind, "promote")
        raise ParameterException, "Path kind #{kind} does not support promote"
      end

      definition = path_kind_definition(kind)

      location = args["location"] || definition["default_location"]
      path = path_argument(args, "path").to_s
      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      unless path_exists?(target)
        raise ParameterException, "Path does not exist or is not readable: #{target}"
      end

      # The destination is resolved from a DECLARATIVE spec only: a location
      # String, or a Hash with "location" (optional "path", defaulting to
      # the source path).  A Callable form is deliberately NOT accepted: it
      # would have to run before the destination is authorized, so a
      # side-effecting callable could mutate anywhere.
      destination_spec = definition["promotion_destination"]
      destination_spec = {"location" => destination_spec} if destination_spec.is_a?(String)
      destination_spec = {"location" => "project"} if destination_spec.nil?
      unless destination_spec.is_a?(Hash) && destination_spec.key?("location")
        raise ParameterException,
              "Invalid promotion destination for path kind #{kind}: expected a " \
              "location String or a Hash with location"
      end

      destination_location = destination_spec.fetch("location").to_s
      destination_path = (destination_spec["path"] || path).to_s
      destination_target = resolve_path(kind, destination_path, destination_location)
      path_authorize!(kind, destination_target, destination_location, mode: :write)

      overwrite = [true, "true"].include?(args["overwrite"])

      # ADVISORY existence check (TOCTOU): destination_target.exist? here and
      # the actual move below are not one atomic operation.  Concurrent
      # promotion is OUT OF SCOPE BY DECISION: no cross-process locking or
      # exclusive-create/link guard is attempted (none is available without
      # new machinery).  Within a single process the engine's serialized
      # authorize -> check -> move flow is the only writer.
      destination_exists = path_exists?(destination_target)
      if destination_exists && !overwrite
        raise ParameterException,
              "Promotion destination already exists: #{destination_target} " \
              "(pass overwrite to replace it)"
      end

      # The ENGINE performs the move to the authorized destination itself.
      path_move_target(target, destination_target)

      result = {
        "kind" => kind,
        "path" => path,
        "location" => location.to_s,
        "promoted" => true,
        "destination" => {"location" => destination_location, "path" => destination_path},
        "promotion_target" => destination_target.to_s,
        "promotion_source_target" => target.to_s
      }

      post_move = definition["promotion_post_move"]
      if post_move
        hook_args = args.merge(
          "promotion_destination" => result["destination"],
          "promotion_target" => destination_target.to_s,
          "promotion_source_target" => target.to_s,
          "overwrite" => overwrite
        )
        hook_result = post_move.call(self, path, location.to_s, hook_args)
        result = hook_result.merge(result) if hook_result.is_a?(Hash)
      end

      result
    end

    # ------------------------------------------------------------------
    # Kind-specific operations
    # ------------------------------------------------------------------

    def path_kind_operation(args, operation)
      kind = path_argument(args, "kind")
      unless path_kind_capable?(kind, operation)
        raise ParameterException, "Path kind #{kind} does not support #{operation}"
      end

      definition = path_kind_definition(kind)
      implementation = definition[operation]
      raise ParameterException, "Path kind #{kind} has no #{operation} implementation" unless implementation

      location = args["location"] || definition["default_location"]
      target = resolve_path(kind, path_argument(args, "path").to_s, location)
      path_authorize!(kind, target, location, mode: :read)

      implementation.call(
        self,
        path_argument(args, "path").to_s,
        (args["location"] || definition["default_location"]).to_s,
        args
      )
    end

    def path_move_target(source, destination)
      FileUtils.mkdir_p(File.dirname(destination.to_s))
      FileUtils.mv(source.to_s, destination.to_s)
    end
  end
end
