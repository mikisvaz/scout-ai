> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# SC26 Multi-Agent Orchestration Patterns

This document extracts reusable real-world multi-agent orchestration patterns from the SC26 workflow codebase (`~/git/workflows/SC26/`). Each pattern includes the actual Ruby/Scout code, the abstractions involved, and practical guidance on when to apply it.

---

## Overview of SC26 Agent Ecosystem

### Agent roster

| Agent | Role | Has `workflow.rb`? | Has `start_chat`? | Tooling |
|-------|------|--------------------|--------------------|---------|
| **User** | Intake normalization (restating user requests) and final report synthesis. | No (uses `AgentWorkflow`) | Yes | None (`tool: false` for final report) |
| **Planner** | Produces candidate step-by-step plans with acceptance criteria. | No (invoked inline by Planned pipeline) | Inherits via `Agent/intro` | Same as Worker |
| **Searcher** | Targeted research and evidence gathering (web + docs). | No (invoked inline by Planned pipeline) | Inherits via `Agent/intro` | Web/docs search tools |
| **Worker** | Concrete task execution — writes code, creates artifacts, runs commands. | No | Yes | `ComputerUse`, `Skills` |
| **Critic** | Verifies outputs against acceptance criteria; returns PASS / NEEDS_WORK / BLOCKED. | Yes (`ask` task) | Yes | `ComputerUse` (limited) |
| **Manager** | Orchestrates the budgeted control loop: Search -> Edit -> Score -> Select. Delegates to all specialists via `ask`. | No (orchestrates in conversation) | Yes | `ComputerUse` (delegated), `socialize: true` |
| **Planned** | A complete linear pipeline: request -> search -> plan -> work -> ask. | Yes | No (pipeline defined in code) | Configurable `worker_agent` |
| **Branched** | Splits work into parallel sub-tasks, each handled by a separate worker. Critic aggregates. | Yes | No | Configurable `worker_agent` |
| **Refined** | Iterative worker-critic loop: work -> review -> repair -> repeat until PASS or BLOCKED. | Yes | No | Configurable `worker_agent` |
| **Analyst** | Gathers and processes data into compact, structured artifacts. | No | Yes | `ScoutCoder`, `Skills` |
| **InterpretData** | Two-phase pipeline: Analyst gathers artifacts -> Worker fulfills request using them. | Yes | No | Configurable `worker_agent` |
| **ChatAnalyst** | Inspects persisted chat sessions, agent logs, tool calls, token usage. | Yes | Yes | `ScoutCoder`, `Skills` |

### Relationship map

```
                      ┌─────────────────────────────────────────┐
                      │              Manager                      │
                      │  (budgeted control loop orchestrator)     │
                      └──┬──────┬──────┬──────┬──────┬──────┬────┘
                         │      │      │      │      │      │
                    ask  │ ask  │ ask  │ ask  │ ask  │ ask
                    ▼     ▼      ▼      ▼      ▼      ▼
                  User  Planner Searcher Worker Critic ...

  ┌─────────────────────────────────────────────────────────────┐
  │                    Planned Pipeline                          │
  │  request → search → plan → work → ask                       │
  │  (linear dependency chain, each step is a chat_task)         │
  └─────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────┐
  │                    Branched Pattern                          │
  │  plan → spliter → [worker_1 || worker_2 || ...] → critic    │
  │  (parallel fan-out, then aggregation)                        │
  └─────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────┐
  │                    Refined Pattern                           │
  │  worker → critic → (NEEDS_WORK? retry) → PASS/BLOCKED       │
  │  (iterative refinement loop using TryAgain exception)        │
  └─────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────┐
  │                    InterpretData Pattern                     │
  │  Analyst (gather artifacts) → Worker (fulfill using them)    │
  │  (data-preparation pipeline)                                 │
  └─────────────────────────────────────────────────────────────┘
```

---

## The Planned Pipeline Pattern

### Full structure

