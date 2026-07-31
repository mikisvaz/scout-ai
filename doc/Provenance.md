# Provenance

When agents delegate to other agents, and those delegations spawn workflow
jobs, and those jobs have dependencies that produce their own agent logs, the
result is a **tree** (or DAG) of conversations. Provenance is how Scout-AI
tracks, traverses, and reports that lineage.

This document covers:

- The provenance data model (meta messages, token fields, job references)
- The `Chat.provenance` and `trace_chats` APIs
- The `scout-ai llm info` command (recommended)
- The `scout-ai llm prov` command (superseded)
- The `job_agent_chat_files` mechanism
- The ChatAnalyst agent

Related docs:

- [../Chat/Persistence.md](../Chat/Persistence.md) — `.chat` file format and meta role
- [../Agent/Delegation.md](../Agent/Delegation.md) — how delegation creates provenance chains
- [../Commands/Commands.md](../Commands/Commands.md) — CLI command reference

---

## 1. What provenance is

A Scout-AI session is rarely a single flat conversation. It is a tree
connected by four kinds of edges:

| Edge type | How it arises | Example |
|---|---|---|
| **Import** | `import:` / `continue:` / `last:` roles pull in previous chat history | Continuing a conversation from a saved file |
| **Result** | `meta: job=<path>` markers project a workflow job's output into a chat | An `ask` task result shown in the orchestrator's chat |
| **Dependency** | Scout workflow jobs depend on other jobs | `:plan` depends on `:search` |
| **Log** | Each ask-job has a `log/` directory with agent chat files | `log/agent.chat` contains the full agent conversation |

Provenance means being able to start at any chat file, follow these edges
recursively, and reconstruct the complete inference graph — including token
counts for every model call.

---

## 2. The provenance data model

### Meta messages

Provenance information is embedded inline in the chat transcript as **meta
messages** — messages with `role: meta` and a content string in
`key=value key=value …` format.

Serialization and parsing live in `lib/scout/llm/chat/process/meta.rb`:

```ruby
Chat.serialize_meta(job: "/path/to/job")   # => 'job=/path/to/job'
Chat.parse_meta('pt=100 ct=50 tt=150')     # => {"pt"=>"100", "ct"=>"50", "tt"=>"150"}
Chat.meta(messages)                        # => merged hash from all meta messages
```

### Token fields

Written by `Backend::Default#update_meta` after each model call:

| Field | Meaning |
|---|---|
| `pt` | Prompt tokens — this single inference |
| `ct` | Completion tokens — this single inference |
| `tt` | Total tokens — this single inference |
| `pt_s`, `ct_s`, `tt_s` | **Session** cumulative counters (per-thread running totals) |
| `pt_c`, `ct_c`, `tt_c` | **Chat** cumulative counters (persisted across requests) |
| `reas` | Reasoning summary (truncated for display) |

### Job-reference field

| Field | Meaning |
|---|---|
| `job` | Canonical path of the Scout workflow job that produced this segment |

### Two kinds of meta messages

1. **Direct inference meta** — contains `pt`, `ct`, `tt`. Records one actual
   model call with real token costs.

2. **Job projection meta** — contains only `job=<path>`. Marks a response
   segment projected from an ask-workflow job. It has **zero direct token
   cost** — the real tokens live in the job's own agent logs and dependency
   chain.

This distinction is critical for correct token accounting: you must never sum
`*_c` (cumulative) or `*_s` (session) counters, because they would
double-count across the import/projection chain. Only sum direct `pt`/`ct`/
`tt` from entries that have no `job` key.

### How projection works

When a `chat_task` produces output, `Chat.project(job, messages)` wraps the
non-meta messages with a single `meta job=<path>` marker:

```ruby
[{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected_messages
```

Consumers can then detect the job origin without scanning for token fields.

---

## 3. The `Chat` provenance API

### Instance methods on Chat objects

| Method | Returns |
|---|---|
| `chat.job_paths` / `chat.jobs` | Array of `Path` objects from all `meta job=…` messages |
| `chat.job_chat_files` | All chat files (result + logs) reachable from this chat's jobs and dependencies |
| `chat.job_agent_chat_files` | All `log/**/*.chat` files from this chat's jobs and dependencies |
| `chat.job_chats` | All `Chat` objects loaded from `job_chat_files` |
| `chat.job_agent_chats` | All `Chat` objects loaded from `job_agent_chat_files` |
| `chat.message_index` | Per-message lineage records: `id`, `role`, `prev`, `fingerprint`, parsed `meta` |
| `chat.meta` | Parsed metadata hash from the last meta message |
| `chat.last_job` | The `job` value from the last meta message |

### `trace_chats`: recursive traversal

