# Chat

A Chat is Scout-AI's conversation format. It serves two purposes at once:

1. **An on-disk text format** (human-editable "chat files") where each message
   is written as `role:` followed by content.
2. **A Ruby builder** over an `Array` of `{role:, content:}` Hashes, annotated
   with a rich DSL.

A chat is not just prompts. Beyond `user`/`system`/`assistant`, Scout-AI
supports dozens of **control roles** that are interpreted by `LLM.chat`
*before* the model is queried: imports, file attachments, tool declarations,
job execution, options, and maintenance directives.

---

## The Chat data model

### A Chat IS an Array

The most important thing to understand: **a Chat is a plain `Array` of message
`Hash`es, not an opaque object.** The `Chat` module uses scout-essentials'
`Annotation` system to add DSL methods to an Array *without subclassing or
wrapping it*:

```ruby
module Chat
  extend Annotation
  # 40+ instance methods (user, system, ask, follow, etc.)
end
```

When you call `Chat.setup(array)`, the Array gains all of Chat's instance
methods while remaining an Array:

```ruby
chat = Chat.setup([])
chat.user("Hello")
chat.system("You are helpful")

chat.class            # => Array
chat.length           # => 2
chat.first[:role]     # => "user"
chat.first[:content]  # => "Hello"
chat.select { |m| m[:role] == 'system' }  # works — it's an Array
```

Consequences:

- **Serializable**: chats round-trip between text and Arrays via `Chat.parse` /
  `Chat.print`.
- **Composable**: `intro + coda` concatenates Arrays; `chat.follow(other)`
  appends.
- **Introspectable**: filter, map, select directly on the Array.
- **Cacheable**: `Persist.persist` hashes the message Array.

### Message hash schema

Every message is a `Hash` with two mandatory keys:

```ruby
{ role: String, content: String | Hash | Array | nil }
```

All message hashes are processed with `IndiferentHash.setup`, so keys work as
both symbols (`msg[:role]`) and strings (`msg["role"]`).

The `:content` field's type varies by role:

| Role category | Content type | Example |
|---|---|---|
| Conversational (`user`, `system`, `assistant`) | String | `"Hello"` |
| Tool calls (`function_call`, `function_call_output`) | JSON String | `'{"name":"...","arguments":{...}}'` |
| Options (`option`, `sticky_option`) | String `"key value"` | `"model gpt-5"` |
| Meta (`meta`) | String `"key=value key=value"` | `"job=/path pt_c=1000"` |
| Files (`file`, `import`) | String (path) | `"README.md"` |

---

## Message roles: the full reference

Roles are organized by category. The three **conversational roles** are sent to
the model; everything else is either expanded into conversational content,
extracted as side-channel data, or used for bookkeeping.

### Conversation roles

| Role | Semantics |
|---|---|
| `system` | System instructions, policy, persona |
| `user` | User input / prompts |
| `assistant` | Model responses. Also triggers option reset (see Options below). |

### Import and composition roles

Processed by `Chat.imports` during compilation. All resolve paths relative to
the current chat file, then via `Scout.chats`, then absolute.

| Role | Effect | Syntax |
|---|---|---|
| `import` | Inline **all** messages from the referenced chat file (recursively) | `import: other_chat` |
| `continue` | Import **only the last non-empty message** from the referenced file | `continue: previous_chat` |
| `last` | Import the last message **after purging** `previous_response_id` messages | `last: summary_chat` |

Example:

```text
import: scout-ai/test_stdio
continue: my_previous_chat
```

### File and resource roles

Processed by `Chat.files` during compilation.

| Role | Effect | Syntax |
|---|---|---|
| `file` | Reads the file, wraps content in `<file name="path">...</file>`, produces a `user:` message | `file: README.md` |
| `directory` | Recursively expands all files under the directory as individual `file:` messages | `directory: lib/scout/llm` |
| `image` | Resolves to a path (not inlined). Backend uploads as base64 when possible. | `image: test/data/cat.jpg` |
| `pdf` | Resolves to a path (not inlined). Backend uploads as base64 when possible. | `pdf: report.pdf` |

