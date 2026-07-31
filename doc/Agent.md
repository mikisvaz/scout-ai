# Agent

An `LLM::Agent` is a **stateful wrapper** around a `Chat` (the conversation
data model), with persistent defaults, tool wiring, optional delegation, and
the ability to live inside a Scout `Workflow`. Agents are the primary way to
build multi-turn programs on top of Scout-AI: they hold the conversation,
they know which tools to expose, and they know how to talk to other agents.

Related docs:

- [../Overview.md](../Overview.md) — how Agent fits in the stack
- [../Chat/Chat.md](../Chat/Chat.md) — the conversation data model
- [../Backends/Backends.md](../Backends/Backends.md) — endpoints and inference
- [../Tools/Tools.md](../Tools/Tools.md) — tool calling overview
- [Delegation.md](Delegation.md) — multi-agent wiring (`socialize`, `delegate`)
- [AgentWorkflow.md](AgentWorkflow.md) — encoding strategies as Scout workflows

---

## 1. What an Agent is

An `Agent` is the layer above `Chat` and `Backend` that adds:

- **Conversation state**: a persistent `start_chat` (seed messages) plus one
  or more `current_chat` branches.
- **Sticky options**: `endpoint`, `model`, `backend`, `format`, `persist`, etc.
  stored in `other_options` and merged into every inference call.
- **Tool wiring**: a `Workflow` exposes its tasks as tools; a `KnowledgeBase`
  exposes its databases as tools; MCP servers can be attached too.
- **Delegation**: a `socialize` tool that lets the model call any specialist,
  and named `hand_off_to_*` tools created by `delegate`.
- **Workflow integration**: when an Agent's workflow defines an `ask` task,
  inference goes through that task and gains Scout job caching/provenance.

Underneath, every Agent is a thin state holder. The conversation itself is
just an annotated `Array` of message `Hash`es (see
[../Chat/Chat.md](../Chat/Chat.md)).

### 1.1 Composition

`LLM::Agent` is defined across five files that reopen the same class:

| File | Concern |
|---|---|
| `lib/scout/llm/agent.rb` | Core: `initialize`, `ask`, `prompt`, tool merging, exception handling |
| `lib/scout/llm/agent/chat.rb` | Conversation lifecycle: `start`, `current_chat`, `chat`, `json`, `json_format` |
| `lib/scout/llm/agent/iterate.rb` | Structured extraction loops: `iterate`, `iterate_dictionary` |
| `lib/scout/llm/agent/delegate.rb` | Multi-agent: `socialize`, `delegate`, `ask_agent` |
| `lib/scout/llm/agent/workflow.rb` | `AgentWorkflow` mixin providing `chat_task`, `helper :agent` |

Two module-level convenience methods exist:

```ruby
LLM.agent(...)         # => LLM::Agent.new(...)
LLM.load_agent(...)    # => LLM::Agent.load_agent(...)
```

### 1.2 Quick start

```ruby
require 'scout-ai'

# The factory shortcut is the shortest way to create an agent
agent = LLM.agent(endpoint: :nano)

# Put persistent messages on start_chat
agent.start_chat.system "You are a helpful assistant"

# Create a new conversation branch (a shallow copy of start_chat)
agent.start

# Build the conversation with the Chat DSL (forwarded via method_missing)
agent.user "Say hi"

# One round-trip: ask + append assistant reply + return the answer text
puts agent.chat
```

The same agent can be loaded from a directory:

```ruby
agent = LLM.load_agent('Baking')
agent.start
agent.user "Bake muffins using the tool"
puts agent.chat
```

---

## 2. Conversation lifecycle

Every Agent keeps two Chat objects:

| Chat | Variable | Purpose |
|---|---|---|
| **start chat** | `@start_chat` | Immutable seed: system policy, tool intros, shared context. Prefixes every new branch. |
| **current chat** | `@current_chat` | The live, evolving conversation. |

### `start_chat`

```ruby
agent.start_chat.system "You are a domain expert"
agent.start_chat.option :format, :json
```

Defaults to an empty `Chat` if none was provided at construction. Messages you
put on `start_chat` are *not* sent on their own — they become the prefix of any
branch created by `start`.

### `start(chat = nil)`

