# Building Agents

This page explains how to create, configure, and use agents in Scout-AI. It is
intended for workflow authors who want to build reusable, stateful AI
assistants with tools and delegation.

**You should read this if:** you understand chats and want to take the next
step to persistent, tool-using agents.

---

## What an agent is

An agent is a **stateful wrapper** around a chat. It remembers:

- **A start chat** — the system prompt and initial context that prefix every
  conversation.
- **Tools** — workflows, knowledge bases, and MCP servers the agent can call.
- **Options** — which endpoint and model to use, output format, etc.

You interact with an agent through a DSL that feels like building a chat: you
add messages, call `chat` to get a response, and the agent maintains the
conversation history for you.

---

## Creating an agent in Ruby

The simplest way is the `LLM.agent` factory:

```ruby
require 'scout-ai'

agent = LLM.agent(endpoint: :openai)
```

### Setting the system prompt

The system prompt lives on `start_chat`:

```ruby
agent.start_chat.system "You are a helpful assistant that answers concisely."
```

### Starting a conversation

Call `start` to create a new conversation branch:

```ruby
agent.start
```

### Adding messages

Use role methods (forwarded to the underlying chat):

```ruby
agent.user "What is the capital of France?"
```

### Getting a response

Call `chat` to send the conversation to the model and get a response:

```ruby
puts agent.chat   # => "Paris"
```

`chat` appends the model's response to the conversation, so subsequent calls
have full history:

```ruby
agent.user "And its population?"
puts agent.chat   # => "Approximately 2.2 million in the city proper."
```

---

## Agent as a named directory

Instead of configuring an agent in Ruby, you can define it as a directory:

```
Agent/
  Researcher/
    start_chat        # system prompt + tool declarations
    workflow.rb       # optional: Scout workflow providing tools
    knowledge_base/   # optional: KB for retrieval
    python/           # optional: Python workflow tasks
```

### The start_chat file

This is a chat file (see [WritingChats.md](WritingChats.md)) containing the
system prompt and any initial configuration:

```text
system:

You are a research assistant. Use the search tool to find information.
Always cite your sources.

endpoint: anthropic
model: claude-sonnet-4-20250514

introduce: SearchWorkflow
```

### Loading and using a named agent

From Ruby:

```ruby
agent = LLM.load_agent('Researcher')
agent.start
agent.user "Find papers about protein folding."
puts agent.chat
```

From the CLI:

```bash
scout-ai agent ask Researcher "Find papers about protein folding."
```

### Agent discovery locations

Scout-AI looks for named agents in several places (first match wins):

1. `Scout.workflows[name]`
2. `Scout.Agent[name]`
3. `Scout.var.Agent[name]`
4. `Scout.chats.Agent[name]`
5. `Scout.chats[name]`

---

## Giving agents tools

### Workflow tools

If your agent has a workflow, all its tasks become callable tools:

```ruby
agent = LLM::Agent.new(workflow: 'Baking', endpoint: :openai)
agent.start
agent.user "Bake muffins using the tool"
puts agent.chat   # the model calls the 'bake' task automatically
```

You can also define a workflow inline:

```ruby
agent.workflow do
  task :greet => :string do |name = nil|
    "Hello, #{name}!"
  end
end
```

### Declaring tools in the start chat

Use `tool:` or `introduce:` roles in the start_chat file:

```text
system:

You are a code analyst.

introduce: CodeAnalyzer
```

### Knowledge base and MCP tools

```text
kb: my_database [genes proteins]
mcp: https://api.example.com/mcp/
```

See [ToolCalling.md](ToolCalling.md) for the complete tool declaration syntax.

---

## Options

Options control which endpoint, model, and format the agent uses. Set them
at construction:

```ruby
agent = LLM.agent(endpoint: :anthropic, model: 'claude-sonnet-4-20250514')
```

Or through the DSL:

```ruby
agent.option :model, 'gpt-4o'
agent.option :temperature, 0.7
```

Common options:

| Option | Purpose |
|--------|---------|
| `endpoint:` | Named endpoint configuration |
| `model:` | Model identifier |
| `format:` | Output format (`:json`, `:text`, or a JSON schema hash) |
| `persist:` | Whether to cache inference results (default `true`) |

---

## Structured outputs

### JSON extraction

```ruby
agent.start
agent.user 'Return {"content": ["apple", "banana", "cherry"]}'
result = agent.json   # => ["apple", "banana", "cherry"]
```

### JSON with a schema

```ruby
schema = {
  name: 'answer',
  type: 'object',
  properties: {
    judgement: { type: :boolean },
    notes:     { type: :string }
  },
  required: [:judgement]
}

agent.json_format(schema)
```

### Iteration helpers

`iterate` extracts a list from the model and processes each item:

```ruby
agent.iterate("List 3 action items") do |action|
  puts "- #{action}"
end
```

---

## Error handling

Set a `process_exception` callback to intercept errors during inference:

```ruby
agent.process_exception = Proc.new do |exception|
  if exception.message =~ /rate limit/i
    sleep 5
    true   # retry
  else
    false  # re-raise
  end
end
```

---

## Common mistakes

- **Forgetting to call `start`**: Without `start`, messages go to a lazy
  default branch. Calling `start` explicitly makes the lifecycle clear.
- **Putting user messages on `start_chat`**: `start_chat` is the *seed* — it
  should contain system prompts and configuration, not the actual question.
- **Expecting `ask` to append to the conversation**: Use `chat` for the
  stateful pattern (ask + append + return text). `ask` is the lower-level
  primitive.
- **Defining wrapper methods on Agent**: The agent forwards unknown methods
  to its chat automatically. You don't need to write wrappers.

---

## Next steps

- [ToolCalling.md](ToolCalling.md) — detailed tool configuration.
- [Delegation.md](Delegation.md) — multi-agent systems.
- [RunningInference.md](RunningInference.md) — endpoint configuration.
- [MultiAgentWorkflows.md](MultiAgentWorkflows.md) — orchestrating agents in
  Scout workflows.
