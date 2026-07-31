> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# 04 — AgentWorkflow: The Agent-as-Workflow Bridge

> **Primary source file:** `lib/scout/llm/agent/workflow.rb` (170 lines)
> **Related source files:**
> - `lib/scout/llm/agent.rb` (constructor, `ask`, `workflow` method, `load_agent`)
> - `lib/scout/llm/agent/chat.rb` (`start_chat`, `current_chat`, `chat`)
> - `lib/scout/llm/agent/iterate.rb` (`iterate`, `iterate_dictionary`)
> - `lib/scout/llm/chat/persist.rb` (`.chat` extension registration, save/load drivers)
> - `lib/scout/llm/chat/process/meta.rb` (`Chat.project`, `Chat.serialize_meta`, `jobs`)
> - `lib/scout/llm/chat/process/tools.rb` (`Chat.allow_dir`, `Chat.allow_read_dir`)
> - `lib/scout/llm/chat/prompt.rb` (`full_tool_calls`, `max_tool_outputs`)
> - `lib/scout-gear/.../workflow/definition.rb` (`include_workflow`, `TYPE_EXTENSIONS`)
> - `lib/scout-gear/.../workflow/step/file.rb` (`files_dir`, `file`)
> - SC26 workflows: `Planned`, `Critic`, `Branched`, `Refined`, `InterpretData`

---

## 1. What AgentWorkflow Is

`AgentWorkflow` is a Scout **Workflow module** that provides a compact DSL for
declaring **chat tasks** — Scout workflow tasks whose inputs, outputs, and
persistence are all built around the `Chat` abstraction.  When a Workflow module
writes `self.include_workflow AgentWorkflow`, it gains:

| Helper / construct     | Kind            | Purpose                                                   |
|------------------------|-----------------|-----------------------------------------------------------|
| `chat_task`            | DSL declaration | Define a workflow task of type `:chat` with a chat input   |
| `chat`                 | Instance helper | Parse or build the task's `Chat` from the `chat` input     |
| `options`              | Instance helper | Extract `LLM.options` from the current chat               |
| `agent`                | Instance helper | Factory: load an `LLM::Agent`, wire it to this job        |
| `agent_options`        | Instance helper | Strip private keys from an options hash                   |
| `tooling`              | Instance helper | Extract tool/kb/mcp/introduce messages from the chat       |
| `tooling_intro`        | Instance helper | Subset of `tooling` containing only `introduce` messages  |
| `log_agent`            | Instance helper | Persist an agent's chats into the job's `log/` directory  |
| `add_chat_dependencies`| Instance helper | Register chat-referenced jobs as Scout dependencies        |

It also patches `Workflow.require_workflow` and `LLM::Agent` (see §10).

---

## 2. Module Structure and `include_workflow`

### 2.1 Definition

```ruby
module AgentWorkflow
  extend Workflow          # ← it is itself a Workflow module

  helper :chat do |chat=nil| ... end
  helper :options do ... end
  helper :agent do |name=nil, chat:nil, options:nil, tooling:nil, files:nil, **kwargs| ... end
  helper :log_agent do |agent, agent_name=nil| ... end
  # ... other helpers

  # Plus the chat_task definition patched into Workflow (see §3)
end
```

### 2.2 How `include_workflow` extends a host module

`Workflow#include_workflow` (defined in `scout-gear/lib/scout/workflow/definition.rb`,
line 233) performs a **five-step merge**:

```ruby
def include_workflow(workflow)
  workflow.documentation
  self.asynchronous_exports += workflow.asynchronous_exports
  self.synchronous_exports += workflow.synchronous_exports
  self.exec_exports += workflow.exec_exports
  self.stream_exports += workflow.stream_exports
  self.tasks.merge! workflow.tasks              # ← merge task definitions
  self.tasks.each{|_,t| t.workflow = workflow }
  self.helpers.merge! workflow.helpers          # ← merge helper definitions
  self.include workflow                         # ← Ruby module inclusion
end
```

**Effect:** all helpers defined inside `AgentWorkflow` become callable inside
the host module's task blocks (`self.agent`, `self.chat`, etc.).  The host does
not need to re-define any of them.

### 2.3 Canonical usage pattern

Every SC26 pipeline workflow follows the same two-line preamble:

