> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# 06 — Tools System

> Source files analyzed:
> `lib/scout/llm/tools.rb`, `lib/scout/llm/tools/call.rb`,
> `lib/scout/llm/tools/workflow.rb`, `lib/scout/llm/tools/knowledge_base.rb`,
> `lib/scout/llm/tools/mcp.rb`, `lib/scout/llm/mcp.rb`,
> `lib/scout/llm/backends/default.rb`, `lib/scout/llm/backends/anthropic.rb`,
> `lib/scout/llm/backends/openai.rb`, `lib/scout/llm/backends/ollama.rb`,
> `lib/scout/llm/backends/huggingface.rb`, `lib/scout/llm/backends/bedrock.rb`,
> `lib/scout/llm/chat/process/tools.rb`, `lib/scout/llm/ask.rb`,
> `lib/scout/llm/agent.rb`, `scout_commands/workflow/mcp`.

---

## 1. Tool Definition Format

### 1.1 Internal representation — the `{ name => [executor, definition] }` hash

Throughout the tools system a **tool registry** is always a `Hash` whose keys
are tool (function) names and whose values are a two-element array:

```ruby
{
  "task_name" => [ executor_object, definition_hash ]
}
```

| Array slot | Meaning |
|---|---|
| `[0]` executor | The object that knows *how* to run the tool.  Can be a `Workflow`, a `KnowledgeBase`, a `Proc`, a `String` (workflow name), or `nil` (fallback to block). |
| `[1]` definition | The JSON-schema-flavoured hash describing the tool for the LLM.  When the executor itself is a `Hash` (e.g. a raw Proc definition), slot `[0]` holds the definition and slot `[1]` may be the same or different. |

When the executor in `[0]` is a `Hash`, `process_calls` treats *that hash*
as the definition (see `call.rb` line 36: `definition = obj if Hash === obj`).

### 1.2 The definition hash

Every definition is an `IndiferentHash` (symbol/string-indifferent access)
with this shape:

```ruby
{
  name:        "my_tool",           # tool / function name
  description: "What this tool does",
  parameters:  {
    type:       "object",
    properties: {
      input_a: { type: "string", description: "..." },
      input_b: { type: "array",  items: { type: "string" },
                 enum: ["x","y"], description: "..." }
    },
    required: ["input_a"],
    defaults: { input_b: "x" }     # optional, stripped before sending to model
  }
}
```

Key points:

* `parameters` follows **JSON Schema** conventions (`type: "object"`,
  `properties`, `required`).
* `defaults` is a Scout-internal extension; it is **stripped** before
  the definition is sent to the LLM (see `default.rb` `format_tool_definitions`
  line 229: `definition[:parameters].delete :defaults`).
* Some code paths store the definition **nested** under a `:function` key
  (`{ type: 'function', function: { name:..., description:..., parameters:...} }`).
  The `format_tool_definitions` method in each backend normalises both
  shapes — flattening when needed.

### 1.3 How tools are registered (entry points)

Tools are gathered from three sources, all of which return the same
`{ name => [executor, definition] }` hash shape:

| Source | Entry point | Called from |
|---|---|---|
| **Explicit `:tools` option** | `options[:tools]` passed to `LLM.ask` or `Backend.ask` | `default.rb` `tools()` method (line 318) |
| **Chat message roles** (`tool`, `mcp`, `kb`, `introduce`) | `Chat.tools(messages)` / `LLM.tools(messages)` | `default.rb` `tools()` line 320 |
| **Agent setup** | `LLM.workflow_tools(wf)`, `LLM.knowledge_base_tool_definition(kb)` | `agent.rb` lines 89-90 |

In `Backend.ask` (default.rb line 319):
```ruby
tools = tools(formatted_prompt, options)
```
which internally does:
```ruby
def tools(messages, options)
  tools = options.delete :tools          # 1. explicit tools option
  # normalise Array → Hash
  tools.merge!(LLM.tools messages)       # 2. tool/mcp/kb/introduce roles
  tools.merge!(LLM.associations messages)# 3. association roles
  tools
end
```

---

## 2. The Calling Protocol

