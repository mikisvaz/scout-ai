> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# Scout-AI Coding Philosophy & Idioms

> **Purpose:** Enable coding agents (and humans) to write code that fits the
> existing Scout-AI style. This document is a field guide to the abstractions,
> design principles, Ruby idioms, naming conventions, and anti-patterns that
> make the codebase elegant and expressive.

---

## 1. Core Abstractions

Scout-AI is built from a small number of composable abstractions. Each one
plays a single, well-defined role. Understanding how they compose is the key
to extending the library.

### 1.1 The six pillars

| Abstraction             | Module / Class        | File                             | Role                                                                                          |
|-------------------------|-----------------------|----------------------------------|-----------------------------------------------------------------------------------------------|
| **Chat**                | `Chat` (Annotation)   | `lib/scout/llm/chat.rb` + `chat/`| A conversation: a plain `Array` of message `Hash`es, annotated with rich DSL methods.         |
| **Agent**               | `LLM::Agent`          | `lib/scout/llm/agent.rb` + sub-files | Stateful wrapper around a Chat with a start_chat, a workflow, knowledge bases, tool wiring, and delegation. |
| **AgentWorkflow**       | `AgentWorkflow` mixin | `lib/scout/llm/agent/workflow.rb`| A `Workflow` mixin that adds `chat_task`, `helper :agent`, and `helper :log_agent` for multi-agent strategies encoded as Scout workflows. |
| **Backend**             | `LLM::Backend` + per-backend modules | `lib/scout/llm/backends/`    | Adapter to a specific LLM provider (OpenAI, Anthropic, Ollama, etc.). Shares logic via `Backend::ClassMethods` and overrides via `prepend`. |
| **Tools**               | `LLM` module methods  | `lib/scout/llm/tools/`           | Definition and execution of callable tools: workflow tasks, knowledge-base queries, MCP servers, code execution. |
| **Annotation**          | `Annotation` (from scout-essentials) | `lib/scout/annotation.rb` | Non-invasive metadata injection onto existing objects (Arrays, Hashes, etc.) without subclassing or wrapping. Chat uses this to add DSL methods to a plain Array. |

### 1.2 How they compose

```
                     ┌─────────────────────────────────────────────┐
                     │                  LLM (module)                 │
                     │  LLM.ask  ← entry point for all inference     │
                     │  LLM.chat ← parse/compile chat files          │
                     │  LLM.load_agent ← resolve agent directories    │
                     └───────────────┬───────────────────────────────┘
                                     │
                 ┌───────────────────┼───────────────────────┐
                 ▼                   ▼                       ▼
           ┌──────────┐       ┌──────────────┐       ┌──────────────┐
           │ Backend  │       │  LLM::Agent  │       │    Tools     │
           │ adapter  │       │ (stateful)   │       │ (WF/KB/MCP)  │
           └──────────┘       └──────┬───────┘       └──────┬───────┘
                                    │ holds                │
                              ┌─────▼─────┐          ┌──────▼──────┐
                              │   Chat    │◄────────►│  Workflow   │
                              │ (Array +  │  task    │  tasks as   │
                              │  DSL)     │  tools   │  tools      │
                              └───────────┘          └─────────────┘
                                    │ extends
                              ┌─────▼─────┐
                              │ Annotation│ (non-invasive mixin)
                              └───────────┘
```

In words:

1. **`LLM.ask`** is the universal entry point. It accepts any string, file, or
   Array of Hashes, compiles it via `Chat`, resolves options, selects a
   `Backend`, and returns the response as a `Chat` (annotated Array).
2. **`LLM::Agent`** wraps a `Chat` with persistent state (start_chat,
   current_chat), a `Workflow` (for workflow-backed `ask`), knowledge bases,
   and delegation methods (`socialize`, `delegate`, `ask_agent`).
3. **`AgentWorkflow`** is a `Workflow` mixin that provides the `chat_task` DSL
   and agent lifecycle helpers. Multi-agent strategies are encoded as Scout
   workflows that `include_workflow AgentWorkflow`.
4. **`Backend`** modules translate the Chat format into provider-specific API
   calls and translate responses back. The composition pattern is
   `class << self; prepend XMethods; include Backend::ClassMethods; end`.
