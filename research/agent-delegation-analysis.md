> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# 03 — Agent Class, Delegation Mechanics, and Socialization

> **Source files analysed**
> - `lib/scout/llm/agent.rb` (213 lines)
> - `lib/scout/llm/agent/chat.rb` (110 lines)
> - `lib/scout/llm/agent/delegate.rb` (323 lines)
> - `lib/scout/llm/agent/iterate.rb` (44 lines)
> - `lib/scout/llm/agent/workflow.rb` (workflow integration helper)
> - `lib/scout/llm/ask.rb` (entry-point `LLM.ask`)
> - `lib/scout/llm/chat/annotation.rb`, `chat/process/tools.rb`, `chat/process/clear.rb`, `chat/prompt.rb`

---

## 1. Agent Class Structure

### 1.1 Definition and composition

`LLM::Agent` is the central Ruby class that represents an autonomous AI agent.
It is defined in `lib/scout/llm/agent.rb` and extended by three mixin modules
loaded at the bottom of the file:

```ruby
require_relative 'agent/chat'
require_relative 'agent/iterate'
require_relative 'agent/delegate'
require_relative 'agent/workflow'
```

Each module adds a cohesive set of instance methods to the same `LLM::Agent`
class — a classic Ruby module-composition / "concern" pattern:

| Module file | Responsibility |
|---|---|
| `agent/chat.rb` | Conversation lifecycle: `start`, `current_chat`, `chat`, `json`, etc. |
| `agent/iterate.rb` | Structured multi-step extraction (`iterate`, `iterate_dictionary`). |
| `agent/delegate.rb` | Multi-agent socialization & delegation (`socialize`, `delegate`, `ask_agent`). |
| `agent/workflow.rb` | Integration with Scout's `Workflow` system (`chat_task`, `AgentWorkflow`). |

The top-level file also defines two convenience module methods on `LLM`:

```ruby
def self.agent(...)   = LLM::Agent.new(...)        # factory shortcut
def self.load_agent(...) = LLM::Agent.load_agent(...)  # discovery + loading
```

### 1.2 Initialization

```ruby
def initialize(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
```

| Parameter | Type | Purpose |
|---|---|---|
| `workflow:` | `Workflow` module or name string | Scout workflow whose tasks become callable tools. If a `String`, it is resolved via `Workflow.require_workflow`. |
| `knowledge_base:` | `KnowledgeBase` | Optional knowledge base; its databases are exposed as tools. |
| `start_chat:` | `Chat` (Array of message hashes) | The seeded / system conversation that prefixes every new chat branch. |
| `**kwargs` | — | Captured into `@other_options` as an `IndiferentHash`. Typically holds `:model`, `:endpoint`, `:tools`, etc. |

### 1.3 Core attributes (attr\_accessor)

```ruby
attr_accessor :workflow, :knowledge_base, :start_chat,
              :process_exception, :other_options, :path, :job
```

Additional attributes from mixins:

| Attribute | Defined in | Purpose |
|---|---|---|
| `@society` | `delegate.rb` | Hash of `{agent_name => Agent}` templates loaded once and cloned per conversation. |
| `@chats` | `delegate.rb` | Hash of `{agent_name/conversation => Agent}` — the live specialist instances. |
| `@current_chat` | `chat.rb` (lazy via `current_chat`) | The active conversation (a `Chat`-annotated array). |

### 1.4 Lazy workflow creation

If no `@workflow` is set, one is created on demand:

```ruby
def workflow(&block)
  if block_given?
    # evaluate block in the workflow's context (DSL)
    workflow.instance_eval &block
  else
    @workflow ||= begin
      m = Module.new
      m.extend Workflow
      m.name ||= 'ScoutAgent'
      m.tasks = {}
      m
    end
  end
end
```

This allows inline workflow definition in tests or scripts:

```ruby
agent.workflow do
  task :my_task => :string do ... end
end
```

---

## 2. The `ask` / `iterate` Loop

### 2.1 `Agent#ask` — entry point for inference

```ruby
def ask(messages = nil, options = {})
```

**Key behaviour:**

1. **Message resolution.** If `messages` is nil, uses `current_chat`. Normalises
   to an array.