### 2.1 Full trace: model emits tool_call → execution → result → model continues

```
 ┌─────────────────────────────────────────────────────────────┐
 │  1. Backend.ask() called with messages + tools              │
 │     (default.rb:475)                                        │
 │                                                             │
 │  2. format_messages() converts internal message roles        │
 │     ('function_call', 'function_call_output') to             │
 │     provider-specific format                                │
 │     (default.rb:259 format_tool_call / format_tool_output)  │
 │                                                             │
 │  3. format_tool_definitions() strips :defaults, normalises   │
 │     to provider format                                      │
 │                                                             │
 │  4. query(client, formatted_prompt, tools, options)          │
 │     → sends to LLM API                                      │
 │                                                             │
 │  5. Model returns response containing tool_call(s)            │
 │                                                             │
 │  6. process_response(messages, response, tools, options)     │
 │     a. Extracts tool_calls from response                     │
 │     b. Parses each via parse_tool_call() (backend-specific)   │
 │     c. Calls LLM.process_calls(tools, tool_calls, &block)    │
 │     d. Returns output messages array                         │
 │                                                             │
 │  7. chain_tools() — if last message role is                  │
 │     'function_call_output', re-calls ask() so the model      │
 │     can continue with the tool results                      │
 │     (default.rb:345)                                        │
 │                                                             │
 │  8. Loop continues until model returns text (no tool_calls)  │
 └─────────────────────────────────────────────────────────────┘
```

### 2.2 `LLM.process_calls` (call.rb) — the core dispatcher

**Signature:**
```ruby
def self.process_calls(tools, calls, &block)
```

**Parameters:**
| Param | Type | Meaning |
|---|---|---|
| `tools` | `Hash` | The `{ name => [executor, definition] }` registry |
| `calls` | `Array<Hash>` | Parsed tool calls from the model response, each containing `name`, `arguments`, `id`/`call_id` |
| `&block` | `Proc` (optional) | Fallback executor for tools whose executor is `nil` |

**Returns:** a flat `Array` of message hashes alternating
`{ role: "function_call", content: ... }` and
`{ role: "function_call_output", content: ... }`.

**Step-by-step:**

1. **For each tool_call**, extract `tool_call_id`, `function_name`,
   `function_arguments` via `call_id_name_and_arguments()`.

2. **Look up the tool** in the registry: `obj, definition = tools[function_name]`.

3. **Apply defaults** from `definition[:parameters][:defaults]`.

4. **Dispatch based on executor type:**

   ```ruby
   case obj
   when Proc        # Lambda/Proc — call directly
     obj.call(function_name, function_arguments)
   when String      # Workflow name string
     # const_get or Workflow.require_workflow, then call_workflow
   when Workflow    # Workflow module
     call_workflow(obj, function_name, function_arguments)
   when KnowledgeBase
     call_knowledge_base(obj, function_name, function_arguments.dup)
   else             # fallback to block
     block.call(function_name, function_arguments)
   end
   ```

5. **Handle special return types:**
   * `Step` — queued for batch production via `Workflow.produce(jobs)`.
   * `LLM::Agent` — batched agent chat execution (parallel via
     `Open.traverse` with configurable `cpus`).
   * `IO` / `TSV::Dumper` — read to string.
   * `nil` — becomes `"success"`.
   * `Exception` — serialised as `{ exception:, stack: }.to_json`.
   * Other — `to_json` or `to_s`.

6. **Step/Job resolution:** After collecting all tool results, if any
   returned a `Step`, they are produced in batch via
   `Workflow.produce(jobs)`. Results are then loaded: `.load` if done,
   exception JSON if errored, or force `.run` if neither.

7. **Agent resolution:** If any tool returned an `LLM::Agent`, those
   agents are chatted in parallel (`Open.traverse`, configurable cpus
   via `Scout::Config.get(:cpus, :agent_ask, :agents, env: 'ASK_AGENTS', default: 3)`).
   The agent's `current_chat.follow(res)` is called to integrate the
   response.

