# Backends

A **backend** is an adapter between Scout-AI's internal message format and a
specific LLM provider API (OpenAI, Anthropic, Ollama, vLLM, …). Backends are
stateless module singletons: you never instantiate them, you dispatch to
`Backend.ask` and Ruby's method resolution figures out which provider's
override to call.

This document covers the backend abstraction, the inference loop, endpoint
configuration, caching, the full provider table, and session continuation.

Related docs:

- [../Overview.md](../Overview.md) — where Backends sit in the stack
- [../Chat/Chat.md](../Chat/Chat.md) — the message format backends consume
- [../Chat/PromptStrategies.md](../Chat/PromptStrategies.md) — `prepare_prompt` details
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and execution
- [../Agent/Agent.md](../Agent/Agent.md) — the layer that calls backends

---

## 1. What a backend is

A backend is a **module** under `LLM::` (e.g. `LLM::OpenAI`, `LLM::Anthropic`)
that exposes singleton methods — most importantly `ask`. It:

1. Receives a normalised message array (the internal Chat format).
2. Translates those messages into the provider's wire format.
3. Calls the provider API.
4. Translates the response back into internal messages.
5. Drives the recursive tool-calling loop (`chain_tools`).

Backends never hold conversational state. All state lives in the `Chat` /
`Agent` layers. This keeps backends simple to reason about and trivially
swappable.

---

## 2. Backend composition pattern

There is no abstract base class. Instead, shared logic lives in the
`LLM::Backend::ClassMethods` module, and each provider composes it with its
own overrides via Ruby's `prepend` / `include` on the singleton class:

```ruby
module LLM
  module OpenAIMethods           # provider-specific overrides
    def query(client, messages, tools = [], parameters = {})
      parameters[:messages] = messages
      parameters[:tools]    = format_tool_definitions(tools) if tools&.any?
      client.chat(parameters: parameters)
    end
    # ... other overrides: format_tool_definitions, process_response, etc.
  end

  module OpenAI
    TAG = 'openai'
    DEFAULT_MODEL = 'gpt-5-nano'

    class << self
      prepend OpenAIMethods          # overrides take priority
      include Backend::ClassMethods  # shared implementation (ask, chain_tools, ...)
    end
  end
end
```

| Mechanism | Purpose |
|---|---|
| `prepend ProviderMethods` | Provider overrides dispatch **before** shared methods. |
| `include Backend::ClassMethods` | Provides `ask`, `chain_tools`, `tools`, `embed`, `process_response`, etc. |

Because `ask` lives in `ClassMethods` and calls `self.query`, `self.format_tool_definitions`, etc., Ruby dispatches to the provider's override when one exists. This is the **template method** pattern: `ask` defines the skeleton, each step is overridable.

### 2.1 `TAG` and `DEFAULT_MODEL`

Every backend module defines two constants:

```ruby
TAG = 'openai'               # used in config key resolution (TAG + '_ask', TAG.upcase + '_URL')
DEFAULT_MODEL = 'gpt-5-nano' # fallback model if none configured
```

These are referenced by the shared `client_options` method as `self::TAG` and
`self::DEFAULT_MODEL`.

---

## 3. The inference loop

`Backend::ClassMethods#ask` is the template method that every backend (except
Relay and Bedrock, which have standalone implementations) uses.

### 3.1 High-level flow