### Workflow and job roles

Processed by `Chat.tasks` and `Chat.jobs` during compilation.

| Role | Effect | Syntax |
|---|---|---|
| `introduce` | Injects workflow documentation as a `user:` message (helps the model understand available tools) | `introduce: Baking` |
| `tool` | Exposes workflow task(s) as callable tools. Optionally filter by task name and inputs. | `tool: Baking bake_muffin_tray blueberries=true` |
| `task` | Runs a workflow job before the model call; replaced with a `job:` marker | `task: Baking bake key=value` |
| `inline_task` | Runs a workflow job; replaced with an `inline_job:` marker (result inlined as a file) | `inline_task: Baking bake` |
| `exec_task` | Executes a job immediately; output inlined as a `user:` message | `exec_task: Baking bake` |
| `job` | References a completed Step; resolved into `function_call` + `function_call_output` | `job: <step_path>` |
| `inline_job` | References a Step; resolved into a `file:` message | `inline_job: <step_path>` |

Tool-call and tool-result messages are persisted using two special roles with
JSON content:

```ruby
# A tool call
{ role: 'function_call',
  content: '{"name":"bake_muffin_tray","arguments":{"blueberries":true},"id":"call_123"}' }

# The tool result
{ role: 'function_call_output',
  content: '{"id":"call_123","content":"...baking result..."}' }
```

### Knowledge base roles

| Role | Effect | Syntax |
|---|---|---|
| `association` | Registers a database from a file path as a KB tool | `association: brothers test/data/brothers undirected=true` |
| `kb` | Loads an existing KnowledgeBase directory and exposes its databases as tools | `kb: my_kb db1 db2` |

### MCP roles

| Role | Effect | Syntax |
|---|---|---|
| `mcp` | Connects to an MCP server (stdio or HTTP) and loads its tool definitions | `mcp: http://localhost:8765` |

Examples:

```text
mcp: http://localhost:8765
mcp: stdio 'npx -y @modelcontextprotocol/server-filesystem ${pwd}'
```

If you list tool names after the URL/command, only those tools are exposed.

### Option roles

Options are extracted by `Chat.options` during compilation. There are two
lifetimes: **sticky** (persist across turns) and **transient** (cleared after
each `assistant:` reply).

| Role | Lifetime | Effect |
|---|---|---|
| `endpoint` | Sticky | Named endpoint config (`~/.scout/etc/AI/<name>`) |
| `backend` | Sticky | Backend selector (`responses`, `openai`, `ollama`, `bedrock`, …) |
| `model` | Sticky | Model id for the backend |
| `agent` | Sticky | Agent name to load |
| `previous_response_id` | Sticky | Continue a Responses API session |
| `option` | **Transient** | Generic `key value` — cleared after `assistant:` reply |
| `sticky_option` | Sticky | Generic `key value` — persists across turns |
| `format` | **Transient** | Output format: `:json`, `json_object`, or a JSON schema hash / filename |
| `persist` | **Transient** | Cache control for `LLM.ask` |
| `config` | Consumed | Sets `Scout::Config` values at runtime; removed from chat |

#### `option:` vs `sticky_option:` behavior

This is a critical distinction:

```text
endpoint: nano
option: temperature 0.7

user: First question

assistant: First answer
```

After the `assistant:` message, `temperature 0.7` is **cleared** — it will not
apply to the next turn. The `endpoint: nano` remains because `endpoint` is
sticky.

If you want an option to persist across turns, use `sticky_option:`:

```text
endpoint: nano
sticky_option: temperature 0.7

user: First question

assistant: First answer

user: Second question
```

Here `temperature 0.7` applies to **both** turns.