8. **Content truncation guard:** if the string content exceeds
   `LLM.max_content_length` (default 100 000, configurable via
   `Scout::Config.get(:max_content_length, :llm_tools, :tools, :llm, :ask, default: 100_000)`),
   it is replaced with an exception JSON containing a fingerprint and
   (if a Step was involved) the persisted file path.

9. **Output messages** are assembled as alternating pairs:
   ```ruby
   [
     { role: "function_call",      content: tool_call_json },
     { role: "function_call_output", content: { name:, content:, id: }.to_json }
   ]
   ```

### 2.3 How tool results are formatted for the model

Each backend has `format_tool_call` and `format_tool_output` methods that
convert the internal `function_call` / `function_call_output` roles to
the provider-specific wire format:

| Backend | Tool call format | Tool result format |
|---|---|---|
| **Default (OpenAI Responses API)** | `{ type: 'function_call', name:, arguments: json_string, call_id:, status: 'completed' }` | `{ type: 'function_call_output', output:, call_id: }` |
| **OpenAI (Chat Completions)** | `{ role: 'assistant', tool_calls: [{ type:'function', function:{name:,arguments:} }] }` | `{ role: 'tool', content:, tool_call_id: }` |
| **Anthropic** | `{ role: 'assistant', content: [{ type:'tool_use', id:, name:, input: }] }` | `{ role: 'user', content: [{ type:'tool_result', tool_use_id:, content: }] }` |
| **Ollama** | `{ role: 'assistant', tool_calls: [{ type:'function', function:{name:,arguments:} }] }` | standard tool role |
| **Bedrock** | provider-native | uses `LLM.tool_response` directly in-loop |

The `chain_tools` method (default.rb:345) implements the **loop continuation**:
if the last output message has role `function_call_output`, it re-calls
`ask()` so the model can see the tool results and respond again. This
enables multi-turn tool use within a single `LLM.ask` call.

### 2.4 `LLM.call_tools` / `LLM.tool_response` (tools.rb — legacy/simpler path)

These methods in `tools.rb` provide a **simpler, block-based** alternative
to `process_calls`. They are used by the Bedrock backend.

```ruby
def self.call_tools(tool_calls, &block)
  # For each tool_call:
  #   1. Calls LLM.tool_response(tool_call, &block)
  #   2. Returns [ {role:'function_call',...}, {role:'function_call_output',...} ]
end

def self.tool_response(tool_call, &block)
  # Extracts name, arguments
  # Calls block.call(function_name, function_arguments)
  # Returns { id:, role: "tool", content: }
end
```

### 2.5 `LLM.run_tools` (tools.rb)

```ruby
def self.run_tools(messages)
  # Converts messages with role 'cmd' into role 'tool' by executing
  # the CMD command in the content.
end
```

This is a **shell-command-as-tool** mechanism: messages with
`role: 'cmd'` have their `content` executed as a shell command and the
output is wrapped as a `tool` role message.

---

## 3. Workflow-as-Tools (workflow.rb)

### 3.1 Overview

Scout's `LLM.workflow_tools` introspects a `Workflow` module and exposes
its tasks as LLM-callable tools. Each task becomes a function whose
parameters are derived from the task's input declarations.

### 3.2 `LLM.task_tool_definition`

**Signature:**
```ruby
def self.task_tool_definition(workflow, task_name, inputs = nil)
```

Generates a single tool definition from a workflow task.

**Process:**

1. Retrieves `task_info` via `workflow.task_info(task_name)` — this is
   Scout's standard task metadata containing `:inputs`,
   `:input_types`, `:input_descriptions`, `:input_options`, `:description`.

2. **Optional `inputs` filter:** If a list of inputs is provided (either
   as symbols or `"name=value"` strings for defaults), only those inputs
   are exposed. Strings containing `=` set defaults:
   ```ruby
   inputs = [:source, "threshold=0.5"]
   # Exposes only :source, and sets default for :threshold
   ```

3. **Type mapping** via `scout_to_tool_input_type`:

   | Scout input type | JSON Schema type |
   |---|---|
   | `:chat` | `:text` |
   | `:text` | `:string` |
   | `:select` | `:string` |
   | `:path` | `:string` |
   | `:float` | `:number` |
   | `*_array` | `:array` |
   | other | unchanged |

