require 'scout/workflow'

module AgentWorkflow
  extend Workflow

  helper :log_cost do |other|
    @meta_list ||= []
    @meta_list << other
  end

  helper :log_agent do |agent, agent_name=nil|
    dir = agent_name ? file(agent_name) : files_dir

    agent.chats.each do |name,other|
      log_cost other
      dir.chats[name].set_extension('chat').write other.current_chat.print
      if agent_job = other.meta[:job]
        self.dependencies << Step.load(agent_job)
      end
    end if agent.chats

    dir['agent.chat'].write agent.current_chat.print

    if agent_job = agent.meta[:job] and agent_job != self.short_path
      self.dependencies << Step.load(agent_job)
    end

    log_cost agent

    update_info :dependencies, dependencies.collect{|dep| dep.path.find }


    agent
  end

  helper :chat do |chat=nil|
    @chat ||= LLM.chat(chat || recursive_inputs[:chat].dup)
  end

  helper :options do 
    @options ||= LLM.options self.chat
  end

  helper :agent_options do |options|
    IndiferentHash.setup options.except(:agent, 'agent', :chat, 'chat').dup
  end

  helper :tooling  do
    @tooling ||= begin 
                   chat = self.chat
                   chat.remove_role(:tool) +
                     chat.remove_role(:kb) +
                     chat.remove_role(:mcp) +
                     chat.remove_role(:introduce)
                 end
  end

  helper :tooling_intro do
    self.tooling.select{|msg| msg[:role] == 'introduce '}
  end

  helper :agent do |name = nil, chat: nil, options: nil, tooling: nil, files: nil, **kwargs|

    options = self.options if options.nil?
    tooling = self.tooling if tooling.nil?
    options = IndiferentHash.add_defaults options, kwargs

    agent = LLM.load_agent name, agent_options(options)
    agent.start_chat.follow tooling if tooling && ! tooling.empty?

    files.each do |path|
      target = file(path)
      if File.exist?(target.find)
        agent.start_chat.file target 
      elsif File.exist?(path.find)
        agent.start_chat.file path 
      end
    end if files

    agent.start_chat.follow LLM.chat(chat) if chat && ! chat.empty?

    agent
  end

  helper :current_meta do |list=nil|

    meta = {job: self.short_path}
    list = @meta_list || []

    list.inject(meta) do |current_meta,meta|
      meta = meta.meta if LLM::Agent === meta
      meta = meta.pull :meta if Chat === meta
      new = {}
      meta.each do |name,value|
        if name.end_with?('_c')
          current_value = current_meta[name]
          new[name] = current_value.to_i + value.to_i
        end
        if name.end_with?('_s')
          chat_name = name.sub(/_s$/,'_c')
          current_value = current_meta[name] || current_meta[chat_name] || 0
          new[name] = current_value.to_i + value.to_i
        end
      end
      current_meta.merge! new

      current_meta
    end
  end

  helper :meta_msg do |list=nil|
    {role: :meta, content: Chat.serialize_meta(current_meta)}
  end
end

module Workflow

  def chat_task(task_name, &block)
    input :chat, :text, "Chat in Scout-AI chat-file format"
    task task_name => :chat do |chat|
      begin
        self.options
        response = self.instance_exec &block
        if LLM::Agent === response
          agent = response
          if agent.current_chat.last[:role].to_s == 'user'
            reply = agent.chat return_messages: true
            log_agent agent
            reply
          else
            log_agent agent
            agent.current_chat - agent.start_chat
          end
          agent.add_meta :job, self.short_path
        elsif Hash === response
          [meta_msg, response]
        else
          response
        end
      rescue ScoutException
        error = {
          exception: $!,
          job: self.short_path
        }
        [meta_msg, {role: :assistant, content: error.to_json}]
      end
    end
  end
end