> **Rule:** `option:` = one-shot (reset after assistant reply). `sticky_option:`
> = persists across all turns. The built-in roles `endpoint`, `model`,
> `backend`, `agent`, and `previous_response_id` are implicitly sticky.

### Maintenance roles

| Role | Effect |
|---|---|
| `clear` | Cut point: everything before the **last** `clear:` marker is discarded |
| `clear_tools` | Remove all previously declared tools (content `false` means don't clear) |
| `clear_associations` | Remove all previously declared associations |
| `skip` | Drop this message (equivalent to empty content) |
| `clean_role` / `clear_role` | Marks roles to be cleaned/removed during processing |

Example of `clear:` as a template cut point:

```text
system: Setup instructions for the template
clear:
user: Actual question
```

The `system:` message is discarded before the model sees the chat.

### Meta role

`meta:` messages are **internal bookkeeping** — they are never sent to the
provider. They carry key=value pairs as space-delimited strings:

```text
meta: job=/path/to/job pt_c=1000 ct_c=500 tt_c=2000
```

Key meta fields: `job` (workflow job path), `pt_c`/`ct_c`/`tt_c` (running token
count totals), `pt`/`ct`/`tt` (single-inference token counts).

See [Persistence.md](Persistence.md) and [Provenance/Provenance.md](../Provenance/Provenance.md)
for how meta enables provenance tracking.

---

## The `Chat` module and Annotation pattern

### `Chat.setup` — how annotation works

`Chat` is a module that calls `extend Annotation`. When you call
`Chat.setup(some_array)`:

1. The Array instance is extended with the `Chat` module.
2. All of Chat's instance methods (defined across `chat/annotation.rb`,
   `chat/process/meta.rb`, etc.) become callable on that Array.
3. The object's class remains `Array` — no subclassing, no wrapping.

```ruby
messages = [{ role: 'user', content: 'Hi' }]
Chat.setup(messages)         # messages is still an Array
messages.system("Be brief")  # annotated method
messages.ask                 # annotated method → calls LLM.ask
```

The annotation is **removable**: `Annotation.purge(obj)` strips it.

### The `LLM` module as factory

The top-level `LLM` module provides the entry points:

| Method | Purpose |
|---|---|
| `LLM.chat(file_or_messages)` | Parse → process → return annotated Chat |
| `LLM.messages(question, role)` | Convert string/Array into message hashes |
| `LLM.print(chat)` | Serialize a Chat back to text |
| `LLM.options(messages)` | Extract options (side-channel, mutates messages) |
| `LLM.tools(messages)` | Extract tool definitions (side-channel, mutates messages) |
| `LLM.associations(messages, kb)` | Extract KB associations (side-channel) |

---

## The Chat DSL methods

All methods below are available on any Array annotated via `Chat.setup`.
They are also available on `LLM::Agent` instances via `method_missing`
delegation to `current_chat`.

### Message building

```ruby
chat = Chat.setup([])

chat.user("Hello")              # append { role: 'user', content: 'Hello' }
chat.system("You are helpful")  # append { role: 'system', content: '...' }
chat.assistant("I can help")    # append { role: 'assistant', content: '...' }
chat.message(:custom, "data")   # append { role: :custom, content: 'data' }
```

### File and context attachment

```ruby
chat.file("README.md")           # append file: → resolved to <file> user message
chat.directory("lib/scout/llm")  # append directory: → expanded to file: messages
chat.image("test/data/cat.jpg")  # append image:
chat.pdf("report.pdf")           # append pdf:
```

### Imports and composition

```ruby
chat.import("other_chat")        # append import:
chat.continue("previous_chat")   # append continue:
chat.import_last("summary")      # append last:

chat.append(other_chat)          # append another chat's messages
chat.follow(other_chat)          # alias for append
chat.prepend(intro_chat)         # prepend messages
chat.branch                      # return a duplicate (annotated copy)
```

### Tool and workflow integration

