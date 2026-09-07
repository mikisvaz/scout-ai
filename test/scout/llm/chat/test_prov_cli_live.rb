# Tests for the --live section of `scout-ai llm prov`: the unified live
# report (Chat.live_report) rendered as an appended section, captured work
# excluded, silent when nothing is live.
#
# Live job fixtures are synthetic on purpose: a running job is a directory
# plus a .info JSON whose pid is the test process itself (Chat.live_pid?
# accepts the current pid), exactly like test_live_workload.rb.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative 'agent_meta_fixtures'

class TestProvCLILive < Test::Unit::TestCase
  include AgentMetaFixtures

  REPO_ROOT = File.expand_path('../../../../../', __FILE__)

  # Run the real binary.  By default the cwd is the fixture dir, because
  # the live passes resolve short job references (WF/continue/one) against
  # Workflow.directory, whose default 'var/jobs' is PWD-relative: fixtures
  # write their jobs under <dir>/var/jobs and the subprocess must run from
  # <dir> for resolution to match live_workload's in-process tests.
  def prov(*args)
    cwd = File.directory?(args.first.to_s) ? args.shift : REPO_ROOT
    cmd = [RbConfig.ruby, File.join(REPO_ROOT, 'bin', 'scout-ai'), 'llm', 'prov'] + args.collect(&:to_s)
    env = ENV.to_h.merge('SCOUT_DEV' => nil)
    Timeout.timeout(120) do
      out, err, status = Open3.capture3(env, *cmd, chdir: cwd)
      [strip_ansi(out), strip_ansi(err), status]
    end
  end

  def strip_ansi(text)
    text.gsub(/\e\[[0-9;]*m/, '')
  end

  # One running job directory: `<wfdir>/<ref>` with a .info sidecar whose
  # pid is this test process, so Chat.classify_live_job reports :running.
  # Returns the full job path.
  def running_job(wfdir, ref, type: 'string', dependencies: [])
    path = File.join(wfdir, ref)
    FileUtils.mkdir_p(path)
    File.write(path + '.info',
               {status: 'running', pid: Process.pid, type: type,
                workflow: ref.split('/').first, task_name: ref.split('/')[1],
                dependencies: dependencies}.to_json)
    path
  end

  # A running chat task with its agent save file inside the job's .files
  # dir, as AgentWorkflow would keep it.
  def running_chat_task(wfdir, ref)
    path = running_job(wfdir, ref, type: 'chat')
    files_dir = path + '.files'
    FileUtils.mkdir_p(files_dir)
    File.write(File.join(files_dir, 'agent.chat'),
               "\nuser:\n\ndo the thing\n")
    path
  end

  def test_live_section_appends_running_inference
    TmpFile.with_dir do |dir|
      # A quiet parent chat plus a live delegation chain: the sidecar lists
      # the wrapper job; the wrapper's dependency is the chat task.
      chat = write_chat(dir, 'parent.chat',
                        "user: go\nmeta: pt=1 ct=1 tt=2 inference_id=q1\nassistant: done\n")
      wfdir = File.join(dir, 'var', 'jobs')
      task = running_chat_task(wfdir, 'WF/continue/one')
      wrapper = running_job(wfdir, 'WF/cortex_continue/one',
                            dependencies: [task])
      File.write(Chat.jobs_file(chat), "WF/cortex_continue/one\n")

      out, err, status = prov(dir, '--live', chat)
      assert status.success?, err

      # The live section header is present once, after the normal report.
      headers = out.lines.select { |l| l.include?('Live work') }
      assert_equal 1, headers.length, out

      # The chat task is the inference entry; the wrapper only shows as
      # workload context; neither duplicates the forensic report's work.
      task_line = out.lines.find { |l| l.include?('WF/continue/one') }
      assert task_line, out
      assert_include task_line, 'chat_task'
      assert_include task_line, 'running'
      assert_include task_line, "log=#{task}.files/agent.chat"

      wrap_line = out.lines.find { |l| l.include?('WF/cortex_continue/one') }
      assert wrap_line, out
      assert_include wrap_line, 'workflow'

      # Exactly one line per entry, sorted deterministically
      # (inference before workload context).
      section = out.lines[(out.lines.index { |l| l.include?('Live work') } || 0)..-1]
      body = section.select { |l| l =~ /^\s{2}(chat_task|workflow|dangling_job|agent_active)\b/ }
      assert_equal 2, body.length, out

      # The normal report was not changed by --live: the forensic footer
      # (token totals) is identical with and without the flag.
      out_plain, _e, s2 = prov(dir, chat)
      assert s2.success?
      footer = ->(o) { o.lines.find { |l| l.start_with?('root deduplicated_total=') } }
      assert_equal footer.(out_plain), footer.(out), out
    end
  end

  def test_quiescent_chat_live_adds_nothing
    TmpFile.with_dir do |dir|
      # Nothing anywhere: no .jobs sidecar, no .files, no society tree.
      plain = write_chat(dir, 'plain.chat',
                         "user: go\nmeta: pt=1 ct=1 tt=2 inference_id=q1\nassistant: done\n")

      out_plain, err, status = prov(dir, plain)
      out_live, _err2, status2 = prov(dir, '--live', plain)
      assert status.success?, err
      assert status2.success?

      assert_equal out_plain, out_live, 'quiescent chat: --live must add nothing'
      assert_not_include out_live, 'Live work'
    end
  end

  def test_captured_job_is_not_repeated_in_live_section
    TmpFile.with_dir do |dir|
      # A finished delegation already in the forensic report (meta: job=)
      # plus a live chat task under the same parent.
      wfdir = File.join(dir, 'var', 'jobs')
      done = running_chat_task(wfdir, 'WF/continue/done')
      # make it terminal so the forensic report resolves it as a job
      info = JSON.parse(File.read(done + '.info'))
      info['status'] = 'done'
      File.write(done + '.info', info.to_json)

      chat = write_chat(dir, 'parent.chat',
                        "user: go\nmeta: job=WF/continue/done\nassistant: done\n")
      live_task = running_chat_task(wfdir, 'WF/continue/live')
      File.write(Chat.jobs_file(chat), "WF/continue/live\n")

      out, err, status = prov(dir, '--live', chat)
      assert status.success?, err

      # The captured (done) job must not appear in the live section.
      live_lines = out.lines.select { |l| l =~ /^\s{2}(chat_task|workflow|dangling_job|agent_active)\b/ }
      assert live_lines.none? { |l| l.include?('WF/continue/done') }, out
      # The live task does.
      assert live_lines.any? { |l| l.include?('WF/continue/live') }, out
    end
  end
end
