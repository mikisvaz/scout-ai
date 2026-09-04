require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMToolDefinition < Test::Unit::TestCase
  INHERIT_ENUM = %w[none tools conversation].freeze

  def setup_workflow_module
    Module.new do
      extend Workflow
      self.name = "RecipeWorkflow"

      desc "List the steps to cook a recipe"
      input :recipe, :string, "Recipe for which to extract steps"
      task :recipe_steps => :array do |recipe|
        ["prepare batter", "bake"]
      end

      desc "Calculate time spent in each step of the recipe"
      input :step, :string, "Cooking step"
      input :minutes, :integer, "Minutes", nil, required: true
      task :step_time => :string do |step|
        "30 minutes"
      end
    end
  end

  def setup_agent
    require 'scout/llm/agent'
    LLM::Agent.new
  end

  ## Attachments site (previously strict)

  def test_attach_definition
    agent = setup_agent
    agent.attachments

    assert_equal true, agent.other_options[:tools][:attach].first.is_a?(Proc)

    definition = agent.other_options[:tools][:attach].last
    assert_equal :attach, definition[:name]
    assert_equal 'function', definition[:type]
    assert_equal({
      type: 'string',
      description: 'Path to the file'
    }, definition[:function][:parameters][:properties][:file])
    assert_equal({
      type: 'string',
      description: 'File type of the file (e.g image, pdf), auto by default',
      enum: %w(auto image pdf png jpeg),
      default: 'auto'
    }, definition[:function][:parameters][:properties][:file_type])
    assert_equal [:file], definition[:function][:parameters][:required]
    assert_equal false, definition[:function][:parameters][:additionalProperties]

    assert_equal definition[:name], definition[:function][:name]
    assert_equal definition[:description], definition[:function][:description]
    assert_equal definition[:parameters], definition[:function][:parameters]
  end

  ## Socialize site (previously strict)

  def test_socialize_definition
    agent = setup_agent
    agent.socialize

    definition = agent.other_options[:tools][:ask].last
    assert_equal :ask, definition[:name]
    assert_equal 'function', definition[:type]

    properties = definition[:function][:parameters][:properties]
    assert_equal({
      type: 'string',
      description: 'Name of the specialist agent to ask'
    }, properties[:agent])
    assert_equal({
      type: 'string',
      description: 'Plain-text prompt sent as one user message to the specialist'
    }, properties[:prompt])
    assert_equal({
      type: 'string',
      pattern: '^[A-Za-z0-9][A-Za-z0-9_.-]*$',
      description: 'Optional conversation or chat identifier; reuse it with the same agent to continue that conversation across several calls'
    }, properties[:conversation])
    assert_equal({
      type: 'string',
      enum: INHERIT_ENUM,
      default: 'tools',
      description: "Context copied only when starting the call or named conversation: 'none' uses only the specialist start_chat, 'tools' also copies caller task tooling, and 'conversation' copies the caller task conversation"
    }, properties[:inherit])

    assert_equal [:agent, :prompt], definition[:function][:parameters][:required]
    assert_equal false, definition[:function][:parameters][:additionalProperties]

    assert_equal definition[:name], definition[:function][:name]
    assert_equal definition[:description], definition[:function][:description]
    assert_equal definition[:parameters], definition[:function][:parameters]
  end

  ## Delegate site (previously NON-strict: strict only after the refactor)

  def test_delegate_definition
    agent = setup_agent
    specialist = setup_agent
    agent.delegate(specialist, 'Worker', 'desc here')

    definition = agent.other_options[:tools][:hand_off_to_Worker].last
    assert_equal :hand_off_to_Worker, definition[:name]
    assert_equal 'desc here', definition[:description]
    assert_equal 'function', definition[:type]

    properties = definition[:function][:parameters][:properties]
    assert_equal({
      type: :string,
      description: 'Message to pass to the agent'
    }, properties[:message])
    assert_equal({
      type: :boolean,
      description: 'Erase conversation history and start a new conversation with this message',
      default: false
    }, properties[:new_conversation])

    assert_equal [:message], definition[:function][:parameters][:required]
    assert_equal false, definition[:function][:parameters][:additionalProperties]

    assert_equal definition[:name], definition[:function][:name]
    assert_equal definition[:description], definition[:function][:description]
    assert_equal definition[:parameters], definition[:function][:parameters]
  end

  ## Workflow task site (previously NON-strict: strict only after the refactor)

  def test_task_tool_definition_no_inputs
    m = setup_workflow_module
    definition = LLM.task_tool_definition(m, :recipe_steps)

    assert_equal :recipe_steps, definition[:name]
    assert_equal 'List the steps to cook a recipe', definition[:description]
    assert_equal({
      type: 'object',
      properties: {
        recipe: { type: :string, description: 'Recipe for which to extract steps' },
        return_path: {
          type: 'boolean',
          description: 'Instead of the result of the job, return the path where it is persisted'
        }
      },
      required: [],
      additionalProperties: false
    }, definition[:parameters])
    # Bare definition: no function envelope for workflow task tools.
    assert_equal false, definition.include?(:function)
  end

  def test_task_tool_definition_required
    m = setup_workflow_module
    definition = LLM.task_tool_definition(m, :step_time)

    assert_equal :step_time, definition[:name]
    assert_equal [:minutes], definition[:parameters][:required]
    assert_equal :integer, definition[:parameters][:properties][:minutes][:type]
    # Previously non-strict: the builder now makes the schema strict.
    assert_equal false, definition[:parameters][:additionalProperties]
  end

  def test_task_tool_definition_filtered_inputs
    m = setup_workflow_module
    definition = LLM.task_tool_definition(m, :step_time, ['step'])

    assert_equal %i(step return_path), definition[:parameters][:properties].keys
    # The empty defaults Hash recorded when inputs are given is preserved.
    assert_equal({}, definition[:parameters][:defaults])
    assert_equal false, definition[:parameters][:additionalProperties]
  end

  def test_task_tool_definition_pinned_default
    m = setup_workflow_module
    definition = LLM.task_tool_definition(m, :recipe_steps, ['recipe=lasagna'])

    assert_equal %i(return_path), definition[:parameters][:properties].keys
    assert_equal({ 'recipe' => 'lasagna' }, definition[:parameters][:defaults])
    assert_equal false, definition[:parameters][:additionalProperties]
  end

  ## Replay side-channel: process_calls merges parameters[:defaults]

  def test_defaults_are_applied_on_replay_for_proc_tools
    m = setup_workflow_module
    definition = LLM.task_tool_definition(m, :recipe_steps, ['recipe=lasagna'])
    seen = nil
    handler = Proc.new do |_name, args|
      seen = args
      'done'
    end

    calls = [
      IndiferentHash.setup({
        'id' => 'call_1', 'type' => 'function',
        'function' => { 'name' => 'recipe_steps', 'arguments' => '{}' }
      })
    ]
    LLM.process_calls({ 'recipe_steps' => [handler, definition] }, calls) do |_name, _args|
      'unused'
    end
    assert_equal({ 'recipe' => 'lasagna' }, seen)
  end

  def test_defaults_are_applied_on_replay_for_workflow_tools
    m = Module.new do
      extend Workflow
      self.name = "RecipeWorkflow"

      desc "List the steps to cook a recipe"
      input :recipe, :string, "Recipe for which to extract steps"
      task :recipe_steps => :array do |recipe|
        ["prepare batter", "bake", recipe]
      end
    end
    definition = LLM.task_tool_definition(m, :recipe_steps, ['recipe=lasagna'])

    calls = [
      IndiferentHash.setup({
        'id' => 'call_1', 'type' => 'function',
        'function' => { 'name' => 'recipe_steps', 'arguments' => '{}' }
      })
    ]
    result = LLM.process_calls({ 'recipe_steps' => [m, definition] }, calls) do |_name, _args|
      'done'
    end
    # The workflow job itself must observe the pinned default: the task
    # returns the recipe string as its third element.
    assert_equal 'lasagna', JSON.parse(JSON.parse(result.last[:content])['content']).last
  end

  ## Builder primitives

  def test_builder_defaults
    definition = LLM.tool_definition(:task, 'A task', {
      'a' => { type: :string },
      'b' => { type: :integer, default: 1 }
    })

    assert_equal({
      name: :task,
      description: 'A task',
      parameters: {
        type: 'object',
        properties: {
          'a' => { type: :string },
          'b' => { type: :integer, default: 1 }
        },
        required: [],
        additionalProperties: false
      },
      type: 'function',
      function: {
        name: :task,
        description: 'A task',
        parameters: {
          type: 'object',
          properties: {
            'a' => { type: :string },
            'b' => { type: :integer, default: 1 }
          },
          required: [],
          additionalProperties: false
        }
      }
    }, definition)
  end

  def test_builder_no_defaults_key_without_argument_defaults
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } })

    assert_equal false, definition[:parameters].include?(:defaults)
    assert_equal false, definition[:parameters][:additionalProperties]
  end

  def test_builder_omits_default_when_nil
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } }, defaults: nil)

    assert_equal false, definition[:parameters].include?(:defaults)
  end

  def test_builder_keeps_empty_hash_defaults
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } }, defaults: {})

    assert_equal({}, definition[:parameters][:defaults])
  end

  def test_builder_optional_strictness
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } }, strict: false)

    assert_equal false, definition[:parameters].include?(:additionalProperties)
    assert_equal false, definition[:function][:parameters].include?(:additionalProperties)
  end

  def test_builder_bare_option
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } }, envelope: false)

    assert_equal({
      name: :task,
      description: 'A task',
      parameters: {
        type: 'object',
        properties: { 'a' => { type: :string } },
        required: [],
        additionalProperties: false
      }
    }, definition)
  end

  def test_builder_wraps_single_required_name
    definition = LLM.tool_definition(:task, 'A task', { 'a' => { type: :string } }, required: 'a')

    assert_equal ['a'], definition[:function][:parameters][:required]
  end

  def test_builder_accepts_string_names
    definition = LLM.tool_definition('task', 'A task', { 'a' => { type: :string } })

    assert_equal 'task', definition[:name]
    assert_equal 'task', definition[:function][:name]
  end
end
