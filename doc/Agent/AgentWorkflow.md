# AgentWorkflow

**AgentWorkflow** is a Scout Workflow mixin that bridges the `LLM::Agent`
abstraction into Scout's dependency-tracked, cacheable workflow execution
model.  It provides:

- **`chat_task`** — a task declaration that automatically wires up chat inputs,
  agent lifecycle, provenance, and persistence.
- **The `agent` helper** — a factory that loads, configures, and wires an
  `LLM::Agent` to the current workflow step.
- **`log_agent`** — persists agent conversations to the job's `log/` directory
  for provenance.
- **Supporting helpers** — `chat`, `options`, `tooling`, `tooling_intro`.

Together, these let you define multi-step agent pipelines as Scout workflows,
where each step is cached, resumable, and produces a full provenance trail.

Related docs:

- [Agent.md](Agent.md) — the `LLM::Agent` abstraction (state, chat, `ask`)
- [Delegation.md](Delegation.md) — how agents delegate to other agents
- [MultiAgentPatterns.md](MultiAgentPatterns.md) — real-world orchestration patterns
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model and message roles
- [../Chat/Persistence.md](../Chat/Persistence.md) — `.chat` file format and provenance
- [../Chat/PromptStrategies.md](../Chat/PromptStrategies.md) — `prepare_prompt` and context truncation

---

## 1. What AgentWorkflow is

AgentWorkflow is a Ruby module that you mix into your Workflow module via
`include_workflow`:

```ruby
module MyPipeline
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :analyze do
    agent = self.agent :Analyst, chat: self.chat
    agent.user "Analyze the data."
    agent
  end
end
```

It provides:

1. **Helper methods** (`agent`, `chat`, `options`, `tooling`, `log_agent`) —
   available inside any `chat_task` block via `self`.
2. **The `chat_task` DSL** — patched onto `Workflow` itself (class-level), so
   it's available to any workflow that has loaded the agent library.

---

## 2. The `chat_task` declaration

### 2.1 How it differs from a regular `task`

| Aspect | Regular `task` | `chat_task` |
|---|---|---|
| **Input** | Manually declared with `input` | Automatically declares `input :chat, :text, 'Chat in Scout-AI chat-file format'` |
| **Type** | Any registered type (`:string`, `:tsv`, etc.) | Always `:chat` |
| **File extension** | Determined by `TYPE_EXTENSIONS[type]` | Always `.chat` (registered by `persist.rb`) |
| **Return processing** | Raw return value is the result | `LLM::Agent` → auto-processed; `Hash` → wrapped; error → JSON error message |
| **Provenance** | Manual | `Chat.project(self.short_path, result)` called automatically |
| **Agent logging** | Manual | `log_agent(agent)` called automatically when block returns an Agent |
| **Error handling** | Propagates exceptions | `ScoutException` → graceful error message in chat format |

### 2.2 Syntax

```ruby
chat_task :task_name do
  # self is the Step instance
  # self.chat     → parsed Chat from input
  # self.options  → LLM options from chat
  # self.tooling  → extracted tool/kb/mcp/introduce messages
  agent = self.agent :MyAgent, chat: self.chat
  agent.user "Do something"
  agent      # ← return value (an LLM::Agent)
end
```

The declaration is defined as a **patch on `Workflow`** (not inside the
`AgentWorkflow` module body), making `chat_task` available to every Workflow
module that has `require`'d the agent library — not just those that explicitly
`include_workflow AgentWorkflow`.  However, to use `self.agent` and the other
helpers, `include_workflow AgentWorkflow` is required.

### 2.3 The full execution body

When a `chat_task` runs, Scout's task machinery wraps the user's block with
automatic lifecycle management:

```ruby
task task_name => :chat do |chat|
  begin
    # 1. Execute the user's block
    response = self.instance_exec(&block)

    # 2. Normalize the response
    result = if LLM::Agent === response
      agent = response
      # If last message is :user, model hasn't responded yet — run inference
      if agent.current_chat.last[:role].to_s == 'user'
        agent.chat(return_messages: true)
      else
        # Already responded — return only messages after start_chat
        agent.current_chat - agent.start_chat
      end.tap { log_agent(agent) }      # ← persist to log/

    elsif Hash === response
      [response]                         # single message

    else
      response                           # pass through (Array, etc.)
    end

    # 3. Tag with provenance meta and return
    Chat.project(self.short_path, result)

  rescue ScoutException
    # 4. Graceful error in chat format
    error = { role: :assistant,
              content: { exception: $!, job: self.short_path }.to_json }
    Chat.project(self.short_path, [error])
  end
end
```

