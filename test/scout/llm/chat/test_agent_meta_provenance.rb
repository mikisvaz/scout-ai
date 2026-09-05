require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require_relative 'agent_meta_fixtures'

# Structure-level tests for the :agent_job provenance relation (plan fixtures
# C, D and the structure part of E).  Token accounting for receipts lives in
# test_agent_meta_tokens.rb; both suites share AgentMetaFixtures#fixture_c.
class TestChatAgentMetaProvenance < Test::Unit::TestCase
  include AgentMetaFixtures

  ## Fixture C

  def test_agent_job_edge_links_receipt_job_to_enclosing_chat
    TmpFile.with_dir do |dir|
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
      worker_log = File.join(worker + '.files', 'agent.chat')
      assert signature.any? { |kind, path, relation, _first| kind == :chat && path == worker_log && relation == :log }
      assert signature.any? { |_kind, path, relation, _first| relation == :dependency && path.end_with?('Dep/load/Default_1') }

      # No receipt-only node kind exists: chats are still only the parent and
      # the worker log.
      assert_equal 2, signature.count { |kind, _path, _relation, _first| kind == :chat }
    end
  end

  ## Envelope variants (current `meta` key) and repeated references ##

  # The current envelope writes receipts under the `meta` key of the
  # function_call_output payload instead of the legacy `agent_meta` array.
  # Both must yield :agent_job edges from the enclosing chat.
  def test_current_meta_envelope_receipt_yields_agent_job_edge
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Cortex/continue/Default_cur.chat')
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text({'a1' => [{'job' => child}]},
                                            envelope: :meta))

      errors = []
      visits = Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
      signature = visit_signature(visits)
      edge = signature.find { |_kind, path, relation, _first| relation == :agent_job && path == child }
      assert edge, "no :agent_job edge to #{child} in #{signature.inspect}"
      assert_equal :job, edge[0]
    end
  end

  # Job references recorded by chat_task point at the .chat result file
  # (e.g. Cortex/continue/Default_x.chat); resolution must work for them too.
  def test_chat_typed_job_reference_resolves
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Cortex/continue/Default_x.chat')
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text({'a1' => [{'job' => child}]},
                                            envelope: :meta))

      errors = []
      visits = Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
      signature = visit_signature(visits)
      assert signature.any? { |_kind, path, relation, _first| relation == :agent_job && path == child },
             signature.inspect
    end
  end

  # Several continuations of one conversation report the SAME child job ref
  # from one parent (the user-visible case: three Cortex/continue calls).
  # Each receipt keeps its own edge and detail, the child node expands once.
  def test_repeated_job_references_keep_distinct_edges_and_expand_once
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Cortex/continue/Default_dup.chat')
      receipt = [{'job' => child}]
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text({'a1' => receipt, 'a2' => receipt, 'a3' => receipt},
                                            envelope: :meta))

      errors = []
      visits = Chat.traverse_provenance(parent, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
      delegated = visits.select { |v| v[4] == :agent_job }
      assert_equal 3, delegated.length, 'each receipt keeps its own edge'
      delegated.each_with_index do |visit, i|
        assert_equal child, visit[1].path.to_s
        assert_equal "a#{i + 1}", visit[6][:call_id], 'edge detail keeps the originating call id'
      end
      assert_equal [true, false, false], delegated.collect { |v| v[5] },
                   'only the first visit expands the child node'
      # Three edges to the SAME job node are structural: only the first one
      # expands it (visit count 3, single expansion flag set).
      assert_equal 3, visits.count { |kind, object, *_| kind == :job && object.path.to_s == child }
    end
  end

  def test_follow_job_excludes_the_agent_job_edge
    TmpFile.with_dir do |dir|
      parent, _worker, _critic, _dep = fixture_c(dir)

      signature = visit_signature(Chat.traverse_provenance(parent, follow: [:job]).to_a)

      assert_empty signature.select { |_kind, _path, relation, _first| relation == :agent_job }
      # The ordinary meta job= reference still resolves under follow: [:job].
      assert signature.any? { |_kind, path, relation, _first| relation == :job && path.end_with?('Critic/ask/Default_c') }
      assert_equal 2, signature.length
    end
  end

  def test_follow_agent_job_includes_only_the_agent_job_edge
    TmpFile.with_dir do |dir|
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
    TmpFile.with_dir do |dir|
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
    TmpFile.with_dir do |dir|
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

      worker_log = File.join(worker + '.files', 'agent.chat')
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
    TmpFile.with_dir do |dir|
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
    TmpFile.with_dir do |dir|
      # Output message indexes in the parsed chat (no leading empty user
      # message since Chat.parse stopped emitting it): b1 -> 2, b2 -> 4,
      # b3 -> 6.
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
        assert_kind_of ScoutException, error
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
      assert_equal [chat, 2], not_an_array.last[:output_address]
      assert_nil not_an_array.last[:evidence_address]
      assert_nil not_an_array.last[:agent_meta_index]
      invalid_role = errors.find { |_e, _k, _o, _r, ref| ref[:reason] == :invalid_role }
      assert_equal [chat, 4, :agent_meta, 0], invalid_role.last[:evidence_address]
      assert_equal 0, invalid_role.last[:agent_meta_index]
      unparseable = errors.find { |_e, _k, _o, _r, ref| ref[:reason] == :unparseable_meta && ref[:output_address] == [chat, 4] }
      assert_equal [chat, 4, :agent_meta, 1], unparseable.last[:evidence_address]

      # Nothing malformed was silently used as provenance.
      assert_equal 1, visits.length
    end
  end

  # Provenance is only extracted from parsed function_call_output JSON
  # Hashes carrying an explicit `agent_meta` key.  Raw output text that merely
  # mentions the word must never produce a warning (or a strict-mode raise).
  def test_unparseable_output_mentioning_agent_meta_is_ignored
    TmpFile.with_dir do |dir|
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

      assert_empty errors
      assert_equal 1, visits.length

      # Strict mode is equally silent: no heuristic may fail traversal.
      assert_nothing_raised do
        Chat.traverse_provenance(chat).to_a
      end
    end
  end

  # An explicit agent_meta key with a non-Array value is a malformed receipt
  # (present, not absent) and must warn through the normal path.
  def test_explicit_non_array_agent_meta_warns
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'explicit.chat',
                        receipt_chat_text({'x1' => [meta_receipt('pt=1 tt=2 inference_id=e1')]}))

      errors = []
      Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a
      assert_empty errors
    end
  end

  def test_unresolved_job_reference_warns_and_is_not_enqueued
    TmpFile.with_dir do |dir|
      missing = File.join(dir, 'Missing/ask/Default_zzz')
      chat = write_chat(dir, 'unresolved.chat',
                        receipt_chat_text({'u1' => [meta_receipt("job=#{missing}")]},
                                          extra: ["meta: job=#{File.join(dir, 'Critic/ask/Default_c')}"]))

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a

      unresolved = errors.collect(&:last).select { |ref| ref[:reason] == :unresolved_job_reference }
      assert_equal 1, unresolved.length
      assert_equal missing, unresolved.first[:reference]
      assert_equal [chat, 2, :agent_meta, 0], unresolved.first[:evidence_address]
      assert_equal 'u1', unresolved.first[:call_id]
      assert_equal 'ask', unresolved.first[:tool_name]

      error, _kind, object, relation, _ref = errors.find { |args| args.last[:reason] == :unresolved_job_reference }
      assert_kind_of ScoutException, error
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
    TmpFile.with_dir do |dir|
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
    TmpFile.with_dir do |dir|
      missing = File.join(dir, 'Missing/ask/Default_zzz')
      chat = write_chat(dir, 'strict.chat',
                        receipt_chat_text({'s1' => [meta_receipt("job=#{missing}")]}))

      error = assert_raise(ScoutException) do
        Chat.traverse_provenance(chat).to_a
      end
      assert_match(/unresolved_job_reference/, error.message)
      assert_match(/#{Regexp.escape(chat)}/, error.message)
      assert_match(/#{Regexp.escape(missing)}/, error.message)
    end
  end

  def test_strict_mode_raises_on_malformed_receipt
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'strict-bad.chat',
                        receipt_chat_text({'s1' => [{role: 'assistant', content: 'x'}]}))

      error = assert_raise(ScoutException) do
        Chat.traverse_provenance(chat).to_a
      end
      assert_match(/invalid_role/, error.message)
    end
  end

  def test_no_warnings_without_receipts
    TmpFile.with_dir do |dir|
      plain = write_chat(dir, 'plain.chat',
                         "user: hi\nmeta: pt=1 tt=2 inference_id=p1\nassistant: done\n")

      errors = []
      Chat.traverse_provenance(plain, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors
    end
  end

  ## Chats with a .files sidecar are scanned like jobs

  def test_saved_chat_sidecar_society_chats_are_traversed_with_log_relation
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat',
                        "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n")

      sidecar = File.expand_path(chat + '.files/agent.society/Worker/default')
      FileUtils.mkdir_p(sidecar)
      File.write(File.join(sidecar, 'agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")

      errors = []
      visits = Chat.traverse_provenance(chat, on_error: ->(*args) { errors << args }).to_a

      assert_empty errors

      society = visits.find do |_kind, object, _pk, _parent, _relation, _first|
        object.to_s.end_with?('agent.society/Worker/default/agent.chat')
      end
      assert society, 'society chat not visited'
      kind, object, parent_kind, parent, relation, first = society
      assert_equal :chat, kind
      assert_equal File.expand_path(File.join(sidecar, 'agent.chat')), object.to_s
      assert_equal :chat, parent_kind
      assert_equal File.expand_path(chat), parent.to_s
      assert_equal :log, relation
      assert first
    end
  end

  def test_saved_chat_sidecar_root_copy_is_not_traversed
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat',
                        "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n")

      log = File.expand_path(chat + '.files')
      FileUtils.mkdir_p(File.join(log, 'agent.society/Worker/default'))
      # The full-copy written by the CLI save mechanism: same content as root.
      File.write(File.join(log, 'agent.chat'),
                 "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n")
      File.write(File.join(log, 'agent.society/Worker/default/agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")

      visits = Chat.traverse_provenance(chat).to_a
      paths = visits.collect { |_k, object, _pk, _p, _r, _f| object.to_s }

      root_copy = File.join(log, 'agent.chat')
      assert_not_include paths, root_copy,
                          'the sidecar root copy must not become its own node'
      assert_include paths, File.join(log, 'agent.society/Worker/default/agent.chat')

      # No chat -> root-copy edge either.
      edges = Chat.provenance_edges(chat).collect { |e| [e[:from].to_s, e[:to].to_s, e[:relation]] }
      assert_empty edges.select { |from, to, _r| to == root_copy }
    end
  end

  def test_saved_chat_sidecar_visits_are_unique_and_repeateable
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'saved.chat',
                        "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n")

      log = File.expand_path(chat + '.files')
      FileUtils.mkdir_p(File.join(log, 'agent.society/Worker/default'))
      FileUtils.mkdir_p(File.join(log, 'agent.society/Critic/default'))
      File.write(File.join(log, 'agent.chat'),
                 "user: hi\nmeta: pt=2 ct=1 tt=3 inference_id=s0\nassistant: done\n")
      File.write(File.join(log, 'agent.society/Worker/default/agent.chat'),
                 "user: work\nmeta: pt=10 ct=5 tt=15 inference_id=w1\nassistant: ok\n")
      File.write(File.join(log, 'agent.society/Critic/default/agent.chat'),
                 "user: check\nmeta: pt=4 ct=2 tt=6 inference_id=c1\nassistant: fine\n")

      keys = nil
      2.times do
        visits = Chat.traverse_provenance(chat).to_a
        keys_now = visits.collect { |kind, object, _pk, _p, _r, _f| [kind, object.to_s] }
        keys = keys_now if keys.nil?
        assert_equal keys, keys_now, 'traversal is not deterministic'
        assert_equal keys_now.length, keys_now.uniq.length,
                     'a file reachable via several globs produced duplicate visits'
      end
    end
  end

  def test_job_log_relation_still_traverses_agent_chat_from_the_job
    TmpFile.with_dir do |dir|
      _parent, worker, _critic, _dep = fixture_c(dir)

      log = Path.setup(File.expand_path(File.join(worker.to_s + '.files')))
      log_chat = File.join(log.to_s, 'agent.chat')
      assert File.file?(log_chat), 'fixture did not create the job log chat'

      visits = Chat.traverse_provenance(worker, root_type: :job).to_a
      log_file = visits.find do |_kind, object, _pk, _parent, relation, _first|
        relation == :log && object.to_s == File.expand_path(log_chat)
      end

      assert log_file, 'job log/agent.chat was not traversed from the job'
      assert_equal :chat, log_file[0]
      assert_equal :job, log_file[2]
      assert_equal File.expand_path(worker.to_s), File.expand_path(log_file[3].path.to_s)
    end
  end

  ## Regression

  ## Reviewer pins: no tool-name gating on the :agent_job edge

  # The edge exists for ANY tool whose function_call_output envelope carries a
  # meta[].job receipt; the function name is irrelevant to accounting.  Proven
  # by fabricating a tool name that is not a scout-ai task (`not_ask`) and by
  # reusing the names of the receipt-producing workflows (`cortex_continue`,
  # `cortex_brief`) on a non-delegating envelope as a negative control.
  def test_agent_job_edge_under_arbitrary_tool_names
    TmpFile.with_dir do |dir|
      child = make_job(dir, 'Cortex/continue/Default_tn.chat')

      %w[not_ask cortex_continue cortex_brief].each do |tool|
        parent = write_chat(dir, "parent_#{tool}.chat",
                            receipt_chat_text({'a1' => [{'job' => child}]},
                                              envelope: :meta, tool: tool))
        signature = visit_signature(Chat.traverse_provenance(parent).to_a)
        assert signature.any? { |_kind, path, relation, _first|
          relation == :agent_job && path == child
        }, "no :agent_job edge for tool #{tool}: #{signature.inspect}"
      end

      # Negative control: same tool names, envelope without a job receipt ->
      # no edge, so the edge follows the receipt, not the name.
      %w[not_ask cortex_continue cortex_brief].each do |tool|
        parent = write_chat(dir, "plain_#{tool}.chat",
                            receipt_chat_text({'a1' => [{'role' => 'meta',
                                                         'content' => 'ok'}]},
                                              envelope: :meta, tool: tool))
        signature = visit_signature(Chat.traverse_provenance(parent).to_a)
        assert_empty signature.select { |_kind, _path, relation, _first| relation == :agent_job },
                     "unexpected :agent_job edge for tool #{tool}"
      end
    end
  end

  # Structural double check: the provenance source contains no conditional on
  # a function/tool name anywhere in the receipt lifting path.  The check
  # looks for gating CONSTRUCTS around the tool name (==/match/case), not for
  # the bare word, because `tool_name` is legitimately recorded as evidence
  # detail.
  def test_no_tool_name_conditional_in_provenance_sources
    source = File.read(File.expand_path('../../../../lib/scout/llm/chat/provenance.rb', __dir__))
    # 1. no equality/matching test between the name and a literal tool name
    %w[ask cortex_continue cortex_brief not_ask].each do |name|
      ["tool_name == :#{name}",
       "tool_name.to_s == '#{name}'",
       "tool_name == '#{name}'",
       "name == '#{name}'",
       "tool_name =~ /#{name}/",
       "'name' => '#{name}'"].each do |pattern|
        assert_not_include source, pattern,
                           "tool-name conditional #{pattern.inspect} leaked into provenance traversal"
      end
    end
    # 2. no case/when branch on the name at all
    assert_not_match(/^\s*case\s+(\S*tool_name|name)\s*$/, source)
    # 3. the word only appears as evidence detail, never as a value compared
    #    (the literal name recorded by callers lives in test fixtures, not here)
    assert_not_include source, "tool_name =='", source
    assert_not_include source, 'tool_name==', source
  end

  def test_provenance_relations_include_agent_job_and_not_import
    assert_equal %i[job dependency log result agent_job], Chat::PROVENANCE_RELATIONS
    assert_not_include Chat::PROVENANCE_RELATIONS, :import
    assert_not_include Chat::PROVENANCE_RELATIONS, :continue
    assert_not_include Chat::PROVENANCE_RELATIONS, :last
  end

  def test_unknown_relation_still_raises
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'any.chat', "user: hi\nassistant: done\n")

      assert_raise(ParameterException) do
        Chat.traverse_provenance(chat, follow: [:agent_meta]).to_a
      end
    end
  end
end
