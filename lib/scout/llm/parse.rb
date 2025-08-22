require 'scout/llm/utils'
module LLM
  def self.process_inside(inside)
    header, content = inside.match(/([^\n]*)\n(.*)/).values_at 1, 2
    if header.empty?
      content
    else
      action, _sep, rest = header.partition /\s/
      case action
      when 'import'
      when 'cmd'
        title = rest.strip.empty? ? content : rest
        tag('file', title, CMD.cmd(content).read)
      when 'file'
        file = content
        title = rest.strip.empty? ? file : rest
        tag(action, title, Open.read(file))
      when 'directory'
        directory = content
        title = rest.strip.empty? ? directory : rest
        directory_content = Dir.glob(File.join(directory, '**/*')).collect do |file|
          file_title = Misc.path_relative_to(directory, file)
          tag('file', file_title, Open.read(file) )
        end * "\n"
        tag(action, title, directory_content )
      else 
        tag(action, rest, content)
      end
    end
  end

  def self.parse(question, role = nil)
    role = :user if role.nil?

    if Array === question
      question.collect do |q|
        Hash === q ? q : {role: role, content: q}
      end
    else
      if m = question.match(/(.*?)\[\[(.*?)\]\](.*)/m)
        pre = m[1]
        inside = m[2]
        post = m[3]
        messages = parse(pre, role)

        messages = [{role: role, content: ''}] if messages.empty?
        messages.last[:content] += process_inside inside

        last = parse(post, messages.last[:role])

        messages.concat last

        messages
      elsif m = question.match(/(.*?)(```.*?```)(.*)/m)
        pre = m[1]
        inside = m[2]
        post = m[3]
        messages = parse(pre, role)

        messages = [{role: role, content: ''}] if messages.empty?
        messages.last[:content] += inside

        last = parse(post, messages.last[:role])

        if last.first[:role] == messages.last[:role]
          m = last.shift
          messages.last[:content] += m[:content]
        end

        messages.concat last

        messages
      else
        chunks = question.scan(/(.*?)^(\w+):(.*?)(?=^\w+:|\z)/m)

        if chunks.any?
          messages = []
          messages << {role: role, content: chunks.first.first} if chunks.first and not chunks.first.first.empty?
          chunks.collect do |pre,role,text|
            messages << {role: role, content: text.strip}
          end
          messages
        elsif question.strip.empty?
          []
        else
          [{role: role, content: question}]
        end
      end
    end
  end
end
