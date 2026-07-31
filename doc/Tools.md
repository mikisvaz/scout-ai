# Tools

**Tools** are callable functions that an LLM can invoke during inference. In
Scout-AI they are the bridge between the model and your Ruby world: a Scout
`Workflow`, a `KnowledgeBase`, an MCP server, or a raw Ruby `Proc` can all be
exposed as tools the model can call mid-conversation.

This document is the system-level reference. For specialized topics see:

- [WorkflowTools.md](WorkflowTools.md) — exposing Scout workflows as tools
- [KnowledgeBase.md](KnowledgeBase.md) — KB databases and RAG
- [MCP.md](MCP.md) — Model Context Protocol client and server
- [../Agent/Agent.md](../Agent/Agent.md) — how Agents auto-wire workflow/KB tools
- [../Chat/Chat.md](../Chat/Chat.md) — chat-file roles (`tool:`, `mcp:`, `kb:`, …)
- [../Backends/Backends.md](../Backends/Backends.md) — the inference loop and `chain_tools`

---

## 1. What tools are

A tool is a function the model can call during a conversation. The model emits
a structured **tool call** (with a name and arguments), Scout-AI executes the
corresponding handler in Ruby, and the result is fed back to the model so it
can continue.

Conceptually:

```
user message
    │
    ▼
model turn 1 ─── tool_call(name="search", args={q:"..."}) ──┐
    │                                                       │
    │              ┌────────────────────────────────────────┘
    │              ▼
    │       process_calls → handler.call(...) → result
    │              │
    │              ▼
    │       function_call_output(result)
    │              │
    ▼              ▼
model turn 2 ─── (sees the result, continues)
    │
    ▼
final answer
```

