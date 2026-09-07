require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'
require 'scout/llm/tools/call'
require 'json'

# Regression guards for answer attribution when one tool round returns the
# SAME LLM::Agent object from several tool calls (two `ask` calls to one
# registered conversation, two delegate hand-offs to one specialist slot).
#
# Historical bug (call.rb ~184): outputs were paired with answers via
# `agent_answers[agents.index(content)]`; Array#index finds the FIRST
# occurrence, so every duplicate-agent call embedded the FIRST answer, and
# current_chat.follow(res) followed the wrong chat.
class TestLLMToolCallAgentPairing < Test::Unit::TestCase
  # ScoutCoder: LLM.process_answers asks agents through Open.traverse with
  # cpus from Scout::Config.get(:cpus, :agent_ask, :agents, env:
  # 'ASK_AGENTS', default: 3). LLM::Mock's response counter (@index) is
  # shared mutable state, so concurrent rounds race on it and answers get
  # duplicated/lost nondeterministically. Pin the collection to sequential
  # execution so pairing assertions are deterministic; the race is a test
  # harness limitation, not the behavior under test.
  setup do
    Scout::Config.set({cpus: 1}, :agent_ask, :agents)
  end

  def shared_worker
    LLM::Agent.new(start_chat: Chat.setup([{role: :system, content: 'worker helper'}]), endpoint: :mock)
  end

  def call(id, prompt)
    IndiferentHash.setup({
      'id' => id, 'type' => 'function',
      'function' => {'name' => 'ask', 'arguments' => {prompt: prompt}.to_json}
    })
  end

  # One tool whose block appends the prompt to the SHARED agent and returns
  # that same agent object from every call.
  def shared_agent_tool(worker)
    Proc.new do |_name, args|
      worker.user args[:prompt]
      worker
    end
  end

  def outputs_for(messages)
    messages.select { |m| m[:role].to_s == 'function_call_output' }
  end

  def output_content(message)
    JSON.parse(message[:content])['content']
  end

  def test_duplicate_agent_answers_pair_by_call_position
    TmpFile.with_dir do |_dir|
      LLM::Mock.script('first answer', 'second answer')

      worker = shared_worker

      result = LLM.process_calls({'ask' => [shared_agent_tool(worker), nil]}, [
        call('call_1', 'first question'),
        call('call_2', 'second question')
      ])

      outputs = outputs_for(result)
      assert_equal 2, outputs.length

      first_content = output_content(outputs[0])
      second_content = output_content(outputs[1])

      # Each function_call_output carries its OWN round's answer: call_1
      # answered "first answer", call_2 answered "second answer". The old
      # agents.index(content) pairing made BOTH carry "first answer".
      assert_equal 'first answer', first_content
      assert_equal 'second answer', second_content
      assert_not_equal first_content, second_content

      # The shared conversation itself followed BOTH rounds in order, so the
      # final answer (content.answer = last assistant message) is the second
      # round's.
      assert_equal 'second answer', worker.current_chat.answer

      # Both prompts reached the shared agent, in call order.
      user_messages = worker.current_chat.select { |m| m[:role].to_s == 'user' }.collect { |m| m[:content] }
      assert_equal ['first question', 'second question'], user_messages
    end
  end

  # The general case stays intact: DISTINCT agents in one round each get
  # their own answer (no cross-talk in either direction).
  def test_distinct_agents_pair_by_call_position
    TmpFile.with_dir do |_dir|
      LLM::Mock.script('left answer', 'right answer')

      left = shared_worker
      right = shared_worker

      tool = Proc.new do |_name, args|
        target = args[:prompt].include?('left') ? left : right
        target.user args[:prompt]
        target
      end

      result = LLM.process_calls({'ask' => [tool, nil]}, [
        call('call_1', 'left question'),
        call('call_2', 'right question')
      ])

      outputs = outputs_for(result)
      assert_equal 2, outputs.length
      assert_equal 'left answer', output_content(outputs[0])
      assert_equal 'right answer', output_content(outputs[1])

      assert_equal 'left answer', left.current_chat.answer
      assert_equal 'right answer', right.current_chat.answer
    end
  end

  # Mixed round: one agent-returning call and one plain String call. The
  # agent answer must still pair with the agent call, not shift into the
  # string output's position.
  def test_mixed_agent_and_string_outputs_pair_correctly
    TmpFile.with_dir do |_dir|
      LLM::Mock.script('agent answer')

      worker = shared_worker
      seen = nil
      tool = Proc.new do |_name, args|
        if args[:prompt].include?('string')
          seen = 'plain result'
        else
          worker.user args[:prompt]
          worker
        end
      end

      result = LLM.process_calls({'ask' => [tool, nil]}, [
        call('call_1', 'agent question'),
        call('call_2', 'string question')
      ])

      outputs = outputs_for(result)
      assert_equal 2, outputs.length
      assert_equal 'agent answer', output_content(outputs[0])
      assert_equal 'plain result', output_content(outputs[1])
      assert_equal 'agent answer', worker.current_chat.answer
      assert_equal 'plain result', seen
    end
  end
end
