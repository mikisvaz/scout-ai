# Design Principles

This document explains the coding philosophy and idioms that make Scout-AI
elegant and expressive. It is intended for framework contributors who want to
write code that fits the existing style.

> This page is the normative summary of the coding philosophy; every rule here
> is self-contained and no external investigation is needed to apply it.

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

Scout-AI avoids deep class hierarchies, and the dependency direction stays
one-way — Agent → Chat → Annotation; backends depend on Chat (through
`Backend::ClassMethods`) but never on Agent, and `AgentWorkflow` depends on
Agent and Chat but not on any particular backend.

Behavior is composed through Ruby modules:

```ruby
# Agent's behavior is split across multiple files that reopen the class:
#   lib/scout/llm/agent.rb          — core (ask, prompt, workflow)
#   lib/scout/llm/agent/chat.rb     — chat management
#   lib/scout/llm/agent/iterate.rb  — iteration patterns
#   lib/scout/llm/agent/delegate.rb — multi-agent delegation
#   lib/scout/llm/agent/conversation.rb — conversation save/load
#   lib/scout/llm/agent/attach.rb     — attachment tool wiring
#   lib/scout/llm/agent/save.rb       — persisted conversation files
#   lib/scout/llm/agent/workflow.rb — AgentWorkflow mixin + chat_task DSL
```

Each module adds a cohesive set of methods to the same class. There is no
inheritance tree — just flat composition. This keeps each concern in its own
file while sharing `@other_options`, `@current_chat`, etc.

Modules also serve double duty as **namespace and mixin** at the same time:
`LLM` is both the entry point namespace (`LLM.ask`, `LLM.chat`,
`LLM.load_agent`) and the host of `LLM::Backend::ClassMethods`, the mixin that
every provider adapter includes into its singleton class. When adding a
subsystem, keep the same split: namespace at the top, behaviour as a nested
`ClassMethods`-style mixin so other modules can compose it.

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
- Is **removable**: `Annotation.purge(obj)` returns a plain duplicate with the
  annotation instance variables stripped (recursively for nested Arrays/Hashes).
- Records the applied annotations in `annotation_types`.

The pattern is not Chat-specific: `Step` annotates a path `String` with job
metadata the same way. Annotating is the house style for "attach rich behaviour
to plain data".

**Implication:** Don't create wrapper classes for data that is already a Hash
or Array. Annotate it instead. Because a chat stays a plain Array it is
serializable to the `.chat` text format, composable by concatenation,
introspectable with ordinary Array/Hash operations, and cacheable by
`Persist.persist` hashing the message array.

---

## Convention over configuration

Scout-AI discovers components by convention rather than registration:

| Convention | Resolution |
|---|---|
| Agent directory `Agent/<Name>/` | Auto-discovered via `Scout.Agent`, `Scout.chats.Agent`, etc. |
| `agent.rb` | `load`-ed; its last expression must be an `Agent`. |
| `start_chat` file | Loaded as initial conversation. |
| `workflow.rb` | Loaded as the agent's workflow. |
| `knowledge_base/` | Loaded as the agent's KB. |
| `python/*.py` | Loaded as Python-backed tools. |
| Endpoint file `etc/AI/<name>.yaml` | Merged as option defaults when `endpoint: <name>` is used. |

There are no registration calls or plugin manifests. Put files in the right
place and they are found. The one deliberate exception is backends: a new
provider is registered explicitly with `LLM.register_backend(name, mod)` (or
added to the `case` in `LLM.ask`), because nothing about a module name tells
the dispatcher where to find it.

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

Because the DSL is just methods on a module, extending it is reopening the
module — a new role or convenience method added to `Chat` is immediately
available on every annotated Array and, through the proxy, on every Agent:

```ruby
module Chat
  def screenshot(file)
    message(:image, file)
  end
end
```

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

`self.include_workflow AgentWorkflow` is required: `extend Workflow` alone does
not define `chat_task`, and the helpers the mixin adds (`helper :agent`,
`helper :log_agent`) only reach the module through `include_workflow`.

### Backend composition DSL

```ruby
module LLM
  module MyProviderMethods
    def query(client, messages, tools = [], parameters = {})
      # override: translate messages/tools to the provider call
    end
  end

  module MyProvider
    TAG = 'myprovider'
    DEFAULT_MODEL = 'my-model-v1'

    class << self
      prepend MyProviderMethods        # overrides, dispatched first
      include Backend::ClassMethods    # shared ask/embed loop
    end
  end
end
```

The prepend runs before the included base, so `Backend::ClassMethods#ask` can
call `query` and reach the provider override. A new backend is dispatched by a
`case` branch in `LLM.ask` or `LLM.register_backend(:myprovider, MyProvider)`.
Every adapter also exposes `TAG` and `DEFAULT_MODEL` constants; name-based
module resolution is deliberately absent, so an unregistered name is an
`Unknown backend` error rather than a guessed constant.

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

The same library carries the option idioms used throughout the codebase:
`IndiferentHash.add_defaults(hash, defaults)` fills missing keys without
overwriting, `process_options(hash, :a, :b)` extracts and removes several keys
in one call, and `IndiferentHash.parse_options("model=x backend=y")` turns a
`key=value` string into a hash. `Scout::Config.get(:key, *tokens, env:,
default:)` resolves configuration through the same cascade: explicit option →
environment variable → config file tokens → default.

API keys ride the same cascade rather than being read by the provider gems'
own env vars: each adapter looks its `key` up through `Scout::Config.get` with
its `TAG` token (`OPENAI_KEY`/`ANTHROPIC_KEY`/…). Exporting
`OPENAI_API_KEY` alone configures nothing — set `<TAG>_KEY` or put `key:` in
the endpoint YAML.

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

