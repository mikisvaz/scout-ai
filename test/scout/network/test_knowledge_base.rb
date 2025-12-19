require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')

class TestKnowledgeBaseRadialExpand < Test::Unit::TestCase
  def test_radial_expand_outward
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      visited, edges = kb.radial_expand(:brothers, seeds, depth: 1, direction: :out)

      # At depth 1 from Miki in an undirected brothers db we expect at least Isa
      assert_include visited, "Miki"
      assert_include visited, "Isa"
      assert edges.any? { |e| [e.source, e.target].sort == %w[Isa Miki].sort }
    end
  end

  def test_radial_expand_filter
    TmpFile.with_dir do |dir|
      kb = KnowledgeBase.new dir
      kb.register :brothers, datafile_test(:person).brothers, undirected: true

      seeds = ["Miki"]
      # Filter that rejects all edges
      visited, edges = kb.radial_expand(:brothers, seeds, depth: 1, direction: :out, filter: ->(item){ false })

      # Only the seed should be visited and no edges kept
      assert_equal ["Miki"], visited
      assert_equal [], edges
    end
  end
end
