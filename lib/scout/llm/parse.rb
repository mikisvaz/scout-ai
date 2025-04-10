module LLM
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
        messages.last[:content] += inside

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
        else
          [{role: role, content: question.strip}]
        end
      end
    end
  end
end
