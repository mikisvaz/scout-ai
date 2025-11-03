module Chat
  def self.clear(messages, role = 'clear')
    new = []

    messages.reverse.each do |message|
      if message[:role].to_s == role
        break
      else
        new << message
      end
    end

    new.reverse
  end

  def self.clean(messages, role = 'skip')
    messages.reject do |message|
      ((String === message[:content]) && message[:content].empty?) ||
        message[:role] == role
    end
  end

  def self.purge(chat)
    chat.reject do |msg|
      IndiferentHash.setup msg
      msg[:role].to_s == 'previous_response_id'
    end
  end
end