```ruby
module Planned
  extend Workflow
  self.include_workflow AgentWorkflow    # ← gains all helpers + chat_task
  # ...
end
```

---

## 3. `chat_task` — The Core DSL Construct

### 3.1 Declaration syntax

```ruby
chat_task :task_name do
  # ... arbitrary Ruby that builds and returns an Agent or Hash
end
```

This is defined not inside the `AgentWorkflow` module body but as a **patch on
`Module`** (via `class << self` inside the `Workflow` module reopening):

```ruby
module Workflow
  def chat_task(task_name, &block)
    input :chat, :text, 'Chat in Scout-AI chat-file format'
    task task_name => :chat do |chat|
      # ... execution body (see §3.3)
    end
  end
end
```

Because `Workflow` is reopened at the class level, `chat_task` is available to
**every** Workflow module that has `require`'d the agent library, not just those
that explicitly `include_workflow AgentWorkflow`.  However, to use `self.agent`
and the other helpers inside the block, `include_workflow AgentWorkflow` (or
equivalent) is required.

### 3.2 Differences from a regular `task`

| Aspect                  | `task :name => :type do ... end`      | `chat_task :name do ... end`                     |
|------------------------|---------------------------------------|--------------------------------------------------|
| **Input**              | Manually declared with `input`        | Automatically declares `input :chat, :text, ...` |
| **Type**               | Any registered type (`:string`, `:tsv`, etc.) | Always `:chat`                            |
| **File extension**     | Determined by `TYPE_EXTENSIONS[type]` | Always `.chat` (registered by `persist.rb`)     |
| **Return processing**  | Raw return value is the result        | `LLM::Agent` → auto-processed via `agent.chat` or differential; `Hash` → wrapped; error → JSON error message |
| **Provenance**         | Manual                                | `Chat.project(self.short_path, result)` called automatically |
| **Agent logging**      | Manual                                | `log_agent(agent)` called automatically when the block returns an Agent |
| **Error handling**     | Propagates exceptions                 | `ScoutException` → graceful error message in chat format |

### 3.3 The full execution body (annotated)

```ruby
task task_name => :chat do |chat|
  begin
    # 1. Execute the user's block.  The block can return:
    #    - an LLM::Agent (most common)
    #    - a Hash (single message)
    #    - an Array (raw message list)
    #    - anything else (returned as-is)
    response = self.instance_exec(&block)

    # 2. Normalize the response into a message array
    result = if LLM::Agent === response
      agent = response
      # If the last message is from the user, the model hasn't responded yet.
      # Run the agent's chat to get the assistant's response.
      if agent.current_chat.last[:role].to_s == 'user'
        agent.chat(return_messages: true)
      else
        # Already responded; extract only the messages after start_chat
        agent.current_chat - agent.start_chat
      end.tap { log_agent(agent) }       # ← persist agent chats to log/

    elsif Hash === response
      [response]                          # single message

    else
      response                            # pass through (Array, etc.)
    end

    # 3. Tag the result with a provenance meta-message and return
    Chat.project(self.short_path, result)

  rescue ScoutException
    # 4. On expected failure, produce an error message in chat format
    error = { role: :assistant,
              content: { exception: $!, job: self.short_path }.to_json }
    Chat.project(self.short_path, [error])
  end
end
```

### 3.4 Key design decisions

1. **Block return value determines behavior.** Returning an `Agent` triggers the
   full lifecycle (auto-run, log, project). Returning raw data is also supported.

2. **Lazy execution.** If the block sets up an agent but the last message is
   still `:user`, `chat_task` calls `agent.chat(return_messages: true)` to
   trigger inference. If the block already ran the agent (e.g., `agent.json`),
   the last message is `:assistant` and the differential is returned directly.

3. **Automatic provenance.** Every result is wrapped with `Chat.project`, which
   prepends a `{:role => :meta, :content => "job=<short_path>"}` marker.

4. **Graceful degradation.** `ScoutException` (the agent-level exception class)
   is caught and converted to a JSON error message, not propagated as a crash.

---

## 4. The `chat` Helper

```ruby
helper :chat do |chat=nil|
  @chat ||= begin
    chat = recursive_inputs[:chat]      # pull from recursive input chain
    chat = Chat.parse(chat) if String === chat
    Chat.setup(chat)
    chat
  end
end
```

