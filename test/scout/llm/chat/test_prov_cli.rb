require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
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
    TmpFile.with_dir do |dir|
      parent, _worker = fixture_b(dir)
      expected = Chat.provenance_token_totals(parent)

      out, _err, status = prov(parent)
      assert status.success?

      # Cross-consumer equality: the root chat line carries the collector total
      # under the evidence= label (subtree-deduplicated closure).
      root_line = out.lines.find { |line| line.include?('parent.chat') }
      assert root_line, out
      assert root_line.include?("evidence=#{expected[:tt]}"), root_line

      # The authoritative root footer always follows the tree.
      assert_match(/root deduplicated_total=#{expected[:tt]} /, out)

      # One delegated annotation line for the two receipt events (w1 + w2).
      assert_match(/delegated receipt: 2 events, total=180/, out)
      assert_equal 1, out.lines.count { |line| line.include?('delegated receipt:') }

      # Chat.tokens and the CLI now come from the same collector.
      assert_equal expected, Chat.tokens(parent)
    end
  end

  def test_saved_chat_with_files_sidecar_is_not_a_job
    TmpFile.with_dir do |dir|
      # A saved agent chat carries a .files sidecar but no .info sidecar: it
      # must be rendered as a chat root, never loaded as a Step.
      saved = write_chat(dir, 'saved.chat',
                         "user: hi\nmeta: pt=1 ct=1 tt=2 inference_id=s1\nassistant: done\n")
      society_chat = File.join(saved + '.files', 'agent.society', 'Worker', 'default', 'agent.chat')
      FileUtils.mkdir_p(File.dirname(society_chat))
      File.write(society_chat,
                 "user: work\nmeta: pt=5 ct=2 tt=7 inference_id=s2\nassistant: ok\n")
      assert !File.exist?(saved + '.info')

      out, err, status = prov(saved)
      assert status.success?, "prov must not blow up on a .files-only chat\n#{err}"

      # Root classification: the rendered root is the chat itself, not a job
      # node. Its aggregate now includes the society conversation in the
      # sidecar (2 + 7 = 9), because chats with a .files sidecar are scanned
      # for socialized agent conversations just like jobs.
      root_line = out.lines.find { |line| line.include?('saved.chat') && !line.include?('.files') }
      assert root_line, out
      assert_match(/\A\s*chat\b/, root_line, out)
      assert_not_match(/\A\s*job\b/, root_line, out)
      assert_include root_line, 'evidence=9', out
      assert_include root_line, 'prompt=6', out
      assert_match(/root deduplicated_total=9 /, out)

      # The society conversation is traversed and rendered as its own node.
      society_line = out.lines.find { |line| line.include?('agent.society/Worker/default/agent.chat') }
      assert society_line, out
      assert_match(/\A\s*chat\b/, society_line, out)
      assert_include society_line, 'evidence=7', out
      assert_include society_line, 'prompt=5', out
    end
  end

  def test_evidence_lists_events_addresses_and_call_ids
    TmpFile.with_dir do |dir|
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
      assert_match(/agent_meta parent\.chat:2\[meta,0\] call=a1/, out)
      assert_match(/agent_meta parent\.chat:2\[meta,1\] call=a1/, out)

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
    TmpFile.with_dir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      out, _err, status = prov(parent)
      assert status.success?

      # Worker is reached through a receipt (relation :agent_job) ...
      assert_match(/delegated-job (Default_)?w\b/, out)
      # ... while the Critic, referenced by an ordinary local meta job= line
      # (relation :job), keeps the plain job rendering.
      assert_match(/^\s*job\s+(Default_)?c\b/, out)
      assert_not_match(/delegated-job (Default_)?c\b/, out)

      # Delegated usage of the parent chat is annotated once.
      assert_equal 1, out.lines.count { |line| line.include?('delegated receipt:') }
    end
  end

  def test_flow_and_dot_render_delegated_result_without_extra_nodes
    TmpFile.with_dir do |dir|
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
    TmpFile.with_dir do |dir|
      parent, _worker = fixture_b(dir)

      out, _err, status = prov('--component', parent)
      assert status.success?
      assert_include out, 'evidence chat_evidence:'
      assert_include out, 'evidence receipt_evidence:'
      assert_include out, 'evidence receipt_only:'

      expected = Chat.provenance_token_totals(parent)
      # The scope block no longer repeats the authoritative total; the root
      # footer (printed in both modes) is its single home.
      assert_not_include out, 'evidence deduplicated_total:', 'scope block must stay 3 lines'
      assert_match(/root deduplicated_total=#{expected[:tt]} /, out)

      # Coverage figures are explicitly labelled as overlapping; nothing in
      # the output invites summing them.
      assert_include out, 'overlaps chat_evidence', out
      assert_include out, 'no saved chat/log', out

      # No conflicts in this fixture: no non-authoritative label.
      assert_not_include out, 'not exact', out
      # The -c conflict caveat comes from the footer only (still none here).
      assert_not_include out, 'unresolved identity conflicts', out
    end

    TmpFile.with_dir do |dir|
      plain = write_chat(dir, 'plain.chat',
                         "user: hi\nmeta: pt=1 ct=1 tt=2 inference_id=x1\nassistant: done\n")

      out, _err, status = prov('--component', plain)
      assert status.success?
      # Footer is present in -c even without any receipt evidence.
      assert_match(/root deduplicated_total=2 /, out)
      assert_include out, 'fresh=', out
      assert_not_include out, 'evidence deduplicated_total:', 'legacy chat must not gain scope lines'
      assert_not_include out, 'evidence chat_evidence:'
      assert_not_include out, 'evidence receipt_evidence:'
      assert_not_include out, 'evidence receipt_only:'
      assert_not_include out, 'delegated receipt:'
    end
  end

  def test_malformed_receipt_renders_with_warning
    TmpFile.with_dir do |dir|
      payload = {'id' => 'bad1', 'result' => 'x', 'meta' => 'oops'}
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
    TmpFile.with_dir do |dir|
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
      assert_match(/receipt=legacy\.chat:2\[meta,0\]/, out)
      assert_include out, 'legacy unresolved'
      assert_not_include out, 'receipt=["', out
    end
  end

  # Option B display contract: job nodes carry delta= (direct tokens of the
  # persisted chat-typed result) alongside evidence=, jobs without a
  # chat-typed result omit the field, and the root footer always follows.
  def test_job_node_delta_labelled_and_footer_present
    TmpFile.with_dir do |dir|
      parent_metas = (1..3).collect { |i| "meta: pt=10 tt=10 inference_id=p#{i}" }
      own_metas = (1..2).collect { |i| "meta: pt=100 tt=100 inference_id=o#{i}" }
      result = "user: b\n#{own_metas * "\n"}\n"
      # The job log is the cumulative history: parent's 3 projected + own 2.
      log = ["user: a", parent_metas, "user: b", own_metas].flatten.join("\n") + "\n"
      job = make_job(dir, 'Chain/continue/Default_d', result: result, logs: {'agent.chat' => log})
      info = JSON.parse(File.read(job + '.info'))
      File.write(job + '.info', {dependencies: info['dependencies'], type: :chat}.to_json)

      out, _err, status = prov(job)
      assert status.success?

      # Job line: evidence closure (5 events once = 230) plus delta (200).
      root_line = out.lines.find { |line| line =~ /\A job\b/ }
      assert root_line, out
      assert_include root_line, 'evidence=230', root_line
      assert_include root_line, 'delta=200', root_line

      # Footer: the authoritative figure, always printed, carrying the event
      # count that no longer lives on the node line.
      assert_match(/root deduplicated_total=230 \(5 events\)/, out)

      # A job whose result is NOT chat-typed omits delta= entirely.
      plain = make_job(dir, 'Chain/ask/Default_n', result: "answer\n",
                       logs: {'agent.chat' => "user: x\nmeta: pt=1 tt=1 inference_id=n1\n"})
      out2, _err2, status2 = prov(plain)
      assert status2.success?
      job_line = out2.lines.find { |line| line =~ /\A job\b/ }
      assert job_line, out2
      assert_include job_line, 'evidence=1', job_line
      assert_not_include job_line, 'delta=', job_line
      assert_match(/root deduplicated_total=1 /, out2)
    end
  end

  # A JOB root whose top-level agent.chat log carries meta job pointers: the
  # delegated children must appear in the tree nested under the owning job,
  # even though the carrier chat itself stays hidden.
  def test_job_root_delegated_children_nest_in_tree
    TmpFile.with_dir do |dir|
      child1 = make_job(dir, 'Cortex/continue/Default_c1')
      child2 = make_job(dir, 'Cortex/continue/Default_c2')
      worker_log = receipt_chat_text(
        {'w1' => [meta_receipt("job=#{child1}"),
                  meta_receipt("job=#{child2}")]}
      )
      worker = make_job(dir, 'Planned/work/Default_w',
                        logs: {'agent.chat' => worker_log})

      out, err, status = prov(worker)
      assert status.success?, err

      root_line = out.lines.find { |line| line.include?('Default_w') && !line.include?('Default_c') }
      assert root_line, out
      assert_match(/\A job\b/, root_line, out)

      child_lines = out.lines.select { |line| line =~ /delegated-job .*Default_c[12]/ }
      assert_equal 2, child_lines.length, out
      child_lines.each do |line|
        assert_match(/\A   job delegated-job\b/, line, "#{line} must nest two spaces under the job root")
      end
      assert_not_include out, 'agent.chat', 'carrier chat must stay hidden in tree mode'
    end
  end

  # Deliberate breakage (plan B2): the legacy `agent_meta` envelope key is no
  # longer read.  A worker log whose job= receipts travel under the legacy key
  # produces NO delegated children (old chats intentionally lose those edges).
  def test_job_root_legacy_agent_meta_receipt_has_no_children
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Worker/ask/Default_legacy')
      worker_log = receipt_chat_text(
        {'l1' => [{role: 'meta', content: "job=#{child}"}]},
        envelope: :agent_meta
      )
      worker = make_job(dir, 'Planned/work/Default_wl',
                        logs: {'agent.chat' => worker_log})

      out, _err, status = prov(worker)
      assert status.success?
      assert_not_include out, 'Default_legacy', out
      assert_not_include out, 'delegated-job', out

      # The same receipt under the current `meta` key DOES produce the child.
      current = receipt_chat_text(
        {'l1' => [{'job' => child}]}
      )
      worker2 = make_job(dir, 'Planned/work/Default_wc',
                        logs: {'agent.chat' => current})
      out2, _err, status2 = prov(worker2)
      assert status2.success?
      assert_match(/delegated-job .*Default_legacy/, out2)
    end
  end


  # Job refs recorded by chat_task are chat-typed (Cortex/continue/Default_x.chat).
  # Tree mode must resolve them and nest the delegated child once per distinct
  # job, even when the parent repeated the same conversation three times.
  def test_job_root_repeated_meta_refs_nest_once
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Cortex/continue/Default_dup.chat')
      worker_log = receipt_chat_text(
        {'a1' => [{'job' => child}], 'a2' => [{'job' => child}], 'a3' => [{'job' => child}]},
        envelope: :meta
      )
      worker = make_job(dir, 'Planned/work/Default_w3',
                        logs: {'agent.chat' => worker_log})

      out, err, status = prov(worker)
      assert status.success?, err

      child_lines = out.lines.select { |line| line =~ /delegated-job .*Default_dup/ }
      assert_equal 1, child_lines.length, out
      assert_match(/\A   job delegated-job\b/, child_lines.first, out)
    end
  end

  # A meta job pointer that does not resolve on disk must degrade to a
  # warning, not an exception, and must not break the tree.
  def test_dangling_meta_job_pointer_warns
    TmpFile.with_dir do |dir|
      missing = File.join(dir, 'Nope', 'ask', 'Default_x.chat')
      worker_log = receipt_chat_text(
        {'d1' => [meta_receipt("job=#{missing}")]}
      )
      worker = make_job(dir, 'Planned/work/Default_wd',
                        logs: {'agent.chat' => worker_log})

      out, err, status = prov(worker)
      assert status.success?, 'a dangling pointer must never abort rendering'
      assert_include err, 'agent_meta receipt:', err
      assert_include err, 'unresolved_job_reference', err
      assert_include err, 'Default_x', err
      assert_match(/\A job Default_wd/, out)
      assert_not_include out, 'Default_x'
    end
  end


  # ---- Phase 10: reworked accounting/presentation contract ---------------

  # 1 + 2 + 3: cache rate from RAW integers (rounding boundary pt=1_999_999
  # cct=1_000_000 -> 50.0%), fresh only in the footer, canonical field order.
  def test_footer_cache_rate_and_fresh_from_raw_integers
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'round.chat',
                        "user: hi\n" +
                        "meta: pt=1999999 ct=1 tt=2000000 cct=1000000 inference_id=r1 timestamp=2026-09-04T00:00:00Z\n" +
                        "meta: pt=0 ct=1 tt=500 inference_id=r2 timestamp=2026-09-04T00:00:00Z\n" +
                        "assistant: ok\n")

      out, _err, status = prov(chat)
      assert status.success?

      node_line = out.lines.find { |line| line.include?('round.chat') }
      footer = out.lines.find { |line| line.start_with?('root') }
      assert footer, out

      # Raw-integer rate on both node and footer: 100.0 * 1000000/1999999
      # is 50.00002... -> '50.0'.  The humanized absolute stays compact.
      assert_include node_line, 'prompt=2M cache=1M@50.0%', node_line
      assert_include footer, 'cache=1M@50.0%', footer

      # fresh is footer-only, raw pt - cct, humanized.
      assert_include footer, 'fresh=1M', footer
      assert_not_include node_line, 'fresh=', 'fresh must not appear on node lines'

      # Canonical field order on both lines.
      assert_match(/chat evidence=2M prompt=2M cache=1M@50\.0% cont=2 round\.chat/,
                   node_line, out)
      assert_match(/\Aroot deduplicated_total=2M \(2 events\) prompt=2M cache=1M@50\.0% fresh=1M cont=2 /,
                   footer, out)

      # The pt=0 event contributes tt and ct but no prompt-axis field.
      assert_include footer, 'cont=2', footer

      # cache_write= only when cwt>0: absent here.
      assert_not_include out, 'cache_write=', out

      # The case2 shape (tmp/prov-rework/case2): pt=20M cct=19M -> 95.0%.
      case2 = write_chat(dir, 'case2.chat',
                         "user: hi\n" +
                         "meta: pt=20000000 ct=800 tt=20000800 cct=19000000 rt=600 " \
                         "inference_id=c2 timestamp=2026-09-04T00:00:00Z\n" +
                         "assistant: ok\n")
      out3, _err3, status3 = prov(case2)
      assert status3.success?
      assert_include out3, 'prompt=20M cache=19M@95.0% cont=800 reason=600', out3
      footer2 = out3.lines.find { |line| line.start_with?('root') }
      assert_include footer2, 'cache=19M@95.0% fresh=1M', footer2
    end
  end

  # 2: fresh includes the cache-write portion (cwt is not subtracted from pt).
  # 3: cache_write= prints only when cwt>0.
  def test_footer_fresh_includes_cache_write_and_cache_write_gated
    TmpFile.with_dir do |dir|
      _a, _b, _c, _tsv, _parent = continuation_chain(dir)
      out, _err, status = prov(_a)
      assert status.success?

      footer = out.lines.find { |line| line.start_with?('root') }
      assert footer, out
      # A's own metas: pt=120, cct=90, cwt=15 -> fresh=120-90=30, cache_write=15.
      assert_include footer, 'prompt=120 cache=90@75.0% fresh=30 cache_write=15', footer

      # Node lines never carry fresh= or cache_write=.
      node = out.lines.find { |line| line =~ /\A job\b/ }
      assert node, out
      assert_not_include node, 'fresh=', node
      assert_not_include node, 'cache_write=', node
    end
  end

  # 4: -c direct= values come from the node's own log sums (cumulative ask
  # shape: the continuation job's direct log carries the projected parent
  # metas inlined, so direct= still equals its full recorded log).
  def test_component_direct_values_from_local_log_sums
    TmpFile.with_dir do |dir|
      a, b, c, _tsv, _parent = continuation_chain(dir)

      out, _err, status = prov('--component', a)
      assert status.success?
      line_a = out.lines.find { |line| line =~ /\A job\b/ }
      assert_include line_a, 'direct=150', line_a
      assert_not_include line_a, 'evidence=', line_a

      out, _err, status = prov('--component', b)
      assert status.success?
      line_b = out.lines.find { |line| line =~ /\A job\b/ }
      assert_include line_b, 'direct=390', 'B log = 3 parent metas + 2 own, each tt=50 or 120'

      out, _err, status = prov('--component', c)
      assert status.success?
      line_c = out.lines.find { |line| line =~ /\A job\b/ }
      assert_include line_c, 'direct=990', 'C log = cumulative history, 6 events'
    end
  end

  # 5 + 11: delta= on job nodes in BOTH modes; absent on chat nodes and for
  # non-chat results.
  def test_delta_visibility_in_both_modes_and_omissions
    TmpFile.with_dir do |dir|
      a, b, c, tsv, parent = continuation_chain(dir)

      ['', '-c'].each do |mode|
        out, _err, status = prov(*(mode.empty? ? [c] : ['--component', c]))
        assert status.success?, mode
        job_c = out.lines.find { |line| line =~ /Default_c3/ && line =~ /\A job\b/ }
        job_b = out.lines.find { |line| line =~ /Default_b2/ && line =~ /\A\s*job\b/ }
        assert_include job_c, 'delta=600', job_c
        assert_include job_b, 'delta=240', job_b

        # The TSV-typed job (receipt child of parent.chat) omits delta=, and
        # the plain chat node never carries it.
        out2, _err2, status2 = prov(*(mode.empty? ? [parent] : ['--component', parent]))
        assert status2.success?, mode
        chat_line = out2.lines.find { |line| line.include?('parent.chat') }
        assert_not_include chat_line, 'delta=', chat_line
        tsv_line = out2.lines.find { |line| line =~ /Default_d4/ }
        assert tsv_line, out2
        assert_not_include tsv_line, 'delta=', 'non-chat result must omit delta=, not print delta=0'
      end
    end
  end

  # 6: footer equals the collector deduplicated scope; footer present in -c
  # without receipts (covered by plain.chat in test_component_mode...).
  def test_footer_equals_collector_deduplicated_total_on_chain
    TmpFile.with_dir do |dir|
      _a, _b, c, _tsv, parent = continuation_chain(dir)
      [c, parent].each do |root|
        expected = Chat.provenance_token_totals(root)
        out, _err, status = prov(root)
        assert status.success?
        assert_match(/root deduplicated_total=#{expected[:tt]} /, out)
        # Cross-consumer: the per-node root line also carries the closure.
        root_line = out.lines.find { |line| line =~ /\A (job|chat)\b/ }
        assert_include root_line, "evidence=#{expected[:tt]}", root_line
        assert_equal expected, Chat.tokens(root)
      end
    end
  end

  # 9: continuation chain additivity: sum of per-job deltas equals the root
  # footer deduplicated_total; ancestor evidence= closures are cumulative.
  def test_chain_deltas_sum_to_footer_and_closures_cumulative
    TmpFile.with_dir do |dir|
      _a, _b, c, _tsv, _parent = continuation_chain(dir)

      out, _err, status = prov(c)
      assert status.success?

      # Cumulative closures down the chain: A 150 < B 390 < C 990.
      assert_match(/job evidence=150 .*Default_a1/, out)
      assert_match(/job evidence=390 .*Default_b2/, out)
      assert_match(/job evidence=990 .*Default_c3/, out)

      # Deltas are disjoint and sum to the footer: 150 + 240 + 600 = 990.
      deltas = out.lines.select { |line| line =~ /job\b/ && line =~ /evidence=/ }
                   .collect { |line| line[/delta=(\d+)/, 1].to_i }
      # Tree order is root-first: C, B, A.
      assert_equal [600, 240, 150], deltas, out
      assert_equal deltas.sum, 990
      assert_match(/root deduplicated_total=990 \(6 events\)/, out)

      # Same additivity holds in -c mode.
      out_c, _err_c, status_c = prov('--component', c)
      assert status_c.success?
      deltas_c = out_c.lines.select { |line| line =~ /job\b/ && line =~ /direct=/ }
                       .collect { |line| line[/delta=(\d+)/, 1].to_i }
      assert_equal deltas, deltas_c
      assert_match(/root deduplicated_total=990 /, out_c)
    end
  end

  # 10: zero/missing cache and pt=0 omission (no exception, no prompt axis).
  def test_zero_cache_and_missing_prompt_axis
    TmpFile.with_dir do |dir|
      _a, _b, _c, _tsv, parent = continuation_chain(dir)

      # cct=0 with pt>0: cache=0@0.0% and footer fresh=<pt>.
      out, _err, status = prov(parent)
      assert status.success?
      footer = out.lines.find { |line| line.start_with?('root') }
      assert footer, out
      assert_include footer, 'prompt=17 cache=0@0.0% fresh=17', footer

      # pt=0 everywhere: the whole prompt axis disappears, tt still prints.
      zero = write_chat(dir, 'zero.chat',
                        "user: hi\nmeta: pt=0 ct=1 tt=500 inference_id=z1 timestamp=2026-09-04T00:00:00Z\nassistant: ok\n")
      out2, _err2, status2 = prov(zero)
      assert status2.success?, 'pt=0 must not raise'
      assert_include out2, 'chat evidence=500 cont=1 zero.chat', out2
      assert_match(/root deduplicated_total=500 \(1 events\) cont=1 /, out2)
      %w[prompt= cache= fresh= cache_write= @].each do |token|
        assert_not_include out2, token, "pt=0 must omit the whole prompt axis: #{token}"
      end
    end
  end

  # 12: identity conflicts produce the footer caveat in both modes; no
  # conflicts means no caveat line.
  def test_conflict_caveat_lives_in_footer_in_both_modes
    TmpFile.with_dir do |dir|
      # Same inference_id recorded with two different tt: a conflict.
      conflicting = write_chat(dir, 'conflict.chat',
                               "user: hi\n" +
                               "meta: pt=10 ct=1 tt=11 inference_id=k1 timestamp=2026-09-04T00:00:00Z provider_response_id=p1\n" +
                               "meta: pt=10 ct=1 tt=99 inference_id=k1 timestamp=2026-09-04T00:00:00Z provider_response_id=p1\n" +
                               "assistant: ok\n")

      ['', '-c'].each do |mode|
        out, _err, status = prov(*(mode.empty? ? [conflicting] : ['--component', conflicting]))
        assert status.success?, mode
        caveat = out.lines.count { |line| line.include?('not exact') }
        assert_equal 1, caveat, "caveat must come from the footer once: #{mode}\n#{out}"
        assert_include out, 'unresolved identity conflicts', out
      end

      # No conflicts: no caveat line at all.
      clean = write_chat(dir, 'clean.chat',
                         "user: hi\nmeta: pt=10 ct=1 tt=11 inference_id=q1 timestamp=2026-09-04T00:00:00Z\nassistant: ok\n")
      out, _err, status = prov(clean)
      assert status.success?
      assert_not_include out, 'not exact', out
    end
  end

  # 8: saved+receipt dedup: the merged event is counted once in the scope
  # block and the footer equals the collector total.
  def test_saved_and_receipt_dedup_scope_and_footer
    TmpFile.with_dir do |dir|
      parent, _worker = fixture_b(dir)
      expected = Chat.provenance_token_totals(parent)

      out, _err, status = prov('--component', parent)
      assert status.success?

      # w1/w2 are stored in the worker log AND in the parent receipt: chat
      # and receipt scopes both cover them, deduplicated_total counts once.
      assert_match(/evidence chat_evidence: total=#{expected[:tt]}/, out)
      assert_match(/evidence receipt_evidence: total=180/, out)
      assert_match(/evidence receipt_only: total=0/, out)
      assert_match(/root deduplicated_total=#{expected[:tt]} /, out)

      # Scope block is exactly 3 lines now.
      scope_lines = out.lines.count { |line| line =~ /^\s*evidence \w+:/ }
      assert_equal 3, scope_lines, out
    end
  end

end
