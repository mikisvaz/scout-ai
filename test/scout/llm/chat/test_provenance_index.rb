require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require_relative 'agent_meta_fixtures'

# Focused tests for the compact path-based provenance index
# (`Chat.provenance_graph`): one node per call, lightweight data only,
# zero-based persisted message indexes, live paths listed but never
# traversed.  Recursive behavior stays in `provenance_closure` and is
# covered by the other provenance suites.
class TestChatProvenanceIndex < Test::Unit::TestCase
  include AgentMetaFixtures

  def graph(root, **options)
    Chat.provenance_graph(root, **options)
  end

  ## (1) planned invocation triplets: job anchored at the META index
  def test_triplet_chats_are_anchored_at_the_meta_message_index
    TmpFile.with_dir do |dir|
      job = make_job(dir, 'W/ask/Default_w')
      chat = write_chat(dir, 'root.chat', [
        'user: first', "meta: job=#{job}", 'assistant: a1',
        'user: second', "meta: job=#{job}", 'assistant: a2'
      ] * "\n" + "\n")

      index = graph(chat)
      assert_equal :chat, index[:type]
      # Zero-based array indexes of the two meta messages.
      assert_equal({1 => job, 4 => job}, index[:chats])
    end
  end

  ## (2) standalone meta reference is enough
  def test_standalone_meta_job_reference
    TmpFile.with_dir do |dir|
      job = make_job(dir, 'W/ask/Default_w')
      chat = write_chat(dir, 'root.chat',
                        "user: run\nmeta: job=#{job}\nassistant: done\n")

      assert_equal({1 => job}, graph(chat)[:chats])
    end
  end

  ## (3) receipt reference anchored at the OUTER output message index
  def test_receipt_reference_is_anchored_at_outer_output_index
    TmpFile.with_dir do |dir|
      job = make_job(dir, 'W/ask/Default_w')
      text = receipt_chat_text({'c1' => [meta_receipt("job=#{job}")]})
      # indexes: 0 user, 1 function_call, 2 function_call_output, 3 assistant
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => job}, graph(chat)[:chats])
    end
  end

  ## (4) both reference forms in one transcript, same map
  def test_both_reference_forms_merge_into_one_map
    TmpFile.with_dir do |dir|
      a = make_job(dir, 'A/load/Default_a')
      b = make_job(dir, 'B/load/Default_b')
      text = receipt_chat_text({'c1' => [meta_receipt("job=#{a}")]},
                               extra: ["meta: job=#{b}"])
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => a, 3 => b}, graph(chat)[:chats])
    end
  end

  ## (5) multiple references at one index are preserved, not overwritten
  def test_multiple_references_at_one_index_become_an_array
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'W/ask/Default_w')
      critic = make_job(dir, 'C/ask/Default_c')
      # One receipt envelope listing two job references: both anchor at the
      # same outer output index.
      text = receipt_chat_text(
        {'c1' => [meta_receipt("job=#{worker}"), meta_receipt("job=#{critic}")]})
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => [worker, critic]}, graph(chat)[:chats])
    end
  end

  ## (6) ask call: index of the call message and Agent#conversation value
  def test_ask_call_records_delegation_at_call_index
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
        "user: go\n" \
        'function_call: {"name":"ask","arguments":{"agent":"Workspace","conversation":"plan"},"id":"c1"}' + "\n" \
        'function_call_output: {"name":"ask","content":"ok","id":"c1"}' + "\n" \
        "assistant: done\n")

      index = graph(chat)
      assert_equal({1 => 'Workspace#plan'}, index[:delegation])
      # An ask with no persisted job= metadata never enters chats.
      assert_empty index[:chats]
    end
  end

  ## (6b) missing conversation argument defaults to 'default'
  def test_ask_without_conversation_defaults
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
        "user: go\n" \
        'function_call: {"name":"ask","arguments":{"agent":"Analyst"},"id":"c1"}' + "\n" \
        'function_call_output: {"name":"ask","content":"ok","id":"c1"}' + "\n")

      assert_equal({1 => 'Analyst#default'}, graph(chat)[:delegation])
    end
  end

  ## (7) a plain reply creates no provenance branch
  def test_plain_response_has_no_provenance
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
                        "user: explain the code\nassistant: plain ScoutCoder reply\n")
      index = graph(chat)

      assert_empty index[:chats]
      assert_empty index[:delegation]
      assert_empty index[:dependencies]
      assert_empty index[:live]
      assert_empty index[:warnings]
      assert_equal :chat, index[:type]
    end
  end

  ## (8) job root: references inside the OUTPUT chat
  def test_job_root_reads_references_from_its_output_chat
    TmpFile.with_dir do |dir|
      nested = make_job(dir, 'N/load/Default_n')
      output = "user: run\nmeta: job=#{nested}\nassistant: done\n"
      job = make_job(dir, 'W/ask/Default_w', result: output,
                     info: {type: 'chat', status: 'done'})

      assert_equal({1 => nested}, graph(job, root_type: :job)[:chats])
    end
  end

  ## (9) the job's INPUT chat is never treated as generated output
  def test_job_root_ignores_its_input_chat
    TmpFile.with_dir do |dir|
      input_only = make_job(dir, 'Other/ask/Default_o')
      # The CALLER's chat references input_only; it is the job's input
      # context, persisted next to it, not the job's output.
      write_chat(dir, 'caller.chat',
                 "user: call\nmeta: job=#{input_only}\nassistant: done\n")
      job = make_job(dir, 'W/ask/Default_w', result: 'plain text result',
                     info: {type: 'tsv', status: 'done'})

      index = graph(job, root_type: :job)
      assert_empty index[:chats]
      assert_equal :job, index[:type]
    end
  end

  ## (10) non-chat job: dependencies and live files, no chats
  def test_non_chat_job_has_dependencies_but_no_chats
    TmpFile.with_dir do |dir|
      dep = make_job(dir, 'D/load/Default_d')
      job = make_job(dir, 'W/load/Default_w', dependencies: [dep])

      index = graph(job, root_type: :job)
      assert_equal :job, index[:type]
      assert_empty index[:chats]
      assert_empty index[:delegation]
    end
  end

  ## (11) dependency order preserved; only direct dependencies
  def test_dependencies_are_direct_and_ordered
    TmpFile.with_dir do |dir|
      first = make_job(dir, 'P/one/Default_1')
      second = make_job(dir, 'P/two/Default_2', dependencies: [first])
      third = make_job(dir, 'P/three/Default_3')
      job = make_job(dir, 'W/ask/Default_w',
                     dependencies: [third, second, first],
                     result: "user: hi\nassistant: done\n",
                     info: {type: 'chat'})

      assert_equal [third, second, first], graph(job, root_type: :job)[:dependencies]
    end
  end

  ## (12) a byte-identical top-level sidecar is still listed in live
  def test_byte_identical_sidecar_is_still_live
    TmpFile.with_dir do |dir|
      text = "user: hi\nassistant: done\n"
      chat = write_chat(dir, 'root.chat', text)
      FileUtils.mkdir_p(chat + '.files')
      File.write(File.join(chat + '.files', 'agent.chat'), text)

      live = graph(chat)[:live].collect { |path| File.basename(path) }
      assert_equal ['agent.chat'], live
    end
  end

  ## (13) society agent.chat is live, but not authoritative provenance
  def test_society_chat_is_live_but_not_provenance
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
                        "user: hi\nassistant: done\n")
      society = File.join(chat + '.files', 'agent.society', 'ScoutCoder', 'default')
      FileUtils.mkdir_p(society)
      # Society chat carries its OWN job reference: still not traversed.
      File.write(File.join(society, 'agent.chat'),
                 "user: work\nmeta: job=Society/Only/Default_x\nassistant: ok\n")

      index = graph(chat)
      assert_equal [File.join(society, 'agent.chat')], index[:live]
      assert_empty index[:chats]
      assert_empty index[:delegation]
    end
  end

  ## (14) missing sidecar and society directories give empty live
  def test_missing_files_dirs_give_empty_live
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat', "user: hi\nassistant: done\n")
      assert_empty graph(chat)[:live]

      job = make_job(dir, 'W/load/Default_w')
      assert_empty graph(job, root_type: :job)[:live]
    end
  end

  ## (15) lightweight data only: no Chat/Step instances, no message bodies
  def test_return_value_contains_no_objects_or_message_bodies
    TmpFile.with_dir do |dir|
      dep = make_job(dir, 'D/load/Default_d')
      output = "user: run\nmeta: job=#{dep}\nassistant: the actual reply text\n"
      job = make_job(dir, 'W/ask/Default_w', result: output,
                     dependencies: [dep], info: {type: 'chat'})
      society = File.join(job + '.files', 'agent.society', 'Critic', 'default')
      FileUtils.mkdir_p(society)
      File.write(File.join(society, 'agent.chat'),
                 "user: c\nassistant: the actual reply text\n")

      index = graph(job, root_type: :job)
      collect = lambda do |value, &block|
        case value
        when Hash then value.each_value { |v| collect.call(v, &block) }
        when Array then value.each { |v| collect.call(v, &block) }
        else block.call(value)
        end
      end
      leaves = []
      collect.call(index) { |leaf| leaves << leaf }
      assert(leaves.all? { |leaf| [String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].any? { |k| k === leaf } },
             "non-scalar leaves: #{leaves.reject { |l| [String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].any? { |k| k === l } }.inspect}")
      assert_not_include leaves, 'the actual reply text'
    end
  end

  ## Invariants V1/V2/V5/V7 restated as behavior
  def test_live_paths_never_reenter_the_index
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat', "user: hi\nassistant: done\n")
      society = File.join(chat + '.files', 'agent.society', 'W', 'c')
      FileUtils.mkdir_p(society)
      File.write(File.join(society, 'agent.chat'),
                 "user: work\nmeta: job=Live/Ref/Default_l\n" \
                 'function_call: {"name":"ask","arguments":{"agent":"Analyst"},"id":"k1"}' + "\n")

      index = graph(chat)
      # The references live inside a live sidecar; the index must not have
      # loaded that chat, so neither entry appears.
      assert_empty index[:chats]
      assert_empty index[:delegation]
    end
  end

  def test_chat_root_has_no_dependencies
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
                        "user: hi\nmeta: job=X/Y/Default_x\nassistant: done\n")
      assert_empty graph(chat)[:dependencies]
    end
  end

  ## Malformed receipts follow the on_error policy and warn
  def test_malformed_receipt_warns_and_keeps_other_provenance
    TmpFile.with_dir do |dir|
      good = make_job(dir, 'G/load/Default_g')
      broken = File.join(dir, 'broken.chat')
      # One standalone meta plus one receipt whose entry is not a Hash.
      File.write(broken,
                 "user: run\nmeta: job=#{good}\n" \
                 'function_call: {"name":"ask","arguments":{},"id":"c1"}' + "\n" \
                 'function_call_output: {"name":"ask","content":"ok","id":"c1","meta":"not-an-array"}' + "\n" \
                 "assistant: done\n")

      index = graph(broken)
      assert_equal({1 => good}, index[:chats])
      assert_equal 1, index[:warnings].length
      assert_equal :agent_meta, index[:warnings].first[:kind]
    end
  end

  def test_unresolved_receipt_reference_warns_and_is_not_listed
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
        "user: run\n" \
        'function_call: {"name":"ask","arguments":{},"id":"c1"}' + "\n" \
        'function_call_output: {"name":"ask","content":"ok","id":"c1","meta":[{"job":"Nope/None/Default_z"}]}' + "\n")

      index = graph(chat)
      assert_empty index[:chats]
      assert_equal 1, index[:warnings].length
      assert_match(/unresolved_job_reference/, index[:warnings].first[:error].to_s)
    end
  end

  def test_strict_mode_raises_on_unresolved_receipt
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
        "user: run\n" \
        'function_call: {"name":"ask","arguments":{},"id":"c1"}' + "\n" \
        'function_call_output: {"name":"ask","content":"ok","id":"c1","meta":[{"job":"Nope/None/Default_z"}]}' + "\n")

      assert_raise ScoutException do
        graph(chat, on_error: :raise)
      end
    end
  end

  ## ROUND 4 — resolved, canonical absolute paths everywhere

  # A SHORT metadata reference resolves to the job's canonical absolute
  # path.  The real spelling is RELATIVE-with-.chat (e.g.
  # 'Planned/ask/Default_x.chat'); load_job_reference resolves it by
  # joining the job fallback bases, so the test stubs the bases to a
  # TmpFile base instead of writing into the user's live var/jobs.
  def test_short_reference_resolves_to_canonical_absolute_job_path
    TmpFile.with_dir do |dir|
      base = File.join(dir, 'var', 'jobs')
      worker = File.join(base, 'W', 'ask', 'Default_w.chat')
      Open.mkdir(File.dirname(worker))
      Open.write(worker, "user: run\nassistant: done\n")
      Open.write(worker + '.info', {}.to_json)

      Chat.singleton_class.send(:alias_method, :job_reference_fallback_bases_original, :job_reference_fallback_bases)
      Chat.singleton_class.send(:define_method, :job_reference_fallback_bases) { [base] }
      short = 'W/ask/Default_w.chat'
      chat = write_chat(dir, 'root.chat',
                        "user: run\nmeta: job=#{short}\nassistant: done\n")
      index = graph(chat)
      assert_equal({1 => worker}, index[:chats])
      assert_empty index[:warnings]
      assert Step === Step.load(index[:chats].values.first)
    ensure
      Chat.singleton_class.send(:remove_method, :job_reference_fallback_bases)
      Chat.singleton_class.send(:alias_method, :job_reference_fallback_bases, :job_reference_fallback_bases_original)
      Chat.singleton_class.send(:remove_method, :job_reference_fallback_bases_original)
    end
  end

  # Follow-up workflow from the round-4 specification, executed end to end.
  def test_follow_up_workflow_with_canonical_paths
    TmpFile.with_dir do |dir|
      dep = make_job(dir, 'D/prepare/Default_d')
      worker = make_job(dir, 'W/ask/Default_w', dependencies: [dep],
                        result: "user: run\nassistant: done\n",
                        info: {type: 'chat'})
      chat = write_chat(dir, 'root.chat',
                        "user: go\nmeta: job=#{worker}\nassistant: done\n")

      graph = Chat.provenance_graph(chat)
      job_path = graph[:chats].values.flatten.first
      assert File.absolute_path?(job_path)
      assert_equal worker, job_path

      job = Step.load(job_path)
      job_graph = Chat.provenance_graph(job)
      assert_equal :job, job_graph[:type]

      job_graph[:dependencies].each do |dependency_path|
        assert File.absolute_path?(dependency_path)
        assert Step === Step.load(dependency_path)
      end
      assert_equal [dep], job_graph[:dependencies]

      # (5) the job root still inspects its OUTPUT chat for references and
      # delegations found there.
      assert_equal :chat, Chat.load(job_result_output(job)).messages.first[:role] rescue nil
      nested = make_job(dir, 'N/load/Default_n')
      Open.write(job.path.to_s,
                 "user: run\nmeta: job=#{nested}\nassistant: done\n")
      assert_equal({1 => nested}, Chat.provenance_graph(job)[:chats])
    end
  end

  # (2) receipt-derived references get the same treatment.
  def test_receipt_reference_resolves_to_canonical_absolute_job_path
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'W/ask/Default_w')
      text = receipt_chat_text({'c1' => [meta_receipt("job=#{worker}")]})
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => worker}, graph(chat)[:chats])
    end
  end

  # (3) multiple references at one index remain intact, as canonical paths.
  def test_multiple_resolved_references_stay_an_array
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'W/ask/Default_w')
      critic = make_job(dir, 'C/ask/Default_c')
      text = receipt_chat_text(
        {'c1' => [meta_receipt("job=#{worker}"), meta_receipt("job=#{critic}")]})
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => [worker, critic]}, graph(chat)[:chats])
    end
  end

  # Repeated references to the SAME job at one index deduplicate.
  def test_repeated_same_job_reference_at_one_index_deduplicates
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'W/ask/Default_w')
      text = receipt_chat_text(
        {'c1' => [meta_receipt("job=#{worker}"), meta_receipt("job=#{worker}")]})
      chat = write_chat(dir, 'root.chat', text)

      assert_equal({2 => worker}, graph(chat)[:chats])
    end
  end

  # A standalone meta reference that cannot resolve warns (or raises) and
  # is not listed, mirroring the receipt behavior.
  def test_unresolved_standalone_meta_warns
    TmpFile.with_dir do |dir|
      chat = write_chat(dir, 'root.chat',
                        "user: run\nmeta: job=Nowhere/None/Default_n\nassistant: done\n")

      index = graph(chat)
      assert_empty index[:chats]
      assert_equal 1, index[:warnings].length
      assert_match(/unresolved_job_reference/, index[:warnings].first[:error].to_s)

      assert_raise ScoutException do
        graph(chat, on_error: :raise)
      end
    end
  end

  # (7)/(8) a Step object is a job root; the same path WITHOUT an explicit
  # root_type stays a CHAT root.  Both must inspect the job.
  def test_step_object_and_explicit_root_type_identify_job_root
    TmpFile.with_dir do |dir|
      dep = make_job(dir, 'D/prepare/Default_d')
      output = "user: hi\nassistant: done\n"
      worker = make_job(dir, 'W/ask/Default_w', result: output,
                        dependencies: [dep], info: {type: 'chat'})
      step = Step.load(worker)

      [Chat.provenance_graph(step),
       Chat.provenance_graph(step.path, root_type: :job)].each do |job_index|
        assert_equal :job, job_index[:type]
        assert_equal [dep], job_index[:dependencies]
        # The output chat exists and is readable at step.path; its presence
        # must not flip the path-only call to a chat root... it does not:
      end

      # Without root_type, the same path is a chat root (the output
      # transcript itself), with no dependencies.
      chat_index = Chat.provenance_graph(step.path)
      assert_equal :chat, chat_index[:type]
      assert_empty chat_index[:dependencies]
    end
  end

  private

  # The job's persisted result file when it is a chat-producing job.
  def job_result_output(job)
    Chat.job_result_chat_file(job).to_s
  end
end
