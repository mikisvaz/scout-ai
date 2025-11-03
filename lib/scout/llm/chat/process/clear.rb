module Chat
  def self.clear(messages)
    new = []

    messages.reverse.each do |message|
      if message[:role].to_s == 'clear'
        break
      else
        new << message
      end
    end

    new.reverse
  end

  def self.clean(messages)
    messages.reject do |message|
      ((String === message[:content]) && message[:content].empty?) ||
        message[:role] == 'skip'
    end
  end

  def self.purge(chat)
    chat.reject do |msg|
      IndiferentHash.setup msg
      msg[:role].to_s == 'previous_response_id'
    end
  end
end
