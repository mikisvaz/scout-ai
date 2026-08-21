require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/backends/openwebui'

# Infrastructure suite for the OpenWebUI backend.
#
# Per-backend endpoint probes (same-named endpoint) live in test_endpoints.rb;
# this file keeps the historically separate direct-URL check against the
# gepeto service, which is not configured through an endpoint yaml.
#
# Conditional omission: only runs when a key is configured for the service
# (config/env) AND a trivial authenticated request succeeds; otherwise the
# test omits with the detected reason.

class TestOpenWebUI < Test::Unit::TestCase
  URL = 'https://gepeto.bsc.es/api'

  def test_gepeto
    key = key_configured
    omit "no key configured for #{URL} (set the openwebui key in your Scout config)" if key.nil?

    reason = unavailable_reason
    omit reason if reason

    Log.severity = 0
    prompt =<<-EOF
user: write a script that sorts files in a directory
    EOF

    res = LLM::OpenWebUI.ask prompt, model: 'qwen3-vl:30b', url: URL, key: key

    assert res.is_a?(String) && !res.strip.empty?, 'OpenWebUI returned no answer'
  end

  private

  def key_configured
    key = Scout::Config.get(:key, :openwebui, :llm, env: 'OPENWEBUI_API_KEY', default: nil)
    key.to_s.strip.empty? ? nil : key
  end

  # A minimal real request (not just TCP) so 401/404/timeout are detected as
  # unavailability instead of raising as errors mid-test.
  def unavailable_reason
    key = key_configured
    headers = { 'Authorization' => "Bearer #{key}", 'Content-Type' => 'application/json' }
    payload = { model: 'qwen3-vl:30b', messages: [{role: 'user', content: 'Reply OK'}] }.to_json
    Timeout.timeout(30) { RestClient.post(File.join(URL, 'chat/completions'), payload, headers) }
    nil
  rescue Timeout::Error
    "request to #{URL} timed out"
  rescue RestClient::Unauthorized
    "key for #{URL} rejected (401)"
  rescue RestClient::NotFound
    nil # endpoint reachable and authenticated; model listing is not required
  rescue RestClient::Exception => e
    "#{URL} not usable: #{e.class}: #{e.message}"
  rescue Errno::ECONNREFUSED, SocketError, Errno::EHOSTUNREACH => e
    "#{URL} unreachable: #{e.class}"
  end
end
