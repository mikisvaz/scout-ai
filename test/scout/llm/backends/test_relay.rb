require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestRelay < Test::Unit::TestCase
  # Real scp/ssh relay version moved to
  # test/integration/scout/llm/backends/test_relay.rb: LLM::Relay shells out
  # to `scp` and has no client seam, so the unit copy stays disabled.
  def _test_ask
    Scout::Config.set(:server, 'localhost', :relay)
    ppp LLM::Relay.ask 'Say hi', model: 'gemma2'
  end
end
