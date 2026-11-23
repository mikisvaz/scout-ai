# encoding: utf-8
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

class TestCallDelegationConflict < Test::Unit::TestCase
  def setup
    super
  end

      # `call(id, name, args)` and `ask_call(id, args)` helpers: providers send
      # the function name and a JSON arguments string; process_calls receives
      # that provider shape unchanged.
      def call(id, name, arguments)
        IndiferentHash.setup(
          'id' => id,
          'type' => 'function',
          'function' => {
            'name' => name.to_s,
            'arguments' => arguments.to_json
          }
        )
      end

      def ask_call(id, arguments)
        call(id, 'ask', arguments)
      end

      def hand_off_call(id, arguments)
        call(id, 'hand_off_to_Worker', arguments)
      end

      # Register the real socialize ask tool on a parent agent so the delegated
      # agents are produced by the production path, then dispatch calls through
      # LLM.process_calls with a save-file-bearing parent so conversations are
      # persisted (anchor save files are derived from it).
      def dispatch(parent, tool_calls)
        tools = parent.other_options[:tools] || {}
        LLM.process_calls(tools, tool_calls)
      end

      def parent_with_ask(dir)
        parent = LLM::Agent.new(
          start_chat: Chat.setup([{role: :system, content: 'orchestrator'}])
        )
        parent.save_file = File.join(dir, 'root.chat')
        # The ask tool and a pre-registered Worker template, so the delegated
        # agents are produced by the production path (socialize + society).
        parent.society = {'Worker' => worker_agent}
        parent.socialize
        parent
      end

      def worker_agent(content = 'worker helper')
        LLM::Agent.new(
          start_chat: Chat.setup([{role: :system, content: content}])
        )
      end

      # Tool-round outputs are function_call_output messages whose content is
      # the JSON envelope {id, name, content, error} (no error key when the
      # call succeeded). Parse them into a convenient array of hashes.
      def outputs_of(result)
        result
          .select { |m| m[:role].to_s == 'function_call_output' }
          .collect { |m| JSON.parse(m[:content]) }
      end

      # A mixed tool round: one ordinary side-effecting Proc tool runs before
      # the delegations. Its result must survive a delegation conflict: the
      # conflict invalidates the agent sub-batch, not the whole round.
      def parent_with_ask_and_write(dir)
        parent = parent_with_ask(dir)
        tools = parent.other_options[:tools]
        tools[:write] = [
          Proc.new do |_name, args|
            Open.write(File.join(dir, args[:path]), args[:text])
            "written #{args[:path]}"
          end,
          LLM.tool_definition(:write, 'Write a file',
                              {path: {type: 'string'}, text: {type: 'string'}},
                              required: [:path, :text])
        ]
        parent.other_options[:tools] = tools
        parent
      end

      # The original hang: two delegations of one round, no conversation name,
      # both resolving onto Worker/default. The round now completes with two
      # error envelopes instead of blocking forever; Timeout remains the
      # honest bound on the regression.
      def test_two_unnamed_delegations_of_one_round_return_errors_instead_of_hanging
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)

            outputs = nil
            assert_nothing_raised do
              outputs = outputs_of dispatch(parent, [
                ask_call('call_1', {agent: 'Worker', prompt: 'do X'}),
                ask_call('call_2', {agent: 'Worker', prompt: 'do Y'})
              ])
            end

            assert_equal 2, outputs.length
            outputs.each do |out|
              assert_equal 'error', out['error']
              assert_match(/Conflicting delegations/, out['content']
                .sub(/^\{"exception":/, '')
                .sub(/"\}$/, ''))
            end
            # No specialist was started and nothing was persisted.
            assert_equal 0, LLM::Mock.index
            assert !Open.exist?(File.join(dir, 'root.society'))
          end
        end
      end

      # Same shape with an explicit conversation name.
      def test_two_named_delegations_of_one_round_return_errors
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)

            outputs = outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X', conversation: 'task_1'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do Y', conversation: 'task_1'})
            ])

            assert_equal 2, outputs.length
            outputs.each do |out|
              assert_equal 'error', out['error']
              assert_match(/task_1/, out['content'])
            end
          end
        end
      end

      # The whole agent sub-batch is rejected, including delegations that
      # target a distinct conversation: all-or-nothing keeps the rule
      # predictable for the model.
      def test_partial_conflict_rejects_all_delegations_of_the_round
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)

            outputs = outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do Y'}),
              ask_call('call_3', {agent: 'Worker', prompt: 'do Z', conversation: 'other'})
            ])

            assert_equal 3, outputs.length
            outputs.each do |out|
              assert_equal 'error', out['error']
            end
            # Even the delegation to a distinct conversation did not run.
            assert_equal 0, LLM::Mock.index
            other = parent.conversation_agent('Worker/other')
            assert other.nil? || other.current_chat.none? { |m| m[:role].to_s == 'user' }
          end
        end
      end

      # Ordinary tool calls of the same round are untouched: their side
      # effects have already happened and the model must see their results.
      def test_side_effecting_tool_of_the_same_round_keeps_its_result
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask_and_write(dir)

            outputs = outputs_of dispatch(parent, [
              call('call_1', 'write', {path: 'out.txt', text: 'hello'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do X'}),
              ask_call('call_3', {agent: 'Worker', prompt: 'do Y'})
            ])

            assert_equal 3, outputs.length
            assert_equal 'written out.txt', outputs.first['content']
            assert !outputs.first.key?('error')
            assert_equal 'write', outputs.first['name']

            assert File.read(File.join(dir, 'out.txt')) == 'hello'
            outputs[1..-1].each do |out|
              assert_equal 'error', out['error']
            end
          end
        end
      end

      # ask and a hand_off slot resolve onto the same conversation holder
      # (Worker/Worker: the slot named after the specialist) and conflict
      # inside one round.
      def test_ask_and_hand_off_onto_the_same_conversation_conflict
        LLM::Mock.script('worker answer')
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)
            parent.delegate(parent.society['Worker'], 'Worker', 'Hand work off')

            # `hand_off_to_Worker` asks the conversation named after its slot,
            # so an `ask` naming that same conversation collides with it.
            outputs = outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X', conversation: 'Worker'}),
              hand_off_call('call_2', {message: 'do Y'})
            ])

            assert_equal 2, outputs.length
            outputs.each do |out|
              assert_equal 'error', out['error']
              assert_match(/Conflicting delegations/, out['content'])
            end
          end
        end
      end

      # A conflicting batch restores the live conversation EXACTLY, whatever
      # mixture of delegation forms staged it: plain continuation prompts, a
      # clear_tools continuation (which staged a context-only marker before
      # its prompt), and a hand_off new_conversation RESTART (which had
      # already re-branched the chat in place before the conflict was even
      # detected). Both delegations of the same slot hold the SAME holder
      # object (the `@chats` registry returns one agent per conversation
      # key), so this also covers one chat mutated through two agent
      # references. Compare the complete message list, roles and contents,
      # before and after.
      def test_rejected_batch_restores_the_conversation_exactly
        LLM::Mock.script('worker answer')
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)
            parent.delegate(parent.society['Worker'], 'Worker', 'Hand work off')

            # Round 0: establish Worker/Worker with one completed turn.
            outputs_of dispatch(parent, [
              hand_off_call('call_0', {message: 'seed turn'})
            ])
            holder = parent.conversation_agent('Worker/Worker')
            before = holder.current_chat.collect { |m| [m[:role], m[:content]] }

            # Round 1: three staged delegations onto the same conversation:
            # plain ask, clear_tools ask, and a restarting hand_off.
            outputs = outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X', conversation: 'Worker'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do Y', conversation: 'Worker', inherit: 'clear_tools'}),
              hand_off_call('call_3', {message: 'do Z', new_conversation: true})
            ])

            assert_equal 3, outputs.length
            outputs.each do |out|
              assert_equal 'error', out['error']
              assert_match(/Conflicting delegations/, out['content'])
            end

            after = holder.current_chat.collect { |m| [m[:role], m[:content]] }
            assert_equal before, after

            # The undo left no restart bookkeeping behind either.
            assert_nil holder.restart_undo_stash
          end
        end
      end

      # A valid batch still works after a rejected one, and the rejected
      # prompts do not leak into the conversation: preparation appends them
      # in memory, and a rejected batch rolls them back before the round
      # finishes.
      def test_valid_delegation_after_rejection_starts_clean
        LLM::Mock.script('worker answer')
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)

            outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do Y'})
            ])

            second = outputs_of dispatch(parent, [
              ask_call('call_3', {agent: 'Worker', prompt: 'do W'})
            ])

            assert_equal 1, second.length
            assert !second.first.key?('error')
            assert_equal 'worker answer', second.first['content']

            child = parent.conversation_agent('Worker/default')
            user_turns = child.current_chat
                              .select { |m| m[:role].to_s == 'user' }
                              .collect { |m| m[:content] }
            assert_equal ['do W'], user_turns
          end
        end
      end

      # Distinct conversations of one round execute normally and their answers
      # are paired to the original calls. All specialists share one scripted
      # answer, so the observable fact is that both calls were answered.
      def test_distinct_conversations_of_one_round_still_work
        LLM::Mock.script('worker answer')
        Timeout.timeout(30) do
          TmpFile.with_dir do |dir|
            parent = parent_with_ask(dir)

            outputs = outputs_of dispatch(parent, [
              ask_call('call_1', {agent: 'Worker', prompt: 'do X', conversation: 'one'}),
              ask_call('call_2', {agent: 'Worker', prompt: 'do Y', conversation: 'two'})
            ])

            assert_equal 2, outputs.length
            contents = outputs.collect { |out| out['content'] }
            assert contents.all? { |c| c == 'worker answer' }
            outputs.each { |out| assert !out.key?('error') }
          end
        end
      end
end
