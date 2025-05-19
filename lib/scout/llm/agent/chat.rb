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
  end
end
