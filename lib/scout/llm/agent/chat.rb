module LLM
  class Agent
    def start_chat
      @start_chat ||= Chat.setup([])
    end

    def start(chat=nil)
      # Restart hook: keep the pre-restart conversation recoverable before it
      # is replaced. Lazy (only with a prior non-empty chat + configured
      # save_file) and never fatal.
      begin
        save_restart_snapshot
      rescue
        Log.warn "Agent restart snapshot failed: #{$!.message}"
      end

      if chat
        (@current_chat || start_chat).annotate chat unless Chat === chat
        @current_chat = chat
      else
        # Restart: keep the displaced conversation (exact object, including
        # every accumulated turn) available to `restore_restarted_chat` so a
        # round rejected before inference can undo this restart precisely.
        @restart_undo_stash = @current_chat if Chat === @current_chat && @current_chat.any?
        start_chat = self.start_chat
        Chat.setup(start_chat) unless Chat === start_chat
        @current_chat = start_chat.branch
      end
    end

    # The exact chat object displaced by the last `start`-restart (the branch
    # that had accumulated the conversation's turns). Held only for the
    # current restart, overwritten by the next one: `restore_restarted_chat`
    # consumes it to undo a restart whose round was rejected before any
    # inference ran, and anything else can keep reading the snapshot written
    # under <save_file>.files/resets/ instead.
    def restart_undo_stash
      @restart_undo_stash
    end

    def restart_undo_stash=(chat)
      @restart_undo_stash = chat
    end

    # Undo one restart that has not been advanced since: put the displaced
    # chat back as current_chat, keeping `start_chat` (the restart kept it,
    # and the stashed chat already prefixes it). Returns the restored chat.
    # Raises when the restarted branch has been mutated since the restart
    # (its tail no longer matches the re-branched start_chat), because
    # restoring then would silently drop those appended turns.
    def restore_restarted_chat(prior)
      raise ScoutException, 'Cannot restore a restarted chat that has advanced' unless current_chat == start_chat.branch
      @current_chat = prior
    end

    def current_chat=(chat)
      @current_chat = Chat.setup(chat)
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

    def chat(options = {})
      response = ask(current_chat, options.merge(return_messages: true))
      if Array === response
        current_chat.concat(response)
        if options[:return_messages] 
          response
        else
          current_chat.answer
        end
      else
        current_chat.push({role: :assistant, content: response})
        response
      end
    ensure
      # Auto-save once the conversation has been updated by this chat round.
      # Non-fatal by design: a save problem must never break the agent run.
      begin
        save_if_configured
      rescue
        Log.warn "Agent auto-save after chat failed: #{$!.message}"
      end
    end

    def create_image(file, options = {})
      current_chat.create_image(file, @other_options.merge(options))
    end

    def json(...)
      current_chat.format :json
      output = chat(...)
      current_chat.format nil
      obj = Chat.parse_json output
      if (Hash === obj) and obj.keys == ['content']
        obj['content']
      else
        obj
      end
    end

    def json_format(format, ...)
      old_format = current_chat.remove_role :format
      current_chat.format format
      output = chat(...)
      current_chat.remove_role :format
      current_chat.concat old_format
      obj = Chat.parse_json output
      if (Hash === obj) and obj.keys == ['content']
        obj['content']
      else
        obj
      end
    end

    #def json(...)
    #  current_chat.format :json
    #  output = ask(current_chat, ...)
    #  current_chat.format nil
    #  obj = Chat.parse_json output
    #  if (Hash === obj) and obj.keys == ['content']
    #    obj['content']
    #  else
    #    obj
    #  end
    #end

    #def json_format(format, options = {})
    #  current_chat.format format
    #  output = ask(current_chat, options.merge({return_messages: false}))
    #  current_chat.format nil
    #  obj = begin
    #          obj = Chat.parse_json output
    #        rescue JSON::ParserError
    #          Log.warn "Not valid JSON:" + output
    #          raise $!
    #        end
    #  if (Hash === obj) and obj.keys == ['content']
    #    obj['content']
    #  else
    #    obj
    #  end
    #end

    def get_previous_response_id
      msg = current_chat.reverse.find{|msg| msg[:role].to_sym == :previous_response_id }
      msg.nil? ? nil : msg['content']
    end

  end
end
