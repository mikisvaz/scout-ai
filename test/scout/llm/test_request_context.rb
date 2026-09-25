require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')
require 'scout/llm/request_context'
require 'scout/llm/tools/call'
require 'scout/llm/tools/workflow'
require 'scout/llm/ask'
require 'open3'

class TestLLMRequestContext < Test::Unit::TestCase
  def context_workflow
    @context_workflow ||= Module.new do
      extend Workflow
      self.name = 'RequestContextTestWorkflow'
      input :value, :string
      task :echo => :string do |value|
        value
      end
      task :read_context => :string do
        request_context.to_json
      end
      dep :read_context
      task :parent => :string do
        step(:read_context).load
      end
    end
  end

  def test_projection_is_serializable_and_excludes_unsafe_fields
    agent = Object.new
    context = LLM::RequestContext.project(
      endpoint: 'local', backend: :openai, model: 'gpt-test',
      agent: agent, client: agent, tools: [proc {}],
      messages: [{role: 'user'}], previous_response_id: 'secret',
      nested: {keep: true, api_key: 'secret', 'X-Api-Key' => 'secret', finite: 1.5,
               nan: Float::NAN, infinity: Float::INFINITY},
      invalid_encoding: "bad\xFF".force_encoding(Encoding::UTF_8)
    )

    assert_equal 'local', context[:endpoint]
    assert_equal 'openai', context[:backend]
    assert_equal 'gpt-test', context[:model]
    assert_equal({keep: true, finite: 1.5}, context[:nested])
    assert(!context.key?(:agent))
    assert(!context.key?(:client))
    assert(!context.key?(:tools))
    assert(!context.key?(:messages))
    assert(!context.key?(:previous_response_id))
    assert(JSON.parse(JSON.generate(context)))
    assert_equal 1.5, context[:nested][:finite]
    assert(!context[:nested].key?(:nan))
    assert(!context[:nested].key?(:infinity))
    assert_equal "bad\uFFFD", context[:invalid_encoding]
  end

  def test_projection_handles_malformed_hash_keys
    malformed = "bad\xFFkey".force_encoding(Encoding::UTF_8)
    context = LLM::RequestContext.project(malformed => 'value')

    assert_equal 'value', context["bad\uFFFDkey".to_sym]
    assert JSON.parse(JSON.generate(context))
  end

  def test_tool_callback_preserves_two_argument_lambda_and_supports_three
    call = {'id' => 'call-1', 'name' => 'echo', 'arguments' => {value: 'x'}}
    two_seen = nil
    LLM.tool_response(call, request_context: {request_id: 'R'}) do |name, arguments|
      two_seen = [name, arguments]
      'ok'
    end
    assert_equal ['echo', {value: 'x'}], two_seen

    three_seen = nil
    LLM.tool_response(call, request_context: {request_id: 'R'}) do |name, arguments, context|
      three_seen = [name, arguments, context]
      'ok'
    end
    assert_equal ['echo', {value: 'x'}, {request_id: 'R'}], three_seen

    strict_seen = nil
    strict = ->(name, arguments) { strict_seen = [name, arguments]; 'ok' }
    LLM.tool_response(call, request_context: {request_id: 'R'}, &strict)
    assert_equal ['echo', {value: 'x'}], strict_seen
  end

  def test_strict_two_argument_tool_response_lambda
    call = {'id' => 'call-strict', 'name' => 'echo', 'arguments' => {value: 'x'}}
    strict = ->(name, arguments) { [name, arguments] }
    response = LLM.tool_response(call, request_context: {request_id: 'R'}, &strict)
    assert_equal ['echo', {value: 'x'}].to_json, response[:content]
  end

  def test_process_calls_forwards_context_without_workflow_parameters
    value = 'not-context'
    context = {request_id: 'R1', endpoint: 'local', backend: 'openai', model: 'gpt-test'}
    definition = LLM.task_tool_definition(context_workflow, :echo)
    tools = {'echo' => [context_workflow, definition]}
    calls = [{'id' => 'call-1', 'name' => 'echo', 'arguments' => {value: value}}]

    result = LLM.process_calls(tools, calls, request_context: context)
    assert_equal value, JSON.parse(result[1][:content])['content']

    job = context_workflow.job(:echo, nil, value: value)
    assert_equal value, job.run
    assert_equal JSON.parse(JSON.generate(version: 1, fields: context)), job.info[:request_context]
    assert_equal value, job.info[:provided_inputs]['value']
    assert(!job.info[:provided_inputs].key?('request_context'))
  end

  def test_task_body_reads_context_from_persisted_info_without_identity_change
    context = {request_id: 'body-R', endpoint: 'test', backend: 'mock'}
    first = context_workflow.job(:read_context, nil, value: 'body-context')
    first.extend(LLM::RequestContext::StepExtension)
    first.register_request_context(context)
    first.clean
    first.produce
    loaded = Step.load(first.path)
    expected_path = first.path.to_s
    assert_equal expected_path, loaded.path.to_s
    assert_equal first.inputs, context_workflow.job(:read_context, nil, value: 'body-context').inputs
    assert_equal expected_path, context_workflow.job(:read_context, nil, value: 'body-context').path.to_s
    assert_equal JSON.parse(JSON.generate(version: 1, fields: context)), loaded.info[:request_context]
    assert(!loaded.info[:provided_inputs].keys.any? { |key| key.to_s == 'request_context' })
    assert_equal context.transform_keys(&:to_s), JSON.parse(loaded.load)
  end

  def test_llm_ask_forwards_request_context_to_workflow_tool_step
    context = {request_id: 'ask-R', endpoint: 'mock', backend: 'mock'}
    tools = {'echo' => [context_workflow, LLM.task_tool_definition(context_workflow, :echo)]}
    backend = Module.new
    backend.define_singleton_method(:ask) do |_messages, options|
      LLM.process_calls(options[:tools],
                        [{name: 'echo', arguments: {value: 'ask-context'}, id: 'ask-call'}],
                        request_context: options[:request_context])
      'done'
    end
    LLM.register_backend(:request_context_test, backend)

    result = LLM.ask('Return the result from the echo tool.', tools: tools,
                     request_context: context, persist: false, backend: :request_context_test)

    assert_include result, 'done'
    step = context_workflow.job(:echo, nil, value: 'ask-context')
    assert_equal JSON.parse(JSON.generate(version: 1, fields: context)), step.info[:request_context]
    assert_equal 'ask-context', step.info[:provided_inputs]['value']
    assert(!step.info[:provided_inputs].key?('request_context'))
  end

  def test_save_file_keyword_remains_compatible
    calls = [{'id' => 'call-1', 'name' => 'echo', 'arguments' => {value: 'saved'}}]
    tools = {'echo' => [context_workflow, LLM.task_tool_definition(context_workflow, :echo)]}
    TmpFile.with_dir do |dir|
      save_file = File.join(dir, 'chat')
      result = LLM.process_calls(tools, calls, save_file: save_file,
                                 request_context: {request_id: 'R2'})
      assert_equal 'saved', JSON.parse(result[1][:content])['content']
    end
  end
  def test_done_and_contextualized_dependencies_are_not_overwritten
    context = {request_id: 'existing-R', endpoint: 'test'}
    dependency = context_workflow.job(:read_context)
    dependency.extend(LLM::RequestContext::StepExtension)
    dependency.register_request_context(context)
    dependency.clean
    dependency.produce
    before = File.binread(dependency.info_file)

    parent = LLM.call_workflow(context_workflow, :parent, {},
                               request_context: {request_id: 'parent-R'})
    parent.clean
    parent.produce

    assert_equal before, File.binread(dependency.info_file)
    assert_equal context.transform_keys(&:to_s), JSON.parse(Step.load(dependency.path).load)
  end

  def test_dependency_task_body_reads_parent_context
    context = {request_id: 'dependency-R', endpoint: 'test'}
    parent = LLM.call_workflow(context_workflow, :parent, {}, request_context: context)
    dependency_path = context_workflow.job(:read_context).path
    parent.clean
    assert(!File.exist?(dependency_path.to_s + '.info'))
    parent.produce

    dependency = Step.load(dependency_path)
    assert_equal context.transform_keys(&:to_s), JSON.parse(dependency.load)
    assert_equal JSON.parse(JSON.generate(version: 1, fields: context)), dependency.info[:request_context]
    assert(!dependency.info[:provided_inputs].keys.any? { |key| key.to_s == 'request_context' })
  end

  def test_context_does_not_change_workflow_job_identity
    inputs = {value: 'same'}
    first = LLM.call_workflow(context_workflow, :echo, inputs,
                              request_context: {request_id: 'one'})
    second = LLM.call_workflow(context_workflow, :echo, inputs,
                               request_context: {request_id: 'two'})
    assert_equal first.path.to_s, second.path.to_s
  end

  def test_replay_in_a_cold_process_does_not_replace_producer_context
    value = 'cold-replay'
    definition = LLM.task_tool_definition(context_workflow, :echo)
    tools = {'echo' => [context_workflow, definition]}
    calls = [{'id' => 'call-1', 'name' => 'echo', 'arguments' => {value: value}}]

    LLM.process_calls(tools, calls, request_context: {request_id: 'A'})
    job = context_workflow.job(:echo, nil, value: value)
    assert_equal 'A', job.info[:request_context][:fields][:request_id]
    original_info = File.binread(job.info_file)

    script = File.join(tmpdir.to_s, 'cold_replay.rb')
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift #{File.expand_path('lib').inspect}
      require 'scout'
      require 'scout/llm/tools/call'
      require 'scout/llm/tools/workflow'
      module RequestContextTestWorkflow
        extend Workflow
        input :value, :string
        task :echo => :string do |value|
          value
        end
      end
      Workflow.directory = Path.setup(#{Workflow.directory.to_s.inspect})
      wf = RequestContextTestWorkflow
      definition = LLM.task_tool_definition(wf, :echo)
      LLM.process_calls({'echo' => [wf, definition]},
                        [{'id' => 'cold', 'name' => 'echo', 'arguments' => {value: #{value.inspect}}}],
                        request_context: {request_id: 'B'})
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
    assert status.success?, "cold replay failed: #{stdout}\n#{stderr}"
    assert_equal original_info, File.binread(job.info_file)
    assert_equal 'A', Step.load(job.path).info[:request_context][:fields][:request_id]
  end

  def test_concurrent_producers_write_one_first_context_and_one_raw_key
    value = 'concurrent-producer'
    definition = LLM.task_tool_definition(context_workflow, :echo)
    tools = {'echo' => [context_workflow, definition]}
    calls = [{'id' => 'call-1', 'name' => 'echo', 'arguments' => {value: value}}]
    errors = Queue.new

    threads = (0...4).map do |i|
      Thread.new do
        begin
          LLM.process_calls(tools, calls, request_context: {request_id: "producer-#{i}"})
        rescue Exception => e
          errors << e
        end
      end
    end
    threads.each(&:join)
    assert errors.empty?, errors.size.times.map { errors.pop.message }.join("\n")

    job = context_workflow.job(:echo, nil, value: value)
    raw_text = File.binread(job.info_file)
    raw = JSON.parse(raw_text)
    request_context_keys = raw.keys.select { |key| key == 'request_context' }
    assert_equal ['request_context'], request_context_keys
    assert_kind_of Hash, raw['request_context']
    assert_equal 1, raw['request_context']['version']
    assert_match(/producer-\d+/, raw['request_context']['fields']['request_id'])
    assert_equal 1, raw_text.scan(/"request_context"\s*:/).length
    assert_equal 1, raw.keys.count { |key| key == 'request_context' }
  end
end
