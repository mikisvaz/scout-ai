require 'scout/workflow'

module AgentWorkflow
  extend Workflow

  helper :chat do |chat=nil|
    @chat ||= LLM.chat(chat || recursive_inputs[:chat].dup)
  end

  helper :options do
    @options ||= LLM.options self.chat
  end

  helper :agent_options do |options|
    IndiferentHash.setup options.except(:agent, 'agent', :chat, 'chat').dup
  end

  helper :tooling do
    @tooling ||= begin
      chat = self.chat
      chat.remove_role(:tool) +
        chat.remove_role(:kb) +
        chat.remove_role(:mcp) +
        chat.remove_role(:introduce)
    end
  end

  helper :tooling_intro do
    self.tooling.select { |msg| msg[:role] == 'introduce ' }
  end

  helper :agent do |name = nil, chat: nil, options: nil, tooling: nil, files: nil, **kwargs|
    options = self.options if options.nil?
    tooling = self.tooling if tooling.nil?
    options = IndiferentHash.add_defaults options, kwargs

    agent = LLM.load_agent name, agent_options(options)
    agent.job = self
    agent.start_chat.follow tooling if tooling && !tooling.empty?

    agent.start_chat.system <<-EOF
Your current working directory is #{Dir.pwd}.
You are working through an ask job with path #{self.path} and files_dir #{self.files_dir}.
    EOF

    if dependencies.any?
      agent.start_chat.system <<-EOF
This workflow job has the following depencencies:

#{rec_dependencies.collect(&:path) * "\n"}
      EOF
    end

    if chat && !chat.empty?
      chat = LLM.chat(chat)
      other_jobs = chat.jobs
      if other_jobs.any?
        agent.start_chat.system <<-EOF
There are other jobs found in this chat:

#{other_jobs * "\n"}
        EOF
      end
    end

    files.each do |path|
      target = file(path)
      if File.exist?(target.find)
        agent.start_chat.file target
      elsif File.exist?(path.find)
        agent.start_chat.file path
      end
    end if files

    if chat && !chat.empty?
      chat = LLM.chat(chat)
      chat.reject! { |msg| msg[:content].to_s.start_with? 'You have been assigned' }
      chat.reject! { |msg| msg[:content].to_s.start_with? 'This workflow job has the following' }
      chat.reject! { |msg| msg[:content].to_s.start_with? 'There are other jobs found in this chat' }
      agent.start_chat.follow chat
    end

    agent
  end

  # Logged conversations and their own job markers are the evidence for work
  # performed by this task. The task result itself only projects those messages.
  helper :add_chat_dependencies do |chat|
    chat.jobs.each do |job_path|
      next if job_path.to_s == self.short_path.to_s
      begin
        dependencies << Step.load(job_path)
      rescue
      end
    end
  end

  helper :log_agent do |agent, agent_name=nil|
    dir = agent_name ? file('log')[agent_name] : file('log')

    agent.chats.each do |name, other|
      dir.chats[name].set_extension('chat').write other.current_chat.print
      add_chat_dependencies(other.current_chat)
    end if agent.chats

    dir['agent.chat'].write agent.current_chat.print
    add_chat_dependencies(agent.current_chat)

    update_info :dependencies, dependencies.collect { |dependency| dependency.path.find }
    agent
  end
end

module Workflow
  def chat_task(task_name, &block)
    input :chat, :text, 'Chat in Scout-AI chat-file format'
    task task_name => :chat do |chat|
      begin
        response = self.instance_exec(&block)

        result = if LLM::Agent === response
          agent = response
          if agent.current_chat.last[:role].to_s == 'user'
            agent.chat(return_messages: true)
          else
            agent.current_chat - agent.start_chat
          end.tap { log_agent(agent) }
        elsif Hash === response
          [response]
        else
          response
        end

        Chat.project(self.short_path, result)
      rescue ScoutException
        error = { role: :assistant, content: { exception: $!, job: self.short_path }.to_json }
        Chat.project(self.short_path, [error])
      end
    end
  end

  class << self
    alias require_workflow_old require_workflow
  end

  def self.require_workflow(name, ...)
    begin
      require_workflow_old(name, ...)
    rescue => e
      begin
        LLM.load_agent(name).workflow
      rescue
        raise e
      end
    end
  end
end

class LLM::Agent
  attr_accessor :job
end