### 2.4 Key design decisions

1. **Block return value determines behavior.** Returning an `Agent` triggers the
   full lifecycle (auto-run, log, project). Returning raw data is also supported.

2. **Lazy execution.** If the block sets up an agent but the last message is
   still `:user`, `chat_task` calls `agent.chat(return_messages: true)` to
   trigger inference. If the block already ran the agent (e.g., `agent.json`),
   the last message is `:assistant` and the differential is returned directly.

3. **Automatic provenance.** Every result is wrapped with `Chat.project`,
   which prepends a `{:role => :meta, :content => "job=<short_path>"}` marker.

4. **Graceful degradation.** `ScoutException` is caught and converted to a JSON
   error message, not propagated as a crash.

---

## 3. The `chat` helper

```ruby
helper :chat do |chat = nil|
  @chat ||= begin
    chat = recursive_inputs[:chat]       # pull from dependency input chain
    chat = Chat.parse(chat) if String === chat
    Chat.setup(chat)
    chat
  end
end
```

- **Memoized** (`@chat ||=`): the chat is parsed once and reused.
- Pulls the raw `chat` input from `recursive_inputs` — Scout's mechanism for
  passing inputs down a dependency chain.
- If the value is a String, it's parsed via `Chat.parse`. If already a Chat or
  Array, it's set up in-place.
- Returns a `Chat` instance (an Array annotated with the `Chat` module).

```ruby
chat_task :my_step do
  chat = self.chat          # ← the parsed input chat
  chat.follow step(:previous).load  # ← append a dependency's chat output
  # ...
end
```

---

## 4. The `options` helper

```ruby
helper :options do
  @options ||= LLM.options(self.chat)
end
```

Extracts LLM configuration (endpoint, model, parameters, etc.) from `:option`
role messages embedded in the chat (e.g., `{:role => :option, :content => "model gpt-4o"}`).
These are typically passed to the `agent` helper.

---

## 5. The `agent` helper — the factory method

This is the most important helper. It loads (or retrieves a cached)
`LLM::Agent`, configures it with tooling, chat context, system messages, and
files, and returns it ready for use.

### 5.1 Signature

```ruby
helper :agent do |name = nil, chat: nil, options: nil, tooling: nil,
                 files: nil, **kwargs|
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `name` | String / Symbol / `nil` | `nil` | Agent name to load via `LLM.load_agent`. `nil` creates a bare agent. |
| `chat` | Chat / Array / `nil` | `nil` | Conversation context to follow into the agent's `start_chat` |
| `options` | Hash / `nil` | `self.options` | LLM options (model, endpoint, parameters) |
| `tooling` | Array / `nil` | `self.tooling` | Tool/introduce/kb/mcp messages to prepend |
| `files` | Array / `nil` | `nil` | File paths to attach to the agent's chat |
| `**kwargs` | varies | — | Merged into options via `IndiferentHash.add_defaults` |

### 5.2 What it does, step by step

```ruby
# Step 1: Resolve defaults
options = self.options if options.nil?      # inherit task's LLM options
tooling = self.tooling  if tooling.nil?     # inherit task's tooling
options = IndiferentHash.add_defaults options, kwargs

# Step 2: Load the agent
agent = LLM.load_agent name, agent_options(options)

# Step 3: Wire to workflow
agent.job = self                            # link agent to this workflow step

# Step 4: Inject tooling
agent.start_chat.follow tooling if tooling && !tooling.empty?

# Step 5: Inject system context (CWD, job path, files_dir, dependencies)
agent.start_chat.system "Current working directory: #{Dir.pwd}"
agent.start_chat.system "Workflow job path: #{self.short_path}"
# ... dependency paths, files_dir, etc.

# Step 6: Inject prompt strategy awareness
agent.start_chat.system "Tool call content may be truncated after #{Chat.full_tool_calls}, " +
                        "and forgotten after #{Chat.max_tool_outputs}."

# Step 7: Inject chat context (filtered)
if chat
  filtered = filter_context(chat)           # strip assignment/dependency messages
  agent.start_chat.follow filtered
end

