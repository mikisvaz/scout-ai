> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# Provenance System: Chat.provenance, trace_chats, prov/info Commands, and ChatAnalyst

> **Scope:** How Scout-AI records, traverses, and reports the lineage of every
> inference — across imported chats, ask-job results, nested agent logs, and
> dependency chains — and the two CLI commands (`prov` and `info`) and the
> ChatAnalyst workflow that consume that provenance data.

---

## Provenance Data Model

### What provenance metadata is stored

Scout-AI does not have a standalone "provenance" table. Instead, provenance
information is embedded in **meta messages** that appear inline within the
chat transcript itself. A meta message has `role: meta` and a content string
serialized as `key=value key=value ...`.

The serialization/parsing layer lives in
`lib/scout/llm/chat/process/meta.rb`:

| Method | Purpose |
|---|---|
| `Chat.serialize_meta(hash)` | Converts a hash to the `key=value` string format, sorted by value length. |
| `Chat.parse_meta(str)` | Parses a `key=value` string back into an `IndiferentHash`. |
| `Chat.meta(messages)` | Strips all `meta` messages from an array and returns a merged metadata hash. The last checkpoint with `pt_c`/`ct_c`/`tt_c` fields is used for cumulative counters. |

#### Fields that can appear in a meta message

**Token fields** (written by `Backend::Default#update_meta` in
`lib/scout/llm/backends/default.rb`):

| Field | Meaning |
|---|---|
| `pt` | Prompt tokens for this single inference |
| `ct` | Completion tokens for this single inference |
| `tt` | Total tokens for this single inference |
| `pt_s`, `ct_s`, `tt_s` | **Session** cumulative counters (per-thread running totals) |
| `pt_c`, `ct_c`, `tt_c` | **Chat** cumulative counters (persisted across requests) |
| `reas` | Reasoning summary string (truncated for display) |

**Job-reference field** (written when a chat-task result is projected):

| Field | Meaning |
|---|---|
| `job` | The canonical path of the Scout workflow job that produced this segment |

#### Two kinds of meta messages

1. **Direct inference meta** — contains `pt`, `ct`, `tt` (and optionally
   cumulative/session variants and `reas`). This records one actual model call.

2. **Job projection meta** — contains only `job=<path>`. This marks a response
   segment that was projected from an ask-workflow job. It has **zero direct
   token cost** — the actual tokens are recorded in the job's own agent logs
   and dependency chain.

### How annotation.rb tracks provenance

The file `lib/scout/llm/chat/annotation.rb` provides the `Chat` annotation
(through `extend Annotation`). It adds convenience methods like `user`,
`assistant`, `import`, `option`, `endpoint`, `model`, etc. But it does **not**
contain provenance-specific methods — those all live in
`lib/scout/llm/chat/process/meta.rb`.

Relevant provenance-related instance methods on `Chat` objects (all defined in
`process/meta.rb`):

| Method | Returns |
|---|---|
| `chat.job_paths` / `chat.jobs` | Array of `Path` objects extracted from all `meta job=...` messages |
| `chat.job_chat_files` | All chat files (result + logs) reachable from this chat's jobs and their dependencies |
| `chat.job_agent_chat_files` | All `log/**/*.chat` files from this chat's jobs and their dependencies |
| `chat.job_chats` | All `Chat` objects loaded from `job_chat_files` |
| `chat.job_agent_chats` | All `Chat` objects loaded from `job_agent_chat_files` |
| `chat.message_index` | Array of per-message lineage records with `id`, `role`, `prev`, `fingerprint`, and parsed `meta` |
| `chat.meta` | The parsed metadata hash from the last meta message |
| `chat.last_job` | The `job` value from the last meta message |

### The `Chat.project` method

When a chat-task produces output, `Chat.project(job, messages)` wraps the
non-meta messages with a single `meta job=<path>` marker at the front. This
ensures that consumers can detect the job origin without scanning for token
fields:

```ruby
[{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected_messages
```

---

## Recursive Traversal / trace_chats

