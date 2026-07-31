# Design Principles

This document explains the coding philosophy and idioms that make Scout-AI
elegant and expressive. It is intended for framework contributors who want to
write code that fits the existing style.

> For detailed examples and analysis of idiomatic vs. non-idiomatic patterns,
> see [../../research/coding-philosophy-analysis.md](../../research/coding-philosophy-analysis.md).

---

## Abstraction-first

Every concept in Scout-AI is an abstraction with a crisp boundary:

- A **Chat** is "a conversation."
- An **Agent** is "a stateful conversation holder with tools."
- A **Backend** is "an adapter to a model API."
- A **Tool** is "a callable function exposed to the model."

New features should be expressed as a new abstraction or an extension of an
existing one, not as inline logic scattered across files. The question is
always: *what abstraction does this feature belong to?*

---

## Module composition over inheritance

Scout-AI avoids deep class hierarchies. Behavior is composed through Ruby
modules:

```ruby
# Agent's behavior is split across multiple files that reopen the class:
#   lib/scout/llm/agent.rb          — core (ask, prompt, workflow)
#   lib/scout/llm/agent/chat.rb     — chat management
#   lib/scout/llm/agent/iterate.rb  — iteration patterns
#   lib/scout/llm/agent/delegate.rb — multi-agent delegation
#   lib/scout/llm/agent/workflow.rb — AgentWorkflow mixin + chat_task DSL
```

Each module adds a cohesive set of methods to the same class. There is no
inheritance tree — just flat composition. This keeps each concern in its own
file while sharing `@other_options`, `@current_chat`, etc.

---

## Chat-as-data (annotate, don't wrap)

The single most important design decision:

> **A Chat is a plain `Array` of message `Hash`es, not an opaque object.**

The `Chat` module uses scout-essentials' `Annotation` system to add DSL methods
to a plain Array **non-invasively**:

```ruby
chat = Chat.setup([])
chat.user("Hello")

chat.class            # => Array (still an Array!)
chat.first[:role]     # => "user"
chat.select { |m| m[:role] == 'system' }  # standard Array operations work
```

The annotation:
- Adds methods to the **singleton class** of the specific object instance.
- Does **not** change the object's class.
- Is **removable** via `Annotation.purge(obj)`.

**Implication:** Don't create wrapper classes for data that is already a Hash
or Array. Annotate it instead.

---

## Convention over configuration

Scout-AI discovers components by convention rather than registration:

| Convention | Resolution |
|---|---|
| Agent directory `Agent/<Name>/` | Auto-discovered via `Scout.Agent`, `Scout.chats.Agent`, etc. |
| `start_chat` file | Loaded as initial conversation. |
| `workflow.rb` | Loaded as the agent's workflow. |
| `knowledge_base/` | Loaded as the agent's KB. |
| `python/*.py` | Loaded as Python-backed tools. |

There are no registration calls or plugin manifests. Put files in the right
place and they are found.

---

## The DSL pattern

Scout-AI builds expressive domain-specific languages on top of Ruby's
flexibility:

### Chat DSL

```ruby
chat = Chat.setup([])
chat.system("You are a helpful assistant")
chat.user("What is 2+2?")
chat.option(:model, "gpt-4")
chat.ask  # → "4"
```

### Agent DSL (via method_missing proxy)

```ruby
agent = LLM.agent(model: "gpt-4")
agent.system("You are a coder")
agent.user("Write a function")
agent.chat
```

The `method_missing` proxy on Agent forwards unknown methods to
`current_chat`, so all Chat methods work directly on the Agent.

### Workflow DSL (chat_task)

```ruby
module MyPipeline
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :my_task do
    agent = self.agent :Worker, chat: chat
    agent.user "Do something"
    agent
  end
end
```

---

## Lazy initialization

Many things are initialized on first use, not eagerly:

```ruby
def workflow(&block)
  @workflow ||= begin
    m = Module.new
    m.extend Workflow
    m.name ||= 'ScoutAgent'
    m.tasks = {}
    m
  end
end

def current_chat
  @current_chat ||= start
end
```

This keeps object creation cheap and defers expensive setup until needed.

---

## IndiferentHash everywhere

Options and metadata use Scout's `IndiferentHash` (symbol/string-indifferent
access):

```ruby
options[:model]   # works
options['model']  # also works
```

This eliminates a whole class of symbol-vs-string bugs. When building option
hashes, use `IndiferentHash.setup(hash)` rather than a plain Hash.

---

## Idiomatic patterns to follow

### Use `Chat.setup` not `Chat.new`

```ruby
# Good
chat = Chat.setup([])

# Wrong — Chat is a module, not a class
chat = Chat.new   # NoMethodError
```

### Prefer annotation forwarding over explicit wrappers

```ruby
# Good — Agent forwards to Chat via method_missing
agent.user("hello")

# Wrong — don't write explicit delegation methods
def agent_user(agent, msg)
  agent.current_chat.user(msg)
end
```

### Use `Chat.follow` to compose conversations

```ruby
# Good — follow prepends context
chat.follow(step(:plan).load)

# Avoid — manual concatenation loses annotations
chat = step(:plan).load + chat
```

### Prefer `proc` blocks for tools

```ruby
# Good — Proc-based tool
LLM.add_tool(
  "my_tool",
  "Does something useful",
  {"type" => "object", "properties" => {...}}
) do |name, params|
  # tool implementation
end
```

---

## Anti-patterns to avoid

1. **Creating wrapper classes for Arrays/Hashes** — Annotate instead.
2. **Adding provider-specific logic to `LLM.ask`** — Put it in the Backend module.
3. **Deep inheritance hierarchies** — Use module composition.
4. **Eager initialization** — Use lazy `||=`.
5. **Explicit delegation methods when `method_missing` already works** — Agent
   already forwards to Chat; don't add `agent_user`, `agent_system`, etc.
6. **Mutating the stored chat during prompt preparation** — Prompt strategies
   are ephemeral; never mutate the source.
7. **Using `Marshal.dump/load` for deep copying** — Procs can't be marshalled;
   use `social_duplicate` patterns.
8. **Hard-coding agent names in delegation logic** — Let the model choose via
   `socialize`, or use `delegate` with explicit instances.

---

## Cross-references

- [Architecture.md](Architecture.md) — Overall system architecture.
- [ChatLifecycle.md](ChatLifecycle.md) — Chat data model.
- [../../research/coding-philosophy-analysis.md](../../research/coding-philosophy-analysis.md) — Deep investigation.
