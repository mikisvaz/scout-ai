require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')

require 'scout/network/knowledge_base'

class TestKnowledgeBaseRadialExpand < Test::Unit::TestCase
  def test_radial_expand_outward
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      visited, edges = kb.radial_expand(:brothers, seeds, depth: 1, direction: :out)

      assert_include visited, "Miki"
      assert_include visited, "Isa"
      assert edges.any? { |e| [e.source, e.target].sort == %w[Isa Miki].sort }
    end
  end

  def test_radial_layers
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      layers, _edges = kb.radial_layers(:brothers, seeds, depth: 2, direction: :out)

      # layers[0] should be seeds
      assert_equal [seeds], layers.first(1)
      # At least Isa should appear in layer 1
      assert_include layers[1], "Isa"
    end
  end

  def test_radial_expand_filter
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      visited, edges = kb.radial_expand(:brothers, seeds, depth: 1, direction: :out,
                                        filter: ->(item){ false })

      assert_equal ["Miki"], visited
      assert_equal [], edges
    end
  end

  def test_subgraph_around
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      edges = kb.subgraph_around(:brothers, seeds, depth: 1, direction: :out)

      assert edges.any? { |e| [e.source, e.target].sort == %w[Isa Miki].sort }
    end
  end
end
