# KnowledgeBase Tools

A Scout **KnowledgeBase** is an association-graph database: it stores
relationships between entities (gene→protein, drug→disease, user→product)
along with optional field values per association. Scout-AI can expose each
database in a KnowledgeBase as LLM-callable tools, letting the model query
real data during inference.

This document covers:

- How KnowledgeBases become agent tools
- `LLM.knowledge_base_tool_definition`
- `LLM.knowledge_base_ask` (convenience helper)
- Chat-file roles: `kb:` and `association:`
- How KB tools dispatch via `LLM.call_knowledge_base`
- **RAG (Retrieval-Augmented Generation)** — the full content from the existing
  RAG documentation, preserved verbatim

For the general tools system (registry shape, dispatcher, output limits), see
[Tools.md](Tools.md). For how agents auto-wire KB tools, see
[../Agent/Agent.md](../Agent/Agent.md).

---

## 1. How KnowledgeBases become tools

Each database in a KnowledgeBase produces up to **two tools**:

| Tool | Generated when | Purpose |
|---|---|---|
| `<database_name>` | Always | Find associations for a list of entities |
| `<database_name>_association_details` | Database has fields | Retrieve field values for specific associations |

### 1.1 Association lookup tool

For a **directed** database (`source → target`):

```ruby
{
  name: "gene_protein",
  description: "Find associations for a list of entities in database gene_protein.
               Returns a list in the format source~target.",
  parameters: {
    type: "object",
    properties: {
      entities: {
        type: "array", items: { type: :string },
        description: 'Source entities, or targets if "reverse" is "true"'
      },
      reverse: {
        type: "boolean",
        description: 'Look for targets instead of sources, defaults to "false"'
      }
    },
    required: ["entities"]
  }
}
```

For an **undirected** database, the `reverse` parameter is omitted, and the
description uses `entity~partner` format.

### 1.2 Association details tool

Only generated when the database has fields. For **multiple fields**:

```ruby
{
  name: "gene_protein_association_details",
  description: "Return details of association as a dictionary object. ...
               The fields are: source, target, score.",
  parameters: {
    type: "object",
    properties: {
      associations: { type: "array", items: { type: :string } },
      fields: { type: "array", items: { type: :string },
                description: "Limit the response to these fields" }
    },
    required: ["associations"]
  }
}
```

For a **single field**, the `fields` parameter is omitted, and the description
mentions the specific field name.

---

## 2. `LLM.knowledge_base_tool_definition`

**Signature:**

```ruby
LLM.knowledge_base_tool_definition(knowledge_base, databases = nil)
```

Builds the tool registry (`{ name => [executor, definition] }`) from a
KnowledgeBase.

- If `databases` is `nil`, all databases in the KB are used.
- Each database's executor slot holds the `KnowledgeBase` object itself, so
  `LLM.call_knowledge_base` can dispatch queries.
- The definition is stored in the provider-nested format
  (`{ type: 'function', function: { ... } }`), which `format_tool_definitions`
  normalises per backend.

```ruby
kb = KnowledgeBase.load('/path/to/kb')
tools = LLM.knowledge_base_tool_definition(kb)
# => {
#      "gene_protein" => [kb, { type: 'function', function: { name: ..., ... } }],
#      "gene_protein_association_details" => [kb, { name: ..., ... }]
#    }
```

---

## 3. `LLM.call_knowledge_base` — dispatch

When the model calls a KB tool, `LLM.process_calls` dispatches to
`LLM.call_knowledge_base`:

**Signature:**

```ruby
LLM.call_knowledge_base(knowledge_base, database, parameters = {})
```

### 3.1 Association lookup (no `_association_details` suffix)

```ruby
entities, reverse = parameters[:entities], parameters[:reverse]

if reverse
  knowledge_base.parents(database, entities)  # target → source
else
  knowledge_base.children(database, entities)  # source → target
end
```

Returns a list of associations in `source~target` format.

### 3.2 Association details (`_association_details` suffix)

```ruby
# Strip suffix
database = database.sub('_association_details', '')

index = knowledge_base.get_index(database)

if fields
  field_pos = fields.collect { |f| index.identify_field(f) }
  associations.each_with_object({}) do |a, hash|
    hash[a] = index[a].values_at(*field_pos)
  end
else
  associations.each_with_object({}) do |a, hash|
    hash[a] = index[a].to_hash
  end
end
```

Returns a Hash mapping each association to its field values.

---

## 4. `LLM.knowledge_base_ask` — convenience helper

