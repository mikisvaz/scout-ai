# 05 - Tool definitions, dispatch and MCP

> Investigation, not normative documentation. Verified behavior of the tool
> registry, the four executor kinds, definition construction, the
> `function_call_output` envelope, knowledge-base tools and both halves of
> MCP. Normative reference: `doc/user/ToolCalling.md`, `doc/user/Cookbook.md`.

## Scope

`lib/scout/llm/tools.rb`, `lib/scout/llm/tools/{definition,workflow,
knowledge_base,mcp,call}.rb`, the chat-message compilers in
`lib/scout/llm/chat/process/tools.rb`, and the serving side
`lib/scout/llm/mcp.rb`.

## Verified behavior

### Registry shape and dispatch

The canonical registry is a plain `{name => [executor, definition]}` Hash
(`tools/call.rb:96`). `LLM.process_calls` dispatches four executor kinds:

| executor | dispatch | returns |
|---|---|---|
| `Proc` | `obj.call(function_name, function_arguments)` | immediate value |
| `String` | `const_get` if a constant, else `Workflow.require_workflow(obj)`, then `call_workflow` | job/step |
| `Workflow` module | `call_workflow(obj, ...)` | job/step |
| `KnowledgeBase` | `call_knowledge_base(obj, ...)` | association list / details hash |

An unknown name with no block *creates* a `ParameterException` and returns it
as the content (not raised) - it surfaces as `error: "error"` in the envelope.
With a block given to `process_calls`, the block is tried first. A registry
value that is a bare Hash (executor slot dropped) makes the content the
definition hash itself. `nil` Proc results become the literal string
`"success"`; Numeric results are stringified.

### Definition construction

`LLM.tool_definition(name, description, properties, required: nil,
defaults: nil, strict: true, envelope: true)`:

- `envelope: true` (default) wraps into `{type: 'function', function:
  {name:, description:, parameters:}}` - used by the agent layer and the MCP
  client definitions. `envelope: false` produces the bare hash - used by
  `task_tool_definition`; the backend's `format_tool_definitions` then
  flattens `definition[:function]` and strips `parameters[:defaults]`.
- `strict: true` emits `parameters[:additionalProperties] = false`.
- `defaults` is a replay side-channel: emitted as `parameters[:defaults]`
  only when truthy, and merged into the call arguments in `process_calls`
  **before** execution.

**Defaults merge precedence is `function_arguments.merge(defaults)`** - the
definition defaults *override* the model-supplied arguments (F10), and
`tool: WF task name=X` both pre-fills and *hides* the input.

### Workflow tools

`LLM.workflow_tools(workflow, tasks = nil)`:

- `tasks.nil?` -> `workflow.all_exports`; if empty **and** `all_tasks`
  exists, all tasks.
- `Array === workflow` merges each workflow's tools in order; **later
  workflows overwrite earlier ones on name collision** (the registry key is
  the task name only).
- Returns `{task_name(Symbol) => [workflow, definition]}`. A task whose
  `task_info` returns `nil` is skipped; an *unknown* task name raises
  `RuntimeError` from `task_info` itself.

`LLM.task_tool_definition(workflow, task_name, inputs = nil)`:

- Type mapping `scout_to_tool_input_type` (workflow.rb:3-11) is
  **symbol-keyed** and covers only `:chat`/`:text`/`:select`/`:path` ->
  `:string`, `:float` -> `:number`, and any `*_array` -> `:array`. String
  type names pass through unchanged, and **`:boolean`, `:integer`, `:json`
  and `:file` are not in the map** - they pass through as symbols rather
  than `"boolean"`/`"number"`/`"string"`.
- `input_options[:select_options]` -> `"enum"` on the property (Hash values
  unwrapped).
- `required` = only inputs whose `input_options` carry `required: true`.
- The `inputs` restriction list: bare names restrict which properties are
  emitted; `name=value` tokens become definition defaults that pre-fill
  **and hide** the input.
- The `return_path` property is appended only for non-`exec_exports` tasks.

`LLM.call_workflow(workflow, task_name, parameters)`
(tools/workflow.rb:75-115): builds `workflow.job(...)`; then exec export or
exec type -> `job.exec`, returning the result value directly (no Step);
`return_path` truthy -> `job.run(true)` + `Chat.allow_read_job(job)`,
returns the job path String; default -> returns the **Step**. The
recursive-call guard raises `ScoutException 'Potential recursive call'`
when the job is already running in this pid and `allow_recursive != 'true'`
(workflow.rb:106); the method-level `rescue ScoutException` **returns the
exception object** instead of raising.

