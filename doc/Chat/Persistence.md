# Chat Persistence

Chats in Scout-AI are **plain text files**. Every conversation — whether a
one-shot CLI question, an agent session, or the output of a workflow job — is
serialised to the same human-editable `.chat` format. This makes chats
inspectable, diffable, reusable as imports, and durable across runs.

This document covers:

- The `.chat` file format
- How Scout's `Persist` system registers and uses the chat driver
- How chats are saved (the `Chat` annotation and serialization helpers)
- **Provenance annotations** — the `meta:` role that records agent names, job
  IDs, token counts, and parent chats
- The `trace_chats` recursive traversal
- How `LLM.ask` caches inference results by default (preserved from
  §6 below)
- How chat files relate to workflow job directories (`files_dir`, `log/`)
- Practical examples

---

## 1. The `.chat` file format

A chat file is a text file with a simple structure: each message starts with a
**role** followed by a colon, then a blank line, then the message body. Bodies
extend until the next role marker or end of file.

```text
system:

You are a helpful assistant.

user:

What is the capital of France?

assistant:

The capital of France is Paris.
```

### 1.1 Roles

Roles are free-form strings, but the common ones are:

| Role | Meaning |
|---|---|
| `system` | System / instruction prompt |
| `user` | User turn |
| `assistant` | Model output |
| `meta` | Provenance / metadata marker (see §4) |
| `tool`, `kb`, `mcp`, `introduce`, `association` | Tool-registration messages (see [../Tools/Tools.md](../Tools/Tools.md)) |
| `task`, `exec_task`, `inline_task` | Inline workflow execution |
| `job`, `inline_job` | Inline job result injection |
| `function_call`, `function_call_output` | Tool call / result pairs |
| `import`, `continue`, `last` | Import another chat file |
| `file`, `image`, `pdf`, `directory` | File attachments |
| `option` | Per-chat options (endpoint, model, …) |
| `clear`, `skip`, `clear_tools`, `clear_associations` | Maintenance directives |

See [Chat.md](Chat.md) for the full role reference.

### 1.2 Parsing and serialization

The parser lives in `lib/scout/llm/chat/parse.rb`:

| Method | Purpose |
|---|---|
| `Chat.parse(text)` | Parse a chat-file string into an Array of `{role:, content:}` hashes |
| `LLM.print(messages)` | Serialize an Array of message hashes back to chat-file text |
| `LLM.chat(input)` | Compile / expand a chat (resolves imports, files, tool roles, etc.) |

These are inverses for standard message types. `LLM.chat` additionally performs
**compilation** (resolving `import:`, `file:`, `task:` and other control roles)
before returning the final message array. `LLM.print` only serializes; it does
not re-compile.

```ruby
# Parse a chat file from disk
messages = Chat.parse(File.read("conversation.chat"))

# Serialize messages back to text
text = LLM.print(messages)

# Compile (resolve imports, tools, etc.) — what LLM.ask does internally
messages = LLM.chat("conversation.chat")
```

---

## 2. Persist driver registration

Scout's general `Persist` system supports type-specific save/load drivers.
Chat support is registered in `lib/scout/llm/chat/persist.rb`:

```ruby
Persist.save_drivers[:chat] = proc do |file, content|
  case content
  when LLM::Agent
    # Persist only the messages added after the agent's start_chat
    new_chat = content.current_chat - content.start_chat
    Open.sensible_write(file, LLM.print(new_chat))
  when Array
    Open.sensible_write(file, LLM.print(content))
  else
    # IO-like streams (TSV::Dumper, etc.)
    Open.sensible_write(file, content.respond_to?(:stream) ? content.stream : content)
  end
end

Persist.load_drivers[:chat] = proc do |file|
  String === file ? LLM.chat(file) : file
end

Workflow::TYPE_EXTENSIONS[:chat] = :chat
```

Key points:

- **Save driver**: accepts an `LLM::Agent` (serializes only the post-`start_chat`
  turns), a plain `Array` of messages, or an IO-like stream.
- **Load driver**: compiles the chat file via `LLM.chat` (so imports, tool
  roles, etc. are resolved on load).