`Chat.trace_chats(chats)` takes an array of `Chat` objects, computes
`message_index` on each, and groups all messages into **response segments**:

```ruby
Chat.trace_chats([chat1, chat2, chat3])
# => [{ id:..., meta: { pt:100, ct:50, tt:150 }, messages:[...], orphan:false },
#     { id:..., meta: { job:"..." }, messages:[...], orphan:false }, ...]
```

Each segment represents one model call (direct inference) or one job
projection. To count tokens:

```ruby
segments = Chat.trace_chats(chats)
direct = segments.select { |s| s[:meta][:pt] && !s[:meta][:job] }
total_pt = direct.sum { |s| s[:meta][:pt].to_i }
total_ct = direct.sum { |s| s[:meta][:ct].to_i }
```

### Lineage IDs

Each message's lineage ID is a digest of `[previous_id, role, content]`,
creating a hash-chain through the conversational history (meta messages are
excluded from the chain). A `seen` Set prevents double-counting when the same
message appears in multiple chats (e.g. via imports).

---

## 4. Job-based recursive provenance

`Chat.job_chat_files(job, seen)` performs recursive traversal of the job
dependency graph:

1. Load the job via `Step.load`.
2. If the job is done and its type is `chat`, add its result path.
3. Add all `log/**/*.chat` files from the job's `files_dir`.
4. For each dependency, recurse (using a `seen` Set to prevent cycles).
5. Return the unique set of all discovered chat file paths.

### The `job_agent_chat_files` mechanism

Agent conversations are located within workflow jobs at:

```
<job_path>/files/log/**/*.chat
```

The primary log is `<job_path>/files/log/agent.chat`. When an agent delegates
to another agent with a named conversation, a **socialized chat** projection
may appear at:

```
<job_path>/files/log/chats/<AgentName>/<conversation>.chat
```

These projection files contain the prompt, propagated options, a
`meta: job=…` marker, and the response — but carry zero direct inference
tokens. The real model calls are found by following the `job` reference into
the specialist's own ask-job and its `agent.chat` log.

---

## 5. How multi-agent inference creates provenance chains

When an orchestrator (e.g. AGI) delegates to a specialist (e.g. Worker) via
`ask`:

1. The orchestrator's chat gets a `function_call` message with tool name
   `ask` and arguments naming the target agent.
2. The `ask` call triggers a Scout workflow job (e.g. `Agent/Worker/ask`).
3. That job runs the target agent, producing `log/agent.chat` with the full
   conversation and its own `meta:` entries with direct token counts.
4. The job result is projected back into the orchestrator's chat as a
   `meta: job=<path>` marker followed by the response messages.
5. The orchestrator's chat thus has a **zero-token projection segment** — the
   real tokens are in the job's `agent.chat`.

Token accounting requires recursive traversal: start at the root chat, follow
every `meta: job=…` to its job, read the job's agent chat logs, follow the
job's dependencies, and sum only direct `pt`/`ct`/`tt` entries.

---

## 6. The `info` command (recommended)

```bash
scout-ai llm info <chat>
scout-ai llm info -f <chat>               # compact flow view
scout-ai llm info --dot flow.dot <chat>   # Graphviz DOT
scout-ai llm info --plot flow.pdf <chat>  # rendered PDF (requires graphviz)
```

**Purpose:** Comprehensive provenance inspection. Discovers the full graph
(root chat, imports, job results, dependencies, agent logs), deduplicates
mirrored jobs between `~/.scout` and `~/.rbbt`, reports token usage, and
optionally produces flow visualization.

### What it reports

| Section | Content |
|---|---|
| **Chats** | Each chat file with message counts by role and job references |
| **Jobs** | Each job with workflow/task name, log count, dependency count |
| **Token usage** | Root-only totals vs. all-traced totals (direct entries only) |
| **Flow** (with `-f`) | Numbered nodes and typed edges with token annotations |
| **Warnings** | Load failures recorded gracefully |

### Why `info` is recommended

- Uses library APIs directly — **no monkey-patching**.
- Discovers imports (`prov` does not).
- Deduplicates mirrored jobs.
- Supports text flow + Graphviz DOT/SVG/PNG/PDF output.
- Records and reports warnings.

---

## 7. The `prov` command (superseded)

```bash
scout-ai llm prov <filename>
```

**Purpose:** Prints a hierarchical, indented tree of jobs, agent logs, and
dependencies with token totals at each node.

### Output format

```
job   total=1.2k prompt=800 cont=400 ~/.scout/var/jobs/.../ask
  chat   total=500 prompt=300 cont=200  agent.chat
  job   total=700 prompt=500 cont=200 ~/.scout/var/jobs/.../subtask
```

