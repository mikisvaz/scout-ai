# Multi-Agent Orchestration Patterns

Scout-AI lets you compose multiple agents into orchestrated workflows where
each agent has its own persona, tools, and conversation history. The
primitives are small and composable:

- **`AgentWorkflow`** provides the `chat_task` DSL, the `agent` factory, and
  the `log_agent` provenance hook. (See
  [AgentWorkflow.md](AgentWorkflow.md).)
- **Delegation** — via the `ask` tool, the `delegate` method, or
  `hand_off_to_<name>` tools — lets agents invoke each other at runtime. (See
  [Delegation.md](Delegation.md).)
- **`chat.follow`** propagates context (full chats or distilled answers)
  between stages without duplicating it.

On top of these primitives, five recurring patterns emerge. Each is presented
below with its structure, a code sketch, and guidance on when to use it.

---

## Pattern 1: Linear Pipeline

A **linear pipeline** chains agents in a fixed sequence: each stage depends
on the previous one through Scout's `dep` mechanism, and the entire chain is
cached and resumable. The canonical instance is the five-stage *Planned*
pipeline:

```
request → search → plan → work → ask
```

Each stage is a `chat_task`. Context flows between stages via `chat.follow`,
which can append the full previous conversation or just its final answer:

```ruby
module Planned
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :request do
    agent = self.agent :User, chat: chat
    agent.user "Restate the request from the user as self-contained instructions."
    agent
  end

  dep :request
  chat_task :search do
    chat = self.chat
    chat.follow step(:request).load          # full conversation
    agent = self.agent :Searcher, chat: chat, tooling: self.tooling_intro
    agent.user "Prepare a research report usable as reference."
    agent
  end

  dep :search
  chat_task :plan do
    chat = self.chat
    chat.follow step(:request).load.last      # only the distilled answer
    chat.follow step(:search).load.last if step(:search)
    chat.message :clear_tools, true
    agent = self.agent :Planner, chat: chat, tooling: self.tooling_intro
    agent.user "Elaborate a plan with acceptance criteria."
    agent
  end

  dep :plan
  chat_task :work do
    chat = self.chat
    chat.follow step(:request).load.last
    chat.follow step(:plan).load.last
    chat.message :clear_tools, true
    agent = self.agent worker_agent, chat: chat, tooling: self.tooling
    agent.user "Proceed with the plan."
    agent
  end
end
```

### Key ideas

| Mechanism | Effect |
|---|---|
| `dep :stage` | Scout resolves and caches the dependency before running the task. |
| `chat.follow step(:x).load` | Append **all** messages from stage *x*. |
| `chat.follow step(:x).load.last` | Append only the **final answer** — avoids context bloat. |
| `chat.message :clear_tools, true` | Strip tool definitions from the propagated context. |
| `worker_agent` option | Swap the execution backend (e.g. `Worker`, `ScoutCoder`). |

### Conditional skipping

A dependency block can short-circuit a stage:

```ruby
dep :search do |jobname, options|
  opts = LLM.options LLM.chat(options[:chat].dup)
  if opts[:use_search] == 'true'
    { inputs: opts, jobname: jobname }
  else
    { task: :request, inputs: opts, jobname: jobname }  # re-route past search
  end
end
```

Downstream stages guard with `if step(:search)` so they tolerate the skip.

**When to use:** the task has clear, sequential phases (understand → research
→ plan → execute → report) and deterministic control flow.

---

## Pattern 2: Manager Control Loop

The **Manager** pattern is model-driven rather than code-driven. The Manager
agent has `socialize: true`, giving it the `ask` tool, and its system prompt
describes a budgeted control loop that the LLM executes at runtime:

```
normalize → plan (2-4 candidates) → score → execute one step → verify →
  (repair | replan | branch-switch | stop)
```

### Budget management

The Manager's prompt enforces explicit resource ceilings to prevent runaway
loops:

| Budget item | Limit |
|---|---|
| Candidate plans | 2–4 |
| Active branches | at most 2 |
| Broad search rounds | at most 1 |
| Repair cycles per step | at most 2 |
| Full branch switches | at most 1 |

