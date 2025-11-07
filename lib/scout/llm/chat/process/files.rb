module Chat
  def self.tag(tag, content, name = nil)
    if name
      <<-EOF.strip
<#{tag} name="#{name}">
#{content}
</#{tag}>
      EOF
    else
      <<-EOF.strip
<#{tag}>
#{content}
</#{tag}>
      EOF
    end
  end
  def self.find_file(file, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    path = Scout.chats[file]
    original = original.find if Path === original
    if original
      relative = File.join(File.dirname(original), file)
      relative_lib = File.join(caller_lib_dir, file) if caller_lib_dir
    end

    if Open.exist?(file)
      file
    elsif Open.remote?(file)
      file
    elsif relative && Open.exist?(relative)
      relative
    elsif relative_lib && Open.exist?(relative_lib)
      relative_lib
    elsif path.exists?
      path
    end
  end

  def self.imports(messages, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    messages.collect do |message|
      if message[:role] == 'import' || message[:role] == 'continue' || message[:role] == 'last'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "Import not found: #{file}" if found_file.nil?

        new = LLM.messages Open.read(found_file)

        new = if message[:role] == 'continue'
                [new.reject{|msg| msg[:content].nil? || msg[:content].strip.empty? }.last]
              elsif message[:role] == 'last'
                [LLM.purge(new).reject{|msg| msg[:content].empty?}.last]
              else
                LLM.purge(new)
              end

        LLM.chat new, found_file
      else
        message
      end
    end.flatten
  end

  def self.files(messages, original = nil, caller_lib_dir = Path.caller_lib_dir(nil, 'chats'))
    messages.collect do |message|
      if message[:role] == 'file' || message[:role] == 'directory'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "File not found: #{file}" if found_file.nil?

        target = found_file

        if message[:role] == 'directory'
          Path.setup target
          target.glob('**/*').
            reject{|file|
              Open.directory?(file)
            }.collect{|file|
              files([{role: 'file', content: file}])
            }
        else
          new = Chat.tag :file, Open.read(target), file
          {role: 'user', content: new}
        end
      elsif message[:role] == 'pdf' || message[:role] == 'image'
        file = message[:content].to_s.strip
        found_file = find_file(file, original, caller_lib_dir)
        raise "File not found: #{file}" if found_file.nil?

        message[:content] = found_file
        message
      else
        message
      end
    end.flatten
  end

end