5. **Tools** are defined as tool-definition Hashes paired with execution
   blocks. They are merged into the `options[:tools]` IndiferentHash and
   dispatched by the backend.
6. **Annotation** powers the Chat DSL: a plain Array is annotated
   (`Chat.setup(array)`) so it gains `.user`, `.system`, `.follow`, `.ask`,
   `.chat`, etc., without being a subclass or a wrapper object.

### 1.3 Dependency graph

```
scout-ai.rb
  └─ scout/llm/ask.rb       (requires scout, chat)
  └─ scout/llm/chat.rb      (requires chat/annotation, chat/parse, chat/process, chat/prompt, chat/persist, tools, utils)
  └─ scout/llm/agent.rb     (requires ask, agent/chat, agent/iterate, agent/delegate, agent/workflow)
  └─ scout/llm/embed.rb
  └─ scout/llm/image.rb
  └─ scout/llm/tools/       (workflow, knowledge_base, mcp, call)
  └─ scout/llm/backends/    (default + 10 provider adapters)
```

Key dependency direction: **Agent → Chat → Annotation**.
Backends depend on Chat and Backend::ClassMethods, not on Agent.
AgentWorkflow depends on Agent and Chat, not on specific Backends.

---

## 2. Design Philosophy

### 2.1 Abstraction-first

Every concept in Scout-AI is an abstraction with a crisp boundary:

- A **Chat** is "a conversation" — nothing more, nothing less.
- An **Agent** is "a stateful conversation holder with tools."
- A **Backend** is "an adapter to a model API."

The code rarely mixes concerns. For example, `LLM.ask` never contains
provider-specific logic; it dispatches to `Backend::OpenAI.ask` or
`Backend::Anthropic.ask`. The Backend modules never hold state; they are
stateless module-method adapters.

**Why this matters:** New features should be expressed as a new abstraction or
an extension of an existing one, not as inline logic scattered across files.

### 2.2 Module composition over inheritance

Scout-AI avoids deep class hierarchies. Instead, it composes behavior through
Ruby modules:

```ruby
# Agent's behavior is split across multiple files that reopen the class:
#   lib/scout/llm/agent.rb          — core
#   lib/scout/llm/agent/chat.rb     — chat delegation methods
#   lib/scout/llm/agent/iterate.rb  — iteration patterns
#   lib/scout/llm/agent/delegate.rb — multi-agent delegation
#   lib/scout/llm/agent/workflow.rb — AgentWorkflow mixin + chat_task DSL
```

The `Chat` module is `extend Annotation` — it is a **module**, not a class.
The annotated object is whatever you pass in (typically a plain Array). This
is the "annotate, don't wrap" philosophy.

### 2.3 The Chat-as-data philosophy

This is the single most important design decision in Scout-AI:

> **A Chat is a plain `Array` of message `Hash`es, not an opaque object.**

The `Chat` module annotates an Array to add DSL methods, but the underlying
data structure is always accessible:

```ruby
chat = Chat.setup([])
chat.user("Hello")
chat.system("You are helpful")

# chat IS an Array:
chat.class            # => Array
chat.length           # => 2
chat.first[:role]     # => "user"
chat.first[:content]  # => "Hello"
chat.select { |m| m[:role] == 'system' }  # works
```

This means:

- Chats are **serializable** to plain text (the `.chat` file format) and back.
- Chats are **composable**: `intro + coda` just concatenates Arrays.
- Chats are **introspectable**: you can filter, map, select directly.
- Chats are **cacheable**: `Persist.persist` hashes the message Array.
- No lock-in: you can drop down to Array operations at any time.

### 2.4 The annotation/metadata pattern

Scout-AI uses scout-essentials' `Annotation` system to add methods to existing
objects **non-invasively**:

```ruby
module Chat
  extend Annotation          # Chat is now an annotation module

  def user(content)
    message(:user, content)
  end
  # ... 40+ DSL methods
end

# Usage: annotate a plain Array
messages = [{ role: 'user', content: 'Hi' }]
Chat.setup(messages)         # messages is still an Array, now with Chat methods
messages.system("Be brief")  # appends { role: 'system', content: 'Be brief' }
messages.ask                 # calls LLM.ask with the messages
```

The annotation:

- Adds methods to the **singleton class** of the specific object instance.
- Does **not** change the object's class (it remains `Array`).
- Is **removable**: `Annotation.purge(obj)` strips annotations.
- Carries **typed metadata**: `annotation_types` tracks which annotations are applied.