### Lineage IDs and message_index

`Chat#message_index` (defined in `process/meta.rb`) computes a **lineage ID**
for each message:

```ruby
id = Misc.digest([previous_id, role, content])
```

Each message's lineage ID incorporates the previous conversational message's ID
(meta messages are excluded from the lineage chain — they start segments but
are not provider input). This creates a hash-chain where `prev` links each
message to its predecessor in the *conversational* history.

The index also assigns each message a `fingerprint` (a truncated head/tail
digest via `Log.truncate_string`) for compact comparison.

### Response segments and trace_indices

`Chat.trace_indices(indices)` walks a set of message indices and groups them
into **response segments**. The algorithm:

1. Iterate through messages in order.
2. When a `meta` message is encountered, **close** the current pending segment
   (if any) and **open** a new one, seeded with the parsed metadata.
3. `user` and `system` messages also close any pending segment.
4. All other messages (`assistant`, `function_call`, `function_call_output`,
   `tool`, etc.) are appended to the current segment's message list.
5. At the end, close any remaining pending segment.
6. Each segment gets `orphan: true` if it has zero covered messages.

A `seen` Set of lineage IDs prevents double-counting.

### trace_chats

```ruby
def self.trace_chats(chats)
  trace_indices(chats.collect(&:message_index))
end
```

This takes an array of `Chat` objects, computes `message_index` on each, then
runs `trace_indices` across all of them. The result is a flat array of segment
records:

```ruby
{ id: <lineage_id>, meta: <parsed_meta_hash>, messages: [<id>, ...], orphan: true|false }
```

### What trace_chats returns

Each entry represents one **response segment** — one model call (or one job
projection). The `meta` field tells you whether it's a direct inference (has
`pt`/`ct`/`tt`) or a projection (has `job`). The `messages` array lists the
lineage IDs of all messages that belong to that segment.

**Token accounting from the trace:** To count tokens, filter to entries where
`meta` has no `:job` key but has `pt`/`ct`/`tt`, then sum those fields. The
`*_c` and `*_s` counters are checkpoints and must never be summed — they would
double-count.

### Job-based recursive provenance

The `Chat.job_chat_files(job, seen)` class method performs recursive traversal
of the **job dependency graph**:

1. Load the job via `Step.load`.
2. If the job is done and its type is `chat`, add its result path.
3. Add all `log/**/*.chat` files from the job's `files_dir`.
4. For each dependency, recurse (using a `seen` Set to prevent cycles and
   duplicate visits).
5. Return the unique set of all discovered chat file paths.

This is the mechanism that `chat.job_chat_files` (instance method) uses to
discover the full provenance tree below a chat.

---

## The `prov` Command

**File:** `scout_commands/llm/prov`

### What it does

`prov` prints a hierarchical, indented tree showing the provenance structure
below a chat file or job path. It walks jobs → agent logs → dependencies
recursively and prints token totals at each node.

### Usage

```bash
scout-ai llm prov <filename>
```

### How it works (internals)

The `prov` command **monkey-patches** several methods onto the `Chat` and
`Step` classes at runtime (these are NOT in the library):

- `Chat.provenance(chat_file, prov={})` — recursively walks a chat's jobs,
  their agent chat files, and dependencies, building a hash mapping each chat
  file to the list of agent chat files it references.
- `Chat.provenance_chat_files(chat)` — flattens the provenance hash into a
  unique list of all chat files.
- `Chat.tokens(chat)` — loads all provenance chat files, then sums `pt`/`ct`/
  `tt` from direct entries only.
- `Chat.trace`, `Chat.direct_entries`, `Chat.token_totals`,
  `Chat.print_tokens` — helper methods for trace-based token accounting.
- `Chat.job_agent_chat_files(job)` — **redefines** the library method.
- `Step#agent_chats` — new method on Step.

These monkey-patches mean `prov` is self-contained but diverges from the
library's actual API. The `Chat.job_agent_chat_files` in the library already
exists and works similarly; the `prov` version is a redundant redefinition.

### Output format

