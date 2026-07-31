# Delegation

**Delegation** is how one Scout-AI agent invokes another.  It enables multi-agent
systems: an orchestrator agent can delegate sub-tasks to specialist agents,
each with its own persona, tools, and conversation history.

Scout-AI provides **three delegation mechanisms**:

1. **The `ask` tool** (`socialize`) — a generic tool exposed to the LLM at
   inference time, letting the model itself choose when and to whom to delegate.
2. **The `delegate` method** — a programmatic Ruby API that pre-registers
   named `hand_off_to_<name>` tools for specific agents.
3. **`hand_off_to_<name>` tools** — auto-generated tools, one per named agent
   in the social network.

All three share a common substrate: the **social inheritance modes** that
control how much caller context flows to the specialist.

Related docs:

- [Agent.md](Agent.md) — the `LLM::Agent` abstraction (state, chat, `ask`)
- [AgentWorkflow.md](AgentWorkflow.md) — using agents inside Scout workflows
- [MultiAgentPatterns.md](MultiAgentPatterns.md) — real-world multi-agent patterns
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and the calling protocol
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model

---

## 1. The three SOCIAL_INHERIT_MODES

Every delegation involves a **caller** (the agent that delegates) and a
**specialist** (the agent that receives the delegation).  A critical question
is: *how much of the caller's context should the specialist see?*

Scout-AI defines exactly three modes, declared in the `SOCIAL_INHERIT_MODES`
constant:

```ruby
SOCIAL_INHERIT_MODES = %w[none tools conversation].freeze
```

| Mode | What the specialist inherits | Typical use case |
|---|---|---|
| **`none`** | Nothing. The specialist starts fresh with only its own `start_chat`. | Fully isolated sub-agent; no context leakage |
| **`tools`** *(default)* | The caller's declarative tooling (roles: `introduce`, `tool`, `mcp`, `kb`) but **not** the conversation history. | Give the specialist the same tool capabilities without sharing history |
| **`conversation`** | The caller's entire current chat **minus** its own `start_chat` prefix. | Full context sharing for deeply collaborative work |

### How inheritance is implemented

```ruby
def social_inherited_context(inherit)
  case inherit
  when 'none'
    Chat.setup([])
  when 'tools'
    tooling = self.current_chat.tooling    # extract :tool, :kb, :mcp, :introduce
    social_chat_copy(tooling)
  when 'conversation'
    social_caller_context                 # everything after start_chat
  end
end
```

The specialist's `start_chat` is rebuilt as:

```
[specialist's original start_chat] + [inherited context from caller]
```

So the specialist always gets its **own** system prompt first, then optionally
the caller's tools or full conversation.

### When `inherit` is consulted

`inherit` is only consulted **once** — when a conversation is first created.
Follow-up turns in the same named conversation reuse the existing specialist
instance with its accumulated history.  Changing `inherit` on a follow-up call
has no effect.

---

## 2. The `ask` tool (socialize)

### 2.1 What it is

`Agent#socialize` registers a single tool named `:ask` in the agent's tool
list.  When the LLM invokes this tool during inference, it can delegate to
**any** specialist agent by name:

```ruby
agent = LLM.load_agent(:Orchestrator)
agent.socialize                        # ← wires up the :ask tool
agent.chat                             # the model can now call :ask during inference
```

### 2.2 The tool schema exposed to the model

| Parameter | Type | Required | Description |
|---|---|---|---|
| `agent` | string | ✅ | Name of the specialist agent |
| `prompt` | string | ✅ | Plain-text prompt (one user message) |
| `conversation` | string | ❌ | Named conversation identifier. Omit for one-shot; reuse to continue a conversation |
| `inherit` | enum `[none, tools, conversation]` | ❌ (default `tools`) | Context policy — only applies when creating a **new** conversation |

### 2.3 Legacy `chat` parameter compatibility

Older versions used a single `chat` parameter.  It is silently accepted via
`social_tool_parameters` for backward compatibility:

| Legacy `chat` value | Maps to `conversation` | Maps to `inherit` |
|---|---|---|
| `'current'` | `'current'` | `'conversation'` |
| `''`, `'none'`, `'false'` | `nil` (one-shot) | `'none'` |
| any other name | that name | `'tools'` |

New code should use `conversation` and `inherit` as separate parameters.

### 2.4 The tool block (executed when the LLM calls `ask`)

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
text answer.  The block captures `social_options` (a deep-duplicated copy of
the caller's `other_options` minus private keys) in its closure.

### 2.5 Security: `user` vs `prompt`

`ask_agent` uses `agent.user(prompt)` rather than `agent.prompt(prompt)`.
This is deliberate: `prompt` parses String input as Scout chat-file syntax,
which could allow prompt injection to escalate privileges (e.g., injecting
`tool:` lines to grant tools).  The `user` method only appends a single
`user`-role message, making delegation safe even with untrusted LLM-generated
prompts.

---

## 3. The `delegate` method (programmatic)

### 3.1 What it is

`Agent#delegate` is a Ruby API that pre-registers a named
`hand_off_to_<name>` tool for a **specific** agent instance:

```ruby
worker = LLM.load_agent(:Worker)
agent.delegate(worker, :worker, "Delegate work to the Worker agent")
```

After this call, the model sees a tool named `hand_off_to_worker` and can
invoke it to hand off a message to the Worker.

### 3.2 Signature

```ruby
def delegate(agent, name, description, task_name = nil, &block)
```

| Parameter | Description |
|---|---|
| `agent` | An `LLM::Agent` instance (pre-loaded) to delegate to |
| `name` | Tool name suffix: creates `hand_off_to_#{name}` |
| `description` | Tool description shown to the model |
| `task_name` | Optional workflow task name (for workflow-integrated delegation) |
| `&block` | Optional custom tool block (default block shown below) |

### 3.3 Default tool block

```ruby
block ||= Proc.new do |_name, parameters|
  message = parameters[:message]
  new_conversation = parameters[:new_conversation]
  agent.start if new_conversation    # reset conversation
  agent.user message
  agent.chat                         # get response
end
```

### 3.4 Tool schema

| Parameter | Type | Required | Description |
|---|---|---|---|
| `message` | string | ✅ | Message to pass to the agent |
| `new_conversation` | boolean | ❌ (default false) | If true, erase history and start fresh |

---

## 4. `delegate` vs `ask` vs `hand_off_to_<name>`

| Aspect | `socialize` (ask tool) | `delegate` (programmatic) | `hand_off_to_<name>` tools |
|---|---|---|---|
| **Agent selection** | Model chooses at call time (`agent` param) | Hard-coded at registration time | Hard-coded at generation time |
| **Tool name** | `:ask` (single tool for all agents) | `hand_off_to_#{name}` (one per agent) | `hand_off_to_#{name}` (one per agent) |
| **Custom block** | No (fixed block) | Yes (caller can supply `&block`) | No (auto-generated) |
| **Conversation mgmt** | Named conversations via `conversation` param | Single conversation, resettable via `new_conversation` | Single conversation, resettable |
| **When created** | On-demand by `socialize` | Explicit `delegate` call in Ruby | Auto-generated for agents in the social network |
| **Inheritance modes** | Per-call (`inherit` param) | Fixed (determined at delegate time) | Fixed |

### When to use each

- **`socialize`** — when the orchestrator should decide dynamically which
  specialist to call.  Best for open-ended tasks where the model needs
  flexibility.

- **`delegate`** — when you want tight control over which agents exist and how
  their tools are described.  Best for fixed pipelines where the set of
  specialists is known at design time.

- **`hand_off_to_<name>`** — auto-generated tools for agents in the social
  network.  These are created when an agent's workflow defines its social
  network (the set of agents it can delegate to).  They provide a simpler
  interface than the generic `ask` tool.

---

## 5. Socialized chat files: persistence and tracking

### 5.1 Conversation keys are scoped by agent

Each delegated conversation is tracked in the caller's `@chats` hash, keyed by
`"agent_name/conversation_name"`:

```ruby
def social_chat_key(agent_name, conversation)
  conversation = normalize_social_conversation_name(conversation) if conversation
  "#{agent_name}/#{conversation || 'default'}"
end
```

This means `Worker/work_A` and `Critic/work_A` are **completely independent**
conversations, even though they share the conversation name `work_A`.

### 5.2 Template + clone pattern

```
@society (templates)               @chats (live instances)
────────────────────               ──────────────────────
"Worker"  → Agent (template)        "Worker/default"     → Agent (clone)
"Critic"  → Agent (template)        "Worker/analysis_1"  → Agent (clone)
                                    "Critic/default"     → Agent (clone)
```

- Templates are loaded **once** via `LLM.load_agent` and cached in `@society`.
- Each named conversation gets a **deep clone** (`clone_social_agent`) so
  their `start_chat`, `other_options`, and conversation state are fully
  independent.

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

`social_duplicate` is a recursive deep-copy that avoids `Marshal.load/dump`
— important because tool blocks (Procs) cannot be marshalled but are simply
passed by reference (they fall into the `else` branch).

### 5.3 Logging delegated conversations

When an agent runs inside a `chat_task` (via `AgentWorkflow`), the
`log_agent` helper persists all delegated conversations:

| File written | Content |
|---|---|
| `<files_dir>/log/agent.chat` | The agent's full `current_chat` |
| `<files_dir>/log/<name>/agent.chat` | Same, under a named subdirectory |
| `<files_dir>/log/<name>/society/<delegated>.chat` | Each delegated agent's conversation |

See [AgentWorkflow.md](AgentWorkflow.md) for details on `log_agent`.

---

## 6. The `ask_agent` delegation engine

Both the `socialize` tool block and programmatic calls route through
`ask_agent`, the core delegation engine:

```ruby
def ask_agent(agent_name, prompt, conversation: nil, inherit: 'tools', options: {})
```

**Flow:**

1. Validate `agent_name` and `inherit` mode.
2. Resolve the specialist instance:
   - If `conversation` is `nil` → uses key `'default'` (a single persistent
     conversation per agent).
   - If `conversation` is provided → uses that named conversation.
3. Load or retrieve the specialist via `load_chat` (template + clone).
4. `agent.user(prompt)` — append the prompt as a user message.
5. The caller's tool block then calls `agent.chat` to get the text response.

### Private option stripping

Before options reach a specialist, private keys are stripped to prevent
leaking session state:

```ruby
SOCIAL_PRIVATE_OPTIONS = %i[
  agent client current_meta format messages no_ask_override
  previous_response_id process return_messages tool_choice tools
].freeze

def social_agent_options(options)
  merged = defaults.merge(supplied)
  SOCIAL_PRIVATE_OPTIONS.each { |name| merged.delete(name) }
  merged
end
```

---

## 7. Practical examples

### 7.1 Socialize pattern (model-driven delegation)

```ruby
# Set up an orchestrator that can delegate to any agent at inference time
orchestrator = LLM.load_agent(:Orchestrator)
orchestrator.socialize

orchestrator.user <<~TXT
  Analyze this codebase. Delegate research to the Searcher agent
  and implementation to the Worker agent as needed.
TXT

response = orchestrator.chat
# During inference, the model may call:
#   ask(agent: "Searcher", prompt: "Find all API endpoints", inherit: "tools")
#   ask(agent: "Worker", prompt: "Add tests for the endpoints", inherit: "conversation")
```

### 7.2 Delegate pattern (programmatic hand-off)

```ruby
# Pre-register specific agents with custom descriptions
orchestrator = LLM.load_agent(:Orchestrator)

searcher = LLM.load_agent(:Searcher)
worker   = LLM.load_agent(:Worker)

orchestrator.delegate(searcher, :searcher,
                      "Delegate research and fact-finding to the Searcher")
orchestrator.delegate(worker, :worker,
                      "Delegate implementation work to the Worker")

# The model now sees two tools: hand_off_to_searcher, hand_off_to_worker
orchestrator.user "Plan and execute a code refactoring task."
orchestrator.chat
```

### 7.3 Named conversation continuity

```ruby
# First call — creates the conversation
ask(agent: "Worker", prompt: "Set up the database schema",
    conversation: "db_work", inherit: "tools")

# Second call — continues the same conversation
ask(agent: "Worker", prompt: "Now add the indexes",
    conversation: "db_work")   # inherit is ignored; conversation already exists
```

### 7.4 Full isolation

```ruby
# Specialist gets no context at all
ask(agent: "Critic", prompt: "Evaluate this code", inherit: "none")
```

### 7.5 Custom delegate block

```ruby
# Custom block with logging
orchestrator.delegate(worker, :worker, "Delegate to Worker") do |_name, params|
  message = params[:message]
  log.info "Delegating to Worker: #{message[0..50]}..."
  worker.user message
  worker.chat
end
```

---

## 8. Decision guide: when to use which mechanism

```
Do you need the model to CHOOSE which agent to call?
│
├── YES → Use socialize (generic :ask tool)
│         The model picks the agent at inference time.
│         Best for: open-ended orchestration, dynamic task routing.
│
└── NO  → Is the set of specialists fixed and known at design time?
          │
          ├── YES → Use delegate (hand_off_to_<name> tools)
          │         Pre-register each specialist with a dedicated tool.
          │         Best for: fixed pipelines, controlled workflows.
          │
          └── NO  → Consider a workflow-based approach
                    (see AgentWorkflow.md and MultiAgentPatterns.md)
```

### Inheritance mode decision

```
How much context does the specialist need?
│
├── None at all (fully sandboxed)        → inherit: 'none'
├── Same tools, but private history      → inherit: 'tools'     (default)
└── Full conversation (tightly coupled)  → inherit: 'conversation'
```

---

## 9. Constants and invariants

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
  alphanumeric, then allow dots, underscores, hyphens.
- **`SOCIAL_PRIVATE_OPTIONS`** — caller options stripped before passing to a
  specialist.

---

## 10. Method reference

### Public methods (from `delegate.rb`)

| Method | Signature | Purpose |
|---|---|---|
| `socialize` | `(options = {})` | Register the generic `:ask` tool for model-driven delegation |
| `delegate` | `(agent, name, description, task_name=nil, &block)` | Register a named `hand_off_to_<name>` tool |
| `ask_agent` | `(agent_name, prompt, conversation:, inherit:, options:)` | Programmatic delegation engine |
| `load_agent` | `(agent_name, options = {})` | Load (or retrieve cached) specialist template |

### Private methods

| Method | Purpose |
|---|---|
| `normalize_social_agent_name` | Validate agent name against regex |
| `normalize_social_conversation_name` | Validate conversation name |
| `normalize_social_inherit` | Validate inherit mode |
| `social_chat_key` | Build `"agent/conversation"` key |
| `social_agent_options` | Merge + strip private options |
| `social_duplicate` | Recursive deep-copy (Hash/Array/String) |
| `social_chat_copy` | Deep-copy a Chat array |
| `clone_social_agent` | Clone template agent with isolated state |
| `start_social_chat` | Create specialist conversation with inherited context |
| `social_caller_context` | Extract non-start_chat messages from current chat |
| `social_inherited_context` | Resolve context based on inherit mode |
| `social_tool_parameters` | Parse tool-call parameters, handle legacy `chat` arg |

---

## Related docs

- [Agent.md](Agent.md) — the `LLM::Agent` abstraction
- [AgentWorkflow.md](AgentWorkflow.md) — using agents inside Scout workflows (where `log_agent` persists delegated chats)
- [MultiAgentPatterns.md](MultiAgentPatterns.md) — real-world multi-agent orchestration patterns
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and the calling protocol
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model
