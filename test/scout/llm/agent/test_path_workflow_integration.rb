require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"


# ---------------------------------------------------------------------------
# Whole-workflow PATH_KINDS incorporation (`tool: Workflow` chat semantic).
#
# Mirrors lib/scout/llm/agent.rb (the `tool:` hook inside Agent#ask) and
# lib/scout/llm/agent/path.rb (`integrate_workflow_path_kinds`).  Test-local
# workflow modules are defined at the bottom of the file and reused across
# these tests; the mock backend drives Agent#ask end to end offline
# (LLM::Mock, test/support/mock_backend.rb, backend :mock from
# test/test_helper.rb).  Every test uses a fresh agent so no kind ever leaks
# between tests.
# ---------------------------------------------------------------------------
class TestPathWorkflowKindIntegration < Test::Unit::TestCase
  def setup
    @tmpdir = Scout.tmp.agent_path_kind_test.find
    FileUtils.mkdir_p(@tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def fresh_agent
    LLM.agent
  end

  def ask_with(agent, chat_text)
    LLM::Mock.script('ok')
    agent.prompt LLM.chat(chat_text), persist: false, endpoint: 'mock', backend: :mock
  end

  # -- registration through whole-workflow `tool:` ---------------------------

  def test_whole_workflow_tool_line_registers_kinds_and_installs_tools
    # Back-compat, re-scoped (step 2 of the path_kind role): the whole-workflow
    # `tool:` kind incorporation now happens only for an UNPREPARED agent (no
    # start_chat file).  With a prepared start_chat the same line configures
    # tools only -- see test_start_chat_present_zero_kinds_from_tool_lines.
    agent = LLM::Agent.new(workflow: TestPathKindWorkflowB)
    assert !agent.start_chat_file?
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\ndo things")

    assert agent.path_kind_registry.key?('wfa_kind')
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']

    tool_names = (agent.other_options[:tools] || {}).keys
    %w[path_kinds path_read path_write].each do |tool|
      assert tool_names.include?(tool), "expected #{tool} in #{tool_names.inspect}"
    end
  end

  def test_task_level_tool_line_registers_nothing
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowB t\nuser\ndo things")

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
    assert_empty (agent.other_options[:tools] || {}).keys
      .select { |name| name.start_with?('path_') }
  end

  def test_workflow_without_path_kinds_is_silent_noop
    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone)

    ask_with(agent, "tool: TestPathKindWorkflowNone\nuser\ndo things")
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_merely_defining_the_module_registers_nothing
    # Negative baseline: TestPathKindWorkflowA's PATH_KINDS exists in the
    # constant table, but a fresh agent that never incorporates the workflow
    # has an empty registry.
    agent = fresh_agent
    assert TestPathKindWorkflowA.const_defined?(:PATH_KINDS, false)
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
    assert_empty (agent.other_options[:tools] || {}).keys
  end

  # -- conflict / idempotence -------------------------------------------------

  def test_conflict_between_two_workflows_raises_naming_both
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nfirst")

    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowConflict)
    end

    assert_include error.message, 'wfa_kind'
    assert_include error.message, 'TestPathKindWorkflowA'
    assert_include error.message, 'TestPathKindWorkflowConflict'
    # the first registration survives the rejected second one
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']
  end

  def test_same_workflow_repeated_is_idempotent
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nfirst")
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nsecond")

    assert_equal ['wfa_kind'], agent.path_kind_registry.keys
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']

    tool_names = (agent.other_options[:tools] || {}).keys
    assert_equal tool_names, tool_names.uniq
    assert_equal 1, tool_names.count('path_kinds')
  end

  # -- shape validation --------------------------------------------------------

  def test_shape_error_names_workflow_and_class
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowBadShape)
    end

    assert_include error.message, 'TestPathKindWorkflowBadShape'
    assert_include error.message, 'String'
  end

  def test_array_of_definition_hashes_is_accepted
    agent = fresh_agent
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray)

    assert agent.path_kind_registry.key?('arr_first')
    assert agent.path_kind_registry.key?('arr_second')
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']
  end

  def test_entry_without_hash_definition_is_rejected
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowBadEntry)
    end
    assert_include error.message, 'TestPathKindWorkflowBadEntry'
  end

  # -- subset selection (`only:`) -----------------------------------------------

  def test_without_selection_registers_every_kind_unchanged
    # The all-kinds contract, pinned beside the subset behavior: nil and an
    # empty list are both the historical call.
    %w[nil empty_array].each do |variant|
      agent = fresh_agent
      case variant
      when 'nil'
        result = agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: nil)
      when 'empty_array'
        result = agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: [])
      end
      assert_equal %w[arr_first arr_second], result.keys.sort
      assert_equal %w[arr_first arr_second], agent.path_kind_registry.keys.sort
      assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']
      assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_second']
    end
  end

  def test_subset_registers_exactly_the_named_kinds
    agent = fresh_agent
    result = agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: ['arr_second'])

    assert_equal ['arr_second'], agent.path_kind_registry.keys
    assert_equal ['arr_second'], result.keys
    assert_nil agent.path_kind_sources['arr_first']
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_second']

    tool_names = (agent.other_options[:tools] || {}).keys
    assert_include tool_names, 'path_read'
    # the kind enum on the installed tools reflects the subset
    kind_enum = (agent.other_options[:tools]['path_kinds'].last)[:parameters][:properties][:kind][:enum]
    assert_equal ['arr_second'], kind_enum
  end

  def test_subset_accepts_a_single_name_and_symbols
    agent = fresh_agent
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: :arr_first)

    assert_equal ['arr_first'], agent.path_kind_registry.keys
  end

  def test_unknown_kind_in_selection_raises_naming_workflow_and_kind
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: ['arr_first', 'nope'])
    end

    assert_include error.message, 'TestPathKindWorkflowArray'
    assert_include error.message, 'nope'
    # cheap, welcome diagnostics: the valid names are listed
    assert_include error.message, 'arr_second'
    # the failed call registered nothing
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_workflow_without_path_kinds_with_selection_raises
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone, only: ['anything'])
    end

    assert_include error.message, 'TestPathKindWorkflowNone'
    assert_include error.message, 'anything'
    assert_empty agent.path_kind_registry
  end

  def test_workflow_without_path_kinds_without_selection_stays_noop
    # Existing contract restated beside the selection behavior: no
    # PATH_KINDS, no selection -> silent nil, nothing registered.
    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone)
    assert_nil agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone, only: nil)
    assert_nil agent.integrate_workflow_path_kinds(TestPathKindWorkflowNone, only: [])
    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_subset_repeated_is_idempotent_and_conflict_aware
    # selection keeps the conflict bookkeeping: the same subset from the
    # same workflow is idempotent, and a second workflow's kind still
    # conflicts even when it is the selected one.
    agent = fresh_agent
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: ['arr_first'])
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowArray, only: ['arr_first'])
    assert_equal ['arr_first'], agent.path_kind_registry.keys

    # unrelated names do not interfere: the unselected arr_first does not
    # block another workflow's wfa_kind
    agent.integrate_workflow_path_kinds(TestPathKindWorkflowA, only: ['wfa_kind'])
    assert_equal %w[arr_first wfa_kind], agent.path_kind_registry.keys.sort

    error = assert_raise(ParameterException) do
      agent.integrate_workflow_path_kinds(TestPathKindWorkflowConflict, only: ['wfa_kind'])
    end
    assert_include error.message, 'wfa_kind'
    assert_equal %w[arr_first wfa_kind], agent.path_kind_registry.keys.sort
  end

  # -- `path_kind:` chat role --------------------------------------------------

  def test_path_kind_all_kinds_line_registers_and_installs_tools
    agent = fresh_agent
    ask_with(agent, "path_kind: TestPathKindWorkflowArray\nuser\ndo things")

    assert_equal %w[arr_first arr_second], agent.path_kind_registry.keys.sort
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']

    tool_names = (agent.other_options[:tools] || {}).keys
    %w[path_kinds path_read path_write].each do |tool|
      assert tool_names.include?(tool), "expected #{tool} in #{tool_names.inspect}"
    end
  end

  def test_path_kind_subset_line_registers_only_the_named_kind
    agent = fresh_agent
    ask_with(agent, "path_kind: TestPathKindWorkflowArray arr_second\nuser\ndo things")

    assert_equal ['arr_second'], agent.path_kind_registry.keys
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_second']
    assert_nil agent.path_kind_sources['arr_first']
  end

  def test_path_kind_multi_kind_line_and_separate_lines_accumulate
    agent = fresh_agent
    ask_with(agent, "path_kind: TestPathKindWorkflowArray arr_first arr_second\npath_kind: TestPathKindWorkflowA\nuser\ndo things")

    assert_equal %w[arr_first arr_second wfa_kind], agent.path_kind_registry.keys.sort
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']
  end

  def test_path_kind_unknown_kind_raises_parameter_exception
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      ask_with(agent, "path_kind: TestPathKindWorkflowArray nope\nuser\ndo things")
    end

    assert_include error.message, 'TestPathKindWorkflowArray'
    assert_include error.message, 'nope'
    assert_empty agent.path_kind_registry
  end

  def test_path_kind_unloadable_workflow_raises
    agent = fresh_agent
    error = assert_raise(ParameterException) do
      ask_with(agent, "path_kind: NoSuchWorkflowForPathKinds kind\nuser\ndo things")
    end

    assert_include error.message, 'NoSuchWorkflowForPathKinds'
    assert_empty agent.path_kind_registry
  end

  def test_path_kind_line_honored_from_start_chat
    # start_chat path: an agent built with an explicit prepared start_chat
    # (start_chat_file? true) still honors an explicit path_kind line in it,
    # while its whole-workflow `tool:` line stays tools-only.
    agent = fresh_agent
    agent.start_chat = LLM.chat("tool: TestPathKindWorkflowA\npath_kind: TestPathKindWorkflowArray arr_first\nsystem\nprepared")
    assert agent.start_chat_file?

    ask_with(agent, "user\ndo things")

    assert_equal ['arr_first'], agent.path_kind_registry.keys
    assert_equal 'TestPathKindWorkflowArray', agent.path_kind_sources['arr_first']
  end

  def test_start_chat_present_zero_kinds_from_tool_lines
    agent = fresh_agent
    agent.start_chat = LLM.chat("tool: TestPathKindWorkflowA\nsystem\nprepared")
    assert agent.start_chat_file?

    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\ndo things")

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_start_chat_file_false_falls_back_to_load_all
    # Unprepared agent (no start_chat at all): its own workflow's PATH_KINDS
    # load implicitly.
    agent = LLM::Agent.new(workflow: TestPathKindWorkflowA)
    assert !agent.start_chat_file?

    ask_with(agent, "user\ndo things")

    assert_equal ['wfa_kind'], agent.path_kind_registry.keys
    assert_equal 'TestPathKindWorkflowA', agent.path_kind_sources['wfa_kind']
  end

  def test_synthetic_introduce_start_chat_still_loads_all
    # load_agent's synthetic `introduce` fallback is NOT a start_chat file:
    # implicit loading stays on (the flag load_agent sets is false).
    agent = LLM::Agent.new(workflow: TestPathKindWorkflowA,
                           start_chat: Chat.setup([{role: 'introduce', content: 'TestPathKindWorkflowA'}]))
    agent.start_chat_file = false
    assert !agent.start_chat_file?

    ask_with(agent, "user\ndo things")

    assert_equal ['wfa_kind'], agent.path_kind_registry.keys
  end

  def test_path_kind_content_never_reaches_the_model
    # Mock-backend proof: registration happened AND no path_kind content is
    # model-visible in any round the backend recorded.
    agent = fresh_agent
    ask_with(agent, "path_kind: TestPathKindWorkflowArray arr_first\nuser\ndo things")

    assert_equal ['arr_first'], agent.path_kind_registry.keys
    LLM::Mock.calls.each do |round_messages, _options|
      assert !round_messages.any? { |m| m[:role].to_s == 'path_kind' },
             "path_kind content reached the model: #{round_messages.collect{|m| m[:role]}.inspect}"
    end
  end

  def test_clear_tools_does_not_bypass_path_kind_registration
    # clear_tools strips earlier tool-call traces for the MODEL, but path_kind
    # registration is driven from the full message list before any stripping.
    agent = fresh_agent
    ask_with(agent, "clear_tools\npath_kind: TestPathKindWorkflowArray arr_second\nuser\ndo things")

    assert_equal ['arr_second'], agent.path_kind_registry.keys
  end

  # -- namespace locality -------------------------------------------------------

  def test_nested_module_does_not_inherit_parent_path_kinds
    agent = fresh_agent
    assert TestPathKindParent::PATH_KINDS.is_a?(Hash)
    # nesting: child has no namespace-local PATH_KINDS
    assert !TestPathKindParent::Child.const_defined?(:PATH_KINDS, false)

    assert_nil agent.integrate_workflow_path_kinds(TestPathKindParent::Child)
    assert_empty agent.path_kind_registry
  end

  def test_subclass_does_not_inherit_parent_path_kinds
    agent = fresh_agent
    # const_defined? without the inherit flag WOULD see the parent constant
    assert TestPathKindSubclassed.const_defined?(:PATH_KINDS)
    assert !TestPathKindSubclassed.const_defined?(:PATH_KINDS, false)

    assert_nil agent.integrate_workflow_path_kinds(TestPathKindSubclassed)
    assert_empty agent.path_kind_registry
  end

  def test_remote_workflow_namespace_returns_nil
    require 'rbbt'
    require 'scout/offsite/ssh'
    require 'rbbt/workflow/remote_workflow'

    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds(RemoteWorkflow)
    assert_empty agent.path_kind_registry
  end

  def test_anonymous_module_returns_nil
    agent = fresh_agent
    anonymous = Module.new { extend Workflow }
    assert_nil agent.integrate_workflow_path_kinds(anonymous)
    assert_empty agent.path_kind_registry
  end

  def test_non_module_object_returns_nil
    agent = fresh_agent
    assert_nil agent.integrate_workflow_path_kinds('TestPathKindWorkflowA')
    assert_nil agent.integrate_workflow_path_kinds(nil)
    assert_empty agent.path_kind_registry
  end

  # -- frozen constant isolation --------------------------------------------------

  def test_frozen_path_kinds_constant_is_never_mutated
    agent = fresh_agent
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\ndo things")

    constant = TestPathKindWorkflowA::PATH_KINDS
    # --- nested-structure isolation (both directions) ---
    # Mutating the CONSTANT's nested structures after registration must not
    # reach the agent's registered copy...
    constant['wfa_kind']['description'] = 'CONST-NESTED-MUTATION'
    registered = agent.path_kind_registry['wfa_kind']
    assert_equal 'Kind exported by TestPathKindWorkflowA', registered['description']
    assert !registered['roots'].equal?(constant['wfa_kind']['roots'])
    assert !registered['locations'].equal?(constant['wfa_kind']['locations'])
    original = constant['wfa_kind'].dup

    registered = agent.path_kind_registry['wfa_kind']
    refute_same constant['wfa_kind'], registered
    refute_same constant, registered

    # mutating the registered copy leaves the constant untouched
    registered['description'] = 'mutated through the registry'
    assert_equal original['description'], constant['wfa_kind']['description']

    # re-registration does not write "name" or normalization back either
    ask_with(agent, "tool: TestPathKindWorkflowA\nuser\nagain")
    assert_nil constant['wfa_kind']['name']
    assert_equal original, constant['wfa_kind']
  end

  # -- `path:` chat role removal ---------------------------------------------------

  def test_path_role_no_longer_installs_path_tools
    agent = fresh_agent
    ask_with(agent, "path: true\nuser\nhello")

    assert_empty agent.path_kind_registry
    assert_empty (agent.other_options[:tools] || {}).keys
  end

  def test_path_role_survives_in_messages_unconsumed
    # Observed behavior after the role removal: the capability loop ignores
    # `path:` lines, so the message stays in the chat and is delivered to the
    # backend together with the user message (the mock records every round).
    agent = fresh_agent
    LLM::Mock.script('ok')
    agent.prompt LLM.chat("path: true\nuser\nhello"),
                 persist: false, endpoint: 'mock', backend: :mock

    roles = LLM::Mock.calls.first.first.collect { |m| m[:role].to_s }
    assert_include roles, 'path'
  end

  def test_agent_path_is_a_plain_accessor_again
    agent = fresh_agent
    agent.path = File.join(@tmpdir, 'agent_path')
    assert_equal File.join(@tmpdir, 'agent_path'), agent.path
  end

  def test_capability_loop_still_handles_socialize_and_attachments
    # the array shrunk to exactly two capabilities; the dispatch helper
    # `path` is gone and `Agent#path` is the plain accessor again (its
    # source is the attr_accessor at agent.rb, not agent/path.rb)
    assert_equal ['lib/scout/llm/agent.rb'],
                 LLM::Agent.instance_method(:path).source_location[0..0]
                 .collect { |f| f.sub(%r{.*/scout-ai/}, '') }
    assert LLM::Agent.instance_methods.include?(:socialize)
    assert LLM::Agent.instance_methods.include?(:attachments)
  end

  # -- skipped incorporations --------------------------------------------------

  def test_unresolvable_workflow_name_is_skipped_silently
    # The hook itself rescues the lookup and skips PATH_KINDS handling; the
    # later backend tool resolution then legitimately raises because no such
    # workflow exists anywhere.  We drive only the hook (the same block
    # Agent#ask runs, lifted verbatim) to pin the skip behavior.
    agent = fresh_agent
    messages = Chat.setup(LLM.chat("tool: NoSuchWorkflowForPathKinds\nuser\ndo things"))
    hook = lambda do |msgs|
      Chat.find_role(msgs, :tool).each do |message|
        workflow_name, task_name, *_inputs = Chat.content_tokens(message)
        next if task_name
        next if workflow_name.nil? || workflow_name.empty?
        next if Open.remote? workflow_name
        begin
          workflow = Chat.load_workflow workflow_name
        rescue
          next
        end
        agent.integrate_workflow_path_kinds(workflow)
      end
    end
    assert_nothing_raised { hook.call(messages) }

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end

  def test_remote_tool_line_is_skipped_by_path_kinds_hook
    agent = fresh_agent
    messages = Chat.setup(LLM.chat("tool: https://127.0.0.1:1/WF\nuser\ndo things"))
    hook = lambda do |msgs|
      Chat.find_role(msgs, :tool).each do |message|
        workflow_name, task_name, *_inputs = Chat.content_tokens(message)
        next if task_name
        next if workflow_name.nil? || workflow_name.empty?
        next if Open.remote? workflow_name
        begin
          workflow = Chat.load_workflow workflow_name
        rescue
          next
        end
        agent.integrate_workflow_path_kinds(workflow)
      end
    end
    assert_nothing_raised { hook.call(messages) }

    assert_empty agent.path_kind_registry
    assert_empty agent.path_kind_sources
  end
