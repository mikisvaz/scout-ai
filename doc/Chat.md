# Chat

`Chat` is Scout-AI’s conversation format.

It serves two related purposes:

1) **An on-disk “chat file” format** (human editable) where each message is written as:

```text
role:

...content...
```

2) **A Ruby builder** over an `Array` of `{role:, content:}` hashes.

The important nuance: a chat is not just prompts. In addition to `user/system/assistant`, Scout-AI supports “control” roles that are interpreted by `LLM.chat` **before** the model is queried:

- imports (`import`, `continue`, `last`)
- files (`file`, `directory`, `image`, `pdf`)
- workflow integration (`tool`, `task`, `inline_task`, `job`, `inline_job`)
- knowledge base integration (`association`, `kb`)
- MCP tool integration (`mcp`)
- options (`endpoint`, `backend`, `model`, `format`, `persist`, `previous_response_id`, `option`, `sticky_option`)
- conversation maintenance (`clear`, `skip`, `clear_tools`, `clear_associations`)

This document is the reference for **all chat roles and options**, and how they behave.

Related docs:

- `doc/LLM.md` — how `LLM.ask` expands/executes chats and calls backends
- `doc/Agent.md` — stateful agents and programmatic control loops

---

## 1. Data model

A chat is an array of messages.

Each message is a Hash:

```ruby
{ role: "user", content: "Hello" }
```

Roles are strings (symbols are accepted but are stringified).

In Ruby, `Chat.setup(array)` annotates an array so it gains the builder methods (`user`, `system`, `file`, …).

```ruby
chat = Chat.setup([])
chat.system "You are a helpful assistant"
chat.user "Say hi"
puts chat.ask
```

---

## 2. Chat file syntax (parser rules)

Chat files are parsed by `Chat.parse`.

### 2.1 Role headers

A **role header** is any line matching:

```text
^[a-z0-9_]+:.*$
```

Examples:

```text
user:
assistant:
endpoint: nano
previous_response_id: resp_123
```

There are two forms:

1) **Block form**:

```text
user:

This is a multi-line user message.
It continues until the next role header.
```

2) **Inline form** (single line):

```text
endpoint: nano
model: gpt-5-nano
```

Inline headers become their own messages and do not “switch” the role for the following lines (except `previous_response_id`, see below).

### 2.2 Special parser protections (to avoid accidental role-splitting)

The parser tries hard to avoid splitting a message when content contains colons.

Protected regions:

- **Markdown code fences**: content between triple backticks is kept in the same message even if it contains `something:` lines.
- **XML-style blocks**: if the text contains `<tag ...>` and later `</tag>`, the whole block is treated as protected.
- **Square-bracket protection**: `[[ ... ]]` protects multi-line content that may include role-looking headers.
  - The `[[` and `]]` markers are stripped.
- **Command output shorthand**: lines like:
  - `shell:-- ls {{{` become `<cmd_output cmd="ls">`
  - `shell:-- ls }}}` become `</cmd_output>`

### 2.3 `previous_response_id` nuance

`previous_response_id: ...` is special: after an inline `previous_response_id`, the parser resets the next block back to `user`.

This makes it convenient to append a new user question *after* a response id marker.

---

## 3. Expansion pipeline: what `LLM.chat` does to a chat

When you call `LLM.ask(chat)` or `chat.ask`, Scout-AI first expands the chat via `LLM.chat`.

Expansion order (important):

1) **Imports** (`import`, `continue`, `last`)
2) **Clear** (`clear`)
3) **Clean** (drops empty messages and `skip`)
4) **Tasks** (`task`, `inline_task`, `exec_task` → jobs)
5) **Jobs** (`job`, `inline_job` → function_call/function_call_output or file)
6) **Files** (`file`, `directory`, `image`, `pdf`)

After this, backends may do another pass to extract tool definitions.

---

## 4. Role reference (chat file / Chat DSL)

### 4.1 Standard conversational roles

| Role | Meaning |
|---|---|
| `system` | System instructions / policy / persona |
| `user` | User message |
| `assistant` | Assistant message (usually produced by the model) |