The `Planned` module defines a five-stage linear pipeline, each stage being a `chat_task` that depends on the previous one through Scout's `dep` mechanism:

```ruby
module Planned
  extend Workflow
  self.include_workflow AgentWorkflow

  # Stage 1: Normalize the user request
  chat_task :request do
    agent = self.agent :User, chat: chat
    agent.user "Restate the request from the user as self contained instructions..."
    agent
  end

  # Stage 2: Optional search (conditionally skipped)
  dep :request
  chat_task :search do
    chat = self.chat
    chat.follow step(:request).load          # context propagation
    agent = self.agent :Searcher, chat: chat, tooling: self.tooling_intro
    agent.user "Prepare a report that can be used as reference..."
    agent
  end

  # Stage 3: Plan
  dep :search
  chat_task :plan do
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:search).load.last if step(:search)  # optional
    chat.message :clear_tools, true
    agent = self.agent :Planner, chat: chat, tooling: self.tooling_intro
    agent.user "You have been asked to fulfill a user request. Elaborate a plan"
    agent
  end

  # Stage 4: Execute the plan
  dep :plan
  chat_task :work do
    worker_agent = options[:Planned_worker_agent] || options[:worker_agent] || 'Worker'
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:plan).load.last
    chat.message :clear_tools, true
    agent = self.agent worker_agent, chat: chat, tooling: self.tooling
    agent.user "Proceed with the plan"
    agent
  end

  # Stage 5: Final report
  dep :work
  chat_task :ask do
    chat = self.chat
    chat.follow step(:request).load
    chat.follow step(:plan).load
    chat.follow step(:work).load
    chat.message :clear_tools, true
    agent = self.agent :User, tooling: false, chat: chat
    agent.user "Please elaborate a final report for the User."
    agent
  end
end
```

### Task chaining via dependencies

Each `chat_task` is preceded by a `dep` declaration:
- `dep :request` before `:search` — search depends on request.
- `dep :search` before `:plan` — plan depends on search.
- `dep :plan` before `:work` — work depends on plan.
- `dep :work` before `:ask` — ask depends on work.

Scout's dependency system ensures that when you run `Planned/ask`, it automatically resolves the entire chain: `request -> search -> plan -> work -> ask`, caching each result.

### Conditional dependency skipping

The `search` step can be conditionally skipped:

```ruby
dep :search do |jobname, options|
  options = LLM.options LLM.chat(options[:chat].dup)
  if options[:use_search] == 'true'
    { inputs: options, jobname: jobname }
  else
    { task: :request, inputs: options, jobname: jobname }  # re-route to request
  end
end
```

When `use_search` is not `'true'`, the dependency block returns `{task: :request, ...}`, effectively short-circuiting the search step and routing directly to `request`. Downstream steps check `if step(:search)` to conditionally follow search results.

### The `chat.follow` mechanism for context propagation

Context flows between stages via `chat.follow`:

```ruby
chat.follow step(:request).load       # Append all messages from the request stage
chat.follow step(:plan).load.last      # Append only the last (answer) message
chat.follow step(:work).load           # Append all messages from the work stage
```

Key distinction:
- `step(:request).load` — loads the **full chat** from the request job and appends all messages.
- `step(:plan).load.last` — loads the chat but appends only the **final assistant message** (the plan), avoiding context bloat.

This is a critical pattern: you can choose to propagate the full conversation or just the distilled answer, depending on how much context the downstream agent needs.

### How artifacts flow between stages

- Each `chat_task` returns an `agent` object whose `.chat` (or `.answer`) is the persisted output.
- The next stage accesses the previous stage's output via `step(:stage_name).load`, which loads the persisted chat.
- `chat.follow` selectively appends messages to build the context for the next agent.
- `chat.message :clear_tools, true` is called before each non-worker stage to strip tool definitions from the propagated context, preventing agents from seeing irrelevant tools.

### Configurable worker agent

The pipeline supports swapping the worker:

```ruby
worker_agent = options[:Planned_worker_agent] || options[:worker_agent] || 'Worker'
```

