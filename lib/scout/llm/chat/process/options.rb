module Chat
  def self.options(chat)
    options = IndiferentHash.setup({})
    sticky_options = IndiferentHash.setup({})
    new = []

    # Most options reset after an assistant reply, but not previous_response_id
    chat.each do |info|
      if Hash === info
        role = info[:role].to_s
        if %w(endpoint model backend agent).include? role.to_s
          sticky_options[role] = info[:content]
          next
        elsif %w(persist).include? role.to_s
          options[role] = info[:content]
          next
        elsif %w(previous_response_id).include? role.to_s
          sticky_options[role] = info[:content]
        elsif %w(format).include? role.to_s
          format = info[:content]
          if Path.is_filename?(format)
            file = find_file(format)
            if file
              format = Open.json(file)
            end
          end
          options[role] = format
          next
        end

        if role.to_s == 'option'
          key, _, value = info[:content].partition(" ")
          options[key] = value
          next
        end

        if role.to_s == 'sticky_option'
          key, _, value = info[:content].partition(" ")
          sticky_options[key] = value
          next
        end

        if role == 'assistant'
          options.clear
        end
      end
      new << info
    end
    chat.replace new
    sticky_options.merge options
  end

  def self.serialize_meta(meta) 
    meta.collect{|p| p * "="} * " "  
  end  

  def self.parse_meta(str) 
    parts = str.split('=')    
    meta = {}   
    key = parts.shift 
    while next_part = parts.shift

      if parts.any?
        rnext_part = next_part.reverse
        rkey,_, rvalue = rnext_part.partition(/\s+/)
        next_key = rkey.reverse
        value = rvalue.reverse
      else
        value = next_part
      end

      case value      
      when /^-?\d+$/
        meta[key] = value.to_i 
      when /^-?\d+\.\d+$/ 
        meta[key] = value.to_f      
      else       
        meta[key] = value
      end

      key = next_key
    end 
    meta
  end  

  def self.meta(messages)  
    meta_msg = messages.select{|info| info[:role].to_sym == :meta }.last

    return nil if meta_msg.nil?
    meta_str = meta_msg[:content] 
    messages.reject!{|info| info[:role].to_sym == :meta }    
    parse_meta meta_str
  end
end
