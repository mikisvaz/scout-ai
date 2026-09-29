require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestDecisionJev < Test::Unit::TestCase

  QUESTIONS = {
    "supported" => {
      "type" => "noul",
      "instructions" => "Does the evidence support the claim?"
    },

    "interpretation" => {
      "type" => "choice",
      "instructions" => "How should the evidence be interpreted?",
      "criteria" => {
        "direct" => "Directly supports the claim",
        "indirect" => "Supports the claim indirectly",
        "contradictory" => "Provides evidence against the claim",
        "unclear" => "The evidence is insufficient"
      }
    }
  }.freeze

  STATE = {
    "claim" => "The treatment inhibits pathway X",
    "evidence" => [
      "Expression of X decreased after treatment",
      "The effect was observed in three replicates"
    ]
  }.freeze

  class FakeClient
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def evaluate(**arguments)
      @calls << arguments
      @response
    end
  end

  def test_eval_delegates_to_client
    response = {
      "model" => "jev-1.13.0",
      "answers" => {
        "supported" => {
          "type" => "noul",
          "noul" => 0.92
        },

        "interpretation" => {
          "type" => "choice",
          "choice" => "indirect",
          "probabilities" => {
            "direct" => 0.15,
            "indirect" => 0.70,
            "contradictory" => 0.03,
            "unclear" => 0.12
          },
          "confidence" => 0.70
        }
      },

      "usage" => {
        "input_tokens" => 100,
        "output_tokens" => 20
      }
    }

    client = FakeClient.new(response)

    decision = Decision::Jev.new(
      client: client,
      model: "jev-1.13.0",
      questions: QUESTIONS
    )

    result = decision.eval(STATE)

    assert_equal 1, client.calls.length

    call = client.calls.first

    assert_equal "jev-1.13.0", call[:model]
    assert_equal STATE, call[:state]
    assert_equal QUESTIONS, call[:questions]

    assert_equal response, result.value
  end

  def test_eval_list_evaluates_each_input
    responses = [
      { "answers" => { "supported" => { "noul" => 0.9 } } },
      { "answers" => { "supported" => { "noul" => 0.2 } } }
    ]

    client = Class.new do
      attr_reader :calls

      def initialize(responses)
        @responses = responses
        @calls = []
      end

      def evaluate(**arguments)
        @calls << arguments
        @responses.shift
      end
    end.new(responses)

    decision = Decision::Jev.new(
      client: client,
      model: "jev-1.13.0",
      questions: QUESTIONS
    )

    inputs = [
      { "id" => 1 },
      { "id" => 2 }
    ]

    results = decision.eval_list(inputs)

    assert_equal 2, results.length
    assert_equal inputs, client.calls.map { |call| call[:state] }

    assert_equal 0.9,
      results[0].value.dig("answers", "supported", "noul")

    assert_equal 0.2,
      results[1].value.dig("answers", "supported", "noul")
  end

  def test_model_defaults_to_latest
    client = FakeClient.new({})

    decision = Decision::Jev.new(
      client: client,
      questions: QUESTIONS
    )

    decision.eval(STATE)

    assert_equal "jev-latest", client.calls.first[:model]
  end


  # ------------------------------------------------------------------
  # Client tests
  # ------------------------------------------------------------------

  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name)
      headers[name]
    end
  end

  class FakeHTTP
    attr_accessor :open_timeout, :read_timeout
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      response = @responses.shift

      raise "No fake response configured" unless response

      response
    end
  end

  def fake_response(code, body, headers = {})
    FakeResponse.new(
      code.to_s,
      body,
      headers
    )
  end

  def test_client_sends_correct_request
    response_body = JSON.generate(
      "model" => "jev-1.13.0",
      "answers" => {
        "supported" => {
          "type" => "noul",
          "noul" => 0.91
        }
      },
      "usage" => {
        "input_tokens" => 100,
        "output_tokens" => 10
      }
    )

    http = FakeHTTP.new(
      fake_response(200, response_body)
    )

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http }
    )

    result = client.evaluate(
      model: "jev-1.13.0",
      state: STATE,
      questions: QUESTIONS
    )

    assert_equal "jev-1.13.0", result["model"]
    assert_equal 0.91,
      result.dig("answers", "supported", "noul")

    assert_equal 1, http.requests.length

    request = http.requests.first

    assert_equal "Bearer test-key", request["Authorization"]
    assert_equal "application/json", request["Content-Type"]
    assert_equal "application/json", request["Accept"]

    body = JSON.parse(request.body)

    assert_equal "jev-1.13.0", body["model"]
    assert_equal STATE, body["state"]
    assert_equal QUESTIONS, body["questions"]
  end

  def test_client_retries_rate_limit
    response_body = JSON.generate(
      "model" => "jev-1.13.0",
      "answers" => {},
      "usage" => {
        "input_tokens" => 1,
        "output_tokens" => 1
      }
    )

    http = FakeHTTP.new(
      fake_response(429, '{"error":"rate limit"}'),
      fake_response(200, response_body)
    )

    sleeps = []

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    result = client.evaluate(
      state: "hello",
      model: "jev-1.13.0",
      questions: {
        "x" => {
          "type" => "noul",
          "instructions" => "Is this true?"
        }
      }
    )

    assert_equal "jev-1.13.0", result["model"]
    assert_equal 2, http.requests.length
    assert_equal [0.25], sleeps
  end

  def test_client_honors_retry_after
    response_body = JSON.generate(
      "model" => "jev-1.13.0",
      "answers" => {},
      "usage" => {
        "input_tokens" => 1,
        "output_tokens" => 1
      }
    )

    http = FakeHTTP.new(
      fake_response(
        429,
        '{"error":"rate limit"}',
        "Retry-After" => "3"
      ),
      fake_response(200, response_body)
    )

    sleeps = []

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    client.evaluate(
      model: "jev-1.13.0",
      state: "hello",
      questions: {
        "x" => {
          "type" => "noul",
          "instructions" => "Is this true?"
        }
      }
    )

    assert_equal [3.0], sleeps
    assert_equal 2, http.requests.length
  end

  def test_client_retries_529
    response_body = JSON.generate(
      "model" => "jev-1.13.0",
      "answers" => {},
      "usage" => {
        "input_tokens" => 1,
        "output_tokens" => 1
      }
    )

    http = FakeHTTP.new(
      fake_response(529, '{"error":"overloaded"}'),
      fake_response(200, response_body)
    )

    sleeps = []

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    result = client.evaluate(
      model: "jev-1.13.0",
      state: "hello",
      questions: {
        "x" => {
          "type" => "noul",
          "instructions" => "Is this true?"
        }
      }
    )

    assert_equal "jev-1.13.0", result["model"]
    assert_equal 2, http.requests.length
  end

  def test_client_raises_after_max_retries
    http = FakeHTTP.new(
      fake_response(529, '{"error":"overloaded"}'),
      fake_response(529, '{"error":"overloaded"}'),
      fake_response(529, '{"error":"overloaded"}')
    )

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      max_retries: 2,
      http_factory: ->(_uri) { http },
      sleeper: ->(_seconds) {}
    )

    error = assert_raise(Decision::Jev::Error) do
      client.evaluate(
        model: "jev-1.13.0",
        state: "hello",
        questions: {
          "x" => {
            "type" => "noul",
            "instructions" => "Is this true?"
          }
        }
      )
    end

    assert_equal 529, error.status
    assert_equal 3, http.requests.length
  end

  def test_client_does_not_retry_normal_errors
    http = FakeHTTP.new(
      fake_response(400, '{"error":"bad request"}')
    )

    sleeps = []

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http },
      sleeper: ->(seconds) { sleeps << seconds }
    )

    error = assert_raise(Decision::Jev::Error) do
      client.evaluate(
        model: "jev-1.13.0",
        state: "hello",
        questions: {
          "x" => {
            "type" => "noul",
            "instructions" => "Is this true?"
          }
        }
      )
    end

    assert_equal 400, error.status
    assert_empty sleeps
    assert_equal 1, http.requests.length
  end

  def test_client_detects_invalid_json
    http = FakeHTTP.new(
      fake_response(200, "not json")
    )

    client = Decision::Jev::Client.new(
      api_key: "test-key",
      http_factory: ->(_uri) { http }
    )

    error = assert_raise(Decision::Jev::Error) do
      client.evaluate(
        model: "jev-1.13.0",
        state: "hello",
        questions: {
          "x" => {
            "type" => "noul",
            "instructions" => "Is this true?"
          }
        }
      )
    end

    assert_equal 200, error.status
  end

  def test_client_requires_api_key
    assert_raise(Decision::Jev::Error) do
      Decision::Jev::Client.new(
        api_key: nil
      )
    end
  end
end

