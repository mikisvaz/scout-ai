# Test support: offline stand-ins for the provider HTTP clients.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
#
# Each fake wraps one provider SDK client class. They all share:
#   * a response list replayed in order (last entry repeats when exhausted)
#   * `.calls` recording every parameters hash for assertions
#   * optional failure injection: an Exception instance entry is raised
#
# Recorded parameters are plain Hash/IndiferentHash values so assertions can
# deep-compare them against expected payloads without type surprises.
class FakeResponseClientBase
  attr_reader :calls, :responses

  # NOTE: entries are NOT flattened. A single entry may itself be an Array
  # (e.g. the Ollama API returns an array of chunk hashes per call, and
  # OLlama#process_response iterates the returned value).
  def initialize(*responses)
    @responses = responses
    @calls = []
    @index = 0
  end

  # Replays the next scripted response. Exception entries are raised so tests
  # can exercise provider error paths.
  def next_response
    entry = @responses[@index] || @responses.last
    @index += 1
    raise entry if Exception === entry
    entry
  end

  def record(parameters)
    @calls << IndiferentHash.setup(parameters.dup)
  end
end

# ruby-openai Chat Completions + embeddings:
#   client.chat(parameters:), client.embeddings(parameters:)
class FakeOpenAIChatClient < FakeResponseClientBase
  def chat(parameters: {})
    record(parameters)
    next_response
  end

  def embeddings(parameters: {})
    record(parameters)
    next_response
  end
end

# ruby-openai Responses API: client.responses.create(parameters:)
class FakeResponsesClient < FakeResponseClientBase
  ResponseStub = Struct.new(:create)

  def responses
    self
  end

  def create(parameters: {})
    record(parameters)
    next_response
  end
end

# anthropic gem: client.messages(parameters:)
class FakeAnthropicClient < FakeResponseClientBase
  def messages(parameters: {})
    record(parameters)
    next_response
  end
end

# ollama-ai gem: client.chat(parameters) (positional),
# client.request(path, parameters)
class FakeOllamaClient < FakeResponseClientBase
  def chat(parameters = {})
    record(parameters)
    next_response
  end

  def request(path, parameters = {})
    record(parameters.merge(path: path))
    next_response
  end
end

# aws-sdk-bedrockruntime: client.invoke_model(model_id:, content_type:, body:)
# returning an object whose .body.string is the JSON payload.
class FakeBedrockClient
  BodyStub = Struct.new(:string)
  ResponseStub = Struct.new(:body)

  attr_reader :calls

  def initialize(*payloads)
    @payloads = payloads
    @calls = []
    @index = 0
  end

  # Records the request (body parsed back to a Hash for assertions) and returns
  # the next scripted payload wrapped as invoke_model does.
  def invoke_model(model_id:, content_type:, body:)
    payload = @payloads[@index] || @payloads.last
    @index += 1
    @calls << IndiferentHash.setup({model_id: model_id, content_type: content_type, body: JSON.parse(body)})
    ResponseStub.new(BodyStub.new(payload.to_json))
  end
end

module TestFixtures
  class << self
    # Build a fake client pre-loaded with the named fixtures, e.g.
    # TestFixtures.openai_client('backends/openai_chat_tool_call',
    #                            'backends/openai_chat')
    def openai_client(*names)
      FakeOpenAIChatClient.new(*names.collect { |n| fixture(n) })
    end

    def responses_client(*names)
      FakeResponsesClient.new(*names.collect { |n| fixture(n) })
    end

    def anthropic_client(*names)
      FakeAnthropicClient.new(*names.collect { |n| fixture(n) })
    end

    def ollama_client(*names)
      FakeOllamaClient.new(*names.collect { |n| fixture(n) })
    end

    def bedrock_client(*names)
      FakeBedrockClient.new(*names.collect { |n| fixture(n) })
    end
  end
end
