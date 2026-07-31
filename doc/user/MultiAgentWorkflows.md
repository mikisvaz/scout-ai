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
that includes the `AgentWorkflow` mixin.

### What `chat_task` gives you

- **Caching**: The same chat input produces the same output, cached on disk.
- **Provenance**: Every agent run is recorded with full chat history.
- **Dependency tracking**: Tasks can depend on each other.

---

## A simple pipeline

Here's a three-step pipeline: Plan → Execute → Review.

```ruby
module Pipeline 
  extend Workflow
  include AgentWorkflow

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

The model decides when to delegate and to whom. Each delegation creates its
own provenance entry.

See [Delegation.md](Delegation.md) for the full delegation API.

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

---

## Logging agent activity

When agents run inside workflow tasks, their conversations are automatically
saved as provenance. You can inspect them:

```bash
scout-ai llm info /path/to/job
scout-ai llm prov /path/to/job
```

This shows the full chat history, including any delegations and tool calls.

See [../developer/Provenance.md](../developer/Provenance.md) for provenance
internals.

---

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

---

## Next steps

- [Delegation.md](Delegation.md) — the delegation API.
- [BuildingAgents.md](BuildingAgents.md) — creating agents.
- [ManagingContext.md](ManagingContext.md) — keeping contexts focused.
