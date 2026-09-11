# 07 - Embeddings, RAG, images and multimodal input

> Investigation, not normative documentation. This subsystem is almost
> entirely undocumented at user level (`doc/user/RunningInference.md` has no
> embeddings or images sections; `doc/user/Cookbook.md` has no RAG examples);
> the study below is the main record. Normative fragments:
> `doc/developer/Backends.md` capability bullets, `doc/user/ToolCalling.md`
> (knowledge-base tools).

## Scope

`lib/scout/llm/embed.rb` (`LLM.embed`), `lib/scout/llm/rag.rb` (`LLM::RAG`),
`lib/scout/llm/image.rb` (`LLM.image`), the embed/image methods of the
backends, multimodal message assembly (the `image`/`pdf` chat roles,
`Chat.find_file`, `format_other`, `encode_image`/`encode_pdf`), the agent
`attach` tool, and the knowledge-base/RAG seam.

## Verified behavior

### `LLM.embed`

- Signature `LLM.embed(text, options = {})` -> Array of Floats; Array text ->
  Array of vectors when the backend batches (Mock and Ollama do; Bedrock does
  not).
- Resolution: `options[:endpoint]` else
  `Scout::Config.get(:endpoint, :embed, :llm, env: 'EMBED_ENDPOINT,LLM_ENDPOINT',
  default: :embed)`; when an endpoint is set and
  `Scout.etc.AI[endpoint].find_with_extension(:yaml)` exists, that yaml is
  merged into the options. A missing *requested* endpoint (options / env /
  config) raises `"Endpoint not found <name>"`, like ask/image; the
  synthesized `:embed` fallback name never raises but is still merged if an
  `etc/AI/embed.yaml` exists.
- Backend: `options[:backend]` else
  `Scout::Config.get(:backend, :embed, :llm, env: 'EMBED_BACKEND,LLM_BACKEND',
  default: :embed)`. Dispatch: `:openai` and `:responses` -> `LLM::OpenAI.embed`;
  `:ollama`, `:openwebui`, `:huggingface`, `:relay`; else the
  `LLM::BACKENDS` registry, else `RuntimeError: Unknown backend: <name>`.
- **No caching** - embed.rb contains no `Persist` call; every call hits the
  backend (contrast `LLM.ask` and `LLM.image`). **No agent branch** either
  (unlike image/ask).
- Out of the box, with no config at all: endpoint `:embed`, backend `:embed`
  -> registry miss -> `RuntimeError: Unknown backend: embed`. `LLM.embed`
  needs an endpoint yaml, an explicit `backend:`, or a registered backend.

Per-backend implementations:

| backend | implementation | status |
|---|---|---|
| OpenAI (`openai`, `responses`) | `ClassMethods#embed` -> `prepare_client` -> `embed_query`: `parameters[:text] = text; client.embeddings(parameters:)`, returns `response.dig('data',0,'embedding')` | usable; Array text passes through verbatim (provider-dependent) |
| Ollama | own `embed_query`: `client.request('api/embed', {input: text})`; Array -> all embeddings, String -> first | usable |
| OpenWebUI | no `embed` of its own; `client` returns a plain Hash, so `ClassMethods#embed` -> `client.embeddings` -> NoMethodError | broken branch |
| Huggingface | own `embed`: builds a local `CausalModel` with `task: 'Embedding'` and calls `model.eval`/`eval_list` | local PyTorch eval wrapper; the task string is never translated, so whether it yields embeddings depends entirely on the checkpoint |
| Relay | dispatch branch exists but `LLM::Relay` defines no `embed` | dead branch |
| Bedrock | `LLM::Bedrock.embed` exists (`invoke_model` on the model id from `:bedrock_embed/:embed/:bedrock` config, env `BEDROCK_EMBED_MODEL_ID`, default `amazon.titan-embed-text-v1`; body `{inputText:}`; single text only) | implemented but **unreachable from dispatch** - only by direct call |
| Anthropic | `embed_query` raises `'Anthropic does not offer embeddings'`; no dispatch branch | unreachable |
| Mock (test) | deterministic bag-of-words hash: each word `word.sum % 64` counted, L2-normalized | identical texts -> identical vectors; shared words -> cosine-near |