> Originally documented in the legacy `LLM.md` §6.2; now canonical in this document.

```ruby
LLM.knowledge_base_ask(knowledge_base, question, options = {})
```

```ruby
def self.knowledge_base_ask(knowledge_base, question, options = {})
  knowledge_base_tools = LLM.knowledge_base_tool_definition(knowledge_base)
  self.ask(question, options.merge(tools: knowledge_base_tools)) do |task_name, parameters|
    parameters = IndiferentHash.setup(parameters)
    database, entities = parameters.values_at "database", "entities"
    knowledge_base.children(database, entities).collect { |e| e.sub('~', '=>') }
  end
end
```

Example:

```ruby
kb = KnowledgeBase.load('/data/gene_kb')
LLM.knowledge_base_ask(kb, "What proteins are associated with gene BRCA1?", endpoint: :nano)
```

---

## 5. Chat-file roles

### 5.1 `kb:` — load a KnowledgeBase and expose its databases

```text
kb: /path/to/gene_kb
```

Or with specific databases:

```text
kb: /path/to/gene_kb gene_protein drug_disease
```

Processed by `Chat.tools()`:

1. Loads the KB via `KnowledgeBase.load`.
2. If the KB has no databases, attempts to load an agent of the same name and
   use its KB.
3. Generates tool definitions and merges them into the registry.
4. The `kb:` message is **consumed** (removed from the message array).

### 5.2 `association:` — register a TSV file as an ad-hoc database

```text
association: brothers /data/brothers.tsv undirected=true
```

Or with fields and type:

```text
association: gene_protein /data/gp.tsv fields=source,target,score type=double
```

Processed by `Chat.associations()`:

1. Creates or reuses a KnowledgeBase (stored at `Scout.var.Agent.Chat.knowledge_base`).
2. Registers the TSV file as a database with the provided options.
3. Generates tool definitions for the new database.
4. The `association:` message is **consumed**.

Options parsed from the content string:

| Option | Example | Effect |
|---|---|---|
| `fields=` | `fields=source,target` | Comma-separated field names |
| `type=` | `type=double` | Value type for the database |
| `undirected=true` | `undirected=true` | Treat as undirected (omits `reverse` param) |

### 5.3 Clearing tools

```text
clear_tools:
```

Removes all tool definitions (including KB tools).

```text
clear_associations:
```

Removes only association-registered tools (from `association:` roles).

---

## 6. How KB tools work during inference

The model can call KB tools in sequence to build up an answer:

```
User: "What proteins does BRCA1 interact with, and what are their scores?"

Model turn 1:
  tool_call("gene_protein", { entities: ["BRCA1"] })
  → ["BRCA1~BRCA2", "BRCA1~PALB2", "BRCA1~RAD51"]

Model turn 2:
  tool_call("gene_protein_association_details", {
    associations: ["BRCA1~BRCA2", "BRCA1~PALB2", "BRCA1~RAD51"]
  })
  → { "BRCA1~BRCA2" => [9.8], "BRCA1~PALB2" => [8.5], "BRCA1~RAD51" => [7.2] }

Model turn 3:
  "BRCA1 interacts with BRCA2 (score 9.8), PALB2 (8.5), and RAD51 (7.2)."
```

The `chain_tools` loop (see [../Backends/Backends.md](../Backends/Backends.md))
handles the multi-turn tool calling automatically.

---

## 7. Practical examples

### 7.1 Programmatic KB tools

```ruby
kb = KnowledgeBase.load('/data/gene_kb')
tools = LLM.knowledge_base_tool_definition(kb)

LLM.ask("What proteins does BRCA1 interact with?",
        tools: tools, endpoint: :nano)
```

### 7.2 Specific databases only

```ruby
tools = LLM.knowledge_base_tool_definition(kb, ['gene_protein'])
```

### 7.3 Using the convenience helper

```ruby
LLM.knowledge_base_ask(kb, "Who are John's brothers?", endpoint: :nano)
```

### 7.4 Chat file with `kb:` role

```text
kb: /data/gene_kb gene_protein

user:

What proteins does BRCA1 interact with?
```

### 7.5 Chat file with `association:` role

```text
association: brothers /data/brothers.tsv undirected=true

user:

Who is John's brother?
```

### 7.6 Ad-hoc KB with fields

```text
association: scores /data/scores.tsv fields=name,score type=double

user:

What is the score for Alice?
```

---

## 8. RAG (Retrieval-Augmented Generation)

> Originally documented in the legacy `doc/RAG.md`; now incorporated here.

