# Writing Chats

This page explains the Scout-AI chat-file format. It is intended for workflow
authors who want to write conversations by hand, inspect saved agent sessions,
or construct chat inputs for agents and workflows.

**You should read this if:** you want to write or read `.chat` files.

---

## The basic format

A chat file is plain text. Each message is a **role name** followed by a colon,
a blank line, then the content:

```text
system:

You are a helpful assistant.

user:

What is 2 + 2?

assistant:

4.
```

Rules:
- The role name is the first non-blank token on the line, followed by `:`.
- A blank line separates the role header from the content.
- Content continues until the next role header or end of file.

---

## Standard roles

| Role | Purpose | Content |
|------|---------|---------|
| `system` | System instructions | Text |
| `user` | User input | Text |
| `assistant` | Model response | Text |

These three are the core conversational roles. All others are processed and
consumed before inference — they configure the conversation but never appear
in what the model sees directly.

---

## Configuration roles

These roles set options, declare tools, and import content. They are processed
during chat compilation and removed from the final message list.

### Setting options

```text
option: model gpt-4o
option: temperature 0.7
```

Options apply to the next inference call. Some options are **sticky** — they
persist across turns:

```text
endpoint: anthropic
model: claude-sonnet-4-20250514
```

### Declaring tools

```text
tool: MyWorkflow task_name input1=value1 input2=value2
introduce: MyWorkflow
```

- `tool:` exposes a specific workflow task.
- `introduce:` exposes an entire workflow (all its tasks).

### Importing files

```text
file: path/to/document.txt
directory: path/to/folder
```

File contents are wrapped in `<file name="...">` tags and inserted as user
messages.

### Importing other chats

```text
import: other_chat.chat
```

This inlines the full content of another chat file.

### MCP tools

```text
mcp: https://api.example.com/mcp/
mcp: stdio my-mcp-command
```

---

## Tool call and result messages

When the model calls a tool, two messages are appended to the chat:

```text
function_call: {"name":"search","arguments":{"query":"ruby"},"id":"call_1"}
function_call_output: {"id":"call_1","content":"Search results..."}
```

These are normally auto-generated. You rarely write them by hand, but you will
see them in saved agent sessions.

---

## Comments

Lines starting with `#` are comments and are ignored:

```text
# This is a comment
system:

# So is this
You are a helpful assistant.
```

---

## Metadata and provenance

When Scout-AI saves a conversation (e.g., as a workflow job output), it
annotates it with metadata:

```text
meta: job=/path/to/job pt_c=1000 ct_c=500
```

This metadata records provenance — which job produced this chat, token counts,
and other bookkeeping. It is used by the provenance system to trace inference
trees.

---

## Complete example

Here is a realistic chat file that configures an endpoint, declares tools,
imports a file, and asks a question:

```text
# Configuration
endpoint: anthropic
model: claude-sonnet-4-20250514

# System prompt
system:

You are a code analyst. Use the provided tools to answer questions about
the codebase.

# Give the model a workflow as tools
introduce: CodeAnalyzer

# Import context
file: src/main.rb

# The question
user:

What design patterns are used in main.rb?
```

---

## Common mistakes

- **Forgetting the blank line** between the role header and content. Without
  it, the role header and content may merge.
- **Using unknown role names.** Only recognized roles are processed; unknown
  ones are treated as literal user messages.
- **Expecting configuration roles to appear in the model's prompt.** Roles
  like `tool:`, `option:`, `file:` are compiled away — they configure the
  conversation but do not become visible messages.

---

## Next steps

- [BuildingAgents.md](BuildingAgents.md) — create agents that use chats.
- [ToolCalling.md](ToolCalling.md) — detailed tool declaration syntax.
- [RunningInference.md](RunningInference.md) — endpoint and model configuration.
