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

These are architectural reports produced during code investigations. They are
not maintained documentation and may be outdated, but they contain detailed
call graphs, implementation discoveries, and design rationale.

---

## Reading paths for common tasks

| Task | Reading path |
|---|---|
| **Build my first agent** | user/GettingStarted → user/CoreConcepts → user/BuildingAgents |
| **Understand multi-agent systems** | user/Delegation → user/MultiAgentWorkflows → developer/DelegationInternals |
| **Add tool support** | user/ToolCalling → (user/Python if needed) |
| **Configure inference** | user/RunningInference → user/ManagingContext |
| **Understand the internals** | developer/Architecture → developer/ChatLifecycle → developer/Backends |
| **Track and inspect provenance** | developer/Provenance → research/provenance-analysis |
| **Write idiomatic code** | developer/DesignPrinciples → research/coding-philosophy-analysis |
| **Use the CLI** | user/Cookbook (quick reference) → research/commands-analysis (full detail) |

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
│   └── Provenance.md
└── ../research/          ← architectural investigation reports
    ├── chat-core-analysis.md
    ├── prompt-strategies-analysis.md
    ├── agent-delegation-analysis.md
    ├── agent-workflow-analysis.md
    ├── backends-analysis.md
    ├── tools-system-analysis.md
    ├── provenance-analysis.md
    ├── multi-agent-patterns-analysis.md
    ├── coding-philosophy-analysis.md
    ├── commands-analysis.md
    └── synthesis-report.md
```

Each layer becomes progressively more detailed and less stable:

```
Code → Investigation (research/) → Developer docs (doc/developer/) → User docs (doc/user/)
```
