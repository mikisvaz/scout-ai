require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')

require 'scout/network/paths'

class TestNetworkPaths < Test::Unit::TestCase
  def test_breadth_first_distances
    adjacency = {
      'A' => %w[B C],
      'B' => %w[D],
      'C' => %w[D E],
      'D' => %w[F],
      'E' => [],
      'F' => []
    }

    distances = Paths.breadth_first(adjacency, 'A', 2)

    assert_equal 0, distances['A']
    assert_equal 1, distances['B']
    assert_equal 1, distances['C']
    assert_equal 2, distances['D']
    assert_equal 2, distances['E']
    # F should not be reached within 2 steps
    assert_nil distances['F']
  end

  def test_neighborhood_from_single_source
    adjacency = {
      'A' => %w[B C],
      'B' => %w[D],
      'C' => %w[D E],
      'D' => %w[F],
      'E' => [],
      'F' => []
    }

    neigh = Paths.neighborhood(adjacency, 'A', 2)

    # Order is not guaranteed; compare as sets
    assert_equal %w[A B C D E].sort, neigh.sort
  end

  def test_neighborhood_from_multiple_sources
    adjacency = {
      'A' => %w[B],
      'B' => %w[C],
      'X' => %w[Y],
      'Y' => %w[Z]
    }

    neigh = Paths.neighborhood(adjacency, %w[A X], 1)

    assert_equal %w[A B X Y].sort, neigh.sort
  end
end