- `start()` (no argument): branches `start_chat` via `Chat#branch` (a
  shallow copy) and stores the result as `current_chat`.
- `start(chat)` with a `Chat` or `Array`: adopts that chat as the new
  `current_chat` (annotating it if needed).

```ruby
agent.start                  # new branch from start_chat
agent.start(some_chat)       # adopt an existing chat
```

### `current_chat`

Lazy accessor: on first access it calls `start` so a branch always exists.

```ruby
agent.current_chat.length   # => 0 on a fresh agent before any user message
```

### The branch pattern in one picture

```
start_chat (immutable seed)
    │
    ├── branch → current_chat (conversation A)
    ├── branch → current_chat (conversation B)   [via start(chat)]
    └── ...
```

`Chat#branch` does `self.annotate(self.dup)` — a shallow copy of the Array.
Editing `current_chat` never mutates `start_chat`.

> **Common pitfall**: `agent.ask(messages)` with an explicit messages array does
> *not* prepend `start_chat`. The normal pattern is `agent.start` → `agent.user`
> → `agent.chat`. To prepend `start_chat` and parse chat syntax, use
> `agent.prompt(string)`.

---

## 3. DSL forwarding via `method_missing`

`Agent` does not re-implement the Chat DSL. Instead it forwards any unknown
method to `current_chat`:

```ruby
def method_missing(name, ...)
  current_chat.send(name, ...)
end
```

So you can use the full chat builder vocabulary directly on the agent:

```ruby
agent.system "You are a domain expert"
agent.user   "Summarize this file"
agent.file   "paper.md"
agent.image  "figure.png"
agent.pdf    "supplement.pdf"
agent.option :model, "gpt-5"
```

Any role supported by Chat works the same way from an Agent. These are
equivalent:

```ruby
agent.pdf "supplement.pdf"
agent.message :pdf, "supplement.pdf"
```

