require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout/llm/ask'
require 'scout/knowledge_base'

# Per-endpoint smoke suite: for every endpoint configured in the Scout AI
# paths (test/etc/AI plus the user configuration), run three probes:
#
#   1. trivial  : answer a trivial question
#   2. tool_call: one weather-style tool call round (block answers the tool)
#   3. kb_query : the Miki brother-in-law knowledge base question, which
#                 needs a two-hop tool chain (marriages then brothers)
#
# This is a diagnostic suite: probe failures are NOT raised as test failures,
# they are collected and reported as a summary table at the end of the run
# (and written to results/endpoint_smoke.md). The test itself only fails if
# the suite could not run at all (no endpoints configured at all).
#
# Endpoints that are not configured or not reachable are omitted with the
# detected reason instead of erroring (see test/support/availability.rb).
class TestEndpointSmoke < Test::Unit::TestCase
  TIMEOUT = 300

  WEATHER_TOOL = {
    "type": "function",
    "function": {
      "name": "get_current_temperature",
      "description": "Get the current temperature and raining conditions for a specific location",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The city and state, e.g., San Francisco, CA"
          },
          "unit": {
            "type": "string",
            "enum": ["Celsius", "Fahrenheit"],
            "description": "The temperature unit to use. Infer this from the user's location."
          }
        },
        "required": ["location", "unit"]
      }
    }
  }.freeze

  class << self
    def results
      @results ||= []
    end

    def record(endpoint, probe, status, reason: nil, answer: nil, duration: nil)
      results << {endpoint: endpoint, probe: probe, status: status, reason: reason, answer: answer, duration: duration}
    end

    def write_summary
      return if results.empty?
      content = summary_lines * "\n"
      $stdout.puts "\n" + content
      begin
        Open.mkdir 'results'
        Open.write 'results/endpoint_smoke.md', content + "\n"
      rescue Exception
        $stderr.puts "Could not write results/endpoint_smoke.md: #{$!.message}"
      end
    end

    def summary_lines
      lines = []
      lines << 'Endpoint smoke summary'
      lines << '=' * 80
      results.each do |r|
        line = [r[:endpoint].to_s.ljust(18), r[:probe].to_s.ljust(12)]
        case r[:status]
        when :ok
          line << 'OK'.ljust(6)
          line << (r[:duration] ? "#{r[:duration].round(1)}s" : '').ljust(8)
          line << " #{r[:answer].to_s.gsub(/\s+/, ' ')[0,120]}"
        when :fail
          line << 'FAIL'.ljust(6)
          line << (r[:duration] ? "#{r[:duration].round(1)}s" : '').ljust(8)
          line << " #{r[:reason].to_s.gsub(/\s+/, ' ')[0,160]}"
        else
          line << 'OMIT'.ljust(6)
          line << " #{r[:reason].to_s.gsub(/\s+/, ' ')[0,160]}"
        end
        lines << line * ' | '
      end
      lines << '=' * 80
      lines << "#{results.count { |r| r[:status] == :ok }} ok, " +
               "#{results.count { |r| r[:status] == :fail }} failed, " +
               "#{results.count { |r| r[:status] == :omit }} omitted"
      lines
    end
  end

  # Endpoints probed: every configured one; the offline 'test' mock endpoint
  # is listed but marked omitted-for-smoke so the table stays complete.
  def endpoints
    @endpoints ||= Availability.configured_endpoints
  end

  def test_endpoints
    assert !endpoints.empty?, 'no endpoints configured at all (no yaml in the Scout AI paths)'

    endpoints.each do |endpoint|
      if endpoint == 'test'
        TestEndpointSmoke.record(endpoint, :all, :omit, reason: "offline mock endpoint defined by this test suite; see unit tests for its coverage")
        next
      end

      reason = Availability.endpoint_reason(endpoint)
      if reason
        TestEndpointSmoke.record(endpoint, :all, :omit, reason: reason)
        next
      end

      # 1. trivial question
      with_probe(endpoint, :trivial) do
        answer = LLM.ask "user: Reply with the single word OK and nothing else (nonce #{Time.now.to_i})",
                         endpoint: endpoint, persist: false
        raise "no answer" if answer.to_s.strip.empty?
        answer
      end

      # 2. simple weather tool call
      with_probe(endpoint, :tool_call) do
        answer = LLM.ask "user: What is the weather in London? Use the provided tool and then answer in one sentence (nonce #{Time.now.to_i}).",
                         endpoint: endpoint, tools: [WEATHER_TOOL], tool_choice: 'required',
                         persist: false do |name, arguments|
          "It's 15 degrees and raining."
        end
        raise "no answer" if answer.to_s.strip.empty?
        answer
      end

      # 3. knowledge base query (two-hop tool chain)
      with_probe(endpoint, :kb_query) do
        TmpFile.with_dir do |dir|
          kb = KnowledgeBase.new dir
          kb.register :brothers, datafile_test(:person).brothers, undirected: true
          kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"

          res = LLM.knowledge_base_ask(kb,
            "Who is Miki's brother in law? The brother in law is your spouse's sibling. Use the marriages and brothers tools to find out (nonce #{Time.now.to_i}).",
            endpoint: endpoint)
          raise "no answer" if res.to_s.strip.empty?
          unless res.include?('Guille')
            raise "answer did not mention Guille: #{res.to_s[0,200]}"
          end
          res
        end
      end
    end

    # ScoutCoder: test-unit's class-level `shutdown` hook does not fire under
    # this setup (neither direct file runs nor rake's test loader), and an
    # at_exit hook registered at load time runs BEFORE the autorunner (at_exit
    # is LIFO and 'test/unit' is required first), so it would print an empty
    # summary. Reporting at the end of the test method is the reliable spot:
    # all probes have run and per-probe failures were rescued, not raised.
    TestEndpointSmoke.write_summary
  end

  private

  def with_probe(endpoint, probe)
    start = Time.now
    answer = Timeout.timeout(TIMEOUT) { yield }
    TestEndpointSmoke.record(endpoint, probe, :ok, answer: answer, duration: Time.now - start)
  rescue Exception => e
    TestEndpointSmoke.record(endpoint, probe, :fail, reason: "#{e.class}: #{e.message.lines.first}", duration: Time.now - start)
  end
end
