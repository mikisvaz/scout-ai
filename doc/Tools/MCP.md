# MCP (Model Context Protocol)

The **Model Context Protocol (MCP)** is an open standard for exposing tools to
LLMs. Instead of hand-crafting function schemas for each model provider, you
run an **MCP server** that publishes a list of tools with JSON Schema
parameters. Any MCP-compatible client — Claude Desktop, Cursor, or another
LLM application — can discover and call those tools.

Scout-AI integrates MCP in **both directions**:

| Direction | Purpose | Source file |
|---|---|---|
| **MCP Client** (consume external tools) | Connect to external MCP servers and expose their tools to Scout agents | `lib/scout/llm/tools/mcp.rb` |
| **MCP Server** (expose Scout workflows) | Run a Scout workflow as an MCP server so other applications can use its tasks | `lib/scout/llm/mcp.rb` |

This document covers:

- The `mcp:` chat role
- `LLM.mcp_tools` (client integration)
- `Workflow#mcp` and `Workflow#mcp_stdio` (server integration)
- The `scout-ai workflow mcp` CLI command
- Tool wrapping: how MCP tool definitions map to Scout's format
- Practical examples

For the general tools system, see [Tools.md](Tools.md).

---

## 1. MCP Client: consuming external MCP servers

### 1.1 `LLM.mcp_tools`

**Signature:**

```ruby
LLM.mcp_tools(url, options = {})
```

Connects to an MCP server, discovers its tools, and wraps each as a Scout-AI
tool registry entry (`{ name => [executor, definition] }`).

**Connection types:**

| `url` value | Transport | How the client is created |
|---|---|---|
| `'stdio'` | stdio subprocess | `MCPClient.create_client(mcp_server_configs: [options.merge(type: 'stdio')])` |
| HTTP/HTTPS URL | HTTP | `MCPClient.create_client(mcp_server_configs: [options.merge(type: 'http', url: url)])` |

For HTTP servers, an optional bearer token is added from `LLM.get_url_config(:key, url, :mcp)`:

```ruby
token = LLM.get_url_config(:key, url, :mcp)
options[:headers] = { 'Authorization' => "Bearer #{token}" }
```

### 1.2 Tool discovery and wrapping

After connecting, `mcp_tools` calls `client.list_tools` to enumerate the
server's tools. For each MCP tool:

1. **Extract metadata:** `name`, `description`, and `schema` (JSON Schema
   parameters) are read from the MCP tool object.
2. **Build the definition** in the provider-nested format:

   ```ruby
   {
     name: name,
     description: description,
     parameters: schema
   }.merge(type: 'function', function: { ... })
   ```

3. **Create the executor block:** a `Proc` that calls
   `tool.server.call_tool(name, params)` and normalises the MCP response
   envelope:

   ```ruby
   res = tool.server.call_tool(name, params)
   res = res['content']    if Hash === res && res['content']
   res = res.first         if Array === res && res.length == 1
   res = res['content']    if Hash === res && res['content']
   res = res['text']       if Hash === res && res['text']
   ```

   This unwraps the MCP response envelope to extract the actual text content
   that the model needs.

4. **Register:** `tool_definitions[name] = [block, definition]`

The executor slot holds a `Proc` (not a Workflow or KnowledgeBase), so
`LLM.process_calls` dispatches it via the `when Proc` branch — calling it
directly with `(name, params)`.

### 1.3 Timeout configuration

```ruby
timeout = Scout::Config.get(:timeout, :mcp, :tools)
```

If set, this becomes the `read_timeout` for the MCP client.

---

## 2. The `mcp:` chat role

MCP servers are connected via chat-file messages with `role: 'mcp'`:

```text
mcp: https://api.example.com/mcp/
```

This connects to the HTTP MCP server and registers **all** its tools. To
register only specific tools:

```text
mcp: https://api.example.com/mcp/ search lookup
```

For stdio-based MCP servers:

```text
mcp: stdio my-mcp-command
```

The `mcp:` message is **consumed** (removed) after processing. The discovered
tools are merged into the tool registry.

### 2.1 Processing in `Chat.tools()`

```ruby
if role == 'mcp'
  url, *tools = content_tokens(message)

  if url == 'stdio'
    command = tools.shift
    mcp_tool_definitions = LLM.mcp_tools(url, command: command, url: nil, type: :stdio)
  else
    mcp_tool_definitions = LLM.mcp_tools(url)
  end

  if tools.any?
    tools.each { |tool| tool_definitions[tool] = mcp_tool_definitions[tool] }
  else
    tool_definitions.merge!(mcp_tool_definitions)
  end
end
```

---

## 3. MCP Server: exposing Scout workflows

### 3.1 `Workflow#mcp`

**Signature:**

```ruby
workflow.mcp(*tasks)
```

Turns a Scout workflow into an MCP server. Each task becomes an MCP tool.

**Process:**

1. **Task selection:** Defaults to all tasks if none specified.

2. **Schema generation:** Reuses `LLM.task_tool_definition` (the same code as
   [WorkflowTools.md](WorkflowTools.md)), then extracts
   `input_schema = { properties:, required: }` — a clean JSON Schema subset
   without Scout-specific extensions like `defaults`.

3. **MCP annotations:** Each tool receives standard MCP hints:

   ```ruby
   annotations[:read_only_hint]   = true
   annotations[:destructive_hint] = false
   annotations[:idempotent_hint]  = true
   annotations[:open_world_hint]  = false
   ```

   These tell MCP clients that the tools are safe to call.

