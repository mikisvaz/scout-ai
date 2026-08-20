require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative 'agent_meta_fixtures'

# Smoke tests for `scout-ai llm prov` (plan delivery step 5).  The command is a
# SOPT script, so the tests run the real binary in a subprocess against the
# AgentMetaFixtures layouts and compare its output with the Chat APIs; no
# providers and no network are involved.
#
# The prov binary works offline in this environment (verified manually), which
# is why a subprocess runner is used instead of loading the command in-process.
class TestProvCLI < Test::Unit::TestCase
  include AgentMetaFixtures

  REPO_ROOT = File.expand_path('../../../..', __dir__)

  def self.startup
    # Keep test progress output clean; the subprocess warnings are captured
    # separately by Open3 anyway.
    Log.severity = 5
  end

  def setup
    @prov_count = 0
  end

  # Run `scout-ai llm prov` and return [stdout, stderr, status], colors stripped.
  def prov(*args)
    cmd = [RbConfig.ruby, File.join(REPO_ROOT, 'bin', 'scout-ai'), 'llm', 'prov'] + args.collect(&:to_s)
    env = ENV.to_h.merge('SCOUT_DEV' => nil)
    Timeout.timeout(120) do
      out, err, status = Open3.capture3(env, *cmd, chdir: REPO_ROOT)
      [strip_ansi(out), strip_ansi(err), status]
    end
  end

  def strip_ansi(text)
    text.gsub(/\e\[[0-9;]*m/, '')
  end

  # Fixture B layout: parent receipt carrying w1/w2, worker log with w1/w2/w3.
  def fixture_b(dir)
    worker_log = "user: work\n" +
                 "meta: pt=100 ct=50 tt=150 inference_id=w1\n" +
                 "meta: pt=20 ct=10 tt=30 inference_id=w2\n" +
                 "meta: pt=5 ct=5 tt=10 inference_id=w3\n" +
                 "assistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text(
                          {'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                    meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')]},
                          extra: ['meta: pt=60 ct=40 tt=100 inference_id=p1',
                                  "meta: job=#{worker}"]
                        ))
    [parent, worker]
  end

  def test_tree_aggregate_matches_token_collector
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_b(dir)
      expected = Chat.provenance_token_totals(parent)

      out, _err, status = prov(parent)
      assert status.success?

      # Cross-consumer equality: the root chat line carries the collector total.
      root_line = out.lines.find { |line| line.include?('parent.chat') }
      assert root_line, out
      assert root_line.include?("total=#{expected[:tt]}"), root_line

      # One delegated annotation line for the two receipt events (w1 + w2).
      assert_match(/delegated receipt: 2 events, total=180/, out)
      assert_equal 1, out.lines.count { |line| line.include?('delegated receipt:') }

      # Chat.tokens and the CLI now come from the same collector.
      assert_equal expected, Chat.tokens(parent)
    end
  end

  def test_evidence_lists_events_addresses_and_call_ids
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_b(dir)

      out, _err, status = prov('--evidence', parent)
      assert status.success?
      assert_include out, 'Direct inference events'

      # Every direct event appears exactly once, with its id.
      %w[w1 w2 w3 p1].each do |id|
        rows = out.lines.count { |line| line =~ /^\s*#{id}\s/ }
        assert_equal 1, rows, "#{id} should appear once, got #{rows}\n#{out}"
      end

      # Receipt evidence keeps its parent output address and call id.
      assert_match(/agent_meta parent\.chat:3\[agent_meta,0\] call=a1/, out)
      assert_match(/agent_meta parent\.chat:3\[agent_meta,1\] call=a1/, out)

      # Chat-side evidence for the merged events.
      assert_match(/chat_meta agent\.chat:3/, out)

      # Status column; nothing is receipt-only, conflicting or duplicated here.
      assert_include out, 'counted once'
      assert_not_include out, 'Receipt-only events'
      assert_not_include out, 'conflict'
      assert_not_include out, 'Job projection references'
    end
  end

  def test_tree_marks_delegated_jobs_only
    Dir.mktmpdir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      out, _err, status = prov(parent)
      assert status.success?

      # Worker is reached through a receipt (relation :agent_job) ...
      assert_match(/delegated-job w\b/, out)
      # ... while the Critic, referenced by an ordinary local meta job= line
      # (relation :job), keeps the plain job rendering.
      assert_match(/^\s*job\s+c\b/, out)
      assert_not_match(/delegated-job c\b/, out)

      # Delegated usage of the parent chat is annotated once.
      assert_equal 1, out.lines.count { |line| line.include?('delegated receipt:') }
    end
  end

  def test_flow_and_dot_render_delegated_result_without_extra_nodes
    Dir.mktmpdir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      out, _err, status = prov('--flow', parent)
      assert status.success?
      assert_include out, 'delegated_result'
      kinds = out.lines.grep(/^\[\s*\d+\] (Job|Chat)/).collect { |line| line.strip[/\] (\w+)/, 1] }
      assert kinds.all? { |kind| %w[Job Chat].include?(kind) }, out

      dot_file = File.join(dir, 'prov.dot')
      out2, _err2, status2 = prov('--dot', dot_file, parent)
      assert status2.success?
      dot = File.read(dot_file)

      assert_include dot, 'delegated_result'
      shapes = dot.scan(/^\s+n\d+ \[shape=(\w+)/).flatten
      # Only chat/job node kinds exist: 3 jobs (box) + the parent chat (note).
      assert shapes.all? { |shape| %w[box note].include?(shape) }, dot
      assert_equal 4, shapes.length, dot
      assert_not_include dot, 'agent_meta'
    end
  end

  def test_component_mode_prints_scopes_only_with_receipts
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_b(dir)

      out, _err, status = prov('--component', parent)
      assert status.success?
      assert_include out, 'evidence deduplicated_total:'
      assert_include out, 'evidence chat_evidence:'
      assert_include out, 'evidence receipt_evidence:'
      assert_include out, 'evidence receipt_only:'

      expected = Chat.provenance_token_totals(parent)
      assert_match(/evidence deduplicated_total: total=#{expected[:tt]}/, out)

      # Coverage figures are explicitly labelled as overlapping; nothing in
      # the output invites summing them.
      assert_include out, 'overlaps chat_evidence', out
      assert_include out, 'no saved chat/log', out

      # No conflicts in this fixture: no non-authoritative label.
      assert_not_include out, 'not exact', out
    end

    Dir.mktmpdir do |dir|
      plain = write_chat(dir, 'plain.chat',
                         "user: hi\nmeta: pt=1 ct=1 tt=2 inference_id=x1\nassistant: done\n")

      out, _err, status = prov('--component', plain)
      assert status.success?
      assert_not_include out, 'evidence deduplicated_total:', 'legacy chat must not gain scope lines'
      assert_not_include out, 'evidence chat_evidence:'
      assert_not_include out, 'evidence receipt_evidence:'
      assert_not_include out, 'evidence receipt_only:'
      assert_not_include out, 'delegated receipt:'
    end
  end

  def test_malformed_receipt_renders_with_warning
    Dir.mktmpdir do |dir|
      payload = {'id' => 'bad1', 'result' => 'x', 'agent_meta' => 'oops'}
      text = "user: hi\n" +
             'function_call: ' + %({"name":"ask","arguments":{},"id":"bad1"}) + "\n" +
             'function_call_output: ' + JSON.generate(payload) + "\n" +
             "meta: pt=10 ct=5 tt=15 inference_id=p9\n" +
             "assistant: done\n"
      bad = write_chat(dir, 'bad.chat', text)

      out, err, status = prov(bad)
      assert status.success?, 'a malformed receipt must never abort rendering'

      assert_include out, 'total=15', out
      assert_include err, 'agent_meta receipt:', err
      assert_include err, 'not_an_array', err
      assert_include err, 'bad1', err
      # The specific receipt line replaces the generic traversal warning, so a
      # malformed receipt must not print both lines.
      assert_not_include err, 'Incomplete provenance at', err
    end
  end

  def test_evidence_compact_legacy_ids_and_zero_scope
    Dir.mktmpdir do |dir|
      # Receipt-only chat with a legacy (no inference_id) meta: local scope has
      # no events at all.
      legacy = write_chat(dir, 'legacy.chat',
                          receipt_chat_text({'r1' => [meta_receipt('pt=3 tt=5')]}))

      out, _err, status = prov('--component', legacy)
      assert status.success?
      assert_include out, 'evidence chat_evidence: total=0', out
      assert_include out, 'evidence receipt_evidence: total=5'
      assert_include out, 'evidence receipt_only: total=5'

      out, _err, status = prov('--evidence', legacy)
      assert status.success?
      # Legacy receipt events show their receipt location instead of the raw
      # address array, and they are flagged as possibly overcounted.
      assert_match(/receipt=legacy\.chat:3\[agent_meta,0\]/, out)
      assert_include out, 'legacy unresolved'
      assert_not_include out, 'receipt=["', out
    end
  end
end
