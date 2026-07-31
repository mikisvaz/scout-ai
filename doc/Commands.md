# CLI Commands

Scout-AI provides a set of CLI commands organized under three top-level
groups: `llm` (direct LLM and chat operations), `agent` (named agent
interactions), and `workflow` (workflow tooling). A standalone `documenter`
command also exists.

This document is a concise reference for all commands. For in-depth coverage
of provenance inspection commands, see
[../Provenance/Provenance.md](../Provenance/Provenance.md).

---

## Command overview

| Command | Purpose | Status |
|---|---|---|
| `scout-ai llm ask` | Ask a model a question (single call) | ✅ Current |
| `scout-ai llm info` | Inspect chat provenance (recommended) | ✅ Current |
| `scout-ai llm prov` | Print provenance tree | ⚠️ Superseded by `info` |
| `scout-ai llm json` | Convert JSON ↔ Chat format | ✅ Current |
| `scout-ai llm md` | Format chat as Markdown | ✅ Current |
| `scout-ai llm word` | Convert chat to `.docx` | ✅ Current |
| `scout-ai llm template` | List question templates | ✅ Current |
| `scout-ai llm process` | Batch queue processing | ⚠️ Legacy |
| `scout-ai llm process_queries` | Batch queue processing (variant schema) | ⚠️ Legacy |
| `scout-ai llm server` | Chat web UI | ✅ Current |
| `scout-ai agent ask` | Ask a named agent | ✅ Current |
| `scout-ai agent find` | Resolve agent path | ✅ Current |
| `scout-ai agent kb` | Launch KB browser | ✅ Current |
| `scout-ai workflow mcp` | Expose workflow as MCP server | ✅ Current |
| `scout-ai documenter` | Auto-documentation | ⚠️ Prototype |

---

## `llm` commands

### `scout-ai llm ask`

Ask an LLM a single question. Supports context injection from files or STDIN,
template-based prompting, multi-turn conversations (via `--chat`), inline
question answering in source files, and workflow tool attachment.

```bash
# Simple question
scout-ai llm ask "What is the capital of France?"

# With file context
scout-ai llm ask -f report.txt "Summarize this report"

# STDIN with '...' placeholder
echo "Some context" | scout-ai llm ask "Based on this: ..., explain X"

# Multi-turn conversation
scout-ai llm ask -c conversation.chat "Follow up question"

# Use a template
scout-ai llm ask -t code_review "src/app.rb"

# Dry run (preview without calling the model)
scout-ai llm ask -d -f data.json "Analyze this data"
```

| Option | Description |
|---|---|
| `-t, --template` | Template (file path or name from `Scout.questions`/`Scout.chats`) |
| `-c, --chat` | Follow a conversation file |
| `-i, --imports` | Chat files to import |
| `-f, --file` | Incorporate file content into the question |
| `-w, --workflow` | Add a workflow as a tool |
| `-m, --model` | Model override |
| `-e, --endpoint` | Endpoint override |
| `-b, --backend` | Backend override (`openai`, `anthropic`, `responses`, `ollama`) |
| `-d, --dry_run` | Print conversation without calling the LLM |
| `--inline` | Process `# ask:` comments in a file |

---

### `scout-ai llm info`

Inspect the chat, jobs, agent logs, and token trace behind a chat.
Discovers the full provenance graph (imports, job results, dependencies,
agent logs), reports token usage, and optionally produces flow visualization.

```bash
# Basic inspection
scout-ai llm info conversation.chat

# Compact flow view
scout-ai llm info -f conversation.chat

# Graphviz DOT output
scout-ai llm info --dot flow.dot conversation.chat

# Render to PDF
scout-ai llm info --plot flow.pdf conversation.chat
```

| Option | Description |
|---|---|
| `-f, --flow` | Print compact provenance flow (numbered nodes + edges) |
| `--dot` | Write flow as Graphviz DOT to file |
| `--plot` | Render flow as SVG/PNG/PDF (requires `dot`) |