# Step 8: Attach files
files&.each { |f| agent.start_chat.file f }
```

After all steps, the agent is:
- Loaded and configured with the right options
- `agent.job` set to the current `Step` (for provenance tracking)
- `agent.start_chat` populated with tooling, system messages, and context
- Ready for `.user(...)` / `.chat(...)` / `.json(...)` calls

### 5.3 The `agent_options` sub-helper

```ruby
helper :agent_options do |options|
  IndiferentHash.setup options.except(:agent, 'agent', :chat, 'chat')
end
```

Strips `:agent` and `:chat` keys from the options hash before passing to
`LLM.load_agent`. This prevents infinite recursion (load_agent would try to
re-parse the chat input).

### 5.4 Context filtering

When a chat is followed into the agent's `start_chat`, three categories of
messages are **stripped** to prevent context bloat in multi-step pipelines:

1. `"You have been assigned"` — assignment prompts from prior pipeline steps
2. `"This workflow job has the following"` — dependency listings from prior steps
3. `"There are other jobs found in this chat"` — cross-job awareness messages

---

## 6. The `tooling` and `tooling_intro` helpers

### 6.1 `tooling`

```ruby
helper :tooling do
  @tooling ||= begin
    chat = self.chat
    chat.remove_role(:tool) +
      chat.remove_role(:kb) +
      chat.remove_role(:mcp) +
      chat.remove_role(:introduce)
  end
end
```

Extracts all configuration messages from the input chat that define the agent's
capabilities:
- `:tool` — tool definitions (JSON schemas)
- `:kb` — knowledge base definitions
- `:mcp` — Model Context Protocol server definitions
- `:introduce` — agent introduction/instruction messages

These are **removed** from the chat (mutating it) and **returned** as a combined
array. The memoization means extraction happens once.

**Effect:** Tooling messages are extracted so they can be selectively
re-injected into agents via the `agent` helper's `tooling:` parameter. This
allows different agents in the same pipeline to receive different subsets of
tools.

### 6.2 `tooling_intro`

```ruby
helper :tooling_intro do
  self.tooling.select { |msg| msg[:role] == 'introduce ' }
end
```

> **Note:** The trailing space in `'introduce '` is present in the source code.

Selects only the `introduce` role messages — agent instruction/context prose.
Used when an agent should understand the available tools conceptually but not
call them.

### 6.3 Tooling flow diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ Input Chat (from user or upstream task)                         │
│                                                                 │
│  :introduce  → "You are the Planner agent..."                   │
│  :tool       → {"type":"function","function":{...}}             │
│  :kb         → knowledge base definitions                       │
│  :mcp        → MCP server definitions                           │
│  :option     → "model gpt-4o"                                   │
│  :user       → "Please analyze the data..."                     │
│  :assistant  → (prior responses)                                │
│  :meta       → "job=Planned/request/abc123"                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ self.tooling removes :tool, :kb, :mcp, :introduce from chat     │
│ and returns them as a combined array (memoized)                 │
│                                                                 │
│ self.agent(:MyAgent,                                            │
│   chat: self.chat,         ← conversation (minus tooling)       │
│   tooling: self.tooling,   ← full tooling (default)             │
│   options: self.options    ← LLM config (default)               │
│ )                                                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ agent.start_chat (after agent helper)                           │
│                                                                 │
│  [tooling messages]         ← :tool, :kb, :mcp, :introduce      │
│  [system messages]          ← CWD, job path, deps               │
│  [conversation messages]    ← filtered chat context             │
│  [file attachments]         ← if files: param given             │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Different agents in the same pipeline get different tool sets:

| Agent type | `tooling:` param | What the agent gets |
|---|---|---|
| Planner | `self.tooling_intro` | Only introductions (understands tools conceptually, can't call them) |
| Worker | `self.tooling` | Full tooling (can call all tools) |
| User (final report) | `false` | No tools at all (pure text synthesis) |
| Critic | (not specified → `self.tooling`) | Full tooling by default |

---

## 7. The `log_agent` helper — provenance persistence

### 7.1 Signature and behavior

```ruby
helper :log_agent do |agent, agent_name = nil|
  dir = agent_name ? file('log')[agent_name] : file('log')

  agent.chats.each do |name, other|
    dir.society[name].set_extension('chat').write other.current_chat.print
  end if agent.chats

  dir['agent.chat'].write agent.current_chat.print

  update_info :dependencies, dependencies.collect { |d| d.path.find }
  agent