- **Workflow type extension**: `Workflow::TYPE_EXTENSIONS[:chat] = :chat`
  tells Scout workflows that a task whose type is `:chat` should produce a
  `.chat` file. This is how the `Agent/* /ask` tasks persist their results.

### 2.1 What this means for workflow jobs

When a workflow task declares `task :ask => :chat`, the result is persisted as
a `.chat` file in the job's directory:

```
~/.scout/var/jobs/Agent/Worker/ask/<jobname>/
├── _.info
├── 1.chat                     ← the result
└── ...
```

---

## 3. How chats are saved

### 3.1 The `Chat` annotation

`Chat` uses scout-essentials' `Annotation` system to add methods to a plain
Array without wrapping it (see [Chat.md](Chat.md)). Among these methods are
convenience builders that don't directly persist — persistence is delegated to
`Persist` and `Open.sensible_write` (atomic write with temp file + rename).

### 3.2 Saving a chat to a file

You typically don't call the Persist driver directly. Instead:

```ruby
# Via LLM.ask with return_messages: true
messages = LLM.ask("Hello", return_messages: true, endpoint: :nano)
File.write("reply.chat", LLM.print(messages))

# Via the CLI with -c (append mode)
#   scout-ai llm ask -c conversation.chat -e nano "Follow-up question"
```

When you use `-c <file>`, the CLI:

1. Loads the existing chat file.
2. Appends the new `user` message.
3. Calls `LLM.ask`.
4. Appends the assistant response to the file.

### 3.3 Agent chat persistence

When an `LLM::Agent` runs, its conversation is accumulated in
`agent.current_chat`. When the agent's `ask` task completes, the save driver
serializes only the messages **after** `start_chat` — the system prompt and
seeded context are not duplicated in the output.

---

## 4. Provenance annotations (`meta:` messages)

Provenance in Scout-AI is **inline**: instead of a separate database, metadata
is embedded in `meta`-role messages within the chat transcript itself.

### 4.1 The meta format

A meta message has `role: meta` and a content string of space-separated
`key=value` pairs:

```text
meta:

pt=320 ct=180 tt=500 pt_c=1500 ct_c=900 tt_c=2400 pt_s=320 ct_s=180 tt_s=500 reas=Identified key entities
```

The serialization layer lives in `lib/scout/llm/chat/process/meta.rb`:

| Method | Purpose |
|---|---|
| `Chat.serialize_meta(hash)` | Convert a Hash to the `key=value` string (sorted by value length) |
| `Chat.parse_meta(str)` | Parse a `key=value` string into an `IndiferentHash` |
| `Chat.meta(messages)` | Strip all meta messages and return a merged metadata Hash |

### 4.2 Token fields

Written by `Backend::Default#update_meta` after each inference:

| Field | Meaning |
|---|---|
| `pt` | Prompt tokens for this single inference |
| `ct` | Completion tokens for this single inference |
| `tt` | Total tokens for this single inference |
| `pt_s`, `ct_s`, `tt_s` | **Session** cumulative counters (per-thread running totals) |
| `pt_c`, `ct_c`, `tt_c` | **Chat** cumulative counters (persisted across requests) |
| `reas` | Reasoning summary string (truncated) |

> **Important:** The `_c` (chat cumulative) and `_s` (session) counters are
> checkpoints. They must **never** be summed across chats or segments — that
> would double-count. Only `pt`, `ct`, `tt` (per-inference) are summable.

### 4.3 Job-reference fields

| Field | Meaning |
|---|---|
| `job` | Canonical path of the Scout workflow job that produced this segment |

A `meta job=<path>` marker indicates a **projected** segment — a response that
originated from a workflow job (typically an `Agent/*/ask` task). It has
**zero direct token cost**; the real inference tokens are recorded in the
job's own agent logs.

### 4.4 The `Chat.project` method

When a chat-task produces output, `Chat.project(job, messages)` wraps the
non-meta messages with a leading `meta job=<path>` marker:

```ruby
[{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected_messages
```

This lets consumers detect the job origin without scanning for token fields.

### 4.5 Two kinds of meta messages

1. **Direct inference meta** — contains `pt`/`ct`/`tt` (and optionally
   cumulative/session variants and `reas`). Records one actual model call.
