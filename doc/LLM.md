# LLM

This package provides a compact layer to talk to multiple LLM backends while keeping:

- **configuration reproducible** (named endpoints)
- **prompts reproducible** (chat files)
- **tool calling first-class** (Workflow tasks, KnowledgeBase databases, MCP tools)

The core entry points are:

- `LLM.ask(question, options={}, &block)` — ask a model (optionally with tools)
- `LLM.chat(...)` — compile/expand a chat file or message array into final messages
- `LLM.options(messages)` — extract per-chat options (`endpoint`, `model`, `format`, …)
- `LLM.print(messages)` — serialize messages back to chat-file format
- `LLM.embed(text, options={})` — embeddings (not the focus of this document)

For stateful multi-turn conversations, see `doc/Agent.md`.

For the full chat-file role reference, see `doc/Chat.md`.

---

## 1. Endpoints: configuring inference points (`~/.scout/etc/AI/<endpoint>`)

Scout-AI uses **named endpoints** so colleagues can agree on short names like `nano` or `deep`.

At runtime, `LLM.ask(..., endpoint: :nano)` will load:

```text
~/.scout/etc/AI/nano
```

This file is YAML.

Minimum useful keys:

- `backend`: which backend to use (`responses`, `openai`, `anthropic`, `ollama`, `vllm`, `openwebui`, `bedrock`, `relay`)
- `url`: server URL (only for backends that need one, e.g. `ollama`, `openwebui`)
- `model`: backend-specific model id

Any **additional keys are passed to the backend** and may be interpreted there.

Examples:

`~/.scout/etc/AI/nano`

```yaml
backend: responses
model: gpt-5-nano
```

`~/.scout/etc/AI/deep`

```yaml
backend: responses
model: gpt-5
reasoning_effort: high
text_verbosity: high
```

`~/.scout/etc/AI/ollama`

```yaml
backend: ollama
url: http://localhost:11434
model: llama3.1
```

How they are used:

```ruby
LLM.ask "Say hi", endpoint: :nano
LLM.ask "Think harder", endpoint: :deep
```

From the CLI:

```bash
scout-ai llm ask -e nano "Say hi"
```

---

## 2. `LLM.ask`: the core call

### 2.1 Input types

The `question` argument can be:

- a String (free text)
- a **path to a chat file** (if the string looks like a filename and exists)
- an Array of `{role:, content:}` hashes
- a `Chat` (which is an annotated array)

Internally `LLM.ask` always compiles input via `LLM.chat` first.

### 2.2 Option resolution order

Options come from multiple places:

1) options extracted from the compiled messages (`LLM.options(messages)`)
2) options passed explicitly to `LLM.ask(question, options)`
3) endpoint YAML (`~/.scout/etc/AI/<endpoint>`) is merged in (as defaults)

### 2.3 Caching (`persist`)

`LLM.ask` caches responses by default via `Persist.persist`.

- default: `persist: true`
- set `persist: false` to disable caching

The cache key includes the endpoint name, messages, and most options.

### 2.4 Return value

- default: returns the assistant content string
- if `return_messages: true`: returns the full message trace (including tool calls)

---

## 3. Chat compilation (`LLM.chat`) and why it matters

`LLM.chat` is what makes chat files powerful.

It expands special roles **before** calling the backend:

- imports: `import`, `continue`, `last`
- pruning: `clear`, `skip`
- workflow execution: `task`, `inline_task`, `exec_task`, and then `job`, `inline_job`
- file inclusion: `file`, `directory`, `image`, `pdf`

See `doc/Chat.md` for exact behavior and role syntax.

---

## 4. Backends (and what is “passed through”)

Backends are selected by `backend:` (from endpoint YAML, env/config, or explicit options).

Currently supported backends (see `lib/scout/llm/backends/`):

- `responses` — OpenAI Responses API style (default). Supports:
  - JSON Schema responses (`format:` as schema)
  - multimodal (`image:`, `pdf:` roles)
  - session continuation (`previous_response_id`)
  - optional web search tool (`websearch`)
