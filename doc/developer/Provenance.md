# Provenance

This document explains how Scout-AI records, traverses, and reports the
lineage of every inference — across imported chats, ask-job results, nested
agent logs, and dependency chains. It is intended for framework contributors.

> For deep code investigation, see
> [../../research/provenance-analysis.md](../../research/provenance-analysis.md).

---

## What provenance is

Scout-AI does not have a standalone provenance database. Instead, provenance
information is **embedded inline in the chat transcript** as special `meta:`
messages. Every inference leaves a trace that can be followed to reconstruct
the full chain of model calls, tool executions, and delegated agent work.

Provenance serves three purposes:
1. **Cost tracking** — Token counts for each inference.
2. **Lineage reconstruction** — Which job produced which response segment.
3. **Multi-agent audit** — What did each delegated agent see and produce.

---

## The meta message

A meta message has `role: meta` and a content string in `key=value` format:

```
meta: pt=1234 ct=567 tt=1801 pt_s=5000 ct_s=2000 tt_s=7000 pt_c=15000 reas=...
```

### Token fields

| Field | Meaning |
|---|---|
| `pt` | Prompt tokens (this inference) |
| `ct` | Completion tokens (this inference) |
| `tt` | Total tokens (this inference) |
| `pt_s`, `ct_s`, `tt_s` | Session cumulative (per-thread running totals) |
| `pt_c`, `ct_c`, `tt_c` | Chat cumulative (persisted across requests) |
| `reas` | Reasoning summary (truncated) |

### Job-reference field

| Field | Meaning |
|---|---|
| `job` | Canonical path of the Scout workflow job that produced this segment |

### Two kinds of meta messages

1. **Direct inference meta** — Contains `pt`/`ct`/`tt`. Records one actual model call.
2. **Job projection meta** — Contains only `job=<path>`. Marks a response projected from an ask-workflow job. Has zero direct token cost — the actual tokens are in the job's own agent logs and dependency chain.

---

## Lineage IDs and message_index

`Chat#message_index` computes a lineage ID for each message:

```ruby
id = Misc.digest([previous_id, role, content])
```

Each message's lineage ID incorporates the **previous conversational message's
ID** (meta messages are excluded from the lineage chain). This creates a
hash-chain where `prev` links each message to its predecessor.

Each message also gets a `fingerprint` — a truncated head/tail digest for
compact comparison.

### Response segments

`Chat.trace_indices(indices)` groups messages into response segments:
- Each `meta:` message **opens** a new segment, seeded with the parsed metadata.
- `user` and `system` messages **close** any pending segment.
- Segments are the unit of provenance traversal.

---

## Job traversal

Chat tasks in AgentWorkflow project their results via `Chat.project(job, messages)`,
which wraps the messages with a `meta job=<path>` marker. This creates a chain:

```
Top-level chat
  → meta: job=Planned/work/Default_abc
      → Planned/work chat
          → meta: job=Worker/ask/Default_def
              → Worker's internal chat (in log/ directory)
```

### Key traversal methods

| Method | Returns |
|---|---|
| `chat.job_paths` / `chat.jobs` | Array of `Path` objects from `meta job=...` messages |
| `chat.job_chat_files` | All chat files reachable from this chat's jobs and their dependencies |
| `chat.job_agent_chat_files` | All `log/**/*.chat` files (delegated agent logs) |
| `chat.job_chats` | All Chat objects loaded from job_chat_files |
| `chat.job_agent_chats` | All Chat objects from agent log files |

These methods traverse the Scout job dependency graph recursively, so a
multi-agent pipeline's full inference chain is recoverable from the top-level
chat alone.

---

## CLI commands

### `scout-ai llm info` (recommended)

The **current, recommended** command for inspecting provenance. It provides:
- Hierarchical provenance tree with token totals.
- Job references and their dependencies.
- Flow visualization.
- Agent log file listing.

### `scout-ai llm prov`

An older command that prints a hierarchical provenance tree with token totals.
It has been **superseded by `info`** and may not reflect the latest provenance
data model. New code and users should prefer `info`.

> **Known issue:** The `info` command may be outdated in some areas. See
> [../Improvements.md](../Improvements.md) for the current status of
> provenance commands.

---

## ChatAnalyst integration

The `ChatAnalyst` agent (from `~/git/workflows/SC26/Agent/`) is a specialist
agent designed to inspect persisted chat sessions, agent logs, tool calls, and
token usage. It uses the provenance traversal methods to:

1. Load a top-level chat.
2. Follow the job dependency chain.
3. Load delegated agent chats from `log/` directories.
4. Produce structured summaries of inference workloads.

This makes it possible to ask an agent: "How did this multi-agent system handle
this inference workload?" and get a grounded, provenance-backed answer.

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/chat/process/meta.rb` | Meta serialization, `message_index`, `trace_indices`, job traversal |
| `lib/scout/llm/backends/default.rb` | `update_meta` — writes token fields after inference |
| `lib/scout/llm/agent/workflow.rb` | `Chat.project` — wraps job results with `meta job=` |
| `scout_commands/llm/info` | CLI provenance inspection |
| `scout_commands/llm/prov` | CLI provenance tree (superseded) |

---

## Cross-references

- [ChatLifecycle.md](ChatLifecycle.md) — How meta messages fit in the chat structure.
- [../../research/provenance-analysis.md](../../research/provenance-analysis.md) — Deep investigation.
- [../../research/multi-agent-patterns-analysis.md](../../research/multi-agent-patterns-analysis.md) — ChatAnalyst agent.
