module Chat
  def self.clear(messages, role = 'clear')
    new = []

    clear_tools = false
    clean_roles = []
    messages.reverse.each do |message|
      if message[:role].to_s == role.to_s
        break
      elsif message[:role].to_s == 'clear_tools' 
        clear_tools = message['content'].to_s != 'false'
      elsif message[:role].to_s == 'function_call' ||
        message[:role].to_s == 'function_call_output' 
        new << message unless clear_tools
      elsif message[:role].to_s == 'clean_role' || 
        message[:role].to_s == 'clear_role'
        clean_roles << message[:content].strip
      else
        new << message
      end
    end

    new = Chat.setup new.reverse

    clean_roles.each do |role|
      new = self.clean(new, role)
    end
    
    new
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
