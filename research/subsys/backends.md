# 04 - LLM backend layer and inference loop

> Investigation, not normative documentation. Verified behavior of the
> backend registry, selection, the shared inference/tool loop and the
> per-provider adapters. Normative reference: `doc/developer/Backends.md`,
> `doc/user/RunningInference.md`.

## Scope

`lib/scout/llm/backends/` (`default.rb` plus `openai`, `anthropic`,
`responses`, `vllm`, `openwebui`, `ollama`, `huggingface`, `relay`, `bedrock`,
`glm`), the dispatch layers `lib/scout/llm/ask.rb` and
`lib/scout/llm/embed.rb`, and the tool-loop glue in
`lib/scout/llm/tools/call.rb`.

## Verified behavior

### Registry and selection

`LLM.ask` resolves backend/endpoint in this order:

1. `options[:endpoint]`; options are defaulted from
   `Scout.etc.AI[<endpoint>].yaml` when that file exists. A non-empty
   endpoint with no yaml raises `RuntimeError: Endpoint not found <name>`
   **after** the ask is logged. Endpoint yaml keys are merged as *defaults*
   (they never override explicit options) and may carry `backend`, `url`,
   `key`, `model`, `provider`, ...
2. `options[:backend]` (explicit) is used directly.
3. Else `Scout::Config.get(:backend, :ask, :llm, env: 'ASK_BACKEND,LLM_BACKEND')`
   with **default `:responses`** (ask.rb:71) - the default backend is the
   OpenAI Responses API, not Chat Completions.
4. The `case backend` ladder hard-codes `:openai`, `:anthropic`,
   `:responses`, `:ollama`, `:vllm`, `:openwebui`, `:huggingface`, `:relay`,
   `:bedrock`, `:glm`, each `require_relative`d lazily.
5. Anything else -> `LLM::BACKENDS[backend]` runtime registry, else
   `RuntimeError: Unknown backend: <name>`. `LLM::BACKENDS` starts empty in
   library code (the test helper registers `:mock`) and is the plugin seam
   through `LLM.register_backend(name, mod)`. There is **no** dynamic
   `const_get` module resolution (F13).

**Model resolution is shared, not per-provider** (F13 config hazard):
`client_options` (default.rb:42-47) pulls `Scout::Config.get(:model, :url,
:key, ...)` with a single `tag: self::TAG` token and
`default_model: self::DEFAULT_MODEL`, so a `model` set for one backend leaks
to all of them through the `key:model` token unless the endpoint yaml pins it
per backend. Endpoint yaml files are the intended isolation mechanism.

`LLM.embed` mirrors the shape with `:openai`/`:responses` both mapping to
`LLM::OpenAI.embed`, plus `:ollama`, `:openwebui`, `:huggingface`, `:relay`;
default backend symbol `:embed`; registry fallback otherwise. There is no
`:anthropic`, `:vllm`, `:bedrock`, `:glm` branch in embed (see the
embed-image study).

### The shared loop

`Backend::ClassMethods#ask` (default.rb:482-570) is a `while` over `query()`
results:

```
prepare_client -> messages = Chat.chat(prompt) -> relay upload if options[:relay]
loop:
  prompt = Chat.prepare_prompt(messages, prompt_strategies, save_file:)
  formatted_prompt = format_messages(prompt)
  tools = tools(formatted_prompt, options)
  response = query(client, formatted_prompt, tools, parameters)
  messages += output; if output contains function_call -> chain_tools(...)
```

- One tool-calling round emits `function_call` (assistant-side request),
  `function_call_output`, then the next `assistant` message, and issues one
  client call per round. There is **no hard round counter**: the loop ends
  when `query()` returns no tool calls, or when the prompt-strategy
  compaction drops the tool outputs.
- `chain_tools` (default.rb:342-390) re-enters `ask` with
  `messages + output` and re-merges the loop-scoped options
  (`prompt_strategies`, `save_file`, `relay`, `client`, `current_meta`) on
  each re-entry, so the prompt is re-prepared every round.
- Responses-API threading: with `backend: responses` and
  `previous_response` not disabled, round N+1's request carries the previous
  round's response id, and the final message list ends with a synthetic
  `previous_response_id` message. `LLM.ask` additionally clears vs cleans
  `previous_response_id` messages depending on whether
  `backend == :responses && previous_response != false` (ask.rb:53-58).
