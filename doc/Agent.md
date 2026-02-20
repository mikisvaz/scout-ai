# Agent

`LLM::Agent` is the stateful wrapper around `LLM.ask` + `Chat`.

Use an Agent when you want **one or more ongoing conversations** (state), plus:

- a consistent place to store default LLM options (`endpoint`, `model`, `backend`, `format`, …)
- automatic tool wiring from:
  - a **Workflow** (tasks as function tools)
  - a **KnowledgeBase** (databases as function tools)
- a convenient Ruby API for structured outputs (`json_format`, `iterate`, `iterate_dictionary`)
- optional delegation to other agents (multi-agent control loops)

Related docs:

- `doc/LLM.md` — `LLM.ask`, endpoints/backends, tool calling
- `doc/Chat.md` — chat file roles/options (including `tool`, `task`, `mcp`, `previous_response_id`)

---

## 1. Quick start

### 1.1 Minimal stateful conversation

```ruby
require 'scout-ai'

agent = LLM::Agent.new(endpoint: :nano)
agent.start_chat.system "You are a helpful assistant"

agent.start          # create a new conversation branch
agent.user "Say hi"  # append to current_chat
puts agent.chat      # ask + append assistant reply
```

### 1.2 Factory shortcut

```ruby
agent = LLM.agent(endpoint: :ollama, model: 'llama3.1')
```

---

## 2. Conversation lifecycle

Agents maintain two chats:

### `start_chat`

The “base” chat.

- It is where you put messages that should always be present (system policy, examples, shared context).
- It is **not automatically sent** unless you create a current chat from it via `start`.

### `start(chat=nil)`

- `start()` with no argument:
  - branches `start_chat` (non-destructive copy)
  - stores it as `current_chat`
- `start(chat)` with a `Chat` or `Array`:
  - adopts that as the `current_chat`

### `current_chat`

The active conversation.

### Common pitfall

If you call `agent.ask(...)` directly with your own messages array, the Agent will not automatically prepend `start_chat`. The simplest “normal” pattern is:

```ruby
agent.start
agent.user "..."
agent.chat
```

---

## 3. Agent forwards the Chat DSL

`LLM::Agent` forwards unknown methods to `current_chat` (via `method_missing`).

So you can use the chat builder methods directly:

```ruby
agent.system "You are a domain expert"
agent.user "Summarize this file"
agent.file "paper.md"
agent.image "figure.png"
agent.pdf "supplement.pdf"
```

All the special chat-file roles described in `doc/Chat.md` work the same way from an Agent: `import`, `continue`, `tool`, `task`, `mcp`, etc. These use the `message` builder, which is a more general way to add messages to the chat. These are equivalent:

```ruby
agent.pdf "supplement.pdf"
agent.message :pdf, "supplement.pdf"
```
---

## 4. Tool wiring (Workflow + KnowledgeBase)

### 4.1 Workflow tools

If an Agent has a `workflow`, all exported tasks are exposed as callable tools when the model supports function calling.

```ruby
agent = LLM::Agent.new(workflow: 'Baking', endpoint: :nano)
agent.start
agent.user "Bake muffins using the tool"
puts agent.chat
```

Internally:

- `LLM.workflow_tools(workflow)` produces one tool definition per task.
- When the model calls a function, `LLM.process_calls` executes it via `LLM.call_workflow`.

### 4.2 KnowledgeBase tools

If an Agent has a `knowledge_base`, each database is exposed as a callable tool.

- For a database `brothers`, the model can call `brothers(entities: [...])`.
- If the database has fields, an additional tool `brothers_association_details` is exposed.

### 4.3 Tool merging rules (important nuance)

Tools come from multiple places:

1) tools passed to `ask(..., tools: ...)`
2) tools stored in `agent.other_options[:tools]`
3) tools auto-exported from `workflow` / `knowledge_base`

The Agent merges them roughly as:

- start with `options[:tools]` (or `{}`)
- merge `other_options[:tools]`
- merge workflow and knowledge base tools

If the same tool name appears multiple times, later merges override earlier ones.

---

## 5. Asking vs chatting

### `ask(messages, options={})`

Low-level: calls `LLM.ask(...)` with Agent defaults merged.

- returns a **string** by default
- returns a **message trace** if `return_messages: true`

### `chat(options={})`

