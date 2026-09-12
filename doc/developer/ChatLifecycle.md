# Chat Lifecycle

This document describes how the `Chat` abstraction works internally: its data
model, the Annotation pattern that gives it a DSL, and the compilation
pipeline that transforms chat-file text into inference-ready message arrays.
It is intended for framework contributors.

> For the user-facing chat-file format guide, see
> [../user/WritingChats.md](../user/WritingChats.md).
> For the probe-verified subsystem study (roles, parse/print round-trip,
> compilation, persistence), see
> [../../research/subsys/chat.md](../../research/subsys/chat.md) under `research/`.

---

## The Chat-as-data philosophy

The most important design decision in Scout-AI:

> **A Chat is a plain `Array` of message `Hash`es, not an opaque object.**

The `Chat` module uses the `Annotation` pattern (from scout-essentials) to add
DSL methods to a plain Array. The underlying data structure is always directly
accessible:

```ruby
chat = Chat.setup([])
chat.user("Hello")

chat.class            # => Array
chat.first[:role]     # => "user"
chat.first[:content]  # => "Hello"
chat.select { |m| m[:role] == 'system' }  # standard Array operations work
```

This means chats are serializable, composable, introspectable, and cacheable,
with no lock-in.

---

## Message roles

Each message in a Chat is a Hash with `:role` and `:content` keys. The system
recognizes these roles:

| Role | Purpose | Visible to model? |
|---|---|---|
| `system` | System instructions | Yes |
| `user` | User message | Yes |
| `assistant` | Model response | Yes |
| `function_call` | Tool invocation request from model | Yes (as provider-specific tool_call) |
| `function_call_output` | Tool execution result. May carry a `meta` key: an Array of already-deserialized receipt field Hashes (delegated inference metadata such as `pt`/`ct`/`tt`/`inference_id`, or `{"job":"<path>"}` producer references), embedded by `LLM.process_calls` when the tool returned an `LLM::Agent`. Only `meta` is read; the legacy serialized `agent_meta` key is no longer accepted, so legacy envelopes contribute no receipt evidence. Outputs may also carry auxiliary `step`/`start_timestamp`/`timestamp` fields; `step` is bookkeeping, not a provenance edge. See [Provenance.md](Provenance.md). | Yes (as provider-specific tool result) |
| `meta` | Provenance metadata (tokens, job references) | **No** — stripped before inference |
| `tool` | Tool definition (inline in chat) | No — extracted into tool registry |
| `introduce` | Workflow introduction | No — extracted; replaced by a `user:` message with the workflow's documentation (generates no tools) |
| `mcp` | MCP server declaration | No — extracted into tool registry |
| `kb` | Knowledge base declaration | No — extracted into tool registry |
| `association` | Association declaration | No — extracted |
| `option` | LLM option (model, endpoint, etc.) | No — extracted into options hash |
| `file` / `image` / `pdf` | Binary content | Processed into content blocks |

The `meta`, `tool`, `introduce`, `mcp`, `kb`, `option`, and similar roles are
**side-channel** roles: they are extracted from the message array during
compilation and do not appear in the prompt sent to the model.

---

## The Annotation pattern

`Chat` is not a class — it is an Annotation module:

```ruby
module Chat
  extend Annotation
  # DSL methods defined here: user, system, ask, follow, option, ...
end
```

When you call `Chat.setup(array)`, the Annotation system:

1. Adds Chat's methods to the **singleton class** of that specific Array instance.
2. Does **not** change the object's class (it remains `Array`).
3. Makes the annotation **removable** via `Annotation.purge(obj)`.

This is the "annotate, don't wrap" philosophy: you get rich behavior without
sacrificing the simplicity of the underlying data type.

---

## The compilation pipeline

When `LLM.ask` (or `Agent#ask`) receives input, the Chat compilation pipeline
transforms it through several stages:

```
Input (String / file / Array)
  │
  ▼
1. Parse     — Chat.parse: text → Array<Hash>
  │            (handles role: directives, block form, indented content)
  ▼
2. Indiferent — every message Hash is set up as an IndiferentHash
  │             (symbol/string-indifferent access)
  ▼
3. Imports    — import:/continue:/last: references expanded
  ▼
4. Clear      — clear: directives processed
  │            (removes tool outputs from history)
  ▼
5. Clean      — Chat.clean: default roles dropped from the prompt
  │            ('skip', 'previous_response_id')
  ▼
6. Config     — Chat.config: `config:` messages applied as Scout::Config.set
  ▼
7. Tasks      — task:/inline_task:/exec_task: messages run eagerly
  │
  ▼
8. Jobs       — pending jobs produced (Workflow.produce)
  ▼
9. Files      — file:/attach: roles resolved to content or paths
  ▼
10. Setup     — Chat.setup: the array is annotated with the Chat DSL,
               producing the compiled chat

Steps 2–10 are `Chat.chat`'s own order —
indiferent → imports → clear → clean → config → tasks → jobs → files →
setup — with parsing (step 1) done by `Chat.messages` before it. This
listing is complete; there is no hidden stage.
  │
  ▼
Backend path — endpoint/model/backend option: roles and
               tool:/introduce:/mcp:/kb:/association: roles are
               extracted here (Chat.options / Chat.tools), then
               prepare_prompt applies the context strategies
               (EPHEMERAL: operates on a copy, never mutates the stored chat)
               and format_messages translates into the provider format
  │
  ▼
API call
```

