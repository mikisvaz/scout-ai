require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestOpenWebUI < Test::Unit::TestCase
  # Real https://gepeto.bsc.es/api version moved to
  # test/integration/scout/llm/backends/test_openwebui.rb (no client seam:
  # LLM::OpenWebUIMethods#query posts through RestClient.post with a plain
  # Hash "client").
  def _test_gepeto
    Log.severity = 0
    prompt =<<-EOF
user: write a script that sorts files in a directory 
    EOF

    ppp LLM::OpenWebUI.ask prompt, model: 'qwen3-vl:30b', url: "https://gepeto.bsc.es/api"
  end

  # Offline: stub RestClient.post so only request construction and response
  # parsing are exercised. OpenWebUI is OpenAI-compatible, so the openai_chat
  # fixture is replayed as the response body.
  def test_ask_request_construction
    fixture = TestFixtures.fixture('backends/openai_chat')
    expected_answer = fixture.dig('choices', 0, 'message', 'content')

    recorded = []
    original = RestClient.method(:post)

    RestClient.define_singleton_method(:post) do |url, payload, headers|
      recorded << {url: url, payload: JSON.parse(payload), headers: headers}
      body = Struct.new(:body).new(fixture.to_json)
      body
    end

    begin
      answer = LLM::OpenWebUI.ask 'user: write a script that sorts files in a directory offline',
                                  model: 'qwen3-vl:30b', url: 'https://openwebui.example/api',
                                  key: 'test-key', persist: false
    ensure
      RestClient.singleton_class.send(:define_method, :post, original)
    end

    assert_equal expected_answer, answer

    assert_equal 1, recorded.length
    call = recorded.first

    assert call[:url].end_with?('chat/completions')
    assert call[:url].start_with?('https://openwebui.example/api')

    payload = call[:payload]
    assert_equal 'qwen3-vl:30b', payload['model']
    assert payload['messages'].any? { |m| m['role'] == 'user' }

    headers = call[:headers]
    assert headers['Authorization'] || headers[:Authorization]
    assert_equal 'Bearer test-key', (headers['Authorization'] || headers[:Authorization]).to_s
    assert((headers['Content-Type'] || headers[:Content_Type]).to_s.include?('application/json'))
  end
end