This allows using `ScoutCoder` or any custom agent as the execution backend by passing `worker_agent=ScoutCoder`.

---

## The Manager Control Loop Pattern

### Overview

The Manager is the most sophisticated orchestration pattern. It is **not defined in a `workflow.rb`** — instead, it operates entirely through its system prompt and the `ask` tool during a live conversation. The control loop is described in prose in `start_chat` and executed by the LLM at runtime.

### Search -> Edit -> Score -> Select cycle

From the Manager system prompt:

```
Default control loop:
1. Normalize the task into explicit objectives, assumptions, missing information, success criteria, and artifacts.
2. Ask Planner for 2 to 4 candidate plans.
3. Ask Critic to score the candidate plans and recommend:
   - a primary branch
   - a fallback branch
   - whether targeted search is needed before execution
4. Execute only one plan step at a time.
5. After each executed step, ask Critic to verify the result and return:
   - status, score, missing checks, smallest next action, branch advice
6. If Critic returns NEEDS_WORK, prefer this order:
   - minimal repair of the current step
   - targeted search to unblock that step
   - local replan of the current branch
   - branch switch
7. Stop when acceptance tests pass or the budget is exhausted.
8. If blocked, produce the smallest set of questions for the user.
```

This is a **model-driven control loop**: the LLM decides at each turn what to do next, using the `ask` tool to delegate to specialist agents.

### Budget management (budgeted branching)

The Manager enforces explicit resource budgets:

```
Budget policy:
- Candidate plans: 2 to 4
- Active branches: at most 2
- Broad search rounds before execution: at most 1
- Search during execution: targeted only unless justified
- Repair cycles per step: at most 2
- Full branch switches: at most 1 unless clearly necessary
```

This prevents runaway agent loops where the system keeps trying without converging.

### Branch-specific chats

The Manager uses **named chat identifiers** to keep branch reasoning separated:

```
Keep branch reasoning separated with named chats when useful,
for example `plan_A`, `work_A`, `critic_A`.
```

This means the Manager can maintain parallel reasoning tracks (branch A, branch B) without cross-contaminating context. Each `ask` call specifies a `chat:` parameter to target the right conversation.

### Delegation to specialist agents

The Manager delegates through the `ask` tool. Each delegation prompt follows a structured template:

```
# Introduction
State the broader project context and why this task matters.

# Current state
List the relevant artifacts, assumptions, branch id, previous results, and open issues.

# Design
Explain how the task should be approached, including framework constraints,
implementation guidance, and validation expectations.

# Task
State exactly what the target agent must do now.

# Output required
Specify the expected sections, decisions, or files to return.
```

The Manager's `socialize: true` setting means it can see and interact with all specialist agents.

### Manager test example

The Manager test shows a real-world delegation pattern:

```
Use the SC26 to find out the TFs for each timepoint for each treatment and save
each of them in tmp/<treatment_name>.json. To avoid overpopulating the context
with tool calls, ask the Worker agent to process each treatment and save the
results separately in a new conversation. Call the Worker with ask once per treatment.
```

Key pattern: **batch processing via repeated `ask` calls with separate chats** — each treatment gets its own Worker conversation to avoid context overflow.

---

## The Critic Pattern

### What the Critic does

The Critic is a **verification-only agent**. It never fixes problems — it only reports them. From `start_chat`:

```
Your primary job is to verify results against the request and the plan.

Review principles:
- Be strict and evidence-based.
- Inspect relevant files directly when possible.
- Do not rely only on the summary from other agents when you can verify something.
- Prefer the smallest next repair.
- If the task is blocked by a missing technical fact, indicate that search is needed.

Do not attempt to fix a problem. Just report it.
```

The Critic has limited `ComputerUse` access — it can read files and run verification commands, but it is instructed not to make changes.

### PASS / NEEDS_WORK / BLOCKED decision model

The Critic returns a JSON decision:

```json
{
  "name": "critic_review",
  "type": "object",
  "properties": {
    "status": { "type": "string", "description": "PASS, NEEDS_WORK, or BLOCKED" },
    "summary": { "type": "string" },
    "issues": { "type": "array", "items": { "type": "string" }, "default": [] },
    "next_step": { "type": "string", "default": "" },
    "search_needed": { "type": "boolean", "default": false }
  },
  "required": ["status", "summary", "issues", "next_step", "search_needed"],
  "additionalProperties": false
}
```

Three outcomes:
- **PASS** — Acceptance criteria met. Work is complete.
- **NEEDS_WORK** — Issues found but fixable. `next_step` describes the smallest repair.
- **BLOCKED** — Cannot proceed without external input or missing information. `search_needed` indicates whether search could help.

### Critic workflow

The `workflow.rb` for the Critic is minimal:

```ruby
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
```

Key details:
- `no_ask_override: true` — prevents the Critic from being given `ask` tool capabilities (it should not delegate).
- `Chat.parse_json(response.answer)` — parses the Critic's JSON response and stores it as job info metadata.
- The Critic uses the existing `chat` context (whatever the calling workflow has accumulated).

### How scoring is consumed

Other workflows consume the Critic's JSON:

In **Refined**:
```ruby
json = critic.json
evaluation = IndiferentHash.setup(json)
case evaluation[:status]
when 'NEEDS_WORK'  # triggers retry
when 'PASS'         # done
when 'BLOCKED'      # stop
end
```

In **Branched**:
```ruby
critic = self.agent :Critic, chat: chat, tooling: self.tooling
# ... feeds all sub-task reports ...
# critic reviews the aggregate
```

In **Manager**: the Critic's JSON is used to decide the next action in the control loop.

---

## The Branched Pattern

### What branching means

The Branched pattern **fans out** a single plan into multiple parallel sub-tasks. A "spliter" agent (an unnamed agent using the accumulated chat context) divides the work into sub-tasks, each assigned to a separate Worker in its own conversation.

### Full structure

```ruby
module Branched
  extend Workflow
  self.include_workflow AgentWorkflow

  # Reuse Planned's plan task via task_alias
  task_alias :plan, Planned, :plan

  dep :plan
  chat_task :work do
    worker_agent = options[:Branched_worker_agent] || options[:worker_agent] || 'Worker'

    chat = self.chat
    chat.follow step(:search).load if step(:search)
    chat.follow step(:plan).load
    chat.message :clear_tools, true

    # Phase 1: Split the work
    spliter = self.agent nil, chat: chat    # unnamed agent, uses accumulated context
    spliter.user <<-EOF
      Divide the job into parallel branched out sub-tasks...
      Return them as JSON object with names and instructions...
    EOF

    plan = step(:plan).load
    tooling = self.tooling
    reports = {}

    # Phase 2: Execute sub-tasks in parallel
    spliter.iterate_dictionary nil, cpus: 8, bar: self.progress_bar('Branches'), into: reports do |name, instructions|
      log name, "Start #{name}"
      worker = self.agent worker_agent, chat: plan.dup, tooling: tooling
      worker.user "You have been asked to produce one sub-task (#{name}):\n\n#{instructions}"
      reports[name] = worker.chat
      log_agent worker, "worker-#{name}"
      log name, "Done #{name}"
      [name, worker.chat]
    end

    log_agent spliter, 'spliter'

    # Phase 3: Critic aggregates all branch reports
    critic = self.agent :Critic, chat: chat, tooling: self.tooling
    critic.user "The work has been complete in different subtasks. Here are the reports"
    reports.each do |name, report|
      critic.user "Report for sub-task #{name}:\n\n#{report}"
    end
    critic
  end

  dep :work
  chat_task :ask do
    # Final report synthesis
    chat = self.chat
    chat.follow step(:request).load
    chat.follow step(:plan).load
    chat.message :clear_tools, true
    agent = self.agent :User, tooling: false, chat: chat
    agent.user "The work proceeded reports and their review are here\n\n#{step(:work).load.answer}"
    agent.user "Please elaborate a final report for the User."
    agent
  end
end
```