**Behavior:**
- Memoized (`@chat ||= ...`): the chat is parsed once and reused.
- Pulls the raw `chat` input from `recursive_inputs`, which is Scout's mechanism
  for passing inputs down a dependency chain.  In `chat_task`, this is the `chat`
  parameter value.
- If the value is a String, it is parsed via `Chat.parse` (YAML/markdown →
  message array). If already a Chat (or Array), it is set up in-place.
- Returns a `Chat` instance (an Array annotated with the `Chat` module).

**Usage in task blocks:**
```ruby
chat_task :ask do
  chat = self.chat          # ← the parsed input chat
  chat.follow step(:request).load  # ← append dependency results
  # ...
end
```

---

## 5. The `options` Helper

```ruby
helper :options do
  @options ||= LLM.options self.chat
end
```

Extracts LLM configuration options (endpoint, model, parameters, etc.) from the
current chat.  `LLM.options` reads these from special `:option` role messages
embedded in the chat (e.g., `{:role => :option, :content => "model gpt-4o"}`).

These options are typically passed to the `agent` helper to configure the
loaded agent.

---

## 6. The `agent` Helper — The Factory Method

This is the most important helper. It loads (or retrieves a cached) `LLM::Agent`,
configures it with tooling, chat context, system messages, and files, and
returns it ready for use.

### 6.1 Signature

```ruby
helper :agent do |name = nil, chat: nil, options: nil, tooling: nil,
                   files: nil, **kwargs|
```

| Parameter   | Type            | Default        | Description                                       |
|-------------|-----------------|----------------|---------------------------------------------------|
| `name`      | String / Symbol / `nil` | `nil`  | Agent name to load via `LLM.load_agent`. `nil` creates a bare agent. |
| `chat`      | Chat / Array / `nil`   | `nil`  | Conversation context to follow into the agent's start_chat |
| `options`   | Hash / `nil`    | `self.options` | LLM options (model, endpoint, parameters, etc.)   |
| `tooling`   | Array / `nil`   | `self.tooling` | Tool/introduce/kb/mcp messages to prepend         |
| `files`     | Array / `nil`   | `nil`          | File paths to attach to the agent's chat          |
| `**kwargs`  | varies          | —              | Merged into options via `IndiferentHash.add_defaults` |

### 6.2 What it does, step by step

```ruby
# Step 1: Resolve defaults
options = self.options if options.nil?     # inherit task's LLM options
tooling = self.tooling  if tooling.nil?    # inherit task's tooling
options = IndiferentHash.add_defaults options, kwargs  # merge keyword args

# Step 2: Load the agent
agent = LLM.load_agent name, agent_options(options)
agent.job = self                           # link agent to this workflow step

# Step 3: Inject tooling
agent.start_chat.follow tooling if tooling && !tooling.empty?

# Step 4: System messages about job context
agent.start_chat.system "Your current working directory is #{Dir.pwd}."
agent.start_chat.system "You are working through an ask job with path #{self.path}..."
agent.start_chat.system "Tool call content may be truncated after #{Chat.full_tool_calls}, ..."
# (these let the agent know about its sandbox boundaries)

# Step 5: Dependency context (if the workflow has deps)
if dependencies.any?
  agent.start_chat.system "This workflow job has the following dependencies:\n#{rec_dependencies...}"
end

# Step 6: Cross-job awareness
if chat && !chat.empty?
  other_jobs = LLM.chat(chat.dup).jobs
  if other_jobs.any?
    agent.start_chat.system "There are other jobs found in this chat:\n#{other_jobs...}"
  end
end

# Step 7: File attachments
files.each do |path|
  target = file(path)
  if File.exist?(target.find)
    agent.start_chat.file target
  elsif File.exist?(path.find)
    agent.start_chat.file path
  end
end if files

# Step 8: Inject conversation context (with filtering)
if chat && !chat.empty?
  chat = LLM.chat(chat)
  # Remove stale assignment/context messages from previous pipeline steps
  chat.reject! { |msg| msg[:content].to_s.start_with? 'You have been assigned' }
  chat.reject! { |msg| msg[:content].to_s.start_with? 'This workflow job has the following' }
  chat.reject! { |msg| msg[:content].to_s.start_with? 'There are other jobs found in this chat' }
  agent.start_chat.follow chat
end

agent
```

### 6.3 What it returns

