require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/embed'

class TestLLMRAG < Test::Unit::TestCase
  def test_rag
    text1 =<<-EOF
Crime, Killing and Theft.
    EOF
    text2 =<<-EOF
Murder, felony and violence
    EOF
    text3 =<<-EOF
Puppies, cats and flowers
    EOF

    data = [ LLM.embed(text1),
             LLM.embed(text2),
             LLM.embed(text3)]

    i = LLM::RAG.index(data)

    # ScoutCoder: the mock embedding is a bag-of-words hash, so nearest
    # neighbour assertions have to be built from literal word overlap
    # ('violence' ties crime/murder texts, 'flowers' is unique to pets).
    nodes, scores = i.search_knn LLM.embed('Puppies, cats and flowers'), 1
    assert_equal 2, nodes.first

    nodes, scores = i.search_knn LLM.embed('Murder and violence'), 2
    assert_include nodes.sort, 1
    assert_false nodes.sort.first == 2

    # deterministic: same text always the same vector
    assert_equal data.first, LLM.embed(text1)
  end

  def test_rag_insity
    text1 =<<-EOF
Crime, Killing and Theft.
    EOF
    text2 =<<-EOF
Murder, felony and violence
    EOF
    text3 =<<-EOF
Puppies, cats and flowers
    EOF

    LLM::RAG.top([text1, text2, text3], 2)

    data = [ LLM.embed(text1),
             LLM.embed(text2),
             LLM.embed(text3)]

    i = LLM::RAG.index(data)
    nodes, scores = i.search_knn LLM.embed('Puppies, cats and flowers'), 1
    assert_equal 2, nodes.first

    nodes, scores = i.search_knn LLM.embed('Murder and violence'), 2
    assert_include nodes.sort, 1
    assert_false nodes.sort.first == 2
  end
end

