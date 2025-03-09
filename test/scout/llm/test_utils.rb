require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestLLMUtils < Test::Unit::TestCase
  def test_server_tokens
    assert_equal %w(some random server some.random random.server some.random.server some.random.server.com), LLM.get_url_server_tokens('http://some.random.server.com/api')
    assert_equal %w(ollama.some ollama.server ollama.some.server ollama.some.server.com), LLM.get_url_server_tokens('http://some.server.com/api', :ollama)
  end
end