### Key abstractions

1. **`task_alias`** — reuses another workflow's task:
   ```ruby
   task_alias :plan, Planned, :plan
   ```
   This makes `Branched/plan` an alias for `Planned/plan`, inheriting its dependency chain (`request` -> `search` -> `plan`).

2. **Unnamed spliter agent** — `self.agent nil, chat: chat` creates an agent without a specific system prompt. It uses whatever context has been accumulated in the chat. Its job is purely structural: divide work into sub-tasks.

3. **Parallel execution via `iterate_dictionary`**:
   ```ruby
   spliter.iterate_dictionary nil, cpus: 8, bar: self.progress_bar('Branches'), into: reports do |name, instructions|
   ```
   This iterates over the JSON dictionary returned by the spliter, spawning a Worker per entry with up to 8 concurrent executions. Each Worker gets:
   - A **fresh chat** from the plan (`chat: plan.dup`) — not the full accumulated context.
   - The sub-task-specific instructions.

4. **Branch isolation** — each worker gets `plan.dup` (a copy of the plan chat), ensuring branches don't interfere with each other. This is critical for parallel safety.

5. **Aggregation by Critic** — after all branches complete, a single Critic agent receives all reports sequentially:
   ```ruby
   reports.each do |name, report|
     critic.user "Report for sub-task #{name}:\n\n#{report}"
   end
   ```

### When to use

- When a task can be decomposed into independent sub-tasks (e.g., processing each treatment in a dataset separately).
- When parallelism provides speedup (up to `cpus: 8` concurrent workers).
- When sub-tasks share the same plan but operate on different data.

---

## The Refined Pattern

### What refinement means

The Refined pattern is an **iterative worker-critic loop**. Unlike branching (which fans out horizontally), refinement iterates vertically: the same worker attempts the task, the critic reviews, and if the result is not good enough, the worker tries again with the critic's feedback.

### Full structure

```ruby
module Refined
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :ask do
    worker_agent = options[:Refined_worker_agent] || options[:worker_agent] || 'Worker'

    chat = self.chat
    worker = self.agent worker_agent, chat: chat, tooling: self.tooling
    critic = self.agent :Critic, chat: chat

    round = 1
    begin
      # Worker executes
      worker.user "Execute the work you have been assigned and write a report for the Critic agent."
      report = worker.chat

      # Critic evaluates
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
        # Feed evaluation back to worker
        worker.user "The Critic has done this evaluation and proposed more work."
        worker.user evaluation.to_json
        worker.message :clear_tools, true
        critic.message :clear_tools, true
        raise TryAgain    # exception-based retry

      when 'PASS'
        # Done — fall through

      when 'BLOCKED'
        # Cannot proceed — fall through
      end
    rescue
      retry if TryAgain === $!    # catch TryAgain and retry the begin block
      raise $!
    end

    { role: :assistant, content: evaluation.to_json }
  end
end
```

### How it differs from branching

| Aspect | Refined | Branched |
|--------|---------|----------|
| **Direction** | Vertical (iterative deepening) | Horizontal (parallel fan-out) |
| **Worker count** | 1 worker, multiple rounds | N workers, 1 round each |
| **Critic role** | After each round, triggers retry | Once, after all branches complete |
| **Loop control** | `TryAgain` exception + `retry` | `iterate_dictionary` with `cpus` |
| **Context** | Shared chat accumulates across rounds | Each worker gets `plan.dup` (isolated) |
| **Termination** | Critic says PASS or BLOCKED | All sub-tasks complete |

### The `TryAgain` exception pattern

This is a Scout-ism for controlled retries:

```ruby
raise TryAgain        # inside the begin block
# ...
rescue
  retry if TryAgain === $!    # catches it and re-executes the begin block
  raise $!                     # re-raises any other exception
```