This pattern is used for:

| Annotation | Annotates       | Purpose                                           |
|------------|-----------------|---------------------------------------------------|
| `Chat`     | `Array`         | Conversation DSL (user, system, ask, follow, etc.)|
| `Step`     | `String` (path) | Workflow job metadata (dependencies, info, etc.)  |

### 2.5 Convention over configuration

Scout-AI discovers components by convention rather than registration:

**Agent resolution** (`LLM.load_agent`):
1. If the name is a file path → `load` it.
2. If it's a directory with `agent.rb` → `load` that file.
3. Otherwise check (in order):
   - `Scout.workflows[<name>]` (workflow directory)
   - `Scout.Agent[<name>]` (agent var directory)
   - `Scout.var.Agent[<name>]` (fallback)
   - `Scout.chats.Agent[<name>]` (chat agent directory)
   - `Scout.chats[<name>]` (general chat directory)

**Agent directory structure** (convention):
```
<agent_name>/
  workflow.rb       ← Scout Workflow with an :ask task
  start_chat        ← initial chat messages (text, chat-file format)
  knowledge_base/   ← optional KB directory
  python/           ← optional Python tasks
```

**Backend convention:**
- Each backend is a module under `LLM::` (e.g., `LLM::OpenAI`, `LLM::Anthropic`).
- It composes via `class << self; prepend XMethods; include Backend::ClassMethods; end`.
- It exposes `TAG` and `DEFAULT_MODEL` constants.

**Endpoint convention:**
- Named endpoints are YAML files in `~/.scout/etc/AI/<name>`.
- Selected by `endpoint: :name` in options or `--endpoint name` on CLI.

### 2.6 DSL patterns

Several DSLs exist in the codebase:

#### Chat DSL (instance methods on annotated Arrays)
```ruby
chat.user("...")          # append user message
chat.system("...")        # append system message
chat.assistant("...")     # append assistant message
chat.file("README.md")    # append file reference
chat.task(WF, :task, opt: val)  # append workflow task reference
chat.follow(other_chat)   # append another chat's messages
chat.option(:model, "gpt-5")    # append sticky option
chat.ask(options)         # call LLM.ask and return response
chat.chat(options)        # call LLM.ask, append response, return answer
chat.json(only_ask: true) # request JSON output
```

#### Agent DSL (via method_missing to current_chat)
```ruby
agent.user("...")    # delegates to current_chat.user
agent.system("...")  # delegates to current_chat.system
agent.chat           # calls ask and appends response
agent.ask            # calls LLM.ask with current_chat
agent.follow(chat)   # appends to current_chat
agent.branch         # creates a new chat from current_chat
```

#### Workflow DSL (from scout-gear, extended by AgentWorkflow)
```ruby
module MyStrategy
  extend Workflow
  self.include_workflow AgentWorkflow

  input :chat, :text, 'Chat input'
  
  chat_task :work do
    agent = self.agent(nil, chat: chat)
    agent.user("Do the work")
    agent.chat
  end
end
```

#### Backend composition DSL
```ruby
module LLM
  module MyBackendMethods
    def query(client, messages, tools = [], parameters = {})
      # override
    end
  end

  module MyBackend
    TAG = 'mybackend'
    DEFAULT_MODEL = 'my-model-v1'

    class << self
      prepend MyBackendMethods    # overrides
      include Backend::ClassMethods  # shared logic
    end
  end
end
```

---

## 3. Key Ruby Idioms Used

### 3.1 `extend` vs `include` vs `prepend`

| Idiom       | Used for                                      | Example                                                                 |
|-------------|-----------------------------------------------|-------------------------------------------------------------------------|
| `extend`    | Adding class/singleton methods to a module    | `module Chat; extend Annotation; end` — Chat gets `.setup`, `.purge`   |
| `include`   | Adding instance methods to a class            | `include Backend::ClassMethods` — shared backend logic                  |
| `prepend`   | Overriding methods while calling `super`      | `prepend OpenAIMethods` — overrides `query` while `ask` stays in base  |

**Backend composition pattern** (the most important `prepend`/`include` usage):