### 4.2 Imports and composition

Imports are processed by `Chat.imports` during `LLM.chat`.

| Role | Effect | Notes |
|---|---|---|
| `import` | Inline the referenced chat file(s) | Imports **all** messages from the imported file, except `previous_response_id` |
| `continue` | Import **only the last non-empty message** from the referenced file | Useful to “continue from the last user/assistant turn” |
| `last` | Import **only the last non-empty message**, after removing `previous_response_id` | Often used to grab the last assistant answer |

Resolution rules for imported paths:

- absolute paths work
- relative paths are resolved relative to the current chat file
- names may resolve via `Scout.chats[...]`

Example:

```text
import: scout-ai/test_stdio
continue: my_previous_chat
last: summary_chat
```

### 4.3 Files and directories

Files are processed by `Chat.files` during `LLM.chat`.

| Role | Effect |
|---|---|
| `file` | Reads the file and inserts it as a tagged `<file name="...">...</file>` inside a `user` message |
| `directory` | Expands to many `file` insertions for all files under the directory (recursive) |
| `image` | Resolves to a path (not inlined). Responses backend will upload as base64 when possible |
| `pdf` | Resolves to a path (not inlined). Responses backend will upload as base64 when possible |

Example:

```text
user:

Please review these files.

directory: lib/scout/llm
file: README.md
image: test/data/cat.jpg
```

### 4.4 Workflow tools (function calling)

There are two related mechanisms:

1) **Expose tools** (so the model can call them)
2) **Run tasks/jobs ahead of time** (so their outputs are available as context)

#### `tool` — expose workflow tasks as callable tools

`tool: <WorkflowName> [<task_name> [<input1> <input2> ...]]`

- If you provide only the workflow name, all exported tasks are available as tools.
- If you provide a task name, only that task is exposed.
- If you provide input names, only those inputs are exposed in the JSON schema.
- You can also provide defaults with `input=value`.

Examples:

```text
tool: Baking
tool: Baking bake_muffin_tray
tool: Baking bake_muffin_tray blueberries=true
tool: Baking bake_muffin_tray blueberries
```

#### `introduce` — inject workflow documentation into the chat

`introduce: <WorkflowName>` expands into a `user` message containing the workflow documentation (`workflow.documentation`).

This is useful when you want the LLM to “understand what the tools do”, not just have access to them.

Example:

```text
introduce: Baking
tool: Baking
```

#### `task`, `inline_task`, `exec_task` — run a workflow job during compilation

`task:` lines are executed **before** the model call.

Syntax:

```text
task: <WorkflowName> <task_name> key=value key2=value2
inline_task: <WorkflowName> <task_name> key=value
exec_task: <WorkflowName> <task_name> key=value
```

Behavior:

- `task` → runs the workflow job and replaces itself with a `job:` marker.
- `inline_task` → runs the workflow job and replaces itself with an `inline_job:` marker.
- `exec_task` → executes the job immediately and inlines its output into a `user` message.

#### `job` / `inline_job` — include a precomputed Step result

If you already have a job path (a `Step`), you can embed it:

- `inline_job` becomes `file:` (the result is inlined as `<file>`)
- `job` becomes a pair of messages:
  - `function_call` with `{name, arguments, id}`
  - `function_call_output` with `{id, content}`

This is how saved chats can preserve tool-call traces.

### 4.5 Knowledge base tools

Two ways:

#### `association` — register a database from a file path

`association: <name> <path> [options...]`

Example:

```text
system:

Query the knowledge base to answer.

association: brothers test/data/person/brothers undirected=true
association: marriages test/data/person/marriages undirected=true source="=>Alias" target="=>Alias"
```

This dynamically registers the database inside a temporary `KnowledgeBase` and exports tools for it.

If a database has fields, an extra tool `<db>_association_details` is also exposed.

#### `kb` — load an existing KnowledgeBase directory

`kb: <knowledge_base_name_or_path> [db1 db2 ...]`

This loads a KB via `KnowledgeBase.load` and exposes tools for all (or selected) databases.

