# Writing Chats

This page explains the Scout-AI chat-file format. It is intended for workflow
authors who want to write conversations by hand, inspect saved agent sessions,
or construct chat inputs for agents and workflows.

**You should read this if:** you want to write or read `.chat` files.

---

## The basic format

A chat file is plain text. Each message is a **role name** followed by a
colon, then the content (a blank line in between is the convention, not a
parser requirement):

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
- A blank line separates the role header from the content (a readability
  convention; the parser does not require it).
- Content continues until the next role header or end of file.
- There is **no comment syntax**: a `#` line is message content.
- A line matching a role header can be escaped with a leading backslash
  (`\user: literal text`); the backslash is dropped and the rest is kept
  as literal content.

Some blocks are protected from role-header parsing, so a line inside them
that happens to look like `something: text` stays content:

- triple-backtick code fences;
- `[[ ... ]]` bracket blocks;
- an XML-ish tag opened as `<tag ...>` with a matching closing tag;
- command-output markers, written `name:-- command {{{` … `name:-- command }}}`
  and normalized to `<cmd_output cmd="command">` … `</cmd_output>`.

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

The full option-related set, and how each behaves:

| Role | Sticky? | Notes |
|---|---|---|
| `option` | no | cleared by the next `assistant` reply |
| `sticky_option` | yes | survives assistant replies |
| `endpoint`, `model`, `backend`, `agent` | yes | removed from the chat once read |
| `previous_response_id` | yes | kept in the chat (it is also the Responses-API continuation record) |
| `persist` | no | ordinary option: cleared by the next `assistant` reply |
| `format` | no | a JSON-schema response format; a value that is an existing filename is loaded and its JSON used |

### Declaring tools

```text
tool: MyWorkflow
tool: MyWorkflow task_name input1=value1 input2=value2
introduce: MyWorkflow
```

- `tool: MyWorkflow` exposes the whole workflow (its exports, or all its
  tasks if it has none exported).
- `tool: MyWorkflow task_name ...` exposes one task; `name=value` tokens
  pre-fill and hide that input.
- `introduce:` injects the workflow's documentation only; it generates no
  tools. Combine it with `tool:` when you want both.

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
imports a file, and asks a question. There is **no comment syntax**: a
line starting with `#` is parsed as a user message.

```text
endpoint: anthropic
model: claude-sonnet-4-20250514

system:

You are a code analyst. Use the provided tools to answer questions about
the codebase.

introduce: CodeAnalyzer
tool: CodeAnalyzer

file: src/main.rb

user:

What design patterns are used in main.rb?
```

---

## Common mistakes

- **Using `#` as a comment marker.** There is no comment syntax; a `#` line
  is a user message and will be sent to the model.
- **Forgetting the blank line** between the role header and content. This is
  the established convention in Scout-AI's own files; keep it for
  readability, but the parser does not require it.
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