```ruby
# The shared implementation lives in Backend::ClassMethods (include)
# The overrides live in a *Methods module (prepend)
# The dispatch order is: *Methods (prepend) → Backend::ClassMethods (include)

class << self
  prepend OpenAIMethods         # called FIRST — can override query, format_tool_definitions
  include Backend::ClassMethods # called SECOND — provides ask, embed, process_tool_calls
end
```

This allows `Backend::ClassMethods#ask` to call `query` and have Ruby dispatch
to `OpenAIMethods#query` (the prepend).

**Agent's `extend Workflow`:**
```ruby
@workflow ||= begin
  m = Module.new
  m.extend Workflow        # The module gains task, input, helper, etc.
  m.name ||= 'ScoutAgent'
  m.tasks = {}
  m
end
```

### 3.2 `IndiferentHash` usage

`IndiferentHash` (from scout-essentials) is used everywhere options are
handled. It provides symbol/string-indifferent access plus utility methods:

```ruby
# Setup any hash as indifferent
options = IndiferentHash.setup({})

# Add defaults without overwriting
options = IndiferentHash.add_defaults(options, model: 'gpt-5')

# Extract and remove keys in one call
backend, persist = IndiferentHash.process_options(options, :backend, :persist, persist: true)

# Parse option strings
options = IndiferentHash.parse_options("model=gpt-5 backend=responses")
```

**Convention:** Always `IndiferentHash.setup` any hash that comes from user
input, parsed JSON, or kwargs. This prevents `:model` vs `'model'` bugs.

### 3.3 `Path` / `Open` / `TSV` from scout-essentials

- **`Path`**: Smart path objects with `.find`, `.exists?`, globbing, and
  Scout's path system (`Scout.var`, `Scout.chats`, `Scout.workflows`).
  ```ruby
  path = Scout.chats.Agent['Worker'].start_chat
  path.exists?  # => true/false
  path.find     # => resolved absolute path
  ```

- **`Open`**: Filesystem utilities that work with Path and String:
  ```ruby
  Open.exists?(path)
  Open.write(path, content)
  Open.read(path)
  Open.remote?(url)  # checks if it's a URL
  ```

- **`TSV`**: Tab-separated value manipulation with `TSV.traverse` for
  parallel iteration:
  ```ruby
  TSV.traverse(dict, **kwargs, &block)
  ```

### 3.4 Module as namespace + mixin

Modules serve double duty as both namespaces and mixin providers:

```ruby
module LLM                          # Namespace: LLM.ask, LLM.chat, LLM.load_agent
  module Backend                    # Namespace: Backend::ClassMethods, Backend::BackendException
    module ClassMethods             # Mixin: included into backend singletons
      def ask(messages, options)    # shared implementation
        ...
      end
    end
  end
  
  module OpenAI                     # Namespace: the backend itself
    # ...also a mixin target via singleton class composition
  end
end
```

### 3.5 Block-based DSLs

Block-based DSLs are used for task definitions and tool execution:

```ruby
# Workflow task with block
task :ask => :text do |chat|
  # self is the workflow instance
  # instance_exec gives access to helpers
end

# Tool execution block
LLM.ask(messages, tools: tools) do |task_name, parameters|
  workflow.job(task_name, parameters).run
end

# Persist with block (only executes if cache miss)
Persist.persist(endpoint, :json, ...) do
  # expensive computation
end
```

### 3.6 `method_missing` delegation

The `Agent` class delegates unknown methods to `current_chat`:

```ruby
class Agent
  def method_missing(name, ...)
    current_chat.send(name, ...)
  end
end
```

This means `agent.user(...)`, `agent.system(...)`, `agent.file(...)` all
transparently delegate to the Chat DSL without defining each method.

### 3.7 Configuration cascade

Configuration is resolved through a priority chain via `Scout::Config.get`:

```ruby
Scout::Config.get(:model, :ask, :llm, env: 'ASK_MODEL,LLM_MODEL', default: 'gpt-5-nano')
```

Priority order (highest first):
1. Explicit option passed in code/options hash
2. Environment variable (from `env:` list)
3. Config file entries (matching tokens)
4. Default value

---

## 4. Naming Conventions

### 4.1 File naming