2. **Socialize hook.** If any message has `role: 'socialize'` and its content is
   truthy (`true`, `T`, `1`), calls `self.socialize(options.dup)` — wiring up
   the `ask` tool so the LLM can delegate.
3. **Tool merging.** Merges three layers of tool definitions:
   - Explicit `options[:tools]`
   - `@other_options[:tools]` (e.g. tools added by `socialize`/`delegate`)
   - Workflow tools (`LLM.workflow_tools(workflow)`) and knowledge-base tools.
4. **Two execution paths:**

   **Path A — Workflow `ask` task (preferred for agent-backed workflows):**
   ```ruby
   if workflow && workflow.tasks.include?(:ask) && !no_ask_override
     job = workflow.job(:ask, chat: Chat.print(messages))
     job.produce
     messages = Chat.project(job.short_path, LLM.chat(job.path))
   ```
   The agent dispatches through the workflow's own `ask` task (a `chat_task`),
   gaining Scout's job caching, provenance, and dependency system.

   **Path B — Direct `LLM.ask`:**
   ```ruby
   LLM.ask messages, @other_options.merge(log_errors: true).merge(options).merge(agent: false)
   ```
   Calls the backend directly without going through a workflow job.

5. **Exception handling.** Wraps everything in a `begin/rescue`; if
   `@process_exception` is a `Proc`, it is called with the exception and may
   trigger a `retry`.

### 2.2 The multi-turn tool-calling loop (backend level)

The iterative tool-calling loop does **not** live in `Agent` itself — it lives
in the backend layer (`LLM::Backend::Default#chain_tools`):

```ruby
def chain_tools(messages, output, tools, options = {}, &block)
  if output.last[:role] == 'function_call_output'
    # re-call ask with the tool output appended
    output + ask(messages + output, options.except(:tool_choice).merge(return_messages: true), &block)
  else
    output   # no pending tool call — done
  end
end
```

This is **recursion**: each backend `ask` call checks whether the model emitted
a `function_call_output`; if so, it calls `ask` again with the growing message
list. The loop terminates when the model's last message is a plain `assistant`
message rather than a tool call.

**Iteration limits** are enforced via the prompt shortening system
(`lib/scout/llm/chat/prompt.rb`):

| Constant | Default | Meaning |
|---|---|---|
| `DEFAULT_MAX_TOOL_CALLS` | 40 | Maximum number of tool call/output pairs retained in the prompt. |
| `DEFAULT_FULL_TOOL_CALLS` | 0 | Number of most-recent tool calls kept at full fidelity. |
| `DEFAULT_FULL_TOOL_OUTPUTS` | 10 | Number of most-recent tool outputs kept at full fidelity. |
| `DEFAULT_MAX_TOOL_CHARS` | 100 000 | Character budget for tool outputs. |

Older tool calls/outputs beyond these limits are truncated or dropped, which
effectively bounds the conversation depth and prevents unbounded recursion.

### 2.3 `Agent#prompt`

```ruby
def prompt(messages, options = {})
  messages = LLM.chat messages if String === messages
  messages = Chat.follow start_chat, messages   # prefix with start_chat
  ask messages, options
end
```

Convenience method: parses a string as chat syntax, prepends the agent's
`start_chat`, then delegates to `ask`.

### 2.4 `Agent#iterate` (iterate.rb)

```ruby
def iterate(prompt = nil, &block)
  self.endpoint :responses
  self.user prompt if prompt
  obj = self.json_format({ ... "type": "object", "properties": { "content": { "type": "array", "items": {"type": "string" } } } ... })
  self.option :format, :text
  list = Hash === obj ? obj['content'] : obj
  list.each &block
end
```

A structured-extraction loop: sends a prompt, asks the model to return a JSON
array of strings, then iterates over each element calling the supplied block.
`iterate_dictionary` is the same pattern but returns a flat key/value hash.

---

## 3. Agent Chat Management (agent/chat.rb)

### 3.1 The dual-chat model

Every `Agent` maintains two Chat objects:

| Chat | Variable | Purpose |
|---|---|---|
| **Start chat** | `@start_chat` | Immutable seed messages (system instructions, tool intros, files). Prefixes every new conversation. |
| **Current chat** | `@current_chat` | The live, evolving conversation. |

