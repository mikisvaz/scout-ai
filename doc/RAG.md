# RAG (Retrieval-Augmented Generation) module

This document explains how to use the RAG helper provided in Scout (lib/scout/llm/rag.rb).

Audience: AI agents and developers integrating retrieval-augmented flows into other applications.

Overview
--------
LLM::RAG provides a thin helper to build a nearest-neighbor index over embedding vectors using the hnswlib library. It expects an array of fixed-size numeric vectors (Float arrays) and returns an HNSW index that can be queried with another vector to find the nearest neighbors.

The RAG.index method is intentionally small and focused:

- It requires the `hnswlib` Ruby gem at runtime (loaded inside the method).
- It uses L2 (Euclidean) distance by default.
- It sets the index dimension to the length of the first vector and initializes the HNSW index with the number of elements supplied.
- Each vector is added in order; the integer ID stored in the index is the zero-based position in the input array.

Prerequisites
-------------
- Ruby environment with the Scout gem code available.
- The `hnswlib` Ruby gem installed (the method requires it dynamically):

  gem install hnswlib

- An embedding function that produces fixed-length numeric vectors. Scout exposes LLM.embed(...) which delegates to configured backends (OpenAI, Ollama, etc.). Ensure your embedding backend is configured and working.

Basic usage
-----------
The common RAG flow is:

1. Prepare a corpus (array of documents or chunks).
2. Compute embeddings for each document.
3. Build an HNSW index from those embeddings using LLM::RAG.index.
4. For a query, compute its embedding and run a nearest-neighbor search on the index.
5. Map matched neighbor indices back to the original documents.

Example (Ruby)
---------------
This example shows a minimal end-to-end flow using Scout's LLM.embed helper to compute embeddings and LLM::RAG to build and query an index.

```ruby
# `documents` is an array of strings (documents/chunks).
documents = [
  "How to make espresso at home",
  "Machine learning: an introduction",
  "Ruby concurrency primitives and patterns",
  "Cooking guide: baking sourdough"
]

# 1) Compute embeddings for each document.
#    Use whatever embed model/backend you have configured. Pass model: if needed.
embeddings = documents.map do |doc|
  # returns an Array<Float> of fixed length
  LLM.embed(doc, model: 'mxbai-embed-large')
end

# 2) Build the HNSW index
index = LLM::RAG.index(embeddings)

# 3) For a query, compute its embedding
query = "best way to brew espresso"
query_vec = LLM.embed(query, model: 'mxbai-embed-large')

# 4) Run nearest-neighbor search
#    search_knn returns two arrays: node indices and distances/scores
k = 3
nodes, scores = index.search_knn(query_vec, k)

# 5) Map indices back to original documents
results = nodes.map { |i| documents[i] }

puts "Top #{k} results:" 
results.each_with_index do |doc, idx|
  puts "#{idx + 1}. #{doc} (score=#{scores[idx]})"
end
```

Notes and best practices
------------------------
- Vector dimensionality: All vectors passed to LLM::RAG.index must have identical length. The code inspects `data.first.length` to determine the index dimension.
- Index IDs: The HNSW index stores integer IDs equal to the input array index. Keep a mapping from those indices to your document IDs/metadata (for instance, an array of document IDs parallel to the embeddings array).
- Persistence: The RAG helper code only constructs and populates the index in memory. The underlying `hnswlib` gem typically offers persistence APIs (save/load). To persist or reload an index, consult the `hnswlib` gem documentation for the correct methods and usage patterns.
- Memory and performance: HNSW indexes keep data in memory and can be large for many vectors. Choose your chunking strategy and max dataset size accordingly.
- Distance metric: The current implementation uses the `'l2'` (Euclidean) space. If your application needs cosine similarity, either normalize vectors before indexing (common practice) or check whether the hnswlib Ruby binding supports a cosine space and adapt accordingly.

Example: utility wrapper
------------------------
Here is a small utility that wraps the typical pattern and returns the top-k documents and scores for a query.

```ruby
# documents: Array of items (strings or objects). If objects, provide a `to_embedding_source` or pass a block to extract text.
# embed_opts: options forwarded to LLM.embed (e.g. model: ...)
def build_rag_index(documents, embed_opts = {})
  # compute embeddings in order
  embeddings = documents.map { |d| LLM.embed(d, embed_opts) }
  index = LLM::RAG.index(embeddings)
  [index, embeddings]
end

def rag_query(index, documents, query, k = 5, embed_opts = {})
  qvec = LLM.embed(query, embed_opts)
  nodes, scores = index.search_knn(qvec, k)
  results = nodes.map { |i| { doc: documents[i], score: scores[nodes.index(i)] } }
  results
end

# Usage:
# index, embs = build_rag_index(documents, model: 'mxbai-embed-large')
# top = rag_query(index, documents, 'how to make coffee', 3, model: 'mxbai-embed-large')
```

Troubleshooting
---------------
- "NoMethodError" or "uninitialized constant Hnswlib": ensure the `hnswlib` gem is installed and available to your Ruby runtime.
- Inconsistent dimensions: If you see errors related to dimension mismatch, confirm every embedding vector has the same length and is numeric.
- Mapping errors: Remember the index IDs correspond to the zero-based position in the `data` array passed to LLM::RAG.index. Keep a parallel array or map to metadata (IDs, titles, etc.).

Further integration
-------------------
- Use chunking for long documents: split long documents into smaller passages, embed each passage, and keep a mapping from passage index to parent document.
- Use result reranking: after retrieval, you can rerank retrieved documents with more expensive cross-encoders or scoring functions.
- Combine with generative models: feed retrieved passages into an LLM prompt to produce answers grounded in retrieved content.

References
----------
- lib/scout/llm/rag.rb (implementation)
- hnswlib Ruby gem (install and persistence documentation)
- Scout LLM embedding helpers (lib/scout/llm/embed.rb)

