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

module LLM
  class Agent
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

    # Handler types a custom operation implementation may declare (Step 3
    # stores them; dispatch semantics are Step 5):
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

    def path(_options = {})
      install_path_tools
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
      definition["capabilities"] = DEFAULT_CAPABILITIES.merge(
        begin
          capabilities = definition.fetch("capabilities", {})
          if Array === capabilities
            hash = {}
            capabilities.each{|c| hash[c] = true }
            hash
          else
            capabilities
          end
        end
      )
      definition["locations"] ||= ["project"]
      definition["default_location"] ||= definition["locations"].first

      definition["operations"] = path_normalize_custom_operations(definition)
      definition["overrides"] = path_normalize_operation_overrides(definition)

      unless definition["locations"].include?(definition["default_location"])
        raise ParameterException,
          "Default location #{definition['default_location'].inspect} " \
          "is not included in locations for #{name}"
      end

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

    def register_path_kinds(definitions)
      definitions.each do |name, definition, block=nil|
        register_path_kind(name, definition, &block)
      end
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

    def path_kind_capable?(kind, operation)
      definition = path_kind_definition(kind)
      !!definition.fetch("capabilities", {}).fetch(operation.to_s, false)
    end

    # ------------------------------------------------------------------
    # Operation registration contract (Step 3)
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
    # Operation registry queries (Step 3)
    # ------------------------------------------------------------------

    # Does this kind support the operation?  True for built-ins enabled by
    # the kind's capabilities; true for custom operations registered on the
    # kind (support is established by registration, no capability flag);
    # false otherwise (including disabled validate/test/promote/smoke and
    # unknown operations).
    def path_operation_support?(kind, operation)
      operation = operation.to_s
      definition = path_kind_definition(kind)

      return true if definition.fetch("overrides", {}).key?(operation)

      if BUILT_IN_OPERATIONS.include?(operation)
        !!definition.fetch("capabilities", {}).fetch(operation, false)
      else
        definition.fetch("operations", {}).key?(operation)
      end
    end

    # Does this kind OVERRIDE the built-in implementation of this operation?
    # (Implementation replacement only: the public schema stays engine-owned
    # and capability gating is not bypassed.)
    def path_operation_override?(kind, operation)
      path_kind_definition(kind).fetch("overrides", {}).key?(operation.to_s)
    end

    # Sorted names of custom operations registered anywhere in THIS agent's
    # registry (agent-local by construction).
    def path_custom_operations
      path_kind_registry.values.flat_map { |definition| definition.fetch("operations", {}).keys }.uniq.sort
    end

    # The normalized custom-operation spec for kind/operation, or nil.
    def path_custom_operation(kind, operation)
      path_kind_definition(kind).fetch("operations", {}).fetch(operation.to_s, nil)
    end

    # Authorization mode that applies to an operation for a kind:
    #   - custom operations: their registered mode (fail-closed :write
    #     default when unspecified);
    #   - built-ins: the engine's existing mode mapping (read/list => :read;
    #     write/edit/move/rename/delete/promote => :write);
    #   - nil for unsupported operations.
    def path_operation_authorization(kind, operation)
      operation = operation.to_s
      return nil unless path_operation_support?(kind, operation)

      custom = path_custom_operation(kind, operation)
      return custom["authorization"] if custom

      case operation
      when "read", "list"
        :read
      else
        :write
      end
    end

    # Implementation selection: an override beats the engine default for
    # built-ins; custom operations return their registered callable.  Nil
    # when the operation is unsupported (custom with no engine default).
    def path_operation_implementation(kind, operation)
      operation = operation.to_s
      definition = path_kind_definition(kind)
      return nil unless path_operation_support?(kind, operation)

      override = definition.fetch("overrides", {}).fetch(operation, nil)
      return override["implementation"] if override

      custom = definition.fetch("operations", {}).fetch(operation, nil)
      return custom["implementation"] if custom

      nil
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

    def install_path_tools
      install = method(:path_install_tool)

      return if path_kind_registry.empty?
      install.call("path_kinds", path_kinds_tool_definition)
      GENERIC_OPERATIONS.each do |operation|
        next unless path_kind_registry.values.any? do |definition|
          definition.fetch("capabilities", {}).fetch(operation, false)
        end

        install.call("path_#{operation}", path_tool_definition(operation))
      end

      SPECIAL_OPERATIONS.each do |operation|
        next unless path_kind_registry.values.any? do |definition|
          definition.fetch("capabilities", {}).fetch(operation, false)
        end

        install.call("path_#{operation}", path_tool_definition(operation))
      end

      path_custom_operations.each do |operation|
        install.call(operation, path_custom_tool_definition(operation))
      end
    end

    # ------------------------------------------------------------------
    # Custom-operation tool aggregation (Step 4)
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

      properties = {
        "kind" => {
          "type" => "string",
          "description" => "Kind of path. Supported kinds: #{kinds.join(', ')}.",
          "enum" => kinds
        },
        "path" => {
          "type" => "string",
          "description" => "Path within the selected kind."
        },
        "location" => {
          "type" => "string",
          "description" => "Storage location; defaults to the kind's default location."
        }
      }

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
        # single engine dispatch entry point (implemented in Step 5).
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

      left_keys = path_contract_keys(left)
      right_keys = path_contract_keys(right)

      (left_keys - right_keys).each do |key|
        differences << "#{where}.#{key} present only in the first contract"
      end
      (right_keys - left_keys).each do |key|
        differences << "#{where}.#{key} present only in the second contract"
      end

      (left_keys & right_keys).each do |key|
        l = path_contract_value(left, key)
        r = path_contract_value(right, key)

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
                elsif !path_contract_equal?(lv, rv)
                  differences << "#{where}.#{key}[#{i}] differs: #{lv.inspect} vs #{rv.inspect}"
                end
              end
            end
          elsif !path_contract_equal?(l, r)
            differences << "#{where}.#{key} differs: #{l.inspect} vs #{r.inspect}"
          end
        end
      end

      differences
    end

    def path_contract_keys(hash)
      (hash.respond_to?(:keys) ? hash.keys : []).map(&:to_s)
    end

    def path_contract_value(hash, key)
      hash.each_pair do |k, v|
        return v if k.to_s == key.to_s
      end
      nil
    end

    # Scalar equality under contract rules: required/enum become sets.
    def path_contract_equal?(left, right)
      return true if left == right
      false
    end

    # Store tools in the same [callable, definition] format consumed by Agent#ask.
    # When +definition+ carries an "implementation" key, that callable is used
    # instead of public_send(name); custom-operation tools use this to route
    # through the engine dispatch entry point (Step 5 fills the dispatch in).
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
    # Centralized dispatch entry point (stub in Step 4; Step 5 implements)
    # ------------------------------------------------------------------

    # Single engine entry point for CUSTOM operations.  Step 4 installs the
    # aggregated tool callables that route here; Step 5 fills in the real
    # dispatch: per-kind capability gate, authorization mode, :content vs
    # :full handler semantics, override selection for built-ins.
    #
    # Contract (frozen here, implemented in Step 5):
    #   kind       - String kind name; must be registered
    #   operation  - String custom operation name
    #   args       - the remaining tool arguments as a Hash (string keys)
    # Raises ParameterException for unknown kind/operation, unsupported
    # combination, or (until Step 5) any custom dispatch attempt.
    # Central dispatcher (Step 5).  Every custom operation flows through
    # here; built-in tools keep calling their engine methods directly, and
    # those methods share the same funnel (resolve -> capability ->
    # authorize -> implement) inside themselves.
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

      unless path_operation_support?(kind, operation)
        raise ParameterException,
          "Path kind #{kind.inspect} does not support operation #{operation.inspect}"
      end

      custom = path_custom_operation(kind, operation)

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

    def path_kinds_tool_definition
      {
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
        }
      }
    end

    def path_tool_definition(operation)
      kinds = path_kind_registry.keys
      kind_description = if kinds.empty?
                           "No Path kinds are currently registered."
                         else
                           "Supported kinds: #{kinds.join(', ')}."
                         end

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

      if operation != "list"
        properties["location"] = {
          "type" => "string",
          "description" => "Storage location; defaults to the kind's default location."
        }
      end

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

      definition = {
        "description" => path_operation_description(operation),
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

    def path_operation_description(operation)
      case operation
      when "read"
        "Read the textual content of a virtual Path."
      when "write"
        "Write complete textual content to a virtual Path."
      when "edit"
        "Edit a textual Path using a line range, character range, or regular expression selector."
      when "list"
        "List paths in a virtual Path kind, optionally below a prefix."
      when "move"
        "Move a virtual Path to another path in the same kind and location."
      when "rename"
        "Rename a virtual Path."
      when "delete"
        "Delete a virtual Path."
      when "validate"
        "Run the kind-specific syntax or validity check for a virtual Path."
      when "test"
        "Run the kind-specific integration test for a virtual Path."
      when "smoke"
        "Run the kind-specific lightweight smoke check for a virtual Path."
      when "promote"
        "Promote a virtual Path from its temporary location to its project location."
      when "patch"
        "Apply a single-file unified diff to a virtual Path in memory and " \
        "write it back atomically (no fuzz, no side files)."
      else
        "Operate on a virtual Path."
      end
    end

    # ------------------------------------------------------------------
    # Path resolution
    # ------------------------------------------------------------------

    # Resolves a virtual path to the underlying Scout/File path.
    #
    # A kind can provide `resolve`, which receives `(agent, path, location)`
    # and may return any object implementing the small textual interface used
    # below. Otherwise `roots` are treated as filesystem roots.
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

    # Selector keys are validated the same way as tool arguments.
    def path_selector_key(selector, key)
      selector.fetch(key) do
        raise ParameterException, "Invalid selector: missing key #{key.inspect}"
      end
    end

    # Selector indexes (lines/chars start/end, regexp pattern) must be
    # validated, not just presence-checked: a nil or string-valued index
    # would otherwise raise NoMethodError/ArgumentError deep inside the
    # comparison, escaping path_install_tool's ScoutException-only rescue
    # so the agent never sees it.  Everything invalid surfaces as
    # ParameterException at the point it occurs, BEFORE any mutation.
    def path_selector_index(selector, key, length: nil, maximum: nil)
      value = path_selector_key(selector, key)
      unless value.is_a?(Integer)
        raise ParameterException,
              "Invalid selector: #{key.inspect} must be an integer, got #{value.inspect}"
      end
      raise ParameterException,
            "Invalid selector: #{key.inspect} must be >= 0, got #{value}" if value.negative?

      if length && key == "end" && value > length
        # Exclusive-end clamping is deliberate and documented: an end
        # beyond the document is the same as "to the end of the document".
        value = length
      elsif length && key == "start" && value > length
        raise ParameterException,
              "Invalid selector: #{key.inspect} #{value} is beyond the last index #{length}"
      end

      value
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

    def path_read_text(target)
      if target.respond_to?(:read)
        target.read.to_s
      elsif File.file?(target.to_s)
        File.read(target.to_s)
      else
        raise ParameterException, "Path does not exist or is not readable: #{target}"
      end
    end

    def path_write_text(target, content)
      if target.respond_to?(:write)
        target.write(content.to_s)
      else
        FileUtils.mkdir_p(File.dirname(target.to_s))
        File.write(target.to_s, content.to_s)
      end
      content.to_s
    end

    def path_exists?(target)
      if target.respond_to?(:exist?)
        target.exist?
      else
        File.exist?(target.to_s)
      end
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

    def path_edit(args)
      kind = path_argument(args, "kind")
      path = path_argument(args, "path")
      selector = path_argument(args, "selector")
      replacement = path_argument(args, "replacement")
      location = args["location"]

      unless path_kind_capable?(kind, "edit")
        raise ParameterException, "Path kind #{kind} does not support edit"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      original = path_read_text(target)

      override = path_operation_implementation(kind, "edit")
      if override
        edited = path_apply_content_handler(
          override, target, original, args, kind
        )
      else
        edited = path_apply_selector(original, selector, replacement)
      end
      path_write_text(target, edited)

      {
        "doc_id" => path_doc_id(kind, path, args["version"]),
        "kind" => kind,
        "path" => path,
        "changed" => original != edited,
        "content" => edited
      }
    end

    # Generic single-file patch (Step 6). Applies a unified diff in
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
      location = args["location"] || path_kind_definition(kind)["default_location"]
      prefix = args["path"].to_s
      target = resolve_path(kind, prefix, location)

      definition = path_kind_definition(kind)
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

      source = resolve_path(kind, source_path, location)
      target = resolve_path(kind, destination, location)
      path_authorize!(kind, source, location, mode: :write)
      path_authorize!(kind, target, location, mode: :write)
      path_move_target(source, target)


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

      source = resolve_path(kind, source_path, location)
      target = resolve_path(kind, name, location)
      path_authorize!(kind, source, location, mode: :write)
      path_authorize!(kind, target, location, mode: :write)
      path_move_target(source, target)


      {"kind" => kind, "path" => source_path, "name" => name, "renamed" => true}
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

    def path_validate(args)
      path_kind_operation(args, "validate")
    end

    def path_test(args)
      path_kind_operation(args, "test")
    end

    def path_smoke(args)
      path_kind_operation(args, "smoke")
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
      destination_exists =
        if destination_target.respond_to?(:exist?)
          destination_target.exist?
        else
          File.exist?(destination_target.to_s)
        end
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
    # Selectors
    # ------------------------------------------------------------------

    def path_apply_selector(content, selector, replacement)
      unless selector.respond_to?(:fetch)
        raise ParameterException,
          "Invalid selector: expected a mapping with type lines, chars, or regexp"
      end
      type = path_selector_key(selector, "type").to_s

      case type
      when "regexp"
        pattern_value = path_selector_key(selector, "pattern")
        unless pattern_value.is_a?(String)
          # A non-String pattern would raise TypeError inside Regexp.new,
          # escaping path_install_tool's ScoutException-only rescue so the
          # agent never sees it; invalid input surfaces as ParameterException.
          raise ParameterException,
                "Invalid selector: pattern must be a String, got #{pattern_value.inspect}"
        end
        pattern =
          begin
            Regexp.new(pattern_value)
          rescue RegexpError => e
            # NARROW rescue at the Regexp.new call site only: a malformed
            # pattern is an invalid input, and must surface as
            # ParameterException (ScoutException subclass) so the tool
            # wrapper's rescue can serialize it to the agent.
            raise ParameterException,
                  "Invalid selector: malformed regexp pattern " \
                  "#{path_selector_key(selector, "pattern").inspect}: #{e.message}"
          end
        content.sub(pattern, replacement.to_s)
      when "chars"
        start = path_selector_index(selector, "start")
        finish = path_selector_index(selector, "end", length: content.length)
        raise ParameterException, "Character range must satisfy start <= end" if start > finish

        content.dup.tap do |text|
          text[start...finish] = replacement.to_s
        end
      when "lines"
        # Explicit line semantics (see "Selector semantics" in tmp/path_recon.md):
        # - indexes are 0-based; "start".."end" is an EXCLUSIVE-end line range
        # - a line includes its terminator; the final line may lack one
        # - the replacement's content substitutes for the selected lines'
        #   content; untouched lines are byte-identical
        # - the final newline of the file is preserved IFF it existed before
        # - DECISION: start == lines.length (insertion-at-end) is ALLOWED and
        #   appends after the last line; start > lines.length raises
        #   ParameterException.  An "end" beyond the document clamps to the
        #   document end (so the append form is start=length, end>length).
        lines = content.lines
        start = path_selector_index(selector, "start", length: lines.length)
        finish = path_selector_index(selector, "end", length: lines.length)
        raise ParameterException, "Line range must satisfy start <= end" if start > finish

        # Rebuild keeping untouched lines byte-identical: lines before the
        # span, the replacement text, and lines after the span.
        head = lines[0...start]
        tail = lines[finish..] || []
        body = replacement.to_s

        # Terminal-newline normalization is BIDIRECTIONAL at the EOF
        # boundary: when the replaced span reaches EOF the result's
        # final-newline state must match the ORIGINAL document's, whatever
        # the replacement's trailing newline looks like (a replacement
        # ending in "\n" must NOT introduce a final newline the original
        # lacked).  When a line follows the span (interior boundary) the
        # replacement is terminated with exactly one newline.  tail is
        # empty exactly when the span reaches EOF.
        eof_span = finish >= lines.length
        final_newline = content.end_with?("\n")
        new_span =
          if body.empty?
            # Deleting the span leaves nothing; no stray terminator is
            # reintroduced by the EOF normalization below.
            ""
          elsif !eof_span || final_newline
            # Interior boundary, or EOF where the original ended with a
            # newline: exactly one terminal newline (appended when
            # missing, collapsed when repeated).
            body.sub(/\n*\z/, "\n")
          else
            # EOF boundary and the original lacked a final newline: strip
            # every trailing newline the replacement may carry.
            body.sub(/\n+\z/, "")
          end

        joined = (head + [new_span] + tail).join
        # The EOF boundary inherits the original document's final-newline
        # state, including the empty-replacement case where only head
        # lines remain (deleting the last line of a file that had no
        # final newline must not add one).
        joined = joined.sub(/\n+\z/, "") if eof_span && !final_newline
        joined
      else
        raise ParameterException,
          "Unknown selector type #{type.inspect}; expected lines, chars, or regexp"
      end
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
      if source.respond_to?(:move)
        source.move(destination)
      else
        FileUtils.mkdir_p(File.dirname(destination.to_s))
        FileUtils.mv(source.to_s, destination.to_s)
      end
    end
  end
end
