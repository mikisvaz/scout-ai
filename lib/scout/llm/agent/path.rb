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
# file can simply call `register_path_kind`.

require "fileutils"
require_relative "../sandbox"

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
      "promote" => false
    }.freeze

    GENERIC_OPERATIONS = %w[
        read write edit list move rename delete
    ].freeze

    SPECIAL_OPERATIONS = %w[
        validate test promote
    ].freeze

    PATH_KINDS = {}
    def self.register_path_kind(name, definition, block = nil)
      PATH_KINDS[name] = [definition, block]
    end

    def path(options = {})
      install_path_tools
      register_path_kinds(PATH_KINDS.collect{|*p| p.flatten})
    end

    # ------------------------------------------------------------------
    # Registry
    # ------------------------------------------------------------------

    # Agent-local registry.  This deliberately remains a plain Hash so
    # workflows/agent definitions can inspect or modify it without another
    # abstraction layer.
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

      unless definition["locations"].include?(definition["default_location"])
        raise ParameterException,
          "Default location #{definition['default_location'].inspect} " \
          "is not included in locations for #{name}"
      end

      path_kind_registry[name] = definition
      install_path_tools
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
    #     "roots" => {
    #       "tmp" => ".scout/var/path/views",
    #       "project" => "share/views"
    #     },
    #     "capabilities" => {"promote" => true},
    #     "validate" => ->(path, content) { ... },
    #     "promote" => ->(path, source, target) { ... }
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
    end

    # Store tools in the same [callable, definition] format consumed by Agent#ask.
    def path_install_tool(name, definition, implementation=nil)
      properties = definition.fetch("parameters").fetch("properties")
      required = definition.fetch("parameters").fetch("required", [])
      tool_definition = LLM.tool_definition(name, definition.fetch("description"), properties, required: required)
      implementation = name.to_sym if implementation.nil?
      callable = Proc.new { |_tool_name, arguments| 
        begin
          public_send(implementation, arguments) 
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
      when "validate", "test", "promote"
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
        "Run the kind-specific smoke/integration test for a virtual Path."
      when "promote"
        "Promote a virtual Path from its temporary location to its project location."
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
    # Text adapter
    # ------------------------------------------------------------------

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
      if !target.is_a?(String) && target.respond_to?(:delete)
        target.delete
      else
        File.delete(target.to_s)
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
      kind = args.fetch("kind")
      path = args.fetch("path")
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
      kind = args.fetch("kind")
      path = args.fetch("path")
      content = args.fetch("content")
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
      kind = args.fetch("kind")
      path = args.fetch("path")
      selector = args.fetch("selector")
      replacement = args.fetch("replacement")
      location = args["location"]

      unless path_kind_capable?(kind, "edit")
        raise ParameterException, "Path kind #{kind} does not support edit"
      end

      target = resolve_path(kind, path, location)
      path_authorize!(kind, target, location, mode: :write)
      original = path_read_text(target)

      edited = path_apply_selector(original, selector, replacement)
      path_write_text(target, edited)

      {
        "doc_id" => path_doc_id(kind, path, args["version"]),
        "kind" => kind,
        "path" => path,
        "changed" => original != edited,
        "content" => edited
      }
    end

    def path_list(args)
      kind = args.fetch("kind")
      location = args["location"] || path_kind_definition(kind)["default_location"]
      prefix = args["path"].to_s
      target = resolve_path(kind, prefix, location)

      definition = path_kind_definition(kind)
      path_authorize!(kind, target, location, mode: :read)

      if definition["list"]
        return definition["list"].call(self, prefix, location)
      end

      if roots = definition.fetch('roots', nil)
        root = roots.fetch(location.to_s).to_s
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
      kind = args.fetch("kind")
      source_path = args.fetch("path")
      destination = args.fetch("destination")
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
      kind = args.fetch("kind")
      source_path = args.fetch("path")
      name = args.fetch("name")
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
      kind = args.fetch("kind")
      path = args.fetch("path")
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

    def path_promote(args)
      kind = args.fetch("kind")
      unless path_kind_capable?(kind, "promote")
        raise ParameterException, "Path kind #{kind} does not support promote"
      end

      definition = path_kind_definition(kind)
      operation = definition["promote"]
      raise ParameterException, "Path kind #{kind} has no promote implementation" unless operation

      location = args["location"] || definition["default_location"]
      target = resolve_path(kind, args.fetch("path").to_s, location)
      path_authorize!(kind, target, location, mode: :write)
      operation.call(
        self,
        args.fetch("path").to_s,
        location.to_s,
        args
      )
    end

    # ------------------------------------------------------------------
    # Selectors
    # ------------------------------------------------------------------

    def path_apply_selector(content, selector, replacement)
      type = selector.fetch("type").to_s

      case type
      when "regexp"
        pattern = Regexp.new(selector.fetch("pattern"))
        content.sub(pattern, replacement.to_s)
      when "chars"
        start = selector.fetch("start")
        finish = selector.fetch("end")
        raise ParameterException, "Character range must satisfy start <= end" if start > finish

        content.dup.tap do |text|
          text[start...finish] = replacement.to_s
        end
      when "lines"
        lines = content.lines
        start = selector.fetch("start")
        finish = selector.fetch("end")
        raise ParameterException, "Line range must satisfy start <= end" if start > finish

        lines[start...finish] = [replacement.to_s]
        lines.join
      else
        raise ParameterException,
          "Unknown selector type #{type.inspect}; expected lines, chars, or regexp"
      end
    end

    # ------------------------------------------------------------------
    # Kind-specific operations
    # ------------------------------------------------------------------

    def path_kind_operation(args, operation)
      kind = args.fetch("kind")
      unless path_kind_capable?(kind, operation)
        raise ParameterException, "Path kind #{kind} does not support #{operation}"
      end

      definition = path_kind_definition(kind)
      implementation = definition[operation]
      raise ParameterException, "Path kind #{kind} has no #{operation} implementation" unless implementation

      location = args["location"] || definition["default_location"]
      target = resolve_path(kind, args.fetch("path").to_s, location)
      path_authorize!(kind, target, location, mode: :read)

      implementation.call(
        self,
        args.fetch("path").to_s,
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