- Error path: a `query()` raise propagates raw. **There is no retry/backoff
  at the backend layer** for openai/anthropic/responses/vllm; the only retry
  constructs are OpenWebUI's `Misc.insist` around the HTTP post (~4 small
  retries) and the optional user-supplied `Agent#process_exception` hook,
  which may `retry`.
- Relay mode: `options[:relay]` inside `Backend#ask` short-circuits to
  `upload_messages`/`gather_response` (scp round-trips to
  `<server>:.scout/var/query/`), while the standalone `LLM::Relay.ask` scps
  options+question to `<server>:.scout/var/ask/` and polls
  `reply/<id>.json`. Both are fire-and-poll, not streaming.
- Ask-level caching: the dispatch is wrapped in
  `Persist.persist(endpoint, :json, prefix: "LLM ask", other:
  options.merge(messages:), persist:, dir: Scout.var.cache.ask)` with
  **persist defaulting to true** (env `ASK_PERSIST,LLM_PERSIST,PERSIST`).
  The cache key includes the whole options hash plus the messages, so a
  change of `model` or `tools` changes the key; `persist: false` bypasses.
  `SCOUT_NO_ASK_CACHE` gates the cache (test usage).

### Provider adapters

Composition pattern: each adapter is
`class << self; prepend XMethods; include Backend::ClassMethods; end`, with
MRO `XMethods -> (parent Methods) -> Backend::ClassMethods`.
`OpenWebUIMethods` *includes* `OpenAIMethods`; `VLLMMethods` includes
`ResponsesMethods`; `GLMAIMethods` is prepended over `OpenAIMethods`.