end

# Test-local workflow modules used above. They are defined OUTSIDE the test
# class (same technique as TestBaking in test/scout/llm/agent/test_workflow.rb
# and test/scout/llm/test_chat.rb): `tool:`/`introduce:` resolve names through
# Kernel.const_get first, so a named module is reachable without any file on
# disk and without touching the real workflow search path.
$test_path_kind_root ||= Path.setup(File.join(Scout.tmp.agent_path_kind_test.find.to_s, 'roots')).find

module TestPathKindWorkflowA
  extend Workflow
  self.name = 'TestPathKindWorkflowA'

  PATH_KINDS = {
    'wfa_kind' => {
      'description' => 'Kind exported by TestPathKindWorkflowA',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root},
      'capabilities' => {'read' => true, 'write' => true}
    }
  }.freeze
end

module TestPathKindWorkflowB
  extend Workflow
  self.name = 'TestPathKindWorkflowB'

  desc 'Sample task'
  input :value, :string
  task :t => :string do |value| value end

  PATH_KINDS = {
    'wfb_kind' => {
      'description' => 'Kind exported by TestPathKindWorkflowB',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

module TestPathKindWorkflowNone
  extend Workflow
  self.name = 'TestPathKindWorkflowNone'

  desc 'Sample task'
  input :value, :string
  task :t => :string do |value| value end
end

module TestPathKindWorkflowConflict
  extend Workflow
  self.name = 'TestPathKindWorkflowConflict'

  PATH_KINDS = {
    'wfa_kind' => {
      'description' => 'Conflicting kind from another workflow',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

module TestPathKindWorkflowBadShape
  extend Workflow
  self.name = 'TestPathKindWorkflowBadShape'

  PATH_KINDS = 'not-a-mapping'
end

module TestPathKindWorkflowBadEntry
  extend Workflow
  self.name = 'TestPathKindWorkflowBadEntry'

  PATH_KINDS = {'broken' => 'not-a-hash'}
end

module TestPathKindWorkflowArray
  extend Workflow
  self.name = 'TestPathKindWorkflowArray'

  PATH_KINDS = [
    {
      'name' => 'arr_first',
      'description' => 'First array entry',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    },
    {
      'name' => 'arr_second',
      'description' => 'Second array entry',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  ].freeze
end

module TestPathKindParent
  PATH_KINDS = {
    'parent_kind' => {
      'description' => 'Parent constant, must not be discovered',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze

  module Child
    extend Workflow
    self.name = 'TestPathKindParent::Child'
  end
end

class TestPathKindBase
  PATH_KINDS = {
    'base_kind' => {
      'description' => 'Base class constant, must not be discovered',
      'locations' => ['tmp'],
      'roots' => {'tmp' => $test_path_kind_root}
    }
  }.freeze
end

class TestPathKindSubclassed < TestPathKindBase
  extend Workflow
  self.name = 'TestPathKindSubclassed'
end