4. **Enum support:** If an input has `:select_options` in its input
   options, these become an `"enum"` array in the schema.

5. **`return_path` injection:** For non-exec tasks, an additional
   boolean parameter `return_path` is injected:
   ```ruby
   properties[:return_path] = {
     type: 'boolean',
     description: 'Instead of the result of the job, return the path were it is persisted'
   }
   ```

6. **Required inputs:** Only inputs explicitly marked `required: true`
   in their input options are added to the `required` array.

7. **Returns** the definition as an `IndiferentHash`.

**Example generated definition:**
```ruby
{
  name: :hi,
  description: "Just say hi to someone",
  parameters: {
    type: "object",
    properties: {
      name: { type: :string, description: "Name" },
      return_path: { type: 'boolean', description: 'Instead of...' }
    },
    required: ["name"]
  }
}
```

### 3.3 `LLM.workflow_tools`

**Signature:**
```ruby
def self.workflow_tools(workflow, tasks = nil)
```

**Process:**

1. **If `workflow` is an Array**, recursively merges tool definitions
   from each workflow in the array (supports multi-workflow registration).

2. **Otherwise:**
   * Calls `Chat.allow_read_dir(workflow.directory)` to grant the chat
     filesystem read access to the workflow source.
   * Determines which tasks to expose:
     * `tasks` argument if provided.
     * `workflow.all_exports` (explicitly exported tasks) if `nil`.
     * Falls back to `workflow.all_tasks` if no exports exist.
   * For each task, calls `task_tool_definition` and builds the registry:
     ```ruby
     { task_name => [workflow, definition] }
     ```

### 3.4 `LLM.call_workflow`

**Signature:**
```ruby
def self.call_workflow(workflow, task_name, parameters = {})
```

Executes a workflow task when the LLM calls it.

**Process:**
1. Extracts special parameters: `jobname`, `return_path`, `exec_type`,
   `allow_recursive`.
2. Creates a job: `workflow.job(task_name, jobname, parameters)`.
3. **Dispatch:**
   * If the task is an `exec_export` or `exec_type` is `'exec'`:
     calls `job.exec` (synchronous, in-process, no persistence).
   * Else if `return_path` is true:
     `job.run(true)` (async) then returns `job.path` (the file path on
     disk where the result will be persisted).
   * Else:
     **Recursion guard** — raises `ScoutException` if the job is already
     running with the current PID (prevents infinite tool-call loops).
     Otherwise returns the `Step` (job) object for deferred production.

### 3.5 How task inputs map to tool parameters

```
Scout task declaration          →   Tool definition
────────────────────────────────    ──────────────────────
input :name, :string, "Desc"        properties[:name] = {
                                      type: :string,
                                      description: "Desc"
                                    }

input :organism, :select, "Org",    properties[:organism] = {
  select_options: ["Hsa", "Mmu"]      type: :string,
                                      description: "Org",
                                      enum: ["Hsa", "Mmu"]
                                    }

input :files, :file_array, "Files"  properties[:files] = {
                                      type: :array,
                                      items: { type: :string },
                                      description: "Files"
                                    }

input :threshold, :float,           properties[:threshold] = {
  default: 0.5                         type: :number,
                                      description: "..."
                                    }
                                    # NOTE: Scout defaults are NOT
                                    # automatically carried to the
                                    # tool schema; only inline
                                    # inputs=["threshold=0.5"] sets
                                    # parameters[:defaults]
```

---

## 4. Knowledge Base / RAG Tools (knowledge_base.rb)

### 4.1 Overview

Scout's KnowledgeBase (an association-graph database) is exposed to the
LLM as a set of query tools. Each database in the KB becomes two tools:
one for finding associations and one for retrieving details.

### 4.2 Tools generated per database

For each database in the KB, `knowledge_base_tool_definition` generates:

#### Tool 1: Association lookup (`database_name`)

