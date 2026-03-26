module Chat
  def self.clear(messages, role = 'clear')
    new = []

    messages.reverse.each do |message|
      if message[:role].to_s == role.to_s
        break
      else
        new << message
      end
    end

    Chat.setup new.reverse
  end

  def self.clean(messages, role = ['skip', 'previous_response_id'])
    messages.reject do |message|
      ((String === message[:content]) && message[:content].empty?) ||
        if Array === role
        else
          message[:role].to_s == role.to_s
        end
    end
  end

  def self.purge(chat, role = :previous_response_id)
    chat.reject do |msg|
      msg = IndiferentHash.setup msg.dup

      msg[:role].to_s == role.to_s
    end
  end

  def self.pull(chat, role = :previous_response_id)
    last = nil
    chat.reject! do |msg|
      msg = IndiferentHash.setup msg.dup

      match = msg[:role].to_s == role.to_s
      last = msg if match
      match
    end

    return nil if last.nil?
    IndiferentHash.setup last.dup
  end
end