The `retry` keyword re-executes the entire `begin...end` block. State (like `round`) is preserved because it's declared outside the `begin`. This gives the worker a fresh attempt while keeping the accumulated chat context (worker and critic share the same `chat`).

### Clear tools between rounds

```ruby
worker.message :clear_tools, true
critic.message :clear_tools, true
```

After each NEEDS_WORK cycle, tools are cleared from the chat context. This prevents tool definitions from accumulating and bloating the context window across iterations.

---

## The InterpretData Pattern

### Overview

InterpretData is a **data-preparation pipeline** that bridges an Analyst agent (who reduces large data to compact artifacts) with a Worker agent (who uses those artifacts to fulfill the request).

### Full structure

```ruby
module InterpretData
  extend Workflow
  self.include_workflow AgentWorkflow

  # Phase 1: Analyst gathers and processes data into artifacts
  chat_task :gather do
    analyst = self.agent :Analyst, chat: chat, tooling: self.tooling
    artifact_dir = file('artifacts')

    # Dynamically inject a write_artifact task into the Analyst's workflow
    analyst.workflow do
      desc "Write an artifact to file"
      input :name, :string, 'Name of the artifact', nil, required: true
      input :content, :text, 'Content of the artifact', nil, required: true
      task :write_artifact => :string do |name, content|
        artifact_dir[name].write content
      end
      export_exec :write_artifact
    end

    analyst.user <<-EOF
      Analyze the data and save data artifacts.
      For text artifacts prefer the tool write_artifact.
      You may also use other tools, like scripts, to create them but make sure
      to save them in #{artifact_dir}.
      Artifacts may include scripts for other agents to use to access the data.

      Respond with a usage guide to these artifacts. Don't try to fulfill
      completely the user request unless the final answer is obvious.
    EOF
    analyst
  end

  # Phase 2: Worker fulfills the request using gathered artifacts
  dep :gather
  chat_task :ask do
    worker_agent = options[:InterpretData_worker_agent] || options[:worker_agent] || 'Worker'
    chat = self.chat
    chat.follow step(:gather).load
    agent = self.agent worker_agent, chat: chat, tooling: self.tooling
    agent.message :clear_tools, true

    agent.user <<-EOF
      Fulfill the request by using the artifacts:

      #{step(:gather).file('artifacts').glob('**/**') * "\n" }
    EOF
    agent
  end
end
```

### Key abstractions

1. **Dynamic workflow injection** — `analyst.workflow do ... end` defines a new task (`write_artifact`) at runtime and exposes it to the Analyst agent via `export_exec`. This lets the Analyst save files to a controlled directory.

2. **Artifact directory** — `file('artifacts')` creates a directory in the job's files area. Artifacts are persisted there and discoverable by subsequent stages.

3. **Artifact discovery** — the Worker stage lists all files in the artifact directory:
   ```ruby
   step(:gather).file('artifacts').glob('**/**') * "\n"
   ```
   This gives the Worker a file listing to work with, rather than embedding large data in the chat.

---

## The ChatAnalyst Pattern

### Overview

ChatAnalyst is a **meta-agent** — it inspects other agents' sessions rather than performing domain tasks. It is the most structurally complex workflow, with a `Session` class that traverses chat lineages, job dependencies, and agent logs.

### Key features

1. **Session discovery** — recursively follows chat references (`import`, `continue`, `last`) and job references to build a full graph of all related chats and jobs.

2. **Token accounting** — distinguishes between direct inference metadata (`pt`, `ct`, `tt`) and projection markers (`meta job=...`). Only direct metadata is counted; projections require following the job reference.

3. **Tool call analysis** — pairs `function_call`/`mcp_call` messages with `function_call_output` messages by call ID to determine success/failure.

4. **Agent interaction tracking** — identifies `ask` and `hand_off_to_*` calls specifically, useful for understanding delegation patterns.

5. **Exported tasks** — all tasks are `export_exec`, making them callable from CLI:
   ```ruby
   export_exec :message_index, :message_content, :chat_overview,
               :chat_tool_calls, :chat_tokens, :chat_agents, :chat_report
   ```

