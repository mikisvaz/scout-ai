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

Endpoints are stored in Scout config. The simplest way is the CLI:

```bash
# OpenAI (uses OPENAI_API_KEY env var)
scout-ai config set openai model=gpt-4o

# Anthropic
scout-ai config set anthropic provider=anthropic model=claude-sonnet-4-20250514

# Local model via Ollama
scout-ai config set local ollama model=qwen2.5:14b url=http://localhost:11434/v1
```

You can also edit the config file directly. Endpoint configs live under their
own section:

```ini
[openai]
model = gpt-4o

[anthropic]
provider = anthropic
model = claude-sonnet-4-20250514

[local]
provider = ollama
model = qwen2.5:14b
url = http://localhost:11434/v1
```

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
| OpenAI | `openai` | GPT models, uses `OPENAI_API_KEY` |
| Anthropic | `anthropic` | Claude models, uses `ANTHROPIC_API_KEY` |
| Ollama | `ollama` | Local models via Ollama API |
| OpenAI-compatible | (custom) | Any server exposing the OpenAI API format (vLLM, etc.) |

### Setting API keys

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

For local models (Ollama, vLLM), no API key is typically needed.

---

## Caching

By default, Scout-AI caches inference results. This means:

- Asking the same question twice returns the cached answer instantly.
- Workflow jobs that produce the same chat are not re-run.
- You can reproduce results deterministically.

To disable caching for a specific call:

```ruby
agent.option :persist, false
```

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

---

## Common mistakes

- **Forgetting to set the API key**: The most common error. Make sure the
  environment variable matches your provider.
- **Using the wrong endpoint name**: Endpoint names are case-sensitive and must
  match your config.
- **Expecting streaming by default**: Streaming is available but not enabled
  by default. Check the CLI flags or Ruby options.
- **Not realizing caching is on**: If you're not seeing new responses to the
  same question, it may be cached. Use `persist: false` to bypass.

---

## Next steps

- [ManagingContext.md](ManagingContext.md) — what happens when conversations
  get long.
- [BuildingAgents.md](BuildingAgents.md) — agents with persistent endpoints.
- [ToolCalling.md](ToolCalling.md) — tools during inference.