### Knowledge base tools

`LLM.knowledge_base_tool_definition(kb, databases = nil)` - one *association*
tool per database plus, **only when the database has fields** (3-column
source), a `<db>_association_details` tool; two-column databases expose only
the association tool.

- Association tool: directed -> `entities` (array of string; "Source
  entities in the association, or target entities if reverse is true") +
  `reverse` (boolean); `undirected:` -> only `entities`, description mentions
  the `entity~partner` output. The KB-registered `description:` is embedded
  when present.
- Details tool: >1 fields -> `associations` + `fields` (array, "Limit the
  response to these fields"), description lists field names and notes `;`
  multi-values; exactly 1 field -> `fields` deleted; 0 fields -> tool not
  generated.

`LLM.call_knowledge_base(kb, database, parameters)`:

- `<db>_association_details` -> strips the suffix, reads `kb.get_index(db)`;
  with `fields` -> `values.values_at(*field_pos)`; without -> the full Hash
  keyed by field name. Missing associations are skipped.
- Plain database -> `entities` (a JSON string is parsed) + `reverse` ->
  `kb.parents` / `kb.children`, returning `source~target` entries.
- **No argument validation**: unknown field names raise inside
  `identify_field`; empty/missing `entities` flows into the KB.
- `reverse` results depend on KB registration flags (`undirected`, `key`),
  not on the tool layer; `kb.parents` is target-side, `kb.children`
  source-side, and for a directed database `parents` is not simply the
  inverse of `children`.

### MCP - two independent halves

**(a) Client side, `LLM.mcp_tools` (tools/mcp.rb)**: consumes an external
MCP server and produces `{tool_name => [Proc, definition]}`.

- `url == 'stdio'` -> `MCPClient.create_client(mcp_server_configs:
  [options.merge(type: 'stdio')])`; the chat compiler passes `command:` plus
  the remaining tokens. **Every token after the command is a tool-name
  selection filter, not a command argument** (`mcp: stdio echo x` selects
  tools named `x`).
- Remote URL: effective merge `options.merge(type: 'http', transport:
  :streamable_http)` via `MCPClient.connect(url, **options)`. The `type:`
  computed from `Open.remote?(url)` is overwritten by the literal `'http'`,
  and `connect` dials eagerly - an unreachable URL raises at `mcp_tools`
  construction time rather than at first tool call.
- Bearer token: `LLM.get_url_config(:key, url, :mcp)` ->
  `options[:headers]['Authorization'] = "Bearer #{token}"` (set even when
  empty). `read_timeout` from `Scout::Config.get(:timeout, :mcp, :tools)`.
- Each server tool becomes a **double-wrapped** definition: both a top-level
  `name/description/parameters` and a `function` envelope holding the same
  Hash. `backends/default.rb`'s flatten path handles it, so the
  provider-visible shape ends up flat.
- The executor Proc calls `tool.server.call_tool(name, params)` and unwraps
  `res['content']` -> array -> `.first` -> `['content']`/`['text']`.

**(b) Server side, `Workflow#mcp` (mcp.rb)**: serves a workflow's tasks as
MCP tools over a `StdioTransport`. Current behavior (fixed 2026-09-11,
uncommitted): the block is `do |server_context: nil, **parameters|` capturing
`workflow = self` and `task_name = task.to_s` in locals, returning
`MCP::Tool::Response.new([{type: 'text', text:
workflow.job(task_name, parameters).run.to_s}])`. Tool names are Strings so
the JSON-RPC lookup matches. Annotations are hard-coded
(`read_only_hint/destructive_hint/idempotent_hint/open_world_hint` = true /
false / true / false); the served input schema is
`tool_definition[:parameters].slice(:properties, :required)`, so the
`return_path` boolean survives into it. Results are coerced with `.to_s`
into a single text item; `structuredContent` is never produced, `nil`
becomes the empty string, and job failures surface as JSON-RPC `-32603
Internal error calling tool <name>: <msg>`.

Before the fix (F2) every served call failed with `Internal error`: the
block declared two positional parameters while the `mcp` gem invokes
`tool.call(**args)`, `self` inside `MCP::Tool.define`'s `Class.new` block
was the anonymous tool class rather than the Workflow module, the return
value was not an `MCP::Tool::Response`, and Symbol tool names missed the
String JSON-RPC lookup. The fixed contract is stable across `mcp` 1.1.0 and
1.5.1 (`call_tool_with_args` still dispatches `tool.call(**args,
server_context:)` when `accepts_server_context?` matches a `:keyrest` or a
literal `server_context` key); older positional-invocation releases are
deliberately unsupported. `mcp` is not a declared runtime dependency (the
gemspec lists only `ruby-mcp-client`, the client gem), so the supported
range is undefined upstream.

### Result shaping

Each call emits a **pair**: `{role: 'function_call', content: <tool-call
json>}` (normalized: `call_id` renamed to `id`, name at top level,
`function` envelope preserved when present) plus `{role:
'function_call_output', content: <response json>}` with fields `name`,
`content`, `id`, plus `error`, `stack`, `meta`, `step`, `start_timestamp`,
`timestamp` when applicable (`start_timestamp` once per round, `timestamp`
per output).

Special executor results:

- **`Step`**: done -> `content.load`; `error?` with an exception ->
  `error: :error` + `{exception: ...}` JSON; otherwise -> `content.run`
  inside begin/rescue; `step: step.short_path` added to the envelope. All
  Step-producing calls are batched through `Workflow.produce` with the
  transient `<save_file>.jobs` sidecar, rewritten per round and removed in
  `ensure` (success and error).
- **`LLM::Agent`**: collected and `chat(return_messages: true)`'d in
  parallel (`Open.traverse`, cpus config `:agent_ask`/`:agents`, env
  `ASK_AGENTS`, default 3), then per agent-returning call
  `Chat.allow_read_job`, `content.current_chat.follow(res)`,
  `meta = LLM.meta_receipt_from_messages(Chat.find_role(res, :meta))`,
  `content = content.answer`. Pairing is by tool-call position.
- **`Exception`** (returned, not raised): `error: :error` +
  `{exception: msg, exception_line: first}`.
- **Hash with exactly `content`+`meta`**: content-with-inference-meta; `meta`
  passes through verbatim as the deserialized receipt array.
- Other Hash -> `to_json`; `TSV` -> `to_s`; `IO`/`TSV::Dumper` -> `.read`;
  anything else -> `to_json` with a `to_s` fallback.
- **Truncation**: String content longer than `LLM.max_content_length`
  (config `max_content_length`, tokens `:llm_tools,:tools,:llm,:ask`,
  default 100_000) is replaced by an exception JSON carrying a
  `Log.fingerprint` of the content and `error: :truncated`; with a Step
  attached the message points at `step.path` (tools/call.rb:10, 257-258).

Error taxonomy on the envelope's `error` key: `:error` (executor/step
exception), `:truncated`, `:scout` (`ScoutException` during shaping),
`:harness` (any other shaping failure).

### Chat-message compilation

`Chat.tools(messages)` mutates the array in place, removing and replacing
tooling roles:

- `tool: WF [task [inputs...]]` -> `LLM.workflow_tools(workflow, [task,
  *inputs])`; a bare workflow name exposes all exports; `none`/`noinputs` as
  the sole token restricts the schema to just `return_path`.
- `introduce: WF` -> **documentation only**: replaced by a `user:` message
  with the workflow's title+description; generates **zero** tools;
  deduplicated per workflow name. Whole-workflow tooling requires a bare
  `tool: MyWorkflow`.
- `mcp: <url|stdio> [tool names...]` -> `LLM.mcp_tools`; named tools select
  a subset, a nonexistent name silently yields a `nil` registry entry, and
  the bracket syntax `[a b]` shown in the docs is not special - brackets
  become part of the tool name.
- `kb: <kb-path-or-agent-name> [databases...]` -> `KnowledgeBase.load`; an
  empty KB falls back to `LLM.load_agent(name).knowledge_base`; no matching
  agent raises `ScoutException "No agent found with name <path>"`.
- `clear_tools:` resets the accumulated registry to `{}`.
- `Chat.associations` (separate pass): `association: <name> <path>
  key=value...` registers a database inline into a KB rooted at
  `Scout.var.Agent.Chat.knowledge_base` and emits only that database's
  tools; `clear_associations:` resets. `Chat.tooling` selects
  `[:introduce, :tool, :mcp, :kb]` - it does **not** include `association`,
  which `AgentWorkflow#tooling` also does not harvest.

`task:`/`inline_task:`/`exec_task:` share the file but are chat-context
constructs: they run a workflow job eagerly (`exec_task` inlines the result
as a `user:` message; the others leave a `job:`/`inline_job:` path message
and `Workflow.produce` the collected jobs).

### Agent auto-wiring

`Agent#chat` assembles `options[:tools] || {}`, merged with
`@other_options[:tools]` (JSON-parsed when a String), then
`LLM.workflow_tools(workflow)` when the agent has a workflow with tasks, and
the KB tools when it has a KB with databases. `AgentWorkflow#tooling`
harvests `tool:`/`kb:`/`mcp:`/`introduce:` messages out of the job chat and
follows them into the spawned agent's `start_chat`.

### Legacy entry points

`LLM.call_tools` / `LLM.tool_response` are a simpler registry-less path (no
lookup, no defaults merge, no Step/Agent handling); used only by
`backends/bedrock.rb`. `LLM.run_tools(messages)` converts legacy `cmd:`
messages into `tool:` messages by running the command. `LLM.ask_knowledge_base`
builds a block-dispatched `children` lookup and rewrites `~` to `=>` - a
different output convention from `call_knowledge_base`.

## Sharp edges and known issues

- **`introduce:` generates zero tools** (F4, open): ToolCalling.md claims it
  auto-generates a tool definition per task; it is documentation injection
  only. Affects every consumer relying on it, including prepared briefs.
- **Definition defaults override model arguments and hide inputs** (F10,
  open). Whether "pre-fill" should mean "apply only when the model omits the
  input" is an open semantic decision.
- **Symbol-named KB databases break the tool layer on reload** (F15, open):
  `register(:name, ...)` + `save` round-trips the registry YAML with symbol
  keys and `get_database('name')` does a string-keyed lookup ->
  `RuntimeError "Repo brothers not found and not registered"`. A
  scout-gear/scout-ai boundary trap; register with String names.
- **`:boolean`/`:integer`/`:json` tool inputs pass through the type map
  unnormalized** (open); whether any provider rejects the symbol needs a
  live call.
- **MCP client definitions are double-wrapped** (open): handled by the
  shared flatten path, but per-backend handling was not probed.
- Hard-coded serving annotations and the `return_path` boolean leaking into
  the served schema (recorded, not fixed).
- `LLM.max_content_length` config tokens are not surfaced in any doc.
- **Fixed 2026-09-11, uncommitted:** F2 - MCP serving broken against `mcp`
  gem 1.1.0; fixed in `lib/scout/llm/mcp.rb` with
  `test/scout/llm/tools/test_mcp.rb` (3/0) and re-verified on 1.5.1. During
  the fix a stray unauthorized `scout_to_tool_input_type` edit in
  `tools/workflow.rb` was made and reverted; HEAD semantics are restored.
- **Client-side transport edit pending owner review**: the working tree
  carries an unattributed `lib/scout/llm/tools/mcp.rb` edit (`:http ->
  :https` default plus `MCPClient.connect` instead of `create_client`). It
  is not required for compatibility with `ruby-mcp-client` 2.1.0 (the old
  `create_client` API still constructs `MCPClient::ServerHTTP` on that gem,
  and streamable HTTP was already reachable via
  `create_client(type: 'streamable_http')`), and it changes observable
  behaviour (transport class, eager connection). Kept in place and flagged.

## Open questions

- Should defaults apply only when the model omits the input (F10)?
- Whether `association:` roles should propagate to delegated agents.
- The interaction of `task:`/`inline_task:`/`exec_task:` with a `tool:` role
  naming the same workflow is untested.
- The supported `mcp` gem version range (server side).

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep. The MCP serving fix (F2) is in scope here and is described as current
behavior above.

- Code: `lib/scout/llm/tools/call.rb`; `tools/workflow.rb:3-14` (type map),
  `:20-33` (input restriction/defaults), `:53-68`, `:75-115`;
  `tools/knowledge_base.rb`; `tools/mcp.rb` (client); `tools/definition.rb`;
  `lib/scout/llm/tools.rb` (legacy); `lib/scout/llm/mcp.rb` (server, current
  fixed form); `lib/scout/llm/chat/process/tools.rb`;
  `lib/scout/llm/backends/default.rb:216-236`.
- Gem cross-reference: `mcp-1.1.0/lib/mcp/server.rb:1048-1074`,
  `mcp-1.1.0/lib/mcp/tool.rb:129-141`; the same contract at
  `mcp-1.5.1/lib/mcp/server.rb:1569-1598`.
- Tests: `test/scout/llm/tools/{test_mcp,test_workflow,test_jobs_file,
  test_definition,test_knowledge_base,test_tools}.rb` (0 failures after the
  fix; `test_call.rb` is an empty placeholder).
- Probes: ~28 offline probes under `tmp/subsys-tools/`; the decisive MCP
  boundary probe is the versioned Cortex artifact
  `probe/mcp_serving_dispatch.rb` (Observation `mcp_serving_dispatch`),
  whose `Observation/probe` run reproduces the fixed/broken matrix and drives
  the real `scout_commands/workflow/mcp` entry point end-to-end over stdio.
