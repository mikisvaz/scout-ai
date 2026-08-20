require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/backends/relay'

# Integration (real infrastructure) copy of test/scout/llm/backends/test_relay.rb:
# LLM::Relay shells out to `scp` against a reachable server, so there is no
# client seam to fake. Kept out of the default unit suite; run with
# `rake test_integration`.
#
# Conditional omission: only runs when a relay server is configured,
# SSH-reachable AND a non-interactive `ssh true` succeeds (port 22 being open
# is not enough: without working keys the scp fails mid-test with an error
# instead of a clean omission).

class TestRelay < Test::Unit::TestCase
  SERVER = ENV['SCOUT_TEST_RELAY_SERVER'] || Scout::Config.get(:server, :relay, default: 'localhost')

  def test_ask
    reason = unavailable_reason
    omit "relay server #{SERVER} not usable (#{reason}; set SCOUT_TEST_RELAY_SERVER or the relay server config)" if reason

    Scout::Config.set(:server, SERVER, :relay)
    res = LLM::Relay.ask 'Say hi', model: 'gemma2'

    assert res.is_a?(String) && !res.strip.empty?, 'relay returned no answer'
  end

  private

  def unavailable_reason
    server = SERVER.to_s
    return 'no server configured' if server.empty?

    host = server.split(':').first
    return 'no host in server setting' if host.nil? || host.empty?

    require 'socket'
    begin
      Timeout.timeout(5) { TCPSocket.open(host, 22) { |s| s.close } }
    rescue Exception => e
      return "ssh port unreachable (#{e.class})"
    end

    # ScoutCoder: use backticks (not Open.run, which does not exist) for the
    # non-interactive ssh probe; BatchMode fails fast instead of hanging on a
    # password prompt, so the probe itself cannot block the test run.
    `ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new #{host} true > /dev/null 2>&1`
    return nil if $?.success?

    "ssh login failed (exit #{$?.exitstatus})"
  end
end