4. **Tool execution:** Each MCP tool's block runs the Scout job:

   ```ruby
   MCP::Tool.define(name: task, description:, input_schema:, annotations:) do |parameters, context|
     self.job(name, parameters).run
   end
   ```

5. **Server creation:**

   ```ruby
   MCP::Server.new(name: self.name, version: "1.0.0", tools: tools)
   ```

### 3.2 `Workflow#mcp_stdio`

```ruby
workflow.mcp_stdio(*tasks)
```

Starts the MCP server using stdio transport — the standard way to run an MCP
server as a subprocess:

```ruby
def mcp_stdio(*tasks)
  server = mcp(*tasks)
  transport = MCP::Server::Transports::StdioTransport.new(server)
  server.transport = transport
  transport.open
end
```

This is the entry point for CLI usage and integration with MCP clients like
Claude Desktop.

---

## 4. The `scout-ai workflow mcp` command

**Purpose:** Run any Scout workflow as an MCP server over stdio.

**Usage:**

```bash
# Export all tasks
scout-ai workflow mcp MyWorkflow

# Export specific tasks only
scout-ai workflow mcp MyWorkflow task1 task2
```

**Arguments:**

| Argument | Type | Description |
|---|---|---|
| `<workflow>` | positional | Name of the workflow to export |
| `[task_name]*` | positional, repeatable | Specific tasks to export. If none given: explicitly exported tasks, or all tasks. |

**How it works:**

1. Requires the named workflow (loads its `workflow.rb`).
2. Calls `workflow.mcp_stdio(*task_names)`.
3. The server listens on stdio for MCP protocol messages from the client.

**Integration with MCP clients:**

Most MCP clients (e.g., Claude Desktop) are configured to launch a command as a
subprocess and communicate over stdio. The `scout-ai workflow mcp` command is
designed for exactly this pattern:

```json
{
  "mcpServers": {
    "scout-baking": {
      "command": "scout-ai",
      "args": ["workflow", "mcp", "Baking"]
    }
  }
}
```

---

## 5. Tool wrapping: MCP ↔ Scout-AI mapping

| MCP concept | Scout-AI equivalent |
|---|---|
| MCP tool `name` | Tool registry key |
| MCP tool `description` | `definition[:description]` |
| MCP tool `input_schema` (`{ properties, required }`) | `definition[:parameters]` |
| MCP `call_tool(name, params)` | Executor `Proc` in registry slot `[0]` |
| MCP response `{ content: [{ text: "..." }] }` | Unwrapped to plain string |
| MCP annotations (`read_only_hint`, etc.) | Only used when Scout is the **server** |

When Scout acts as an **MCP server**, the mapping reverses: Scout task
definitions are converted to MCP tool definitions using the same
`LLM.task_tool_definition` code path, then wrapped in `MCP::Tool.define`.

---

## 6. Practical examples

### 6.1 Consume an external MCP server (HTTP)

```ruby
tools = LLM.mcp_tools("https://api.example.com/mcp/")
LLM.ask("Search for documents about Ruby", tools: tools, endpoint: :nano)
```

### 6.2 Consume specific tools from an MCP server

```ruby
all_tools = LLM.mcp_tools("https://api.example.com/mcp/")
tools = { "search" => all_tools["search"] }
LLM.ask("Search for Ruby patterns", tools: tools, endpoint: :nano)
```

### 6.3 Consume a stdio MCP server

```ruby
tools = LLM.mcp_tools('stdio', command: 'my-mcp-server', type: :stdio)
LLM.ask("Use the server to do X", tools: tools, endpoint: :nano)
```

### 6.4 Chat file with `mcp:` role (HTTP)

```text
mcp: https://api.example.com/mcp/ search

user:

Search for documents about Ruby concurrency.
```

### 6.5 Chat file with `mcp:` role (stdio)

```text
mcp: stdio my-mcp-server

user:

Run the server's analysis tool.
```

### 6.6 Expose a workflow as an MCP server (Ruby)

```ruby
module Analysis
  extend Workflow

  task :analyze => :text do |data|
    "Analysis result for: #{data}"
  end
end

Analysis.mcp_stdio  # Starts MCP server on stdio
```

### 6.7 Expose a workflow as an MCP server (CLI)

```bash
scout-ai workflow mcp Analysis
```

### 6.8 Configure Claude Desktop to use a Scout workflow

```json
{
  "mcpServers": {
    "scout-analysis": {
      "command": "scout-ai",
      "args": ["workflow", "mcp", "Analysis", "analyze"]
    }
  }
}
```

After adding this to the MCP client's configuration, the client can discover
the `analyze` tool and call it during conversations.

---

## 7. Dependencies

| Gem | Required for | Loaded in |
|---|---|---|
| `mcp_client` (`ruby-mcp-client`) | MCP client (consuming external servers) | `lib/scout/llm/tools/mcp.rb` |
| `mcp` | MCP server (exposing Scout workflows) | `lib/scout/llm/mcp.rb` |

```bash
gem install ruby-mcp-client mcp
```

---

## 8. Cross-references

- [Tools.md](Tools.md) — the unified tool registry, `process_calls` dispatcher
- [WorkflowTools.md](WorkflowTools.md) — `LLM.task_tool_definition` (shared
  code path for schema generation)
- [../Chat/Chat.md](../Chat/Chat.md) — the `mcp:` chat role
- [../Agent/Agent.md](../Agent/Agent.md) — how agents can use MCP tools
- [../Commands/](../Commands/) — the `scout-ai workflow mcp` command
