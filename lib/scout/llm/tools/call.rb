require_relative '../request_context'
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

    function_arguments = begin
                           JSON.parse(function_arguments, { symbolize_names: true })
                         rescue JSON::ParserError
                           {error: "Error parsing function arguments - #{$!.message}"}
                         end if String === function_arguments

    [tool_call_id, function_name, function_arguments]
  end

  # Normalize serialized meta messages (the chat-message shape
  # {role: 'meta', content: 'k=v k=v ...'}) into the receipt format: an Array
  # of DESERIALIZED field Hashes, as emitted under the `meta` key of
  # function_call_output envelopes.
  #
  # Non-Hash entries, non-meta roles, non-String contents and entries that
  # parse to no fields at all are dropped.  The reader side keeps the full
  # malformed-entry warning taxonomy; the writer side simply never emits an
  # entry that carries no evidence.
  def self.meta_receipt_from_messages(messages)
    Array(messages).collect do |msg|
      next nil unless Hash === msg
      role = msg[:role] || msg['role']
      content = msg[:content] || msg['content']
      next nil unless role.to_s == 'meta' && String === content
      fields = Chat.parse_meta(content)
      fields.empty? ? nil : fields
    end.compact
  end

  def self.process_calls(tools, calls, save_file: nil, request_context: nil, &block)
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
                            call_workflow(wf, function_name, function_arguments, request_context: request_context)
                          when Workflow
                            call_workflow(obj, function_name, function_arguments, request_context: request_context)
                          when KnowledgeBase
                            call_knowledge_base(obj, function_name, function_arguments.dup)
                          else
                            if block_given?
                              LLM.call_tool_callback(block, function_name, function_arguments, request_context)
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
                  function_response
                when Hash
                  IndiferentHash.setup(function_response)
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
    jobs.each { |job| job.extend(RequestContext::StepExtension) if request_context }
    workload = jobs.reject{|job| job.done? }
    if workload.any?
      # Live-workload sidecar to help provenance traversal: a SIBLING of the
      # chat save_file holding the short paths of every workflow job still in
      # flight, rewritten per round (it is a snapshot of the CURRENT set, not
      # an append log) and removed in the ensure once Workflow.produce returns
      # -- on success AND on error. Path derivation goes through
      # Chat.jobs_file, the one trailing-strip sibling rule shared with
      # .inbox/.inbox_removed.
      jobs_file = Chat.jobs_file(save_file) if save_file
      workload.each{|job| job.rec_dependencies.each{|job| job.init_info }; job.init_info }
      Open.write(jobs_file, workload.collect{|j| j.short_path } * "\n") if jobs_file
      begin
        Workflow.produce jobs
      rescue
      ensure
        Open.rm jobs_file if jobs_file && Open.exists?(jobs_file)
      end
    end

    agents = tool_call_content.collect{|p| p.last }.select{|c| LLM::Agent === c }

    # ScoutCoder: the delegations of one tool round are executed in parallel
    # by the Open.traverse below, and a specialist conversation is persisted
    # by exactly ONE save file: two pending delegations onto the same save
    # file would drive (and auto-save) that conversation twice concurrently,
    # which used to block forever on the persistence lock. Validate the
    # batch here, before any specialist is started, and report the faulty
    # plan as tool errors instead of raising out of the round: every
    # delegation of the round is replaced with one ScoutException (rendered
    # by the Exception branch below through the same channel as any other
    # tool error), while the round's OTHER tool calls keep their normal,
    # already-computed results. Agent objects are not compared because two
    # delegation entry points can mint distinct objects for the same
    # persisted conversation; save_file is the actual persistence target,
    # which is the identity this invariant protects.
    conflicted = agents.collect(&:save_file).compact.tally.select{|_f, count| count > 1 }.keys
    if conflicted.any?
      exception = ScoutException.new(
        "Conflicting delegations: multiple agent executions of this round " \
        "target the same saved conversation #{conflicted.join(", ")}. A " \
        "conversation can be advanced by only one delegation at a time. " \
        "Use distinct conversation names, or delegate sequentially " \
        "(across rounds) so each conversation runs one turn at a time. No " \
        "specialist of this round was started, and every delegation of " \
        "this round was rejected together with it; the round's other tool " \
        "calls were not affected."
      )

      # Un-stage what this round appended so a retried plan finds each
      # conversation exactly as before the faulty round. Delegation staging
      # appended one user prompt per delegation (preceded, for a
      # clear_tools continuation, by one context-only marker), and no save
      # has happened yet -- saving starts inside Agent#chat, which none of
      # these delegations reached -- so the chats are still memory-only.
      # Walk the calls newest first and pop the matching tail; a marker
      # directly before a staged prompt can only be the marker staged by
      # that same delegation (an earlier round's marker is followed by its
      # own prompt and answer).
      # One delegation in the rejected batch may have asked for a RESTART of
      # an existing conversation (hand_off's new_conversation, or
      # ask_conversation's restart): Agent#start then saved a snapshot of the
      # prior chat to <save_file>.files/resets/ and re-branched in place
      # (keeping start_chat, dropping everything after it) BEFORE this
      # validation ran. Popping the staged prompt is not enough there: the
      # turns the conversation had accumulated are gone from the live chat.
      # Un-restart them: pop the staged prompt off the restart branch and
      # swap back in the exact pre-restart chat object that Agent#start
      # displaced. The snapshot file under resets/ is only an append-only
      # recovery record of what was displaced, never read back by the live
      # conversation, so it needs no compensating action. This runs BEFORE
      # the plain prompt pops below: the restored chat does not end with the
      # staged prompt (it ends where the old conversation ended), so the
      # plain pop loop leaves it alone.
      tool_call_content.reverse_each do |_function_name, function_arguments, _tool_call_id, _tool_call, content|
        next unless LLM::Agent === content
        next unless function_arguments[:new_conversation] || function_arguments[:restart]
        next unless (prior = content.restart_undo_stash)
        content.restart_undo_stash = nil
        chat = content.current_chat
        prompt = function_arguments[:prompt] || function_arguments[:message]
        if chat.last && chat.last[:role].to_s == 'user' && chat.last[:content] == prompt
          chat.pop
          content.restore_restarted_chat(prior)
        end
      end

      tool_call_content.reverse_each do |function_name, function_arguments, _tool_call_id, _tool_call, content|
        next unless LLM::Agent === content
        chat = content.current_chat
        prompt = function_arguments[:prompt] || function_arguments[:message]
        next unless chat.last && chat.last[:role].to_s == 'user' && chat.last[:content] == prompt
        chat.pop
        if function_arguments[:inherit].to_s == 'clear_tools' &&
           chat.last && chat.last[:role].to_s == 'clear_tools'
          chat.pop
        end
      end

      tool_call_content.each{|entry| entry[-1] = exception if LLM::Agent === entry.last }
      agents = []
    end

    agent_answers = TSV.setup({}, key_field: 'Pos', fields: ['Content', 'Job path'], type: :list)

    if agents.any?
      cpus = Scout::Config.get(:cpus, :agent_ask, :agents, env: 'ASK_AGENTS', default: 3)
      Open.traverse (0..agents.length-1).to_a, cpus: cpus, bar: 'Asking agents', type: :list, into: agent_answers do |i|
        agent = agents[i]
        res = agent.chat return_messages: true, request_context: request_context
        path = Step === agent.job ? agent.job.path : nil
        [i, [res, path]]
      end
    end

    # ScoutCoder: each agent-returning tool call must be paired with the
    # answer produced by ITS OWN round. `agents.index(content)` returns the
    # position of the FIRST occurrence, so two calls in one round returning
    # the SAME Agent (two `ask` calls to one registered conversation, or two
    # delegate calls to the same specialist slot) both embedded the FIRST
    # answer in every `function_call_output` message and followed the wrong
    # chat. Pair by tool-call position instead: the n-th agent-returning
    # call consumes the n-th collected answer.
    agent_call_positions = {}
    tool_call_content.each_with_index do |entry, position|
      agent_call_positions[position] = agent_call_positions.length if LLM::Agent === entry.last
    end

    tool_call_content.each_with_index.collect do |(function_name,function_arguments,tool_call_id,tool_call,content), call_position|
      error = false
      stack = nil
      meta = []
      if Step === content
        step = content
        Chat.allow_read_job step
        if content.done?
          content = content.load
        elsif content.error? && content.exception
          error = :error
          content = if String === content.exception
                      {exception: content.exception}.to_json
                    elsif Hash === content.exception
                      content = content.exception
                    else
                      content = {exception: content.exception.message, exception_line: content.exception.backtrace&.first}.to_json
                    end
        else
          begin
            content = content.run
          rescue Exception
            error = :error
            stack = $!.backtrace
            content = {exception: $!.message, exception_line: $!.backtrace&.first}.to_json
          end
        end
      elsif LLM::Agent === content
        res, path = agent_answers[agent_call_positions[call_position]]

        begin
          Chat.allow_read_job Step.load(path) 
        rescue
        end if path

        content.current_chat.follow(res)
        # Receipt format: the child agent's meta messages are DESERIALIZED
        # into plain field Hashes and emitted under the `meta` key (the
        # legacy serialized `agent_meta` array is no longer written).
        # Entries that parse to no fields are dropped: a receipt entry
        # exists to carry evidence fields, and an empty one carries none.
        meta = LLM.meta_receipt_from_messages(Chat.find_role(res, :meta))
        content = content.answer
      elsif Exception === content
        error = :error
        stack = content.backtrace
        content = {exception: content.message, exception_line: content.backtrace&.first}.to_json
      else
        step = nil
      end


      begin
        content = case content
                  when Hash
                    # ScoutCoder: When the response of the function contains a
                    # Hash with exactly two keys, content and meta, treat it as
                    # content with inference meta. Extract accordingly.
                    content = IndiferentHash.setup(content)
                    keys = content.keys.collect{|k| k.to_s }
                    if keys.sort == %w(content meta)
                      # `meta` is the deserialized receipt array; pass it
                      # through verbatim.
                      meta, content = content.values_at :meta, :content
                      content
                    else
                      content.to_json
                    end
                  when TSV
                    content.to_s
                  when String
                    content
                  else
                    content.to_json
                  end

        if (String === content) && content.length > max_content_length
          exception_msg = "Function #{function_name} #{tool_call_id} (#{Log.fingerprint function_arguments}) was executed successfully, but it returned #{content.length} characters, which is more than the maximum of #{max_content_length}. To protect the model context window this result was not returned. Here is a fingerprint of the content #{Log.fingerprint(content)}."
          exception_msg += " The results was persisted at '#{step.path}'." if step
          Log.high exception_msg
          content = {exception: exception_msg, stack: caller}.to_json
          error = :truncated
        end

        Log.high "Called #{function_name} #{tool_call_id} (#{Log.fingerprint function_arguments}): " + Log.fingerprint(content)
      rescue ScoutException => e
        error = :scout
        stack = e.backtrace
        content = {exception: e.message, exception_line: e.backtrace&.first}.to_json
      rescue => e
        Log.exception e
        error = :harness
        stack = e.backtrace
        content = {exception: e.message, exception_line: e.backtrace&.first}.to_json
      end

      response_message = {
        name: function_name,
        content: content,
        id: tool_call_id,
      }

      response_message[:error] = error if error
      response_message[:stack] = stack if stack
      meta = [meta] if Hash === meta
      response_message[:meta] = meta if meta && meta.any?

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