An `LLM::Agent` instance with:
- `agent.job` set to the current `Step` (for provenance tracking)
- `agent.start_chat` populated with tooling, system messages, and context
- Ready for `.user(...)` / `.chat(...)` / `.json(...)` calls

### 6.4 The `agent_options` sub-helper

```ruby
helper :agent_options do |options|
  IndiferentHash.setup options.except(:agent, 'agent', :chat, 'chat')
end
```

Strips `:agent` and `:chat` keys from the options hash before passing to
`LLM.load_agent`. This prevents infinite recursion (load_agent would try to
re-parse the chat input).

### 6.5 Context filtering — a subtle but important detail

When a chat is followed into the agent's start_chat, three categories of
messages are **stripped**:

1. `"You have been assigned"` — assignment prompts from prior pipeline steps
2. `"This workflow job has the following"` — dependency listings from prior steps
3. `"There are other jobs found in this chat"` — cross-job awareness messages

This prevents context bloat as chats flow through multi-step pipelines.

---

## 7. The `tooling` and `tooling_intro` Helpers

### 7.1 `tooling`

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

**What it does:** Extracts all configuration messages from the input chat that
define the agent's capabilities:
- `:tool` — tool definitions (JSON schemas)
- `:kb` — knowledge base definitions
- `:mcp` — Model Context Protocol server definitions
- `:introduce` — agent introduction/instruction messages

These are **removed** from the chat (mutating it) and **returned** as a combined
array. The memoization (`@tooling ||=`) means the extraction happens once.

**Effect:** The tooling messages are extracted so they can be selectively
re-injected into agents via the `agent` helper's `tooling:` parameter. This
allows different agents in the same pipeline to receive different subsets of
tools.

### 7.2 `tooling_intro`

```ruby
helper :tooling_intro do
  self.tooling.select { |msg| msg[:role] == 'introduce ' }
end
```

**Note the trailing space in `'introduce '`** — this is present in the source
code. This selects only the `introduce` role messages, which contain agent
instruction/context prose. It is used when an agent should receive the
introduction context but not the actual tool definitions (e.g., a Planner agent
that should understand the available tools conceptually but not call them).

**Typical usage in SC26:**
```ruby
# Planner gets intros only (no actual tools to call)
agent = self.agent :Planner, chat: chat, tooling: self.tooling_intro

# Worker gets full tooling (tools + intros)
agent = self.agent worker_agent, chat: chat, tooling: self.tooling

# Final report agent gets no tools at all
agent = self.agent :User, tooling: false, chat: chat
```

---

## 8. The `log_agent` Helper — Provenance Persistence

### 8.1 Signature and behavior

```ruby
helper :log_agent do |agent, agent_name=nil|
  dir = agent_name ? file('log')[agent_name] : file('log')

  agent.chats.each do |name, other|
    dir.society[name].set_extension('chat').write other.current_chat.print
    #add_chat_dependencies(other.current_chat)   # ← commented out
  end if agent.chats

  dir['agent.chat'].write agent.current_chat.print
  #add_chat_dependencies(agent.current_chat)      # ← commented out

  update_info :dependencies, dependencies.collect { |dependency| dependency.path.find }
  agent
end
```

### 8.2 What it persists

| File written                         | Content                                           |
|--------------------------------------|---------------------------------------------------|
| `<files_dir>/log/agent.chat`         | The agent's full current_chat (all messages)      |
| `<files_dir>/log/<agent_name>/agent.chat` | Same, but under a named subdirectory            |
| `<files_dir>/log/<agent_name>/society/<delegated_name>.chat` | For each agent in the society hash, its current chat |

### 8.3 Provenance trail

These persisted `.chat` files are the **evidence trail** for what an agent did.
They are discoverable by:
- `Chat.job_agent_chat_files(job)` — globs `job.file('log').glob('**/*.chat')`
- The `ChatAnalyst` agent's `Session.discover_job` method
- The `scout llm prov` command

### 8.4 `add_chat_dependencies` (currently commented out)

```ruby
helper :add_chat_dependencies do |chat|
  chat.jobs.each do |job_path|
    next if job_path.to_s == self.short_path.to_s
    next if dependencies.find{|dep| dep.path.find == job_path.find }
    begin
      job = Step.load(job_path)
      dependencies << job unless dependencies.select{|dep| dep.path}.include?(job)
    rescue
    end
  end
end
```