```
job   total=1.2k prompt=800 cont=400 ~/.scout/var/jobs/.../ask
  chat   total=500 prompt=300 cont=200  agent.chat
  job   total=700 prompt=500 cont=200 ~/.scout/var/jobs/.../subtask
```

- **Yellow `job`** lines show job paths with token totals.
- **Green `chat`** lines show chat/agent-log files with token totals.
- Indentation reflects the nesting depth.
- Token totals are computed by summing `pt`/`ct`/`tt` from direct inference
  metas across all provenance chat files.

### Limitations

- The `agent.chat` file (the default agent log) is suppressed in the output
  (`unless name == 'agent.chat'`), but its tokens are still counted.
- The command has a hardcoded fallback filename:
  `~/git/workflows/SC26/chats/network_usecase/3.1.themes` if no argument is
  given.
- It does not produce machine-readable output (no JSON mode).

---

## The `info` Command — STATUS ASSESSMENT

**File:** `scout_commands/llm/info`

### What it does

`info` is a **substantially more capable** command than `prov`. It:

1. **Discovers the full provenance graph** — root chat, imports, job results,
   job dependencies, and agent logs — using a BFS traversal.
2. **Deduplicates jobs** by a canonical identity (workflow/task/basename) so
   that `~/.scout` and `~/.rbbt` mirrors of the same job appear once.
3. **Reports** chats (with role/message counts and job references), jobs (with
   workflow/task, log count, dependency count), and token usage (root-only vs
   all-traced).
4. **Optional flow mode** (`-f`/`--flow`): prints a compact numbered node/edge
   list with token annotations.
5. **Optional DOT/plot mode** (`--dot`, `--plot`): generates Graphviz DOT or
   renders SVG/PNG/PDF.

### Is `info` outdated? — **NO, it is current and well-maintained**

The user suspected `info` might be outdated. After thorough cross-referencing,
**the `info` command is NOT outdated**. It is in fact the more modern and
complete implementation. Here is the specific evidence:

#### Methods/APIs it calls and their current status

| API used by `info` | Defined in | Still exists? |
|---|---|---|
| `Chat.load(path)` | `lib/scout/llm/chat/process/meta.rb:86` | ✅ Yes |
| `Chat.trace_chats(chats)` | `lib/scout/llm/chat/process/meta.rb:195` | ✅ Yes |
| `Chat.find_file(...)` | `lib/scout/llm/chat/process/files.rb:17` | ✅ Yes |
| `chat.role_messages(role)` | `lib/scout/llm/chat/annotation.rb` | ✅ Yes |
| `chat.jobs` / `chat.job_paths` | `lib/scout/llm/chat/process/meta.rb:76` | ✅ Yes |
| `job.dependencies` | Scout `Step` API | ✅ Yes |
| `job.file('log')` | Scout `Step` API | ✅ Yes |
| `job.info[:workflow]`, `job.info[:task_name]` | Scout `Step` API | ✅ Yes |
| `job.done?`, `job.type` | Scout `Step` API | ✅ Yes |
| `Step.load(path)` | Scout API | ✅ Yes |

#### Annotation fields it reads

The `info` command reads `pt`, `ct`, `tt` from parsed meta messages via
`Chat.trace_chats` → `trace_indices` → per-entry `:meta` hash. These fields are
written by `Backend::Default#update_meta` (line 420 of `backends/default.rb`)
and are fully current.

It correctly filters to **direct entries only** (entries whose meta has no
`:job` key but has `pt`/`ct`/`tt`), matching the exact pattern used by
`ChatAnalyst::Session#token_entries`.

#### What `info` does that `prov` does not

| Feature | `info` | `prov` |
|---|---|---|
| Import discovery | ✅ (`import`/`continue`/`last` roles) | ❌ |
| Job deduplication | ✅ (canonical identity by workflow/task/basename) | ❌ |
| Dependency graph | ✅ | ✅ (via Chat.provenance) |
| Flow visualization | ✅ (text flow + Graphviz DOT/SVG/PNG/PDF) | ❌ |
| Warnings | ✅ (records load failures) | ❌ |
| Token accounting | ✅ (`trace_chats` + direct_entries) | ✅ (same approach, but monkey-patched) |
| Uses library API directly | ✅ (no monkey-patching) | ❌ (redefines Chat methods) |