### Branch-specific named chats

The Manager keeps parallel reasoning tracks isolated by using **named chat
identifiers**:

```
plan_A, work_A, critic_A   ← branch A
plan_B, work_B, critic_B   ← branch B
```

Each `ask` call specifies a `chat:` parameter to target the right
conversation, so branch A and branch B never cross-contaminate.

### Structured delegation prompts

Every delegation from the Manager follows a template:

```
# Introduction
State the broader project context and why this task matters.

# Current state
List artifacts, assumptions, branch id, previous results, open issues.

# Design
Explain the approach, framework constraints, validation expectations.

# Task
State exactly what the target agent must do now.

# Output required
Specify the expected sections, decisions, or files to return.
```

### Batch processing

For tasks that fan out over many items, the Manager issues one `ask` call per
item, each in its own conversation, to avoid context overflow:

> Ask the Worker once per treatment, in a separate conversation each time, and
> save results to `tmp/<treatment>.json`.

**When to use:** the task is complex, uncertain, or may require replanning and
branch switching. The Manager adapts at runtime rather than following a fixed
script.

---

## Pattern 3: Parallel Fan-Out

The **Branched** pattern splits a single plan into independent sub-tasks,
executes them concurrently, then aggregates the results through a Critic.

```
plan → spliter → [ worker_1 ‖ worker_2 ‖ … ] → critic → report
```

```ruby
module Branched
  extend Workflow
  self.include_workflow AgentWorkflow

  task_alias :plan, Planned, :plan     # reuse Planned's plan stage

  dep :plan
  chat_task :work do
    worker_agent = options[:worker_agent] || 'Worker'
    chat = self.chat
    chat.follow step(:plan).load
    chat.message :clear_tools, true

    # Phase 1 — split
    spliter = self.agent nil, chat: chat                # unnamed structural agent
    spliter.user "Divide the job into parallel sub-tasks. Return JSON {name: instructions}."

    plan_chat = step(:plan).load
    tooling   = self.tooling
    reports   = {}

    # Phase 2 — execute in parallel
    spliter.iterate_dictionary nil, cpus: 8,
                                bar: self.progress_bar('Branches'),
                                into: reports do |name, instructions|
      worker = self.agent worker_agent, chat: plan_chat.dup, tooling: tooling
      worker.user "Sub-task #{name}:\n\n#{instructions}"
      log_agent worker, "worker-#{name}"
      [name, worker.chat]
    end

    # Phase 3 — aggregate
    critic = self.agent :Critic, chat: chat, tooling: self.tooling
    critic.user "The work was split into sub-tasks. Here are the reports:"
    reports.each { |name, r| critic.user "Report for #{name}:\n\n#{r}" }
    critic
  end
end
```

### Key ideas

| Mechanism | Effect |
|---|---|
| `task_alias :plan, Planned, :plan` | Reuse another workflow's task (and its dependency chain). |
| `self.agent nil, chat: chat` | An unnamed agent that uses accumulated context — purely structural. |
| `iterate_dictionary …, cpus: 8` | Iterate over JSON dictionary with up to 8 concurrent workers. |
| `chat: plan_chat.dup` | Each worker gets an isolated copy of the plan — branches never interfere. |
| Aggregate Critic | One Critic receives all branch reports sequentially for review. |

**When to use:** the task decomposes into independent sub-tasks over
different data (e.g. processing each file or treatment separately) and
parallelism provides speedup.

---

## Pattern 4: Iterative Refinement

The **Refined** pattern loops vertically: one Worker attempts the task, a
Critic reviews, and if the result is not good enough the Worker tries again
with the Critic's feedback.

```
worker → critic.evaluate → NEEDS_WORK? retry → PASS / BLOCKED
```