### 3.2 `start_chat` accessor

```ruby
def start_chat
  @start_chat ||= Chat.setup([])
end
```

Defaults to an empty chat if none was provided at construction.

### 3.3 `start` — creating a new conversation branch

```ruby
def start(chat = nil)
  if chat
    (@current_chat || start_chat).annotate chat unless Chat === chat
    @current_chat = chat
  else
    start_chat_obj = self.start_chat
    Chat.setup(start_chat_obj) unless Chat === start_chat_obj
    @current_chat = start_chat_obj.branch    # shallow copy via annotate(self.dup)
  end
end
```

- With no argument: creates a **branch** (shallow copy) of `start_chat` and
  assigns it to `@current_chat`.
- With an argument: adopts the provided chat as the current chat (annotating it
  to ensure it behaves as a `Chat`).

### 3.4 `current_chat`

```ruby
def current_chat
  @current_chat ||= start
end
```

Lazy: on first access it calls `start` to create the default branch.

### 3.5 `method_missing` — Chat proxy

```ruby
def method_missing(name, ...)
  current_chat.send(name, ...)
end
```

Any method not defined on `Agent` is forwarded to `current_chat`. This means
calls like `agent.user("hi")`, `agent.system("...")`, `agent.option(:model,
"gpt-4")`, `agent.print` are all delegated to the underlying Chat object.

### 3.6 `chat` — one round-trip with history

```ruby
def chat(options = {})
  response = ask(current_chat, options.merge(return_messages: true))
  if Array === response
    current_chat.concat(response)
    options[:return_messages] ? response : current_chat.answer
  else
    current_chat.push({role: :assistant, content: response})
    response
  end
end
```

Calls `ask` with `return_messages: true`, appends the response messages to the
current chat, and returns either the full message list or just the answer text.

### 3.7 JSON helpers

`json` and `json_format` push a format constraint onto the chat, call `chat`,
parse the output as JSON, and restore the format. They provide structured
extraction.

---

## 4. Socialization and Delegation (delegate.rb) — CRITICAL

This module (323 lines) implements Scout-AI's multi-agent architecture. It
allows one Agent to **socialize** (expose a generic `ask` tool to the LLM) or
**delegate** (create named `hand_off_to_*` tools for specific agents).

### 4.1 Constants and invariants

```ruby
SOCIAL_INHERIT_MODES      = %w[none tools conversation].freeze
SOCIAL_AGENT_NAME         = /\A[a-z_.-]+\z/i
SOCIAL_CONVERSATION_NAME  = /\A[a-z0-9][a-z0-9_.-]*\z/i
SOCIAL_PRIVATE_OPTIONS    = %i[
  agent client current_meta format messages no_ask_override
  previous_response_id process return_messages tool_choice tools
].freeze
```

- **`SOCIAL_AGENT_NAME`** — valid agent name pattern (letters, dots,
  underscores, hyphens).
- **`SOCIAL_CONVERSATION_NAME`** — conversation identifiers must start with
  alphanumeric.
- **`SOCIAL_PRIVATE_OPTIONS`** — caller options that are **stripped** before
  being passed to a specialist (prevents leaking session state, tool blocks,
  or message arrays).

### 4.2 SOCIAL\_INHERIT\_MODES

These three modes control **how much caller context** flows to a specialist
when a new call or conversation is first created:

| Mode | What is inherited | Use case |
|---|---|---|
| **`none`** | Nothing. The specialist starts only with its own `start_chat`. | Fully isolated sub-agent. |
| **`tools`** *(default)* | Only the declarative tooling (roles: `introduce`, `tool`, `mcp`, `kb`) from the caller's current chat. | Give the specialist the same tool capabilities without conversation history. |
| **`conversation`** | The caller's entire current chat minus its own start\_chat prefix. | Full context sharing for deeply collaborative work. |

Implemented in `social_inherited_context`:

```ruby
def social_inherited_context(inherit)
  case inherit
  when 'none'
    Chat.setup([])
  when 'tools'
    tooling = self.current_chat.tooling
    social_chat_copy(tooling)
  when 'conversation'
    social_caller_context
  end
end
```