This would register any jobs referenced in the chat's meta messages as Scout
dependencies of the current step. The calls are commented out in the current
source, meaning cross-job dependency links are **not** automatically
established at present. The `update_info` call at the end of `log_agent` still
writes the dependency list to the step's info file.

### 8.5 Auto-invocation

`log_agent` is called **automatically** by `chat_task` when the block returns an
`LLM::Agent` (see §3.3, the `.tap { log_agent(agent) }` call). You rarely call
it manually — unless you are managing multiple agents in a single task (as the
`Branched` workflow does).

---

## 9. The `.chat` Extension and Persistence

### 9.1 Registration

`lib/scout/llm/chat/persist.rb` registers the `.chat` extension:

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

### 9.2 How chat task results are saved and loaded

1. **On save** (`Persist.save_drivers[:chat]`):
   - If the result is an `LLM::Agent`: saves `current_chat - start_chat` (only the
     new messages, not the preamble).
   - If the result is an Array: saves all messages.
   - Uses `Open.sensible_write` (atomic write with temp file + rename).
   - Serialization format is `LLM.print(chat)` — human-readable chat markup.

2. **On load** (`Persist.load_drivers[:chat]`):
   - Reads the file content as a string and parses it with `LLM.chat(string)`.
   - Returns a `Chat` instance.

3. **File location**: `<step.path>` (which already has no extension for chat
   types, since the extension is `:chat` and `TYPE_EXTENSIONS[:chat] = :chat`).
   The job result file IS the `.chat` file.

4. **Loading a dependency's chat**: `step(:dep_name).load` returns the parsed
   Chat object, which can then be `follow`ed into the current chat.

### 9.3 The `Chat.project` function

```ruby
def self.project(job, messages)
  projected = Array(messages).reject { |message| message[:role].to_s == 'meta' }.collect(&:dup)
  return [] if projected.empty?
  [{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected
end
```

**Purpose:** When a chat task completes, its result messages are "projected"
from the job. The projection:
1. Strips any existing `:meta` messages (to avoid accumulation).
2. Prepends a single `:meta` marker with `job=<short_path>`.
3. Returns the tagged message array.

This meta marker is how downstream tasks and the `Chat.jobs` method discover
which job produced a given chat segment.

### 9.4 The `Chat.jobs` method

```ruby
def job_paths
  role_messages(:meta).collect do |message|
    Path.setup(Chat.parse_meta(message[:content])[:job])
  end.compact.uniq
end
alias jobs job_paths
```

Scans the chat for `:meta` role messages, parses each one to extract the `job=`
key, and returns the list of job paths. This is how the system builds the
provenance graph: a chat that follows another job's output inherits its meta
markers, and `chat.jobs` reveals all contributing jobs.

---

## 10. Patches to Existing Classes

### 10.1 `Workflow.require_workflow` — agent-aware fallback

```ruby
class << self
  alias require_workflow_old require_workflow
end

def self.require_workflow(name, ...)
  begin
    require_workflow_old(name, ...)
  rescue => e
    begin
      LLM.load_agent(name).workflow    # ← if not a regular workflow, try loading as agent
    rescue
      raise e
    end
  end
end
```

When `Workflow.require_workflow("SomeAgent")` fails because no standard workflow
file exists, it falls back to loading the name as an agent and extracting its
`.workflow`. This is how agent-based workflows like `Planned` are resolved.

### 10.2 `LLM::Agent#job=` — provenance link

```ruby
class LLM::Agent
  attr_accessor :job
end
```

This adds a `job` accessor to every agent. The `agent` helper sets
`agent.job = self` (the current Step). This allows the agent's `ask` method to
detect when it is running inside a workflow and route inference through the
workflow's own `:ask` task (see §11.2).

---

## 11. Job Context Propagation

### 11.1 How context flows into agents

When the `agent` helper is called inside a `chat_task` block, the agent receives:

1. **Tooling** — from `self.tooling` (extracted from the input chat)
2. **Options** — from `self.options` (extracted from `:option` messages in the chat)
3. **Conversation** — from the `chat:` parameter (typically `self.chat`)
4. **System context** — CWD, job path, files_dir, dependency paths
5. **Files** — from the `files:` parameter, resolved via `Step#file`