- `openai` — OpenAI Chat Completions style
- `anthropic` — Anthropic Messages API style
- `ollama` — local Ollama server
- `vllm` — vLLM OpenAI-compatible server
- `openwebui` — OpenWebUI-compatible chat/completions
- `bedrock` — AWS Bedrock runtime
- `relay` — simple SCP/poll relay

### 4.1 Common backend options

Many backends accept the same high-level keys:

- `model`, `url`, `key`
- `request_timeout`
- `log_errors`
- `tools`

And then backend-specific keys are forwarded (for example: reasoning/text options for `responses`).

### 4.2 Responses session continuation (`previous_response_id`)

If you use the Responses backend and provide a `previous_response_id`, Scout-AI will:

- keep only the messages after the most recent `previous_response_id` marker (so you do not resend the entire conversation)
- pass `previous_response_id` to the backend

If you set `previous_response: false`, session continuation is disabled.

---

## 5. Tools and function calling

Scout-AI represents tools as a **hash**:

```ruby
tools = {
  "tool_name" => [handler, tool_definition]
}
```

Where:

- `handler` can be:
  - a `Workflow`
  - a `KnowledgeBase`
  - a `Proc` (custom tool implementation)
- `tool_definition` is an OpenAI-style function schema (adapted per backend)

### 5.1 Providing tools

You can provide tools in three main ways:

1) programmatically: `LLM.ask(..., tools: {...})`
2) via chat roles: `tool:`, `kb:`, `association:`, `mcp:`
3) via an Agent: `LLM::Agent` automatically exports a workflow/KB as tools

### 5.2 Workflow tools

```ruby
workflow_tools = LLM.workflow_tools(Baking)
LLM.ask "Bake muffins", tools: workflow_tools
```

Or in a chat file:

```text
tool: Baking bake_muffin_tray
```

### 5.3 KnowledgeBase tools

```ruby
kb_tools = LLM.knowledge_base_tool_definition(kb)
LLM.ask "Query relationships", tools: kb_tools
```

Or in a chat file:

```text
association: brothers test/data/person/brothers undirected=true
```

### 5.4 Tool execution and output limits

Tool calls are executed by `LLM.process_calls`.

To protect the context window, tool outputs are capped (config key `:max_content_length` under `:llm_tools`).

If a tool returns more than the max length, the content is replaced by an exception-like JSON string.

---

## 6. Convenience helpers

### 6.1 `LLM.workflow_ask`

```ruby
LLM.workflow_ask(Baking, "Bake muffins", endpoint: :nano)
```

### 6.2 `LLM.knowledge_base_ask`

```ruby
LLM.knowledge_base_ask(kb, "Who is X's brother in law?", endpoint: :nano)
```

---

## 7. CLI usage

### 7.1 `scout-ai llm ask`

The main “stateless” CLI.

```bash
scout-ai llm ask -e nano "Say hi"
```

Useful flags:

- `-e/--endpoint <name>`
- `-m/--model <model_id>`
- `-b/--backend <backend>`
- `-c/--chat <file>` — read/append to a chat file
- `-i/--imports <a,b,c>` — import other chat files
- `-t/--template <name_or_path>` — templates with optional `???` placeholder
- `-f/--file <path>` — inline a file into the prompt
- `-d/--dry_run` — print the compiled conversation (no model call)

### 7.2 `scout-ai agent ask`

The “agent-aware” CLI.

```bash
scout-ai agent ask Baking "Bake a tray of muffins"
```

It loads the agent (workflow + knowledge base + start_chat) and runs a stateful conversation.

See `doc/Agent.md`.

---

## 8. Programmatic use (control loops)

For loops, branching, delegation, and structured iteration, use `LLM::Agent`.

See `doc/Agent.md` for the full API and examples.

---

## 9. Minimal end-to-end example

1) Create an endpoint file:

```yaml
# ~/.scout/etc/AI/nano
backend: responses
model: gpt-5-nano
```

2) Ask from the CLI:

```bash
scout-ai llm ask -e nano "Say hi"
```

3) Use a chat file with a workflow tool:

```text
user:

tool: Baking bake_muffin_tray

Bake muffins using the tool.
```

```bash
scout-ai llm ask -c baking.chat -e nano
```