end
```

### 7.2 What it persists

| File written | Content |
|---|---|
| `<files_dir>/log/agent.chat` | The agent's full `current_chat` (all messages) |
| `<files_dir>/log/<agent_name>/agent.chat` | Same, but under a named subdirectory |
| `<files_dir>/log/<agent_name>/society/<delegated_name>.chat` | Each delegated agent's current chat |

### 7.3 Provenance trail

These `.chat` files are the **evidence trail** for what an agent did. They are
discoverable by:
- `Chat.job_agent_chat_files(job)` — globs `job.file('log').glob('**/*.chat')`
- The `ChatAnalyst` agent's `Session.discover_job` method
- The `scout llm prov` command

### 7.4 Auto-invocation

`log_agent` is called **automatically** by `chat_task` when the block returns
an `LLM::Agent`. You rarely call it manually — unless managing multiple agents
in a single task (as parallel fan-out workflows do).

---

## 8. Job context propagation

### 8.1 How context flows into agents

When the `agent` helper is called inside a `chat_task` block, the agent
receives:

1. **Tooling** — from `self.tooling` (extracted from the input chat)
2. **Options** — from `self.options` (extracted from `:option` messages)
3. **Conversation** — from the `chat:` parameter (typically `self.chat`)
4. **System context** — CWD, job path, `files_dir`, dependency paths
5. **Files** — from the `files:` parameter, resolved via `Step#file`

### 8.2 How agents route back through workflows

When an agent has a `workflow` with an `:ask` task AND has `job` set (meaning
it is running inside a `chat_task`), its `ask` method does NOT call `LLM.ask`
directly. Instead:

```ruby
# From agent.rb, simplified:
if workflow && workflow.tasks.include?(:ask) && !no_ask_override
  job = workflow.job(:ask, chat: Chat.print(messages))
  self.job = job
  Chat.allow_dir job.files_dir
  Chat.allow_read_dir workflow.directory
  job.produce
  messages = Chat.project(job.short_path, LLM.chat(job.path))
else
  LLM.ask messages, ...
end
```

This creates a **nested workflow job** for each inference call, which:
- Is itself cached/persisted as a Scout job
- Has its own `files_dir` for agent-generated artifacts
- Creates a provenance chain (parent job → ask job)
- Can be inspected by `ChatAnalyst` and `scout llm prov`

The `no_ask_override` flag bypasses this routing and calls `LLM.ask` directly
(used by the `Critic` workflow to avoid recursion).

### 8.3 Directory permissions

```ruby
Chat.allow_dir job.files_dir           # write access for tool calls
Chat.allow_read_dir workflow.directory # read access for workflow resources
```

These register thread-local allowed directories that the tool execution sandbox
respects. This is how agents get controlled filesystem access.

---

## 9. The `.chat` extension

### 9.1 Registration

`lib/scout/llm/chat/persist.rb` registers the `.chat` extension with Scout's
`Persist` system:

```ruby
Workflow::TYPE_EXTENSIONS[:chat] = :chat

Persist.save_drivers[:chat] = proc do |file, content|
  case content
  when LLM::Agent
    new_chat = content.current_chat - content.start_chat
    Open.sensible_write(file, LLM.print(new_chat))
  when Array
    Open.sensible_write(file, LLM.print(content))
  else
    # ... stream handling
  end
end

Persist.load_drivers[:chat] = proc do |file|
  String === file ? LLM.chat(file) : file
end
```

### 9.2 Save behaviour

- If the result is an `LLM::Agent`: saves `current_chat - start_chat` (only the
  **new** messages, not the preamble).
- If the result is an Array: saves all messages.
- Uses `Open.sensible_write` (atomic write with temp file + rename).
- Serialization format is `LLM.print(chat)` — human-readable chat markup.

### 9.3 Load behaviour

Reads the file content as a string and parses it with `LLM.chat(string)`.
Returns a `Chat` instance.

### 9.4 `Chat.project` — provenance tagging

```ruby
def self.project(job, messages)
  projected = Array(messages).reject { |m| m[:role].to_s == 'meta' }.collect(&:dup)
  return [] if projected.empty?
  [{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected
end
```

When a chat task completes:
1. Existing `:meta` messages are stripped (avoid accumulation).
2. A single `:meta` marker with `job=<short_path>` is prepended.
3. The tagged array is returned.

This marker is how downstream tasks and `Chat.jobs` discover which job produced
a given chat segment.

### 9.5 `Chat.jobs` — provenance traversal

```ruby
def job_paths
  role_messages(:meta).collect do |message|
    Path.setup(Chat.parse_meta(message[:content])[:job])
  end.compact.uniq
end
alias jobs job_paths
```