| backend | essentials |
|---|---|
| OpenAI (chat completions) | client `OpenAI::Client.new(api_version: 'v1', access_token:, uri_base:, request_timeout: 1200)`. Tool defs nested `{type: :function, function: {...}}`. `format_tool_call` -> assistant `tool_calls`; tool output -> `{role: 'tool', tool_call_id}`. Usage `pt/ct/tt` from `prompt_tokens/completion_tokens/total_tokens`, `cct/cwt` from the `*_details` sub-hashes. `process_response` raises on API error bodies. |
| Anthropic (messages) | client `Anthropic::Client.new(api_key:, base_url:)`; `extra_options` forces `max_tokens` default **1000**. Tool defs **flat** `name/description/input_schema` (parameters renamed), `type: 'function'` rewritten to `type: 'custom'`. Tool output is a **user-role content-block** message `{role: 'user', content: [{type: 'tool_result', tool_use_id:, content:}]}`. Usage `input_tokens/output_tokens` -> `pt/ct`, `cache_read_input_tokens` -> `cct`, `cache_creation_input_tokens` -> `cwt`, `tt` computed. `process_response` iterates content blocks: `text` -> assistant; `reasoning` and `web_search_call` skipped; unknown types raise. `embed_query` raises `'Anthropic does not offer embeddings'`. |
| Responses (default) | no overrides at all - the whole behaviour is `Backend::ClassMethods` on `client.responses.create(parameters:)` with `previous_response_id` threading. `DEFAULT_MODEL = 'gpt-5-nano'`. Tool calls arrive as `output[].type == 'function_call' | 'mcp_call'`. Usage `input_tokens/output_tokens/total_tokens`, `cct` from `input_tokens_details.cached_tokens`, `rt` from `output_tokens_details.reasoning_tokens`. |
| vLLM | includes `ResponsesMethods`; the only override is `parse_tool_call`, which strips a `channel<word>` fragment from the tool name (regex `[^a-zA-Z_]+channel[^a-zA-Z_]+[a-zA-Z_]+`) to undo vLLM name mangling. |
| OpenWebUI | `client()` returns a plain Hash spec, not an SDK client; `query()` posts `parameters.to_json` with `Authorization: Bearer <key>` + `Content-Type: application/json` to `<url>/chat/completions` via `RestClient.post`, `verify_ssl: false`, propagating `timeout/read_timeout/open_timeout` (default 12000). Wrapped in `Misc.insist`. Tool defs reuse the OpenAI shape; `parse_tool_call` synthesizes `id = name + '_' + Misc.digest(arguments)` when absent. |
| Ollama | client `Ollama.new(credentials: {address: url, bearer_token: key})` - the localhost:11434 default comes from the gem, not scout-ai. `query` sets `parameters[:stream] = false` explicitly (the only explicit stream token in the subsystem). Responses arrive as an Array of chunks; `process_response` flattens them and skips empty assistant messages. `update_meta` is overridden to return `{}` (no usage) and `reasoning` to nil - an override **must** return a Hash because `ask` assigns `meta['timestamp']` into it. `embed_query` posts to `api/embed`. |
| Huggingface | no client SDK: `prepare_client` builds a `CausalModel` through scout's python support, pulling `MODEL_OPTION_KEYS` (task/checkpoint/chat_template/generation_kwargs/tokenizer_args/trust_remote_code/torch_dtype/device_map/...) from options or `HUGGINGFACE_MODEL`/`HF_MODEL`. `DEFAULT_MODEL = nil`. `query` calls `client.chat(messages, formatted_tools, parameters)` and converts PyCall objects with `ScoutPython.dict2hash`. It has the **only** custom `tools()` override: it consumes `options[:tools]` (Array of provider definitions -> name-keyed Hash) and strips `role: 'tool'` messages carrying `tool_call_id`/`name` before deriving definitions from directives. |
| Relay | no provider: `ask` scps a JSON options file to a server and polls for the reply. No embed, no tool loop, no usage tracking. |
| Bedrock | **does not use the shared loop**. Standalone `ask` with its own while-loop, building either `type: :messages` (system messages concatenated into a `system:` parameter, only user messages kept) or `type: :prompt` (system+user concatenated into a single `prompt:` string), invoking `client.invoke_model(model_id:, body:)`, unwrapping `content[].tool_calls` and looping until no tool calls remain. Returns the joined text of `content[].text`, **not** a message list. Credentials via `LLM.get_url_config`/`AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, model via `BEDROCK_MODEL_ID` (embed `BEDROCK_EMBED_MODEL_ID`, default `amazon.titan-embed-text-v1`). Because it bypasses `Backend::ClassMethods`, it gets none of the shared machinery: no meta/usage messages, no prompt strategies, no `save_file` threading. |
| GLM | prepends `GLMAIMethods` over `OpenAIMethods`; `format_other` adds `image` (base64 `image_url`), `pdf` (`input_file` with `file_data`/`file_url`), `websearch` (`{role: 'tool', content: {type: 'web_search_preview'}}`) and drops `previous_response_id` roles. `DEFAULT_MODEL = 'glm-turbo'`. Dispatched from `LLM.ask` but **not** from `LLM.embed`. |

### Tool-call dispatch

`LLM.process_calls` (tools/call.rb) is called from each backend's
`process_response` with normalized `{arguments:, id:, name:}` hashes; the
registry lookup is `obj, definition = tools[function_name]`, and definition
`parameters.defaults` are merged into the arguments (see the tools study for
the override direction). Step results are batched through `Workflow.produce`
with the transient `.jobs` sidecar; `LLM::Agent` results are run in parallel
and paired by position. String content longer than `LLM.max_content_length`
(config `max_content_length`, tokens `:llm_tools,:tools,:llm,:ask`, default
**100_000**) is replaced by an exception payload with a fingerprint of the
content (tools/call.rb:10, 257-258).

## Sharp edges and known issues

- **No retry/backoff despite doc claims** (F8, open): `doc/developer/Backends.md`
  documents exponential backoff on transient errors; a `query` raise
  propagates raw.
- **No streaming despite doc claims** (F9, open): `stream_results` appears
  nowhere in lib/; the only stream token is ollama's `stream: false`.
  `doc/user/RunningInference.md`'s "streaming is available but not enabled
  by default" is likewise unsupported.
- **Unknown-backend module resolution does not exist** (F13, open): only
  `LLM.register_backend` into `LLM::BACKENDS` works; the documented
  `:my_backend` -> `LLM::MyBackend` resolution is absent.
- **Model config cross-talk** (F13, open): a `model` set for one backend
  leaks to all via the shared `key:model` token unless endpoint yaml pins it.
- **Documented backend list incomplete** (F13, open): openwebui, huggingface,
  relay, bedrock, glm are missing from Backends.md's table.
- **Stale loop bound** (F14, open): Backends.md's "MAX_TOOL_CALLS (40) via
  `shorten_tools`" - the default strategy is
  `shorten_tools_epoch_increment` (threshold 50 / keep 20 / cap 80), and the
  strategy bounds *context size*, it is not a hard round limit.
- **Ollama localhost default is the gem's** (doc nuance): scout-ai passes
  `address: url` verbatim and would pass nil without the ollama-ai gem's
  `DEFAULT_ADDRESS`.
- **Bedrock is not a normal backend** (doc nuance): presenting it alongside
  the others hides that it shares none of `Backend::ClassMethods`.
- **`parameters.defaults` stripping is mostly dead code** (F21, open):
  `openai.rb:53` deletes at the *wrapper* level where `:parameters` is nil
  (parameters live under `function:` after wrapping), so the scout-specific
  subschema reaches the provider. Only huggingface digs correctly
  (`definition.dig(:function, :parameters).delete(:defaults)`); ollama and
  anthropic never strip it.
- **Embedding dispatch asymmetry**: no anthropic/vllm/bedrock/glm branch;
  `:responses` aliases OpenAI; the registry fallback covers only registered
  plugins. Dead/broken branches are catalogued in the embed-image study (F11).
- **`_s` session counters** observed starting from large values in probes
  (shared process-level state); the exact reset semantics of `_s` vs `_c`
  were not traced to their accumulation site.

## Open questions

- Why `LLM.embed` omits bedrock/glm/anthropic branches while `LLM.ask`
  dispatches them - `LLM::Bedrock.embed` is fully implemented but only
  reachable by direct call. Oversight or deliberate?
- The relay paths differ (`Backend#ask` uses `.scout/var/query/`,
  `LLM::Relay.ask` uses `.scout/var/ask/`); is one dead, or must a relay
  server serve both?
