module Chat
  # Traverse the provenance graph of a chat: the chat itself, all job
  # agent-log chats, and their dependencies, collecting every chat file
  # reachable from the root.  Each file is visited only once to avoid
  # duplicating evidence or recursing forever on cycles.
  def self.provenance(chat_file, prov = {})
    return prov if prov.include? chat_file
    return prov unless Open.exists?(chat_file)
    chat = Chat.load chat_file
    chat.jobs.each do |job_ref|
      job = Step.load(job_ref) unless Step === job_ref
      prov[chat_file] ||= []
      Chat.job_agent_chat_files(job).each do |agent_chat_file|
        prov[chat_file] << agent_chat_file
        prov.merge(Chat.provenance(agent_chat_file, prov))
      end
      job.dependencies.each do |dep|
        prov.merge(Chat.provenance(dep.path, prov))
      end
    end
    prov
  end

  def self.provenance_chat_files(chat)
    provenance(chat).values.flatten.uniq + [chat]
  end

  def self.tokens(chat)
    chats = provenance_chat_files(chat).collect{|file| 
      @@chat_file ||= {}
      @@chat_file[file] ||= Chat.load file 
    }
    Chat.token_totals(chats)
  end

end
