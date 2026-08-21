require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/ask'
require 'scout/knowledge_base'
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'support', 'infrastructure_probes'))

# Per-backend infrastructure suites. Each backend looks for an endpoint with
# the same name as itself (openai, responses, anthropic, ollama, bedrock,
# openwebui, relay). If the endpoint is not defined in the Scout AI paths,
# the suite omits with the detected reason; if it is defined, it runs the
# three probes (trivial ask, weather tool call, KnowledgeBase query) and
# reports latency/token usage in the shared summary instead of raising.
class TestLLMEndpointsByBackend < Test::Unit::TestCase
  include InfrastructureProbes

  BACKENDS = %w[openai responses anthropic ollama bedrock openwebui relay].freeze

  def test_backend_endpoints
    BACKENDS.each do |backend|
      reason = Availability.endpoint_reason(backend)
      if reason
        InfrastructureProbes.record(backend, :all, :omit, reason: reason)
        next
      end

      # The backend's own implementation must match the endpoint; when the
      # endpoint yaml points elsewhere the probes still use the endpoint as
      # configured, the backend name is only the target label.
      run_probes(backend, endpoint: backend)
    end

    InfrastructureProbes.write_summary
  end
end
