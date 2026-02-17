module LLM
  class RAG
    def self.index(data)
      require 'hnswlib'

      dim = data.first.length
      t = Hnswlib::HierarchicalNSW.new(space: 'l2', dim: dim)
      t.init_index(max_elements: data.length)

      data.each_with_index do |vector,i|
        t.add_point vector, i
      end
      t
    end

    def self.load(path, dim)
      require 'hnswlib'

      u = Hnswlib::HierarchicalNSW.new(space: 'l2', dim: dim)
      u.load_index(path)

      u
    end

    def self.top(texts, prompt, num = 10)
      data = texts.collect{|text| LLM.embed(text) }

      i = LLM::RAG.index(data)
      pos, scores = i.search_knn LLM.embed(prompt), num

      texts.values_at *pos.reverse
    end
  end
end