#### Assessment summary

- **`info` is the current, recommended command** for provenance inspection.
- **`prov` is older** and relies on runtime monkey-patches rather than the
  library API. It still works but is superseded by `info` in functionality.
- Neither command is "broken" — both will execute successfully.
- If anything is "outdated," it is `prov` (monkey-patches, no import
  discovery, no flow/DOT output), not `info`.

---

## ChatAnalyst Provenance Capabilities

**Location:** `~/git/workflows/SC26/Agent/ChatAnalyst/`

### What the ChatAnalyst agent does

ChatAnalyst is a Scout-AI agent specialized in **inspecting work sessions** to
find usage patterns, tool-calling issues, barriers, and areas for improving
the harness, agent instructions, or tooling.

Its system prompt (`start_chat`) directs it to:
- Follow conversations across different chats and ask jobs.
- Inspect persisted chat sessions for patterns and issues.
- Use the ChatAnalyst workflow tooling (README.md) for structured analysis.

### The Session class (workflow.rb core)

The `workflow.rb` defines a `ChatAnalyst::Session` class that performs
BFS-based discovery identical in spirit to `info`'s `LLMInfoReport`:

1. **`resolve_chat(input)`** — tries multiple candidate paths (plain,
   `.chat` extension, expanded, `Scout.chats[]` lookup).

2. **`discover_chat(path)`** — for each chat:
   - Records it in `@chats`.
   - Follows `import`/`continue`/`last` roles to discover imported chats
     (adding `import` edges).
   - Follows `meta job=...` references to discover producer jobs (adding
     `result` edges).

3. **`discover_job(reference)`** — for each job:
   - Records it in `@jobs`.
   - Follows dependencies recursively (adding `dependency` edges).
   - If the job is done and type is `chat`, discovers the result chat (adding
     it to the chat queue).
   - Scans `log/**/*.chat` for agent conversation logs (adding `log` edges and
     feeding them back into `discover_chat`).

4. **Token accounting** — `token_entries` filters the trace to direct inference
   segments (no `:job` key, has `pt`/`ct`/`tt`). `token_totals` sums them.

### Tasks exposed by the ChatAnalyst workflow

| Task | Type | Purpose |
|---|---|---|
| `message_index` | JSON | Compact per-message index across the full session tree. Each entry has an ID (`file#index`), lineage ID, previous lineage ID, role, fingerprint, and parsed meta. Supports optional `role` filter. |
| `message_content` | JSON | Retrieves full untruncated content for specific message IDs. Two-phase inspection: scan index → drill into interesting messages. |
| `chat_overview` | JSON | Structural graph overview: per-file summaries (roles, messages, jobs, tool calls), per-job summaries (workflow/task, dependencies, logs), typed edges, aggregate totals, warnings. |
| `chat_tool_calls` | JSON | Pairs `function_call`/`mcp_call` with `function_call_output` by call ID. Reports tool name, call ID, output position, success/failure, exception/exit status. Summary: totals, successes, failures, breakdown by tool. |
| `chat_tokens` | JSON | Per-file and aggregate token accounting using direct `pt`/`ct`/`tt` metas only. Includes `note` explaining methodology. |
| `chat_agents` | JSON | Detects `ask` and `hand_off_to_*` calls. Reports interactions with source file, call ID, output position, success state. |
| `chat_report` | JSON | Combined snapshot: session size, job count, aggregate tokens, trace records, first 20 tool calls, all failures, warnings. |

### Tooling file

The `tooling` file in the ChatAnalyst agent directory is a **chat session
log** (not a tooling declaration file). It contains the conversation in which
the ChatAnalyst workflow was originally designed, including a detailed
critique and README update session. It is not loaded as tooling — it is a
record of the development process.

