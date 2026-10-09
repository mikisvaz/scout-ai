# frozen_string_literal: true

# In-memory single-file unified-diff applier for the Path engine.
#
# Contract (see tmp/path_recon.md "Round 3 — Step 6 design"):
#   * EXACTLY ONE `--- `/`+++ ` header pair; header filenames are ignored
#     as target selectors and can never redirect the write.
#   * Hunks: `@@ -l[,s] +l[,s] @@`, body lines starting with ' '
#     (context), '-' (removal), '+' (addition), or the
#     `\ No newline at end of file` marker (toggles the no-newline state
#     of the preceding line).
#   * STRICT application: no fuzz, no search window. Context must match
#     exactly at the computed position. Any failure raises
#     ParameterException and the caller writes NOTHING.
#   * All hunks apply or none: the caller only writes the final result.
#
# This is an original implementation written from the unified-diff
# grammar; no code was copied from the Workspace patch task (whose
# shell-out execution model was deliberately rejected).
module LLM
  class Agent
    module PathPatch
      module_function

      # Parse the patch text. Returns hunks: array of
      # { old_start:, old_size:, new_start:, new_size:, lines: }
      # where lines is an array of [tag, text, no_newline] tuples with
      # tags :context / :del / :add.
      def parse(patch_text)
        raise ParameterException, "Patch must be a String" unless String === patch_text

        raw_lines = patch_text.split(/\r?\n/, -1)
        # A trailing empty element from a final newline is not a body line
        raw_lines.pop if raw_lines.last == ""

        headers = raw_lines.each_index.select do |i|
          raw_lines[i].start_with?("--- ", "+++ ")
        end

        if headers.empty?
          raise ParameterException, "Patch is missing the ---/+++ header pair"
        end

        if headers.length > 2 || !headers.include?(headers.first + 1)
          raise ParameterException,
                "multi-file patch not supported: #{[headers.length, 2].min}+ file headers"
        end
        unless raw_lines[headers.first].start_with?("--- ") &&
               raw_lines[headers.first + 1].start_with?("+++ ")
          raise ParameterException, "Patch header pair is malformed"
        end

        hunks = []
        i = headers.first + 2

        while i < raw_lines.length
          line = raw_lines[i]

          if line.start_with?("@@")
            hunk, i = parse_hunk(raw_lines, i)
            hunks << hunk
          elsif line.strip.empty?
            i += 1
          else
            raise ParameterException, "Unexpected text between hunks: #{line.inspect}"
          end
        end

        if hunks.empty?
          raise ParameterException, "Patch contains no hunks"
        end

        hunks
      end

      def parse_hunk(raw_lines, start)
        header = raw_lines[start]
        match = header.match(/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
        unless match
          raise ParameterException, "Malformed hunk header: #{header.inspect}"
        end

        old_start = match[1].to_i
        old_size = match[2] ? match[2].to_i : 1
        new_start = match[3].to_i
        new_size = match[4] ? match[4].to_i : 1

        lines = []
        i = start + 1
        old_count = 0
        new_count = 0

        while i < raw_lines.length
          line = raw_lines[i]

          if line.start_with?("\\ No newline")
            if lines.empty?
              raise ParameterException, "No-newline marker before any hunk line"
            end
            lines.last[2] = true
            i += 1
            next
          end

          break if line.start_with?("@@") ||
                   (line.start_with?("--- ", "+++ ") && looks_like_header?(raw_lines, i))

          tag, text =
            if line.start_with?(" ") || line.empty?
              [:context, line.sub(/\A /, "")]
            elsif line.start_with?("-")
              [:del, line[1..]]
            elsif line.start_with?("+")
              [:add, line[1..]]
            else
              raise ParameterException, "Malformed patch body line: #{line.inspect}"
            end

          old_count += 1 if tag == :context || tag == :del
          new_count += 1 if tag == :context || tag == :add
          lines << [tag, text, false]
          i += 1
        end

        if lines.empty?
          raise ParameterException, "Hunk starting at #{header.inspect} has no body"
        end

        unless old_count == old_size && new_count == new_size
          raise ParameterException,
                "Hunk #{header.inspect} counts mismatch: declared " \
                "#{old_start},#{old_size} #{new_start},#{new_size}; " \
                "found old=#{old_count} new=#{new_count}"
        end

        [{old_start: old_start, old_size: old_size,
          new_start: new_start, new_size: new_size, lines: lines}, i]
      end

      def looks_like_header?(raw_lines, i)
        # `--- ` inside a hunk body (context line whose content starts
        # with `-`) starts with " ", so a bare `--- ` line here is a
        # header only when followed by `+++ ` (a second file header).
        raw_lines[i + 1]&.start_with?("+++ ")
      end

      # Apply parsed hunks to content. Returns [new_content, changed].
      # Raises ParameterException on any context mismatch; content is
      # never modified by this method (pure function of its inputs).
      def apply(content, hunks)
        original = content.dup
        original_terminated = original.end_with?("\n")
        body = original.sub(/\n\z/, "")
        buffer = body.split("\n", -1)
        # split("\n", -1) on "a\nb" -> ["a","b"]; on "" -> [""]
        buffer = [] if body.empty?

        offset = 0
        hunks.each_with_index do |hunk, hunk_index|
          header = "@@ -#{hunk[:old_start]},#{hunk[:old_size]}"
          position = hunk[:old_start] - 1 + offset

          unless position >= 0 && position <= buffer.length
            raise ParameterException,
                  "Patch hunk #{hunk_index + 1} (#{header}) starts out of range: " \
                  "line #{hunk[:old_start]} in a #{buffer.length}-line file"
          end

          # Verify and apply: walk context/del lines against the buffer,
          # collect additions.
          cursor = position
          additions = []
          hunk[:lines].each_with_index do |(tag, text, _no_newline), line_index|
            case tag
            when :context, :del
              if cursor >= buffer.length || buffer[cursor] != text
                raise ParameterException,
                      "Patch hunk #{hunk_index + 1} (#{header}) context mismatch " \
                      "at hunk line #{line_index + 1}: expected #{text.inspect}, " \
                      "found #{buffer[cursor]&.inspect}"
              end
              cursor += 1
              additions << nil if tag == :context
            when :add
              additions << text
            end
          end

          # Rebuild: buffer[0...position] + interleaved new sequence +
          # remainder. The new sequence replaces old_size lines starting
          # at position: context lines map 1:1, dels vanish, adds insert.
          new_sequence = []
          old_consumed = 0
          hunk[:lines].each do |tag, text, _no_newline|
            case tag
            when :context
              new_sequence << buffer[position + old_consumed]
              old_consumed += 1
            when :del
              old_consumed += 1
            when :add
              new_sequence << text
            end
          end

          unless old_consumed == hunk[:old_size]
            raise ParameterException,
                  "Patch hunk #{hunk_index + 1} (#{header}) consumed " \
                  "#{old_consumed} old lines, expected #{hunk[:old_size]}"
          end

          buffer[position, old_consumed] = new_sequence
          offset += new_sequence.length - old_consumed
        end

        result = buffer.join("\n")

        # Newline policy: explicit no-newline markers override; otherwise
        # preserve the ORIGINAL's termination. The old side's final line
        # is the last :del/:context; the new side's the last
        # :add/:context (both of the last hunk, the usual EOF position).
        new_no_newline = final_line_marked?(hunks, :new)
        old_no_newline = final_line_marked?(hunks, :old)
        if new_no_newline
          result = result.sub(/\n+\z/, "")
        elsif old_no_newline
          result = result.sub(/\n*\z/, "\n")
        elsif original_terminated
          result = result.sub(/\n*\z/, "\n")
        else
          result = result.sub(/\n+\z/, "")
        end

        [result, result != original]
      end

      # Whether the final line of the old or new side (as of the last
      # hunk) carries the no-newline marker. side is :old or :new.
      def final_line_marked?(hunks, side)
        last_hunk = hunks.last
        return false unless last_hunk

        wanted = side == :old ? %i[del context] : %i[add context]
        last = last_hunk[:lines].reverse.find { |tag, _, _| wanted.include?(tag) }
        return false unless last

        tag, _text, no_newline = last
        no_newline
      end
    end
  end
end