### Status: superseded by `info`

`prov` still works but has architectural drawbacks:

| Issue | Detail |
|---|---|
| Monkey-patching | Redefines `Chat.trace_chats`, `Chat.token_totals`, `Chat.job_agent_chat_files` at runtime; adds `Chat.provenance`, `Chat.tokens`, `Step#agent_chats`. |
| No import discovery | Cannot follow `import`/`continue`/`last` edges. |
| No job deduplication | `~/.scout` and `~/.rbbt` mirrors of the same job appear twice. |
| No flow visualization | No text flow or Graphviz output. |
| Hardcoded fallback path | Defaults to `~/git/workflows/SC26/…` if no argument is given. |

For all provenance inspection tasks, prefer `scout-ai llm info`.

---

## 8. ChatAnalyst agent

ChatAnalyst is a **meta-agent** — it inspects other agents' sessions rather
than performing domain tasks. It is an SC26-specific agent (not part of the
core library), but it demonstrates the provenance API well.

### What it does

ChatAnalyst traverses chat provenance to understand multi-agent workloads:
session size, job count, token usage, tool-call success/failure rates, and
delegation patterns.

### The `Session` class

The workflow defines a `Session` class that performs BFS-based discovery:

1. **`resolve_chat(input)`** — tries multiple candidate paths (plain,
   `.chat` extension, expanded, `Scout.chats[]` lookup).
2. **`discover_chat(path)`** — follows `import`/`continue`/`last` roles and
   `meta job=…` references.
3. **`discover_job(reference)`** — follows dependencies recursively, scans
   `log/**/*.chat` for agent logs.
4. **Token accounting** — filters trace to direct inference segments (no
   `:job` key, has `pt`/`ct`/`tt`), sums them.

### Exposed tasks

| Task | Purpose |
|---|---|
| `message_index` | Compact per-message index across the session tree |
| `message_content` | Full untruncated content for specific message IDs |
| `chat_overview` | Structural graph: per-file summaries, per-job summaries, edges, totals |
| `chat_tool_calls` | Pairs tool calls with outputs; reports success/failure per tool |
| `chat_tokens` | Per-file and aggregate token accounting (direct entries only) |
| `chat_agents` | Detects `ask` and `hand_off_to_*` delegation calls |
| `chat_report` | Combined snapshot: session size, jobs, tokens, trace, tool calls, failures |

### How it compares to `info`

| Aspect | `info` CLI | ChatAnalyst workflow |
|---|---|---|
| Consumer | Human (terminal, Graphviz) | Agent (JSON tasks) |
| Discovery | BFS (imports, jobs, deps, logs) | Same BFS |
| Token accounting | `trace_chats` + direct entries | Same |
| Job deduplication | ✅ | ❌ (simple path check) |
| Tool-call analysis | ❌ | ✅ |
| Agent-interaction analysis | ❌ | ✅ |

They are complementary tools built on the same provenance data model.

---

## 9. Practical example

### Examining a multi-agent run

After running a Manager-orchestrated task:

```bash
# Recommended: comprehensive inspection
scout-ai llm info chats/my_session.chat

# With flow visualization
scout-ai llm info -f chats/my_session.chat

# Generate a PDF diagram of the provenance graph
scout-ai llm info --plot provenance.pdf chats/my_session.chat
```

The output shows:
- **Chats**: the root chat plus all imported and job-produced chats.
- **Jobs**: each ask-job with its workflow/task name and dependency count.
- **Token usage**: root-only (what the root chat directly spent) vs.
  all-traced (the full recursive total across all delegated agents).

### Programmatic traversal

```ruby
chat = Chat.load("chats/my_session.chat")

# All chat files in the provenance tree
files = chat.job_chat_files

# All agent log chats
agent_chats = chat.job_agent_chats

# Full token accounting
segments = Chat.trace_chats(chat.job_chats + [chat])
direct = segments.select { |s| s[:meta][:pt] && !s[:meta][:job] }
totals = {
  prompt:     direct.sum { |s| s[:meta][:pt].to_i },
  completion: direct.sum { |s| s[:meta][:ct].to_i },
  total:      direct.sum { |s| s[:meta][:tt].to_i }
}
```

---

## Related documentation

- [../Chat/Persistence.md](../Chat/Persistence.md) — `.chat` file format and the `meta:` role
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model
- [../Agent/Delegation.md](../Agent/Delegation.md) — how delegation creates provenance chains
- [../Agent/MultiAgentPatterns.md](../Agent/MultiAgentPatterns.md) — orchestration patterns
- [../Commands/Commands.md](../Commands/Commands.md) — `llm info` and `llm prov` command reference