### How ChatAnalyst compares to `info`

| Aspect | `info` CLI | ChatAnalyst workflow |
|---|---|---|
| Consumer | Human (terminal output, DOT/SVG) | Agent (JSON tasks) |
| Discovery | Identical BFS (imports, jobs, deps, logs) | Identical BFS |
| Token accounting | `trace_chats` + direct entries | `trace_chats` + direct entries |
| Job deduplication | ✅ (canonical identity) | ❌ (simple expand_path check) |
| Tool-call analysis | ❌ | ✅ |
| Agent-interaction analysis | ❌ | ✅ |
| Output | Text / Graphviz | JSON |
| Graphviz rendering | ✅ | ❌ |

---

## Key Design Notes

### The provenance tree metaphor

A Scout-AI session is not a single flat conversation. It is a **tree** (or DAG)
of conversations connected by:

1. **Import edges** — `import:`/`continue:`/`last:` roles pull in previous
   chat history, creating a horizontal chain of related conversations.

2. **Result edges** — `meta: job=<path>` markers indicate that a response
   segment was produced by a Scout workflow job (typically an `ask` task).
   The actual inference happened inside that job's agent logs.

3. **Dependency edges** — Scout workflow jobs have dependencies (other jobs
   they consume). Each dependency may itself be a chat-producing job with its
   own agent logs.

4. **Log edges** — Each ask-job has a `log/` directory containing agent chat
   files. The primary `log/agent.chat` is the agent's full conversation.
   Socialized projections may appear under `log/chats/<AgentName>/`.

5. **Call edges** (semantic, not structural) — Tool calls to `ask` or
   `hand_off_to_*` represent agent-to-agent delegation. These are detected by
   scanning tool-call messages, not by following meta references.

### How multi-agent inference creates provenance chains

When an orchestrator agent (e.g., `AGI`) dispatches work to a specialist agent
(e.g., `Worker`) via `ask`:

1. The orchestrator's chat contains a `function_call` with tool name `ask` and
   arguments naming the target agent.
2. The `ask` call triggers a Scout workflow job (e.g.,
   `Agent/Worker/ask`).
3. That job runs the target agent, producing `log/agent.chat` with the full
   agent conversation and its own `meta:` entries with direct token counts.
4. The job result is projected back into the orchestrator's chat as a
   `meta: job=<path>` marker followed by the response messages.
5. The orchestrator's chat thus has a **zero-token projection segment** — the
   real tokens are in the job's `agent.chat`.

This means token accounting requires **recursive traversal**: start at the root
chat, follow every `meta: job=...` to its job, read the job's `agent.chat`
logs, follow the job's dependencies, and sum only direct `pt`/`ct`/`tt`
entries. Cumulative (`*_c`) and session (`*_s`) counters must never be summed
because they would double-count across the import/projection chain.

### Socialized chat projections

When an agent dispatches to another agent with a named `conversation`, the
specialist interaction may be persisted as a socialized chat at:
```
<caller_job>.files/log/chats/<AgentName>/<conversation>.chat
```
These files contain the prompt, propagated `option:` lines, a `meta: job=...`
marker, and the response — but **zero direct inference tokens**. The real
model calls are found by following the `meta: job=...` reference into the
specialist's ask-job and its `agent.chat` log.

### Why `info` is preferred over `prov`

- `info` uses the library API directly (no monkey-patching).
- `info` discovers imports (prov does not).
- `info` deduplicates mirrored jobs between `~/.scout` and `~/.rbbt`.
- `info` supports flow visualization (text + Graphviz).
- `info` records and reports warnings for load failures.
- `prov` remains functional but is architecturally older and less complete.

### Design consistency between `info` and ChatAnalyst

Both `info` and ChatAnalyst use the same `Chat.trace_chats` API for token
accounting and the same BFS pattern for provenance discovery. The key
difference is that `info` adds job deduplication (canonical identity), while
ChatAnalyst adds tool-call and agent-interaction analysis. They are
complementary tools for the same provenance data model.
