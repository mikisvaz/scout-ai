require_relative 'parse'
require_relative 'tools'

module LLM
  def self.messages(question, role = nil)
    return question if Array === question
    messages = []
    current_role = nil
    current_content = ""
    default_role = "user"
    in_protected_block = false
    protected_block_type = nil
    protected_stack = []

    file_lines = question.split("\n")

    file_lines.each do |line|
      stripped = line.strip

      # Detect protected blocks
      if stripped.start_with?("[[")
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
      if stripped =~ /^([a-zA-Z0-9_]+):(.*)$/
        role = $1
        inline_content = $2.strip

        # Save current message if any
        messages << { role: current_role, content: current_content.strip }

        if inline_content.empty?
          # Block message
          current_role = role
          current_content = ""
        else
          # Inline message + next block is default role
          messages << { role: role, content: inline_content }
          current_role = default_role
          current_content = ""
        end
      else
        current_content << "\n" << line
      end
    end

    # Final message
    messages << { role: current_role, content: current_content.strip }

    messages
  end

  def self.imports(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'import' || message[:role] == 'continue'
        file = message[:content].strip
        path = Scout.root[file]
        original = original.find if Path === original
        relative = File.join(File.dirname(original), file) if original

        new = if Open.exist?(file)
                LLM.chat file
              elsif relative && Open.exist?(relative)
                LLM.chat relative
              elsif path.exists?
                LLM.chat path
              else
                raise "Import not found: #{file}"
              end

        if message[:role] == 'continue'
          new.last
        else
          new
        end
      else
        message
      end
    end.flatten
  end

  def self.files(messages, original = nil)
    messages.collect do |message|
      if message[:role] == 'file' || message[:role] == 'directory'
        file = message[:content].strip
        path = Scout.root[file]
        original = original.find if Path === original
        relative = File.join(File.dirname(original), file) if original

        target = if Open.exist?(file)
                file
              elsif relative && Open.exist?(relative)
                relative
              elsif path.exists?
                path
              else
                raise "Import not found: #{file}"
              end

        if message[:role] == 'directory'
          Path.setup target
          target.glob('*').collect{|dir| files(dir) }
        else
          new = LLM.tag :file, file, Open.read(target)
          {role: 'user', content: new}
        end
      else
        message
      end
    end.flatten
  end

  def self.clear(messages)
    new = []

    messages.reverse.each do |message|
      if message[:role] == 'clear'
        break
      else
        new << message
      end
    end

    new.reverse
  end

  def self.clean(messages)
    messages.reject do |message|
      message[:content].empty?
    end
  end

  def self.chat(file)
    messages = LLM.messages Open.read(file)
    messages = LLM.imports messages, file
    messages = LLM.clear messages
    messages = LLM.clean messages
    messages = LLM.files messages

    messages
  end

  def self.print(chat)
    return chat if String  === chat
    chat.collect do |message|
      IndiferentHash.setup message
      message[:role].to_s + ":\n\n" + message[:content] 
    end * "\n\n"
  end
end