```ruby
chat.introduce("Baking")                      # append introduce:
chat.tool("Baking", "bake_muffin_tray")       # append tool:
chat.task(Baking, :bake, blueberries: true)   # append task:
chat.exec_task(Baking, :bake)                 # append exec_task:
chat.inline_task(Baking, :bake)               # append inline_task:
chat.job(step)                                # append job:
chat.inline_job(step)                         # append inline_job:
chat.association("bros", "data/brothers")     # append association:
```

### Options

```ruby
chat.option(:temperature, 0.7)   # transient option
chat.endpoint(:nano)             # sticky
chat.model("gpt-5-nano")         # sticky
chat.format(:json)               # transient
```

### Inference

```ruby
# ask: call LLM.ask with this chat, return assistant content (string)
response = chat.ask(endpoint: :nano)

# chat: ask + append the response messages to this chat, return answer
answer = chat.chat(endpoint: :nano)

# json: ask with JSON format, parse and return the result
obj = chat.json(only_ask: true)

# json_format: ask with a specific JSON schema, return parsed object
obj = chat.json_format({
  name: 'answer', type: 'object',
  properties: { items: { type: 'array', items: { type: 'string' } } },
  required: ['items'], additionalProperties: false
})
```

`ask` vs `chat`:
- **`ask(options)`** → calls `LLM.ask(self, options)`, returns the assistant
  content string (or message trace with `return_messages: true`). Does **not**
  modify the chat.
- **`chat(options)`** → calls `ask` with `return_messages: true`, **appends**
  the resulting messages to the chat, returns the assistant content.

### Reporting and provenance

```ruby
chat.print          # serialize to text (Chat.print format)
chat.final          # last message after purge
chat.purge          # remove previous_response_id messages
chat.shed           # return a new chat with just the final message
chat.answer         # content of the final message

chat.save("my.chat")         # write full chat to file
chat.write("my.chat")        # write processed form
chat.write_answer("ans.txt") # write only the final answer

chat.meta           # parse last meta message → Hash
chat.add_meta(:job, path)    # add/update meta key-value
chat.message_index  # lineage IDs for all messages
```

---

## Chat compilation pipeline

When you call `LLM.ask(chat)` or `chat.ask`, Scout-AI first compiles the chat
via `LLM.chat`. The pipeline stages run in a specific order:

```
LLM.chat(file)
  │
  ├─ 1. Parse → Messages         (Chat.parse: text → [{role:, content:}, ...])
  ├─ 2. IndiferentHash           (IndiferentHash.setup on every message)
  ├─ 3. Imports                  (resolve import:/continue:/last: — recursive)
  ├─ 4. Clear                    (discard everything before last clear: marker)
  ├─ 5. Clean                    (drop empty messages and skip: roles)
  ├─ 6. Config                   (process config: → Scout::Config.set)
  ├─ 7. Tasks                    (run task:/inline_task:/exec_task: → job:/inline_job:)
  ├─ 8. Jobs                     (resolve job:/inline_job: → function_call pairs or file:)
  ├─ 9. Files                    (resolve file:/directory:/pdf:/image:/step:)
  │
  └─ Chat.setup(messages)        → annotated Array ready for the model
```

After compilation, the backend performs **side-channel extractions** (these
mutate the message array in place via `messages.replace`):

- **`Chat.options(messages)`** — extracts `option:`, `sticky_option:`,
  `endpoint:`, `model:`, etc. Returns merged options Hash.
- **`Chat.tools(messages)`** — extracts `tool:`, `introduce:`, `mcp:`, `kb:`,
  `clear_tools:`. Returns tool definitions Hash.
- **`Chat.associations(messages, kb)`** — extracts `association:` messages.

These control messages are **consumed** (removed from the chat) and their data
is returned separately. The model never sees them.

Finally, just before the API call, `Chat.prepare_prompt` applies **prompt
strategies** (e.g., `shorten_tools`) that may prune old tool-call messages.
These transformations are **ephemeral** — they modify what is sent to the model
but are NOT persisted to the chat file. See
[PromptStrategies.md](PromptStrategies.md) for details.