High-level “stateful” method:

- calls `ask(current_chat, return_messages: true)`
- appends returned messages onto `current_chat`
- returns the assistant content (the last assistant message)

---

## 6. Structured outputs

### `json`

Sets chat format to JSON and parses the response:

```ruby
agent.start
agent.user "Return {\"content\": [\"a\",\"b\"]}"
pp agent.json
```

If the returned JSON is exactly `{"content": ...}`, the helper returns the inner `content`.

### `json_format(schema_hash)`

Requests a JSON response constrained by a schema (supported best by the Responses backend).

```ruby
schema = {
  name: 'answer',
  type: 'object',
  properties: {
    judgement: { type: :boolean },
    notes: { type: :string, default: "" }
  },
  required: [:judgement],
  additionalProperties: false
}

agent.start
agent.user "Is this funny?"
pp agent.json_format(schema)
```

---

## 7. Iteration helpers (programmatic control loops)

These helpers are designed for “agentic scripts” where you want the model to produce a list/dictionary and then iterate in Ruby.

### `iterate(prompt=nil) { |item| ... }`

- forces `endpoint :responses`
- requests JSON schema `{content: [string, ...]}`
- yields each item
- resets `format` back to `:text`

```ruby
agent = LLM.agent
agent.iterate("List 3 next actions") do |action|
  puts "- #{action}"
end
```

### `iterate_dictionary(prompt=nil) { |k,v| ... }`

- requests a JSON object whose values are strings (`additionalProperties: {type: :string}`)

```ruby
agent.iterate_dictionary("Return a dict of tool_name => what it does") do |name, desc|
  puts "#{name}: #{desc}"
end
```

---

## 8. Delegation (multi-agent wiring)

`Agent#delegate` registers another agent as a **tool**.

The tool name becomes:

```text
hand_off_to_<name>
```

The default schema expects:

- `message` (required)
- `new_conversation` (optional, default false)

Example:

```ruby
joker = LLM.agent(endpoint: :nano)
joker.start_chat.system "You only answer with knock knock jokes"

judge = LLM.agent(endpoint: :nano, format: { judgement: :boolean })
judge.start_chat.system "Judge if a joke is funny"

supervisor = LLM.agent(endpoint: :nano)
supervisor.start_chat.system "Use delegated agents to do the work"

supervisor.delegate(joker, :joker, "Generate jokes")
supervisor.delegate(judge, :judge, "Evaluate jokes")

supervisor.start
supervisor.user "Try up to 5 jokes until judged funny"
puts supervisor.chat
```

---

## 9. Loading an Agent (agent directories)

Agents can be loaded by name or from a directory.

### `LLM::Agent.load_agent(name)`

Resolution logic (simplified):

- if `name` is a path:
  - if it is a directory with `agent/*.rb` it loads that script
  - otherwise it loads the directory as an agent directory
- otherwise it looks under the standard Scout paths:
  - workflows (`Scout.workflows[name]`)
  - agent dirs (`Scout.var.Agent[name]`)
  - chat dirs (`Scout.chats[name]`)

### Agent directory layout

If you create an agent directory, these files are detected automatically:

```text
<agent_dir>/workflow.rb        # optional
<agent_dir>/knowledge_base/    # optional
<agent_dir>/start_chat         # optional chat file
```

If `start_chat` is not present but a workflow exists, the Agent will create a base chat containing an `introduce: <workflow>` message (workflow documentation injected).

---

## 10. Advanced: workflow-provided `ask` task

If the Agent’s workflow defines a task named `ask`, `Agent#ask` can delegate the entire LLM interaction to that workflow task:

- the Agent passes `chat: Chat.print(messages)` as input
- the workflow task can implement a custom control loop, custom tool execution, etc.

This is an escape hatch for “agent frameworks built as workflows”.

---

## 11. Error handling

Set `agent.process_exception` to a Proc to intercept exceptions raised during ask/chat.

If the Proc returns truthy, the call is retried.

---

## 12. CLI integration

Agents are primarily used from:

```bash
scout-ai agent ask <agent_name> your question
scout-ai agent ask -c my.chat <agent_name> continue this conversation
```

Note how the question does not need to be in quotes.

See `doc/Chat.md` for chat file roles and `doc/LLM.md` for endpoint configuration.
