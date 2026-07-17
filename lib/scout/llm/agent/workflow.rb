require 'scout/workflow'

module AgentWorkflow
  extend Workflow

  helper :log_cost do |other|
    @meta_list ||= []
    @meta_list << other
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

    Thread.current['Agent-Job'] = self

    options = self.options if options.nil?
    tooling = self.tooling if tooling.nil?
    options = IndiferentHash.add_defaults options, kwargs

    agent = LLM.load_agent name, agent_options(options)
    agent.start_chat.follow tooling if tooling && ! tooling.empty?

    agent.start_chat.system <<-EOF
You have been assigned this job path #{self.path}. The files
directory is #{self.files_dir} you have write access and you may use it
to write files. If you need to create temporary files please do it under
that directory.

Your current directory is #{Dir.pwd}
    EOF

    if dependencies.any?
      agent.start_chat.system <<-EOF
This workflow job has the following depencencies:

#{rec_dependencies.collect{|dep| dep.path } * "\n"}
      EOF
    end

    files.each do |path|
      target = file(path)
      if File.exist?(target.find)
        agent.start_chat.file target 
      elsif File.exist?(path.find)
        agent.start_chat.file path 
      end
    end if files

    if chat && ! chat.empty?
      chat = LLM.chat(chat)
      chat.reject!{|msg| msg[:content].start_with? 'You have been assigned' }
      chat.reject!{|msg| msg[:content].start_with? 'This workflow job has the following' }
      agent.start_chat.follow chat
    end

    agent
  end

  # Usage created by agents logged while this task runs. Each agent may have
  # inherited a chat from an upstream task, so retain only events absent from
  # its start_chat. Delegated agents are included through @meta_list too.
  helper :new_usage do |list=nil|
    list ||= @meta_list || []

    list.inject({}) do |all, entry|
      next all unless LLM::Agent === entry

      before = Chat.usage_events(entry.start_chat)
      after = Chat.usage_events(entry.current_chat)
      all.merge(after.reject { |id, _usage| before.include?(id) })
    end
  end

  # Summaries may reach an agent through self.chat or through an explicit
  # `chat:` argument (for example, the `work` task receives the plan result).
  helper :inherited_usage do |list=nil|
    list ||= @meta_list || []
    summaries = Chat.usage_summaries(self.chat)

    list.each do |entry|
      next unless LLM::Agent === entry
      summaries.merge! Chat.usage_summaries(entry.start_chat)
    end

    summaries
  end

  helper :current_meta do |list=nil|
    meta = {job: self.short_path, usage_job: self.short_path, usage_scope: 'task'}

    # Results of dependency tasks contain one delta summary per task. Their
    # job ids make repeated follows/imports harmless.
    inherited = inherited_usage(list)
    local = new_usage(list)

    inherited_totals = Chat.usage_totals(inherited)
    local_totals = Chat.usage_totals(local)

    %w(pt ct tt).each do |name|
      meta["#{name}_d"] = local_totals["#{name}_c"]
      meta["#{name}_c"] = inherited_totals["#{name}_c"].to_i + local_totals["#{name}_c"].to_i
    end

    meta
  end

  helper :log_agent do |agent, agent_name=nil|
    dir = agent_name ? file('log')[agent_name] : file('log')

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


  helper :meta_msg do |list=nil|
    {role: :meta, content: Chat.serialize_meta(current_meta)}
  end

  # Step results expose a single task summary. Full per-request traces remain
  # in log/agent.chat for auditing; Step results need only the task delta.
  helper :usage_trace do
    [{role: :meta, content: Chat.serialize_meta(current_meta)}]
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
          result = if agent.current_chat.last[:role].to_s == 'user'
            reply = agent.chat return_messages: true
            agent.add_meta :job, self.short_path
            log_agent agent
            reply
          else
            agent.add_meta :job, self.short_path
            log_agent agent
            agent.current_chat - agent.start_chat
          end
          trace = usage_trace
          trace + result.reject { |message| message[:role].to_s == 'meta' }
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
