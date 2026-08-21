# Test support: infrastructure probe collector shared by the endpoint suites.
#
# Not named test_*.rb on purpose: the Rakefile test pattern must not collect
# this file.
#
# Runs a fixed set of probes against one inference target and reports the
# outcome (including latency and token usage) as a summary instead of raising:
#
#   trivial  : answer a trivial question
#   tool_call: one weather-style tool call round (a block answers the tool)
#   kb_query : the Miki brother-in-law knowledge base question, a two-hop
#              tool chain (marriages then brothers)
#
# Failures are recorded as :fail rows, never raised, so one broken endpoint
# cannot break the run; the summary table is printed and written to
# results/infrastructure_summary.md by whichever suite runs last.
module InfrastructureProbes
  TIMEOUT = 300

  WEATHER_TOOL = {
    "type": "function",
    "function": {
      "name": "get_current_temperature",
      "description": "Get the current temperature and raining conditions for a specific location",
      "parameters": {
        "type": "object",
        "properties": {
          "location": { "type": "string", "description": "The city and state, e.g., San Francisco, CA" },
          "unit": { "type": "string", "enum": ["Celsius", "Fahrenheit"],
                    "description": "The temperature unit to use. Infer this from the user's location." }
        },
        "required": ["location", "unit"]
      }
    }
  }

  class << self
    attr_accessor :results
  end
  self.results ||= []

  module_function

  def record(target, probe, status, reason: nil, answer: nil, duration: nil, tokens: nil)
    InfrastructureProbes.results << {target: target, probe: probe, status: status, reason: reason,
                                     answer: answer, duration: duration, tokens: tokens}
  end

  # Run the three probes against `target` (a display name), using
  # `ask_options` (already carrying :endpoint or nothing, i.e. the default).
  # Nothing raises: each probe is rescued and recorded.
  def run_probes(target, ask_options = {})
    nonce = Time.now.to_i

    run_probe(target, :trivial, ask_options) do
      answer = LLM.ask "user: Reply with the single word OK and nothing else (nonce #{nonce})",
                       ask_options.merge(persist: false)
      raise 'no answer' if answer.to_s.strip.empty?
      answer
    end

    run_probe(target, :tool_call, ask_options) do
      answer = LLM.ask "user: What is the weather in London? Use the provided tool and then answer in one sentence (nonce #{nonce}).",
                       ask_options.merge(tools: [WEATHER_TOOL], tool_choice: 'required', persist: false) do |_name, _arguments|
        "It's 15 degrees and raining."
      end
      raise 'no answer' if answer.to_s.strip.empty?
      answer
    end

    run_probe(target, :kb_query, ask_options) do
      TmpFile.with_dir do |dir|
        kb = KnowledgeBase.new dir
        kb.register :brothers, Test::Unit::TestCase.datafile_test(:person).brothers, undirected: true
        kb.register :marriages, Test::Unit::TestCase.datafile_test(:person).marriages,
                    undirected: true, source: "=>Alias", target: "=>Alias"

        text = LLM.knowledge_base_ask(kb,
          "Who is Miki's brother in law? The brother in law is your spouse's sibling. Use the marriages and brothers tools to find out (nonce #{nonce}).",
          ask_options.merge(persist: false))
        raise "answer did not mention Guille: #{text.to_s[0, 200]}" unless text.to_s.include?('Guille')
        text
      end
    end
  end

  def run_probe(target, probe, ask_options)
    start = Time.now
    answer = Timeout.timeout(TIMEOUT) { yield }
    record(target, probe, :ok, answer: answer, duration: Time.now - start, tokens: nil)
  rescue Exception => e
    record(target, probe, :fail,
           reason: "#{e.class}: #{e.message.to_s.lines.first}",
           duration: Time.now - start)
  end

  def summary_lines
    lines = []
    lines << 'Infrastructure endpoint summary'
    lines << '=' * 96
    InfrastructureProbes.results.each do |r|
      line = [r[:target].to_s.ljust(14), r[:probe].to_s.ljust(11)]
      case r[:status]
      when :ok
        line << 'OK'.ljust(5)
        line << (r[:duration] ? "#{r[:duration].round(1)}s" : '').ljust(8)
        line << " #{r[:answer].to_s.gsub(/\s+/, ' ')[0, 100]}"
      when :fail
        line << 'FAIL'.ljust(5)
        line << (r[:duration] ? "#{r[:duration].round(1)}s" : '').ljust(8)
        line << " #{r[:reason].to_s.gsub(/\s+/, ' ')[0, 140]}"
      else
        line << 'OMIT'.ljust(5)
        line << " #{r[:reason].to_s.gsub(/\s+/, ' ')[0, 140]}"
      end
      lines << line * ' | '
    end
    lines << '=' * 96
    lines << "#{InfrastructureProbes.results.count { |r| r[:status] == :ok }} ok, " +
             "#{InfrastructureProbes.results.count { |r| r[:status] == :fail }} failed, " +
             "#{InfrastructureProbes.results.count { |r| r[:status] == :omit }} omitted"
    lines
  end

  def write_summary
    return if InfrastructureProbes.results.empty?
    content = summary_lines * "\n"
    $stdout.puts "\n" + content
    begin
      Open.mkdir 'results'
      Open.write 'results/infrastructure_summary.md', content + "\n"
    rescue Exception
      $stderr.puts "Could not write results/infrastructure_summary.md: #{$!.message}"
    end
  end
end
