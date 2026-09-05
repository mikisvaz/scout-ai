require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative 'agent_meta_fixtures'

# Explanatory-plot fixture builder for the prov `--dot`/`--plot` section.
#
# Mirrors the real `test_simplify_delegation` hierarchy (in
# test/scout/llm/chat/test_simplify.rb) inside a TmpFile dir, using the
# AgentMetaFixtures helpers instead of bespoke file surgery so the dot
# tests exercise the same traversal path as the tree/flow ones:
#
#   root.chat (Manager)                     note, root
#   +- .files/agent.society/{Searcher,Worker}/...   3 society chats
#   +- receipts: 6 delegated Cortex/continue jobs
#      echo-worker, cortex-smoke x3 (SAME clean_name; continuation
#      chain ordered by explicit File.utime), cortex-unknown-brief,
#      cortex-bad-brief (status=error, no .files)
#      each success job logs Worker.chat (cumulative replay per turn)
#
# Continuation turns are ordered by mtime only: File.utime stamps t,
# t+1, t+2 on the three smoke jobs AFTER all files exist (make_job
# writes at the same second, so file-creation order would be a coin
# flip).
module ProvPlotFixtures
  # Returns [root_chat, {echo:, smoke: [turn1, turn2, turn3], unknown:,
  # bad:}, society_chats].
  def explanatory_fixture(dir)
    worker_chat = lambda do |turns|
      (1..turns).collect { |i| "user: turn #{i}\nmeta: pt=27000 ct=95 tt=27100 inference_id=s#{i}\nassistant: ok#{i}\n" } * ''
    end

    echo = make_job(dir, 'Cortex/continue/echo-worker_f44dbdeb0c47d569454e8276ea39de5e.chat',
                    info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'echo-worker'},
                    logs: {'Worker.chat' => worker_chat.call(1)})
    smoke = [
      make_job(dir, 'Cortex/continue/cortex-smoke_115194274cd0f8e93ec792fe4c73deba.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(1)}),
      make_job(dir, 'Cortex/continue/cortex-smoke_e82f128e92d0e62380defe56a7220c10.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(2)}),
      make_job(dir, 'Cortex/continue/cortex-smoke_a8f0e48e3aa9e5e127490869ccef6e3d.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(3)})
    ]
    unknown = make_job(dir, 'Cortex/continue/cortex-unknown-brief_ec60777c00847dfd02ea4d33b24895e3.chat',
                       info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-unknown-brief'},
                       logs: {'Worker.chat' => worker_chat.call(2)})
    bad = make_job(dir, 'Cortex/continue/cortex-bad-brief_56de1491208492552873b7fd299efe02.chat',
                   result: '',
                   info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-bad-brief',
                          status: 'error', exception: '{"m":"No brief unknown-brief for agent Worker"}'})

    # Continuation order is mtime-based; stamp the three smoke jobs
    # monotonically AFTER everything is on disk.
    base = Time.now - 60
    smoke.each_with_index { |job, index| File.utime(base + index, base + index, job) }

    society_chats = []
    root = write_chat(dir, 'root.chat',
                      receipt_chat_text(
                        {'r1' => [echo, *smoke, unknown, bad].collect { |job| meta_receipt("job=#{job}") }}
                      ))
    [['Searcher', 'default'], ['Worker', 'default'], ['Worker', 'mgr-social-smoke']].each do |agent, conv|
      path = File.join(root + '.files', 'agent.society', agent, conv, 'agent.chat')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "user: #{agent} #{conv}\nmeta: pt=12000 ct=100 tt=12700 inference_id=#{agent}#{conv}\nassistant: done\n")
      society_chats << path
    end

    [root, {echo: echo, smoke: smoke, unknown: unknown, bad: bad}, society_chats]
  end
end
