require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/ask'
require 'scout/knowledge_base'

# Integration (real infrastructure) copy of test/scout/llm/test_ask.rb:
# the unit file tests the knowledge_base_ask pipeline offline with the
# scripted LLM::Mock backend; this one runs the same Miki brother-in-law
# question against a real inference point, exercising the whole
# marriages -> brothers tool chain over the wire.
#
# The endpoint defaults to the 'test' inference point (test/etc/AI or the
# user's own configuration); any other configured endpoint can be selected
# with SCOUT_TEST_ASK_ENDPOINT.
#
# Conditional omission: it omits with the detected reason when no endpoint
# is configured or it is not usable, instead of erroring.

class TestLLMAskIntegration < Test::Unit::TestCase
  ENDPOINT = ENV['SCOUT_TEST_ASK_ENDPOINT'] || 'test'

  def test_knowledge_base_ask_brother_in_law
    reason = unavailable_reason
    omit "endpoint #{ENDPOINT} not usable (#{reason})" if reason

    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true
      kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"

      question = "Who is Miki's brother in law? The brother in law is your spouse's sibling. " \
                 "Use the marriages and brothers tools to find out (nonce #{Time.now.to_i})."
      res = LLM.knowledge_base_ask(kb, question, endpoint: ENDPOINT)

      assert res.is_a?(String) && !res.strip.empty?, "endpoint #{ENDPOINT} returned no answer"
      assert_include res, 'Guille'
    end
  end

  private

  # A trivial real ask bounds the integration risk: the tool-chain question
  # below only runs once the endpoint has proven it can answer at all.
  def unavailable_reason
    return "endpoint #{ENDPOINT} is the offline mock defined by this suite; set SCOUT_TEST_ASK_ENDPOINT to a real one" if ENDPOINT == 'test'

    res = Timeout.timeout(120) { LLM.ask "Reply with the single word OK", endpoint: ENDPOINT, persist: false }
    res.to_s.strip.empty? ? 'trivial ask returned no answer' : nil
  rescue Timeout::Error
    "timeout on trivial ask"
  rescue Exception => e
    "#{e.class}: #{e.message.lines.first}"
  end
end