### 11.2 How agents route back through workflows

When an agent has a `workflow` with an `:ask` task AND has `job` set (meaning it
is running inside a `chat_task`), its `ask` method does NOT call `LLM.ask`
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

The `no_ask_override` flag (set to `true` in the `Critic` workflow's agent
helper) bypasses this routing and calls `LLM.ask` directly.

### 11.3 Directory permissions

The agent's `ask` method calls:
```ruby
Chat.allow_dir job.files_dir          # write access for tool calls
Chat.allow_read_dir workflow.directory  # read access for workflow resources
```

These register thread-local allowed directories that the tool execution sandbox
respects. This is how agents get controlled filesystem access.

---

## 12. The `chat_task` Lifecycle (End-to-End)

```
┌──────────────────────────────────────────────────────────────────────┐
│                        DECLARATION PHASE                             │
│                                                                      │
│  chat_task :my_task do                                               │
│    # 'self' is the Step instance                                     │
│    # self.chat → parsed Chat from input                              │
│    # self.options → LLM options from chat                            │
│    # self.tooling → extracted tool/kb/mcp/introduce messages         │
│    agent = self.agent :MyAgent, chat: self.chat                      │
│    agent.user "Do something"                                         │
│    agent     # ← return value                                        │
│  end                                                                 │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      EXECUTION PHASE (chat_task body)                │
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
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│                   RESULT PROCESSING (chat_task wrapper)              │
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

## 13. Real Usage Examples from SC26

### 13.1 Planned — Linear Pipeline (`Agent/Planned/workflow.rb`)

The canonical multi-step agent pipeline. Each `chat_task` depends on the
previous one, building up context through `chat.follow`:

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

  dep :search                            # ← conditional dependency
  chat_task :plan do
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:search).load.last if step(:search)
    chat.message :clear_tools, true      # ← strip tools from context
    agent = self.agent :Planner, chat: chat, tooling: self.tooling_intro
    agent.user "Elaborate a plan..."
    agent
  end

  dep :plan
  chat_task :work do
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:plan).load.last
    chat.message :clear_tools, true
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
    agent = self.agent :User, tooling: false, chat: chat  # ← no tools
    agent.user "Please elaborate a final report..."
    agent
  end
end
```

**Pattern: Linear dependency chain with context accumulation.** Each step:
1. Declares `dep :previous_step`
2. Follows previous step's output into the chat
3. May clear tools to focus the agent
4. May use different tooling levels (`tooling_intro` vs `tooling` vs `false`)

### 13.2 Critic — Direct Inference (`Agent/Critic/workflow.rb`)

Uses `no_ask_override: true` to bypass workflow routing:

```ruby
module Critic
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :ask do
    agent = self.agent :Critic, chat: chat, no_ask_override: true
    agent.user "Evaluate the previous work."
    response = agent.chat return_messages: true
    begin
      set_info :json, Chat.parse_json(response.answer)
    rescue
    end
    agent
  end
end
```

**Pattern: Structured output with side-effect metadata.** The `set_info` call
writes parsed JSON to the step's info file, making it queryable via Scout's
metadata system.

### 13.3 Branched — Parallel Fan-out (`Agent/Branched/workflow.rb`)

Uses `log_agent` manually for multiple agents, and `iterate_dictionary` for
parallel execution:

```ruby
chat_task :work do
  # ... spliter agent produces a JSON dict of sub-tasks ...

  reports = {}
  spliter.iterate_dictionary nil, cpus: 8, bar: self.progress_bar('Branches'),
                              into: reports do |name, instructions|
    log name, "Start #{name}"
    worker = self.agent worker_agent, chat: plan.dup, tooling: tooling
    worker.user "Produce sub-task (#{name}):\n\n#{instructions}"
    reports[name] = worker.chat
    log_agent worker, "worker-#{name}"    # ← manual logging with named subdir
    log name, "Done #{name}"
    [name, worker.chat]
  end

  log_agent spliter, 'spliter'            # ← log the spliter too

  # ... critic aggregates reports ...
end
```

**Pattern: Manual agent management with parallel execution.** Key techniques:
- `iterate_dictionary` for JSON-dict-driven parallel fan-out
- `chat: plan.dup` to give each branch an independent copy of the plan
- Manual `log_agent` calls with distinct names for each branch
- `self.progress_bar` for visual feedback

