# Reusable offline fixtures for agent_meta provenance tests (plan fixtures C,
# D, E; also intended for the later token-collector rounds).  Everything runs
# on TmpFile.with_dir directories plus persisted-style chat text; no providers.
#
# Helpers provided:
#   write_chat(dir, name, text)                         -> chat file path
#   meta_receipt(content)                               -> agent_meta entry Hash
#   receipt_output(call_id, agent_meta, ...)            -> JSON envelope String
#   receipt_chat_text(receipts, extra: nil)             -> persisted chat text
#   plain_delegation_chat(job_path)                     -> persisted chat text
#   make_job(dir, ref, dependencies:, logs:)            -> job path
#   visit_signature(visits)                             -> comparable Array
#   fixture_c(dir)                                      -> C/D layout paths
#   truncated_receipt_chat(call_id, agent_meta)          -> fixture H text
require 'fileutils'
require 'json'

module AgentMetaFixtures
  # Write persisted-style chat text and return its absolute path.
  def write_chat(dir, name, text)
    path = File.expand_path(File.join(dir, name))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  # One agent_meta receipt entry with direct meta content, e.g.
  # meta_receipt('pt=10 ct=4 tt=14 inference_id=w1') or
  # meta_receipt('job=Worker/ask/Default_w').
  def meta_receipt(content)
    {role: 'meta', content: content}
  end

  # JSON payload of a function_call_output envelope carrying agent_meta.
  def receipt_output(call_id, agent_meta, name: 'ask', content: 'child answer')
    {name: name, content: content, id: call_id, agent_meta: agent_meta}.to_json
  end

  # Persisted chat text with one paired ask call per receipt entry.  Hash keys
  # are call ids, values are the agent_meta payloads (Arrays, Strings, ...).
  # `extra` lines are appended after the receipts (e.g. local meta lines).
  #
  # Message indexes produced by Chat.parse (inline user line is doubled):
  #   0 user, 1 user, then per receipt: function_call, function_call_output.
  def receipt_chat_text(receipts, extra: nil)
    lines = ['user: Run the worker']
    receipts.each do |call_id, agent_meta|
      lines << 'function_call: ' + %({"name":"ask","arguments":{},"id":"#{call_id}"})
      lines << 'function_call_output: ' + receipt_output(call_id, agent_meta)
    end
    lines.concat(Array(extra)) if extra
    lines << 'assistant: done'
    lines * "\n" + "\n"
  end

  # Persisted chat text delegating to `job_path` through an ordinary local
  # `meta: job=` message (no receipts at all).
  def plain_delegation_chat(job_path)
    "user: Run the worker\nmeta: job=#{job_path}\nassistant: done\n"
  end

  # Create a job layout under `dir` for the relative reference `ref`
  # (e.g. 'Worker/ask/Default_w'): the result file, an optional .info sidecar
  # with `dependencies` (absolute paths), and log chats written under
  # `<job>.files/log/<name>` (Hash name -> chat text).  Returns the job path.
  def make_job(dir, ref, result: 'answer', dependencies: [], logs: {})
    path = File.expand_path(File.join(dir, ref))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, result)
    File.write(path + '.info', {dependencies: dependencies}.to_json) if dependencies.any?
    logs.each do |name, text|
      log_path = File.join(path + '.files', 'log', name)
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(log_path, text)
    end
    path
  end

  # Comparable signature of traverse_provenance visits:
  # [kind, path, relation, first_visit].
  def visit_signature(visits)
    visits.collect do |kind, object, _parent_kind, _parent, relation, first|
      [kind, object.respond_to?(:path) ? object.path.to_s : object.to_s, relation, first]
    end
  end

  # Fixture C layout (plan fixtures C/D): a parent receipt points at a Worker
  # job whose log chat has two direct metas (w1, w2), a nested receipt for a
  # Critic job (with one direct meta c1), and a dependency job.  The parent
  # chat also carries an ordinary local `meta: job=` reference to the Critic so
  # both discovery paths coexist, plus one receipt-only direct meta (shadow).
  # Returns [parent_chat_path, worker_job_path, critic_job_path, dep_job_path].
  def fixture_c(dir)
    critic = make_job(dir, 'Critic/ask/Default_c')
    dep = make_job(dir, 'Dep/load/Default_1')

    worker_log = receipt_chat_text(
      {'wc1' => [meta_receipt('pt=30 ct=10 tt=40 inference_id=c1'),
                 meta_receipt("job=#{critic}")]},
      extra: ['meta: pt=100 ct=50 tt=150 inference_id=w1',
              'meta: pt=20 ct=10 tt=30 inference_id=w2']
    )
    worker = make_job(dir, 'Worker/ask/Default_w',
                      dependencies: [dep], logs: {'agent.chat' => worker_log})

    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text(
                          {'p1' => [meta_receipt('pt=10 tt=12 inference_id=shadow'),
                                    meta_receipt("job=#{worker}")]},
                          extra: ["meta: job=#{critic}"]
                        ))

    [parent, worker, critic, dep]
  end

  # Fixture H: the output content is the standard truncation exception JSON
  # (error: :truncated) exactly as LLM.process_calls serializes it, while the
  # agent_meta receipts survive in the same envelope.
  def truncated_receipt_chat(call_id, agent_meta, name: 'ask', characters: 90_000)
    exception_msg = "Function #{name} #{call_id} was executed successfully, but it returned #{characters} characters, which is more than the maximum of 30000. To protect the model context window this result was not returned."
    content = {exception: exception_msg, stack: ['a', 'b']}.to_json
    payload = {name: name, content: content, id: call_id, error: :truncated,
               agent_meta: agent_meta}.to_json
    "user: Run\n" +
      %({"name":"#{name}","arguments":{},"id":"#{call_id}"}).sub(/^/, 'function_call: ') + "\n" +
      "function_call_output: #{payload}\n" +
      "assistant: done\n"
  end
end