This is the **recommended** command for provenance inspection. It uses
library APIs directly (no monkey-patching), discovers imports, deduplicates
mirrored jobs, and supports Graphviz output. For full details, see
[../Provenance/Provenance.md](../Provenance/Provenance.md).

---

### `scout-ai llm prov`

Print a hierarchical, indented tree of jobs, agent logs, and dependencies
with token totals at each node.

```bash
scout-ai llm prov conversation.chat
```

**Status: superseded by `info`.** Still functional, but relies on runtime
monkey-patches, lacks import discovery and job deduplication, has no flow
visualization, and contains a hardcoded fallback path. Prefer `llm info` for
all provenance tasks. See
[../Provenance/Provenance.md](../Provenance/Provenance.md) for details.

---

### `scout-ai llm json`

Convert between JSON and Chat format. Reads a file as one format and outputs
the other.

```bash
# JSON → Chat format (default)
scout-ai llm json -j input.json

# Chat → JSON format
scout-ai llm json -c conversation.chat

# Save to file
scout-ai llm json -c conversation.chat -o output.json
```

| Option | Description |
|---|---|
| `-c, --chat` | Load as Chat format (output JSON) |
| `-j, --json` | Load as JSON format (output Chat) — default |
| `-o, --output` | Save to file instead of STDOUT |

---

### `scout-ai llm md`

Format a chat file as Markdown with emoji headers for user and assistant
turns.

```bash
# Print to stdout
scout-ai llm md conversation.chat

# Save to file
scout-ai llm md conversation.chat output.md

# Only the last exchange
scout-ai llm md -l conversation.chat output.md
```

| Option | Description |
|---|---|
| `-l, --last` | Format only the last user/assistant interaction |

---

### `scout-ai llm word`

Convert a chat file to a Word `.docx` document using pandoc, with custom
paragraph styles for user blocks.

```bash
# Basic conversion
scout-ai llm word conversation.chat

# Specify output file
scout-ai llm word conversation.chat report.docx

# Custom reference doc for styling
scout-ai llm word -r my-reference.docx conversation.chat report.docx
```

| Option | Description |
|---|---|
| `-r, --reference` | Custom `reference.docx` for pandoc styling |
| `-l, --last` | Convert only the last user/assistant interaction |

Requires the `pandoc` CLI.

---

### `scout-ai llm template`

List all available question templates found under the `Scout.questions` path
collection.

```bash
scout-ai llm template
```

---

### `scout-ai llm process` / `process_queries` (legacy)

Batch-process JSON files from a directory queue. `process` expects files
with `{"question": "...", "model": "..."}`, while `process_queries` expects
`[messages, options]` tuples. Both run as daemon-like infinite loops, polling
a directory, sending each file to the LLM, and writing replies.

```bash
scout-ai llm process /path/to/queue
scout-ai llm process_queries /path/to/queue
```

**Status: legacy.** These represent an older queue-based async processing
architecture. They use the relay backend and are not the standard pattern for
current LLM operations.

---

### `scout-ai llm server`

A Sinatra-based web server providing a chat notebook UI for browsing,
editing, and running chat files stored under `./chats`.

```bash
# Start server (default: 127.0.0.1:4567)
mkdir -p chats && scout-ai llm server

# Custom bind/port
SCOUT_BIND=0.0.0.0 SCOUT_PORT=8080 scout-ai llm server
```

| Endpoint | Method | Description |
|---|---|---|
| `/` | GET | Serve chat HTML UI |
| `/list` | GET | List files under `./chats` |
| `/load?path=` | GET | Load a chat file |
| `/save` | POST | Save a chat file |
| `/run` | POST | Run a chat through the LLM |
| `/ping` | GET | Health check |

Requires the `sinatra` gem.

---

## `agent` commands

### `scout-ai agent ask`

Ask a named LLM agent. Unlike `llm ask` (which does a single model call),
this loads a full agent — with system prompt, tools, workflows, and knowledge
base — and runs the agent loop (multi-turn with tool calls).