Scans the chat for `:meta` messages, extracts `job=` keys, and returns the
list of job paths — building the provenance graph.

---

## 10. Complete working example

### Linear pipeline (Planned-style)

```ruby
module Planned
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :request do
    agent = self.agent :User, chat: chat
    agent.user "Restate the request from the user..."
    agent
  end

  dep :request
  chat_task :search do
    chat = self.chat
    chat.follow step(:request).load       # ← append request's chat output
    agent = self.agent :Searcher, chat: chat, tooling: self.tooling_intro
    agent.user "Prepare a research report..."
    agent
  end

  dep :plan
  chat_task :work do
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:plan).load.last
    chat.message :clear_tools, true       # ← strip tools from context
    agent = self.agent worker_agent, chat: chat, tooling: self.tooling
    agent.user "Proceed with the plan..."
    agent
  end

  dep :work
  chat_task :ask do
    chat = self.chat
    chat.follow step(:request).load
    chat.follow step(:plan).load
    chat.follow step(:work).load
    chat.message :clear_tools, true
    agent = self.agent :User, tooling: false, chat: chat   # ← no tools
    agent.user "Please elaborate a final report..."
    agent
  end
end
```

**Pattern:** Linear dependency chain with context accumulation. Each step:
1. Declares `dep :previous_step`
2. Follows previous step's output into the chat
3. May clear tools to focus the agent
4. Uses different tooling levels (`tooling_intro` vs `tooling` vs `false`)

### Worker-critic loop (Refined-style)

```ruby
chat_task :ask do
  worker = self.agent worker_agent, chat: chat, tooling: self.tooling
  critic = self.agent :Critic, chat: chat

  round = 1
  begin
    worker.user "Execute the work..."
    report = worker.chat

    critic.user "Below is the worker's report"
    critic.user report
    critic.user "Make an evaluation in JSON."
    json = critic.json
    evaluation = IndiferentHash.setup(json)

    log_agent worker, "worker-round-#{round}"
    log_agent critic, "critic-round-#{round}"

    case evaluation[:status]
    when 'NEEDS_WORK'
      round += 1
      worker.user "The Critic has done this evaluation..."
      worker.user evaluation.to_json
      worker.message :clear_tools, true
      critic.message :clear_tools, true
      raise TryAgain
    when 'PASS'
    when 'BLOCKED'
    end
  rescue
    retry if TryAgain === $!
    raise $!
  end

  { role: :assistant, content: evaluation.to_json }
end
```

**Pattern:** Worker-critic loop with exception-driven retry (`raise TryAgain` +
`retry if TryAgain === $!`), round-specific `log_agent` names, and
`:clear_tools` between rounds.

---

## 11. The `chat_task` lifecycle (end-to-end)

