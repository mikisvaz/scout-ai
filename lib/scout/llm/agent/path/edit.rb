# frozen_string_literal: true

# Editing implementation for the agent-level virtual Path interface
# (see lib/scout/llm/agent/path.rb for the engine overview).
#
# Extracted verbatim from path.rb (behavior-preserving move): this module is
# included into LLM::Agent and holds the selector-based editing path only -
# `path_edit`, the selector application `path_apply_selector`, and the
# selector-validation helpers.  Shared engine machinery (kind registry,
# capability gates, `path_argument`, `path_authorize!`, resolution, content
# handlers, read/write text adapters) stays in path.rb and is called through
# the including instance.
module LLM
  class Agent
    module AgentPathEdit
      # ------------------------------------------------------------------
      # Argument and selector validation
      # ------------------------------------------------------------------

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
      # Tool implementations
      # ------------------------------------------------------------------

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
    end
  end
end