- Huggingface's bespoke `tools()` override diverges from every other backend;
  whether `tool:`/`kb:`/`association:` directives behave identically there
  was verified only for the shared path.
- Whether any test exercises the glm `format_other` pdf/file handling (no glm
  test file exists under `test/scout/llm/backends/`).
- Whether any provider rejects the `input_image` default shape on
  Chat-Completions-only deployments (needs a live backend call).

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch). The `LLM.embed` endpoint-YAML fix (F5) in
that sweep changed embed.rb only; the ask/image dispatch described here is
unchanged by it.

- Code: `lib/scout/llm/ask.rb:26-116` (resolution, cache, dispatch),
  `:53-58` (previous_response_id clear/clean), `:71` (default `:responses`);
  `lib/scout/llm/backends/default.rb:35-47` (client/client_options),
  `:91-102` (responses query), `:155-235` (encode/format_other/tools
  formatting), `:273-341` (format_messages, tools, messages),
  `:342-390` (chain_tools), `:415-448` (update_meta), `:482-570` (ask loop),
  `:584-617` (meta append, final output), `:619-637` (image, embed_query,
  embed); `backends/{openai,anthropic,responses,vllm,openwebui,ollama,
  huggingface,relay,bedrock,glm}.rb`; `lib/scout/llm/tools/call.rb:8-11,48+`;
  `lib/scout/llm/embed.rb`.
- Tests: `test/scout/llm/backends/test_openwebui.rb` (headers),
  `test/scout/llm/test_ask.rb`.
- Probe receipts (Cortex Observations, all offline via the
  `Observation/probe` property): `scout_ai_backends_registry` (selection,
  registry, plugin backends, endpoint yaml merge, error conditions),
  `scout_ai_backends_loop` (shared loop, rounds, `chain_tools` re-merge,
  error path, cache, max_content_length), `scout_ai_backends_adapters`
  (client construction, tool-def mapping per provider, MRO, model
  cross-talk), `scout_ai_backends_usage_meta` (usage normalization, ollama
  override, vllm mangle), `scout_ai_backends_openwebui_cache` (request
  construction against a local HTTP stub, ask-level cache semantics).
  Durable claims derived from them: Cortex `claims/scout_ai_backend_selection.md`,
  `claims/scout_ai_no_streaming_no_retry.md`,
  `claims/scout_ai_epoch_compaction_defaults.md`.