### 4.6 MCP tools

`mcp: <url_or_stdio> [tool1 tool2 ...]`

This loads tool definitions from an MCP server and makes them available as tools.

Examples:

```text
mcp: http://localhost:8765
mcp: stdio 'npx -y @modelcontextprotocol/server-filesystem ${pwd}'
```

If you list tool names after the URL, only those tools are exposed.

### 4.7 Options and session control

Options are extracted by `Chat.options` and merged into `LLM.ask` options.

There are two categories:

- **Sticky options**: persist across turns (until overridden)
- **Transient options**: cleared after an `assistant` message

#### Sticky options

| Role | Meaning |
|---|---|
| `endpoint` | Named endpoint configuration (merged from `~/.scout/etc/AI/<endpoint>`) |
| `backend` | Backend selector (`responses`, `openai`, `ollama`, `bedrock`, …) |
| `model` | Model id for the backend |
| `agent` | Agent name to load (see doc/Agent.md) |
| `previous_response_id` | Continue a Responses API conversation session |

#### Transient options

| Role | Meaning |
|---|---|
| `format` | Output format: `:json`, `json_object`, or a JSON schema hash |
| `persist` | Cache control for `LLM.ask` (see `doc/LLM.md`) |
| `option` | Generic `key value` (cleared after assistant) |
| `sticky_option` | Generic `key value` (persists across assistant turns) |

Examples:

```text
endpoint: nano
model: gpt-5-nano
format: json

option: websearch true
sticky_option: endpoint anthropic
previous_response_id: resp_034e...
```

#### `websearch` (Responses backend)

If a message with role `websearch` is present, or if you pass option `websearch: true`, the Responses backend will include the `web_search_preview` tool.

Example:

```text
endpoint: deep
websearch: true

user:

Find current information about ...
```

### 4.8 Maintenance roles

| Role | Meaning |
|---|---|
| `clear` | Drop all messages *before* the last `clear:` marker |
| `skip` | Drop this message |
| `clear_tools` | Remove all previously declared tools (in this compilation) |
| `clear_associations` | Remove all previously declared associations (in this compilation) |

---

## 5. Running a chat (Ruby)

### 5.1 `ask` vs `chat`

- `chat.ask(...)` → returns assistant output (string)
- `chat.chat(...)` → asks with `return_messages: true` and appends the resulting message trace to the chat

### 5.2 JSON helpers

```ruby
chat.format :json
obj = chat.json
```

Or with a schema:

```ruby
obj = chat.json_format({
  name: 'answer',
  type: 'object',
  properties: {content: {type: 'array', items: {type: 'string'}}},
  required: ['content'],
  additionalProperties: false,
})
```

---

## 6. Using chat files from the CLI

Chat files are primarily used via:

```bash
scout-ai llm ask --chat my.chat "your question"
```

Behavior:

- the file is parsed into messages
- the model is called
- the assistant reply (and tool call trace when present) is appended back to the file

You can keep typing into the file in an editor and re-run the command.

---

## 7. Example chat file (with tools + previous_response_id)

```text
user:

endpoint: nano
agent: Baking

bake some muffins using bake_muffin_tray, use blueberries

function_call: {"name":"bake_muffin_tray","arguments":{"blueberries":true},"id":"call_123"}
function_call_output: {"name":"bake_muffin_tray","content":"...","id":"call_123"}

assistant:

Blueberry muffins are in the oven.

previous_response_id: resp_034e...

Can you also bake one without blueberries?
```

Notes:

- `endpoint:` and `agent:` are parsed as their own messages even when written inside a `user:` block.
- `function_call` / `function_call_output` are how tool traces are persisted in chat logs.
- `previous_response_id` enables session continuation for the Responses backend.

---

## 8. Summary

Use `Chat` when you want:

- a reproducible, append-only conversation artifact on disk
- a safe way to inline files/directories
- a declarative way to expose workflow/KB/MCP tools
- a convenient place to store endpoint/model/options per conversation

The key to using chat files effectively is understanding the “control roles” above and the compilation order.