```bash
# Ask the AGI agent
scout-ai agent ask AGI "Analyze this codebase"

# With a conversation file
scout-ai agent ask -c session.chat Worker "Process this data"

# With file context
scout-ai agent ask -f input.txt Searcher "Find relevant information"

# Specify model/endpoint
scout-ai agent ask -m gpt-4o -e production AGI "Complex task"
```

| Option | Description |
|---|---|
| `-l, --log` | Log level |
| `-t, --template` | Use a template |
| `-c, --chat` | Follow a conversation file |
| `-m, --model` | Model override |
| `-e, --endpoint` | Endpoint override |
| `-f, --file` | Incorporate file content |
| `-w, --workflow` | Add a workflow as a tool |
| `-wt, --workflow_tasks` | Export specific tasks from the workflow |
| `-i, --imports` | Chat files to import |

This is the primary entry point for agent-based interactions. See
[../Agent/Agent.md](../Agent/Agent.md) for the agent abstraction.

---

### `scout-ai agent find`

Resolve and print the filesystem path of a named agent.

```bash
scout-ai agent find AGI
# Output: ~/.scout/var/Agent/AGI
```

---

### `scout-ai agent kb`

Launch the Scout knowledge base browser, scoped to a specific agent's KB
directory. This is a thin wrapper that delegates to the main `scout kb`
command.

```bash
scout-ai agent kb AGI
```

See [../Tools/KnowledgeBase.md](../Tools/KnowledgeBase.md) for the KB system.

---

## `workflow` commands

### `scout-ai workflow mcp`

Expose a Scout workflow as an MCP (Model Context Protocol) service over
stdio. Workflow tasks become MCP tools callable by MCP-compatible clients
(e.g. Claude Desktop).

```bash
# Export all tasks
scout-ai workflow mcp MyWorkflow

# Export specific tasks only
scout-ai workflow mcp MyWorkflow task1 task2
```

If no task names are given, exports all explicitly exported tasks (those
marked with `export_exec`). If none are explicitly exported, exports all
tasks. See [../Tools/MCP.md](../Tools/MCP.md) for the MCP integration.

---

## Standalone commands

### `scout-ai documenter` (prototype)

Automatically generate technical documentation for a Scout library topic by
analyzing Ruby source files and their test files using an LLM agent.

```bash
scout-ai documenter chat
scout-ai documenter agent
```

**Status: early prototype.** Last updated 2025-08-04. Uses a two-pass approach
(generate sub-topic docs → aggregate → revise), but has no options for output
directory, model selection, or dry-run. The system prompt and file-layout
assumptions are hardcoded.

---

## Status summary

### ✅ Current and recommended

| Command | Notes |
|---|---|
| `llm ask` | Primary LLM question command |
| `llm info` | **Recommended** provenance inspector |
| `llm json` | Format converter |
| `llm md` | Chat → Markdown |
| `llm word` | Chat → Word (requires pandoc) |
| `llm template` | Lists templates |
| `llm server` | Web UI (requires sinatra) |
| `agent ask` | Primary agent interaction command |
| `agent find` | Agent path resolver |
| `agent kb` | Agent KB browser |
| `workflow mcp` | MCP service exporter |

### ⚠️ Superseded or legacy

| Command | Issue |
|---|---|
| `llm prov` | Superseded by `llm info` — monkey-patches, no imports/dedup/flow |
| `llm process` | Legacy queue-based processor |
| `llm process_queries` | Legacy queue-based processor (variant schema) |
| `documenter` | Early prototype, no options or error handling |

---

## Related documentation

- [../Provenance/Provenance.md](../Provenance/Provenance.md) — in-depth provenance inspection (`info`, `prov`)
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model
- [../Chat/Persistence.md](../Chat/Persistence.md) — `.chat` file format
- [../Agent/Agent.md](../Agent/Agent.md) — the `LLM::Agent` abstraction
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and calling protocol
- [../Tools/MCP.md](../Tools/MCP.md) — MCP integration
- [../Tools/KnowledgeBase.md](../Tools/KnowledgeBase.md) — knowledge bases