This is a deliberate design choice (see
[../Overview.md](../Overview.md#annotation-over-wrapping)). The anti-pattern is
defining wrapper methods on `Agent` that duplicate Chat — `method_missing`
already does the job.

---

## 4. Agent options

The `**kwargs` passed to `new` (or `LLM.agent(...)`) are stored as an
`IndiferentHash` in `other_options` and merged into every `ask`/`chat` call:

| Option | Type | Meaning |
|---|---|---|
| `endpoint:` | Symbol/String | Named endpoint (YAML in `~/.scout/etc/AI/<name>`) |
| `model:` | String | Model id forwarded to the backend |
| `backend:` | Symbol | Backend selector: `:responses`, `:openai`, `:anthropic`, `:ollama`, … |
| `format:` | Symbol/Hash | Output format (JSON, JSON Schema, …) |
| `persist:` | Boolean | Whether to cache inference (default `true`) |
| `tools:` | Hash | Extra tool definitions merged on top of workflow/KB tools |
| `reasoning_effort:` | String | Responses backend reasoning level |
| `websearch:` | Boolean | Append a `websearch: true` message |

`IndiferentHash` gives symbol/string-indifferent access, so `:model` and
`'model'` behave identically.

```ruby
agent = LLM.agent(endpoint: :ollama, model: 'llama3.1')
agent.other_options[:endpoint]  # => :ollama
```

Because the options hash is sticky, you can set options through the Chat DSL
too:

```ruby
agent.option :model, 'gpt-5'      # forwards to current_chat.option
```

---

## 5. Tool wiring

### 5.1 Where tools come from

`Agent#ask` merges tools from three layers (later layers override earlier
ones by tool name):

1. `options[:tools]` passed to the individual call.
2. `@other_options[:tools]` (e.g. tools added by `socialize`, `delegate`, or
   explicit `agent.other_options[:tools][:foo] = [...]`).
3. Workflow tools from `LLM.workflow_tools(workflow)` and knowledge-base
   tools from `LLM.knowledge_base_tool_definition(knowledge_base)`.

The merged registry has the same shape everywhere in Scout-AI:

```ruby
{ "tool_name" => [executor, definition] }
```

See [../Tools/Tools.md](../Tools/Tools.md) for the full tool contract.

### 5.2 Workflow tools

If an Agent has a `workflow`, all exported tasks are exposed as callable
tools (when the backend supports function calling):

```ruby
agent = LLM::Agent.new(workflow: 'Baking', endpoint: :nano)
agent.start
agent.user "Bake muffins using the tool"
puts agent.chat
```

Internally `LLM.workflow_tools(workflow)` produces one tool definition per
task, and `LLM.process_calls` executes the tool via `LLM.call_workflow`.

### 5.3 KnowledgeBase tools

If an Agent has a `knowledge_base`, each database becomes a tool. For a
database named `brothers`, the model can call `brothers(entities: [...])`,
and (if the database has fields) `brothers_association_details`.

### 5.4 Inline workflow definition

If no workflow is provided, one is created lazily and can be defined inline:

```ruby
agent.workflow do
  task :hi => :string do |name = nil|
    "Hi #{name}"
  end
end
```

### 5.5 Tools from chat roles

Tools can also be declared through chat roles that are forwarded to the Chat
DSL — `tool:`, `introduce:`, `task:`, `association:`, `kb:`, `mcp:`. See
[../Chat/Chat.md](../Chat/Chat.md) for role syntax and
[../Tools/Tools.md](../Tools/Tools.md) for how they are compiled.

### 5.6 Workflows as toolkits (and "skills")

In Scout-AI a `Workflow` *is* the executable toolkit abstraction. If you come
from systems that talk about "skills", the closest equivalents are:

- a `Workflow` for executable capabilities,
- a `start_chat` file for instructions and examples,
- an optional `KnowledgeBase` for retrieval tools,
- an agent directory that bundles those pieces together.

A small agent directory plays the role of a skill package, but with stronger
typing and provenance because the executable part is a real Scout Workflow.

---

## 6. The `ask` method

`Agent#ask(messages = nil, options = {})` is the core inference entry point.

1. If `messages` is nil, uses `current_chat`.
2. If any message has `role: 'socialize'` with truthy content, calls
   `socialize` to wire up the generic `ask` tool for delegation.
3. Merges tools from the three layers above.
4. Picks one of two execution paths:
   - **Workflow path**: if the workflow defines an `:ask` task and the call
     doesn't disable it, dispatches through `workflow.job(:ask, chat: ...)`.
     This gains Scout job caching, provenance, and dependency tracking.
   - **Direct path**: otherwise calls `LLM.ask(messages, options)`.
5. Wraps everything in `begin/rescue`; if `process_exception` is a `Proc`, it
   is called with the exception and may trigger a `retry`.

Return value:

- **String** by default (the last assistant message content).
- **Message trace** (array of message hashes) when
  `options[:return_messages] == true`.

### `prompt(messages, options = {})`

Convenience: parses a string as chat-file syntax, prepends `start_chat`, then
calls `ask`:

```ruby
agent.prompt "user:\n\nHello"
# equivalent to: ask(Chat.follow(start_chat, LLM.chat("user:\n\nHello")))
```

---

## 7. The `chat` method

`Agent#chat(options = {})` is the high-level "stateful" call:

1. Calls `ask(current_chat, return_messages: true)`.
2. Appends the returned messages onto `current_chat`.
3. Returns the assistant answer text (or the message list if
   `return_messages: true` was passed).

```ruby
agent.start
agent.user "Tell me a joke"
joke = agent.chat        # appends the assistant reply to current_chat
agent.user "Now another"
agent.chat               # current_chat now has the full history
```

---

## 8. Structured outputs

### `json`

Sets the chat format to JSON, calls `chat`, parses the response, and restores
the format:

```ruby
agent.start
agent.user 'Return {"content": ["a","b"]}'
pp agent.json            # => {"content" => ["a", "b"]} or ["a", "b"] if unwrapped
```

If the returned JSON is exactly `{"content": ...}`, the helper returns the
inner `content`.

### `json_format(schema_hash)`

Requests a JSON response constrained by a schema (best supported by the
Responses backend):

```ruby
schema = {
  name: 'answer',
  type: 'object',
  properties: {
    judgement: { type: :boolean },
    notes:     { type: :string, default: "" }
  },
  required: [:judgement],
  additionalProperties: false
}

agent.start
agent.user "Is this funny?"
pp agent.json_format(schema)   # => {"judgement" => true, "notes" => "..."}
```

### `iterate(prompt = nil) { |item| ... }`

A structured-extraction loop: forces `endpoint :responses`, asks the model to
return a JSON object of shape `{ "content": [string, ...] }`, then yields each
string to the block, and resets `format` back to `:text`.

```ruby
agent = LLM.agent
agent.iterate("List 3 next actions") do |action|
  puts "- #{action}"
end
```

### `iterate_dictionary(prompt = nil) { |k, v| ... }`

Same idea, but the schema is a flat object whose values are strings:

```ruby
agent.iterate_dictionary("Return a dict of tool_name => what it does") do |name, desc|
  puts "#{name}: #{desc}"
end
```

---

## 9. Error handling

Set `agent.process_exception` to a `Proc` to intercept exceptions raised
during `ask`/`chat`. If the Proc returns truthy, the call is retried:

```ruby
agent.process_exception = Proc.new do |exception|
  if exception.message =~ /rate limit/i
    sleep 5
    true              # retry
  else
    false             # re-raise
  end
end
```

The Proc receives the exception object. This is the main hook for custom
retry/backoff policies on top of whatever the backend itself provides.

---

## 10. Loading an Agent

### `LLM::Agent.load_agent(name, options = {})`

Resolution order (first match wins):

1. **Direct file path.** If `name` is a filename:
   - A directory containing `agent.rb` → loads that file.
   - A `.rb` file → loads it directly.
2. **Named agent discovery** (when `name` is a name string), checking in order:
   - `Scout.workflows[name]`
   - `Scout.Agent[name]`
   - `Scout.var.Agent[name]`
   - `Scout.chats.Agent[name]`
   - `Scout.chats[name]`
3. **Workflow resolution**: if a workflow directory exists, loads
   `workflow.rb`; if `python/*.py` exists, loads them as a Python workflow.
4. **KnowledgeBase resolution**: `knowledge_base/` subdirectory is loaded via
   `KnowledgeBase.load`.
5. **Start chat resolution**: `start_chat` file (Scout chat-file syntax); if
   absent but a workflow exists, seeds with an `introduce: <workflow>` message.

### Agent directory layout

```
<agent_dir>/
  agent.rb          # Ruby file defining/returning an Agent (optional)
  workflow.rb       # Scout Workflow definition (optional)
  knowledge_base/   # KnowledgeBase directory (optional)
  start_chat        # Initial chat in Scout chat-file syntax (optional)
  python/           # Python workflow tasks (*.py) (optional)
```

If `workflow.rb` is absent but `python/*.py` exists, Scout-AI auto-loads those
files through `PythonWorkflow.load_directory(..., 'ScoutAgent')` and treats
them as workflow tasks. See [Python.md](Python.md) for the full guide.

---

## 11. Workflow-provided `ask` task

If the Agent's workflow defines a task named `ask`, `Agent#ask` can delegate
the entire LLM interaction to that workflow task:

```ruby
# Inside a chat_task definition, the workflow owns the control loop
chat_task :ask do
  agent = self.agent(nil, chat: chat)
  # ... custom multi-step control loop ...
end
```

The Agent passes `chat: Chat.print(messages)` as input; the workflow task can
implement custom control loops, custom tool execution, and multi-agent
patterns. This is the main Scout-AI escape hatch for strategies like
intake → plan → execute → review, validation chains, or artifact-first
multi-agent collaboration.

See [AgentWorkflow.md](AgentWorkflow.md) for the `chat_task` DSL and
[Delegation.md](Delegation.md) for `socialize`/`delegate` semantics.

---

## 12. Factory shortcut

`LLM.agent(...)` is a thin alias for `LLM::Agent.new(...)`:

```ruby
agent = LLM.agent(endpoint: :nano, workflow: 'Baking')
agent = LLM.agent(endpoint: :ollama, model: 'llama3.1')
```

---

## 13. CLI integration

Agents are primarily used from:

```bash
scout-ai agent ask <agent_name> your question
scout-ai agent ask -c my.chat <agent_name> continue this conversation
```

The question does not need to be in quotes. See
[../Commands/Commands.md](../Commands/Commands.md) for the full CLI reference.