| Pattern                          | Convention                              | Example                          |
|----------------------------------|-----------------------------------------|----------------------------------|
| Top-level modules               | `<module>.rb`                           | `lib/scout/llm/ask.rb`           |
| Sub-modules (namespace + body)  | `<namespace>/<name>.rb`                 | `lib/scout/llm/agent/delegate.rb`|
| Annotation modules              | `<name>/annotation.rb`                  | `lib/scout/llm/chat/annotation.rb`|
| Processing modules              | `<name>/process/<aspect>.rb`            | `lib/scout/llm/chat/process/tools.rb`|
| Backend modules                 | `backends/<provider>.rb`               | `lib/scout/llm/backends/openai.rb`|
| Agent directory files           | lowercase, no extension                 | `start_chat`, `workflow.rb`      |

**Key rule:** File paths mirror module nesting.
`LLM::Agent` → `lib/scout/llm/agent.rb`.
`LLM::Agent` behavior extensions → `lib/scout/llm/agent/chat.rb`.

### 4.2 Method naming

| Category         | Convention                        | Examples                                |
|------------------|-----------------------------------|-----------------------------------------|
| DSL actions      | verb (lowercase)                  | `user`, `system`, `ask`, `follow`       |
| Queries          | noun or predicate                 | `current_chat`, `answer`, `final`       |
| Class methods    | `self.` prefix on module          | `LLM.ask`, `Chat.parse`, `Chat.setup`   |
| Helpers (WF)     | `helper :name do ... end`         | `helper :agent`, `helper :chat`         |
| Predicates       | end with `?`                      | `exists?`, `remote?`, `is_filename?`    |
| Destructive      | end with `!` (rare)               | —                                       |
| Convention: `setup` | class method that annotates    | `Chat.setup(array)`, `IndiferentHash.setup(hash)` |

### 4.3 Variable conventions

| Variable        | Convention                              | Example                                   |
|-----------------|-----------------------------------------|-------------------------------------------|
| Messages/chats  | `messages`, `chat`, `coda`, `intro`     | `messages = LLM.chat(question)`           |
| Options         | `options` (always IndiferentHash)       | `options = IndiferentHash.setup({})`      |
| Path objects    | `path`, `dir`, `file` (Path-typed)      | `path = Scout.chats.find['hello']`        |
| Agent instances | `agent`                                 | `agent = LLM.load_agent('Worker')`        |
| Blocks/lambdas  | `block`, named with `&`                 | `&block`                                  |

---

## 5. How to Write Idiomatic Scout-AI Code

### 5.1 Extending the Chat DSL

To add a new message role or convenience method:

```ruby
# GOOD: Add to the Chat annotation module
module Chat
  def screenshot(file)
    message(:image, file)  # or a new role
  end
end
```

This automatically becomes available on any annotated Array and via
`agent.method_missing`.

### 5.2 Adding a new backend

```ruby
require_relative 'default'

module LLM
  module MyProviderMethods
    # Override provider-specific methods
    def query(client, messages, tools = [], parameters = {})
      parameters[:messages] = messages
      parameters[:tools] = format_tool_definitions(tools) if tools&.any?
      client.chat(parameters: parameters)
    end

    def format_tool_definitions(tools)
      # translate to provider format
    end

    def client(options, messages = nil)
      url, key = IndiferentHash.process_options(options, :url, :key)
      MyProvider::Client.new(api_key: key, base_url: url)
    end
  end

  module MyProvider
    TAG = 'myprovider'
    DEFAULT_MODEL = 'my-model-v1'

    class << self
      prepend MyProviderMethods
      include Backend::ClassMethods
    end
  end
end
```

Then register it in the dispatch `case` statement in `LLM.ask`:

```ruby
when :myprovider, "myprovider"
  require_relative 'backends/myprovider'
  LLM::MyProvider.ask(messages, options, &block)
```

### 5.3 Building a multi-agent strategy

```ruby
require 'scout-ai'

module MyStrategy
  extend Workflow
  self.include_workflow AgentWorkflow

  input :chat, :text, 'Chat input'
  extension :chat

  chat_task :ask do
    # Create an agent from a chat
    agent = self.agent(nil, chat: chat)

    # Use the Chat DSL through method_missing
    agent.user("Analyze this request and produce a plan.")

    # The agent.chat method calls LLM.ask and appends the response
    plan = agent.answer

    # Delegate to a specialist
    specialist = self.agent('Worker', chat: nil)
    specialist.user("Execute: #{plan}")
    specialist.chat

    # Log agent conversations
    log_agent(specialist, 'worker')
    log_agent(agent, 'planner')

    specialist.answer
  end
end
```