2. **Job projection meta** — contains only `job=<path>`. Marks a segment
   projected from an ask-workflow job with zero direct token cost.

---

## 5. Recursive traversal: `trace_chats`

Because a single Scout-AI session can span multiple chats, jobs, and agent
logs, provenance requires recursive traversal.

### 5.1 Message lineage IDs

`Chat#message_index` computes a **lineage ID** for each message:

```ruby
id = Misc.digest([previous_id, role, content])
```

Each message's ID incorporates the previous *conversational* message's ID
(meta messages are excluded from the lineage chain). This creates a hash-chain
where `prev` links each message to its predecessor.

### 5.2 Response segments

`Chat.trace_indices(indices)` walks message indices and groups them into
**response segments**:

1. A `meta` message closes the current segment and opens a new one (seeded
   with the parsed metadata).
2. `user` and `system` messages also close any pending segment.
3. All other messages are appended to the current segment.

Each segment record:

```ruby
{ id: <lineage_id>, meta: <parsed_meta_hash>, messages: [<id>, ...], orphan: true|false }
```

### 5.3 `Chat.trace_chats`

```ruby
def self.trace_chats(chats)
  trace_indices(chats.collect(&:message_index))
end
```

Takes an array of `Chat` objects and returns a flat array of segment records.

**Token accounting from the trace:** filter to entries where `meta` has no
`:job` key but has `pt`/`ct`/`tt`, then sum those fields.

### 5.4 Job dependency traversal

`Chat.job_chat_files(job, seen)` performs recursive traversal of the **job
dependency graph**:

1. Load the job via `Step.load`.
2. If the job is done and its type is `chat`, add its result path.
3. Add all `log/**/*.chat` files from the job's `files_dir`.
4. For each dependency, recurse (using a `seen` Set to prevent cycles).
5. Return the unique set of all discovered chat file paths.

Instance methods on `Chat` objects:

| Method | Returns |
|---|---|
| `chat.job_paths` / `chat.jobs` | Array of `Path` objects from all `meta job=...` messages |
| `chat.job_chat_files` | All chat files reachable from this chat's jobs and their dependencies |
| `chat.job_agent_chat_files` | All `log/**/*.chat` files from this chat's jobs and dependencies |
| `chat.job_chats` | All `Chat` objects loaded from `job_chat_files` |
| `chat.job_agent_chats` | All `Chat` objects loaded from `job_agent_chat_files` |
| `chat.message_index` | Array of per-message lineage records |
| `chat.meta` | Parsed metadata Hash from the last meta message |
| `chat.last_job` | The `job` value from the last meta message |

---

## 6. Caching behavior in `LLM.ask`

> Originally documented in the legacy `LLM.md`; now canonical here.

`LLM.ask` caches responses by default via `Persist.persist`:

```ruby
endpoint, persist = IndiferentHash.process_options options,
  :endpoint, :persist, persist: true
```

- **Default:** `persist: true` — responses are cached on disk under
  `Scout.var.cache.ask`.
- **Disable:** pass `persist: false` to always re-run the model.

### 6.1 Cache key composition

The cache key is built from:

- The **endpoint** name
- The compiled **messages** array
- Most **options** (model, tools, format, etc.)

The cache is content-addressed: if the prompt or any relevant option changes,
the cache misses and the model is called again.

### 6.2 What the cache stores

The cached value is the **full message trace** (assistant response, tool calls,
tool outputs, meta markers). When the cache hits, no model call is made — the
stored messages are returned directly.

```ruby
# First call — hits the model, caches the result
res = LLM.ask("What is 2+2?", endpoint: :nano)

# Second call — same prompt, returns cached result
res = LLM.ask("What is 2+2?", endpoint: :nano)

# Disable cache
res = LLM.ask("What is 2+2?", endpoint: :nano, persist: false)
```

---

## 7. Chat files and workflow jobs

### 7.1 The `files_dir`

Every Scout workflow job has a `files_dir` — a directory for auxiliary files
beside the main result. For `ask` jobs (agent tasks), this is where agent chat
logs live:

```
~/.scout/var/jobs/Agent/Worker/ask/<jobname>/
├── _.info
├── 1.chat                          ← main result (type: :chat)
└── files/
    └── log/
        ├── agent.chat              ← full agent conversation
        └── chats/
            └── <AgentName>/        ← socialized projections (named conversations)
```

### 7.2 The `log/` directory

The `log/` subdirectory inside `files_dir` contains agent conversation logs:

- `log/agent.chat` — the agent's full conversation with the model, including
  tool calls, system prompt, and all turns.
- `log/chats/<AgentName>/<conversation>.chat` — when an agent delegates to
  another agent with a named conversation, the interaction may be persisted
  here. These files contain the prompt, propagated options, a `meta: job=...`
  marker, and the response — but **zero direct inference tokens**. The real
  model calls are found by following the `meta: job=...` reference.

### 7.3 Read-access for tool execution

When `LLM.ask` detects `meta job=...` references in the messages, it grants
filesystem read access to those jobs' `files_dir`:

```ruby
job_paths.each do |job_path|
  job = Step.load(Path.setup(job_path))
  jobs = [job] + job.rec_dependencies.to_a
  jobs.each do |j|
    Chat.allow_read_dir(j.files_dir) if Open.exist?(j.files_dir)
  end
end
```

This allows the model to reference files produced by upstream jobs.

### 7.4 The provenance tree

A Scout-AI session is a **tree** (or DAG) of conversations connected by:

| Edge type | Meaning |
|---|---|
| **Import** | `import:`/`continue:`/`last:` roles pull in previous chat history |
| **Result** | `meta: job=<path>` markers indicate a segment produced by a workflow job |
| **Dependency** | Scout workflow jobs have dependencies (other jobs they consume) |
| **Log** | Each ask-job has a `log/` directory containing agent chat files |
| **Call** (semantic) | Tool calls to `ask` or `hand_off_to_*` represent agent-to-agent delegation |

---

## 8. Practical examples

### 8.1 Reading a chat file

```ruby
# Load and compile (resolves imports, tools, etc.)
messages = LLM.chat("conversation.chat")

# Or parse without compilation
messages = Chat.parse(File.read("conversation.chat"))

# Access messages by role
user_messages = Chat.setup(messages).role_messages("user")
```

From the CLI:

```bash
# Print the chat as-is
cat conversation.chat

# Format as Markdown
scout-ai llm md conversation.chat

# Convert to JSON
scout-ai llm json -c conversation.chat
```

### 8.2 Writing a chat file

```ruby
chat = Chat.setup([])
chat.system("You are helpful.")
chat.user("Hello!")
chat.assistant("Hi there!")

File.write("greeting.chat", LLM.print(chat))
```

### 8.3 Examining provenance

```ruby
chat = Chat.load("conversation.chat")

# Get all job references
chat.job_paths.each { |p| puts "Job: #{p}" }

# Get all chat files in the provenance tree
chat.job_chat_files.each { |f| puts "Chat file: #{f}" }

# Trace response segments and sum tokens
segments = Chat.trace_chats([chat] + chat.job_chats)
direct = segments.select { |s| s[:meta][:pt] && !s[:meta][:job] }
total_tokens = direct.sum { |s| s[:meta][:tt].to_i }
puts "Total direct tokens: #{total_tokens}"
```

From the CLI:

```bash
# Inspect a chat's provenance (recommended)
scout-ai llm info conversation.chat

# Compact flow view
scout-ai llm info -f conversation.chat

# Generate a Graphviz diagram
scout-ai llm info --plot provenance.pdf conversation.chat
```

### 8.4 Disabling the cache

```ruby
# Programmatic
res = LLM.ask("Generate a random story", endpoint: :nano, persist: false)

# The cache key is content-addressed, so changing any option also busts the cache:
res = LLM.ask("Generate a random story", endpoint: :nano, temperature: 0.9)
```

---

## 9. Cross-references

- [Chat.md](Chat.md) — full role reference, the `Chat` annotation, compilation
- [../Tools/Tools.md](../Tools/Tools.md) — how `meta` messages with tool-call
  pairs are produced
- [../Agent/Delegation.md](../Agent/Delegation.md) — how `ask` / `hand_off_to_*`
  create provenance chains
- [../Commands/Commands.md](../Commands/Commands.md) — the `llm info` command