```
ask(question, options, &block)
  │
  ├─ 1. options setup: extract return_messages, log_response,
  │      current_meta, relay, process, prompt_strategies
  │
  ├─ 2. messages = self.messages(question, options)
  │      (normalise question → message array)
  │
  ├─ 3a. IF relay:
  │      upload_messages(server, messages, options) → id
  │      response = gather_response(server, id)
  │
  ├─ 3b. ELSE (normal path):
  │      client = prepare_client(options, messages)
  │      prompt = Chat.prepare_prompt(messages, prompt_strategies)
  │      formatted  = format_messages(prompt)
  │      tools      = self.tools(formatted, options)
  │      response   = query(client, formatted, tools, options)
  │
  ├─ 4. IF process: write response to disk, return response
  │
  ├─ 5. reasoning = self.reasoning(response)
  │
  ├─ 6. output = process_response(messages, response, tools, options, &block)
  │      → parses API response into internal messages
  │      → executes tool calls via LLM.process_calls
  │
  ├─ 7. IF log_response: meta = update_meta(response, current_meta)
  │      meta['reas'] = reasoning
  │
  ├─ 8. output = chain_tools(messages, output, tools, options, &block)  ← RECURSIVE
  │
  ├─ 9. Prepend meta message to output
  │
  ├─ 10. Append previous_response_id message if applicable
  │
  └─ 11. Return: Chat (if return_messages) or String (if not)
```

### 3.2 `prepare_prompt` integration

Between message normalisation and the API call, `ask` runs the prompt through
the configured strategies:

```ruby
prompt = Chat.prepare_prompt(messages, prompt_strategies)
```

`Chat.prepare_prompt` (defined in `lib/scout/llm/chat/prompt.rb`) applies a
pipeline of transformations:

- `Proc` → called directly with the prompt.
- Comma-separated string → split into named strategies applied in order.
- Built-in strategies: `'shorten_tools'` (condense tool definitions),
  `'none'` (pass-through).
- Custom strategies can be registered in `REGISTERED_STRATEGIES`.

If `prompt_strategies` is `nil`, a `DEFAULT_CONTEXT_STRATEGY` is used. See
[../Chat/PromptStrategies.md](../Chat/PromptStrategies.md) for the full
strategy catalogue.

### 3.3 `chain_tools` — the recursive tool loop

```ruby
def chain_tools(messages, output, tools, options = {}, &block)
  return output if output == []

  if output.last[:role] == 'function_call_output'
    # A tool was just executed → feed result back to the model
    output + ask(messages + output,
                 options.except(:tool_choice).merge(return_messages: true),
                 &block)
  else
    # Last message is an assistant reply → terminate
    output
  end
end
```

**Termination**: recursion stops when the last message is **not** a
`function_call_output` — i.e. the model produced a final answer without
calling a tool.

**Safeguards**:

- `tool_choice` is stripped on each recursive call (no forced tool loops).
- `max_content_length` truncation protects the context window.
- No explicit iteration cap; model behaviour is expected to converge.