### 5.4 Adding a tool

```ruby
# Register a tool on an agent
agent.other_options[:tools][:search] = [
  search_block,    # Proc: (task_name, parameters) => result
  {
    name: 'search',
    description: 'Search the web',
    type: 'function',
    function: {
      name: 'search',
      description: 'Search the web',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string' } },
        required: ['query']
      }
    }
  }
]
```

### 5.5 Anti-patterns (what NOT to do)

#### ❌ Don't create wrapper classes for Chat

```ruby
# BAD: Wrapping Chat in a custom class
class MyConversation
  def initialize
    @messages = []
  end
  def add_user(text)
    @messages << { role: 'user', content: text }
  end
end

# GOOD: Use the annotation pattern
chat = Chat.setup([])
chat.user("Hello")
```

#### ❌ Don't hardcode provider logic in LLM.ask

```ruby
# BAD
def self.ask(question, options = {})
  if options[:provider] == 'openai'
    # 50 lines of OpenAI-specific code inline
  end
end

# GOOD: Dispatch to a backend module
def self.ask(question, options = {})
  case backend
  when :openai
    require_relative 'backends/openai'
    LLM::OpenAI.ask(messages, options, &block)
  end
end
```

#### ❌ Don't use plain Hash when options come from user input

```ruby
# BAD: String/symbol key bugs
def ask(question, options = {})
  model = options[:model]  # fails if user passed 'model'
end

# GOOD: IndiferentHash
def ask(question, options = {})
  options = IndiferentHash.setup(options)
  model = options[:model]  # works for both :model and 'model'
end
```

#### ❌ Don't subclass to add behavior

```ruby
# BAD: Inheritance hierarchy
class SpecialChat < Array
  def user(content)
    self << { role: 'user', content: content }
  end
end

# GOOD: Annotation (open class, no hierarchy)
module Chat
  extend Annotation
  def user(content)
    message(:user, content)
  end
end
# Then: Chat.setup(any_array)
```

#### ❌ Don't scatter file I/O without Path/Open

```ruby
# BAD
File.read("/hardcoded/path/#{name}")

# GOOD
path = Scout.var.Agent[name].start_chat
content = Open.read(path.find) if path.exists?
```

#### ❌ Don't define methods on Agent that duplicate Chat

```ruby
# BAD: Redundant delegation
class Agent
  def add_user_message(text)
    current_chat << { role: 'user', content: text }
  end
end

# GOOD: method_missing already delegates to current_chat
agent.user(text)  # works automatically
```

---

## 6. Examples: Good vs Bad Code

### Example 1: Processing a chat before sending to the model

#### ❌ Non-idiomatic
```ruby
class ChatProcessor
  def initialize(chat_array)
    @chat = chat_array
  end

  def remove_tool_messages
    @chat.reject! { |m| m[:role] == 'tool' }
  end

  def get_options
    result = {}
    @chat.each do |m|
      if m[:role] == 'option'
        key, val = m[:content].split(' ', 2)
        result[key] = val
      end
    end
    result
  end

  def send_to_model(provider, api_key)
    if provider == 'openai'
      client = OpenAI::Client.new(api_key)
      response = client.chat(messages: @chat)
      @chat << { role: 'assistant', content: response }
    end
  end
end

processor = ChatProcessor.new(messages)
processor.remove_tool_messages
options = processor.get_options
processor.send_to_model('openai', ENV['OPENAI_API_KEY'])
```

#### ✅ Idiomatic
```ruby
chat = Chat.setup(messages)

# Use Chat's built-in DSL
chat.remove_role(:tool)

# Use Chat.options for option extraction
options = Chat.options(chat)

# Use the universal entry point
chat.ask(options.merge(endpoint: :nano))
```

**Why the idiomatic version is better:**
- Uses the existing DSL (`remove_role`, `options`) instead of reimplementing.
- Delegates to `LLM.ask` which handles backend dispatch, caching, persistence.
- The Chat remains a plain Array — no wrapper object to maintain.
- Options are resolved through the full config cascade.

---

### Example 2: Building a multi-agent orchestration