### 8.1 Overview

`LLM::RAG` provides a thin helper to build a nearest-neighbor index over
embedding vectors using the `hnswlib` library. It expects an array of
fixed-size numeric vectors (Float arrays) and returns an HNSW index that can be
queried with another vector to find the nearest neighbors.

The `RAG.index` method is intentionally small and focused:

- It requires the `hnswlib` Ruby gem at runtime (loaded inside the method).
- It uses L2 (Euclidean) distance by default.
- It sets the index dimension to the length of the first vector and initializes
  the HNSW index with the number of elements supplied.
- Each vector is added in order; the integer ID stored in the index is the
  zero-based position in the input array.

### 8.2 Prerequisites

- Ruby environment with the Scout gem code available.
- The `hnswlib` Ruby gem installed (the method requires it dynamically):

  ```bash
  gem install hnswlib
  ```

- An embedding function that produces fixed-length numeric vectors. Scout
  exposes `LLM.embed(...)` which delegates to configured backends (OpenAI,
  Ollama, etc.). Ensure your embedding backend is configured and working.

### 8.3 The embedding flow (`LLM.embed`)

`LLM.embed(text, options)` computes an embedding vector for a given text:

```ruby
vec = LLM.embed("Hello world", model: 'mxbai-embed-large')
# => [0.0123, -0.0456, 0.0789, ...]  (Array<Float>)
```

It delegates to the configured backend's embedding endpoint. The `model:`
option selects the embedding model.

### 8.4 End-to-end RAG example

This example shows a minimal end-to-end flow using Scout's `LLM.embed` helper
to compute embeddings and `LLM::RAG` to build and query an index.

```ruby
# `documents` is an array of strings (documents/chunks).
documents = [
  "How to make espresso at home",
  "Machine learning: an introduction",
  "Ruby concurrency primitives and patterns",
  "Cooking guide: baking sourdough"
]

# 1) Compute embeddings for each document.
embeddings = documents.map do |doc|
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

### 8.5 Notes and best practices

- **Vector dimensionality:** All vectors passed to `LLM::RAG.index` must have
  identical length. The code inspects `data.first.length` to determine the
  index dimension.
- **Index IDs:** The HNSW index stores integer IDs equal to the input array
  index. Keep a mapping from those indices to your document IDs/metadata (for
  instance, an array of document IDs parallel to the embeddings array).
- **Persistence:** The RAG helper code only constructs and populates the index
  in memory. The underlying `hnswlib` gem typically offers persistence APIs
  (save/load). To persist or reload an index, consult the `hnswlib` gem
  documentation for the correct methods and usage patterns.
- **Memory and performance:** HNSW indexes keep data in memory and can be
  large for many vectors. Choose your chunking strategy and max dataset size
  accordingly.
- **Distance metric:** The current implementation uses the `'l2'` (Euclidean)
  space. If your application needs cosine similarity, either normalize vectors
  before indexing (common practice) or check whether the `hnswlib` Ruby binding
  supports a cosine space and adapt accordingly.

### 8.6 Utility wrapper

Here is a small utility that wraps the typical pattern and returns the top-k
documents and scores for a query.

```ruby
def build_rag_index(documents, embed_opts = {})
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

### 8.7 Troubleshooting

- **"NoMethodError" or "uninitialized constant Hnswlib":** ensure the `hnswlib`
  gem is installed and available to your Ruby runtime.
- **Inconsistent dimensions:** If you see errors related to dimension mismatch,
  confirm every embedding vector has the same length and is numeric.
- **Mapping errors:** Remember the index IDs correspond to the zero-based
  position in the `data` array passed to `LLM::RAG.index`. Keep a parallel
  array or map to metadata (IDs, titles, etc.).

### 8.8 Further integration

- **Chunking:** Split long documents into smaller passages, embed each passage,
  and keep a mapping from passage index to parent document.
- **Reranking:** After retrieval, rerank retrieved documents with more
  expensive cross-encoders or scoring functions.
- **Combine with generative models:** Feed retrieved passages into an LLM
  prompt to produce answers grounded in retrieved content.

---

## 9. Cross-references

- [Tools.md](Tools.md) — the unified tool registry, `process_calls` dispatcher
- [../Backends/Backends.md](../Backends/Backends.md) — `chain_tools` loop
- [../Chat/Chat.md](../Chat/Chat.md) — chat-file roles (`kb:`, `association:`)
- [../Agent/Agent.md](../Agent/Agent.md) — how agents auto-wire KB tools