```ruby
# Directed database:
{
  name: "gene_protein",
  description: "Find associations for a list of entities in database gene_protein. ...
               Returns a list in the format source~target.",
  parameters: {
    type: "object",
    properties: {
      entities: { type: "array", items: { type: :string },
                  description: 'Source entities, or targets if "reverse" is true' },
      reverse:  { type: "boolean",
                  description: 'Look for targets instead of sources, defaults to "false"' }
    },
    required: ["entities"]
  }
}

# Undirected database:
#   - No :reverse parameter
#   - description mentions entity~partner format
```

#### Tool 2: Association details (`database_name_association_details`)

Only generated if the database has fields.

```ruby
# Multiple fields:
{
  name: "gene_protein_association_details",
  description: "Return details of association as a dictionary object. ...
               The fields are: source, target, score.",
  parameters: {
    type: "object",
    properties: {
      associations: { type: "array", items: { type: :string } },
      fields: { type: "array", items: { type: :string } }
    },
    required: ["associations"]
  }
}

# Single field: :fields property is omitted
```

### 4.3 `LLM.call_knowledge_base`

**Signature:**
```ruby
def self.call_knowledge_base(knowledge_base, database, parameters = {})
```

**Dispatch:**
* If `database` ends with `_association_details`:
  - Strips the suffix to get the real database name.
  - Uses `knowledge_base.get_index(database)` to look up values.
  - If `fields` given: returns `{ association => [field_values...] }`.
  - If no fields: returns `{ association => { field => value, ... } }`.

* Otherwise (association lookup):
  - If `reverse`: calls `knowledge_base.parents(database, entities)`.
  - Else: calls `knowledge_base.children(database, entities)`.
  - Returns a list of associations in `source~target` format.

### 4.4 Registration entry points

| Context | Code |
|---|---|
| **Agent** | `agent.rb:90`: `tools.merge!(LLM.knowledge_base_tool_definition(knowledge_base))` |
| **Chat `kb` role** | `Chat.tools()` line 200: loads KB via `KnowledgeBase.load`, generates tools |
| **`LLM.knowledge_base_ask`** | `ask.rb:118`: convenience method for asking questions against a KB |
| **`association` role** | `Chat.associations()` line 221: registers a TSV file as a KB database on-the-fly |

### 4.5 RAG integration

The KB tools are the **retrieval mechanism** for Scout's RAG pipeline.
The model can:
1. Call a database tool to find associations (e.g., gene→disease).
2. Call the `_association_details` tool to get field values.
3. Use `reverse: true` to traverse in the opposite direction.

The `association` chat role allows dynamically registering a TSV file as
a queryable database during a conversation:
```ruby
# In a chat message:
# role: association, content: "mydb /path/to/data.tsv fields=col1,col2 type=double"
```
This registers the TSV and immediately generates the corresponding tools.

---

## 5. MCP Integration (mcp.rb, tools/mcp.rb)

### 5.1 What is MCP in Scout

Scout integrates the **Model Context Protocol (MCP)** in two directions:

| Direction | File | Purpose |
|---|---|---|
| **MCP Client** (consume external tools) | `lib/scout/llm/tools/mcp.rb` | Connect to external MCP servers (HTTP or stdio) and expose their tools to Scout agents |
| **MCP Server** (expose Scout workflows) | `lib/scout/llm/mcp.rb` | Run a Scout workflow as an MCP server, making its tasks available to any MCP-compatible client |

Dependencies:
* `ruby-mcp-client` gem (the `mcp_client` require in `tools/mcp.rb`)
* `mcp` gem (the `mcp` require in `llm/mcp.rb`)

### 5.2 MCP Client: `LLM.mcp_tools`

**Signature:**
```ruby
def self.mcp_tools(url, options = {})
```

**Process:**

1. **Determine connection type:**
   * If `url == 'stdio'`: creates a stdio-based MCP client using the
     `command:` option.
   * If `Open.remote?(url)`: creates an HTTP-based client. Optionally
     adds an `Authorization: Bearer <token>` header, where the token
     comes from `LLM.get_url_config(:key, url, :mcp)`.
   * Otherwise: defaults based on options.

2. **Creates the client:**
   ```ruby
   client = MCPClient.create_client(mcp_server_configs: [options.merge(type: ..., url: ...)])
   ```

