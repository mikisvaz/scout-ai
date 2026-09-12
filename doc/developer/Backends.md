# Backends

This document describes how the LLM backend abstraction works internally:
the module composition pattern, the inference loop, error handling, and
provider differences. It is intended for framework contributors.

> For the user-facing guide on configuring inference endpoints and providers,
> see [../user/RunningInference.md](../user/RunningInference.md).
> For the probe-verified subsystem study (backend registry, the shared loop,
> provider adapters, sharp edges), see
> [../../research/subsys/backends.md](../../research/subsys/backends.md) under `research/`.

---

## The Backend abstraction

There is **no abstract base class**. Instead, shared logic lives in the
`LLM::Backend` module (in `lib/scout/llm/backends/default.rb`), specifically in
an inner `ClassMethods` module. Each provider is a **module** (not a class)
that composes it.

### Composition pattern

```ruby
module LLM
  module FooMethods       # provider-specific overrides
    def query(...)
      ...
    end
  end

  module Foo
    TAG = 'foo'
    DEFAULT_MODEL = 'foo-model'

    class << self
      prepend FooMethods             # overrides take priority
      include Backend::ClassMethods  # shared implementation
    end
  end
end
```

Ruby's method resolution order (MRO) ensures:
- `FooMethods#query` shadows `Backend::ClassMethods#query` (via `prepend`).
- Shared methods (`ask`, `chain_tools`, `tools`, `embed`) come from `ClassMethods`.
- `self.query(...)` inside the shared `ask` method dispatches to the provider
  override.

This gives every backend the full inference pipeline for free, while only
requiring it to implement the provider-specific API call and response parsing.

---

## The `ask` method (template method pattern)

`Backend::ClassMethods.ask` is the universal entry point for all backends. It
follows a template-method structure:

```
ask(messages, options)
  │
  ├── prepare_client(options, messages)     →  API client setup
  ├── Chat.prepare_prompt(messages, strategies)  →  ephemeral context management
  ├── format_messages(prompt)               →  provider-specific formatting
  ├── tools(prompt, options)                →  tool registry assembly
  ├── query(client, formatted_prompt, tools, options)  →  API call
  ├── process_response(...)                 →  parse API response → message list
  ├── extract_tools(response)               →  detect tool calls
  ├── chain_tools(...)                      →  recursive tool loop (if needed)
  ├── update_meta(messages, response)       →  provenance annotations
  └── return annotated Chat
```

---

## The `chain_tools` loop

When the model emits a tool call, the backend enters a recursive loop:

```ruby
def chain_tools(messages, output, tools, options, &block)
  if output.last[:role] == 'function_call_output'
    # re-call ask with the tool output appended
    output + ask(messages + output, options.except(:tool_choice).merge(return_messages: true), &block)
  else
    output   # no pending tool call — done
  end
end
```

Each iteration:
1. Checks if the model's last message is a `function_call_output`.
2. If so, executes the tool, appends the result, and calls `ask` again with the
   growing message list.
3. Terminates when the model's last message is a plain `assistant` message.

### Implicit iteration limiting

There is no hard loop counter. The loop ends when `query()` returns no tool
calls; what bounds it is context size, not a round limit. The default
`shorten_tools_epoch_increment` strategy (see
[PromptProcessing.md](PromptProcessing.md)) no-ops at or below **50** total
tool calls, keeps the most recent **20** at full fidelity, may keep up to
**80** compacted, and truncates the rest to `DEFAULT_SHORT_STRING_LENGTH * 2`
(400 characters). These are strategy bounds on the *prompt*,
not a request round limit — there is no `MAX_TOOL_CALLS` in the loop.

---

## Error handling and retries

Backends do not retry. A `query` raise propagates out of `ask` unchanged
(no backoff, no retry). The shared loop does tag it with
`Backend::BackendException` and give it a `.chat` accessor pointing at a
saved debug copy of the failing messages/options/meta before re-raising:

- The only retry construct inside a backend is OpenWebUI's `query`, which
  wraps its HTTP POST in `Misc.insist` (about four attempts with sub-second
  sleeps).
- **Agent-level exception handling** — `Agent#chat` rescues a backend raise
  and calls the user-supplied `process_exception` Proc (an accessor on the
  agent); returning truthy triggers a `retry`, anything else re-raises.

### Parallel agent fan-out

