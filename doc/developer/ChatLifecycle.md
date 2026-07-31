# Chat Lifecycle

This document describes how the `Chat` abstraction works internally: its data
model, the Annotation pattern that gives it a DSL, and the compilation
pipeline that transforms chat-file text into inference-ready message arrays.
It is intended for framework contributors.

> For the user-facing chat-file format guide, see
> [../user/WritingChats.md](../user/WritingChats.md).
> For deep code investigation, see
> [../../research/chat-core-analysis.md](../../research/chat-core-analysis.md).

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
| `function_call_output` | Tool execution result | Yes (as provider-specific tool result) |
| `meta` | Provenance metadata (tokens, job references) | **No** — stripped before inference |
| `tool` | Tool definition (inline in chat) | No — extracted into tool registry |
| `introduce` | Workflow/tool introduction | No — extracted, introduces tools to the model context |
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
1. Parse          — Chat.parse: text → Array<Hash>
  │                 (handles role: directives, block form, indented content)
  ▼
2. Extract options — options: directives extracted into options hash
  │                 (model:, endpoint:, backend:, etc.)
  ▼
3. Extract tools   — tool:/introduce:/mcp:/kb: roles extracted
  │                 into a tool registry hash
  ▼
4. Extract clear   — clear: directives processed
  │                 (removes tool outputs from history)
  ▼
5. prepare_prompt  — context strategies applied (shorten_tools)
  │                 EPHEMERAL: operates on a copy, never mutates stored chat
  ▼
6. format_messages — Backend translates into provider-specific format
  │
  ▼
API call
```

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

The format is human-readable and diffable, making it ideal for version control
and inspection.

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/chat.rb` | Chat module definition, `setup`, `parse` |
| `lib/scout/llm/chat/annotation.rb` | DSL methods (user, system, ask, follow, etc.) |
| `lib/scout/llm/chat/parse.rb` | Text → Array<Hash> parser |
| `lib/scout/llm/chat/process/options.rb` | Option extraction |
| `lib/scout/llm/chat/process/tools.rb` | Tool/introduce/mcp/kb extraction |
| `lib/scout/llm/chat/process/clear.rb` | Clear directive processing |
| `lib/scout/llm/chat/process/meta.rb` | Meta messages, provenance, message_index |
| `lib/scout/llm/chat/prompt.rb` | Prompt strategies (prepare_prompt, shorten_tools) |
| `lib/scout/llm/chat/persist.rb` | .chat file load/save |

---

## Cross-references

- [../user/WritingChats.md](../user/WritingChats.md) — Chat-file format from the user perspective.
- [PromptProcessing.md](PromptProcessing.md) — Context management internals.
- [Provenance.md](Provenance.md) — Provenance data model.
- [../../research/chat-core-analysis.md](../../research/chat-core-analysis.md) — Deep investigation.