#### ❌ Non-idiomatic
```ruby
class Orchestrator
  def initialize(question)
    @question = question
    @conversations = {}
  end

  def run
    planner_messages = [{ role: 'user', content: @question }]
    planner_messages << { role: 'system', content: 'You plan tasks.' }
    planner_response = call_llm(planner_messages)
    
    worker_messages = [{ role: 'user', content: planner_response }]
    worker_messages << { role: 'system', content: 'You execute tasks.' }
    worker_response = call_llm(worker_messages)
    
    @conversations['planner'] = planner_messages
    @conversations['worker'] = worker_messages
    
    worker_response
  end

  def call_llm(messages)
    # reimplement API call, caching, tool calling, etc.
    client = OpenAI::Client.new
    response = client.chat(parameters: { messages: messages })
    response.dig('choices', 0, 'message', 'content')
  end
end
```

#### ✅ Idiomatic
```ruby
require 'scout-ai'

module Orchestration
  extend Workflow
  self.include_workflow AgentWorkflow

  input :chat, :text, 'Chat input'
  extension :chat

  chat_task :ask do
    agent = self.agent(nil, chat: chat)

    agent.start_chat.system "You are an orchestrator."

    # Delegate to specialists via socialize
    agent.socialize

    agent.user "Plan and execute this request using specialists."
    agent.chat
  end
end
```

Or using direct delegation:

```ruby
chat_task :ask do
  orchestrator = self.agent(nil, chat: chat)

  planner = self.agent('Planner')
  planner.user(orchestrator.answer)
  plan = planner.chat

  worker = self.agent('Worker')
  worker.follow(plan)
  worker.chat

  log_agent(planner, 'planner')
  log_agent(worker, 'worker')

  worker.answer
end
```

**Why the idiomatic version is better:**
- Uses `AgentWorkflow` mixin → gets `chat_task`, `helper :agent`, `helper :log_agent`.
- Uses `Agent` → gets stateful chats, tool wiring, start_chat loading.
- Uses `Chat` DSL → `.user`, `.system`, `.follow`, `.chat`, `.answer`.
- Uses `log_agent` → conversations are persisted for provenance.
- The entire strategy is a Scout Workflow → inputs are typed, jobs are cached,
  dependencies are tracked, CLI integration is automatic.
- No reinvention of API calls, caching, or tool calling.

---

### Example 3: Adding a new message role

#### ❌ Non-idiomatic
```ruby
# Adding a "context" role by modifying parse logic inline
def my_custom_parse(text)
  messages = Chat.parse(text)
  messages.each do |m|
    if m[:content]&.start_with?('CONTEXT:')
      m[:role] = 'context'
      m[:content] = m[:content].sub('CONTEXT:', '').strip
    end
  end
  messages
end
```

#### ✅ Idiomatic
```ruby
# Add the role to the Chat annotation DSL
module Chat
  def context(content)
    message(:context, content)
  end
end

# Add handling in the chat file parser if needed (chat/parse.rb)
# Add processing in chat/process/ if compilation rules are needed

# Now it works everywhere:
chat = Chat.setup([])
chat.context("Some background info")
agent.context("Some background info")  # via method_missing
```

---

## 7. Summary: The Scout-AI Coding Mindset

1. **Data is plain.** Chats are Arrays, options are Hashes. Annotate, don't wrap.
2. **Compose, don't inherit.** Use modules, `extend`, `include`, `prepend`.
3. **One abstraction, one responsibility.** Chat holds conversation. Agent holds state. Backend adapts to a provider. Tools define callable actions.
4. **Convention discovers.** Directory structures and file names are the registry.
5. **DSLs are methods on annotated objects.** Add methods to modules, get them everywhere via annotation and `method_missing`.
6. **Use the full stack.** `IndiferentHash` for options, `Path` for files, `Scout::Config` for configuration, `Persist` for caching, `Log` for logging. Don't reimplement.
7. **Keep it serializable.** Everything can be written to disk and read back. This is a feature, not a limitation.
8. **Small files, clear boundaries.** `agent.rb` → `agent/chat.rb` → `agent/delegate.rb`. Each file adds one concern.

> **The guiding question when writing Scout-AI code:**
> *"Can I express this as a composition of existing abstractions, or does it
> need a new one? If new, is its boundary crisp?"*
