require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMHF < Test::Unit::TestCase
  class FakeHFClient
    attr_reader :messages, :tools, :calls

    def initialize(*responses)
      @responses = responses
      @calls = 0
    end

    def chat(messages, tools, parameters = {})
      @messages = messages
      @tools = tools
      response = @responses[@calls] || @responses.last
      @calls += 1
      response
    end
  end

  def _test_ask
    Log.severity = 0
    prompt =<<-EOF
system: you are a coding helper that only write code and inline comments. No extra explanations or comentary
system: Avoid using backticks ``` to format code.
user: write a script that sorts files in a directory 
    EOF
    ppp LLM::Huggingface.ask prompt, model: 'HuggingFaceTB/SmolLM2-135M-Instruct'
  end

  def test_format_tool_call
    message = {
      role: 'function_call',
      content: {
        name: 'get_current_temperature',
        arguments: { location: 'London', unit: 'Celsius' },
        id: 'call_123'
      }.to_json
    }

    formatted = LLM::Huggingface.format_tool_call(message)

    assert_equal 'assistant', formatted[:role]
    assert_equal 'function', formatted.dig(:tool_calls, 0, :type)
    assert_equal 'call_123', formatted.dig(:tool_calls, 0, :id)
    assert_equal 'get_current_temperature', formatted.dig(:tool_calls, 0, :function, :name)
    assert_equal 'London', formatted.dig(:tool_calls, 0, :function, :arguments, :location)
  end

  def test_format_tool_output
    message = {
      role: 'function_call_output',
      content: {
        id: 'call_123',
        name: 'get_current_temperature',
        content: "It's 15 degrees and raining."
      }.to_json
    }

    formatted = LLM::Huggingface.format_tool_output(message)

    assert_equal 'tool', formatted[:role]
    assert_equal 'get_current_temperature', formatted[:name]
    assert_equal 'call_123', formatted[:tool_call_id]
    assert_equal "It's 15 degrees and raining.", formatted[:content]
  end

  def test_parse_tool_call
    tool_call = {
      id: 'call_123',
      type: 'function',
      function: {
        name: 'get_current_temperature',
        arguments: { location: 'London', unit: 'Celsius' }
      }
    }

    parsed = LLM::Huggingface.parse_tool_call(tool_call)

    assert_equal 'call_123', parsed[:id]
    assert_equal 'get_current_temperature', parsed[:name]
    assert_equal 'London', parsed.dig(:arguments, :location)
  end

  def test_ask_with_fake_client
    client = FakeHFClient.new({ role: 'assistant', content: 'Hello from Huggingface' })

    response = LLM::Huggingface.ask("user: say hi", client: client, log_response: false)

    assert_equal 'Hello from Huggingface', response
    assert_equal 1, client.calls
  end

  def test_ask_tool_loop_with_fake_client
    client = FakeHFClient.new(
      {
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: 'call_123',
            type: 'function',
            function: {
              name: 'get_current_temperature',
              arguments: { location: 'London', unit: 'Celsius' }
            }
          }
        ]
      },
      {
        role: 'assistant',
        content: 'Take an umbrella.'
      }
    )

    tools = [
      {
        type: 'function',
        function: {
          name: 'get_current_temperature',
          description: 'Get the current temperature',
          parameters: {
            type: 'object',
            properties: {
              location: { type: 'string' },
              unit: { type: 'string' }
            },
            required: %w(location unit)
          }
        }
      }
    ]

    response = LLM::Huggingface.ask("user: What is the weather in London?", client: client, tools: tools, log_response: false) do |_name, _arguments|
      "It's 15 degrees and raining."
    end

    assert_equal 'Take an umbrella.', response
    assert_equal 2, client.calls
  end

  def test_format_tool_definitions
    tools = {
      'get_current_temperature' => [
        nil,
        {
          name: 'get_current_temperature',
          description: 'Get the current temperature',
          parameters: {
            type: 'object',
            properties: {
              location: { type: 'string' }
            },
            required: ['location'],
            defaults: { unit: 'Celsius' }
          }
        }
      ]
    }

    formatted = LLM::Huggingface.format_tool_definitions(tools)

    assert_equal 'function', formatted.first[:type].to_s
    assert_equal 'get_current_temperature', formatted.first.dig(:function, :name)
    assert_nil formatted.first.dig(:function, :parameters, :defaults)
  end
end