### 13.4 Refined — Iterative Loop (`Agent/Refined/workflow.rb`)

Uses `TryAgain` exception for control flow:

```ruby
chat_task :ask do
  worker = self.agent worker_agent, chat: chat, tooling: self.tooling
  critic = self.agent :Critic, chat: chat

  round = 1
  begin
    worker.user "Execute the work..."
    report = worker.chat

    critic.user "Below is the workers report"
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

  {role: :assistant, content: evaluation.to_json}
end
```

**Pattern: Worker-critic loop with exception-driven retry.** Key techniques:
- `raise TryAgain` + `retry if TryAgain === $!` for loop control
- Round-specific `log_agent` names for provenance
- `:clear_tools` between rounds to manage context
- Returns a Hash (not an Agent) — the chat_task wrapper handles it

### 13.5 InterpretData — Dynamic Tool Definition (`Agent/InterpretData/workflow.rb`)

Uses `agent.workflow do ... end` to define tasks inline:

```ruby
chat_task :gather do
  analyst = self.agent :Analyst, chat: chat, tooling: self.tooling

  artifact_dir = file('artifacts')

  analyst.workflow do
    desc "Write an artifact to file"
    input :name, :string, 'Name of the artifact', nil, required: true
    input :content, :text, 'Content of the artifact', nil, required: true
    task :write_artifact => :string do |name, content|
      artifact_dir[name].write content
    end
    export_exec :write_artifact
  end

  analyst.user "Analyze the data and save artifacts..."
  analyst
end
```

**Pattern: Runtime tool injection.** The `agent.workflow do ... end` block
calls `LLM::Agent#workflow(&block)` which does `workflow.instance_eval(&block)`,
adding tasks to the agent's workflow module. These tasks become callable tools
for the agent. The `export_exec` makes them available as executable tools.

---

## 14. How Tooling Flows Through Workflows to Agents

