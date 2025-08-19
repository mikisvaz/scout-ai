module LLM
  class Agent
    def start_chat
      @start_chat ||= Chat.setup []
    end

    def start(chat=nil)
      if chat
        (@current_chat || start_chat).annotate chat unless Chat === chat
        @current_chat = chat
      else
        @current_chat = start_chat.branch
      end
    end

    def current_chat
      @current_chat ||= start
    end

    def method_missing(name,...)
      current_chat.send(name, ...)
    end

    def respond(...)
      self.ask(current_chat, ...)
    end

    def chat(...)
      response = respond(...)
      current_chat.push({role: :assistant, content: response})
      response
    end

    def json(...)
      current_chat.format :json
      output = ask(current_chat, ...)
      obj = JSON.parse output
      if (Hash === obj) and obj.keys == ['content']
        obj['content']
      else
        obj
      end
    end

    def json_format(format, ...)
      current_chat.format format
      output = ask(current_chat, ...)
      obj = JSON.parse output
      if (Hash === obj) and obj.keys == ['content']
        obj['content']
      else
        obj
      end
    end

  end
end