```ruby
module Refined
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :ask do
    worker = self.agent worker_agent, chat: chat, tooling: self.tooling
    critic = self.agent :Critic, chat: chat

    round = 1
    begin
      worker.user "Execute the work and write a report for the Critic."
      report = worker.chat

      critic.user "Below is the worker's report:\n\n#{report}"
      critic.user "Make an evaluation in JSON."
      evaluation = IndiferentHash.setup(critic.json)

      log_agent worker, "worker-round-#{round}"
      log_agent critic, "critic-round-#{round}"

      case evaluation[:status]
      when 'NEEDS_WORK'
        round += 1
        worker.user "The Critic proposes more work:\n#{evaluation.to_json}"
        worker.message :clear_tools, true
        critic.message :clear_tools, true
        raise TryAgain

      when 'PASS'    # fall through — done
      when 'BLOCKED' # fall through — stop
      end
    rescue
      retry if TryAgain === $!
      raise $!
    end

    { role: :assistant, content: evaluation.to_json }
  end
end
```

### How it works

| Mechanism | Effect |
|---|---|
| `raise TryAgain` + `retry` | Scout-ism for controlled re-execution of the `begin` block. State (`round`) is preserved. |
| Shared `chat` | Worker and Critic accumulate context across rounds — the Critic's feedback is visible to the Worker on the next attempt. |
| `clear_tools` | After each `NEEDS_WORK` cycle, tool definitions are stripped to prevent context bloat. |
| Critic JSON | `{status:, summary:, issues:, next_step:, search_needed:}` drives the loop termination decision. |

### Convergence criteria

The loop ends when the Critic returns **PASS** (acceptance criteria met) or
**BLOCKED** (external input needed). The Critic never fixes problems — it
only reports them and recommends the smallest next repair.

**When to use:** the task requires iterative quality improvement and you can
define clear acceptance criteria.

---

## Pattern 5: Dynamic Tool Injection

The **InterpretData** pattern bridges a data-gathering agent with an
execution agent. What makes it notable is that it **injects a new task into
the agent's workflow at runtime**, giving the agent a custom tool that did
not exist when the workflow was defined.

```ruby
module InterpretData
  extend Workflow
  self.include_workflow AgentWorkflow

  chat_task :gather do
    analyst    = self.agent :Analyst, chat: chat, tooling: self.tooling
    artifact_dir = file('artifacts')

    # Inject a write_artifact task into the Analyst's workflow at runtime
    analyst.workflow do
      desc "Write an artifact to file"
      input :name,    :string, 'Artifact name',  nil, required: true
      input :content, :text,   'Artifact content', nil, required: true
      task :write_artifact => :string do |name, content|
        artifact_dir[name].write content
      end
      export_exec :write_artifact
    end

    analyst.user "Analyze the data and save artifacts to #{artifact_dir}."
    analyst
  end

  dep :gather
  chat_task :ask do
    worker = self.agent worker_agent, chat: chat, tooling: self.tooling
    chat.follow step(:gather).load
    worker.message :clear_tools, true

    files = step(:gather).file('artifacts').glob('**/**') * "\n"
    worker.user "Fulfill the request using these artifacts:\n\n#{files}"
    worker
  end
end
```

### Key ideas

| Mechanism | Effect |
|---|---|
| `analyst.workflow do … end` | Defines a new task at runtime and exposes it via `export_exec`. |
| `file('artifacts')` | A directory in the job's file area for persisted artifacts. |
| `glob('**/**')` | The Worker stage discovers artifacts by listing files, not by embedding large data in the chat. |

**When to use:** the task involves large datasets that need reduction or
pre-processing before the main agent can work with them.

---

## Specialist Agents (e.g. ScoutCoder)

In all of the patterns above, the *worker* role is filled by a generic
`Worker` agent. However, Scout-AI also supports **specialist agents** —
agents that come with domain-specific tooling and knowledge baked into their
`start_chat` and tool definitions.

A concrete example is **ScoutCoder**, a coding specialist that is pre-wired
with deep knowledge of the Scout framework (classes, conventions, APIs) and
the `ScoutCoder` workflow, which provides tools for inspecting Scout source
code, looking up documentation, and navigating the repository structure.