### `LLM::RAG`

- `LLM::RAG.index(vectors)` -> `require 'hnswlib'`; `HierarchicalNSW` with
  `space: 'l2'`, `dim = data.first.length`, `init_index(max_elements:
  data.length)`; `add_point` per vector. No persistence - the index lives in
  memory; `LLM::RAG.load(path, dim)` rehydrates via `load_index`.
- `LLM::RAG.top(texts, prompt, num = 10, ...)` embeds every text
  (`LLM.embed(text, ...)` - Ruby 3 `...` forwarding, so any embed option
  passes through), indexes, `search_knn`s the embedded prompt and returns
  `texts.values_at(*pos.reverse)`.
- **Ordering quirk**: `search_knn` returns node ids ascending with distance
  (best match *last*); `pos.reverse` makes `RAG.top` return most-relevant
  first. `scores` are unnormalized L2 distances in far-to-near order.
- `rag.rb` is the **only** `LLM.embed` consumer inside `lib/` - RAG is the
  framework's only embedding consumer.

### `LLM.image`

- Signature `LLM.image(question, options = {}, &block)`; `messages =
  LLM.chat(question)`; options = `LLM.options(messages)` + the given options.
- Endpoint resolution mirrors ask: `find_with_extension(:yaml)` merge plus
  `"Endpoint not found <name>"` for a non-empty unknown endpoint (env chain
  `IMAGE_ENDPOINT,ASK_ENDPOINT,LLM_ENDPOINT,ENDPOINT,LLM,ASK,IMAGE`).
- **Agent branch**: `options[:agent]` (none/false/nil disabled) ->
  `LLM::Agent.load_agent(agent).follow(messages).ask(options)`.
- Backend default `:responses` (env `ASK_BACKEND,LLM_BACKEND`). Dispatch:
  `:openai, :anthropic, :responses, :ollama, :vllm, :openwebui, :huggingface,
  :relay, :bedrock` -> `<Mod>.image(...)`; **no `:glm` branch**. The registry
  fallback calls `<mod>.ask(messages, options)` - plain ask, no
  image_generation tool, for plugin backends.
- **Caching**: the dispatch is wrapped in `Persist.persist(endpoint, :json,
  prefix: "LLM image", other: options.merge(messages:), persist:,
  dir: Scout.var.cache.ask)` with `persist` defaulting to true; the key is
  endpoint + all options + the full messages, so any option change
  recomputes. A cache hit skips backend selection entirely.
- Return: `Chat.setup res if Array === res`.

Backend side: `ClassMethods#image` (default.rb:619-628) is inherited by every
ClassMethods-including backend - `ask(question, options.merge(tools:
[{type: 'image_generation'}], return_messages: true))` then
`messages.select{|i| i[:role]=='image'}.first['content']['result']`. The
`image_generation` "tool" is a type-only provider tool (Responses API), no
function name or parameters; the output item type `'image_generation_call'`
maps to `{role: 'image', content: output}` and `image()` digs out the base64
`result`. Provider reachability: modules with an inherited `image` are
OpenAI, Anthropic, Responses, OLlama, VLLM, OpenWebUI, Huggingface and GLM
(none overrides it); **Bedrock and Relay define no `image` at all**, yet
image.rb routes `:bedrock`/`:relay` to `Mod.image`.

Convenience: `Chat#create_image(file, ...)` =
`base64 = LLM.image(LLM.chat(self), ...); Open.write(file,
Base64.decode64(base64), mode: 'wb')` - the whole chat is the image prompt.
`Agent#create_image` merges `@other_options` and forwards.

### Vision input (multimodal message assembly)

1. `chat.image(path)` / `chat.pdf(path)` append `{role: 'image'|'pdf',
   content: <path>}` to the current chat (`Agent` forwards through
   `method_missing` to `current_chat`).
