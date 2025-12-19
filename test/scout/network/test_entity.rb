require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')

require 'scout/network/entity'
require 'scout/knowledge_base'

class TestNetworkEntityAssociationItem < Test::Unit::TestCase
  def build_pairs
    kb = KnowledgeBase.new tmpdir
    kb.register :brothers, datafile_test(:person).brothers, undirected: true
    kb.all(:brothers)
  end

  def test_components
    pairs = build_pairs
    comps = AssociationItem.components(pairs)
    # All nodes from brothers should appear in a single component for this tiny graph
    flat = comps.flatten
    %w[Miki Isa Clei Guille].each do |name|
      assert_include flat, name
    end
    assert_equal 2, comps.length
  end

  def test_degrees
    pairs = build_pairs
    deg   = AssociationItem.degrees(pairs)
    # In brothers example, Miki and Isa each connected to at least one
    assert deg['Miki'] > 0
    assert deg['Isa']  > 0
  end

  def test_subset_by_nodes
    pairs = build_pairs
    sub   = AssociationItem.subset_by_nodes(pairs, %w[Miki Isa])
    assert sub.any? { |e| [e.source, e.target].sort == %w[Isa Miki].sort }
    # Edges involving others should be filtered out
    refute sub.any? { |e| (e.source == 'Clei') || (e.target == 'Clei') }
  end

  def test_neighborhood_inside_subgraph
    pairs = build_pairs
    neigh = AssociationItem.neighborhood(pairs, 'Miki', 1)
    assert_include neigh, 'Miki'
    assert_include neigh, 'Isa'
  end
end
