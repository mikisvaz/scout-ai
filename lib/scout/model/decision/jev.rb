# frozen_string_literal: true

require_relative 'base'
require "json"
require "net/http"
require "uri"

class Decision
  class Jev < Decision
    DEFAULT_URL = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"

    RETRYABLE_STATUS = [429, 529].freeze

    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class Client
      def initialize(
        api_key: Scout::Config.get(:key, :jev, env: 'TYPESAFE_API_KEY'),
        url: DEFAULT_URL,
        open_timeout: 10,
        read_timeout: 120,
        max_retries: 2,
        retry_base: 0.25,
        http_factory: nil,
        sleeper: nil
      )
        raise Error, "TYPESAFE_API_KEY is not configured" if api_key.to_s.empty?

        @api_key = api_key
        @url = url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @retry_base = retry_base

        @http_factory = http_factory || method(:default_http)
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      def evaluate(model:, state:, questions:)
        request(
          model: model,
          state: state,
          questions: questions
        )
      end

      private

      def request(payload)
        attempts = 0

        loop do
          response = perform_request(payload)
          status = response.code.to_i

          return parse_response(response) if status.between?(200, 299)

          if RETRYABLE_STATUS.include?(status) && attempts < @max_retries
            @sleeper.call(retry_delay(response, attempts))
            attempts += 1
            next
          end

          raise Error.new(
            "Jev API request failed: HTTP #{status}",
            status: status,
            body: response.body
          )
        end
      end

      def perform_request(payload)
        uri = URI.parse(@url)
        http = @http_factory.call(uri)

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(payload)

        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        http.request(request)
      rescue URI::InvalidURIError => e
        raise Error, "Invalid Jev URL: #{e.message}"
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "Jev request failed: #{e.class}: #{e.message}"
      end

      def default_http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = (uri.scheme == "https")
        end
      end

      def parse_response(response)
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Error.new(
          "Jev API returned invalid JSON: #{e.message}",
          status: response.code.to_i,
          body: response.body
        )
      end

      def retry_delay(response, attempt)
        retry_after = response["Retry-After"]

        return retry_after.to_f if retry_after&.match?(/\A\d+(?:\.\d+)?\z/)

        @retry_base * (2**attempt)
      end
    end

    attr_reader :model, :client

    def initialize(options = {})
      super(nil, options)

      @model = options.fetch(:model, DEFAULT_MODEL)

      @client =
        options[:client] ||
        Client.new(
          **options.slice(
            :api_key,
            :url,
            :open_timeout,
            :read_timeout,
            :max_retries,
            :retry_base
          ).compact
        )
    end

    protected

    def query(input)
      @client.evaluate(
        model: @model,
        state: input,
        questions: @questions
      )
    end
  end
end