2. Path resolution happens in `Chat.files`, the last step of `Chat.process`,
   via `Chat.find_file(file, original, caller_lib_dir)`: relative to the
   original chat file, then the caller libdir join, then a cwd file, then
   remote passthrough (http/https kept verbatim), then the `Scout.chats`
   pathmap. The content becomes an absolute path; the role is unchanged. A
   missing file raises `"File not found: <name>"`.
3. Encoding happens at format time, not annotation time. `format_other`
   (default.rb:180+) cases on the role string:
   - `'image'`: `Chat.find_file` again (idempotent); a remote URL becomes a
     provider URL block, otherwise `encode_image(path)` -> data URI; raises
     `"Image does not exist in <path>"` when missing.
   - `'pdf'`: `encode_pdf` -> `data:application/pdf;base64,...` ->
     `input_file`/`file_data` block.
   - `encode_image` (default.rb:155-171): base64 `strict_encode64`; MIME by
     extension - `jpg|jpeg` -> `image/jpeg`, `png` -> `image/png`,
     **everything else -> the literal string `"image/extension"`**.
4. Per-provider shape: only `glm.rb` overrides `format_other` - image ->
   `{type: :image_url, image_url: {url: <path-or-dataURI>}}` (bare hash for
   remote, array-wrapped for local). Every other backend (openai, anthropic,
   responses, ollama, vllm, openwebui, huggingface) inherits the default
   Responses-style `{type: :input_image, image_url: <data-uri-or-url>}`.
5. One image message -> exactly one provider content block; images ride as
   `user`-role content arrays.

### Knowledge base / RAG seam

- **No embeddings in the KB path at all.** `LLM.knowledge_base_tool_definition`
  builds per database a `children`/`parents` traversal tool (params
  `entities` (+ `reverse` for directed DBs), output `source~target`) and,
  when the index has fields, a `<db>_association_details` tool (params
  `associations` (+ `fields`); `fields` is dropped when the database has
  exactly one field). Execution is pure TSV index lookup.
- Chat wiring: the `association:` role registers a TSV inline via
  `kb.register`; the `kb:` role points at an existing KB by name;
  `Chat.associations` consumes both. Driving the `association` role
  end-to-end with a minimal flat TSV raises inside **scout-gear**
  (`Association#index` -> `undefined method 'include?' for nil`) - the role
  is a thin registration; indexing semantics and TSV-shape requirements live
  in scout-gear's KnowledgeBase.
- `LLM.knowledge_base_ask(kb, question, options)` wires a tools block that
  answers only the `children` lookup, not the details tool.
- **The two "RAG" meanings are disjoint**: `LLM::RAG` (hnswlib over
  `LLM.embed` vectors) never touches KnowledgeBase; KB tools never touch
  embeddings.

## Sharp edges and known issues

- **Dead/broken embed and image branches** (F11, open): embed `:relay` ->
  NoMethodError; embed `:openwebui` -> NoMethodError (Hash client); image
  `:relay` and `:bedrock` -> NoMethodError (`Mod.image` does not exist);
  `:glm` missing from the image dispatch although `LLM::GLM.image` works when
  called directly; bedrock embed implemented but unreachable from
  `LLM.embed`.
- **`encode_image` MIME table maps only jpg/jpeg/png** (F18, open): any other
  extension yields the literal `data:image/extension;base64,...` - webp, gif
  and tiff are silently malformed.
- **Anthropic image support does not exist** (F18, open): despite
  `doc/developer/Backends.md` describing base64 `image` content blocks with
  media type, `LLM::Anthropic` defines no image handling and inherits the
  default `input_image` shape; only GLM uses a true nested `image_url`.
- **ToolCalling.md's details-tool parameter is wrong** (doc bug, open): the
  parameter is `associations` (optionally `fields`), never `entities`.
- **No user-level documentation** of embeddings, images, vision or RAG
  anywhere in `doc/user/` (RunningInference.md has no sections; Cookbook.md
  has no examples).