3. **Lists tools** from the server: `tools = client.list_tools`.

4. **For each MCP tool**, builds a Scout tool registry entry:
   ```ruby
   tool_definitions[name] = [block, definition]
   ```
   Where:
   * `definition` = `{ name:, description:, parameters: schema }` merged
     with `{ type: 'function', function: { ... } }`.
   * `block` = a `Proc` that calls `tool.server.call_tool(name, params)`
     and normalises the response (extracting `content` → `text` from the
     MCP response envelope).

5. **Response normalisation** in the block:
   ```ruby
   res = tool.server.call_tool(name, params)
   res = res['content'] if Hash === res && res['content']
   res = res.first if Array === res && res.length == 1
   res = res['content'] if Hash === res && res['content']
   res = res['text'] if Hash === res && res['text']
   ```

### 5.3 MCP Server: `Workflow#mcp` and `Workflow#mcp_stdio`

Defined in `lib/scout/llm/mcp.rb`, these methods turn a Scout workflow
into an MCP server.

#### `Workflow#mcp`

```ruby
def mcp(*tasks)
  # tasks defaults to all tasks if none specified
  tools = tasks.collect do |task, inputs = nil|
    tool_definition = LLM.task_tool_definition(self, task, inputs)
    description = tool_definition[:description]
    input_schema = tool_definition[:parameters].slice(:properties, :required)
    annotations = tool_definition.slice(:title)
    annotations[:read_only_hint] = true
    annotations[:destructive_hint] = false
    annotations[:idempotent_hint] = true
    annotations[:open_world_hint] = false
    MCP::Tool.define(name: task, description: description,
                     input_schema: input_schema,
                     annotations: annotations) do |parameters, context|
      self.job(name, parameters).run
    end
  end

  MCP::Server.new(name: self.name, version: "1.0.0", tools: tools)
end
```

Key details:
* Reuses `LLM.task_tool_definition` to generate the schema — same code
  path as workflow-as-tools.
* Extracts `input_schema` as `{ properties:, required: }` (JSON Schema
  subset, no `defaults`).
* Adds MCP **annotations** hinting the tools are read-only,
  non-destructive, idempotent, and closed-world.
* The tool block calls `self.job(name, parameters).run`.

#### `Workflow#mcp_stdio`

```ruby
def mcp_stdio(*tasks)
  server = mcp(*tasks)
  transport = MCP::Server::Transports::StdioTransport.new(server)
  server.transport = transport
  transport.open
end
```

Starts the MCP server over stdio transport — the standard way to run
an MCP server as a subprocess.

### 5.4 CLI entry point

The `scout workflow mcp` command (`scout_commands/workflow/mcp`) runs
any Scout workflow as an MCP server:

```bash
scout workflow mcp <workflow> [<task_name>]*
```

If no tasks are named, exports follow the same fallback logic as
`workflow_tools`: explicitly exported tasks, or all tasks.

### 5.5 Chat-level MCP integration

In the chat system, MCP servers are connected via messages with
`role: 'mcp'` (processed in `Chat.tools()` lines 125-143):

```
role: mcp
content: https://api.example.com/mcp/          # HTTP MCP server (all tools)
content: https://api.example.com/mcp/ tool1 tool2  # HTTP MCP server (specific tools)
content: stdio my-mcp-command                   # stdio MCP server
```

---

## 6. Key Design Patterns

### 6.1 Unified tool registry shape

The single most important pattern: **every tool source produces the same
`{ name => [executor, definition] }` hash**, regardless of whether the
tool comes from a workflow task, a knowledge base database, an MCP
server, or a raw Proc. This means `process_calls` has one dispatch path
that handles all tool types.

### 6.2 Backend polymorphism via module prepend

Each backend overrides specific formatting/parsing methods:
```ruby
class << self
  prepend OpenAIMethods      # overrides
  include Backend::ClassMethods  # shared
end
```

The shared `ask()` method calls `process_response()`, which each backend
implements to parse its native response format and then delegates to the
shared `LLM.process_calls()`.

### 6.3 Deferred Step production

