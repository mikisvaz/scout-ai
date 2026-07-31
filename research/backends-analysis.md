> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# 05 — Backend Abstraction, Inference Loop, chain_tools, Error Handling, and Provider Differences

This document describes the LLM backend layer in `lib/scout/llm/backends/`,
the top-level entry point in `lib/scout/llm/ask.rb`, the `chain_tools`
recursive tool-calling loop, error handling and retries, and the differences
between every provider backend.

All paths are relative to the repository root (`/bulk/mvazque2/git/scout-ai`).

---

## Table of Contents

1. [Backend Class Hierarchy](#1-backend-class-hierarchy)
2. [The `ask` Method](#2-the-ask-method)
3. [The `chain_tools` Loop (CRITICAL)](#3-the-chain_tools-loop-critical)
4. [Error Handling and Retries](#4-error-handling-and-retries)
5. [Provider-Specific Differences](#5-provider-specific-differences)
6. [Integration Points](#6-integration-points)
7. [Key Design Patterns](#7-key-design-patterns)

---

## 1. Backend Class Hierarchy

### 1.1 The `Backend` module (default.rb)

There is **no abstract base class** in the traditional OOP sense. Instead, the
shared implementation lives in a Ruby **module** called `LLM::Backend`,
defined in `lib/scout/llm/backends/default.rb` (≈610 lines).

```
LLM::Backend                          # module
  ├── BackendException                # a class used to tag exceptions with a `.chat` accessor
  └── ClassMethods                    # inner module holding ALL shared methods
        ├── client, client_options, prepare_client, extra_options
        ├── query
        ├── process_format, encode_image, encode_pdf, format_other
        ├── format_tool_definitions, format_tool_call, format_tool_output
        ├── format_messages, extract_tools, tools
        ├── messages
        ├── chain_tools               # recursive tool loop
        ├── parse_tool_call
        ├── process_response          # parse API response → internal message list
        ├── update_meta, reasoning
        ├── upload_messages, gather_response   # relay helpers
        ├── ask                       # main entry point (template method)
        ├── image
        └── embed_query, embed
```

### 1.2 How providers compose it

Every backend is a **module** (not a class) that exposes singleton methods.
The composition idiom is:

```ruby
module LLM
  module FooMethods       # provider-specific overrides
    def query(...)
      ...
    end
    # ... other overrides
  end

  module Foo
    TAG = 'foo'
    DEFAULT_MODEL = 'foo-model'

    class << self
      prepend FooMethods            # overrides take priority
      include Backend::ClassMethods # shared implementation
    end
  end
end
```

Key mechanics:

| Mechanism | Purpose |
|---|---|
| `class << self; prepend FooMethods; end` | Provider-specific overrides (e.g. `query`, `process_response`) are dispatched **before** the shared methods. |
| `class << self; include Backend::ClassMethods; end` | Shared methods (`ask`, `chain_tools`, `tools`, `embed`, etc.) come from the included module. |
| `prepend` (not `include`) for overrides | Ruby MRO ensures `FooMethods#query` shadows `Backend::ClassMethods#query`. |

This allows the shared `ask` method to call `self.query(...)`, `self.format_tool_call(...)`, etc., and Ruby dispatches to the **provider-specific** version when one exists.

### 1.3 The Backend Registry / How a Backend Is Selected

The top-level `LLM.ask` (in `ask.rb`) selects a backend in two ways:

**A. Hard-coded `case` dispatch** (for built-in backends):

```ruby
case backend
when :openai, "openai"     then LLM::OpenAI.ask(...)
when :anthropic, "anthropic" then LLM::Anthropic.ask(...)
when :responses, "responses" then LLM::Responses.ask(...)
when :ollama, "ollama"     then LLM::OLlama.ask(...)
when :vllm, "vllm"         then LLM::VLLM.ask(...)
when :openwebui, "openwebui" then LLM::OpenWebUI.ask(...)
when :huggingface, "huggingface" then LLM::Huggingface.ask(...)
when :relay, "relay"       then LLM::Relay.ask(...)
when :bedrock, "bedrock"   then LLM::Bedrock.ask(...)
else
  mod = BACKENDS[backend]
  raise "Unknown backend: #{backend}" if mod.nil?
  mod.ask(...)
end
```

**B. Dynamic registry** (for plugins / user-registered backends):

```ruby
BACKENDS = IndiferentHash.setup({})

def self.register_backend(name, mod)
  BACKENDS[name] = mod
end
```

Third-party code can call `LLM.register_backend(:my_backend, MyModule)` and
then pass `backend: :my_backend` in options.

**Default backend**: `Scout::Config.get(:backend, :ask, :llm, env:
'ASK_BACKEND,LLM_BACKEND', default: :responses)` — the **Responses API**
backend is the default.

### 1.4 TAG and DEFAULT_MODEL constants

Every backend module defines two constants used by `client_options`:

```ruby
TAG = 'openai'               # used in config key resolution: TAG + '_ask', TAG.upcase + '_URL'
DEFAULT_MODEL = 'gpt-5-nano' # fallback model if none configured
```

These are referenced via `self::TAG` and `self::DEFAULT_MODEL` in the shared
`client_options` method.

---

## 2. The `ask` Method

### 2.1 Full Signature

```ruby
def ask(question, options = {}, &block)
```

**Location**: `LLM::Backend::ClassMethods#ask` in `default.rb`, line ~476.

### 2.2 Parameters

| Parameter | Type | Description |
|---|---|---|
| `question` | String, Array (chat messages), or Chat object | The user's input. Converted to messages via `self.messages(question, options)`. |
| `options` | Hash (IndiferentHash) | Options hash. Key entries: |
| `options[:backend]` | Symbol/String | Backend selector (e.g. `:responses`, `:openai`). |
| `options[:tools]` | Array of tool definitions | Tools made available to the model. |
| `options[:model]` | String | Model identifier. |
| `options[:url]` | String | API endpoint URL. |
| `options[:key]` | String | API key. |
| `options[:return_messages]` | Boolean | If `true`, returns the full message array (including meta, tool calls); if `false`, returns just the final text content. Default: `false`. |
| `options[:log_response]` | Boolean | Whether to compute/store metadata (token counts). Default: `true`. |
| `options[:current_meta]` | Hash | Accumulated metadata from prior calls (token counts). |
| `options[:relay]` | String | Server hostname for relay mode. If set, the query is dispatched via SCP to a remote server. |
| `options[:process]` | String | If set, the raw response JSON is written to `Scout.var.query.response[process]` and returned immediately (no further processing). |
| `options[:prompt_strategies]` | String/Proc/Array | Controls how messages are prepared before inference (see Integration Points). |
| `options[:previous_response_id]` | String | OpenAI Responses API conversation threading ID. |
| `options[:previous_response]` | String/Boolean | If `'false'`, disables `previous_response_id` propagation. |
| `options[:format]` | Symbol/String/Hash | Output format control (JSON, json_schema, etc.). |
| `options[:websearch]` | Boolean | If truthy, appends a `{role: 'websearch', content: true}` message. |
| `options[:tool_choice]` | Various | Passed through to provider. Removed during `chain_tools` recursion. |
| `&block` | Block | If provided, called as `block.call(function_name, function_arguments)` for each tool call when no matching tool object is found. Used by `LLM.workflow_ask` and `LLM.knowledge_base_ask`. |

### 2.3 Return Value

| Mode | Return type |
|---|---|
| `return_messages: true` | `Chat` (Array of message hashes), including `{role: :meta}`, `{role: 'function_call'}`, `{role: 'function_call_output'}`, `{role: 'assistant'}`, etc. |
| `return_messages: false` (default) | `String` — the last assistant message's `content`, after purging non-content messages. Returns `''` if no content. |
| `process:` set | Raw response Hash (JSON), written to disk and returned. |
| `relay:` set | Hash (parsed JSON) from the remote server. |

### 2.4 High-Level Flow of `Backend#ask`

```
ask(question, options, &block)
  │
  ├─ 1. options setup: extract return_messages, log_response, current_meta, relay, process, prompt_strategies
  │
  ├─ 2. messages = self.messages(question, options)  # normalize question → message array
  │
  ├─ 3a. IF relay:
  │      upload_messages(server, messages, options) → id
  │      response = gather_response(server, id)
  │
  ├─ 3b. ELSE (normal path):
  │      client = prepare_client(options, messages)
  │      prompt = Chat.prepare_prompt(messages, prompt_strategies)
  │      formatted_prompt = format_messages(prompt)
  │      tools = self.tools(formatted_prompt, options)
  │      response = query(client, formatted_prompt, tools, options)
  │
  ├─ 4. IF process: write response to disk, return response
  │
  ├─ 5. reasoning = self.reasoning(response)
  │
  ├─ 6. output = process_response(messages, response, tools, options, &block)
  │      → parses API response into internal message format
  │      → executes tool calls via LLM.process_calls
  │
  ├─ 7. IF log_response: meta = update_meta(response, current_meta); meta['reas'] = reasoning
  │
  ├─ 8. output = chain_tools(messages, output, tools, options, &block)  ← RECURSIVE
  │
  ├─ 9. Prepend meta message to output
  │
  ├─ 10. Append previous_response_id message if applicable
  │
  └─ 11. Return: Chat (if return_messages) or String (if not)
```

---

## 3. The `chain_tools` Loop (CRITICAL)

`chain_tools` is the **recursive tool-calling loop** that allows the model to
make multiple rounds of tool calls. It is the heart of Scout-AI's agentic
capability.

### 3.1 Location and Signature

```ruby
def chain_tools(messages, output, tools, options = {}, &block)
```

`default.rb`, line ~342.

### 3.2 How It Works — Step by Step

```ruby
def chain_tools(messages, output, tools, options = {}, &block)
  previous_response_id = options[:previous_response_id]

  return output if output === []              # guard: empty output

  raise "Output format unknown" unless        # guard: last message must be a hash with :role
    Hash === output.last && output.last.include?(:role)

  if output.last[:role] == 'function_call_output'
    # The last message is a tool result → feed it back to the model
    case previous_response_id
    when String
      # OpenAI Responses API: can use previous_response_id for threading
      output + ask(output, options.except(:tool_choice)
                              .merge(return_messages: true,
                                     previous_response_id: previous_response_id), &block)
    else
      # Generic path: re-send full conversation including tool outputs
      output + ask(messages + output, options.except(:tool_choice)
                                          .merge(return_messages: true), &block)
    end
  else
    # Last message is NOT a function_call_output → loop terminates
    output
  end
end
```

### 3.3 The Recursive Loop in Detail

```
┌──────────────────────────────────────────────────────────────┐
│  Backend#ask (iteration 1)                                    │
│    query(client, ...) → response                              │
│    process_response(messages, response, tools, ...)           │
│      → extracts tool_calls from response                      │
│      → LLM.process_calls(tools, tool_calls, &block)           │
│      → returns [function_call_msg, function_call_output_msg]  │
│    output.last[:role] == 'function_call_output'  → YES        │
│    chain_tools(messages, output, tools, options)              │
│      ┌────────────────────────────────────────────────────┐   │
│      │  Recursive call to ask (iteration 2)               │   │
│      │    messages + output → query → response            │   │
│      │    process_response → more tool calls?             │   │
│      │      YES → recurse again                           │   │
│      │      NO  → output.last is 'assistant' → return     │   │
│      └────────────────────────────────────────────────────┘   │
│    output = chain_tools result                                 │
│    return final output                                         │
└──────────────────────────────────────────────────────────────┘
```

**Termination condition**: The recursion stops when `output.last[:role]` is
**not** `'function_call_output'`. This happens when:

1. The model returns a text/assistant response **without** any tool calls.
2. `process_response` produces only assistant messages (no tool calls were
   detected in the API response).

**Each iteration of the loop:**

1. **Ask** the model with the current messages (including previous tool call results).
2. **Process** the response: `process_response` extracts any tool calls, executes them via `LLM.process_calls`, and produces function_call / function_call_output messages.
3. **Check**: if the last message is `function_call_output` (i.e., a tool was just called), the loop continues.
4. **Recurse**: call `ask` again with the accumulated messages + tool outputs.

### 3.4 How Tool Results Are Appended to the Chat

Tool results are produced by `LLM.process_calls` (in
`lib/scout/llm/tools/call.rb`). For each tool call, it returns a **pair** of
messages:

```ruby
[
  { role: "function_call",       content: tool_call.to_json },  # the call itself
  { role: "function_call_output", content: result.to_json }     # the result
]
```

These pairs are concatenated into the `output` array. When the loop recurses,
`messages + output` is passed as the new question to `ask`, which feeds the
full conversation (including tool calls and results) back to the model.

The `format_messages` method in `Backend::ClassMethods` then transforms these
internal roles into provider-specific formats:

| Internal role | Default (Responses API) | OpenAI (Chat Completions) | Anthropic |
|---|---|---|---|
| `function_call` | `{type: 'function_call', name:..., arguments:..., call_id:...}` | `{role: 'assistant', tool_calls: [{type:'function', function:{name:..., arguments:...}}]}` | `{role: 'assistant', content: [{type:'tool_use', id:..., name:..., input:...}]}` |
| `function_call_output` | `{type: 'function_call_output', output:..., call_id:...}` | `{role: 'tool', tool_call_id:..., content:...}` | `{role: 'user', content: [{type:'tool_result', tool_use_id:..., content:...}]}` |

### 3.5 Maximum Iterations / Safeguards

**There is no explicit maximum iteration count.** The `chain_tools` method
recurses indefinitely until the model stops requesting tool calls.

However, several implicit safeguards exist:

1. **Model behavior**: The model is expected to eventually stop calling tools and produce a final answer.
2. **`tool_choice` is stripped**: Each recursive call uses `options.except(:tool_choice)`, preventing forced tool selection from causing infinite loops.
3. **Token limits / API limits**: Provider API limits (max tokens, rate limits) will eventually cause errors.
4. **`max_content_length`**: In `LLM.process_calls`, if a tool result exceeds
   `LLM.max_content_length` (default: 100,000 characters, configurable via
   `Scout::Config.get(:max_content_length, ...)`), the result is replaced with
   an exception message instead of being fed back to the model.

> **⚠ Design note**: The lack of an explicit recursion limit is a potential
> concern for robustness. If a model continuously calls tools without
> producing a final answer, the system will recurse until a stack overflow or
> API error occurs.

---

## 4. Error Handling and Retries

### 4.1 Error Handling in `Backend#ask`

The `ask` method has two major `rescue` blocks, both in the non-relay path:

**A. Query errors** (calling `query(client, ...)`):

```ruby
response = begin
  query(client, formatted_prompt, tools, options)
rescue Exception => e
  # Save diagnostic information
  tmpfile = TmpFile.tmp_file
  Open.write tmpfile + ".chat", Chat.print(messages)
  Open.write tmpfile + ".options", options.except(:messages, :tools).to_json
  Open.write tmpfile + ".meta", current_meta.to_json
  Log.warn "Messages and options saved in #{tmpfile}"

  e.extend LLM::Backend::BackendException   # tag the exception
  e.chat tmpfile                              # attach the tmpfile path

  raise e                                     # re-raise
end
```

**B. `process_response` errors**:

```ruby
output = begin
  process_response(messages, response, tools, options, &block)
rescue Exception => e
  # Same pattern: save diagnostics, tag exception, re-raise
  ...
  raise e
end
```

In both cases:
- Messages and options are saved to temporary files for debugging.
- The exception is tagged with `BackendException` and given a `.chat` accessor pointing to the diagnostic files.
- The exception is **re-raised** — it is NOT silently swallowed.

### 4.2 Relay Retry Logic

The relay backend (`gather_response` and `Relay.gather`) uses a **retry loop**:

```ruby
def gather_response(server, id)
  TmpFile.with_file do |file|
    begin
      CMD.cmd("scp #{server}:.../response/#{id}.json #{file}")
      JSON.parse(Open.read(file))
    rescue
      sleep 1
      retry       # infinite retry with 1-second sleep
    end
  end
end
```

This retries indefinitely until the response file appears on the remote server.

### 4.3 `chain_tools` Error Handling

```ruby
begin
  ask(output, options.except(:tool_choice).merge(...), &block)
rescue Exception
  raise $!   # re-raise immediately
end
```

No retry logic inside `chain_tools`. If a recursive call fails, the error
propagates up.

### 4.4 No Explicit Rate-Limiting / Backoff

There is **no built-in rate-limit handling** (429 retries, exponential
backoff, etc.) in the Scout-AI backend layer. The `request_timeout` option
(default: 12000 for client creation, 1200 in `client_options`) is passed to
the underlying HTTP client (e.g., `OpenAI::Client`), but Scout-AI itself does
not catch rate-limit errors and retry them.

### 4.5 Bedrock Inline Tool Loop (Separate Implementation)

The Bedrock backend (`lib/scout/llm/backends/bedrock.rb`) implements its own
**`while` loop** for tool calling, bypassing `chain_tools` entirely:

```ruby
tool_calls = message.dig('content').select{|m| m['tool_calls']}
while tool_calls && tool_calls.any?
  messages << message
  tool_calls.each do |tool_call|
    response_message = LLM.tool_response(tool_call, &block)
    messages << response_message
  end
  # re-invoke model
  response = client.invoke_model(...)
  result = JSON.parse(response.body.string)
  message = result
  tool_calls = message.dig('content').select{|m| m['tool_calls']}
end
```

This is an iterative (not recursive) loop, but like `chain_tools`, it has no
explicit iteration limit.

---

## 5. Provider-Specific Differences

### 5.1 Summary Table

| Backend | File | API Style | Tool Format | Embeddings | Notes |
|---|---|---|---|---|---|
| **Responses** (default) | `responses.rb` | OpenAI Responses API (`client.responses.create`) | `function_call` / `function_call_output` types | ✅ | Uses all default `Backend::ClassMethods`. No overrides. |
| **OpenAI** | `openai.rb` | OpenAI Chat Completions API (`client.chat`) | `{type:'function', function:{...}}` | ✅ | Overrides `query`, `format_tool_definitions`, `format_tool_call`, `format_tool_output`, `parse_tool_call`, `process_response`. |
| **Anthropic** | `anthropic.rb` | Anthropic Messages API (`client.messages`) | `{type:'custom', input_schema:...}` / `tool_use` / `tool_result` | ❌ (`raise 'Anthropic does not offer embeddings'`) | Overrides `client`, `query`, `format_tool_definitions`, `format_tool_call`, `format_tool_output`, `parse_tool_call`, `process_response`, `extra_options`, `embed_query`. |
| **vLLM** | `vllm.rb` | OpenAI-compatible Responses API | Same as Responses | ✅ | Includes `ResponsesMethods`. Only overrides `parse_tool_call` (strips channel artifacts from tool names). |
| **Ollama** | `ollama.rb` | Ollama native API (`Ollama.new(...)`) | `{type:'function', function:{...}}` (like OpenAI) | ✅ (via `/api/embed`) | Overrides `client`, `query`, `embed_query`, `parse_tool_call`, `process_response`, `format_tool_definitions`, `format_tool_call`, `format_tool_output`, `extra_options`. Stubs out `update_meta` and `reasoning` (return `nil`). |
| **OpenWebUI** | `openwebui.rb` | REST API (RestClient, not OpenAI gem) | Same as OpenAI | ✅ | Includes `OpenAIMethods`. Overrides `client` (returns a config hash, not a client object), `query` (manual HTTP POST), `parse_tool_call`. |
| **HuggingFace** | `huggingface.rb` | Local Python model via ScoutPython (`CausalModel`) | `{type:'function', function:{...}}` | ✅ (via local model) | Overrides nearly everything: `prepare_client`, `query`, `format_tool_definitions`, tool formatting, `parse_tool_call`, `process_response`, `tools`, `reasoning`, `embed`. Uses a Python subprocess for inference. |
| **Relay** | `relay.rb` | SCP-based delegation to remote server | N/A (delegated) | N/A | Standalone module, does NOT include `Backend::ClassMethods`. Uploads serialized messages/options via SCP, polls for response. |
| **Bedrock** | `bedrock.rb` | AWS Bedrock Runtime (`Aws::BedrockRuntime::Client`) | Limited (inline `while` loop) | ✅ | Standalone module, does NOT include `Backend::ClassMethods`. Has its own `ask` with iterative tool loop. Supports `:messages` and `:prompt` types. |

### 5.2 Detailed Provider Notes

#### Responses (Default Backend)

- **Module**: `LLM::Responses`
- **TAG**: `'responses'`, **DEFAULT_MODEL**: `'gpt-5-nano'`
- **API**: OpenAI Responses API via `client.responses.create(parameters:)`.
- **Methods module**: `ResponsesMethods` — empty, no overrides.
- Uses **all** shared `Backend::ClassMethods` unchanged.
- The default `query` method passes `parameters[:input] = messages` and `parameters[:tools] = formatted_tools`.
- Supports `previous_response_id` for conversation threading (OpenAI server-side state).
- Parses responses with `response['output']` — a flat array of typed items (`message`, `function_call`, `mcp_call`, `image_generation_call`, `web_search_call`, `reasoning`).

#### OpenAI (Chat Completions)

- **Module**: `LLM::OpenAI`
- **TAG**: `'openai'`, **DEFAULT_MODEL**: `'gpt-5-nano'`
- **API**: `client.chat(parameters:)` — the classic Chat Completions endpoint.
- Key differences from Responses:
  - `query`: passes `parameters[:messages]` instead of `parameters[:input]`.
  - `format_tool_definitions`: wraps definitions in `{type: :function, function: {...}}` (nested structure).
  - `format_tool_call`: produces `{role: 'assistant', tool_calls: [...]}`.
  - `format_tool_output`: produces `{role: 'tool', tool_call_id: ..., content: ...}`.
  - `parse_tool_call`: extracts `function.name`, `function.arguments`, `id`.
  - `process_response`: reads `response['choices'][0]['message']` and `response['choices'][0]['tool_calls']`.

#### Anthropic

- **Module**: `LLM::Anthropic`
- **TAG**: `'anthropic'`, **DEFAULT_MODEL**: `'claude-sonnet-4-5'`
- **API**: `client.messages(parameters:)`.
- **No embeddings** — `embed_query` raises an exception.
- `extra_options` adds `max_tokens` (default 1000) and maps `format` to `response_format`.
- `client` method creates an `Anthropic::Client` directly (ignores URL from options).
- Tool definitions use `type: 'custom'` (not `'function'`) and `input_schema` (not `parameters`).
- `format_tool_call`: produces `{role: 'assistant', content: [{type:'tool_use', ...}]}`.
- `format_tool_output`: produces `{role: 'user', content: [{type:'tool_result', tool_use_id:..., content:...}]}`.
- `process_response`: iterates `response[:content]`, handling `text`, `reasoning`, `tool_use`, and `web_search_call` types. Tool calls are processed **one at a time** per content block (not batched).

#### vLLM

- **Module**: `LLM::VLLM`
- **TAG**: `'vllm'`, **DEFAULT_MODEL**: `'vllm'`
- Includes `ResponsesMethods` (same as the Responses backend).
- Only override: `parse_tool_call` — calls `super` then strips a regex pattern (`/[^a-zA-Z_]+channel[^a-zA-Z_]+[a-zA-Z_]+/`) from the tool name to clean up artifacts from vLLM's tool name generation.

#### Ollama

- **Module**: `LLM::OLlama`
- **TAG**: `'ollama'`, **DEFAULT_MODEL**: `'llama3.1'`
- **API**: `Ollama.new(credentials: {address:, bearer_token:})` → `client.chat(parameters)`.
- Sets `parameters[:stream] = false` explicitly.
- Tool definitions use the OpenAI-like `{type: :function, function: {...}}` format.
- `update_meta`: **returns nil** (Ollama doesn't provide token usage in a standard way).
- `reasoning`: **returns nil** (no reasoning extraction).
- `parse_tool_call`: generates ID from `name + '_' + Misc.digest(arguments)` if no ID provided.
- `process_response`: iterates over `responses` (array of response chunks), handles both `response['tool_calls']` and `response['message']['tool_calls']`.
- Embeddings: calls `client.request('api/embed', parameters)`.

#### OpenWebUI

- **Module**: `LLM::OpenWebUI`
- **TAG**: `'openwebui'`, **DEFAULT_MODEL**: `'llama3.1'`
- Includes `OpenAIMethods` (reuses all OpenAI overrides).
- `client` method: returns a **plain Hash** (not a client object) with `base_url`, `key`, `model`, `method`, `action`.
- `query` method: uses `RestClient.post` directly (not the OpenAI gem). Sets `verify_ssl: false`, configures timeouts.
- `parse_tool_call`: similar to OpenAI but generates ID from `name + '_' + Misc.digest(arguments)`.

#### HuggingFace

- **Module**: `LLM::Huggingface`
- **TAG**: `'huggingface'`, **DEFAULT_MODEL**: `nil`
- **API**: Local Python inference via `ScoutPython` → `CausalModel`.
- `prepare_client`: loads a Python causal language model. Supports extensive model options (`checkpoint`, `dir`, `chat_template`, `generation_kwargs`, `torch_dtype`, `device_map`, etc.).
- `query`: calls `client.chat(messages, formatted_tools, parameters)` and converts Python dict result to Ruby hash.
- `reasoning`: extracts `message[:thinking]` (thinking/reasoning traces from models like QwQ).
- `tools` method override: filters out messages with `role == 'tool'` that have `tool_call_id` or `name` before collecting tool definitions from chat.
- Embeddings: loads model with `task: 'Embedding'` and calls `model.eval(text)` or `model.eval_list(text)`.

#### Relay

- **Module**: `LLM::Relay`
- **Does NOT include `Backend::ClassMethods`** — fully standalone.
- `ask` method: serializes question + options to a temp JSON file, SCPs it to a remote server, polls for the response.
- No tool calling, no formatting, no embeddings — all delegated to the remote server.

#### Bedrock

- **Module**: `LLM::Bedrock`
- **Does NOT include `Backend::ClassMethods`** — fully standalone.
- Uses `Aws::BedrockRuntime::Client`.
- Supports two invocation types: `:messages` (structured messages) and `:prompt` (plain text prompt).
- Tool calling: inline `while` loop (not recursive `chain_tools`).
- Embeddings: uses `amazon.titan-embed-text-v1` by default.

---

## 6. Integration Points

### 6.1 How `prepare_prompt` Is Called Before Inference

In `Backend#ask` (the shared template method), after preparing the client:

```ruby
prompt = Chat.prepare_prompt(messages, prompt_strategies)
```

`Chat.prepare_prompt` is defined in `lib/scout/llm/chat/prompt.rb`:

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil)
  return prompt_strategies.call(prompt) if Proc === prompt_strategies
  prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
  prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies
  prompt_strategies.each do |strategy|
    prompt = case strategy
             when 'shorten_tools' then Chat.shorten_tools(prompt)
             when 'none'          then prompt
             else strategy_proc = REGISTERED_STRATEGIES[strategy]
                  strategy_proc.call(prompt)
             end
  end
  prompt
end
```

- `prompt_strategies` can be: a `Proc` (called directly), a comma-separated string of named strategies, or an array.
- If `nil`, uses `DEFAULT_CONTEXT_STRATEGY`.
- Registered strategies can be added to `REGISTERED_STRATEGIES`.
- `'shorten_tools'` is a built-in strategy that condenses tool definitions.
- `'none'` is a pass-through.

### 6.2 How Tools Are Passed to the Backend

Tools enter the system through multiple channels and are merged in `Backend#tools`:

```ruby
def tools(messages, options)
  tools = options.delete :tools    # 1. Explicit tools from options

  # Normalize Array → Hash keyed by name
  case tools
  when Array  then tools = tools.inject({}){|acc, d| ... }
  when nil    then tools = {}
  end

  tools.merge!(LLM.tools messages)        # 2. Tools from chat 'tool'/'mcp' messages
  tools.merge!(LLM.associations messages) # 3. Associations from chat 'associate' messages

  tools
end
```

**Sources of tools:**

| Source | How |
|---|---|
| `options[:tools]` | Explicitly passed as an Array of tool definitions. |
| Chat messages with `role: 'tool'` | `LLM.tools(messages)` extracts workflow/task tool definitions from messages. Supports local workflows, remote workflows, and specific tasks. |
| Chat messages with `role: 'mcp'` | `LLM.tools(messages)` connects to MCP (Model Context Protocol) servers and loads their tool definitions. Supports both HTTP and stdio transports. |
| Chat messages with `role: 'introduce'` | `LLM.tools(messages)` loads all tasks from a workflow as tool definitions. |
| Chat messages with `role: 'associate'` | `LLM.associations(messages)` extracts knowledge-base association tools. |

The resulting `tools` is a Hash: `{ tool_name => [obj, definition] }` where
`obj` is a `Proc`, `Workflow`, `KnowledgeBase`, `String` (workflow name), or
`nil` (use block).

### 6.3 How Responses Are Parsed

Each backend overrides `process_response(messages, response, tools, options, &block)`:

**Default (Responses API)**:
1. Extract `function_call` / `mcp_call` items from `response['output']`.
2. Parse them into `{name:, arguments:, id:}` via `parse_tool_call`.
3. Execute all tool calls via `LLM.process_calls(tools, tool_calls, &block)`.
4. Build output array: for each `response['output']` item, produce the appropriate message(s):
   - `message` → `{role: 'assistant', content: text}`
   - `function_call` / `mcp_call` → the tool call + tool output pair
   - `image_generation_call` → `{role: 'image', content: output}`
   - `reasoning` → skipped
   - `web_search_call` → skipped
5. Set `options[:previous_response_id]` from `response['id']` for threading.

**OpenAI (Chat Completions)**:
1. Check for `response['error']` → raise if present.
2. Extract `response['choices'][0]['message']`.
3. Check for `response['choices'][0]['tool_calls']` or nested.
4. If tool calls exist: parse and execute via `LLM.process_calls`.
5. If no tool calls: return `[{role: 'assistant', content: ...}]`.

**Anthropic**:
1. Iterate `response[:content]` array.
2. For each block: `text` → assistant message; `tool_use` → parse + execute; `reasoning` / `web_search_call` → skip.
3. Tool calls processed individually (not batched).

**Ollama**:
1. Iterate response chunks.
2. Skip empty assistant messages with no tool calls.
3. If `tool_calls` present: parse and execute.
4. Otherwise return the message.

**HuggingFace**:
1. Extract `response['message']['content']`.
2. Check `response['message']['tool_calls']`.
3. Build output: assistant text (if content), then tool call results (if any).

### 6.4 `LLM.process_calls` — The Tool Execution Engine

Located in `lib/scout/llm/tools/call.rb`. For each tool call:

1. **Look up** the tool by name in the `tools` hash → `[obj, definition]`.
2. **Merge defaults** from `definition[:parameters][:defaults]` into arguments.
3. **Execute** the tool:
   - `Proc` → `obj.call(function_name, function_arguments)`
   - `String` (workflow name) → load workflow and call task
   - `Workflow` → `call_workflow(obj, function_name, arguments)`
   - `KnowledgeBase` → `call_knowledge_base(obj, function_name, arguments)`
   - `else` → `block.call(function_name, function_arguments)` if block given
4. **Process results**: handle `Step` (run/produce job), `LLM::Agent` (ask agent), `String`, `IO`, `TSV::Dumper`, `Exception`, `nil`.
5. **Content length guard**: if result > `max_content_length` (100k chars), replace with exception message (optionally referencing persisted Step path).
6. **Return**: pairs of `[function_call_message, function_call_output_message]`.
7. **Agent parallelism**: agents returned by tools are asked in parallel using `Open.traverse` with configurable CPU count (`Scout::Config.get(:cpus, :agent_ask, default: 3)`).

---

## 7. Key Design Patterns

### 7.1 Strategy Pattern for Providers

Each backend module is a **strategy** for LLM inference. The `LLM.ask` entry
point selects which strategy to use via the `backend` option. All strategies
share the same interface: `ask(question, options, &block)`.

### 7.2 Template Method for `ask`

`Backend::ClassMethods#ask` is a **template method**: it defines the skeleton
of the algorithm (prepare → query → process → chain → return), while
delegating specific steps to overridable methods:

| Step | Overridable Method | Default (Responses) |
|---|---|---|
| Create client | `client(options)` | `OpenAI::Client.new(...)` |
| Prepare client | `prepare_client(options, messages)` | Standard flow |
| Prepare prompt | `Chat.prepare_prompt(...)` | External (shared) |
| Format messages | `format_messages(messages)` | Responses API format |
| Collect tools | `tools(messages, options)` | Standard flow |
| Execute query | `query(client, messages, tools, params)` | `client.responses.create(...)` |
| Parse response | `process_response(...)` | Responses API parsing |
| Tool loop | `chain_tools(...)` | Shared (recursive) |
| Update metadata | `update_meta(response, meta)` | Token counting |
| Extract reasoning | `reasoning(response)` | From `choices[0].message.reasoning_content` |

### 7.3 Module Composition via `prepend` + `include`

The backend composition pattern is the core architectural choice:

```ruby
class << self
  prepend ProviderMethods        # overrides (higher priority)
  include Backend::ClassMethods  # shared implementation (lower priority)
end
```

This is Ruby's MRO (Method Resolution Order) used as a dependency injection
mechanism. The comment block at the top of `default.rb` explains why:

> *This file used to expose its API by doing `extend Backend` in each backend
> module. That worked for simple overrides, but other backends (notably
> OpenWebUI) started **copying** singleton methods from another backend.
> Copying/binding singleton methods breaks Ruby's internal dispatch because
> internal calls stay bound to the original receiver.*

The `prepend` approach ensures that when the shared `ask` method calls
`self.query(...)`, Ruby dispatches to the provider's override, not the default.

### 7.4 IndiferentHash — Pervasive Option Normalization

Throughout the codebase, `IndiferentHash.process_options` is used to extract
and set defaults for option keys in a symbol/string-agnostic way. This is a
convention that makes the API tolerant of different key types (`:model` vs
`'model'`).

### 7.5 Chat as a Universal Message Format

Internally, all backends use a common message format with roles like
`system`, `user`, `assistant`, `tool`, `function_call`,
`function_call_output`, `meta`, `websearch`, `image`, `pdf`,
`previous_response_id`. The `format_messages` method (overridden per provider)
transforms these into API-specific formats. This decoupling allows the same
chat history to be sent to any provider.

### 7.6 Relay Pattern — Remote Delegation

The `relay` option in `ask` and the standalone `LLM::Relay` module implement a
**remote delegation pattern**: serialize the full conversation + options, send
them to a remote server via SCP, and poll for the response. This allows running
LLM queries on a machine with different credentials, models, or network
access.

### 7.7 Persistence / Caching Layer

`LLM.ask` wraps the backend call in `Persist.persist(...)`:

```ruby
res = Persist.persist(endpoint, :json, prefix: "LLM ask",
                      other: options.merge(messages: messages),
                      persist: persist, dir: Scout.var.cache.ask) do
  # backend dispatch happens here
end
```

This caches responses based on the endpoint + options + messages, avoiding
redundant API calls. Can be disabled with `persist: false`.

### 7.8 Endpoint Configuration Files

```ruby
endpoint ||= Scout::Config.get(:endpoint, :ask, :llm, env: 'ASK_ENDPOINT,...')
if endpoint && Scout.etc.AI[endpoint].find_with_extension(:yaml).exists?
  options = IndiferentHash.add_defaults options, Scout.etc.AI[endpoint].yaml
end
```

Named endpoints can be defined as YAML files in `~/.scout/etc/AI/<name>.yaml`,
providing preset configurations (model, URL, key, backend, etc.).

---

## Appendix A: File Reference

| File | Lines | Description |
|---|---|---|
| `lib/scout/llm/ask.rb` | ~126 | Top-level `LLM.ask` entry point, backend dispatch, persistence. |
| `lib/scout/llm/backends/default.rb` | ~610 | `Backend` module with `ClassMethods` — shared implementation. |
| `lib/scout/llm/backends/responses.rb` | ~26 | Responses API backend (default, no overrides). |
| `lib/scout/llm/backends/openai.rb` | ~110 | OpenAI Chat Completions backend. |
| `lib/scout/llm/backends/anthropic.rb` | ~107 | Anthropic Messages API backend. |
| `lib/scout/llm/backends/vllm.rb` | ~28 | vLLM backend (Responses + tool name cleanup). |
| `lib/scout/llm/backends/ollama.rb` | ~130 | Ollama native API backend. |
| `lib/scout/llm/backends/openwebui.rb` | ~85 | OpenWebUI REST backend (OpenAI-compatible). |
| `lib/scout/llm/backends/huggingface.rb` | ~190 | HuggingFace local model backend (Python subprocess). |
| `lib/scout/llm/backends/relay.rb` | ~38 | Remote relay backend (SCP-based). |
| `lib/scout/llm/backends/bedrock.rb` | ~110 | AWS Bedrock backend (standalone). |
| `lib/scout/llm/tools/call.rb` | ~150 | `LLM.process_calls` — tool execution engine. |
| `lib/scout/llm/chat/prompt.rb` | ~140 | `Chat.prepare_prompt` — prompt strategy pipeline. |
| `lib/scout/llm/chat/process/tools.rb` | ~250+ | `LLM.tools` / `LLM.associations` — tool extraction from chat. |