- **Fixed 2026-09-11, uncommitted:** F1 - the `attach` tool never attached
  PDFs (normalization overwrote an explicit `file_type: 'pdf'` to `'image'`
  and the dispatcher's bare `case` matched the first branch unconditionally,
  so `when 'pdf'` was unreachable; every attach routed to `self.image(path)`).
  Now only `auto` is normalized (pdf by `.pdf` extension, else `image`), the
  dispatcher is `case file_type`, and an unknown type raises. Regression
  tests in `test/scout/llm/agent/test_attach.rb` (8/0). The `ATACH_TYPES`
  typo and the schema/code default divergence it exposed (schema
  `default: 'auto'`, code default now `'auto'`) were reconciled in the same
  fix; the constant name typo remains.
- **Fixed 2026-09-11, uncommitted:** F5 - `LLM.embed` never merged endpoint
  YAML (extensionless `Scout.etc.AI[endpoint].exists?` instead of
  `find_with_extension(:yaml).exists?`), and a missing endpoint failed
  silently instead of raising like ask/image. Now the yaml merge and the
  requested-endpoint raise match the ask/image contract (see
  `lib/scout/llm/embed.rb`'s comment). Regression tests in
  `test/scout/llm/test_embed.rb` (6/0). A behaviour change to note: an
  explicitly requested endpoint with no yaml now raises instead of silently
  using the config defaults.
- `test_rag.rb#_test_rag` is underscore-disabled; only `test_rag_insitu`
  runs.

## Open questions

- Does `CausalModel` with `task: 'Embedding'` return usable vectors for a
  real checkpoint? (Not probed - no downloads.)
- Are the unreachable-but-implemented paths (bedrock embed, glm image)
  deliberate omissions from the dispatch or oversights?
- Should `LLM.embed` cache? Embeddings are the classic cache-friendly
  workload (deterministic per text+model); `ask`/`image` both cache.
- Whether any provider rejects the `input_image` default shape on
  Chat-Completions-only deployments - untestable offline.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep. The attach fix (F1) and the embed endpoint-YAML fix (F5) in that sweep
are in scope here and are described as current behavior above.

- Code: `lib/scout/llm/embed.rb` (54 lines, current fixed form with the
  ScoutCoder comment documenting the F5 fix); `lib/scout/llm/rag.rb` (33
  lines); `lib/scout/llm/image.rb`; `lib/scout/llm/agent/attach.rb` (current
  fixed form with the ScoutCoder comment documenting the F1 fix);
  `lib/scout/llm/backends/default.rb:155-178` (`encode_image`/`encode_pdf`),
  `:180-214` (`format_other`), `:398-400` (image output mapping),
  `:619-637` (`image`, `embed_query`, `embed`); `backends/{ollama,openwebui,
  huggingface,bedrock,anthropic,glm}.rb`; `lib/scout/llm/chat/annotation.rb:250-253`
  (`create_image`); `lib/scout/llm/chat/process/files.rb:17-36,83-89`;
  `lib/scout/llm/tools/knowledge_base.rb`; `lib/scout/llm/ask.rb:132-140`.
- Tests: `test/scout/llm/test_embed.rb` (6/0 after the F5 fix),
  `test/scout/llm/test_rag.rb` (one test disabled),
  `test/scout/llm/agent/test_attach.rb` (8/0 after the F1 fix).
- Probe receipts: ~57 offline probes under `tmp/probe_embed_image/` covering
  the embed API surface and default failure mode, no-Persist, RAG
  index/load/top and the ordering quirk, per-backend embed implementations
  and dead branches, the huggingface local-eval path, `LLM.image` dispatch
  and provider reachability, the `image_generation` tool shape and response
  mapping, image caching key inputs, annotation -> files -> absolute-path
  resolution and the `find_file` order, per-provider content-block shapes
  and `format_other` ownership, the MIME table bug, the attach dispatch bug
  and its re-confirmation, config/endpoint-yaml precedence and the
  asymmetry, and the KB tool parameter shapes.
