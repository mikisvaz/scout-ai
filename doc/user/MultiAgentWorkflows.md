# Multi-Agent Workflows

This page explains how to orchestrate multiple agents inside Scout workflows
for reproducible, pipeline-style AI applications. It is intended for workflow
authors building complex, multi-step agent systems.

**You should read this if:** you want to build pipelines where agents
collaborate, pass artifacts, and produce tracked, reproducible results.

---

## The idea

Scout-AI agents are powerful on their own, but for complex applications you
often need:

- **Multiple steps** — plan, search, execute, review.
- **Specialized agents** — each with different tools and personas.
- **Reproducibility** — the same inputs should produce the same results.
- **Provenance** — you should be able to trace what each agent did.

Scout workflows provide all of this. You define tasks that load and run agents,
and the workflow engine handles caching, dependencies, and provenance.

---

## The chat_task helper

The core building block is `chat_task` — a Scout workflow task that runs an
agent:

```ruby
module MyWorkflow
  extend Workflow
  include_workflow AgentWorkflow
  chat_task :analyze do
    agent = self.agent('Analyst', chat: chat)
    agent.start
    agent.user "Analyze this data."
    result = agent.chat
    agent.answer
  end
end
```

The `chat_task` helper and the `agent` method are available in any workflow
that includes the `AgentWorkflow` mixin. `chat_task` itself is defined on
`Workflow`, so a bare `extend Workflow` module *can* declare one — but the
block shown here calls `self.agent`, which needs the mixin: `extend Workflow`
alone raises `NoMethodError`.

Mix the mixin in with `include_workflow AgentWorkflow`, not plain `include`:
the helpers are class-level state that only `include_workflow` merges, so a
plain `include` leaves the task without `self.agent`/`self.chat`/`log_agent`
at run time (the helpers list would be empty; `test/scout/llm/agent/test_workflow.rb`
covers it).

### What `chat_task` gives you

- **Caching**: The same chat input produces the same output, cached on disk.
  (`chat_task` declares its result type as `:chat`; `:chat` is a registered
  workflow type extension — `Workflow::TYPE_EXTENSIONS[:chat] = :chat` — so
  plain `task :x => :chat` in any workflow gets the same serialization for
  free.)
- **Provenance**: Every agent run is recorded with full chat history.
- **Agent chat sidecar**: the agent's own conversation is always written to
  `<job>.files/<name>.chat` next to the job (`agent.chat` by default,
  `worker.chat`/`critic.chat` for named agents), holding the **full** chat
  (system prompt, tools, every turn), while the job **result** keeps delta
  semantics — only the messages produced by this run.
- **Provenance includes the society tree**: `scout-ai llm prov` treats a job
  and a saved chat the same way here — both are scanned for conversations
  under `<path>.files/`, namely `<path>.files/*.chat` and
  `<path>.files/*.society/<agent>/<conversation>/`. A saved chat skips
  only its own top-level copy at `<chat>.files/<name>.chat`;
  society conversations keep the same `agent.chat` name and are included.
- **Lazy society tree**: delegated specialist conversations, if any, are
  saved under `<job>.files/<name>.society/<agent_name>/<conversation>/…`, but
  only when they exist. Nothing is created eagerly — no job starts with an
  empty `.files` directory — and parent directories appear on demand.
- **Dependency tracking**: Tasks can depend on each other.

---

## A simple pipeline

Here's a three-step pipeline: Plan → Execute → Review.

```ruby
module Pipeline 
  extend Workflow
  include_workflow AgentWorkflow

  chat_task :plan do |objective|
    agent = self.agent('Planner', chat: chat)
    agent.start
    agent.user objective
    agent.chat
  end

  chat_task :execute do |plan|
    agent = self.agent('Executor', chat: chat)
    agent.socialize  # executor can delegate to specialists
    agent.start
    agent.user "Execute this plan:\n#{plan}"
    agent.chat
  end

  chat_task :review do |result|
    agent = self.agent('Critic', chat: chat)
    agent.start
    agent.user "Review this result:\n#{result}"
    agent.chat
  end
end
```

Each task gets its own agent, its own chat, and its own provenance trail.

---

## Artifact-first collaboration

When agents need to share information, prefer **artifacts** (files on disk)
over passing everything through the conversation:

```ruby
chat_task :search do |query|
  agent = self.agent('Searcher', chat: chat)
  agent.start
  agent.user "Research: #{query}"
  report = agent.chat
  # Save the report as an artifact
  Step.write_file('research_report.md', report)
  report
end

chat_task :synthesize do |report|
  # Read the artifact rather than relying on conversation memory
  full_report = Step.read_file('research_report.md')
  agent = self.agent('Writer', chat: chat)
  agent.start
  agent.user "Write a summary based on this report:\n#{full_report}"
  agent.chat
end
```

Benefits:
- Each agent's context stays focused on its own task.
- Artifacts are inspectable and debuggable.
- Large outputs don't bloat the orchestrator's conversation.

---

## Delegation within workflows

Agents in workflows can also delegate to each other:

```ruby
chat_task :run do
  agent = self.agent('Manager', chat: chat)
  agent.socialize  # model can call ask(agent: 'Worker', prompt: ...)
  agent.start
  agent.user "Complete this project."
  agent.chat
end
```

Delegation semantics — the `ask`/`hand_off_to_<name>` tool pair, the
inheritance modes and their one-turn scope, conversation persistence and the
safe-delegation rules — are documented once in
[Delegation.md](Delegation.md); nothing here repeats them.

---

## Common patterns

### Linear pipeline

```
Plan → Execute → Review → Report
```

Each step depends on the previous one. Simple and predictable.

### Manager-worker

```
Manager → delegates to → Worker(s)
         ← returns to ←
```

The manager agent has `socialize` enabled and dynamically delegates to
specialists.

### Critic loop

```
Executor → produces → Critic → reviews → Executor → refines → Critic → ...
```

Repeat until the critic approves or a max iteration count is reached.

### Branched exploration

```
           → Agent A →
Orchestrator → Agent B → Synthesizer
           → Agent C →
```

Multiple agents work in parallel on different aspects, then a synthesizer
combines results.

### What the `chat_task` block may return

| block returns | outcome |
|---|---|
| an agent (`LLM::Agent`) | if its chat does not already end in an assistant message, one more `agent.chat(return_messages: true)` round runs; then the agent is logged (`log_agent`) and this run's delta is projected |
| a `Chat` / Array of messages | used as-is, roles preserved |
| a single `Hash` | wrapped as `[hash]` |
| a `String` / `Integer` / `nil` | not a chat: the projection fails with a `TypeError` and the job ends in `error` |
| `raise ScoutException` | rescued: the result is an assistant message holding `{exception: ..., job: <short_path>}` as JSON, job status `done` |
| any other `raise` | propagates; job status `error` (and `log_agent` never runs) |

### Idioms inside a chain

| Idiom | Code | Purpose |
|---|---|---|
| Follow a dependency's whole chat | `chat.follow step(:dep).load` | Append the dependency's projected chat result |
| Follow only its last message | `chat.follow step(:dep).load.last` | Just the final answer, not the tool traffic |
| Drop tools for a focused step | `chat.message :clear_tools, true` | Remove tool definitions from the step's context |
| Configurable worker agent | `options[:worker_agent] || 'Worker'` | Pick the agent at run time |
| Conditional dependency | `dep :search do |jobname,options| ... end` | Skip a stage on demand |
| Iterative refinement | `raise` + `retry` on your own exception class | Loop control inside a `chat_task` block (plain Ruby; `ScoutException` is special-cased by `chat_task`, so use a distinct class for retry) |

---

## Logging agent activity

The `agent` helper seeds the spawned agent's `start_chat` with the current
job's tooling (`tool:`, `kb:`, `mcp:`, `introduce:` roles). That extraction
is **destructive**: `Chat#remove_role` strips those roles out of the job's
own chat permanently. The memoized helper can only run once per task — a
second `agent` call in the same task finds no tooling left to extract. Use
`tooling_intro` (the non-destructive half, the `introduce:` messages only,
intended for specialists) when the job's chat must keep its roles, or pass
`tooling:` explicitly to override what is inherited.

When agents run inside workflow tasks, the seeded `start_chat` also receives
system notes about the working directory, the job path, the job's
dependencies and any other jobs found in the incoming chat; the incoming
`You have been assigned …` and those note prefixes are stripped before the
rest of the chat is followed in. (One of those prefixes relies on a
misspelled "depencencies" literal that the recycle filter matches — do not
"fix" the spelling in `lib/scout/llm/agent/workflow.rb` without updating the
filter.)