`LLM.process_calls` is the shared tool executor, so it also collects tool
results that are `LLM::Agent` objects and runs their `agent.chat
(return_messages: true)` rounds concurrently through `Open.traverse`. The
concurrency is
`Scout::Config.get(:cpus, :agent_ask, :agents, env: 'ASK_AGENTS', default: 3)`.
Each answer is paired back with the tool call that produced it by position
(a duplicate agent in one round gets its own answer, not the first one's).

There is no streaming either (`stream_results` does not exist): every request
is blocking and returns once complete. The only `stream` token in the
subsystem is ollama's `stream: false`.

---

## Backend selection

`LLM.ask` selects a backend via:

1. **Endpoint configuration** — `options[:endpoint]`; when set, its options
   are defaulted from `Scout.etc.AI[<endpoint>].yaml` (which may specify a
   `backend`). A non-empty endpoint with no YAML raises
   `Endpoint not found <name>`. Writing those files is the user-facing
   mechanism; see [../user/RunningInference.md](../user/RunningInference.md)
   for the hand-written YAML and `-ck key=value` forms.
2. **Explicit `:backend` option** — `options[:backend]` selects the module.
3. **Config default** — `Scout::Config.get(:backend, :ask, :llm, env:
   'ASK_BACKEND,LLM_BACKEND')`, defaulting to `:responses`.
4. **Hard-coded dispatch** — A `case` statement maps `:openai`, `:anthropic`,
   `:responses`, `:ollama`, `:vllm`, `:openwebui`, `:huggingface`, `:relay`,
   `:bedrock`, `:glm` to their modules, requiring each file lazily.
5. **Plugin registry** — Anything else is looked up in `LLM::BACKENDS`
   (populated by `LLM.register_backend(name, module)`), else it raises
   `RuntimeError: Unknown backend: <name>`.

**Model configuration is shared, not per-provider.** `client_options` pulls
`Scout::Config.get(:model, ...)` through a single `key:model` token, so a
`model` set for one backend leaks to all of them unless the endpoint YAML
pins it per backend.

---

## Provider differences

### OpenAI (`LLM::OpenAI`)

- **API client**: `OpenAI::Client` (ruby-openai gem). The
  `request_timeout` default differs by construction path: `client_options`
  defaults it to **1200** and `client` to **12000** — and since
  `prepare_client` merges `client_options` into the options before calling
  `client`, the 1200 default wins in practice unless overridden (the gem's
  own default is 120).
- **Tool format**: `type: 'function'` with nested `function:` key; the
  `format_tool_call`/`format_tool_output` pair emits assistant
  `tool_calls` and `role: 'tool'` + `tool_call_id` messages.
- **Usage meta**: `pt/ct/tt` plus `inference_id`, `provider_response_id`,
  cumulative `_s` and per-conversation `_c` counters; `cct/cwt/rt` come from
  the `*_details` sub-hashes when present.
- **Images**: No override — inherits the default `input_image` shape
  (`{type: :input_image, image_url: <data-uri-or-url>}`), which is what the
  OpenAI/Responses/ollama family uses. `encode_image` maps only
  jpg/jpeg/png to a correct MIME type; webp/gif/tiff fall through to the
  literal `image/extension` MIME and produce a malformed data URI.
- **Defaults subschema**: its `parameters[:defaults]` delete looks at the
  wrapper level, where `:parameters` is always nil, so the scout-specific
  `defaults` subschema still reaches the provider (dead code — see
  [Improvements.md](../Improvements.md) issue 8).

### Anthropic (`LLM::Anthropic`)

- **API client**: `Anthropic::Client`; `extra_options` forces a `max_tokens`
  default of 1000.
- **Tool format**: Flat `name`, `description`, `input_schema` (renamed from
  `parameters`; no `function:` nesting); `type: 'function'` is rewritten to
  `type: 'custom'`. Tool outputs go back as a user-role
  `tool_result` content block, not an assistant `tool_calls` message.
- **Usage meta**: `input_tokens`/`output_tokens` → `pt`/`ct`,
  `cache_read_input_tokens` → `cct`, `cache_creation_input_tokens` → `cwt`;
  `tt` is computed (input+output).
- **Images**: `LLM::Anthropic` defines no image handling of its own, so it
  inherits the default `input_image` shape — there is **no** Anthropic
  base64 `image` block. `embed_query` raises
  `'Anthropic does not offer embeddings'`.
- **System messages**: Extracted from the message list and sent as a separate
  parameter.
- **Reasoning**: Extracts `thinking` content blocks.

### Ollama (`LLM::OLlama`)

- **API client**: `Ollama.new(credentials: {address:, bearer_token:})` from
  the `ollama-ai` gem; when `url` is unset the *gem* defaults the address to
  `http://localhost:11434`.
- **Tool format**: Uses OpenAI-compatible format.
- **Requests**: `query` sets `stream: false` explicitly — the only explicit
  stream token in the subsystem; responses arrive as an Array of chunks that
  `process_response` flattens.
- **Usage meta**: `update_meta` returns `{}` (no usage available).
- **Embedding**: `embed_query` posts to `api/embed`.

### Responses API (`LLM::Responses`) — the default backend

- **The config default**: when neither `endpoint`, nor an explicit
  `:backend`, nor a config `backend` selects anything, this is what runs
  (`DEFAULT_MODEL = 'gpt-5-nano'`).
- **Session state**: threads `previous_response_id` between rounds so context
  stays server-side; a `previous_response: 'false'` option disables the
  threading.
- **Tool calls** arrive as `output[]` entries of type `function_call` /
  `mcp_call`.

### vLLM (`LLM::VLLM`)

- Includes `ResponsesMethods`; the **only** override is `parse_tool_call`,
  which strips a `channel…<word>` fragment that vLLM injects into tool names.
  Everything else (client, messages, usage) is the Responses API.

### Bedrock (`LLM::Bedrock`)

- **Multi-provider**: Routes to different providers (Anthropic, Meta, etc.) via
  the AWS Bedrock API, using provider-prefixed model IDs
  (`anthropic.claude-3-sonnet`, …) configured through `BEDROCK_MODEL_ID`;
  credentials come from `AWS_REGION` / `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY`. A `type:` option (default `:messages`) switches
  between a Messages-style body and a flat prompt body.
- **Standalone**: does not compose `Backend::ClassMethods` — it defines its
  own `ask` with no meta, no prompt strategies and no `save_file`, returning
  joined text. `LLM::Bedrock.embed` exists but no `LLM.embed` dispatch branch
  reaches it; embeddings must be requested from it directly.
- **Tool-call concurrency**: its private tool loop executes the tool calls of
  one model round through `Open.traverse` with
  `Scout::Config.get(:cpus, :tool_calling, default: 3)` — a Bedrock-local
  knob, distinct from the shared agent fan-out below.

### GLM (`LLM::GLM`)

- A Chat-Completions backend (`DEFAULT_MODEL = 'glm-turbo'`) that prepends
  `GLMAIMethods` over `OpenAIMethods` and overrides only `format_other`: it
  adds `image` (base64 `image_url`), `pdf` (`input_file` with
  `file_data`/`file_url`) and `websearch` roles, and drops
  `previous_response_id` messages. It is the one backend that sends images as
  a true nested `image_url` block rather than the default `input_image`
  shape. Dispatched from `LLM.ask` but **not** from `LLM.embed`.

### HuggingFace (`LLM::Huggingface`)

- Prepends `HuggingfaceMethods` over `OpenAIMethods` (chat-completions shape).
  **Not an HTTP API**: `prepare_client` builds a `CausalModel` through Scout's
  Python support, with the model/checkpoint/generation options taken from
  `HUGGINGFACE_MODEL`/`HF_MODEL` (`DEFAULT_MODEL` is nil). `query` converts
  PyCall results back with `ScoutPython.dict2hash`.
- It is the only adapter that actually strips
  `parameters[:defaults]` out of a tool definition before sending (OpenAI's
  equivalent line looks at the wrapper level, where `:parameters` is nil —
  see [Improvements.md](../Improvements.md) issue 8).

### Relay (`LLM::Relay`)

- Fire-and-poll over `scp`: `options[:relay]` in the shared `ask` uploads the
  messages to `<server>:.scout/var/query/` and gathers the reply; standalone
  `LLM::Relay.ask` scps options+question to `var/ask/` and polls for
  `reply/<id>.json` with `sleep 1; retry`. Not streaming.

### OpenWebUI (`LLM::OpenWebUI`)

- Includes `OpenAIMethods`; `client()` returns a plain Hash spec rather than
  an SDK client, and `query()` posts `parameters.to_json` with a bearer
  header. Its HTTP POST is the one place a backend retries
  (`Misc.insist`, ~4 sub-second attempts).

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/ask.rb` | Top-level `LLM.ask`, backend dispatch |
| `lib/scout/llm/backends/default.rb` | `Backend` module + `ClassMethods` |
| `lib/scout/llm/backends/openai.rb` | OpenAI provider |
| `lib/scout/llm/backends/anthropic.rb` | Anthropic provider |
| `lib/scout/llm/backends/ollama.rb` | Ollama provider |
| `lib/scout/llm/backends/responses.rb` | OpenAI Responses API |
| `lib/scout/llm/backends/vllm.rb` | vLLM provider (Responses + tool-name unmangling) |
| `lib/scout/llm/backends/openwebui.rb` | OpenWebUI provider (Hash client, `Misc.insist` retry) |
| `lib/scout/llm/backends/huggingface.rb` | HuggingFace provider |
| `lib/scout/llm/backends/relay.rb` | Relay (scp round-trip) provider |
| `lib/scout/llm/backends/bedrock.rb` | AWS Bedrock provider (standalone `ask`) |
| `lib/scout/llm/backends/glm.rb` | GLM provider (image/pdf/websearch formatting) |

---

## Cross-references

- [../user/RunningInference.md](../user/RunningInference.md) — User guide for endpoints and providers.
- [PromptProcessing.md](PromptProcessing.md) — Context management integrated into the backend.
- [../../research/subsys/backends.md](../../research/subsys/backends.md) — Probe-verified subsystem study (registry, shared loop, provider adapters).