When a workflow tool returns a `Step` (job), it is not immediately run.
Instead:
1. All Steps are collected.
2. `Workflow.produce(jobs)` batch-produces them (potentially in parallel).
3. Results are loaded from the produced Steps.

This allows the model to call multiple workflow tools in one turn and
have them execute concurrently.

### 6.4 Content truncation as a safety pattern

The `max_content_length` guard (default 100K chars) prevents enormous
tool outputs from blowing up the model's context window. When triggered,
the content is replaced with a JSON error containing a `Log.fingerprint`
(a compact hash/summary) and, if a Step was involved, the persisted file
path so the model knows where the full result lives.

### 6.5 Chat-role-as-DSL for tool registration

Instead of a programmatic API, Scout uses **message roles** in the chat
as a declarative DSL:

| Role | Purpose |
|---|---|
| `tool` | Register a workflow task as a tool |
| `introduce` | Add workflow documentation to the context + register tools |
| `mcp` | Connect to an MCP server and expose its tools |
| `kb` | Load a knowledge base and expose its databases as tools |
| `association` | Register a TSV file as an ad-hoc KB database |
| `clear_tools` | Remove all tool definitions |
| `clear_associations` | Remove all association definitions |
| `cmd` | Execute a shell command (run_tools) |

These are processed by `Chat.tools()` and `Chat.associations()`, which
mutate the message array (consuming/removing tool-registration messages)
and return the accumulated tool registry.

### 6.6 Recursion guard

In `call_workflow`, a `ScoutException` is raised if a job is already
running with the current PID (`job.running? && job.info[:pid] == Process.pid`).
This prevents an agent from calling a workflow task that itself triggers
another agent call, which could create infinite recursion. The guard can
be explicitly bypassed with `allow_recursive: 'true'`.

### 6.7 Dual schema representation

Tool definitions exist in two forms:
1. **Internal**: flat hash `{ name:, description:, parameters: { ... } }`.
2. **Provider-nested**: `{ type: 'function', function: { name:, description:, parameters: { ... } } }`.

The `format_tool_definitions` method in each backend normalises between
these. The KB and MCP code paths produce the nested form; the workflow
code path produces the flat form. Both are handled transparently.

### 6.8 Method reference summary

| Method | File | Purpose |
|---|---|---|
| `LLM.call_tools` | `tools.rb` | Simple block-based tool execution (Bedrock) |
| `LLM.tool_response` | `tools.rb` | Execute one tool via block, format response |
| `LLM.run_tools` | `tools.rb` | Execute `cmd`-role messages as shell commands |
| `LLM.process_calls` | `tools/call.rb` | **Main dispatcher** for tool execution |
| `LLM.call_id_name_and_arguments` | `tools/call.rb` | Extract id/name/args from tool_call |
| `LLM.task_tool_definition` | `tools/workflow.rb` | Build tool definition from workflow task |
| `LLM.workflow_tools` | `tools/workflow.rb` | Build tool registry from workflow |
| `LLM.call_workflow` | `tools/workflow.rb` | Execute workflow task as tool |
| `LLM.scout_to_tool_input_type` | `tools/workflow.rb` | Map Scout input types to JSON Schema types |
| `LLM.database_tool_definition` | `tools/knowledge_base.rb` | Build association-lookup tool from KB database |
| `LLM.database_details_tool_definition` | `tools/knowledge_base.rb` | Build details tool from KB database |
| `LLM.knowledge_base_tool_definition` | `tools/knowledge_base.rb` | Build full tool registry from KB |
| `LLM.call_knowledge_base` | `tools/knowledge_base.rb` | Execute KB query as tool |
| `LLM.mcp_tools` | `tools/mcp.rb` | Connect to MCP server, build tool registry |
| `Workflow#mcp` | `llm/mcp.rb` | Create MCP server from workflow |
| `Workflow#mcp_stdio` | `llm/mcp.rb` | Start MCP server over stdio |
| `LLM.tools` | `chat/process/tools.rb` (via `Chat.tools`) | Process chat messages to extract tool definitions |
| `LLM.associations` | `chat/process/tools.rb` (via `Chat.associations`) | Process association messages |