---

## How to write a chat file

### Minimal conversation

```text
system: You are a helpful assistant.

user: What is 2+2?

assistant: 4
```

### Block form vs inline form

**Block form** (multi-line content after `role:` with blank line):

```text
user:

This is a multi-line user message.
It continues until the next role header.
```

**Inline form** (content on the same line as `role:`):

```text
endpoint: nano
model: gpt-5-nano
```

Inline headers become their own messages and do not "switch" the role for
following lines — **except** `previous_response_id:`, which resets the next
block to `user:`.

### Protected blocks (to avoid accidental role-splitting)

The parser protects certain blocks from being interpreted as role headers:

- **Markdown code fences** (``` ``` ```): content between fences is preserved literally.
- **XML-style blocks**: if text contains `<tag>` ... `</tag>`, the block is protected.
- **`[[ ... ]]` blocks**: square-bracket-delimited protected regions (markers stripped).
- **Escaped headers**: `\user: this is literal` — the backslash prevents role parsing.
- **Command output**: `shell:-- ls {{{` ... `shell:-- ls }}}` → `<cmd_output cmd="ls">`.

### Example: files + tools + options

```text
endpoint: nano
model: gpt-5-nano

system:

You are a code reviewer. Be concise.

introduce: CodeReview
tool: CodeReview review

file: lib/scout/llm/chat.rb

user:

Review the chat processing pipeline for potential issues.
```

### Example: tool call trace in a persisted chat

```text
endpoint: nano
agent: Baking

user: Bake some muffins with blueberries.

function_call: {"name":"bake_muffin_tray","arguments":{"blueberries":true},"id":"call_123"}
function_call_output: {"id":"call_123","content":"Muffins baked."}

assistant: Your blueberry muffins are ready!

previous_response_id: resp_034e...

user: Now bake one without blueberries.
```

### Example: clear as a template cut point

```text
system: These are template setup instructions.
option: temperature 0.5
clear:
user: This is the actual question that reaches the model.
```

Everything before `clear:` (the `system:` and `option:` messages) is discarded
during compilation.

---

## Key properties

### Serializable

Chats round-trip between text and Arrays. `Chat.parse(text)` → Array;
`Chat.print(chat)` → text. The `.chat` file format is the same text format
that `Chat.parse` reads.

```ruby
text = File.read("hello.chat")
messages = Chat.parse(text)
# ... modify messages ...
File.write("hello.chat", Chat.print(messages))
```

### Composable

```ruby
intro = Chat.setup([])
intro.system("You are helpful.")

question = Chat.setup([])
question.user("What is 2+2?")

full = intro + question         # Array concatenation
Chat.setup(full)
puts full.ask(endpoint: :nano)
```

### Introspectable

```ruby
chat = LLM.chat("hello.chat")

# Filter by role
user_messages = chat.select { |m| m[:role] == 'user' }

# Extract all tool calls
tool_calls = chat.select { |m| m[:role] == 'function_call' }
                  .map { |m| JSON.parse(m[:content]) }

# Count tokens from meta
meta = chat.meta
puts "Total tokens: #{meta['tt_c']}" if meta
```

---

## Related docs

- [Overview.md](../Overview.md) — installation, architecture, philosophy
- [Chat/PromptStrategies.md](PromptStrategies.md) — `prepare_prompt`, `shorten_tools`, thresholds
- [Chat/Persistence.md](Persistence.md) — `.chat` file format, provenance annotations, caching
- [Agent/Agent.md](../Agent/Agent.md) — stateful agents (uses Chat via `method_missing`)
- [Tools/Tools.md](../Tools/Tools.md) — tool definition and calling protocol
- [Backends/Backends.md](../Backends/Backends.md) — backends and inference flow
- [Provenance/Provenance.md](../Provenance/Provenance.md) — provenance trees and token tracking
