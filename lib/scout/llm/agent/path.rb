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
# optionally supplies kind-specific operations such as validation, smoke,
# or promotion.
#
# Path plugins are loaded in the context of an Agent instance, so a plugin
# file can simply call `register_path_kind`; registration is agent-local
# (there is no class-wide registry).

require "fileutils"
require_relative "../sandbox"
require_relative "path/patch"
require_relative "path/edit"
require_relative "path/workflow_kinds"

module LLM
  class Agent
    include AgentPathEdit
    include AgentPathWorkflowKinds
    DEFAULT_CAPABILITIES = {
      "read" => true,
      "write" => true,
      "edit" => true,
      "list" => true,
      "move" => true,
      "rename" => true,
      "delete" => true,
      "validate" => false,
      "promote" => false,
      "smoke" => false,
      "patch" => false
    }.freeze

    GENERIC_OPERATIONS = %w[
        read write edit list move rename delete
    ].freeze

    SPECIAL_OPERATIONS = %w[
        validate promote smoke patch
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
      unless Hash === definition
        raise ParameterException, "Path kind definition must be a mapping"
      end

      definition = definition.dup
      definition["name"] = name
      definition["sandbox"] = true unless definition.key?("sandbox")
      unless [true, false].include?(definition["sandbox"])
        raise ParameterException, "Path kind sandbox setting must be boolean"
      end
      definition["description"] ||= "#{name} path"

      definition["locations"] ||= ["project"]
      path_validate_locations!(definition)

      # Scout path maps: normalize an optional per-kind "path_map" key, then
      # pin NON-absolute roots against the effective map (the kind's map,
      # else the agent-level path_map option, else :current) BEFORE the
      # absolute-root validation. Absolute roots pass through untouched.
      definition.delete("path_map") if definition["path_map"].nil?
      unless definition["path_map"].nil?
        definition["path_map"] =
          path_map_validate!(definition["path_map"], "Path kind #{name.inspect} path_map")
      end
      effective_path_map = path_kind_effective_map(definition)
      path_pin_roots!(definition, effective_path_map)

      path_validate_roots!(definition)

      capabilities = definition.fetch("capabilities", {})
      if Array === capabilities
        unless capabilities.all? { |operation| String === operation || Symbol === operation }
          raise ParameterException, "Path kind capabilities must name built-in operations"
        end
        capabilities = capabilities.each_with_object({}) do |operation, hash|
          hash[operation.to_s] = true
        end
      elsif Hash === capabilities
        capabilities = capabilities.each_with_object({}) do |(operation, enabled), hash|
          unless String === operation || Symbol === operation
            raise ParameterException, "Path kind capability names must be strings or symbols"
          end
          operation = operation.to_s
          unless BUILT_IN_OPERATIONS.include?(operation)
            raise ParameterException, "Unknown Path kind capability #{operation.inspect}"
          end
          unless [true, false].include?(enabled)
            raise ParameterException, "Path kind capability #{operation.inspect} must be boolean"
          end
          hash[operation] = enabled
        end
      else
        raise ParameterException, "Path kind capabilities must be an Array or mapping"
      end
      capabilities.each_key do |operation|
        unless BUILT_IN_OPERATIONS.include?(operation)
          raise ParameterException, "Unknown Path kind capability #{operation.inspect}"
        end
      end
      definition["capabilities"] = DEFAULT_CAPABILITIES.merge(capabilities)

      default_location = definition["default_location"]
      default_location = definition["locations"].first if default_location.nil?
      unless String === default_location && definition["locations"].include?(default_location)
        raise ParameterException,
          "Default location #{default_location.inspect} is not included in locations for #{name}"
      end
      definition["default_location"] = default_location

      path_validate_kind_hooks!(definition)
      path_validate_promotion_destination!(definition)
      definition["operations"] = path_normalize_custom_operations(definition)
      definition["overrides"] = path_normalize_operation_overrides(definition)

      definition["operation_table"] =
        path_operation_table(definition["capabilities"],
                             definition["operations"],
                             definition["overrides"])

      had_registry = instance_variable_defined?(:@path_kinds)
      registry = path_kind_registry
      had_previous_kind = registry.key?(name)
      previous_kind = registry[name]
      had_options = instance_variable_defined?(:@other_options)
      previous_options = @other_options if had_options
      previous_tools_present = previous_options.is_a?(Hash) && previous_options.key?(:tools)
      previous_tools = previous_options[:tools] if previous_tools_present
      previous_tool_entries = previous_tools.dup if previous_tools.is_a?(Hash)

      registry[name] = definition
      begin
        install_path_tools
      rescue Exception
        # Restore the exact prior registration and installed tool entries. The
        # installation routine updates the tool Hash incrementally, so merely
        # deleting the candidate kind would leave stale/partial tool schemas.
        if had_previous_kind
          registry[name] = previous_kind
        else
          registry.delete(name)
        end
        remove_instance_variable(:@path_kinds) unless had_registry

        if had_options
          @other_options = previous_options
          if previous_options.is_a?(Hash)
            if previous_tools_present
              if previous_tools.is_a?(Hash) && previous_tool_entries
                previous_tools.replace(previous_tool_entries)
              end
              previous_options[:tools] = previous_tools
            else
              previous_options.delete(:tools)
            end
          end
        elsif instance_variable_defined?(:@other_options)
          remove_instance_variable(:@other_options)
        end
        raise
      end
      definition
    end

    # Validate declared location names before any registry or tool mutation.
    def path_validate_locations!(definition)
      locations = definition["locations"]
      unless Array === locations && !locations.empty? &&
             locations.all? { |location| String === location && !location.empty? } &&
             locations.uniq.length == locations.length
        raise ParameterException,
          "Path kind locations must be a nonempty Array of unique, nonempty Strings"
      end
    end

    # ------------------------------------------------------------------
    # Scout path maps for kind roots
    # ------------------------------------------------------------------
    # A NON-absolute (relative/unlocated) root would otherwise be carried
    # as a logical Scout path and re-resolved later (Path#find on a missing
    # target falls back through Scout's map_order to :user, i.e. ~/.scout).
    # The map declared here (per kind, else the agent-level :path_map
    # option, else :current) is applied ONCE at registration and the result
    # is pinned to an absolute String, so the filesystem boundary
    # (plain File.* on target.to_s) can never re-resolve.
    DEFAULT_PATH_MAP = :current

    # The agent-level default map, an option on this Agent instance:
    #   LLM.agent(path_map: :lib) { ... }
    def path_map_option
      raw = @other_options.key?(:path_map) ? @other_options[:path_map] : nil
      raw = nil if raw.to_s.empty?
      raw.nil? ? DEFAULT_PATH_MAP : path_map_validate!(raw, "Agent path_map option")
    end

    # Effective map for one kind: the kind's own "path_map" key wins, then
    # the agent-level default. Returns a Symbol.
    def path_kind_effective_map(definition)
      map = definition["path_map"]
      map = path_map_option if map.nil?
      Symbol === map ? map : map.to_s.to_sym
    end

    # A map must be a String or Symbol naming a resolvable Scout path map.
    # Instance maps (Path.add_path / per-PATH maps) and the global
    # Path.path_maps table are both accepted; anything else raises the
    # framework's parameter error.
    def path_map_validate!(map, label)
      unless String === map || Symbol === map
        raise ParameterException,
          "#{label} must be a String or Symbol naming a Scout path map"
      end
      name = map.to_s.to_sym
      begin
        Scout.root.follow(name)
      rescue StandardError => error
        raise ParameterException,
          "#{label} is not a resolvable Scout path map: #{map.inspect} " \
          "(#{error.class}: #{error.message.split("\n").first.strip[0, 120]})"
      end
      name
    end

    # Pin every NON-absolute root of the definition against the effective
    # map and store it back as an absolute String. Absolute roots (Strings
    # or Path-likes) pass through untouched, so kinds that already resolve
    # to absolute roots keep their current placement (compatibility rule).
    def path_pin_roots!(definition, effective_map)
      roots = definition["roots"]
      return unless Hash === roots

      roots.each_pair do |location, root|
        next if root.to_s.start_with?(File::SEPARATOR)

        root = Path.setup(root.to_s)
        begin
          pinned = root.follow(effective_map)
        rescue StandardError => error
          raise ParameterException,
            "Path kind #{definition['name'].inspect} root for location #{location.inspect} " \
            "could not be resolved against path map #{effective_map.inspect}: " \
            "#{error.class}: #{error.message.split("\n").first.strip[0, 120]}"
        end
        pinned = pinned.to_s
        unless pinned.start_with?(File::SEPARATOR)
          raise ParameterException,
            "Path kind #{definition['name'].inspect} root for location #{location.inspect} " \
            "did not resolve to an absolute path through map #{effective_map.inspect}"
        end
        roots[location] = pinned
      end
    end

    # Roots are authorization grants. Every declared location needs a root,
    # except the long-standing implicit project root used by resolve_path and
    # path_authorize! when no explicit project root is supplied.
    def path_validate_roots!(definition)
      roots = definition.fetch("roots", {})
      unless Hash === roots
        raise ParameterException, "Path kind roots must be a mapping"
      end
      roots.each_pair do |location, root|
        unless String === location && !location.empty?
          raise ParameterException,
            "Path kind root location names must be nonempty Strings"
        end
        path_validate_root!(location, root)
      end

      definition["locations"].each do |location|
        next if roots.key?(location)
        next if location == "project"

        raise ParameterException,
          "Path kind #{definition['name']} has no root configured for location #{location}"
      end

      if definition["locations"].include?("project") && !roots.key?("project")
        begin
          path_validate_root!("project", Scout.root.find(path_kind_effective_map(definition)))
        rescue ParameterException
          raise
        rescue StandardError => error
          raise ParameterException,
            "Path kind implicit project root is unavailable: #{error.message}"
        end
      end
    end

    def path_validate_root!(location, root)
      root_string = root.to_s
      scout_path = root.respond_to?(:to_path) ||
                   (defined?(Path) && Path === root)
      unless !root_string.empty? && root_string.start_with?(File::SEPARATOR) &&
             (String === root || scout_path)
        raise ParameterException,
          "Path kind root for location #{location.inspect} must be a nonempty absolute path " \
          "or an absolute Scout Path-like object"
      end
    end

    def path_validate_kind_hooks!(definition)
      %w[resolve list validate smoke promotion_post_move].each do |hook|
        next unless definition.key?(hook)
        unless definition[hook].respond_to?(:call)
          raise ParameterException, "Path kind #{hook} hook must be Callable"
        end
      end
    end

    # Promotion destinations are resolved and authorized by the engine, so
    # only the documented declarative forms may be stored in a kind.
    def path_validate_promotion_destination!(definition)
      destination = definition["promotion_destination"]
      if destination.nil?
        # The implicit project destination matters only when promotion is
        # enabled; non-promotable kinds need not declare an unused location.
        return unless definition["capabilities"].fetch("promote", false)
        location = "project"
        unless definition["locations"].include?(location)
          raise ParameterException,
            "Invalid promotion destination for path kind #{definition['name']}: default project location is not declared"
        end
        return
      end

      if String === destination
        unless definition["locations"].include?(destination)
          raise ParameterException,
            "Invalid promotion destination for path kind #{definition['name']}: location #{destination.inspect} is not declared"
        end
        return
      end

      unless Hash === destination && destination.key?("location") &&
             (destination.keys - %w[location path]).empty?
        raise ParameterException,
          "Invalid promotion destination for path kind #{definition['name']}: expected a location String or a Hash with location and optional path"
      end
      location = destination["location"]
      unless String === location && definition["locations"].include?(location)
        raise ParameterException,
          "Invalid promotion destination for path kind #{definition['name']}: location #{location.inspect} is not declared"
      end
      if destination.key?("path") && !(String === destination["path"])
        raise ParameterException,
          "Invalid promotion destination for path kind #{definition['name']}: path must be a String"
      end
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
      operations = definition["operations"]
      operations = {} if operations.nil?
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
        unless Hash === spec
          raise ParameterException,
            "Custom operation #{name.inspect} must be a Callable or a spec Hash"
        end

        implementation = spec["implementation"]
        unless implementation.respond_to?(:call)
          raise ParameterException,
            "Custom operation #{name.inspect} requires an implementation Callable"
        end

        authorization = spec["authorization"]
        authorization = :write if authorization.nil?
        unless String === authorization || Symbol === authorization
          raise ParameterException,
            "Custom operation #{name.inspect} authorization must be a String or Symbol"
        end
        authorization = authorization.to_sym
        unless PATH_AUTHORIZATION_MODES.include?(authorization)
          raise ParameterException,
            "Custom operation #{name.inspect} authorization must be one of " \
            "#{PATH_AUTHORIZATION_MODES.map(&:inspect).join(', ')}; got " \
            "#{authorization.inspect}"
        end

        handler = spec["type"]
        handler = :full if handler.nil?
        unless String === handler || Symbol === handler
          raise ParameterException,
            "Custom operation #{name.inspect} type must be a String or Symbol"
        end
        handler = handler.to_sym
        unless PATH_HANDLER_TYPES.include?(handler)
          raise ParameterException,
            "Custom operation #{name.inspect} type must be one of " \
            "#{PATH_HANDLER_TYPES.map(&:inspect).join(', ')}; got #{handler.inspect}"
        end

        parameters = spec["parameters"]
        parameters = {} if parameters.nil?
        unless Hash === parameters
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
      overrides = definition["overrides"]
      overrides = {} if overrides.nil?
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
        implementation = spec["implementation"] if Hash === spec
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
                          its supported locations and operations. Supply kind to return
                          only that kind's entry.
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
        path_map = args["path_map"] || DEFAULT_PATH_MAP
        target = resolve_path(kind, path, location, path_map)
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
      when "list"
        # `path` is optional for list: an omitted path lists the kind root,
        # a relative subdirectory lists that subtree.  The parameter keeps
        # the base spelling; only its description is specialized here.
        properties["path"]["description"] =
          "Optional subdirectory within the selected kind; omit to list the kind root."
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
      when "validate"
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
    def resolve_path(kind, path, location = nil, path_map = DEFAULT_PATH_MAP)
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
        root = roots.fetch(location.to_s) { Scout.root.find(path_kind_effective_map(definition)) }
      else
        root = roots.fetch(location.to_s) do
          raise ParameterException,
            "No root configured for #{kind} at location #{location}"
        end
      end

      root = root.sub('BASEDIR', File.basename(Dir.pwd))

      # A Scout Path-like root may implement [] for child paths. Otherwise
      # use ordinary filesystem paths.
      # Absolute filesystem paths address their exact target. Authorization
      # below still limits them to the configured location root.
      return path.to_s if root.is_a?(String) && path.to_s.start_with?(File::SEPARATOR)

      final_path = if Path === root
                     root[path.to_s]
                   else
                     Path.setup(File.join(root.to_s, path.to_s))
                   end

      if definition["extension"]
        final_path = final_path.set_extension(definition["extension"])
      end

      final_path.find(path_map)
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
               Scout.root.find(path_kind_effective_map(definition))
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

    # Root selectors are an ENUMERATION surface only: an empty string, "."
    # and "./" all address the kind ROOT as a whole, not one file within it.
    # Every file-shaped built-in calls this guard with its own tool name so
    # the rejection names the operation that received the bad value and
    # points at the enumeration surface (path_list).  path_list itself is
    # NOT guarded: it normalizes a root selector to the empty prefix
    # instead.  path_dispatch is not guarded either: custom operations own
    # their path grammar and may legitimately receive ".".
    ROOT_SELECTOR_PATHS = ["", ".", "./"].freeze

    def path_reject_root_selector!(operation, path)
      value = path.to_s
      return value unless ROOT_SELECTOR_PATHS.include?(value)

      raise ParameterException,
            "Invalid path for #{operation}: #{value.inspect} addresses the " \
            "kind root; use a path relative to the root, or path_list to " \
            "enumerate the root"
    end

    # path_list's counterpart to the guard above: instead of rejecting a
    # root selector it maps it onto the empty prefix, which lists the whole
    # kind root.
    def path_root_selector_normalize(path)
      value = path.to_s
      ROOT_SELECTOR_PATHS.include?(value) ? "" : value
    end

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

    def path_kinds(args = {})
      kind = args["kind"]
      registry = path_kind_registry
      unless kind.nil? || kind.to_s.empty?
        kind = kind.to_s
        unless registry.key?(kind)
          raise ParameterException,
                "Unknown path kind: #{kind} (available: #{registry.keys.sort.join(', ')})"
        end

        return {kind => path_kind_registry_entry(registry.fetch(kind))}
      end

      path_kind_registry.transform_values { |definition| path_kind_registry_entry(definition) }
    end

    def path_kind_registry_entry(definition)
      {
        "description" => definition["description"],
        "locations" => definition["locations"],
        "default_location" => definition["default_location"],
        "sandbox" => definition["sandbox"],
        "capabilities" => definition["capabilities"]
      }
    end

    def path_read(args)
      kind = path_argument(args, "kind")
      path = path_reject_root_selector!("path_read", path_argument(args, "path"))
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
      path = path_reject_root_selector!("path_write", path_argument(args, "path"))
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
        "target_file" => target,
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
      path = path_reject_root_selector!("path_patch", path_argument(args, "path"))
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
      # A root selector (".", "./", or an empty prefix) addresses the kind
      # ROOT itself; normalize it to the empty prefix so listing falls into
      # the root branch below instead of resolving a bogus file target.
      prefix = path_root_selector_normalize(args["path"])
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
        root = Scout.root.find(path_kind_effective_map(definition))
      end
      # H4 hardening: the target is always a plain absolute String here
      # (resolve_path returns root[path] and every registered root is pinned
      # absolute at registration), so go straight to Dir.glob on the pinned
      # String. Path#glob on an unlocated logical path would resolve through
      # Scout's map_order and could reach :user; Dir.glob never re-resolves.
      base = prefix.empty? ? root : target.to_s
      entries = Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH)
                     .reject { |entry| File.directory?(entry) }
      # Listing has always returned paths relative to the configured kind root,
      # even when the prefix supplied by the caller is absolute.
      entries.map { |entry| entry.to_s.sub(%r{\A#{Regexp.escape(root)}/?}, "") }.sort
    end

    def path_move(args)
      kind = path_argument(args, "kind")
      source_path = path_reject_root_selector!("path_move", path_argument(args, "path"))
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
      source_path = path_reject_root_selector!("path_rename", path_argument(args, "path"))
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
      path = path_reject_root_selector!("path_delete", path_argument(args, "path"))
      location = args["location"]

      unless path_kind_capable?(kind, "delete")
        raise ParameterException, "Path kind #{kind} does not support delete"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      path_delete_target(target)

      {"kind" => kind, "path" => path, "deleted" => true}
    end

    # The kind-specific wrapper operations share one body: they only
    # differ in the operation name handed to path_kind_operation.  The
    # generated methods keep the exact names the tools and tests use.
    %w[validate smoke].each do |operation|
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
      path = path_reject_root_selector!("path_promote", path_argument(args, "path"))
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
      path = path_reject_root_selector!("path_#{operation}", path_argument(args, "path"))
      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :read)

      implementation.call(
        self,
        path,
        location.to_s,
        args
      )
    end

    def path_move_target(source, destination)
      FileUtils.mkdir_p(File.dirname(destination.to_s))
      FileUtils.mv(source.to_s, destination.to_s)
    end
  end
end
