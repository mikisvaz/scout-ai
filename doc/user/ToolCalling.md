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

Scout-AI supports three kinds of tools:

| Kind | How to declare | What it provides |
|------|---------------|-----------------|
| **Workflow tools** | `tool:` / `introduce:` in chat, or auto-wired from agent workflow | Typed tasks from a Scout Workflow |
| **Knowledge base tools** | `kb:` in chat | Database lookups |
| **MCP tools** | `mcp:` in chat | Any MCP-compatible external server |

---

## Workflow tools

A Scout Workflow is a module of tasks with typed inputs and outputs. When you
expose a workflow as tools, each task becomes a callable function.

### Exposing an entire workflow

```text
introduce: MyWorkflow
```

This auto-generates a tool definition for every task in the workflow. The model
can call any task, providing inputs as arguments.

### Exposing a specific task

```text
tool: MyWorkflow my_task input1=value1 input2=value2
```

This exposes only `my_task` from `MyWorkflow`, with some inputs pre-filled.

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
kb: my_database [genes proteins interactions]
```

This exposes two tools per database:
- `my_database(entities: [...])` — find related entities.
- `my_database_association_details(entities: [...])` — get association details.

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
mcp: stdio my-mcp-command arg1 arg2
```

### Selecting specific tools

```text
mcp: https://api.example.com/mcp/ [search write_file]
```

Only the named tools will be available.

---

## Tool calling in action

When a tool is called, the conversation grows with two messages:

```text
function_call: {"name":"search","arguments":{"query":"ruby blocks"},"id":"call_1"}
function_call_output: {"id":"call_1","content":"Ruby blocks are..."}
```

The tool-calling loop is automatic. If the model calls multiple tools in one
turn, or calls a tool and then needs to call another, Scout-AI handles the
iteration until the model responds with plain text.

---

## Controlling tool behavior

### Forcing a tool call

```ruby
agent.option :tool_choice, {type: 'function', function: {name: 'search'}}
```

### Clearing tools

```text
clear_tools: true
```

---

## When to use tools vs. direct code

Tools are for things the **model** should decide to do. If you know you need a
piece of data before inference, just put it in the chat as a file or user
message. Use tools when:

- The model needs to **decide** whether to look something up.
- The model needs to **iterate** — call a tool, see results, call another.
- The operation is **expensive** and should only run when needed.
- You want the **provenance** of tool calls recorded in the chat history.

---

## Common mistakes

- **Declaring tools but forgetting the workflow**: If you write
  `introduce: MyWorkflow` but the workflow is not on the agent's load path,
  the tools won't resolve.
- **Expecting tool results to be structured**: Tool results are always
  converted to text before being shown to the model. If you need structured
  data, use JSON format and tell the model to expect it.
- **Overloading the model with too many tools**: Each tool adds to the context
  size. Introduce only the workflows relevant to the task.

---

## Next steps

- [BuildingAgents.md](BuildingAgents.md) — how agents auto-wire tools.
- [RunningInference.md](RunningInference.md) — endpoint and model configuration.
- [ManagingContext.md](ManagingContext.md) — what happens when tool calls
  accumulate and the context gets long.
