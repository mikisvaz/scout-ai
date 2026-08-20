require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'tmpdir'
require 'json'
require_relative 'agent_meta_fixtures'

# Token accounting for agent_meta receipts (plan delivery step 3): the
# provenance-aware event collector.  Fixtures A, B, D, F, G and H from the
# design record; traversal structure itself is covered by
# test_agent_meta_provenance.rb.
class TestChatAgentMetaTokens < Test::Unit::TestCase
  include AgentMetaFixtures

  ## Fixture A - receipt-only delegation

  def test_receipt_only_events_are_counted_once
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                      meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')]},
                            extra: ['meta: pt=60 ct=40 tt=100 inference_id=p1']
                          ))

      events = Chat.provenance_token_events(parent)

      # Both worker events plus the parent's own direct event.
      assert_equal %w[p1 w1 w2], events.collect { |event| event[:inference_id] }.sort

      worker = events.select { |event| %w[w1 w2].include?(event[:inference_id]) }
      assert_equal [20, 100], worker.collect { |event| event[:tokens][:pt] }.sort
      assert worker.all? { |event| event[:deduplication] == :inference_id }
      assert worker.all? { |event| !event[:conflict] }
    end
  end

  def test_receipt_only_evidence_addresses_and_call_ids
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                      meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')]}
                          ))

      evidence = Chat.provenance_token_events(parent)
                     .sort_by { |event| event[:inference_id] }
                     .collect { |event| event[:evidence].first }

      assert_equal [parent, 3, :agent_meta, 0], evidence.first[:evidence_address]
      assert_equal [parent, 3, :agent_meta, 1], evidence.last[:evidence_address]
      assert_equal %w[a1 a1], evidence.collect { |record| record[:call_id] }
      assert_equal %w[ask ask], evidence.collect { |record| record[:tool_name] }
      assert_equal parent, evidence.first[:source]
      assert_equal :agent_meta, evidence.first[:origin]
    end
  end

  def test_receipt_only_scopes_and_follow_option
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                      meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')]},
                            extra: ['meta: pt=60 ct=40 tt=100 inference_id=p1']
                          ))

      aggregate = Chat.provenance_token_totals(parent)
      assert_equal({pt: 180, ct: 100, tt: 280, cct: 0, cwt: 0, rt: 0}, aggregate)

      # Receipt events are not local, but they are receipt evidence.
      local = Chat.provenance_token_totals(parent, scope: :chat_evidence)
      assert_equal({pt: 60, ct: 40, tt: 100, cct: 0, cwt: 0, rt: 0}, local)

      receipt = Chat.provenance_token_totals(parent, scope: :receipt_evidence)
      assert_equal({pt: 120, ct: 60, tt: 180, cct: 0, cwt: 0, rt: 0}, receipt)

      # Totals keep working with a restricted traversal (no jobs to follow).
      assert_equal aggregate, Chat.provenance_token_totals(parent, follow: [:job])

      # Chat.tokens now uses the collector.
      assert_equal aggregate, Chat.tokens(parent)
    end
  end

  ## Fixture B - receipt plus saved worker log

  def test_receipt_and_log_evidence_merge_into_one_event
    Dir.mktmpdir do |dir|
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

      events = Chat.provenance_token_events(parent)
      assert_equal 4, events.length

      merged = events.select { |event| %w[w1 w2].include?(event[:inference_id] )}.sort_by { |event| event[:inference_id] }
      merged.each do |event|
        assert_equal 2, event[:evidence].length
        origins = event[:evidence].collect { |record| record[:origin] }
        assert_include origins, :chat_meta
        assert_include origins, :agent_meta

        chat_side = event[:evidence].find { |record| record[:origin] == :chat_meta }
        receipt_side = event[:evidence].find { |record| record[:origin] == :agent_meta }
        assert_equal File.join(worker + '.files', 'log', 'agent.chat'), chat_side[:source]
        assert_equal [parent, 3, :agent_meta, event[:inference_id] == 'w1' ? 0 : 1],
                     receipt_side[:evidence_address]
        assert !event[:conflict]
      end

      # Aggregate is fixture A plus the worker-only event, never doubled.
      assert_equal({pt: 185, ct: 105, tt: 290, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))

      # Totals equal the sum over events.
      summed = events.each_with_object(Hash.new(0)) do |event, hash|
        event[:tokens].each { |key, value| hash[key] += value }
      end
      assert_equal Chat.provenance_token_totals(parent), summed

      assert_equal Chat.provenance_token_totals(parent), Chat.tokens(parent)
    end
  end

  def test_scope_selection_with_shared_evidence
    Dir.mktmpdir do |dir|
      worker_log = "user: work\n" +
                   "meta: pt=100 ct=50 tt=150 inference_id=w1\n" +
                   "meta: pt=5 ct=5 tt=10 inference_id=w3\n" +
                   "assistant: done\n"
      worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})

      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1')]},
                            extra: ['meta: pt=60 ct=40 tt=100 inference_id=p1',
                                    "meta: job=#{worker}"]
                          ))

      events = Chat.provenance_token_events(parent)
      shared = events.select { |event| event[:evidence].any? { |r| r[:origin] == :chat_meta } &&
                                       event[:evidence].any? { |r| r[:origin] == :agent_meta } }
      assert_equal ['w1'], shared.collect { |event| event[:inference_id] }

      # local and receipt both include the shared event; aggregate counts it once.
      local = Chat.provenance_token_totals(parent, scope: :chat_evidence)
      receipt = Chat.provenance_token_totals(parent, scope: :receipt_evidence)
      aggregate = Chat.provenance_token_totals(parent)
      shared_tokens = shared.first[:tokens]

      local_events = events.select { |event| event[:evidence].any? { |r| r[:origin] == :chat_meta } }
      receipt_events = events.select { |event| event[:evidence].any? { |r| r[:origin] == :agent_meta } }
      assert_equal local_events.length + receipt_events.length - shared.length, events.length

      summed = shared_tokens.each_with_object(Hash.new(0)) { |(k, v), h| h[k] = local[k] + receipt[k] - v }
      assert_equal aggregate, summed
    end
  end

  ## Fixture D - aggregate over the nested chain

  def test_fixture_d_every_direct_event_counted_once
    Dir.mktmpdir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      events = Chat.provenance_token_events(parent)

      # w1, w2 (worker log), c1 (critic receipt inside the worker log),
      # shadow (parent receipt); the two job= projections count for nothing.
      assert_equal %w[c1 shadow w1 w2], events.collect { |event| event[:inference_id] }.sort
      assert_empty events.select { |event| event[:meta][:job] }

      # By hand: parent receipt shadow (10/0/12) + worker log w1 (100/50/150)
      # + w2 (20/10/30) + critic receipt c1 (30/10/40).
      assert_equal({pt: 160, ct: 70, tt: 232, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))
    end
  end

  ## Fixture F - identity conflicts

  def test_conflicting_token_fields_count_only_canonical_evidence
    Dir.mktmpdir do |dir|
      log = "user: work\nmeta: pt=10 ct=5 tt=99 inference_id=f1\nassistant: done\n"
      worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => log})

      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=10 ct=5 tt=15 inference_id=f1')]},
                            extra: ["meta: job=#{worker}"]
                          ))

      warnings = []
      events = Chat.provenance_token_events(parent, warnings: warnings)

      assert_equal 1, events.length
      event = events.first
      assert event[:conflict]

      # Canonical is the chat side; tokens are neither the sum nor the receipt.
      assert_equal 99, event[:tokens][:tt]
      assert_equal({pt: 10, ct: 5, tt: 99, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))

      # Both evidence records survive, each with its own meta.
      assert_equal 2, event[:evidence].length
      assert_equal 99, event[:evidence].find { |r| r[:origin] == :chat_meta }[:meta][:tt].to_i
      assert_equal 15, event[:evidence].find { |r| r[:origin] == :agent_meta }[:meta][:tt].to_i

      assert_equal 1, warnings.length
      warning = warnings.first
      assert_equal :identity_conflict, warning[:reason]
      assert_equal 'f1', warning[:inference_id]
      assert_equal [:inference_id, 'f1'], warning[:identity]
      assert_equal [:tt], warning[:fields]
      assert_equal [99, 15], warning[:values][:tt].collect(&:to_i)
      assert_equal 2, warning[:evidence].length
    end
  end

  def test_provider_response_id_disagreement_is_a_conflict
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'p2.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=1 tt=2 inference_id=g1 provider_response_id=ra'),
                                      meta_receipt('pt=1 tt=2 inference_id=g1 provider_response_id=rb')]}
                          ))

      warnings = []
      events = Chat.provenance_token_events(parent, warnings: warnings)

      assert_equal 1, events.length
      assert events.first[:conflict]
      assert_equal 2, events.first[:evidence].length
      assert_equal 1, warnings.length
      assert_equal [:provider_response_id], warnings.first[:fields]
      assert_equal %w[ra rb], warnings.first[:values][:provider_response_id]
    end
  end

  def test_provider_response_id_groups_receipt_and_log_without_inference_id
    Dir.mktmpdir do |dir|
      worker = make_job(dir, 'W3/ask/Default_3',
                        logs: {'agent.chat' => "user: w\nmeta: pt=1 tt=2 provider_response_id=rx\nassistant: done\n"})
      parent = write_chat(dir, 'p4.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=1 tt=2 provider_response_id=rx')]},
                            extra: ["meta: job=#{worker}"]
                          ))

      events = Chat.provenance_token_events(parent)

      assert_equal 1, events.length
      assert_equal :provider_response_id, events.first[:deduplication]
      assert_equal [:provider_response_id, 'rx'], events.first[:identity]
      assert_equal 2, events.first[:evidence].length
      assert_equal({pt: 1, ct: 0, tt: 2, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))
    end
  end

  def test_conflicts_do_not_raise_without_a_warnings_array
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'p2.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=1 tt=2 inference_id=g1'),
                                      meta_receipt('pt=1 tt=9 inference_id=g1')]}
                          ))

      events = Chat.provenance_token_events(parent)
      assert_equal 1, events.length
      assert events.first[:conflict]
      assert_equal 2, events.first[:evidence].length
    end
  end

  ## Fixture G - legacy records without inference_id

  def test_legacy_chat_metas_keep_lineage_dedup
    Dir.mktmpdir do |dir|
      legacy = "user: w\nmeta: pt=7 ct=3 tt=10\nassistant: done\n"
      j1 = make_job(dir, 'J1/ask/Default_1', logs: {'agent.chat' => legacy})
      j2 = make_job(dir, 'J2/ask/Default_2', logs: {'agent.chat' => legacy})
      copied = write_chat(dir, 'copied.chat',
                          "user: go\nmeta: job=#{j1}\nmeta: job=#{j2}\nassistant: done\n")

      events = Chat.provenance_token_events(copied)

      assert_equal 1, events.length
      assert_equal :legacy_lineage, events.first[:deduplication]
      assert_equal [:lineage, events.first[:identity][1]], events.first[:identity]
      assert_equal({pt: 7, ct: 3, tt: 10, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(copied))
    end
  end

  def test_legacy_receipt_metas_are_never_merged
    Dir.mktmpdir do |dir|
      twice = write_chat(dir, 'twice.chat',
                         receipt_chat_text(
                           {'r1' => [meta_receipt('pt=5 tt=6')],
                            'r2' => [meta_receipt('pt=5 tt=6')]}
                         ))

      events = Chat.provenance_token_events(twice)

      # No exact rule exists for legacy receipts: identical content stays two
      # events (documented possible overcount).
      assert_equal 2, events.length
      assert events.all? { |event| event[:deduplication] == :receipt_unresolved }
      assert_equal 2, events.collect { |event| event[:identity] }.uniq.length
      assert_equal({pt: 10, ct: 0, tt: 12, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(twice))
    end
  end

  def test_legacy_receipt_and_log_stay_two_events
    Dir.mktmpdir do |dir|
      worker = make_job(dir, 'LG/ask/Default_1',
                        logs: {'agent.chat' => "user: w\nmeta: pt=8 tt=9\nassistant: done\n"})
      mixed = write_chat(dir, 'mixed.chat',
                         receipt_chat_text(
                           {'r1' => [meta_receipt('pt=8 tt=9')]},
                           extra: ["meta: job=#{worker}"]
                         ))

      events = Chat.provenance_token_events(mixed)

      assert_equal 2, events.length
      assert_equal 1, events.count { |event| event[:deduplication] == :legacy_lineage }
      assert_equal 1, events.count { |event| event[:deduplication] == :receipt_unresolved }
      # Documented overcount for legacy data.
      assert_equal({pt: 16, ct: 0, tt: 18, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(mixed))
    end
  end

  def test_chat_without_agent_meta_keeps_token_totals_semantics
    Dir.mktmpdir do |dir|
      path = write_chat(dir, 'plain.chat',
                        "user: hi\nmeta: pt=1 tt=2\nmeta: pt=3 tt=4\nassistant: done\n")

      assert_equal Chat.token_totals([Chat.load(path)]),
                   Chat.provenance_token_totals(path)
      assert_equal Chat.token_totals([Chat.load(path)]), Chat.tokens(path)
    end
  end

  ## Fixture H - truncated parent output

  def test_truncated_output_keeps_receipt_events
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'parent.chat',
                          truncated_receipt_chat(
                            'a1', [meta_receipt('pt=200 ct=100 tt=300 inference_id=t1')]
                          ))

      warnings = []
      events = Chat.provenance_token_events(parent, warnings: warnings)

      assert_equal ['t1'], events.collect { |event| event[:inference_id] }
      assert_equal({pt: 200, ct: 100, tt: 300, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))

      # Truncation is a transport fact, not a token problem.
      assert_empty warnings
      status = Chat.tool_call_status(Chat.tool_calls(Chat.load(parent)).first)
      assert_equal false, status[:success]
      assert_match(/90,?000 characters/, status[:exception])

      totals = Chat.provenance_token_totals(parent)
      assert_equal 0, totals.values.select { |v| v > 300 }.length
    end
  end

  ## Canonical rule

  def test_canonical_evidence_prefers_chat_side_then_discovery_order
    Dir.mktmpdir do |dir|
      worker = make_job(dir, 'W/ask/Default_w',
                        logs: {'agent.chat' => "user: w\nmeta: pt=11 ct=7 tt=18 inference_id=k1\nassistant: done\n"})
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=22 ct=14 tt=36 inference_id=k1')]},
                            extra: ["meta: job=#{worker}"]
                          ))

      event = Chat.provenance_token_events(parent).first

      # Chat side wins over the receipt.
      assert_equal :chat_meta, event[:evidence].first[:origin]
      assert_equal 11, event[:meta][:pt].to_i
      assert_equal({pt: 11, ct: 7, tt: 18, cct: 0, cwt: 0, rt: 0}, event[:tokens])

      # Within one origin, discovery order decides (first receipt of two).
      other = write_chat(dir, 'two.chat',
                         receipt_chat_text(
                           {'a1' => [meta_receipt('pt=1 tt=2 inference_id=d1'),
                                     meta_receipt('pt=1 tt=2 inference_id=d1')]}
                         ))
      assert_equal 1, Chat.provenance_token_events(other).length
      assert_equal 1, Chat.provenance_token_totals(other)[:pt]
    end
  end

  ## Traversal-stage receipt problems vs the warnings Array

  def test_traversal_stage_receipt_problems_go_to_the_warnings_array
    Dir.mktmpdir do |dir|
      missing = File.join(dir, 'Missing/ask/Default_zzz')
      chat = write_chat(dir, 'bad.chat',
                        receipt_chat_text(
                          {'b1' => 'not-an-array',
                           'b2' => [meta_receipt("job=#{missing}")]},
                          extra: ['meta: pt=5 tt=6 inference_id=ok1']
                        ))

      warnings = []
      events = Chat.provenance_token_events(chat, warnings: warnings)

      # The good direct event still comes through; nothing raised.
      assert_equal ['ok1'], events.collect { |event| event[:inference_id] }

      # Totals use their own buffer (each API call reports its own warnings).
      totals_warnings = []
      assert_equal({pt: 5, ct: 0, tt: 6, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(chat, warnings: totals_warnings))
      assert_equal warnings.collect { |w| w[:reason] }, totals_warnings.collect { |w| w[:reason] }

      # One warning per problem, in the agent_meta_error_reference shape plus
      # the error message; the same problem is not reported twice.
      reasons = warnings.collect { |warning| warning[:reason] }
      assert_equal %i[not_an_array unresolved_job_reference], reasons
      not_an_array = warnings.first
      assert_equal chat, not_an_array[:source]
      assert_equal [chat, 3], not_an_array[:output_address]
      assert_equal 'b1', not_an_array[:call_id]
      assert_equal 'ask', not_an_array[:tool_name]
      assert_nil not_an_array[:evidence_address]
      assert_match(/not_an_array/, not_an_array[:message])

      unresolved = warnings.last
      assert_equal missing, unresolved[:reference]
      assert_equal [chat, 5, :agent_meta, 0], unresolved[:evidence_address]
      assert_equal 'b2', unresolved[:call_id]
      assert_match(/unresolved_job_reference/, unresolved[:message])
    end
  end

  def test_traversal_stage_receipt_problems_raise_without_warnings_array
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'bad.chat',
                        receipt_chat_text({'b1' => 'not-an-array'},
                                          extra: ['meta: pt=5 tt=6 inference_id=ok1']))

      error = assert_raise(ScoutException) do
        Chat.provenance_token_events(chat)
      end
      assert_match(/not_an_array/, error.message)
      assert_match(/#{Regexp.escape(chat)}/, error.message)
    end
  end

  ## Reviewer cases: multi-location evidence, shared-job receipts, strict mode

  # The same inference_id persisted in three ordinary chat/log locations plus
  # one receipt must produce ONE event whose evidence array keeps all four
  # addresses, counted once.
  def test_same_identity_in_three_chat_locations_and_one_receipt
    Dir.mktmpdir do |dir|
      shared = 'meta: pt=100 ct=40 tt=140 inference_id=shared1'
      j1 = make_job(dir, 'J1/ask/Default_1', logs: {'agent.chat' => "user: w\n#{shared}\nassistant: done\n"})
      j2 = make_job(dir, 'J2/ask/Default_2', logs: {'agent.chat' => "user: w\n#{shared}\nassistant: done\n"})
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=100 ct=40 tt=140 inference_id=shared1')]},
                            extra: [shared, "meta: job=#{j1}", "meta: job=#{j2}"]
                          ))

      events = Chat.provenance_token_events(parent).select { |event| event[:inference_id] == 'shared1' }

      assert_equal 1, events.length
      event = events.first
      assert_equal 4, event[:evidence].length

      chat_side = event[:evidence].select { |record| record[:origin] == :chat_meta }
      assert_equal 3, chat_side.length
      expected_sources = [parent,
                          File.join(j1 + '.files', 'log', 'agent.chat'),
                          File.join(j2 + '.files', 'log', 'agent.chat')].collect(&:to_s).sort
      assert_equal expected_sources, chat_side.collect { |record| record[:source].to_s }.sort

      receipt_side = event[:evidence].select { |record| record[:origin] == :agent_meta }
      assert_equal 1, receipt_side.length
      assert_equal 'a1', receipt_side.first[:call_id]
      assert !event[:conflict]

      # Counted exactly once.
      assert_equal({pt: 100, ct: 40, tt: 140, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))
    end
  end

  # Two separate ask receipts pointing at the same job= keep both edge details
  # (distinct call ids and receipt addresses) while the Step is visited once.
  def test_two_receipts_to_the_same_job_keep_both_edge_details
    Dir.mktmpdir do |dir|
      worker = make_job(dir, 'Worker/ask/Default_w',
                        logs: {'agent.chat' => "user: w\nmeta: pt=1 tt=2 inference_id=wonly\nassistant: done\n"})
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt("job=#{worker}")],
                             'a2' => [meta_receipt("job=#{worker}")]}
                          ))

      edges = Chat.provenance_edges(parent).select { |edge| edge[:relation] == :agent_job }
      assert_equal 2, edges.length
      details = edges.collect { |edge| edge[:detail] }
      assert_equal %w[a1 a2], details.collect { |detail| detail[:call_id] }.sort
      assert_equal 2, details.collect { |detail| detail[:evidence_address] }.uniq.length
      assert(edges.all? { |edge| edge[:to].path.to_s == worker.to_s })
      assert(edges.all? { |edge| edge[:from].to_s == parent.to_s })

      # One unique Step node; each edge visits it, only the first expands it.
      assert_equal 1, Chat.provenance_jobs(parent).length
      job_visits = Chat.traverse_provenance(parent).to_a
                       .select { |kind, object, *_rest| kind == :job && object.path.to_s == worker.to_s }
      assert_equal 2, job_visits.length
      assert_equal 1, job_visits.count { |visit| visit[5] }
    end
  end

  def test_strict_mode_raises_on_identity_conflict
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'p5.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=1 tt=2 inference_id=g1'),
                                      meta_receipt('pt=1 tt=9 inference_id=g1')]}
                          ))

      assert_raise(ScoutException) do
        Chat.provenance_token_events(parent, strict: true)
      end
    end
  end

  # A provider_response_id present in one copy and absent in another is
  # incomplete evidence (migration), never a conflict.
  def test_missing_provider_response_id_is_incomplete_not_conflict
    Dir.mktmpdir do |dir|
      worker = make_job(dir, 'W4/ask/Default_4',
                        logs: {'agent.chat' => "user: w\nmeta: pt=3 tt=4 inference_id=h1 provider_response_id=rq\nassistant: done\n"})
      parent = write_chat(dir, 'p6.chat',
                          receipt_chat_text(
                            {'a1' => [meta_receipt('pt=3 tt=4 inference_id=h1')]},
                            extra: ["meta: job=#{worker}"]
                          ))

      warnings = []
      events = Chat.provenance_token_events(parent, warnings: warnings)

      event = events.find { |item| item[:inference_id] == 'h1' }
      assert event
      assert_equal 2, event[:evidence].length
      assert event[:incomplete_evidence]
      assert !event[:conflict]
      assert_empty warnings.select { |warning| warning[:reason] == :identity_conflict }
      assert_equal({pt: 3, ct: 0, tt: 4, cct: 0, cwt: 0, rt: 0},
                   Chat.provenance_token_totals(parent))
    end
  end

  ## Scope validation

  def test_unknown_scope_raises
    Dir.mktmpdir do |dir|
      path = write_chat(dir, 'any.chat', "user: hi\nassistant: done\n")

      assert_raise(ParameterException) do
        Chat.provenance_token_totals(path, scope: :bogus)
      end
    end
  end
end
