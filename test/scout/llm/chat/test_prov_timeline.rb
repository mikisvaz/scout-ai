require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require_relative 'agent_meta_fixtures'
require_relative 'prov_plot_fixtures'

# Execution-timeline tests (`--timeline`) for `scout-ai llm prov`.
#
# Companion class to TestProvExplanatoryPlot (same file convention, same
# CLI driver): these assert on the timeline dot the CLI writes through
# `--timeline FILE.dot`, plus one graphviz geometry check (`dot -Tplain`).
#
# The fixture (ProvPlotFixtures#explanatory_fixture) stamps every node
# with BOTH a chat-content meta `timestamp=` pair and a coherent
# File.utime (job mtime = end of its chat), so the chat-content priority
# and the mtime fallback agree on the order.  Root and the error job
# carry no chat timestamps on purpose: they exercise the mtime fallback.
# Every sequence-dependent expectation below is RECOMPUTED from the
# fixture's returned `schedule` map, never hard-coded from the spec's
# ASSUMED sequence.
class TestProvTimeline < Test::Unit::TestCase
  include AgentMetaFixtures
  include ProvPlotFixtures

  REPO_ROOT = File.expand_path('../../../..', __dir__)

  def self.startup
    Log.severity = 5
  end

  def prov(*args)
    cmd = [RbConfig.ruby, '-I', File.join(REPO_ROOT, 'lib'),
           File.join(REPO_ROOT, 'bin', 'scout-ai'), 'llm', 'prov',
           '--nocolor', *args.collect(&:to_s)]
    Open3.capture3(*cmd)
  end

  def timeline_for(root, name = 'timeline')
    @prov_count += 1
    target = File.join(@dir, "#{name}_#{@prov_count}.dot")
    out, err, status = prov('--timeline', target, root)
    assert status.success?, err
    [File.read(target), out]
  end

  # Recompute the expected time sequence from the fixture schedule,
  # exactly as the CLI's time model does (spec S3):
  #   job      -> chat interval [first meta, last meta]  (start = first)
  #   job chat -> its own mtime (the fixture stamps end)  (start = end)
  #   root/bad -> mtime (no chat timestamps)              (start = end)
  #   society  -> its own chat interval (single stamp)
  # Returns [ordered_paths, time_by_path] with [start, end] pairs.
  def expected_sequence(root, jobs, society, schedule)
    time_by_path = {}
    time_by_path[root] = schedule[root]
    time_by_path[jobs[:bad]] = schedule[jobs[:bad]]
    [jobs[:echo], *jobs[:smoke], jobs[:unknown]].each do |job|
      chat = File.join(job + '.files', 'Worker.chat')
      # the job uses the chat interval; the chat NODE uses its own file's
      # chat timestamps too, which for the cumulative replays is
      # [first-turn stamp, own stamp]
      time_by_path[job] = schedule[chat]
      time_by_path[chat] = schedule[chat]
    end
    society.each { |chat| time_by_path[chat] = schedule[chat] }
    # the CLI sorts on the full time key [start, end, path]
    ordered = time_by_path.keys.sort_by { |path| [*time_by_path[path], path] }
    [ordered, time_by_path]
  end

  # Parse the timeline dot into {node id => {label:, tooltip:, attrs:}}
  # and [[from, to, attrs], ...].
  def parse_dot(dot)
    nodes = {}
    dot.lines.each do |line|
      next unless line =~ /^\s*(n\d+) \[(.*)\];?\s*$/
      id, attrs = Regexp.last_match(1), Regexp.last_match(2)
      label = attrs[/label="((?:[^"\\]|\\.)*)"/, 1]
      tooltip = attrs[/tooltip="((?:[^"\\]|\\.)*)"/, 1]
      nodes[id] = {label: label && label.gsub('\n', "\n"), tooltip: tooltip, attrs: attrs}
    end
    edges = dot.lines.filter_map do |line|
      next unless line =~ /^\s*(n\d+) -> (n\d+) \[(.*)\];?\s*$/
      [Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)]
    end
    [nodes, edges]
  end

  # Ids are numbered along the sequence, so n0 is the earliest event.
  def id_for_path(nodes, path)
    id, = nodes.find { |_id, node| node[:tooltip] == path }
    raise "no node with tooltip #{path}" unless id
    id
  end

  setup do
    @prov_count = 0
    @dir = Dir.mktmpdir('prov-timeline')
  end

  teardown do
    FileUtils.remove_entry @dir if @dir && File.directory?(@dir)
  end

  test 'T1 rank separation: one event per rank, no rank=same' do
    TmpFile.with_dir do |dir|
      root, jobs, society = explanatory_fixture(dir)
      dot, = timeline_for(root)
      assert_not_include dot, '{rank=same', dot
      assert_include dot, 'rankdir=TB', dot
      assert_include dot, 'ranksep=0.45', dot
      # the only rank directive is the root pinned to the source rank
      assert_equal 1, dot.scan(/\{rank=source;/).length, dot
      root_id = id_for_path(parse_dot(dot)[0], root)
      assert dot.include?("{rank=source; #{root_id};}"), dot
      # and the root must be the earliest event
      _r2, _j2, _s2, schedule2 = explanatory_fixture(dir)
      ordered, = expected_sequence(root, jobs, society, schedule2)
      assert_equal root, ordered.first, dot
    end
  end

  test 'T2/T3 spine: consecutive time neighbours, reused segments' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, edges = parse_dot(dot)
      ordered, = expected_sequence(root, jobs, society, schedule)
      # the ids ARE the sequence order (n0 = earliest)
      ordered.each_with_index do |path, index|
        assert_equal "n#{index}", id_for_path(nodes, path), "#{path} should be n#{index}"
      end
      # every consecutive pair is joined by exactly one constraint=true edge
      ordered.each_cons(2) do |first, second|
        joined = edges.select { |f, t, attrs| f == id_for_path(nodes, first) && t == id_for_path(nodes, second) && attrs.include?('constraint=true') }
        assert_equal 1, joined.length, "#{first} -> #{second}\n#{dot}"
      end
      # no other edge carries constraint=true
      assert_equal ordered.length - 1, edges.count { |_f, _t, attrs| attrs.include?('constraint=true') }, dot
    end
  end

  test 'T4 chain integrity: chain arcs follow the time order' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, = parse_dot(dot)
      turns = jobs[:smoke]
      time = {}
      turns.each_with_index { |job, index| time[job] = schedule[job].first }
      ordered_turns = turns.sort_by { |job| [time[job], job] }
      continues = dot.scan(/label="continues"/).length
      assert_equal 2, continues, dot
      (ordered_turns[0...-1]).zip(ordered_turns[1..-1]).each do |first, second|
        assert dot.include?("#{id_for_path(nodes, first)} -> #{id_for_path(nodes, second)} [label=\"continues\""), dot
      end
    end
  end

  test 'T5 ports: delegates headport=w, continues tailport=e headport=w' do
    TmpFile.with_dir do |dir|
      root, jobs, _society = explanatory_fixture(dir)
      dot, = timeline_for(root)
      assert dot.scan(/class="delegated_result"[^\]]*headport=w/).length +
             dot.scan(/headport=w[^\]]*class="delegated_result"/).length >= 6, dot
      assert_equal 2, dot.scan(/constraint=false, tailport=e, headport=w/).length, dot
      assert_not_include dot, 'tailport=s'
      assert_not_include dot, 'headport=n'
    end
  end

  test 'T6 error job: time line present, token line absent' do
    TmpFile.with_dir do |dir|
      root, jobs, _society = explanatory_fixture(dir)
      dot, = timeline_for(root)
      bad = dot.lines.find { |l| l.include?("tooltip=#{jobs[:bad].inspect}") }
      assert bad, dot
      assert_include bad, 't='
      assert_include bad, '⚠ error'
      assert_not_include bad, 'tokens'
      assert_include bad, 'prov-error'
    end
  end

  test 'T7 cluster rule: chain cluster iff contiguous, no society cluster' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, = parse_dot(dot)
      assert_not_include dot, 'cluster_society', dot
      assert_include dot, 'cortex-smoke continuation chain', dot
      # recomputed contiguity: the chain cluster appears iff the chain's
      # jobs + produced chats form a contiguous block of the sequence
      ordered, = expected_sequence(root, jobs, society, schedule)
      smoke = [jobs[:smoke], jobs[:smoke].collect { |j| File.join(j + '.files', 'Worker.chat') }].flatten
      indexes = smoke.collect { |path| ordered.index(path) }.compact.sort
      contiguous = indexes.each_cons(2).all? { |a, b| b == a + 1 }
      cluster_blocks = dot.scan(/subgraph cluster_cortex_smoke \{.*?\n  \}/m)
      if contiguous
        assert_equal 1, cluster_blocks.length, dot
        ids_in_cluster = cluster_blocks[0].scan(/n\d+/)
        smoke.each { |path| assert_include ids_in_cluster, id_for_path(nodes, path), dot }
        assert_equal smoke.length, ids_in_cluster.length, dot
      else
        assert cluster_blocks.empty?, dot
      end
    end
  end

  test 'T9 y-monotonic order via dot -Tplain' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot_file = File.join(dir, 'timeline.dot')
      prov('--timeline', dot_file, root)
      dot = File.read(dot_file)
      skip 'graphviz dot not installed' unless Open.exists?('/usr/bin/dot')
      plain, err, status = Open3.capture3('dot', '-Tplain', dot_file)
      assert status.success?, err
      ordered, = expected_sequence(root, jobs, society, schedule)
      nodes, = parse_dot(dot)
      # -Tplain has a bottom-left origin, so EARLIER events must have
      # LARGER y coordinates (monotone non-increasing down the sequence).
      y_by_path = {}
      plain.lines.each do |line|
        next unless line =~ /^node (n\d+) [\d.]+ ([\d.]+)/
        y_by_path[Regexp.last_match(1)] = Regexp.last_match(2).to_f
      end
      ys = ordered.collect { |path| y_by_path[id_for_path(nodes, path)] }
      ys.each_cons(2) { |first, second| assert_operator first, :>=, second, "y not monotone: #{ys.inspect}" }
    end
  end

  test 'T10 badges and time lines match the computed order' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, = parse_dot(dot)
      # root: mtime fallback => point badge `t=` without arrow
      root_line = nodes[id_for_path(nodes, root)][:label]
      assert root_line.lines[1] =~ /^t=\d\d:\d\d:\d\d$/, root_line
      # stamped nodes: interval badge with duration
      turn3 = File.join(jobs[:smoke][2] + '.files', 'Worker.chat')
      label = nodes[id_for_path(nodes, turn3)][:label]
      assert label.lines[1] =~ /^t=\d\d:\d\d:\d\d→\d\d:\d\d:\d\d · \d+s$/, label
      # every visible node carries exactly one time line
      nodes.each_value do |node|
        time_lines = node[:label].lines.count { |l| l =~ /^t=/ }
        assert_equal 1, time_lines, node[:label]
      end
      # timestamps only in the time line: no absolute paths in labels
      nodes.each_value do |node|
        assert_not_include node[:label], dir, node[:label]
        assert_not_include node[:label], '.files/', node[:label]
        assert_not_include node[:label], 'agent.society', node[:label]
      end
    end
  end

  test 'T11 tooltips carry full paths, labels carry none' do
    TmpFile.with_dir do |dir|
      root, jobs, society = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, = parse_dot(dot)
      assert_equal 15, nodes.length, dot
      nodes.each_value do |node|
        assert node[:tooltip]&.include?('/'), node.inspect
        assert_not_include node[:label], dir, node[:label]
        assert_not_include node[:label], '.files/', node[:label]
        assert_not_include node[:label], 'agent.society', node[:label]
        next unless node[:label].include?('/')
        assert_match(/\A(?:[^"\/]|\\.)*\/(?:[^"\/]|\\.)*\z/m, node[:label], node[:label])
      end
      # every fixture node (root, jobs, produced chats, society chats) has
      # its own node with its own tooltip
      expected = [root, jobs[:echo], jobs[:unknown], jobs[:bad], *jobs[:smoke],
                  *society,
                  *[jobs[:echo], jobs[:unknown], *jobs[:smoke]].collect { |j| File.join(j + '.files', 'Worker.chat') }]
      tooltips = nodes.values.collect { |node| node[:tooltip] }
      expected.each { |path| assert_include tooltips, path }
    end
  end

  test 'T12 render: --timeline svg produces a renderable document' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      svg_file = File.join(dir, 'timeline.svg')
      out, err, status = prov('--timeline', svg_file, root)
      assert status.success?, err
      assert File.file?(svg_file), out
      svg = File.read(svg_file)
      assert svg.start_with?('<?xml'), svg[0, 100]
      assert_operator svg.scan(/<title>/).length, :>=, 15, svg[0, 400]
    end
  end

  test 'T13 budgets: no rank=same, bounded natural width' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      svg_file = File.join(dir, 'timeline.svg')
      prov('--timeline', svg_file, root)
      skip 'graphviz dot not installed' unless Open.exists?('/usr/bin/dot')
      svg = File.read(svg_file)
      width = svg[/width="([\d.]+)pt"/, 1].to_f
      assert_operator width, :<=, 900, "natural width #{width}pt too wide for a single column"
      height = svg[/height="([\d.]+)pt"/, 1].to_f
      assert_operator height, :>, 200, height
    end
  end

  test 'T14 census: exact node/edge class census' do
    TmpFile.with_dir do |dir|
      root, jobs, society, schedule = explanatory_fixture(dir)
      dot, = timeline_for(root)
      nodes, edges = parse_dot(dot)
      # node class census, counted by parsing the class attribute rather
      # than by substring so prov-overlap flags do not double-count
      classes = nodes.values.collect { |node| node[:attrs][/class="([^"]*)"/, 1] }
      assert_equal 15, nodes.length, dot
      assert_equal 6, classes.count { |c| c.include?('prov-job') }, classes.inspect
      assert_equal 1, classes.count { |c| c.include?('prov-error') }, classes.inspect
      assert_equal 1, classes.count { |c| c.include?('prov-root') }, classes.inspect
      assert_equal 3, classes.count { |c| c.include?('prov-society') }, classes.inspect
      assert_equal 5, classes.count { |c| c.include?('prov-chat') && !c.include?('prov-society') }, classes.inspect
      # label census: only continues arcs carry labels
      assert_equal 2, dot.scan(/label="continues"/).length, dot
      assert_equal 0, dot.scan(/label="delegates"/).length, dot
      assert_equal 0, dot.scan(/label="produces"/).length, dot
      assert_equal 0, dot.scan(/label="result"/).length, dot
      # spine census: 14 consecutive pairs, one constraint=true each
      ordered, time_by_path = expected_sequence(root, jobs, society, schedule)
      assert_equal ordered.length - 1, edges.count { |_f, _t, a| a.include?('constraint=true') }, dot
      # synthetic spine segments carry the timeline class
      synthetic = dot.scan(/class="timeline"/).length
      assert_operator synthetic, :>=, 1, dot
      # overlap flags recomputed from the same time keys the CLI uses
      # (job key = its chat interval, chat node key = its own interval,
      # fallback nodes are points); [start,end) pairwise overlap.
      expected_overlap = ordered.select do |path|
        span = time_by_path[path]
        ordered.any? do |other|
          next false if other == path
          other_span = time_by_path[other]
          span.first < other_span.last && other_span.first < span.last
        end
      end
      flagged = nodes.count { |_id, node| node[:attrs].include?('prov-overlap') }
      assert_equal expected_overlap.length, flagged,
                   "expected #{expected_overlap.collect { |p| File.basename(p) }.inspect}" 
    end
  end
end
