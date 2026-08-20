# LLM::Agent is referenced below in content dispatch, but the require chain
# chat -> tools -> tools/call does not pull in scout/llm/agent (agent.rb
# requires ask.rb, which requires chat.rb, so loading agent from chat would
# be circular). Load it lazily on first use instead of at file load time.
module LLM
  require 'scout/llm/agent' unless defined?(LLM::Agent)
end

module LLM
  @max_content_length = Scout::Config.get(:max_content_length, :llm_tools, :tools, :llm, :ask, default: 100_000)
  self.singleton_class.attr_accessor :max_content_length

  def self.call_id_name_and_arguments(tool_call)
    tool_call_id = tool_call.dig("call_id") || tool_call.dig("id") || tool_call.dig('tool_call_id')
    if tool_call['function']
      function_name = tool_call.dig("function", "name")
      function_arguments = tool_call.dig("function", "arguments")
    else
      function_name = tool_call.dig("name")
      function_arguments = tool_call.dig("arguments")
    end

    function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments

    [tool_call_id, function_name, function_arguments]
  end

  def self.process_calls(tools, calls, &block)
    max_content_length = LLM.max_content_length
    IndiferentHash.setup tools

    start_timestamp = Chat.timestamp
    tool_call_content = calls.collect do |tool_call|
      tool_call = IndiferentHash.setup tool_call
      tool_call_id, function_name, function_arguments = call_id_name_and_arguments(tool_call)

      raise "No tool_call_id in #{ tool_call}" if tool_call_id.nil?

      function_arguments = IndiferentHash.setup function_arguments

      obj, definition = tools[function_name]

      definition = obj if Hash === obj

      defaults = definition[:parameters][:defaults] if definition && definition[:parameters]
      function_arguments = function_arguments.merge(defaults) if defaults

      Log.high "Calling #{function_name} (#{Log.fingerprint function_arguments}): "
      function_response = case obj
                          when Proc
                            obj.call function_name, function_arguments
                          when String
                            if Kernel.const_defined? obj
                              wt = Kernel.const_get obj
                            else
                              wf = Workflow.require_workflow obj
                            end
                            call_workflow(wf, function_name, function_arguments)
                          when Workflow
                            call_workflow(obj, function_name, function_arguments)
                          when KnowledgeBase
                            call_knowledge_base(obj, function_name, function_arguments.dup)
                          else
                            if block_given?
                              block.call function_name, function_arguments
                            else
                              ParameterException.new "Tool or function not found '#{function_name}'. Called with parameters #{Log.fingerprint function_arguments}" if obj.nil? && definition.nil?
                            end
                          end

      content = case function_response
                when Step
                  function_response
                when String
                  function_response
                when IO
                  function_response.read
                when TSV::Dumper
                  function_response.read
                when LLM::Agent
                  function_response
                when nil
                  "success"
                when Exception
                  {exception: function_response.message, stack: function_response.backtrace }.to_json
                else
                  begin
                    function_response.to_json
                  rescue Exception => e
                    begin
                      function_response.to_s
                    rescue
                      {exception: e.message, stack: e.backtrace }.to_json
                    end
                  end
                end

      content = content.to_s if Numeric === content

      function_call = tool_call.dup
      function_call = {'name' => tool_call['name']}.merge tool_call.except('name')

      function_call['id'] = function_call.delete('call_id') if function_call.dig('call_id')

      [
        function_name,
        function_arguments,
        tool_call_id,
        IndiferentHash.setup({role: "function_call", content: function_call.to_json}),
        content
      ]
    end

    jobs = tool_call_content.collect{|p| p.last }.select{|c| Step === c }
    
    if jobs.reject{|job| job.done? }.any?
      begin
        Workflow.produce jobs
      rescue
      end
    end

    agents = tool_call_content.collect{|p| p.last }.select{|c| LLM::Agent === c }

    agent_answers = TSV.setup({}, key_field: 'Pos', fields: ['Content', 'Job path'], type: :list)

    if agents.any?
      cpus = Scout::Config.get(:cpus, :agent_ask, :agents, env: 'ASK_AGENTS', default: 3)
      Open.traverse (0..agents.length-1).to_a, cpus: cpus, bar: 'Asking agents', type: :list, into: agent_answers do |i|
        agent = agents[i]
        res = agent.chat return_messages: true
        path = Step === agent.job ? agent.job.path : nil
        [i, [res, path]]
      end
    end

    tool_call_content.collect do |function_name,function_arguments,tool_call_id,tool_call,content|
      agent_meta = []
      if Step === content
        step = content
        if content.done?
          error = false
          content = content.load if content.done?
          content = content.to_s if TSV === content
          content = content.to_json unless String === content
        elsif content.error? && content.exception
          error = :error
          content = if String === content.exception
                      {exception: content.exception}.to_json
                    else
                      {exception: content.exception.message, stack: content.exception.backtrace }.to_json
                    end
        else
          begin
            content = content.run
            content = content.to_s if TSV === content
            content = content.to_json unless String === content
          rescue
            error = :error
            content = {exception: $!.message, stack: $!.backtrace }.to_json
          end
        end
      elsif LLM::Agent === content
        res, path = agent_answers[agents.index(content)]

        begin
          Chat.allow_read_job Step.load(path) 
        rescue
        end if path

        content.current_chat.follow(res)
        agent_meta = Chat.find_role(res, :meta)
        content = content.answer
      else
        step = nil
      end

      if (String === content) && content.length > max_content_length
        exception_msg = "Function #{function_name} #{tool_call_id} (#{Log.fingerprint function_arguments}) was executed successfully, but it returned #{content.length} characters, which is more than the maximum of #{max_content_length}. To protect the model context window this result was not returned. Here is a fingerprint of the content #{Log.fingerprint(content)}."
        exception_msg += " The results was persisted at '#{step.path}'." if step
        Log.high exception_msg
        content = {exception: exception_msg, stack: caller}.to_json
        error = :truncated
      end

      Log.high "Called #{function_name} #{tool_call_id} (#{Log.fingerprint function_arguments}): " + Log.fingerprint(content)

      response_message = {
        name: function_name,
        content: content,
        id: tool_call_id,
      }

      response_message[:error] = error if error
      response_message[:agent_meta] = agent_meta if agent_meta && agent_meta.any?

      if step
        response_message.merge!(
          step: step.short_path,
          start_timestamp: start_timestamp,
          timestamp: Chat.timestamp
        )
      else
        response_message.merge!(
          start_timestamp: start_timestamp,
          timestamp: Chat.timestamp
        )
      end


      json_content = begin
                       response_message.to_json
                     rescue
                       "Error turning content into JSON (#{$!.message}): #{Log.fingerprint response_message}"
                     end
      [ 
        tool_call,
        IndiferentHash.setup({role: "function_call_output", content: json_content})
      ]
    end.flatten
  end
end