The agent's own conversation is saved to `<job>.files/<name>.chat` (the full
chat; `agent.chat` by default,
`worker.chat` for a `worker` agent), the job result keeps only
this run's delta, and delegated specialist conversations — when they exist —
are saved under `<job>.files/<name>.society/<agent_name>/<conversation>/…`.
Nothing is created up front; directories and files appear only when there is
something to save.

Chats saved by the CLI get the same sidecar layout: the root conversation is
copied to `<chat>.files/<name>.chat` and any socialized agents land under
`<chat>.files/<name>.society/…`. Both jobs and saved chats are examined for
those conversations, so you can inspect either as provenance:

```bash
scout-ai llm prov /path/to/job
scout-ai llm prov /path/to/saved.chat
```

This shows the full chat history, including any delegations and tool calls.
Jobs are recognized by their `.info` sidecar; a `.files` directory alone does
not make a path a job, because saved chats have one too.

Restart snapshots (`.files/resets/<timestamp>.chat`, taken by `agent.start`
when a prior non-empty chat existed) sit outside `log/` and are recovery
artifacts, not provenance logs.

Sibling state next to that chat file follows one convention: `<base>.society/`,
`<base>.inbox/`, `<base>.inbox_removed/` and the transient `<base>.jobs`
(trailing `.chat` stripped). Add `--live` to see the in-flight workflow
workload of an agent while it runs:

```bash
scout-ai llm prov --live /path/to/saved.chat
```

`chat_task` inputs are plain text parsed into a Chat, so they can declare
arbitrary tooling or run arbitrary code; that is why Scout-AI never exposes
chat_tasks directly — higher layers (e.g. Cortex) expose them through
prompt-only interfaces that append to conversations the agent has limited or
indirect control over. The five ways of asking, and what is visible live vs
after the fact, are tabulated in
[Delegation.md](Delegation.md#the-five-ways-of-asking-and-what-you-can-see).

See [../developer/Provenance.md](../developer/Provenance.md) for provenance
internals and [BuildingAgents.md](BuildingAgents.md) for save semantics.

---

### SC26-style compositions

`research/multi-agent-patterns-analysis.md` (retired 2026-09-12) catalogued
seven compositions from a real agent ecosystem: a linear **Planned pipeline**
(request → search → plan → work → ask as chained `chat_task`s), a **Manager
control loop** (budgeted Search → Edit → Score → Select driven by the `ask`
tool with named branch chats), a **Critic** verification stage (JSON
`PASS`/`NEEDS_WORK`/`BLOCKED` verdict parsed with `Chat.parse_json` and stored
with `set_info`, the critic agent created with `no_ask_override: true` so it
cannot delegate), a **Branched** fan-out (a splitter agent partitions the plan,
`iterate_dictionary ... cpus: N` runs one isolated worker per branch over
`plan.dup`, an aggregate critic reads the reports), a **Refined**
worker/critic retry loop (shared chat across rounds, `clear_tools` between
rounds), and a two-phase **InterpretData** prep pipeline (an analyst agent
reduces data into artifacts, a worker consumes them). Every idiom involved
lives in scout-ai — `dep`, `chat_task`, `chat.follow`,
`iterate_dictionary`, `log_agent`, `self.agent(nil, chat:, tooling:)`,
`IndiferentHash.setup` over parsed JSON — so treat the paragraph above as the
surviving summary; the compositions are reproducible from this page's
vocabulary.

## Common mistakes

- **Trying to do everything in one giant chat**: Break work into tasks. Each
  task gets a fresh context.
- **Passing everything through conversation**: Use artifacts (files) for large
  outputs between agents.
- **Not using `socialize` when the model should decide**: If you want dynamic
  delegation, enable `socialize` and let the model choose.
- **Forgetting that tasks are cached**: If you change an agent's `start_chat`
  but not the task input, you may get a cached result. Clear the cache or
  change the input.
- **Calling `agent` twice in one task**: the tooling extraction behind it is
  destructive and memoized, so the second call finds nothing left to extract —
  pass `tooling:` explicitly instead.

---

## Next steps

- [Delegation.md](Delegation.md) — the delegation API.
- [BuildingAgents.md](BuildingAgents.md) — creating agents.
- [ManagingContext.md](ManagingContext.md) — keeping contexts focused.