Note that options and tools extraction happens on the **backend path**, after
the chat itself has been compiled — that is why `option:`/`tool:` roles are
compiled away from the prompt but still configure the request.

### Key properties

- **Side-channel extraction**: Roles like `tool`, `option`, and `meta` are
  removed from the message array before the prompt is formatted. The model
  never sees them.
- **Ephemeral prompt preparation**: `prepare_prompt` operates on a **local copy**
  of the messages. The stored chat retains full-fidelity data. Only the
  inference API call sees the shortened version.
- **Provider-specific formatting**: Each backend translates the canonical
  message hashes into the format its API expects.

---

## Provenance annotations

After each inference, the backend inserts a `meta:` message into the chat
containing token counts and other provenance:

```
meta: pt=1234 ct=567 tt=1801 pt_s=5000 ct_s=2000 tt_s=7000 pt_c=15000 ...
```

These meta messages are:
- Interleaved with conversational messages in the stored chat.
- Excluded from the lineage chain (they start segments but are not provider input).
- Used by the provenance traversal system (see [Provenance.md](Provenance.md)).

---

## Persistence

Chats are serialized to `.chat` files — plain-text files using the chat-file
format (see [../user/WritingChats.md](../user/WritingChats.md)). The
`.chat` extension is registered as a load driver:

- **Load**: `LLM.chat(path)` or `Chat.setup(Chat.parse(File.read(path)))`.
- **Save**: `Chat.print(chat)` produces the text representation.
- `Chat.load(file)` is the **no-compile** reader (`Chat.setup(Chat.parse(...))`
  only, no task/job/file/import expansion). Provenance inspection uses it so
  reading a chat never re-executes anything.
- Annotated chats carry three writers that all default a bare filename to
  `Scout.chats` and skip existing files unless `force`: `save` (`LLM.print`
  of the chat), `write` (`self.print` — the processed form), and
  `write_answer` (the final answer text only).
- `.chat` is also a **workflow result type** (`Workflow::TYPE_EXTENSIONS[:chat]`
  with `Persist.save_drivers`/`load_drivers` in `chat/persist.rb`). Saving an
  `LLM::Agent` through that driver writes `current_chat - start_chat` — this
  run's delta, not the seeded preamble — while saving a plain Chat/Array writes
  every message. That is why a `chat_task` result file and the agent's
  full-conversation sidecar (`<job>.files/<name>.chat`) differ in length.

The format is human-readable and diffable, making it ideal for version control
and inspection.

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/chat.rb` | Chat module definition, `setup`, `parse` |
| `lib/scout/llm/chat/annotation.rb` | DSL methods (user, system, ask, follow, etc.) |
| `lib/scout/llm/chat/parse.rb` | Text → Array<Hash> parser |
| `lib/scout/llm/chat/process.rb` | Pipeline driver (indiferent → imports → clear → clean → config → tasks → jobs → files → setup) |
| `lib/scout/llm/chat/process/options.rb` | `Chat.config` — option/endpoint resolution |
| `lib/scout/llm/chat/process/tools.rb` | `Chat.tasks`/`Chat.jobs` plus tool/introduce/mcp/kb extraction |
| `lib/scout/llm/chat/process/clear.rb` | `Chat.clear`/`Chat.clean` |
| `lib/scout/llm/chat/process/files.rb` | `Chat.imports`/`Chat.files` |
| `lib/scout/llm/chat/process/meta.rb` | Meta messages, provenance, message_index |
| `lib/scout/llm/chat/prompt.rb` | `prepare_prompt` dispatch only; the strategies themselves live in the `chat/prompt/` strategy files below |
| `lib/scout/llm/chat/prompt/shorten_tools.rb` | Truncation strategy (not in the default list) |
| `lib/scout/llm/chat/prompt/shorten_tools_epoch.rb` | Cache-friendly epoch strategy |
| `lib/scout/llm/chat/prompt/shorten_tools_epoch_increment.rb` | Growing-window epoch strategy (default) |
| `lib/scout/llm/chat/prompt/inbox.rb` | Consume-once inbox strategy |

The prompt strategies are documented in
[PromptProcessing.md](PromptProcessing.md); this table only maps the files.
| `lib/scout/llm/chat/persist.rb` | .chat file load/save |
| `lib/scout/llm/chat/provenance.rb` | Provenance/receipt traversal primitives |
| `lib/scout/llm/chat/tool_calls.rb` | Tool-call message normalization |
| `lib/scout/llm/chat/agent_meta.rb` | Agent receipt (`meta`) message shaping |

---

## Cross-references

- [../user/WritingChats.md](../user/WritingChats.md) — Chat-file format from the user perspective.
- [PromptProcessing.md](PromptProcessing.md) — Context management internals.
- [Provenance.md](Provenance.md) — Provenance data model.
- [../../research/subsys/chat.md](../../research/subsys/chat.md) — Probe-verified subsystem study (roles, parsing, compilation, persistence).
