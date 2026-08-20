require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/embed'

class TestLLMEmbed < Test::Unit::TestCase
  def test_embed_deterministic_fixed_dimension
    # ScoutCoder: the default embed backend for tests is the registered
    # LLM::Mock backend (Scout::Config.set({backend: :mock}, :embed, :llm) in
    # test_helper), so LLM.embed resolves through the LLM::BACKENDS registry
    # fallback and never touches the network.
    v1 = LLM.embed('a text')
    v2 = LLM.embed('a text')

    assert_instance_of Array, v1
    assert_equal LLM::Mock::DIMENSIONS, v1.length
    assert v1.all? { |e| Float === e }
    assert_equal v1, v2
  end

  def test_embed_array_input
    vectors = LLM.embed(['one two', 'two three'])

    assert_equal 2, vectors.length
    assert_equal [LLM::Mock::DIMENSIONS, LLM::Mock::DIMENSIONS], vectors.collect(&:length)
    assert_equal LLM.embed('one two'), vectors.first
  end

  def test_embed_shared_words_closer
    # cosine similarity: texts sharing words must be closer than disjoint texts
    def cos(a, b)
      dot = a.zip(b).inject(0.0) { |acc, (x, y)| acc + x * y }
      na  = Math.sqrt(a.inject(0.0) { |acc, x| acc + x * x })
      nb  = Math.sqrt(b.inject(0.0) { |acc, x| acc + x * x })
      dot / (na * nb)
    end

    shared  = LLM.embed('crime and theft')
    similar = LLM.embed('crime theft violence')
    other   = LLM.embed('puppies and flowers')

    assert cos(shared, similar) > cos(shared, other)
  end

  def test_embed_explicit_backend
    assert_equal LLM::Mock.embed('a text'), LLM.embed('a text', backend: :mock)
  end
end