This loop can repeat. Scout-AI implements it via `chain_tools` (see
[../Backends/Backends.md](../Backends/Backends.md#the-chain_tools-loop)).

---

## 2. Tool definition format

### 2.1 The `{ name => [executor, definition] }` registry

Every tool source — Proc, workflow, KB, MCP — produces the same hash shape:

```ruby
{
  "search" => [ executor_object, definition_hash ]
}
```

| Slot | Meaning |
|---|---|
| `[0]` executor | The object that knows *how* to run the tool: `Proc`, `Workflow`, `KnowledgeBase`, `String` (workflow name), or `nil` (fall back to a block). |
| `[1]` definition | A JSON-schema-flavoured hash describing the tool for the LLM. |

When the executor slot itself is a `Hash` (e.g. a nested function schema),
`process_calls` treats that hash as the definition. This keeps the dispatcher
uniform across all tool sources.

### 2.2 The definition hash

```ruby
{
  name:        "my_tool",
  description: "What this tool does",
  parameters:  {
    type:       "object",
    properties: {
      query:    { type: "string", description: "..." },
      options:  { type: "array",  items: { type: "string" },
                  enum: ["x","y"], description: "..." }
    },
    required: ["query"],
    defaults:  { options: ["x"] }   # Scout-only; stripped before sending
  }
}
```

Key points:

- `parameters` follows **JSON Schema** (`type: "object"`, `properties`,
  `required`).
- `defaults` is a Scout extension. It is **stripped** by
  `format_tool_definitions` before the definition reaches the model, and is
  re-applied by `process_calls` when executing the call.
- Some code paths store the definition nested under a `:function` key
  (`{ type: 'function', function: { ... } }`). Each backend's
  `format_tool_definitions` normalises both shapes.

---

## 3. The calling protocol

### 3.1 Full trace

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Backend.ask(messages, options)                             │
│                                                              │
│ 2. tools = self.tools(messages, options)                     │
│      ├─ options[:tools]            (explicit)                │
│      ├─ Chat.tools(messages)       (tool/mcp/kb roles)       │
│      └─ Chat.associations(messages) (association roles)      │
│                                                              │
│ 3. format_tool_definitions() → provider-specific schema      │
│                                                              │
│ 4. query(client, messages, tools, options)                   │
│      → model returns response with tool_calls               │
│                                                              │
│ 5. process_response(messages, response, tools, options)      │
│      ├─ parse_tool_call()           (per backend)            │
│      └─ LLM.process_calls(tools, tool_calls) &block          │
│                                                              │
│ 6. chain_tools()                                              │
│      if last message is function_call_output → re-ask        │
│      else → terminate                                         │
└──────────────────────────────────────────────────────────────┘
```

See [../Backends/Backends.md](../Backends/Backends.md) for how `chain_tools`
recurses until the model stops calling tools.

### 3.2 `LLM.process_calls` — the dispatcher

`LLM.process_calls(tools, calls, &block)` is the core dispatcher in
`lib/scout/llm/tools/call.rb`. For each tool call:

1. Extract `id`, `name`, `arguments` via `LLM.call_id_name_and_arguments`.
2. Look up `executor, definition = tools[name]`.
3. Merge `definition[:parameters][:defaults]` into the arguments.
4. Dispatch on executor type:

   | Executor | Dispatch |
   |---|---|
   | `Proc` | `executor.call(name, arguments)` |
   | `String` | resolve workflow by name, then `call_workflow` |
   | `Workflow` | `LLM.call_workflow(workflow, name, arguments)` |
   | `KnowledgeBase` | `LLM.call_knowledge_base(kb, name, arguments)` |
   | `nil` / other | `block.call(name, arguments)` if a block was given |

5. Process the return value:

   | Return | Handling |
   |---|---|
   | `Step` (job) | Batched via `Workflow.produce(jobs)`, result loaded |
   | `LLM::Agent` | Chatted in parallel via `Open.traverse` (see Delegation) |
   | `IO` / `TSV::Dumper` | Read to string |
   | `nil` | Becomes `"success"` |
   | `Exception` | Serialised as `{ exception:, stack: }.to_json` |
   | Other | `to_json` if possible, else `to_s` |

6. Build output message pairs:
   ```ruby
   [
     { role: "function_call",       content: tool_call.to_json },
     { role: "function_call_output", content: { name:, content:, id: }.to_json }
   ]
   ```

### 3.3 Output limits (`max_content_length`)

Tool outputs are capped to protect the context window. If the result string
exceeds `LLM.max_content_length` (default **100 000** chars, configurable via
`Scout::Config.get(:max_content_length, :llm_tools, :tools, :llm, :ask, default: 100_000)`),
it is replaced with a JSON error containing a `Log.fingerprint` (a compact
summary) and, when a `Step` was involved, the persisted file path so the model
knows where the full result lives.

### 3.4 Legacy block-based path

`LLM.call_tools(tool_calls, &block)` / `LLM.tool_response(tool_call, &block)`
provide a simpler, block-only variant used by the Bedrock backend. Each
tool_call is dispatched through the block, and the output is wrapped as a
`tool`-role message.

### 3.5 Shell-command-as-tool (`LLM.run_tools`)

Messages with `role: 'cmd'` are executed as shell commands via
`LLM.run_tools`. The command output is wrapped as a `tool`-role message. This
is a lightweight "shell-as-tool" mechanism separate from function calling.

---

## 4. The four kinds of tools

### 4.1 Bare tools (Proc)

The most flexible: any Ruby callable wrapped in a `Proc`. You own the schema
and the handler.

```ruby
search_tool = lambda do |name, args|
  # `name` is the tool name, `args` is a Hash of parsed arguments
  results = MySearcher.query(args["query"])
  results.to_json
end

tools = {
  "search" => [
    search_tool,
    {
      name: "search",
      description: "Search the web",
      parameters: {
        type: "object",
        properties: { query: { type: "string", description: "Search query" } },
        required: ["query"]
      }
    }
  ]
}

LLM.ask("Find recent papers on RAG", tools: tools, endpoint: :nano)
```

### 4.2 Workflow tools

A Scout `Workflow` module is introspected and each task becomes a callable
tool. The parameter schema is **derived from the task's input declarations**,
so you get typed, validated tools for free.

```ruby
module Baking
  extend Workflow
  task :bake_muffin_tray => :text do |flavor = "blueberry", count = 6|
    "Baking a #{count}-count #{flavor} muffin tray..."
  end
end

tools = LLM.workflow_tools(Baking)
LLM.ask("Bake a chocolate muffin tray", tools: tools, endpoint: :nano)
```

Type mapping from Scout inputs to JSON Schema:

| Scout input type | JSON Schema type |
|---|---|
| `:text`, `:path` | `:string` |
| `:chat` | `:text` |
| `:select` | `:string` (+ `enum` from `select_options`) |
| `:float`, `:integer` | `:number` / `:integer` |
| `*_array` | `:array` |

For non-exec tasks, a boolean `return_path` parameter is injected; when the
model sets it to `true`, the tool returns the persisted file path instead of
the result content.

See [WorkflowTools.md](WorkflowTools.md) for the full mapping, the `inputs`
filter, `call_workflow` dispatch rules, and the recursion guard.

### 4.3 KnowledgeBase tools

Each database in a `KnowledgeBase` produces up to two tools:

- `<database_name>(entities:, reverse:)` — find associations
  (`source~target` format). Undirected databases omit `reverse`.
- `<database_name>_association_details(associations:, fields:)` — retrieve
  field values for a list of associations. Only generated when the database
  has fields.

```ruby
kb = KnowledgeBase.load('/path/to/kb')
tools = LLM.knowledge_base_tool_definition(kb)
LLM.ask("Who are John's brothers?", tools: tools, endpoint: :nano)
```

This is the retrieval mechanism behind Scout-AI's RAG pipeline. See
[KnowledgeBase.md](KnowledgeBase.md) for the full schema and the `call_knowledge_base`
dispatch.

### 4.4 MCP tools

Tools served by a **Model Context Protocol** server (HTTP or stdio) can be
attached. `LLM.mcp_tools(url, options)` connects to the server, lists its
tools, and returns the same `{ name => [executor, definition] }` registry.

```ruby
tools = LLM.mcp_tools("https://api.example.com/mcp/")
LLM.ask("Use the external tools", tools: tools, endpoint: :nano)
```

Conversely, any Scout workflow can be exposed as an MCP server via
`Workflow#mcp` / `Workflow#mcp_stdio`. See [MCP.md](MCP.md) for both
directions.

---

## 5. How tools are attached

Tools are gathered from three channels, all merged into a single registry:

```ruby
def tools(messages, options)
  tools = options.delete :tools        # 1. explicit option
  tools = normalize(tools)             #    (Array → Hash keyed by name)
  tools.merge!(LLM.tools messages)     # 2. chat roles: tool/mcp/kb/introduce
  tools.merge!(LLM.associations messages) # 3. association roles
  tools
end
```

### 5.1 Via agent options

```ruby
agent = LLM.agent(tools: { "search" => [proc, def] }, endpoint: :nano)
```

Agents also auto-export their `workflow` and `knowledge_base` as tools (see
[../Agent/Agent.md](../Agent/Agent.md#tool-wiring)).

### 5.2 Via `LLM.ask` options

```ruby
LLM.ask("...", tools: { "search" => [proc, def] }, endpoint: :nano)
```

### 5.3 Via chat-file roles

The chat-file parser turns certain roles into tool-registration messages,
which `Chat.tools` consumes:

| Role | Purpose |
|---|---|
| `tool:` | Register one or more workflow tasks as tools |
| `introduce:` | Inject workflow documentation + register all its tasks |
| `task:` | Run a workflow task inline and include its result |
| `kb:` | Load a knowledge base and expose its databases as tools |
| `association:` | Register a TSV file as an ad-hoc KB database |
| `mcp:` | Connect to an MCP server and expose its tools |
| `clear_tools:` | Remove all tool definitions |
| `clear_associations:` | Remove all association definitions |
| `cmd:` | Execute a shell command (run_tools) |

These roles are processed by `Chat.tools()` and `Chat.associations()`, which
mutate the message array (consuming/removing tool-registration messages) and
return the accumulated tool registry.

### 5.4 Declaring tools in a chat file

```text
introduce: Baking

user:

Bake a chocolate muffin tray using the tool.
```

Or registering a single task:

```text
tool: Baking bake_muffin_tray

user:

Bake muffins using the tool.
```

Connecting to an MCP server:

```text
mcp: https://api.example.com/mcp/ search summarize

user:

Summarize the latest paper.
```

Registering an ad-hoc association:

```text
association: brothers test/data/person/brothers undirected=true

user:

Who is John's brother?
```

---

## 6. How tools are declared in code

### 6.1 Inline hash

```ruby
tools = {
  "echo" => [
    lambda { |name, args| args["text"] },
    {
      name: "echo",
      description: "Echo back the input text",
      parameters: {
        type: "object",
        properties: { text: { type: "string" } },
        required: ["text"]
      }
    }
  ]
}

LLM.ask("Echo 'hello'", tools: tools, endpoint: :nano)
```

### 6.2 Workflow-as-tool

```ruby
tools = LLM.workflow_tools(Baking)
tools = LLM.workflow_tools(Baking, [:bake_muffin_tray])   # subset of tasks
tools = LLM.workflow_tools([Baking, Search])              # multiple workflows
```

### 6.3 KB-as-tool

```ruby
tools = LLM.knowledge_base_tool_definition(kb)
```

### 6.4 MCP-as-tool

```ruby
tools = LLM.mcp_tools("https://api.example.com/mcp/")
tools = LLM.mcp_tools("stdio", command: "my-mcp-server")
```

### 6.5 Convenience wrappers

```ruby
LLM.workflow_ask(Baking, "Bake muffins", endpoint: :nano)
LLM.knowledge_base_ask(kb, "Who is X's brother?", endpoint: :nano)
```

These convenience methods build the tools for you and call `LLM.ask`.

---

## 7. Key design patterns

### 7.1 Unified registry shape

The single most important pattern: **every tool source produces the same
`{ name => [executor, definition] }` hash**. `process_calls` has one dispatch
path that handles all tool types by inspecting the executor.

### 7.2 Deferred Step production

When a workflow tool returns a `Step` (a job), it is not run immediately. All
Steps from a single model turn are collected and batch-produced via
`Workflow.produce(jobs)`, potentially in parallel. Results are then loaded.
This lets the model call multiple workflow tools in one turn and have them
execute concurrently.

### 7.3 Recursion guard

`LLM.call_workflow` raises a `ScoutException` if a job is already running with
the current PID (`job.running? && job.info[:pid] == Process.pid`). This
prevents an agent from calling a workflow task that itself triggers another
agent call into infinite recursion. The guard can be bypassed explicitly with
`allow_recursive: 'true'`.

### 7.4 Content truncation as a safety pattern

The `max_content_length` guard prevents huge tool outputs from blowing up the
context window. When triggered, the content is replaced with a compact JSON
error containing a fingerprint and (for Steps) the persisted file path.

### 7.5 Chat-role-as-DSL

Instead of a programmatic API, Scout-AI uses chat message roles as a
declarative DSL for tool registration. This means the same chat file works on
disk, in Ruby, and through the CLI.

### 7.6 Dual schema representation

Tool definitions exist in two forms:

- **Internal (flat)**: `{ name:, description:, parameters: { ... } }` — used by
  the workflow tool path.
- **Provider-nested**: `{ type: 'function', function: { ... } }` — used by the
  KB and MCP paths and by some backends.

`format_tool_definitions` normalises between them transparently.

---

## 8. Method reference

| Method | File | Purpose |
|---|---|---|
| `LLM.process_calls` | `tools/call.rb` | **Main dispatcher** for tool execution |
| `LLM.call_id_name_and_arguments` | `tools/call.rb` | Extract id/name/args from a tool call |
| `LLM.call_tools` | `tools.rb` | Simple block-based execution (Bedrock) |
| `LLM.tool_response` | `tools.rb` | Execute one tool via block, format response |
| `LLM.run_tools` | `tools.rb` | Execute `cmd`-role messages as shell commands |
| `LLM.task_tool_definition` | `tools/workflow.rb` | Build a tool definition from a workflow task |
| `LLM.workflow_tools` | `tools/workflow.rb` | Build a tool registry from a workflow |
| `LLM.call_workflow` | `tools/workflow.rb` | Execute a workflow task as a tool |
| `LLM.scout_to_tool_input_type` | `tools/workflow.rb` | Map Scout input types → JSON Schema |
| `LLM.knowledge_base_tool_definition` | `tools/knowledge_base.rb` | Build a tool registry from a KB |
| `LLM.call_knowledge_base` | `tools/knowledge_base.rb` | Execute a KB query as a tool |
| `LLM.mcp_tools` | `tools/mcp.rb` | Connect to an MCP server, build a tool registry |
| `LLM.tools` / `Chat.tools` | `chat/process/tools.rb` | Extract tool definitions from chat messages |
| `LLM.associations` / `Chat.associations` | `chat/process/tools.rb` | Extract association tools from chat messages |