### 4.3 The `socialize` method

**Signature:**

```ruby
def socialize(options = {})
```

**What it does:** Registers a single tool named `:ask` in `@other_options[:tools]`.
When the LLM invokes this tool, it can ask **any** specialist agent.

**Tool schema exposed to the model:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `agent` | string | ✅ | Name of the specialist agent. |
| `prompt` | string | ✅ | Plain-text prompt (one user message). |
| `conversation` | string | ❌ | Named conversation identifier. Omit for one-shot. Reuse to continue. |
| `inherit` | enum `[none, tools, conversation]` | ❌ (default `tools`) | Context policy for new calls/conversations only. |

**Tool block (executed when the LLM calls `ask`):**

```ruby
block = Proc.new do |_name, parameters|
  agent_name, prompt, conversation, inherit = social_tool_parameters(parameters)
  ask_agent(agent_name, prompt,
            conversation: conversation,
            inherit: inherit,
            options: social_options)
end
```

The model **never sees** the specialist's `Chat` object — it receives only the
text answer. The block captures `social_options` (a deep-duplicated copy of the
caller's `other_options` minus private keys) in its closure.

### 4.4 The `ask_agent` method — the delegation engine

**Signature:**

```ruby
def ask_agent(agent_name, prompt, conversation: nil, inherit: 'tools', options: {})
```

**Flow:**

1. Validate `agent_name` and `inherit`.
2. Resolve the specialist instance:
   - If `conversation` is nil → uses conversation key `'default'` (a
     single persistent conversation per agent, effectively shared across
     one-shot calls).
   - If `conversation` is provided → uses that named conversation.
3. `agent.user(prompt)` — appends the prompt as a user message.
4. Returns the specialist `Agent` object (the caller's tool block then calls
   `agent.chat` to get the text response, or the socialize block does this
   internally).

> **Security note (from source comment):** `ask_agent` uses `agent.user(prompt)`
> rather than `agent.prompt(prompt)` because `prompt` parses String input as
> Scout chat-file syntax — a malicious or confused prompt containing `tool:`
> or `system:` directives could inject control messages or grant tools.
> `user` simply appends a single user-role message.

### 4.5 The `load_chat` method — conversation scoping

```ruby
def load_chat(agent_name, options = {}, conversation = nil, inherit: 'tools')
  key = social_chat_key(agent_name, conversation)   # "Worker/work_A"
  @chats[key] ||= start_social_chat(agent_name, options, inherit)
end
```

**Conversation keys are scoped by agent:** `Worker/work_A` and `Critic/work_A`
are completely independent conversations. The `@chats` hash persists specialist
instances across calls within the same caller agent.

`inherit` is only consulted **once** — when the conversation is first created.
Follow-up turns reuse the existing conversation with its accumulated history.

### 4.6 `start_social_chat` — the full initialization

```ruby
def start_social_chat(agent_name, options, inherit)
  template = load_agent(agent_name, options)        # load specialist template
  agent    = clone_social_agent(template)            # deep clone
  initial_chat = social_chat_copy(agent.start_chat)  # copy start chat
  initial_chat.follow(social_inherited_context(inherit))  # append inherited ctx
  agent.start_chat.follow(initial_chat)              # set as new start_chat
  agent
end
```

This means the specialist's `start_chat` is rebuilt as:

```
[specialist's original start_chat] + [inherited context from caller]
```

So the specialist always gets its own system prompt first, then optionally the
caller's tools or full conversation.

### 4.7 `clone_social_agent` — template isolation

```ruby
def clone_social_agent(template)
  agent = template.clone
  agent.start_chat  = social_chat_copy(template.start_chat)
  agent.other_options = IndiferentHash.setup(social_duplicate(template.other_options || {}))
  agent.society = nil
  agent.chats   = nil
  agent.instance_variable_set(:@current_chat, nil)
  agent
end
```

Every conversation gets a **fresh clone** of the loaded template, with its own
`start_chat`, `other_options`, and nilled-out `society`/`chats` (preventing
accidental cross-contamination of delegation state).

### 4.8 `load_agent` (instance method) — specialist loading

```ruby
def load_agent(agent_name, options = {})
  agent_name = normalize_social_agent_name(agent_name)
  @society ||= {}
  @society[agent_name] ||= LLM.load_agent(agent_name, social_agent_options(options))
end
```

**One immutable template per specialist.** The template is loaded once and
cloned per-conversation. `social_agent_options` strips private options:

```ruby
def social_agent_options(options)
  merged = defaults.merge(supplied)
  SOCIAL_PRIVATE_OPTIONS.each { |name| merged.delete(name) }
  merged
end
```

### 4.9 `social_caller_context` — extracting non-start-chat messages

```ruby
def social_caller_context
  current = current_chat || []
  base    = start_chat || []
  base_ids = base.each_with_object({}) { |m, ids| ids[m.object_id] = true }

  if current.any? { |m| base_ids[m.object_id] }
    # Fast path: same Hash objects — reject by object_id
    current.reject { |m| base_ids[m.object_id] }
  else
    # Fallback: prefix matching for separately parsed Chats
    prefix = 0
    limit = [current.length, base.length].min
    prefix += 1 while prefix < limit && current[prefix] == base[prefix]
    current.drop(prefix)
  end
end
```

This extracts the "new" messages — everything the caller has added beyond its
own `start_chat` — for `inherit: 'conversation'` mode.

### 4.10 The `chat` / `conversation` parameter semantics

The old `chat` parameter (from earlier versions) is silently accepted for
backward compatibility via `social_tool_parameters`:

| Legacy `chat` value | Maps to `conversation` | Maps to `inherit` |
|---|---|---|
| `'current'` | `'current'` | `'conversation'` |
| `''`, `'none'`, `'false'` | `nil` (one-shot) | `'none'` |
| any other name | that name | `'tools'` |

New code should use `conversation` and `inherit` as separate parameters.

### 4.11 The `delegate` method — named hand-off tools

**Signature:**

```ruby
def delegate(agent, name, description, task_name = nil, &block)
```

**What it does:** Creates a tool named `hand_off_to_#{name}` (e.g.,
`hand_off_to_worker`) that delegates to a specific, pre-loaded `Agent` object.

**Default tool block:**

```ruby
block ||= Proc.new do |_name, parameters|
  message = parameters[:message]
  new_conversation = parameters[:new_conversation]
  agent.start if new_conversation    # reset conversation
  agent.user message
  agent.chat                         # get response
end
```

**Tool schema:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `message` | string | ✅ | Message to pass to the agent. |
| `new_conversation` | boolean | ❌ (default false) | If true, erase history and start fresh. |

**Key difference from `socialize`:**

| Aspect | `socialize` | `delegate` |
|---|---|---|
| Agent name | Model chooses at call time (`agent` param) | Hard-coded at registration time |
| Tool name | `:ask` (single tool for all agents) | `hand_off_to_#{name}` (one tool per agent) |
| Custom block | No (fixed block) | Yes (caller can supply `&block`) |
| Conversation management | Named conversations via `conversation` param | Single conversation, resettable via `new_conversation` |

### 4.12 Deep-duplication via `social_duplicate`

```ruby
def social_duplicate(value)
  case value
  when Hash   then value.each_with_object({}) { |(k, v), h| h[social_duplicate(k)] = social_duplicate(v) }
  when Array  then value.collect { |item| social_duplicate(item) }
  when String then value.dup
  else             value
  end
end
```

A recursive deep-copy that avoids `Marshal.load/dump` — important because tool
blocks (Procs) cannot be marshalled but are simply passed by reference (they
fall into the `else` branch).

---

## 5. Agent Loading

### 5.1 `LLM::Agent.load_agent` — the class method

**Signature:**

```ruby
def self.load_agent(agent_name = nil, options = {})
```

**Resolution order** (first match wins):

1. **Direct file path.** If `agent_name` is a filename:
   - If it's a directory containing `agent.rb` → `load` that file.
   - If it's a `.rb` file → `load` it directly.

2. **Named agent discovery** (when `agent_name` is a name string):
   ```ruby
   workflow_path = Scout.workflows[agent_name]       # Scout workflows dir
   agent_path    = Scout.Agent[agent_name]           # Scout Agent dir
   agent_path    = Scout.var.Agent[agent_name] unless agent_path.exists?
   agent_path    = Scout.chats.Agent[agent_name] unless agent_path.exists?
   agent_path    = Scout.chats[agent_name] unless agent_path.exists?
   ```

3. **Workflow resolution:**
   - If `workflow_path` exists → `Workflow.require_workflow(agent_name)`.
   - If `agent_path/workflow.rb` exists → load that file.
   - If `agent_path/python/*.py` exists → load as a Python workflow via
     `PythonWorkflow.load_directory`.

4. **Knowledge base resolution:**
   - `agent_path/knowledge_base` → `KnowledgeBase.load`.
   - Or `workflow_path/knowledge_base`.

5. **Start chat resolution:**
   - `agent_path/start_chat` → `Chat.setup(LLM.chat(file))`.
   - Or `workflow_path/start_chat`.
   - Or, if the workflow has documentation, `[{role: 'introduce', content: workflow.name}]`.

### 5.2 The agent directory convention

A named agent is discovered as a directory that may contain:

```
Agent/
  Worker/
    agent.rb          # Ruby file defining the agent (loaded via `load`)
    workflow.rb       # Scout Workflow definition
    knowledge_base/   # KnowledgeBase directory
    start_chat        # Initial chat in Scout chat-file syntax
    python/           # Python workflow files (*.py)
```

The lookup chain `Scout.workflows → Scout.Agent → Scout.var.Agent →
Scout.chats.Agent → Scout.chats` provides multiple well-known locations.

### 5.3 `load_from_path` — struct-path-based loading

```ruby
def self.load_from_path(path, workflow: nil, knowledge_base: nil, chat: nil)
```

Used when you have a `Path` object (Scout's Pathwise extension) with
sub-paths: `path['workflow.rb']`, `path['knowledge_base']`,
`path['start_chat']`. Each is checked for existence and loaded if present.

### 5.4 Instance-level `load_agent` (delegate.rb)

The `delegate.rb` module defines an **instance method** `load_agent` that wraps
the class method with socialization-specific option filtering:

```ruby
def load_agent(agent_name, options = {})
  @society[agent_name] ||= LLM.load_agent(agent_name, social_agent_options(options))
end
```

This shadows the class method within instances that have mixed in the delegate
module (which is always, since `delegate.rb` is always loaded).

---

## 6. Key Abstractions and Design Patterns

### 6.1 Module composition (Ruby concerns)

The four `agent/*.rb` files all reopen `LLM::Agent` and add methods. There is no
inheritance hierarchy — just flat module inclusion. This keeps each concern in
its own file while sharing `@other_options`, `@current_chat`, etc.

### 6.2 `method_missing` proxy to Chat

`Agent#method_missing` forwards unknown method calls to `current_chat`, making
`Agent` a transparent proxy for Chat operations. This is a deliberate DSL
choice: `agent.user(...)`, `agent.system(...)`, `agent.print`, etc. all "just
work" without explicit delegation methods.

### 6.3 `IndiferentHash` for option passing

Scout's `IndiferentHash` (symbol/string-indifferent access) is used everywhere
for `options` and `@other_options`, allowing both `:model` and `'model'` keys.

### 6.4 The start\_chat / current\_chat branch pattern

```
start_chat (immutable seed)
    │
    ├── branch → current_chat (conversation A)
    ├── branch → current_chat (conversation B)   [via start(chat)]
    └── ...
```

`Chat#branch` does `self.annotate(self.dup)` — a shallow copy. The `start_chat`
is the persistent prefix; `current_chat` is the working copy.

### 6.5 Template + clone pattern for multi-agent

```
@society (templates)               @chats (live instances)
────────────────────               ──────────────────────
"Worker"  → Agent (template)        "Worker/default"     → Agent (clone)
"Critic"  → Agent (template)        "Worker/analysis_1"  → Agent (clone)
                                    "Critic/default"     → Agent (clone)
```

Templates are loaded once (`LLM.load_agent`). Each named conversation gets a
deep clone (`clone_social_agent`) so their `start_chat`, `other_options`, and
conversation state are fully independent.

### 6.6 Inheritance modes as a flexibility knob

The three `SOCIAL_INHERIT_MODES` create a spectrum of coupling:

```
none         →  fully sandboxed specialist (no caller context)
tools        →  shared capabilities, private history (default)
conversation →  shared everything (tightly coupled pair)
```

This lets an orchestrator agent control how much context each specialist
receives on a per-call basis — the model itself can choose `inherit` per tool
invocation.

### 6.7 Scout chat-file syntax as a security boundary

`ask_agent` deliberately uses `agent.user(prompt)` instead of
`agent.prompt(prompt)` because `prompt` parses chat-file syntax, which could
allow prompt injection to escalate privileges (e.g., injecting `tool:` lines).
The `user` method only appends a single `user`-role message, making delegation
safe even with untrusted LLM-generated prompts.

### 6.8 Workflow integration via `chat_task`

`agent/workflow.rb` defines `Workflow#chat_task` which creates Scout workflow
tasks that:

1. Accept a `chat` input (Scout chat-file format).
2. Load an agent via the `agent` helper.
3. Run the agent to completion.
4. Project the result back with `Chat.project(job.short_path, result)`.
5. Log delegated agent chats via `log_agent`.

This bridges the Agent abstraction into Scout's dependency-tracked,
cacheable workflow execution model.

### 6.9 Context truncation as implicit iteration limiting

Rather than a hard loop counter, the system bounds multi-turn depth through
`Chat.shorten_tools` in `prompt.rb`: tool calls/outputs beyond
`MAX_TOOL_CALLS` (40) are truncated, and those beyond `MAX_TOOL_OUTPUTS` are
dropped. This naturally constrains the context window and indirectly limits how
many tool-call rounds a conversation can sustain before the model "forgets"
earlier tool outputs.

---

## Appendix: Method Reference Table

### Public methods added by each module

| Method | Source | Purpose |
|---|---|---|
| `ask(messages, options)` | `agent.rb` | Core inference entry point. |
| `prompt(messages, options)` | `agent.rb` | Parse string as chat, prefix with start\_chat, then `ask`. |
| `start(chat)` | `chat.rb` | Create/reset the current conversation. |
| `current_chat` | `chat.rb` | Lazy accessor for the active conversation. |
| `chat(options)` | `chat.rb` | One round-trip, appending to current\_chat. |
| `respond(...)` | `chat.rb` | Alias for `ask(current_chat, ...)`. |
| `json(...)` / `json_format(...)` | `chat.rb` | Structured JSON extraction. |
| `iterate(prompt, &block)` | `iterate.rb` | Extract a JSON array, iterate over it. |
| `iterate_dictionary(prompt, &block)` | `iterate.rb` | Extract a JSON dict, traverse it. |
| `socialize(options)` | `delegate.rb` | Register the generic `ask` tool for multi-agent delegation. |
| `delegate(agent, name, desc, &block)` | `delegate.rb` | Register a named `hand_off_to_*` tool. |
| `ask_agent(name, prompt, ...)` | `delegate.rb` | Programmatic delegation to a specialist. |
| `load_agent(name, options)` | `delegate.rb` | Load (or retrieve cached) specialist template. |
| `load_chat(name, options, conv, inherit:)` | `delegate.rb` | Get/create a named specialist conversation. |

### Private methods in delegate.rb

| Method | Purpose |
|---|---|
| `normalize_social_agent_name` | Validate agent name against regex. |
| `normalize_social_conversation_name` | Validate conversation name. |
| `normalize_social_inherit` | Validate inherit mode. |
| `social_chat_key` | Build `"agent/conversation"` key. |
| `social_agent_options` | Merge + strip private options for specialist. |
| `social_duplicate` | Recursive deep-copy (Hash/Array/String). |
| `social_chat_copy` | Deep-copy a Chat array. |
| `clone_social_agent` | Clone a template agent with isolated state. |
| `start_social_chat` | Create a new specialist conversation with inherited context. |
| `social_caller_context` | Extract non-start\_chat messages from current chat. |
| `social_inherited_context` | Resolve context based on inherit mode. |
| `social_tool_parameters` | Parse tool-call parameters, handle legacy `chat` arg. |
