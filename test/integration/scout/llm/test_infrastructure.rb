require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/ask'
require 'scout/knowledge_base'
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'support', 'infrastructure_probes'))

# General infrastructure suite.
#
# Target resolution (in order):
#   1. an endpoint named 'test' defined at installation level
#      (~/.scout/etc/AI/test.yaml and friends). The repo deliberately does
#      not define one (only the offline 'mock' lives in test/etc/AI), so
#      this one is always the user's own.
#   2. if 'test' is not defined, no endpoint is specified at all and the
#      installation default (config default backend/endpoint) is used.
#
# The suite omits with a detected reason when neither can work, and reports
# probe outcomes (latency, tokens) in the summary instead of raising; see
# test/support/infrastructure_probes.rb.
class TestInfrastructureGeneral < Test::Unit::TestCase

  # ScoutCoder: test_helper configures backend :mock for the unit suite; the
  # infrastructure suite must NOT inherit it (it would silently run the mock
  # as if it were real infrastructure). Scout::Config::CACHE is a plain hash
  # of set() entries, so dropping the unit entry at load time restores
  # whatever the installation actually configured.
  UNIT_MOCK_CACHE_KEYS = Scout::Config::CACHE.keys.select { |k| k.to_s == 'backend' }.dup
  UNIT_MOCK_CACHE_KEYS.each { |k| Scout::Config::CACHE.delete(k) }

  TARGET = if Availability.endpoint_configured?('test')
             :test_endpoint
           else
             :default
           end

  def test_general_trivial_question
    reason = target_reason
    InfrastructureProbes.record(target_name, :all, :omit, reason: reason) if reason
    omit reason if reason

    # the :test_endpoint case uses the installation-level endpoint named
    # 'test'; the :default case specifies nothing and lets the installation
    # default backend/endpoint apply
    ask_options = TARGET == :test_endpoint ? {endpoint: 'test'} : {}
    InfrastructureProbes.run_probes(target_name, ask_options)

    # ScoutCoder: test-unit's class-level `shutdown` hook does not fire under
    # this setup (neither direct file runs nor rake's test loader), and an
    # at_exit hook registered at load time runs BEFORE the autorunner. Writing
    # the summary at the end of this test method is the reliable spot; the
    # per-backend suite appends its rows afterwards.
    InfrastructureProbes.write_summary
  end

  private

  def target_name
    TARGET == :test_endpoint ? 'test' : '(default)'
  end

  # The default target is usable only when the installation actually
  # configured something to talk to; an empty configuration cannot serve any
  # ask, so we omit with the reason instead of failing.
  def target_reason
    if TARGET == :test_endpoint
      Availability.endpoint_reason('test')
    else
      backend  = Scout::Config.get(:backend, :ask, :llm, default: nil)
      endpoint = Scout::Config.get(:endpoint, :ask, :llm, default: nil)
      return "no 'test' endpoint defined at installation level and no default backend/endpoint configured" if backend.nil? && endpoint.nil?
      nil
    end
  end
end