### Socialized chat files

ChatAnalyst documents the concept of **socialized chats** — projections of agent interactions:

> When a Manager or supervisor agent dispatches work to a specialist agent through the `ask` tool with a named `conversation`, the specialist interaction is persisted as a socialized chat file at:
>
> `<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat`

These are projections, not full logs. They contain the prompt, propagated options, a `meta: job=<path>` marker, and the assistant response — but carry zero direct inference tokens. The actual model calls are found by following the job reference.

---

## Delegation Flows

### How agents delegate to each other

There are two primary delegation mechanisms in SC26:

#### 1. Programmatic delegation (workflow-level)

Used by `Planned`, `Branched`, `Refined`, and `InterpretData`. The workflow code creates agents and drives them:

```ruby
agent = self.agent :Worker, chat: chat, tooling: self.tooling
agent.user "..."
agent.chat    # blocks until the agent responds
```

This is synchronous, deterministic, and part of the Scout dependency graph. Each `chat_task` produces a cached job.

#### 2. Conversational delegation (Manager-level)

Used by the Manager. The Manager uses the `ask` tool during its live conversation:

```
socialize: true
tool: Manager
```

The Manager's `socialize: true` setting gives it access to all specialist agents. It calls `ask` with a target agent name, a prompt, and optionally a named `chat` identifier. This is asynchronous from the workflow perspective — the Manager decides at runtime whom to ask and what to say.

### `socialize` vs `delegate` usage

- **`socialize: true`** (in `start_chat`) — makes the agent able to see and interact with other agents. The Manager has this. It means the agent can use `ask` and `hand_off_to_*` tools.
- **No `socialize` / no `ask` tool** — agents like Worker and Critic cannot initiate delegation (unless explicitly given `ask` tools). The Critic has `no_ask_override: true` to explicitly prevent this.

Context: the Critic CAN ask the Worker questions (`"You have the ability to ask the Worker agent questions to clarify how or why things were done"`), but only for information, not for work.

### Context propagation patterns

| Pattern | Code | Effect |
|---------|------|--------|
| Full chat follow | `chat.follow step(:x).load` | All messages from stage x appended |
| Last message follow | `chat.follow step(:x).load.last` | Only the final answer from stage x |
| Dup for isolation | `chat: plan.dup` | Copy of plan chat, no shared mutation |
| Clear tools | `chat.message :clear_tools, true` | Strip tool definitions from context |
| Inline reference | `#{step(:x).load.answer}` | Embed answer text directly in a prompt |

### Named chat conversations

Named chats allow the Manager to maintain separate conversation threads:

- `plan_A`, `work_A`, `critic_A` — branch A's conversations
- `plan_B`, `work_B`, `critic_B` — branch B's conversations

Each named chat is a separate persisted conversation. The Manager can switch between them by specifying the `chat:` parameter in its `ask` calls. This is how budgeted branching works in practice: the Manager can pursue branch A, and if it fails, switch to branch B without losing either context.

---

## Reusable Patterns Summary

