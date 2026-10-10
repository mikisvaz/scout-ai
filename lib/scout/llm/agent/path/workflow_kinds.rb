# frozen_string_literal: true

# Whole-workflow PATH_KINDS incorporation for the agent-level virtual Path
# interface (see lib/scout/llm/agent/path.rb for the engine overview).
module LLM
  class Agent
    module AgentPathWorkflowKinds
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

    end
  end
end