### What makes an agent a "specialist"

| Property | Generic `Worker` | Specialist (e.g. `ScoutCoder`) |
|---|---|---|
| Tooling | `ComputerUse` (filesystem, bash, patch, etc.) | Domain-specific workflow + `ComputerUse` |
| System prompt | Generic step-executor instructions | Domain expertise, conventions, best practices |
| Typical role | Execute any well-defined step | Execute steps requiring domain knowledge |

### How specialists fit into orchestration patterns

Specialist agents are almost always used as **worker agents** within an
existing pattern rather than as top-level orchestrators:

- **Linear Pipeline** — swap `worker_agent: 'ScoutCoder'` when a step involves
  Scout framework coding.
- **Manager Control Loop** — the Manager delegates coding steps to
  `ScoutCoder` via `ask`.
- **Parallel Fan-Out** — each parallel worker can be a specialist when the
  sub-tasks are all within the same domain.
- **Iterative Refinement** — the Worker in the `Refined` loop can be a
  specialist, with a generic `Critic` providing domain-agnostic quality
  checks.

Because specialists implement the same `LLM::Agent` interface, they are
fully interchangeable with `Worker` via the `worker_agent` option — no
changes to the orchestration code are needed.

> See [Agent.md](Agent.md) for how agent tool wiring works
> (`tool:`, `introduce:`, and the `tooling` option in `agent` factory calls).


---

## Budget Management

All patterns benefit from explicit budget management to prevent runaway agent
loops:

| Technique | Where used | Effect |
|---|---|---|
| Prompt-level budget ceilings | Manager pattern | Limits candidate plans, active branches, search rounds, repair cycles. |
| `TryAgain` + fixed `round` counter | Refined pattern | Caps iterations implicitly via Critic's PASS/BLOCKED decisions. |
| `cpus: N` concurrency limit | Branched pattern | Caps parallel worker fan-out. |
| Conditional dependency skipping | Planned pipeline | Avoids unnecessary search when not needed. |

The general principle: **declare resource limits in the agent's system prompt
or in workflow code**, and let the Critic's `PASS` / `NEEDS_WORK` / `BLOCKED`
verdicts drive termination.

---

## Branch-Specific Chats

Named conversations are the mechanism for keeping parallel reasoning tracks
isolated:

```ruby
# Manager delegates to Worker in branch A's conversation
agent.ask :Worker, chat: 'work_A', prompt: "Implement step 1 of plan A"

# Same Manager switches to branch B
agent.ask :Worker, chat: 'work_B', prompt: "Implement step 1 of plan B"
```

Each named chat is a separately persisted `.chat` file. The Manager can switch
between branches by changing the `chat:` parameter, and neither branch sees
the other's context.

In the Branched pattern, isolation is achieved differently: each worker
receives `plan.dup` (a copy of the plan chat), so branches operate on
independent copies.

---

## Pattern Selection Guide

| Situation | Recommended pattern |
|---|---|
| Clear sequential phases | **Linear Pipeline** |
| Complex, uncertain, may need replanning | **Manager Control Loop** |
| Independent sub-tasks over different data | **Parallel Fan-Out** |
| Iterative quality improvement | **Iterative Refinement** |
| Large data needing reduction first | **Dynamic Tool Injection** |
| Verification at any checkpoint | **Critic** (embeddable in any pattern) |

These patterns compose. For example, a Manager can delegate to a Branched
workflow, which internally uses Refined for each branch, with a Critic at
each level.

---

## Related documentation

- [AgentWorkflow.md](AgentWorkflow.md) — the `chat_task` DSL, `agent` factory, `log_agent`.
- [Delegation.md](Delegation.md) — `ask`, `delegate`, `hand_off_to_<name>`, social inheritance modes.
- [Agent.md](Agent.md) — the `LLM::Agent` abstraction.
- [../Chat/Chat.md](../Chat/Chat.md) — the Chat data model and message roles.
- [../Provenance/Provenance.md](../Provenance/Provenance.md) — how to inspect the provenance of a multi-agent run.
