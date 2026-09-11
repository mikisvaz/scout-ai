# Tool Calling

This page explains how to give Scout-AI agents and chats access to callable
tools. It is intended for workflow authors who want the LLM to query data,
run code, or interact with external systems during inference.

**You should read this if:** you want the model to do more than generate text.

---

## What tools are

Tools are functions the LLM can call during inference. When a tool is
available, the model sees its name, description, and parameter schema. If the
model decides to call the tool, Scout-AI executes it, appends the result to the
conversation, and re-sends the conversation so the model can use the result.

Chat files declare three kinds of tools:

| Kind | How to declare | What it provides |
|------|---------------|-----------------|
| **Workflow tools** | `tool:` in chat, or auto-wired from agent workflow | Typed tasks from a Scout Workflow |
| **Knowledge base tools** | `kb:` in chat | Database lookups |
| **MCP tools** | `mcp:` in chat | Any MCP-compatible external server |

`introduce:` is **not** a tool declaration: it injects the workflow's
documentation as a `user:` message and generates **zero** tool definitions
(deduplicated per workflow). Use it to explain a workflow to the model; use
`tool:` to give the model its tasks.

Internally every registered tool is a `{name => [executor, definition]}`
pair, and the executor is one of four kinds: a raw `Proc` (used by
agent-layer tools such as `ask`, `attach` and `hand_off_to_<name>`, and by MCP
client tools), a workflow module, a workflow name (`String`), or a
`KnowledgeBase`.

---

## Workflow tools

A Scout Workflow is a module of tasks with typed inputs and outputs. When you
expose a workflow as tools, each task becomes a callable function.

### Exposing an entire workflow

```text
tool: MyWorkflow
```

This generates one tool per exported task (or, when the workflow has no
exports, one tool per task). The model can call any of them, providing inputs
as arguments. Agents that have a workflow with tasks get this wiring
automatically.

### Introducing a workflow without tools

```text
introduce: MyWorkflow
```

Injects the workflow's title and description as a `user:` message. No tool is
created — pair it with `tool:` if the model also needs the tasks.

### Exposing a specific task

```text
tool: MyWorkflow my_task input1 input2=value1
```

This exposes only `my_task` from `MyWorkflow`. Two input forms exist:

- bare names (`input1`) restrict which inputs appear in the tool's schema;
- `name=value` tokens (`input2=value1`) pre-fill an input **and hide it from
  the model-visible schema**.

Pre-filled values are *definition defaults*, and defaults take precedence:
when the call is executed, the saved value is merged over whatever the model
sent for that argument, so the model cannot override it. Treat `name=value` as
a fixed parameter, not a suggestion.

### How it works

When the model calls a workflow tool:

1. Scout-AI runs the task as a workflow job.
2. The job goes through Scout's dependency resolution and caching.
3. The result is converted to text and returned as a tool output message.
4. The model sees the result and continues.

### Inline workflow definition

In Ruby, you can define a workflow inline on an agent:

```ruby
agent.workflow do
  task :search => :string do |query|
    # your search logic here
    "Results for: #{query}"
  end

  task :save => :string do |path, content|
    File.write(path, content)
    "Saved to #{path}"
  end
end
```

The model can now call `search` and `save` as tools.

---

## Knowledge base tools

If your agent or chat has a knowledge base, its databases become tools the
model can query.

```text
kb: my_kb genes proteins interactions
```

`my_kb` is a knowledge-base path or an agent name; the database names are
optional and select a subset.

One *association* tool is exposed per database, plus — only when the database
source has fields (a third column) — a details tool:

- `my_database(entities: [...])` — find related entities. Directed databases
  also take `reverse` to look up targets instead of sources; undirected ones
  take only `entities`.
- `my_database_association_details(associations: [...])` — return the fields
  of given `source~target` pairs, optionally restricted to a subset with
  `fields: [...]`. Exists only when the database has fields; a single-field
  database drops the `fields` argument.

### From an agent

```ruby
agent = LLM::Agent.new(knowledge_base: 'my_kb')
```

The KB's databases are automatically wired as tools.

---

## MCP tools

The Model Context Protocol (MCP) is an open standard for exposing tools to
LLMs. Scout-AI can connect to any MCP server.

### HTTP MCP server

```text
mcp: https://api.example.com/mcp/
```

### Stdio MCP server

```text
mcp: stdio my-mcp-command
```

### Selecting specific tools

```text
mcp: https://api.example.com/mcp/ search write_file
```

Only the named tools will be available. Note that with `mcp: stdio <command>`,
**every token after the command is a tool-name filter**, not an argument to the
command — `mcp: stdio echo x` runs `echo` and selects the tool named `x`.

---

## Tool calling in action

When a tool is called, the conversation grows with two messages:

```text
function_call: {"name":"search","arguments":{"query":"ruby blocks"},"id":"call_1"}
function_call_output: {"id":"call_1","name":"search","content":"Ruby blocks are..."}
```

The output envelope also carries `error`, `stack`, `meta`, `step`,
`start_timestamp` and `timestamp` when applicable, and oversized results are
replaced by a truncation notice that points at the persisted step.

The tool-calling loop is automatic. If the model calls multiple tools in one
turn, or calls a tool and then needs to call another, Scout-AI handles the
iteration until the model responds with plain text.

---

## Controlling tool behavior

### Forcing a tool call

`tool_choice` is passed through to the provider verbatim, so it takes the
provider's own spelling:

```ruby
agent.option :tool_choice, {type: 'function', function: {name: 'search'}}
```

It is dropped after the first tool round (each re-entry of the loop starts
from the model's own choice).

### Clearing tools

```text
clear_tools: true
```

---

## When to use tools vs. direct code

Tools are for things the **model** should decide to do. If you know you need a
piece of data before inference, put it in the chat as a file or user message.

- The model must **decide** whether to look something up.
- The model must **iterate** — call a tool, see results, call another.
- The operation is **expensive** and should only run when needed.
- You want the **provenance** of tool calls recorded in the chat history.

Otherwise prefer direct code: it is cheaper, deterministic, and cacheable.

---

## Common mistakes

- **Writing `introduce: MyWorkflow` and expecting tools**: `introduce:` injects
  documentation only. Use `tool: MyWorkflow` to generate tools.
- **Expecting a `name=value` pre-fill to be overridable**: pre-filled inputs
  are hidden from the model and their values win over model arguments.
- **Expecting two KB tools per database**: the `_association_details` tool only
  exists when the database source has fields.
- **Expecting tool results to be structured**: results are converted to text
  before being shown to the model. Use JSON format if you need structure.
- **Overloading the model with too many tools**: each tool adds to the context
  size. Expose only the workflows relevant to the task.

---

## See also

- [ManagingContext.md](ManagingContext.md) — what happens when tool calls
  accumulate and the context gets long.
- [../developer/Backends.md](../developer/Backends.md) — the inference loop
  that drives tool calls.
- [RunningInference.md](RunningInference.md) — endpoint and model configuration.