```
┌──────────────────────────────────────────────────────────────────────┐
│                        DECLARATION PHASE                             │
│                                                                      │
│  chat_task :my_task do                                               │
│    agent = self.agent :MyAgent, chat: self.chat                      │
│    agent.user "Do something"                                         │
│    agent          # ← return value                                   │
│  end                                                                 │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      EXECUTION PHASE                                 │
│                                                                      │
│  1. Input :chat is parsed → self.chat (memoized)                     │
│  2. Block executed via instance_exec                                │
│  3. self.agent(:MyAgent) called:                                     │
│     a. LLM.load_agent loads agent from filesystem                    │
│     b. agent.job = self (current Step)                               │
│     c. agent.start_chat populated with:                              │
│        - tooling messages (tools, KB, MCP, introductions)            │
│        - system messages (CWD, job path, files_dir, deps)            │
│        - conversation context (filtered chat)                        │
│        - file attachments                                            │
│  4. agent.user("Do something") adds a user message                   │
│  5. Block returns the agent                                          │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────┐
│                   RESULT PROCESSING                                  │
│                                                                      │
│  6. response = block return value (an LLM::Agent)                    │
│  7. Since last message is :user → agent.chat(return_messages: true)  │
│     a. Agent#ask detects workflow.tasks.include?(:ask)               │
│     b. Creates nested workflow job: workflow.job(:ask, chat: ...)    │
│     c. job.produce → runs inference, persists result                 │
│     d. Returns projected messages                                    │
│  8. log_agent(agent) called automatically:                           │
│     a. Writes log/agent.chat (full conversation)                     │
│     b. Writes log/society/*.chat for delegated agents                │
│     c. Updates step info with dependency paths                       │
│  9. Chat.project(self.short_path, result) wraps with provenance meta │
│ 10. Result saved as <step.path> with .chat extension                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 12. When to use `chat_task` vs regular `task`

**Use `chat_task` when:**
- The task's primary input is a Chat (conversation context)
- The task's output should be a `.chat` file
- The task involves agent interaction (loading an agent, sending prompts)
- You want automatic provenance tracking via `Chat.project`
- You want automatic agent logging via `log_agent`

**Use regular `task` when:**
- The input/output types are different (TSV, JSON, etc.)
- The task is pure data transformation with no agent involvement
- You need fine-grained control over persistence

### When to `include_workflow AgentWorkflow`

**Always include it when:**
- You define `chat_task`s (the task type needs the helpers)
- You use `self.agent`, `self.chat`, `self.tooling`, etc.

**You don't need it when:**
- Your workflow has only regular tasks (no agent interaction)
- You're using agent delegation purely at the agent level (not through workflows)

---

## 13. Common idioms

| Idiom | Code | Purpose |
|---|---|---|
| Follow dependency output | `chat.follow step(:dep).load` | Append a dependency's chat result |
| Follow only the last message | `chat.follow step(:dep).load.last` | Get just the final answer |
| Clear tools for focus | `chat.message :clear_tools, true` | Remove tool definitions from context |
| Configurable worker agent | `options[:worker_agent] \|\| 'Worker'` | Allow runtime agent selection |
| Conditional dependency | `dep :search do \|jobname, options\| ... end` | Skip search if `use_search` is false |
| Named agent logging | `log_agent agent, "worker-#{name}"` | Create subdirectories for multiple agents |
| Structured metadata | `set_info :json, parsed_json` | Store parsed output in step info |
| Exception-driven retry | `raise TryAgain; retry if TryAgain === $!` | Loop control in iterative patterns |

---

## 14. Provenance patterns

The AgentWorkflow creates a multi-layered provenance trail:

```
User Chat
  └─ Planned/ask/<id>.chat                    ← final report task
       └─ Planned/work/<id>.chat              ← work task (dep of ask)
            └─ Worker/ask/<id>.chat           ← individual inference calls
                 └─ (LLM.ask cache)           ← raw LLM API call cache
       └─ Planned/plan/<id>.chat              ← plan task (dep of ask)
       └─ Planned/request/<id>.chat           ← request task (dep of ask)
  └─ log/agent.chat                           ← full agent conversations
  └─ log/society/*.chat                       ← delegated agent chats
```

Each level is independently cached, resumable, and queryable by `ChatAnalyst`
and `scout llm prov`.

---

## 15. Method reference

| Method | Defined in | Signature | Returns | Auto-called? |
|---|---|---|---|---|
| `chat_task` | `Workflow` (patched) | `(name, &block)` | — | No (DSL) |
| `chat` | `AgentWorkflow` helper | `(chat = nil)` | `Chat` | No |
| `options` | `AgentWorkflow` helper | `()` | `Hash` | No |
| `agent` | `AgentWorkflow` helper | `(name=nil, chat:, options:, tooling:, files:, **kwargs)` | `LLM::Agent` | No |
| `agent_options` | `AgentWorkflow` helper | `(options)` | `Hash` | No (internal) |
| `tooling` | `AgentWorkflow` helper | `()` | `Array<Hash>` | No |
| `tooling_intro` | `AgentWorkflow` helper | `()` | `Array<Hash>` | No |
| `log_agent` | `AgentWorkflow` helper | `(agent, agent_name=nil)` | `LLM::Agent` | Yes (by `chat_task` when block returns Agent) |
| `Chat.project` | `Chat` class method | `(job, messages)` | `Array<Hash>` | Yes (by `chat_task`) |
| `Chat.jobs` | `Chat` instance | `()` | `Array<Path>` | No |

---

## Related docs

- [Agent.md](Agent.md) — the `LLM::Agent` abstraction (state, chat, `ask`)
- [Delegation.md](Delegation.md) — how agents delegate to other agents (the mechanism behind `log/`society/*.chat`)
- [MultiAgentPatterns.md](MultiAgentPatterns.md) — real-world orchestration patterns
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model and message roles
- [../Chat/Persistence.md](../Chat/Persistence.md) — `.chat` file format and provenance
- [../Chat/PromptStrategies.md](../Chat/PromptStrategies.md) — `prepare_prompt` and context truncation
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and the calling protocol
- [../Backends/Backends.md](../Backends/Backends.md) — backends and inference flow
