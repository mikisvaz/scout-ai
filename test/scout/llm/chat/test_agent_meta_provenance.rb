require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'tmpdir'
require_relative 'agent_meta_fixtures'

# Structure-level tests for the :agent_job provenance relation (plan fixtures
# C, D and the structure part of E).  Token accounting for receipts lives in
# test_agent_meta_tokens.rb; both suites share AgentMetaFixtures#fixture_c.
class TestChatAgentMetaProvenance < Test::Unit::TestCase
  include AgentMetaFixtures

  ## Fixture C

  def test_agent_job_edge_links_receipt_job_to_enclosing_chat
    Dir.mktmpdir do |dir|
      parent, worker, _critic, _dep = fixture_c(dir)

      errors = []
      visits = Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
      signature = visit_signature(visits)

      # The delegated producer is a normal :job node whose parent is the parent
      # chat, discovered through the new relation.
      edge = signature.find { |_kind, path, relation, _first| relation == :agent_job && path == worker }
      assert edge, "no :agent_job edge to the worker job in #{signature.inspect}"
      assert_equal :job, edge[0]

      enclosing = visits.find do |kind, object, _pk, _p, _rel, _first|
        kind == :job && object.path.to_s == worker
      end
      assert enclosing, 'worker job not visited'
      assert_equal :chat, enclosing[2]
      assert_equal parent, enclosing[3].to_s

      # The worker log chat is reached through the ordinary :log relation and
      # the worker dependency through :dependency.
      worker_log = File.join(worker + '.files', 'log', 'agent.chat')
      assert signature.any? { |kind, path, relation, _first| kind == :chat && path == worker_log && relation == :log }
      assert signature.any? { |_kind, path, relation, _first| relation == :dependency && path.end_with?('Dep/load/Default_1') }

      # No receipt-only node kind exists: chats are still only the parent and
      # the worker log.
      assert_equal 2, signature.count { |kind, _path, _relation, _first| kind == :chat }
    end
  end

  def test_follow_job_excludes_the_agent_job_edge
    Dir.mktmpdir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      signature = visit_signature(Chat.traverse_provenance(parent, follow: [:job]).to_a)

      assert_empty signature.select { |_kind, _path, relation, _first| relation == :agent_job }
      # The ordinary meta job= reference still resolves under follow: [:job].
      assert signature.any? { |_kind, path, relation, _first| relation == :job && path.end_with?('Critic/ask/Default_c') }
      assert_equal 2, signature.length
    end
  end

  def test_follow_agent_job_includes_only_the_agent_job_edge
    Dir.mktmpdir do |dir|
      parent, worker, _critic, _dep = fixture_c(dir)

      signature = visit_signature(Chat.traverse_provenance(parent, follow: [:agent_job]).to_a)

      delegated = signature.select { |_kind, _path, relation, _first| relation == :agent_job }
      assert_equal 1, delegated.length
      assert_equal worker, delegated.first[1]

      # Nothing else expands: no ordinary :job edge, no logs, no dependencies.
      # (The root chat itself carries a nil relation.)
      assert_empty signature.select { |_kind, _path, relation, _first| relation && relation != :agent_job }
      assert_equal 2, signature.length
    end
  end

  def test_chat_without_agent_meta_traverses_as_before
    Dir.mktmpdir do |dir|
      critic = make_job(dir, 'Critic/ask/Default_c')
      plain = write_chat(dir, 'plain.chat', plain_delegation_chat(critic))

      errors = []
      signature = visit_signature(
        Chat.traverse_provenance(plain, on_error: ->(*args) { errors << args }).to_a
      )

      assert_empty errors
      assert_empty signature.select { |_kind, _path, relation, _first| relation == :agent_job }
      assert signature.any? { |_kind, path, relation, _first| relation == :job && path == critic }
      assert_equal 2, signature.length
    end
  end

  ## Fixture D (structure)

  def test_nested_receipt_chain_terminates_with_both_delegation_edges
    Dir.mktmpdir do |dir|
      parent, worker, critic, _dep = fixture_c(dir)

      errors = []
      visits = Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
      signature = visit_signature(visits)

      delegated = signature.select { |_kind, _path, relation, _first| relation == :agent_job }
      # Parent chat -> Worker and worker log chat -> Critic; the Critic edge is
      # still yielded as a structural edge even though Critic was already
      # visited through the ordinary :job relation.
      assert_equal 2, delegated.length
      assert delegated.any? { |_kind, path, _first| path == worker }
      assert delegated.any? { |_kind, path, _first| path == critic }

      worker_log = File.join(worker + '.files', 'log', 'agent.chat')
      nested = visits.find do |kind, object, _pk, p, rel, _first|
        kind == :job && object.path.to_s == critic && rel == :agent_job && p.to_s == worker_log
      end
      assert nested, 'no :agent_job edge from the worker log chat to the Critic job'

      # Each node expands exactly once.
      first_visits = signature.count { |_kind, _path, _relation, first| first }
      assert_equal signature.uniq { |kind, path, _rel, _first| [kind, path] }.length, first_visits
    end
  end

  def test_deliberate_receipt_cycle_does_not_hang
    Dir.mktmpdir do |dir|
      parent, worker, critic, _dep = fixture_c(dir)

      # Self reference plus a reference back to the already-visited Worker:
      # both must terminate through the seen set instead of looping.
      cyclic_log = receipt_chat_text(
        {'c1' => [meta_receipt('pt=1 tt=2 inference_id=loop'),
                  meta_receipt("job=#{critic}"),
                  meta_receipt("job=#{worker}")]},
        extra: ['meta: pt=3 tt=4 inference_id=cl1']
      )
      make_job(dir, 'Critic/ask/Default_c', logs: {'agent.chat' => cyclic_log})

      errors = []
      signature = visit_signature(
        Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a
      )

      assert_empty errors
      assert signature.any? { |_kind, path, relation, _first| relation == :agent_job && path == critic }
      # The Critic job expands exactly once even though several receipt edges
      # reach it.
      expansions = signature.count do |kind, path, _relation, first|
        kind == :job && path == critic && first
      end
      assert_equal 1, expansions
    end
  end

  ## Fixture E

  def test_malformed_receipts_become_agent_job_warnings
    Dir.mktmpdir do |dir|
      # Output indexes after the doubled inline user line: b1 -> 3, b2 -> 5,
      # b3 -> 7.
      chat = write_chat(dir, 'bad.chat',
                        receipt_chat_text(
                          {'b1' => 'not-an-array',
                           'b2' => [{role: 'assistant', content: 'pt=1 tt=2'},
                                    meta_receipt('no parseable pairs at all')],
                           'b3' => [meta_receipt('also not parseable')]}
                        ))

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a

      assert_equal 4, errors.length
      reasons = errors.collect { |_error, _kind, _object, _relation, reference| reference[:reason] }
      assert_include reasons, :not_an_array
      assert_include reasons, :invalid_role
      assert_equal 2, reasons.count(:unparseable_meta)

      errors.each do |error, kind, object, relation, reference|
        assert_kind_of Chat::AgentMetaError, error
        assert_equal :chat, kind
        assert_equal chat, object.to_s
        assert_equal :agent_job, relation
        assert_equal chat, reference[:source]
        assert reference[:output_address], 'warning has no output address'
        assert reference[:call_id], 'warning has no call id'
        assert_equal 'ask', reference[:tool_name]
        assert_not_nil reference[:raw_entry]
        # The error message locates the receipt.
        assert_match(/#{Regexp.escape(chat)}/, error.message)
        assert_match(/#{reference[:call_id]}/, error.message)
        assert_match(/ask/, error.message)
      end

      # Indexed entries keep their evidence address; the whole-value failure
      # does not have one.
      not_an_array = errors.find { |_e, _k, _o, _r, ref| ref[:reason] == :not_an_array }
      assert_equal [chat, 3], not_an_array.last[:output_address]
      assert_nil not_an_array.last[:evidence_address]
      assert_nil not_an_array.last[:agent_meta_index]
      invalid_role = errors.find { |_e, _k, _o, _r, ref| ref[:reason] == :invalid_role }
      assert_equal [chat, 5, :agent_meta, 0], invalid_role.last[:evidence_address]
      assert_equal 0, invalid_role.last[:agent_meta_index]
      unparseable = errors.find { |_e, _k, _o, _r, ref| ref[:reason] == :unparseable_meta && ref[:output_address] == [chat, 5] }
      assert_equal [chat, 5, :agent_meta, 1], unparseable.last[:evidence_address]

      # Nothing malformed was silently used as provenance.
      assert_equal 1, visits.length
    end
  end

  def test_unparseable_output_mentioning_agent_meta_warns
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'broken.chat', <<TXT)
user: Run
function_call: {"name":"chat_task","arguments":{},"id":"u1"}
function_call_output: OutputException: truncated [CUT to 100] mentions agent_meta
function_call: {"name":"ask","arguments":{},"id":"u2"}
function_call_output: also not json at all
assistant: done
TXT

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a

      # Only the unparseable output mentioning agent_meta is reported; the
      # second one is unparseable too but carries no receipt marker.
      assert_equal 1, errors.length
      error, kind, object, relation, reference = errors.first
      assert_equal :unparseable_output, reference[:reason]
      assert_equal :agent_job, relation
      assert_equal :chat, kind
      assert_equal chat, object.to_s
      assert_equal chat, reference[:source]
      assert_equal [chat, 3], reference[:output_address]
      assert_equal 'u1', reference[:call_id]
      assert_equal 'chat_task', reference[:tool_name]
      assert_match(/#{Regexp.escape(chat)}/, error.message)
      assert_match(/u1/, error.message)
      assert_equal 1, visits.length
    end
  end

  def test_unresolved_job_reference_warns_and_is_not_enqueued
    Dir.mktmpdir do |dir|
      missing = File.join(dir, 'Missing/ask/Default_zzz')
      chat = write_chat(dir, 'unresolved.chat',
                        receipt_chat_text({'u1' => [meta_receipt("job=#{missing}")]},
                                          extra: ["meta: job=#{File.join(dir, 'Critic/ask/Default_c')}"]))

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a

      unresolved = errors.collect(&:last).select { |ref| ref[:reason] == :unresolved_job_reference }
      assert_equal 1, unresolved.length
      assert_equal missing, unresolved.first[:reference]
      assert_equal [chat, 3, :agent_meta, 0], unresolved.first[:evidence_address]
      assert_equal 'u1', unresolved.first[:call_id]
      assert_equal 'ask', unresolved.first[:tool_name]

      error, _kind, object, relation, _ref = errors.find { |args| args.last[:reason] == :unresolved_job_reference }
      assert_kind_of Chat::AgentMetaError, error
      assert_equal :agent_job, relation
      assert_equal chat, object.to_s
      assert_match(/#{Regexp.escape(missing)}/, error.message)
      assert_match(/#{Regexp.escape(chat)}/, error.message)

      # The missing job is never enqueued as a node.
      signature = visit_signature(visits)
      assert_empty signature.select { |_kind, path, _relation, _first| path == missing }
    end
  end

  def test_malformed_receipt_does_not_hide_other_provenance
    Dir.mktmpdir do |dir|
      ordinary = make_job(dir, 'Ordinary/ask/Default_o')
      chat = write_chat(dir, 'mixed.chat',
                        receipt_chat_text({'m1' => 'not-an-array'},
                                          extra: ["meta: job=#{ordinary}"]))

      errors = []
      signature = visit_signature(
        Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a
      )

      assert_equal 1, errors.length
      assert_equal :not_an_array, errors.first.last[:reason]

      # The ordinary meta job= reference still expands through :job.
      assert signature.any? { |_kind, path, relation, _first| path == ordinary && relation == :job }
      assert_equal 2, signature.length
    end
  end

  def test_strict_mode_raises_on_unresolved_reference
    Dir.mktmpdir do |dir|
      missing = File.join(dir, 'Missing/ask/Default_zzz')
      chat = write_chat(dir, 'strict.chat',
                        receipt_chat_text({'s1' => [meta_receipt("job=#{missing}")]}))

      error = assert_raise(Chat::AgentMetaError) do
        Chat.traverse_provenance(chat).to_a
      end
      assert_match(/unresolved_job_reference/, error.message)
      assert_match(/#{Regexp.escape(chat)}/, error.message)
      assert_match(/#{Regexp.escape(missing)}/, error.message)
    end
  end

  def test_strict_mode_raises_on_malformed_receipt
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'strict-bad.chat',
                        receipt_chat_text({'s1' => [{role: 'assistant', content: 'x'}]}))

      error = assert_raise(Chat::AgentMetaError) do
        Chat.traverse_provenance(chat).to_a
      end
      assert_match(/invalid_role/, error.message)
    end
  end

  def test_no_warnings_without_receipts
    Dir.mktmpdir do |dir|
      plain = write_chat(dir, 'plain.chat',
                         "user: hi\nmeta: pt=1 tt=2 inference_id=p1\nassistant: done\n")

      errors = []
      Chat.traverse_provenance(plain, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
    end
  end

  ## Regression

  def test_provenance_relations_include_agent_job_and_not_import
    assert_equal %i[job dependency log result agent_job], Chat::PROVENANCE_RELATIONS
    assert_not_include Chat::PROVENANCE_RELATIONS, :import
    assert_not_include Chat::PROVENANCE_RELATIONS, :continue
    assert_not_include Chat::PROVENANCE_RELATIONS, :last
  end

  def test_unknown_relation_still_raises
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'any.chat', "user: hi\nassistant: done\n")

      assert_raise(ParameterException) do
        Chat.traverse_provenance(chat, follow: [:agent_meta]).to_a
      end
    end
  end
end
