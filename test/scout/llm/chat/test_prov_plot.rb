require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/chat'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require_relative 'agent_meta_fixtures'
require_relative 'prov_plot_fixtures'

# Explanatory provenance plot tests (`--dot` / `--plot`).
#
# These are `scout-ai llm prov --dot` output tests, NOT dot-syntax tests:
# every assertion below runs against the dot source the CLI writes, so the
# assertions grep the CLI's own strings (label=, tooltip=, class=) and not a
# graphviz rendering (except the two graphviz runs, which skip when the dot
# binary is missing).
#
# The fixture is the explanatory mirror (root chat, 6 delegated
# Cortex/continue jobs, one continuation chain of 3, one error job, 3
# society chats); see ProvPlotFixtures#explanatory_fixture.
class TestProvExplanatoryPlot < Test::Unit::TestCase
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

  def dot_for(root)
    @prov_count += 1
    dot_file = File.join(@dir, "prov_#{@prov_count}.dot")
    out, err, status = prov('--dot', dot_file, root)
    assert status.success?, err
    [File.read(dot_file), out]
  end

  setup do
    @prov_count = 0
    @dir = Dir.mktmpdir('prov-plot')
  end

  teardown do
    FileUtils.remove_entry @dir if @dir && File.directory?(@dir)
  end

  test 'labels carry names, paths only in tooltips' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      node_lines = dot.lines.grep(/^\s+n\d+ \[/)
      labels = node_lines.flat_map { |l| l.scan(/label=("(?:[^"\\]|\\.)*")/) }
      assert_equal 15, node_lines.length, dot
      assert labels.length >= 15, dot
      # Packet item 1 vs item 8 tension, resolved narrowly: the jobname
      # label itself is `Cortex/continue <name>`, whose slash is the
      # workflow/task separator required by the legacy jobname tests, not
      # a filesystem path.  A NAME such as the basename `Worker.chat` is
      # legitimate label content.  What must NOT appear is any path: the
      # fixture dir, a `.files/` or `agent.society` fragment, or a second
      # slash beyond the one workflow/task separator.
      labels.each do |label|
        assert_not_include label, dir, "label leaks the fixture dir: #{label}"
        assert_not_include label, '.files/', "label leaks a files dir: #{label}"
        assert_not_include label, 'agent.society', "label leaks a society path: #{label}"
        next unless label.include?('/')
        assert_match(/\A"(?:[^"\/]|\\.)*\/(?:[^"\/]|\\.)*"\z/, label,
                     "label carries more than the workflow/task slash: #{label}")
      end
      tooltips = dot.scan(/tooltip=("(?:[^"\\]|\\.)*")/).flatten
      assert_equal labels.length, tooltips.length
      tooltips.each { |t| assert t.include?('/'), "tooltip without full path: #{t}" }
    end
  end

  test 'root tooltip is the chat, root label names the kind' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      root_line = dot.lines.find { |l| l.include?("tooltip=#{root.inspect}") }
      assert root_line, dot
      assert_include root_line, 'Root conversation'
      assert_include root_line, 'root.chat'
      assert_match(/\{rank=source; n\d+;\}/, dot)
      # the rank=source id must be the root node id
      root_id = root_line[/^\s*(n\d+) \[/, 1]
      assert dot.include?("{rank=source; #{root_id};}"), dot
    end
  end

  test 'worker chat tooltips show the files dir' do
    TmpFile.with_dir do |dir|
      root, jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      first_turn = jobs[:smoke][0]
      worker = File.join(first_turn + '.files', 'Worker.chat')
      assert_include dot, "tooltip=#{worker.inspect}"
    end
  end

  test 'semantic edge labels replace machine relations' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      assert_equal 6, dot.scan(/label="delegates"/).length, dot
      assert_equal 5, dot.scan(/label="produces"/).length, dot
      assert_equal 2, dot.scan(/label="continues"/).length, dot
      # machine relation tokens survive only as class attributes
      %w[delegated_result dependency].each do |token|
        assert_not_include dot, %(label="#{token}")
        assert dot.include?(%(class="#{token}")), dot
      end
    end
  end

  test 'continuation chain arcs follow mtime order' do
    TmpFile.with_dir do |dir|
      root, jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      id_of = {}
      dot.lines.each do |line|
        next unless line =~ /^\s*(n\d+) \[.*tooltip=("(?:[^"\\]|\\.)*")/
        id_of[JSON.parse(Regexp.last_match(2))] = Regexp.last_match(1)
      end
      turn1, turn2, turn3 = jobs[:smoke]
      assert_equal 2, dot.scan(/constraint=false, tailport=s, headport=n/).length, dot
      assert dot.include?("#{id_of[turn1]} -> #{id_of[turn2]} [label=\"continues\""), dot
      assert dot.include?("#{id_of[turn2]} -> #{id_of[turn3]} [label=\"continues\""), dot
      # turn numbering is visible on the smoke labels
      assert_include dot, 'cortex-smoke · turn 1'
      assert_include dot, 'cortex-smoke · turn 2'
      assert_include dot, 'cortex-smoke · turn 3'
    end
  end

  test 'error outcome replaces token line' do
    TmpFile.with_dir do |dir|
      root, jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      bad_line = dot.lines.find { |l| l.include?("tooltip=#{jobs[:bad].inspect}") }
      assert bad_line, dot
      assert_include bad_line, '⚠ error'
      assert_not_include bad_line, 'tokens'
      assert_include bad_line, '#FBE3E3'
      assert_include bad_line, 'prov-error'
    end
  end

  test 'society chats keep pair labels with dashed unlabeled edges' do
    TmpFile.with_dir do |dir|
      root, _jobs, society = explanatory_fixture(dir)
      dot, = dot_for(root)
      society.each do |chat|
        line = dot.lines.find { |l| l.include?("tooltip=#{chat.inspect}") }
        assert line, "#{chat}\n#{dot}"
        pair = chat.split(File::SEPARATOR)[-3, 2] * '/'
        assert_include line, "society #{pair}"
      end
      dashed = dot.lines.select { |l| l.include?('style=dashed') }
      assert_equal 3, dashed.length, dot
      dashed.each { |l| assert_not_include l, 'label=' }
    end
  end

  test 'legacy shape contract and jobname labels survive' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      dot, = dot_for(root)
      shapes = dot.scan(/^\s+n\d+ \[shape=(\w+)/).flatten
      assert shapes.all? { |shape| %w[box note].include?(shape) }, dot
      assert_equal 15, shapes.length, dot
      assert_include dot, 'Cortex/continue echo-worker'
      assert_include dot, 'Cortex/continue cortex-unknown-brief'
    end
  end

  test 'graphviz renders the dot without error' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      dot_file = File.join(dir, 'prov.dot')
      prov('--dot', dot_file, root)
      skip 'graphviz dot not installed' unless Open.exists?('/usr/bin/dot')
      out, err, status = Open3.capture3('dot', '-Tsvg', dot_file)
      assert status.success?, err
      assert out.start_with?('<?xml'), out[0, 100]
      titles = out.scan(/<title>/).length
      assert titles >= 15, out
    end
  end

  test 'plot writes an svg of bounded natural width' do
    TmpFile.with_dir do |dir|
      root, _jobs, _society = explanatory_fixture(dir)
      plot_file = File.join(dir, 'prov.svg')
      out, err, status = prov('--plot', plot_file, root)
      assert status.success?, err
      assert File.file?(plot_file), out
      svg = File.read(plot_file)
      width = svg[/width="([\d.]+)pt"/, 1].to_f
      assert width > 0, svg[0, 200]
      assert_operator width, :<=, 1200, "natural width #{width}pt too wide"
    end
  end
end