See [../Tools/Tools.md](../Tools/Tools.md#the-calling-protocol) for how tool
results are formatted and appended.

---

## 4. Endpoint configuration

### 4.1 Named endpoints (YAML)

Scout-AI prefers **named endpoints** — short, shareable identifiers backed by
YAML files in:

```
~/.scout/etc/AI/<name>
```

At runtime, `LLM.ask(..., endpoint: :nano)` loads `~/.scout/etc/AI/nano` and
merges its contents as defaults.

Minimum useful keys:

- `backend` — which backend to use
- `model`   — model identifier
- `url`     — server URL (for self-hosted backends)

Any additional keys are passed through to the backend.

#### Examples

`~/.scout/etc/AI/nano` — OpenAI Responses API, small model:

```yaml
backend: responses
model: gpt-5-nano
```

`~/.scout/etc/AI/deep` — higher reasoning effort:

```yaml
backend: responses
model: gpt-5
reasoning_effort: high
text_verbosity: high
```

`~/.scout/etc/AI/anthropic` — Anthropic Messages API:

```yaml
backend: anthropic
model: claude-sonnet-4-5
key: sk-ant-...
```

`~/.scout/etc/AI/ollama` — local Ollama server:

```yaml
backend: ollama
url: http://localhost:11434
model: llama3.1
```

Usage:

```ruby
LLM.ask "Say hi", endpoint: :nano
LLM.ask "Think harder", endpoint: :deep
```

```bash
scout-ai llm ask -e nano "Say hi"
```

### 4.2 Config cascade

Every option is resolved through `Scout::Config.get`, which checks (highest
priority first):

1. **Explicit option** passed in code / options hash.
2. **Environment variable** (from the `env:` list, e.g. `ASK_MODEL`,
   `LLM_MODEL`).
3. **Config file entries** under `~/.scout/etc/config` (e.g.
   `endpoint nano ask`).
4. **Default value**.

Example resolution for the backend:

```ruby
Scout::Config.get(:backend, :ask, :llm,
                  env: 'ASK_BACKEND,LLM_BACKEND',
                  default: :responses)
```

### 4.3 Default endpoint via config

Set a default endpoint in `~/.scout/etc/config`:

```config
# ~/.scout/etc/config
endpoint nano ask
```

Then `scout-ai llm ask "hi"` uses `nano` without `-e`.

---

## 5. Caching

### 5.1 Default-on persistence

`LLM.ask` wraps the backend dispatch in `Persist.persist`:

```ruby
res = Persist.persist(endpoint, :json,
                      prefix: "LLM ask",
                      other: options.merge(messages: messages),
                      persist: persist,
                      dir: Scout.var.cache.ask) do
  # backend dispatch happens here
end
```

- **Default**: `persist: true` — responses are cached on disk.
- **Disable**: pass `persist: false` to force a fresh API call.

### 5.2 Cache key

The cache key is derived from:

- the endpoint name,
- the compiled message array,
- most options (model, tools, format, etc.).

Changing any of these produces a different cache key. This makes chats
reproducible: the same conversation + options returns the cached response
without a new API call.

### 5.3 When caching matters

- **Development / iteration**: caching avoids burning tokens on repeated runs.
- **CI / tests**: caches make runs deterministic.
- **Production with volatile inputs**: use `persist: false` or a unique
  `cache_namespace` to avoid stale responses.

---

## 6. Provider table

| Backend | Module | API style | Tools | Embeddings | Notes |
|---|---|---|---|---|---|
| **responses** (default) | `LLM::Responses` | OpenAI Responses API (`client.responses.create`) | ✅ `function_call` / `function_call_output` | ✅ | Uses all shared `ClassMethods` unchanged. Supports `previous_response_id`. |
| **openai** | `LLM::OpenAI` | Chat Completions (`client.chat`) | ✅ `{type:'function', function:{...}}` | ✅ | Overrides `query`, tool formatting, `process_response`. |
| **anthropic** | `LLM::Anthropic` | Messages API (`client.messages`) | ✅ `tool_use` / `tool_result` | ❌ raises | Overrides many methods. Adds `max_tokens`. Tool defs use `type: 'custom'`. |
| **vllm** | `LLM::VLLM` | OpenAI-compatible Responses API | ✅ same as Responses | ✅ | Includes `ResponsesMethods`. Only overrides `parse_tool_call` (cleans tool-name artifacts). |
| **ollama** | `LLM::OLlama` | Ollama native API | ✅ OpenAI-like | ✅ via `/api/embed` | Overrides client/query/tool formatting. Stubs `update_meta` and `reasoning` (return `nil`). |
| **openwebui** | `LLM::OpenWebUI` | REST (RestClient, not OpenAI gem) | ✅ same as OpenAI | ✅ | Includes `OpenAIMethods`. `client` returns a config Hash; `query` uses `RestClient.post`. |
| **huggingface** | `LLM::Huggingface` | Local Python model (ScoutPython) | ✅ OpenAI-like | ✅ local | Overrides nearly everything. Python subprocess for inference. Extracts `thinking` traces. |
| **bedrock** | `LLM::Bedrock` | AWS Bedrock Runtime | ✅ inline `while` loop | ✅ Titan | **Standalone** — does not include `ClassMethods`. Iterative (not recursive) tool loop. |
| **relay** | `LLM::Relay` | SCP delegation to remote server | N/A (delegated) | N/A | **Standalone** — serialises messages + options, SCPs to a server, polls for response. |

### 6.1 Provider highlights

#### Responses (default)

- TAG: `'responses'`, DEFAULT_MODEL: `'gpt-5-nano'`.
- Uses `client.responses.create(parameters:)` with `parameters[:input]` and
  `parameters[:tools]`.
- Supports `previous_response_id` for server-side conversation threading.
- Parses a flat `response['output']` array of typed items (`message`,
  `function_call`, `mcp_call`, `image_generation_call`, `web_search_call`,
  `reasoning`).

#### OpenAI (Chat Completions)

- TAG: `'openai'`, DEFAULT_MODEL: `'gpt-5-nano'`.
- `query` passes `parameters[:messages]` (not `:input`).
- Tool definitions nested under `{ type: :function, function: {...} }`.
- `process_response` reads `response['choices'][0]`.

#### Anthropic

- TAG: `'anthropic'`, DEFAULT_MODEL: `'claude-sonnet-4-5'`.
- No embeddings (`embed_query` raises).
- Tool definitions use `type: 'custom'` and `input_schema`.
- `extra_options` injects `max_tokens` (default 1000).
- Tool calls processed one content block at a time.

#### Ollama

- TAG: `'ollama'`, DEFAULT_MODEL: `'llama3.1'`.
- Sets `parameters[:stream] = false`.
- `update_meta` and `reasoning` return `nil` (no standard usage data).

#### Bedrock (standalone)

- Uses `Aws::BedrockRuntime::Client`.
- Supports `:messages` and `:prompt` invocation types.
- Tool calling via an inline `while` loop (not `chain_tools`).
- Embeddings via `amazon.titan-embed-text-v1`.

---

## 7. `previous_response_id` — session continuation

The **Responses** backend supports OpenAI's server-side conversation threading.
When `previous_response_id` is provided:

1. Scout-AI keeps only the messages **after** the most recent
   `previous_response_id` marker (so you don't resend the entire history).
2. The ID is passed to the backend, which reconstructs the prior context
   server-side.

```ruby
LLM.ask("Follow up question",
        endpoint: :nano,
        previous_response_id: "resp_abc123")
```

To **disable** session continuation:

```ruby
LLM.ask("...", endpoint: :nano, previous_response: false)
```

This is useful when you want to start a fresh server-side session but keep
the local chat history.

---

## 8. Error handling and retries

### 8.1 Diagnostic capture

The `ask` method wraps `query` and `process_response` in `begin/rescue`. On
failure:

1. Messages, options, and metadata are saved to temporary files
   (`TmpFile.tmp_file + ".chat" / ".options" / ".meta"`).
2. The exception is tagged with `LLM::Backend::BackendException` and given a
   `.chat` accessor pointing at the diagnostic files.
3. The exception is **re-raised** — it is never silently swallowed.

```ruby
begin
  LLM.ask("...", endpoint: :nano)
rescue LLM::Backend::BackendException => e
  puts "Diagnostics at: #{e.chat}"
  raise
end
```

### 8.2 Agent-level retry hook

`LLM::Agent` exposes `agent.process_exception` — a `Proc` called with the
exception. If it returns truthy, the call is retried:

```ruby
agent.process_exception = Proc.new do |e|
  if e.message =~ /rate limit|429/
    sleep 5
    true    # retry
  else
    false   # re-raise
  end
end
```

See [../Agent/Agent.md](../Agent/Agent.md#error-handling).

### 8.3 Relay retry

The Relay backend retries indefinitely (1-second sleep between attempts) until
the response file appears on the remote server. There is no exponential
backoff.

### 8.4 No built-in rate-limit backoff

Scout-AI does **not** implement automatic 429 handling or exponential backoff
in the backend layer. The `request_timeout` option is forwarded to the
underlying HTTP client, but rate-limit errors propagate to the caller. Use the
`process_exception` hook (above) for custom retry policies.

---

## 9. Backend selection

### 9.1 `LLM.ask` dispatch

`LLM.ask` selects a backend via a `case` statement on the `:backend` option:

```ruby
case backend
when :openai      then LLM::OpenAI.ask(...)
when :anthropic   then LLM::Anthropic.ask(...)
when :responses   then LLM::Responses.ask(...)
when :ollama      then LLM::OLlama.ask(...)
when :vllm        then LLM::VLLM.ask(...)
when :openwebui   then LLM::OpenWebUI.ask(...)
when :huggingface then LLM::Huggingface.ask(...)
when :relay       then LLM::Relay.ask(...)
when :bedrock     then LLM::Bedrock.ask(...)
else
  mod = BACKENDS[backend]
  raise "Unknown backend: #{backend}" if mod.nil?
  mod.ask(...)
end
```

### 9.2 Dynamic registration

Third-party backends can be registered at runtime:

```ruby
LLM.register_backend(:my_backend, MyBackendModule)
LLM.ask("...", backend: :my_backend)
```

### 9.3 Default backend

The default is resolved via:

```ruby
Scout::Config.get(:backend, :ask, :llm,
                  env: 'ASK_BACKEND,LLM_BACKEND',
                  default: :responses)
```

So the **Responses API** is the default unless overridden by config or
environment.

---

## 10. Practical examples

### 10.1 Minimal ask

```ruby
LLM.ask "Say hi", endpoint: :nano
# => "Hi there!"
```

### 10.2 With tools

```ruby
tools = LLM.workflow_tools(Baking)
LLM.ask "Bake muffins", tools: tools, endpoint: :nano
```

### 10.3 Return the full message trace

```ruby
messages = LLM.ask "Say hi", endpoint: :nano, return_messages: true
messages.last[:role]     # => "assistant"
messages.last[:content]  # => "Hi there!"
```

### 10.4 Using a local Ollama model

```ruby
LLM.ask "Summarize this", endpoint: :ollama
# ~/.scout/etc/AI/ollama has: backend: ollama, url: http://localhost:11434, model: llama3.1
```

### 10.5 Switching backends per call

```ruby
LLM.ask "Quick answer",    backend: :responses,  model: "gpt-5-nano"
LLM.ask "Deeper analysis", backend: :anthropic,  model: "claude-sonnet-4-5"
LLM.ask "Local inference", backend: :ollama,     model: "llama3.1", url: "http://localhost:11434"
```

### 10.6 Disabling cache for a one-off call

```ruby
LLM.ask "Generate a random story", endpoint: :nano, persist: false
```

---

## 11. File reference

| File | Description |
|---|---|
| `lib/scout/llm/ask.rb` | Top-level `LLM.ask` entry point, backend dispatch, persistence wrapper. |
| `lib/scout/llm/backends/default.rb` | `Backend` module + `ClassMethods` — shared implementation (`ask`, `chain_tools`, `tools`, `embed`). |
| `lib/scout/llm/backends/responses.rb` | Responses API backend (default, no overrides). |
| `lib/scout/llm/backends/openai.rb` | OpenAI Chat Completions backend. |
| `lib/scout/llm/backends/anthropic.rb` | Anthropic Messages API backend. |
| `lib/scout/llm/backends/vllm.rb` | vLLM backend (Responses + tool-name cleanup). |
| `lib/scout/llm/backends/ollama.rb` | Ollama native API backend. |
| `lib/scout/llm/backends/openwebui.rb` | OpenWebUI REST backend (OpenAI-compatible). |
| `lib/scout/llm/backends/huggingface.rb` | HuggingFace local model backend (Python subprocess). |
| `lib/scout/llm/backends/relay.rb` | Remote relay backend (SCP-based). |
| `lib/scout/llm/backends/bedrock.rb` | AWS Bedrock backend (standalone). |
| `lib/scout/llm/chat/prompt.rb` | `Chat.prepare_prompt` — prompt strategy pipeline. |
| `lib/scout/llm/tools/call.rb` | `LLM.process_calls` — tool execution engine. |
