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
          next
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

end