### Branch before diverging

`chat.branch` returns an annotated duplicate of the conversation, so an
exploration can run without mutating the original — the cheap way to try two
prompt variants off the same history.

```ruby
variant = chat.branch
variant.system("Answer in one word")
```

### Prefer `proc` blocks for tools

```ruby
# Good — a Proc executor paired with an LLM.tool_definition schema
block = ->(name, params) { ... }   # receives (tool_name, arguments)
definition = LLM.tool_definition(
  'my_tool', 'Does something useful',
  { query: { type: 'string' } }, required: [:query]
)
agent.other_options[:tools]['my_tool'] = [block, definition]  # [executor, definition]
```

The registry entry is always the pair `[executor, definition]`; a `Proc`
executor is the plainest kind and is what the agent-layer tools (`attach`,
`ask`, `hand_off_to_*`) use.

Note the merge order the agent applies: per-call `options[:tools]` is merged
over the agent's construction-time tools, and the auto-wired workflow and
knowledge-base tools are merged **last**, so a name you register explicitly
wins over an auto-generated one with the same name.

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
9. **Treating a `false` option as "unset"** — `opt ||= default` silently
   discards an explicit `false`. Use `opt = default if opt.nil?` when the
   caller must be able to opt out (this bit `persist: false`).
10. **Adding a new backend through name-mangling** — `LLM::BACKENDS` +
    `LLM.register_backend(name, mod)` is the only extension seam; an
    unregistered symbol raises, it is not resolved as a module name.
11. **Scattering file I/O on plain Strings** — Use `Path` for anything that
    participates in Scout's path system (`Scout.var`, `Scout.chats`,
    `.find`, `.exists?`) and `Open` for reads/writes and `Open.remote?`, so
    the same code works from a workflow job, the CLI, and an agent society.
12. **Parsing chat text yourself** — a new role belongs in the Chat annotation
    module (plus `chat/parse.rb` / `chat/process/` if it needs compilation
    rules); ad-hoc regex rewriting of message content bypasses the pipeline.
13. **Reimplementing what scout-essentials ships** — `TSV.traverse` for
    parallel iteration over a TSV (or any index), `Open.remote?` for URL
    checks, `Persist.persist` for the compute-once cache. Writing a local
    replacement duplicates a battle-tested path system.
14. **Reading a plain `Hash` of user options with symbol keys** — `options[:model]`
    misses a caller's `'model'`. `IndiferentHash.setup` any hash that came
    from user input, parsed JSON, or kwargs before reading it.
15. **Mixing a class-state mixin with plain `include`** — `include_workflow`
    merges helpers and task state into the receiving Workflow module; a plain
    `include` copies no class-level state, so `self.agent`/`self.chat` are
    missing at run time even though the file loads.

---

## File and method naming

File paths mirror module nesting: `LLM::Agent` lives in
`lib/scout/llm/agent.rb`, and a behavior extension of the same class lives in
`lib/scout/llm/agent/<aspect>.rb` (`agent/delegate.rb`, `agent/conversation.rb`).
Annotation bodies sit in `<name>/annotation.rb`, per-aspect chat processing
in `chat/process/<aspect>.rb`, and provider adapters in
`backends/<provider>.rb`. Agent directory files are lowercase and
extension-free except `workflow.rb` and `agent.rb`.

Method names follow the role they play: DSL actions are verbs
(`user`, `system`, `ask`, `follow`), queries are nouns or predicates
(`current_chat`, `answer`, `exists?`), Workflow helpers are declared with
`helper :name do ... end`, predicates end in `?` (`exists?`, `remote?`,
`is_filename?`), and the `setup` class method always means "annotate this
plain object" (`Chat.setup`, `IndiferentHash.setup`).

Variable names carry the same conventions: `messages`/`chat` for conversation
arrays, `options` (always an `IndiferentHash`) for option hashes,
`path`/`dir`/`file` for `Path` objects, and `agent` for `LLM::Agent`
instances.

---

## The Scout-AI coding mindset

1. **Data is plain.** Chats are Arrays, options are Hashes. Annotate, don't wrap.
2. **Compose, don't inherit.** Use modules, `extend`, `include`, `prepend`.
3. **One abstraction, one responsibility.** Chat holds conversation. Agent
   holds state. Backend adapts to a provider. Tools define callable actions.
4. **Convention discovers.** Directory structures and file names are the registry.
5. **DSLs are methods on annotated objects.** Add methods to modules, get them
   everywhere through annotation and `method_missing`.
6. **Use the full stack.** `IndiferentHash` for options, `Path` for files,
   `Scout::Config` for configuration, `Persist` for caching, `Log` for
   logging. Don't reimplement.
7. **Keep it serializable.** Everything can be written to disk and read back.
   This is a feature, not a limitation.
8. **Small files, clear boundaries.** `agent.rb` → `agent/chat.rb` →
   `agent/delegate.rb`. Each file adds one concern.
9. **Treat `false` as a value, not as "unset"** (see the anti-pattern list).
10. **Derive, don't transcribe.** When a number or a claim can be produced by
    code, make the code produce it and cite the job that produced it —
    transcribed numbers rot and cannot be audited.

The guiding question when writing Scout-AI code: *can this be expressed as a
composition of existing abstractions, or does it need a new one — and if new,
is its boundary crisp?*

---

## Cross-references

- [Architecture.md](Architecture.md) — Overall system architecture.
- [ChatLifecycle.md](ChatLifecycle.md) — Chat data model.
