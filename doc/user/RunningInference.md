# Running Inference

This page explains how to configure inference endpoints, choose models, and
run conversations from the CLI or Ruby. It is intended for workflow authors who
need to connect Scout-AI to LLM providers.

**You should read this if:** you want to configure which LLM provider and model
your agents and chats use.

---

## What an endpoint is

An **endpoint** is a named configuration that bundles a provider, a model, and
credentials. You configure endpoints once and reference them by name.

Endpoints solve a portability problem: your agent code and chat files stay the
same regardless of whether you're using OpenAI, Anthropic, or a local model.

---

## Configuring endpoints

There is no CLI command that writes endpoint configuration. Endpoints are
YAML files under `Scout.etc.AI` (by default `~/.scout/etc/AI/`), one file per
endpoint, named `<endpoint>.yaml`. Hand-write them:

```yaml
# ~/.scout/etc/AI/anthropic.yaml
backend: anthropic
model: claude-sonnet-4-20250514

# ~/.scout/etc/AI/local.yaml
backend: ollama
model: qwen2.5:14b
url: http://localhost:11434/v1
```

The keys merge in as option defaults: `backend`, `url`, `key`, `model` are
recognized, and an explicit option still wins over the file. For one-off
configuration you can also pass `-ck key=value` to the CLI instead of
writing a file. `-ck` is Scout's global option (`--config_keys`): values are
comma-separated, and each one is either a `key=value` pair, a config file
path, or a named profile under `etc/config_profile/`.

Endpoint names are case-sensitive and must resolve to a real
`AI/<name>.yaml`; asking for a non-empty endpoint that has no file raises
`Endpoint not found <name>`.

---

## Using endpoints

### From the CLI

```bash
# Use the default endpoint
scout-ai llm ask "Hello"

# Use a specific endpoint
scout-ai llm ask -e anthropic "Hello"

# Use a specific model on an endpoint
scout-ai llm ask -e openai -m gpt-4o-mini "Hello"
```

### From Ruby

```ruby
# Reference an endpoint by name
agent = LLM.agent(endpoint: :anthropic)

# Or set inline
agent = LLM.agent
agent.option :endpoint, :anthropic
agent.option :model, 'claude-sonnet-4-20250514'
```

### In chat files

```text
endpoint: anthropic
model: claude-sonnet-4-20250514
```

These are sticky options — they persist across the conversation.

---

## Supported providers

Scout-AI supports several providers out of the box:

| Provider | Key | Notes |
|----------|-----|-------|
| OpenAI (default) | `responses` | OpenAI **Responses** API; `gpt-5-nano` by default |
| OpenAI (chat) | `openai` | GPT models via Chat Completions |
| Anthropic | `anthropic` | Claude models |
| Ollama | `ollama` | Local models via Ollama API |
| vLLM | `vllm` | Responses-shaped, with vLLM tool-name unmangling |
| OpenWebUI | `openwebui` | OpenAI-compatible HTTP with bearer key |
| HuggingFace | `huggingface` | Inference endpoints |
| GLM | `glm` | Nested `image_url` image formatting |
| Bedrock | `bedrock` | Standalone loop (`LLM::Bedrock.ask`) |
| Relay | `relay` | scp round-trip to a remote `scout-ai` |

The full dispatch table is documented in
[../developer/Backends.md](../developer/Backends.md).

### Setting API keys

Scout-AI looks up `<TAG>_KEY` — `OPENAI_KEY`, `ANTHROPIC_KEY`, and so on for
the backend's `TAG` (`ANTHROPIC_API_KEY` is *not* one of them):

```bash
export ANTHROPIC_KEY="sk-ant-..."
```

A `key:` entry in the endpoint YAML, or `-ck key=...`, works as well. Local
models (Ollama, vLLM) usually need no key.

---

## Bypassing processing for a daemon (`process:`)

`LLM.ask` accepts a `process:` option (a String). When set, the raw provider
response JSON is written to `Scout.var.query.response[<process>].json` and
returned **immediately, unprocessed** — no parsing, no tool loop, no meta.
This is the mechanism behind the `llm process_queries` daemon (it polls
`Scout.var.query` for request files and calls
`LLM.ask(messages, options.merge(process: id))`); the sibling
`llm process` daemon serves the same role for `Scout.var.ask` files by
calling plain `LLM.ask` and writing the reply file itself.

## Caching

By default, `LLM.ask` wraps every round in a `Persist` cache keyed on the
endpoint, the whole options hash, and the message list. Asking the same
question with the same options twice replays the cached answer; the flip side
is that any option change (`model`, `tools`, …) changes the key and forces a
re-query. To bypass the cache for a specific call, set `persist: false`
(`agent.option :persist, false`), which is the only way to force a re-run of
an identical question — the cache key includes the options hash, but not that
flag.

---

## Choosing the right model

| Use case | Suggested approach |
|----------|-------------------|
| Fast, cheap interactions | GPT-4o-mini, Claude Haiku, or a small local model |
| Complex reasoning | GPT-4o, Claude Sonnet/Opus |
| Code generation | GPT-4o, Claude Sonnet |
| Local / offline | Ollama with Qwen2.5 or Llama 3.1 |

The model is configured per-endpoint but can be overridden per-call:

```bash
scout-ai llm ask -e openai -m gpt-4o-mini "Quick question"
```

> **Model is not isolated per provider.** The `model` config key is read
> through a single shared token, so a `model` set at the config level leaks
> into the default model of every backend. Pin `model:` inside each endpoint
> YAML to isolate providers from each other.

---

## The inference flow

When you call `agent.chat` or `scout-ai llm ask`, Scout-AI:

1. Collects the messages (from the chat file or agent state).
2. Applies any context management (see [ManagingContext.md](ManagingContext.md)).
3. Formats the messages for the provider's API.
4. Sends to the endpoint.
5. If the model calls a tool, executes it and re-sends (automatic).
6. Returns the final text response.

This is all automatic. You configure the endpoint and model; Scout-AI handles
the rest.

Persistence, however, differs slightly between the two CLIs:

- `scout-ai agent ask ... -c <chat>` sets the agent's `save_file` to
  `<chat>.files/<name>.chat` (`agent.chat` by default; a named agent writes
  `worker.chat`), runs the agent through `agent.chat` (so the
  auto-save hook fires), and also appends the new messages to `<chat>`
  itself — a dual write. The `agent.chat` should contain also the agent
  instructions. Delegated society conversations, when they exist, are written
  under `<chat>.files/<name>.society/<agent>/<conversation>/agent.chat`.
- `scout-ai llm ask ... -c <chat>` computes an `agent_save_file` for the chat
  and passes it to `LLM.ask`, but it is only applied when the chat also
  declares an `agent` (the `agent:` role); otherwise the option is extracted
  and dropped, so nothing is saved.

---

## Common mistakes

- **Forgetting to set the API key**: The most common error. Make sure the
  environment variable matches your provider.
- **Using the wrong endpoint name**: Endpoint names are case-sensitive and must
  match your config.
- **Expecting streaming**: there is no streaming path at all — requests are
  blocking and return once complete.
- **Not realizing caching is on**: If you're not seeing new responses to the
  same question, it may be cached. Use `persist: false` to bypass.

---

## Next steps

- [ManagingContext.md](ManagingContext.md) — what happens when conversations
  get long.
- [BuildingAgents.md](BuildingAgents.md) — agents with persistent endpoints.
- [ToolCalling.md](ToolCalling.md) — tools during inference.
