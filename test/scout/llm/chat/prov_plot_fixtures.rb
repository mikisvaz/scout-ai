require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative 'agent_meta_fixtures'

# Explanatory-plot fixture builder for the prov `--dot`/`--plot`/`--timeline`
# section.
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
# Timeline schedule: every stamped node gets ONE coherent time applied BOTH
# as chat-content meta `timestamp=` fields and as File.mtime (job mtime =
# the END of its chat), so the timeline view's chat-content priority and
# its mtime fallback agree on the order and the flow view's mtime-ordered
# continuation chain is untouched.  Cumulative chain replays share their
# first turn's timestamp, so chain chats are ordered by (start, end, path).
# The smoke family is contiguous in the resulting sequence, so the temporal
# cluster rule fires on this fixture; the root and the error job carry NO
# chat timestamps on purpose, exercising the mtime-fallback badge.
module ProvPlotFixtures
  # Seconds after `base` (base = Time.now.utc - 600): root 0, society
  # chats 10/44/50, echo 30, smoke turns 60/95/110 (cumulative chats span
  # 60->95 and 60->110), unknown 130->140, error job 150.
  TIMELINE_OFFSETS = {
    root: 0, society_searcher: 10, echo: 30, society_worker: 44,
    society_mgr: 50, smoke: [60, 95, 110], unknown: [130, 140], bad: 150
  }.freeze

  # Returns [root_chat, {echo:, smoke: [turn1, turn2, turn3], unknown:,
  # bad:}, society_chats, schedule].  `schedule` maps every stamped node
  # path to its [start, end] Time pair; the timeline tests recompute the
  # event sequence, the cluster outcome and the overlap flags from it
  # instead of trusting the spec's ASSUMED order.
  def explanatory_fixture(dir)
    base = Time.now.utc - 600
    iso = lambda { |time| time.utc.iso8601 }
    worker_chat = lambda do |turns, times|
      (1..turns).collect do |i|
        "user: turn #{i}\nmeta: pt=27000 ct=95 tt=27100 inference_id=s#{i} " \
          "timestamp=#{iso.call(times[i - 1])}\nassistant: ok#{i}\n"
      end * ''
    end

    echo_time = base + TIMELINE_OFFSETS[:echo]
    smoke_times = TIMELINE_OFFSETS[:smoke].collect { |offset| base + offset }
    unknown_times = TIMELINE_OFFSETS[:unknown].collect { |offset| base + offset }

    echo = make_job(dir, 'Cortex/continue/echo-worker_f44dbdeb0c47d569454e8276ea39de5e.chat',
                    info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'echo-worker'},
                    logs: {'Worker.chat' => worker_chat.call(1, [echo_time])})
    smoke = [
      make_job(dir, 'Cortex/continue/cortex-smoke_115194274cd0f8e93ec792fe4c73deba.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(1, smoke_times[0, 1])}),
      make_job(dir, 'Cortex/continue/cortex-smoke_e82f128e92d0e62380defe56a7220c10.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(2, smoke_times[0, 2])}),
      make_job(dir, 'Cortex/continue/cortex-smoke_a8f0e48e3aa9e5e127490869ccef6e3d.chat',
               info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-smoke'},
               logs: {'Worker.chat' => worker_chat.call(3, smoke_times)})
    ]
    unknown = make_job(dir, 'Cortex/continue/cortex-unknown-brief_ec60777c00847dfd02ea4d33b24895e3.chat',
                       info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-unknown-brief'},
                       logs: {'Worker.chat' => worker_chat.call(2, unknown_times)})
    bad = make_job(dir, 'Cortex/continue/cortex-bad-brief_56de1491208492552873b7fd299efe02.chat',
                   result: '',
                   info: {workflow: 'Cortex', task_name: 'continue', clean_name: 'cortex-bad-brief',
                          status: 'error', exception: '{"m":"No brief unknown-brief for agent Worker"}'})

    society_chats = []
    root = write_chat(dir, 'root.chat',
                      receipt_chat_text(
                        {'r1' => [echo, *smoke, unknown, bad].collect { |job| meta_receipt("job=#{job}") }}
                      ))

    society_times = [['Searcher', 'default', TIMELINE_OFFSETS[:society_searcher]],
                     ['Worker', 'default', TIMELINE_OFFSETS[:society_worker]],
                     ['Worker', 'mgr-social-smoke', TIMELINE_OFFSETS[:society_mgr]]]
    society_times = society_times.collect do |agent, conv, offset|
      path = File.join(root + '.files', 'agent.society', agent, conv, 'agent.chat')
      FileUtils.mkdir_p(File.dirname(path))
      time = base + offset
      File.write(path, "user: #{agent} #{conv}\nmeta: pt=12000 ct=100 tt=12700 " \
                       "inference_id=#{agent}#{conv} timestamp=#{iso.call(time)}\nassistant: done\n")
      society_chats << path
      [path, time]
    end.to_h

    # Stamp every fixture file with its schedule time AFTER all files exist
    # (make_job writes at the same second, so file-creation order would be
    # a coin flip).  The smoke jobs keep a strictly monotonic mtime
    # sequence (60 < 95 < 110), so the flow view's continuation chain
    # ordering and turn numbering are unchanged by the schedule.
    schedule = {}
    stamp = lambda do |path, start_time, end_time|
      File.utime(end_time, end_time, path)
      schedule[path] = [start_time, end_time]
    end
    stamp.call(root, base, base)
    stamp.call(echo, echo_time, echo_time)
    stamp.call(File.join(echo + '.files', 'Worker.chat'), echo_time, echo_time)
    smoke.each_with_index do |job, index|
      stamp.call(job, smoke_times[index], smoke_times[index])
      stamp.call(File.join(job + '.files', 'Worker.chat'), smoke_times.first, smoke_times[index])
    end
    stamp.call(unknown, unknown_times.last, unknown_times.last)
    stamp.call(File.join(unknown + '.files', 'Worker.chat'), unknown_times.first, unknown_times.last)
    stamp.call(bad, base + TIMELINE_OFFSETS[:bad], base + TIMELINE_OFFSETS[:bad])
    society_times.each { |path, time| stamp.call(path, time, time) }

    [root, {echo: echo, smoke: smoke, unknown: unknown, bad: bad}, society_chats, schedule]
  end
end