| Pattern | Structure | When to Use | Key Abstractions |
|---------|-----------|-------------|------------------|
| **Planned Pipeline** | `request → search → plan → work → ask` (linear dependency chain) | Well-defined tasks with clear phases; deterministic workflows | `dep`, `chat_task`, `chat.follow`, `task_alias`, conditional deps, configurable `worker_agent` |
| **Manager Control Loop** | `normalize → plan → score → execute → verify → (repair/switch/stop)` (model-driven loop) | Complex, uncertain tasks requiring adaptive decision-making; tasks with multiple solution strategies | `ask` tool, named chats, budget policy, structured delegation prompts, `socialize: true` |
| **Critic Verification** | `work → critic.evaluate → PASS/NEEDS_WORK/BLOCKED` | Any point where verification before continuation is needed | JSON schema response, `Chat.parse_json`, `no_ask_override`, evidence-based review, smallest-next-repair |
| **Branched Fan-Out** | `plan → spliter → [worker_1 ‖ worker_2 ‖ ...] → critic → report` | Embarrassingly parallel sub-tasks; same plan, different data | `iterate_dictionary`, `cpus: N`, `plan.dup` for isolation, unnamed spliter agent, aggregate Critic |
| **Refined Iteration** | `worker → critic → (NEEDS_WORK? retry) → PASS` | Tasks requiring quality convergence; iterative improvement | `TryAgain` exception, `retry`, shared chat across rounds, `clear_tools` between rounds |
| **InterpretData Prep** | `Analyst.gather(artifacts) → Worker.fulfill(artifacts)` | Tasks requiring data reduction before processing; large-volume data handling | Dynamic `analyst.workflow` injection, `export_exec`, artifact directory, `glob` for discovery |
| **ChatAnalyst Meta** | Session graph traversal → structured reports | Debugging agent sessions, analyzing token usage, understanding delegation patterns | `Session` class, recursive discovery, lineage tracking, `Chat.trace_chats`, `Chat.load` |

---

## Cross-Cutting Implementation Details

### `AgentWorkflow` inclusion

Every agent workflow module includes `AgentWorkflow`:

```ruby
module Planned
  extend Workflow
  self.include_workflow AgentWorkflow
```

This provides:
- `self.agent(name, chat:, tooling:)` — creates an agent instance with a given chat context and tooling.
- `self.chat` — access to the current chat.
- `self.tooling` / `self.tooling_intro` — tooling configuration for agents.
- `chat_task` — declares a task whose result is a chat (persisted as a `.chat` file).

### The `agent` factory method

```ruby
agent = self.agent :Worker, chat: chat, tooling: self.tooling
```

Parameters:
- **Agent name** (`:Worker`, `:Critic`, `:User`, `nil`) — selects the agent type. `nil` creates an unnamed agent.
- **`chat:`** — the chat context. Can be the current chat, a dup of another chat, or a named chat.
- **`tooling:`** — what tools to expose. `self.tooling` gives full tools; `self.tooling_intro` gives introductory/descriptive tooling; `false` gives no tools.
- **`no_ask_override:`** — when `true`, prevents the agent from getting `ask` delegation capabilities.

### `log_agent` for provenance

```ruby
log_agent worker, "worker-#{name}"
log_agent critic, "critic-round-#{round}"
```

This persists the agent's full chat log to the job's file area, enabling post-hoc inspection and the ChatAnalyst's analysis.

### Progress bars

```ruby
spliter.iterate_dictionary nil, cpus: 8, bar: self.progress_bar('Branches'), into: reports
```

`self.progress_bar('label')` creates a named progress bar for long-running parallel operations, providing visibility into execution progress.

### `IndiferentHash` for option access

```ruby
evaluation = IndiferentHash.setup(json)
evaluation[:status]   # works with both string and symbol keys
```

This Scout utility makes hash access indifferent to whether keys are strings or symbols — essential when parsing JSON responses from agents.

---

## Pattern Selection Guide

| Situation | Recommended Pattern |
|-----------|-------------------|
| Task has clear phases (understand, research, plan, execute, report) | **Planned Pipeline** |
| Task is complex, uncertain, may need replanning or branch switching | **Manager Control Loop** |
| Task can be split into independent sub-tasks over different data | **Branched** |
| Task requires iterative quality improvement | **Refined** |
| Task involves large datasets that need reduction first | **InterpretData** |
| Need to verify work at any checkpoint | **Critic** (embed in any pattern) |
| Need to analyze past agent sessions | **ChatAnalyst** |
| Need to delegate to a specialist at runtime | **Manager with `ask`** |
| Need to delegate deterministically in a workflow | **Programmatic `self.agent`** |

These patterns can be composed: e.g., a Manager could delegate to a Branched workflow, which internally uses Refined for each branch, with a Critic at each level.
