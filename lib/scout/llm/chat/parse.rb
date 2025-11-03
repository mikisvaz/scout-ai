module Chat
  def self.parse(text, role = nil)
    default_role = "user"

    messages = []
    current_role = role || default_role
    current_content = ""
    in_protected_block = false
    protected_block_type = nil
    protected_stack = []

    role = default_role if role.nil?

    file_lines = text.split("\n")

    file_lines.each do |line|
      stripped = line.strip

      # Detect protected blocks
      if stripped.start_with?("```")
        if in_protected_block
          in_protected_block = false
          protected_block_type = nil
          current_content << "\n" << line unless line.strip.empty?
        else
          in_protected_block = true
          protected_block_type = :square
          current_content << "\n" << line unless line.strip.empty?
        end
        next
      elsif stripped.end_with?("]]") && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub("]]", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.start_with?("[[")
        in_protected_block = true
        protected_block_type = :square
        line = line.sub("[[", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.end_with?("]]") && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub("]]", "")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.match(/^.*:-- .* {{{/)
        in_protected_block = true
        protected_block_type = :square
        line = line.sub(/^.*:-- (.*) {{{.*/, '<cmd_output cmd="\1">')
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif stripped.match(/^.*:--.* }}}/) && in_protected_block && protected_block_type == :square
        in_protected_block = false
        protected_block_type = nil
        line = line.sub(/^.*:-- .* }}}.*/, "</cmd_output>")
        current_content << "\n" << line unless line.strip.empty?
        next
      elsif in_protected_block

        if protected_block_type == :xml
          if stripped =~ %r{</(\w+)>}
            closing_tag = $1
            if protected_stack.last == closing_tag
              protected_stack.pop
            end
            if protected_stack.empty?
              in_protected_block = false
              protected_block_type = nil
            end
          end
        end
        current_content << "\n" << line
        next
      end

      # XML-style tag handling (protected content)
      if stripped =~ /^<(\w+)(\s+[^>]*)?>/
        tag = $1
        protected_stack.push(tag)
        in_protected_block = true
        protected_block_type = :xml
      end

      # Match a new message header
      if line =~ /^([a-z0-9_]+):(.*)$/
        role = $1
        inline_content = $2.strip

        current_content = current_content.strip if current_content
        # Save current message if any
        messages << { role: current_role, content: current_content }

        if inline_content.empty?
          # Block message
          current_role = role
          current_content = ""
        else
          # Inline message + next block is default role
          messages << { role: role, content: inline_content }
          current_role = 'user' if role == 'previous_response_id'
          current_content = ""
        end
      else
        if current_content.nil?
          current_content = line
        else
          current_content += "\n" + line
        end
      end
    end

    # Final message
    messages << { role: current_role || default_role, content: current_content.strip }

    messages
  end

  def self.print(chat)
    return chat if String  === chat
    "\n" + chat.collect do |message|
      IndiferentHash.setup message
      case message[:content]
      when Hash, Array
        message[:role].to_s + ":\n\n" + message[:content].to_json
      when nil, ''
        message[:role].to_s + ":"
      else
        if %w(option previous_response_id function_call function_call_output).include? message[:role].to_s
          message[:role].to_s + ": " + message[:content].to_s
        else
          message[:role].to_s + ":\n\n" + message[:content].to_s
        end
      end
    end * "\n\n"
  end
end
