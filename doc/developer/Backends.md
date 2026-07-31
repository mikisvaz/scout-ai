# Backends

This document describes how the LLM backend abstraction works internally:
the module composition pattern, the inference loop, error handling, and
provider differences. It is intended for framework contributors.

> For the user-facing guide on configuring inference endpoints and providers,
> see [../user/RunningInference.md](../user/RunningInference.md).
> For deep code investigation, see
> [../../research/backends-analysis.md](../../research/backends-analysis.md).

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

There is no hard loop counter. Instead, the `shorten_tools` prompt strategy
bounds the conversation depth: tool calls beyond `MAX_TOOL_CALLS` (40) are
dropped from the prompt, and tool outputs beyond `MAX_TOOL_OUTPUTS` are
truncated or dropped. This naturally constrains how many tool-call rounds a
conversation can sustain.

---

## Error handling and retries

Backends wrap the API call in `begin/rescue`:

- **`BackendException`** — A custom exception class tagged with a `.chat`
  accessor so callers can inspect the chat that caused the failure.
- **Retry policy** — On transient errors (rate limits, timeouts), the backend
  retries with exponential backoff.
- **Agent-level exception handling** — `Agent#ask` wraps the backend call and
  delegates to `@process_exception` (a user-supplied Proc) if set, which may
  trigger a `retry`.

---

## Backend selection

`LLM.ask` selects a backend via:

1. **Explicit `:backend` option** — `options[:backend]` selects the module.
2. **Endpoint configuration** — Endpoints defined in
   `Scout.etc.AI[<endpoint>].yaml` may specify a backend.
3. **Hard-coded dispatch** — A `case` statement maps `:openai`, `:anthropic`,
   `:responses`, `:ollama`, `:vllm` to their modules.
4. **Dynamic loading** — Unknown backend names are resolved as a module name
   (e.g., `:my_backend` → `LLM::MyBackend`), enabling third-party backends.

---

## Provider differences

### OpenAI (`LLM::OpenAI`)

- **API client**: `OpenAI::Client` (ruby-openai gem).
- **Streaming**: Supports `stream_results` for token-level streaming.
- **Tool format**: `type: 'function'` with nested `function:` key.
- **Images**: Encoded as base64 `image_url` content blocks.
- **Session continuation**: Supports `previous_response_id` for
  conversation-threading (Responses API).
- **Reasoning**: Extracts reasoning summaries from `o1`/`o3`-class models.

### Anthropic (`LLM::Anthropic`)

- **API client**: HTTP client to Anthropic API.
- **Tool format**: Flat `name`, `description`, `input_schema` (no `function:`
  nesting).
- **Images**: Base64 `image` content blocks with media type.
- **System messages**: Extracted from the message list and sent as a separate
  parameter.
- **Reasoning**: Extracts `thinking` content blocks.

### Ollama (`LLM::OLlama`)

- **API client**: HTTP client to local Ollama server.
- **Tool format**: Uses OpenAI-compatible format.
- **Endpoint**: Defaults to `http://localhost:11434`.
- **Embedding**: Supports embedding queries natively.

### Responses API (`LLM::Responses`)

- **Wraps OpenAI's Responses API** — a session-oriented endpoint.
- **Session state**: Uses `previous_response_id` to maintain context
  server-side, reducing token consumption.
- **Compatible with**: OpenAI's `o1`/`o3` reasoning models.

### Bedrock (`LLM::Bedrock`)

- **Multi-provider**: Routes to different providers (Anthropic, Meta, etc.) via
  the AWS Bedrock API.
- **Model naming**: Uses provider-prefixed model IDs
  (e.g., `anthropic.claude-3-sonnet`).

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
| `lib/scout/llm/backends/vllm.rb` | vLLM provider |
| `lib/scout/llm/backends/bedrock.rb` | AWS Bedrock provider |

---

## Cross-references

- [../user/RunningInference.md](../user/RunningInference.md) — User guide for endpoints and providers.
- [PromptProcessing.md](PromptProcessing.md) — Context management integrated into the backend.
- [../../research/backends-analysis.md](../../research/backends-analysis.md) — Deep investigation.
