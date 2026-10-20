# Scout-AI Documentation

Scout-AI is an agent and LLM layer built on top of
[Scout](https://github.com/mikisvaz/scout-gear). It provides a reproducible
conversation format (`Chat`), tool calling backed by real Scout workflows,
knowledge bases, and MCP servers, and multi-agent orchestration encoded as
typed, inspectable workflow jobs.

---

## Choose your path

### I want to build applications with Scout-AI

→ Go to **[user/](user/)** documentation.

The user documentation explains how to use Scout-AI to build agents, define
tools, configure inference, and orchestrate multi-agent workflows. It is
organized around concepts and tasks, not internal classes.

The ML model subsystem (`ScoutModel`, `TorchModel`, Hugging Face wrappers)
is documented separately in [Model.md](Model.md); it is intentionally
outside the agent/LLM layer.

**Start here:**
1. [user/GettingStarted.md](user/GettingStarted.md) — install, configure, first conversation.
2. [user/CoreConcepts.md](user/CoreConcepts.md) — the four building blocks.
3. Then follow the topic guides as needed.

### I want to extend or modify Scout-AI

→ Go to **[developer/](developer/)** documentation.

The developer documentation explains how Scout-AI is implemented: the
architecture, the compilation pipeline, the backend abstraction, the
delegation internals, and the provenance system. It is concise and links to
[research/](../research/) for deep code investigations.

**Start here:**
1. [developer/Architecture.md](developer/Architecture.md) — subsystem map and data flow.
2. [developer/DesignPrinciples.md](developer/DesignPrinciples.md) — coding philosophy and idioms.
3. Then follow the topic guides as needed.

### I need to understand how a subsystem works in detail

→ Go to **[../research/](../research/)** investigation documents.

The maintained set is `research/subsys/` — one probe-verified study per
subsystem (chat, backends, tools, agent delegation, agent directories,
AgentWorkflow, provenance, embeddings/RAG, model, CLI entry). Each is an
investigation record, not normative documentation: it may state sharp edges
and open questions that `doc/` does not. One design file is additionally
retained — `provenance-navigation-design.md`, the rationale tracked by
[Improvements.md](Improvements.md) A1.

---

## Reading paths for common tasks

| Task | Reading path |
|---|---|
| **Build my first agent** | user/GettingStarted → user/CoreConcepts → user/BuildingAgents |
| **Understand multi-agent systems** | user/Delegation → user/MultiAgentWorkflows → developer/DelegationInternals |
| **Add tool support** | user/ToolCalling → (user/Python if needed) |
| **Configure inference** | user/RunningInference → user/ManagingContext |
| **Understand the internals** | developer/Architecture → developer/ChatLifecycle → developer/Backends |
| **Extend the agent Path engine** | developer/PathEngine |
| **Understand the sandbox / execution boundaries** | developer/Sandbox |
| **Track and inspect provenance** | developer/Provenance |
| **Write idiomatic code** | developer/DesignPrinciples |
| **Use the ML/PyTorch model subsystem** | Model.md |
| **Use the CLI** | user/Cookbook (CLI quick reference) |

---

## Documentation structure

```
doc/
├── StartHere.md          ← you are here
├── Improvements.md       ← known issues and improvement advisory
├── Model.md              ← ML model subsystem (separate from harness)
├── user/                 ← building applications with Scout-AI
│   ├── GettingStarted.md
│   ├── CoreConcepts.md
│   ├── WritingChats.md
│   ├── BuildingAgents.md
│   ├── ToolCalling.md
│   ├── RunningInference.md
│   ├── ManagingContext.md
│   ├── Delegation.md
│   ├── MultiAgentWorkflows.md
│   ├── Python.md
│   └── Cookbook.md
├── developer/            ← extending and modifying Scout-AI
│   ├── Architecture.md
│   ├── ChatLifecycle.md
│   ├── DesignPrinciples.md
│   ├── PromptProcessing.md
│   ├── Backends.md
│   ├── DelegationInternals.md
│   ├── Provenance.md
│   ├── PathEngine.md
│   └── Sandbox.md
└── ../research/          ← probe-verified subsystem studies
    ├── subsys/           ← one study per subsystem
    ├── scout-ai-runtime-availability.md
    └── provenance-navigation-design.md   ← retained for Improvements.md A1
```

Each layer becomes progressively more detailed and less stable:

```
Code → Investigation (research/) → Developer docs (doc/developer/) → User docs (doc/user/)
```

---

## The three layers and their authority

- **`doc/` is authoritative.** If a page here states a contract, behavior,
  or limit, that statement is the current truth for Scout-AI. When code
  changes, the page changes with it; docs lagging code is a defect, not a
  preference.
- **`research/` holds investigation records, not authority.** A research
  file documents the rationale, evidence, and open questions behind a
  decision at the time it was made. It may state sharp edges and
  uncertainty, but it never silently overrides `doc/`: on conflict,
  `doc/` wins, and the research file should be updated or retired.
- **`var/cortex/` is mutable working state.** The agent workspace —
  conversations, briefs, artifacts — is scratch space for active
  investigation. Anything durable that came out of it must be promoted
  into `doc/` or `research/`; nothing under `var/` is citable as
  authoritative.