```
┌─────────────────────────────────────────────────────────────────┐
│ Input Chat (from user or upstream task)                         │
│                                                                 │
│  Messages with roles:                                           │
│    :introduce  → "You are the Planner agent..."                 │
│    :tool       → {"type":"function","function":{...}}           │
│    :kb         → knowledge base definitions                     │
│    :mcp        → MCP server definitions                         │
│    :option     → "model gpt-4o"                                 │
│    :user       → "Please analyze the data..."                   │
│    :assistant  → (prior responses)                              │
│    :meta       → "job=Planned/request/abc123"                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ chat_task body                                                  │
│                                                                 │
│  self.tooling ──→ removes :tool, :kb, :mcp, :introduce from chat │
│                   returns them as a combined array              │
│                   (memoized: extracted once)                    │
│                                                                 │
│  self.tooling_intro ──→ subset of tooling: only :introduce msgs │
│                                                                 │
│  self.options ──→ LLM.options(self.chat) extracts :option msgs  │
│                                                                 │
│  self.agent(:MyAgent,                                           │
│    chat: self.chat,         ← conversation (minus tooling)      │
│    tooling: self.tooling,   ← full tooling (default)            │
│    options: self.options    ← LLM config (default)              │
│  )                                                              │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ agent.start_chat (after agent helper)                           │
│                                                                 │
│  [tooling messages]         ← :tool, :kb, :mcp, :introduce      │
│  [system messages]          ← CWD, job path, deps               │
│  [conversation messages]    ← filtered chat context             │
│  [file attachments]         ← if files: param given              │
│                                                                 │
│  Then agent.user("prompt") adds the task prompt                 │
│  Then agent.chat() triggers inference                           │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Tooling is **extracted** from the input chat (mutating it)
and **selectively re-injected** into each agent. This allows different agents
in the same pipeline to have different tool sets:

| Agent type | `tooling:` param | What the agent gets |
|---|---|---|
| Planner | `self.tooling_intro` | Only introductions (understands tools conceptually, can't call them) |
| Worker | `self.tooling` | Full tooling (can call all tools) |
| User (final report) | `false` | No tools at all (pure text synthesis) |
| Critic | (not specified → `self.tooling`) | Full tooling by default |

---

## 15. Design Patterns and When to Use AgentWorkflow

### 15.1 When to use `chat_task` vs regular `task`

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

### 15.2 When to use `include_workflow AgentWorkflow`

**Always include it when:**
- You define `chat_task`s (the task type needs the helpers)
- You use `self.agent`, `self.chat`, `self.tooling`, etc.

**You don't need it when:**
- Your workflow has only regular tasks (no agent interaction)
- You're using agent delegation purely at the agent level (not through workflows)

### 15.3 Provenance patterns

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

### 15.4 Common idioms

| Idiom | Code | Purpose |
|---|---|---|
| Follow dependency output | `chat.follow step(:dep).load` | Append a dependency's chat result |
| Follow only the last message | `chat.follow step(:dep).load.last` | Get just the final answer |
| Clear tools for focus | `chat.message :clear_tools, true` | Remove tool definitions from context |
| Configurable worker agent | `options[:worker_agent] \|\| 'Worker'` | Allow runtime agent selection |
| Conditional dependency | `dep :search do \|jobname,options\| ... end` | Skip search if `use_search` is false |
| Named agent logging | `log_agent agent, "worker-#{name}"` | Create subdirectories for multiple agents |
| Structured metadata | `set_info :json, parsed_json` | Store parsed output in step info |
| Exception-driven retry | `raise TryAgain; retry if TryAgain === $!` | Loop control in iterative patterns |

---

## 16. Method Reference Summary

| Method | Defined in | Signature | Returns | Auto-called? |
|---|---|---|---|---|
| `chat_task` | `Workflow` (patched) | `(name, &block)` | — | No (DSL) |
| `chat` | `AgentWorkflow` helper | `(chat=nil)` | `Chat` | No |
| `options` | `AgentWorkflow` helper | `()` | `Hash` | No |
| `agent` | `AgentWorkflow` helper | `(name=nil, chat:nil, options:nil, tooling:nil, files:nil, **kwargs)` | `LLM::Agent` | No |
| `agent_options` | `AgentWorkflow` helper | `(options)` | `Hash` | No (internal) |
| `tooling` | `AgentWorkflow` helper | `()` | `Array<Hash>` | No |
| `tooling_intro` | `AgentWorkflow` helper | `()` | `Array<Hash>` | No |
| `log_agent` | `AgentWorkflow` helper | `(agent, agent_name=nil)` | `LLM::Agent` | Yes (by `chat_task` when block returns Agent) |
| `add_chat_dependencies` | `AgentWorkflow` helper | `(chat)` | void | No (commented out) |
| `Chat.project` | `Chat` class method | `(job, messages)` | `Array<Hash>` | Yes (by `chat_task`) |
| `Chat.jobs` / `job_paths` | `Chat` instance | `()` | `Array<Path>` | No |

---

## 17. Relationship to the Broader Agent Ecosystem

```
                         ┌─────────────────────┐
                         │   LLM::Agent        │
                         │   (stateful wrapper) │
                         └────────┬────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
    ┌─────────▼──────┐  ┌────────▼────────┐  ┌───────▼────────┐
    │ agent/chat.rb  │  │ agent/delegate  │  │ agent/workflow │
    │ (conversation  │  │ (multi-agent    │  │ (AgentWorkflow │
    │  lifecycle)    │  │  delegation)    │  │  + chat_task)  │
    └────────────────┘  └─────────────────┘  └───────┬────────┘
                                                      │
                                           ┌──────────▼──────────┐
                                           │  Scout Workflow     │
                                           │  (persistence,      │
                                           │   dependencies,     │
                                           │   provenance,       │
                                           │   scheduling)       │
                                           └─────────────────────┘
```

`AgentWorkflow` is the **integration layer** that connects the Agent abstraction
to Scout's Workflow system. It provides:
- **Task abstraction:** `chat_task` makes agent conversations first-class
  workflow steps
- **Persistence:** Results are automatically saved as `.chat` files with
  proper serialization
- **Provenance:** `Chat.project` + `log_agent` create a complete evidence trail
- **Composability:** Dependencies between chat tasks enable complex pipelines
- **Configurability:** Tooling and options flow through the chat input,
  allowing runtime configuration

---

*This document covers `lib/scout/llm/agent/workflow.rb` in full and cross-references
all related source files. For the broader agent class and delegation mechanics,
see `03_agent_and_delegation.md`. For multi-agent orchestration patterns, see
`08_multi_agent_patterns.md`.*
