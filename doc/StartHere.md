# Scout-AI Documentation

Scout-AI is an agent and LLM layer built on top of
[Scout](https://github.com/mikisvaz/scout-gear). It provides a reproducible
conversation format (`Chat`), tool calling backed by real Scout workflows,
knowledge bases, and MCP servers, and multi-agent orchestration encoded as
typed, inspectable workflow jobs. These docs are for anyone who wants to use
Scout-AI to build LLM-powered workflows or to extend the framework itself.

> **Before you write any code: read the design philosophy section in
> [Overview.md](Overview.md).** Scout-AI emphasizes the right abstractions
> (plain Arrays annotated with DSL methods, module composition over
> inheritance, convention over configuration). Code that ignores these
> conventions will fight the library.

---

## Choose your path

### I want to use Scout-AI

Start with the high-level overview, then follow the tutorial-oriented reading
sequence:

1. [Overview.md](Overview.md) — what Scout-AI is, how to install it, how to
   configure your first endpoint, and the core abstractions.
2. [Chat/Chat.md](Chat/Chat.md) — the conversation format and the `Chat` DSL.
3. [Agent/Agent.md](Agent/Agent.md) — building stateful agents.
4. [Commands/Commands.md](Commands/Commands.md) — CLI commands for everyday
   use.

### I want to develop or extend Scout-AI

Start with the overview, then go deep on the three foundational systems before
specializing:

1. [Overview.md](Overview.md) — architecture, abstractions, and design
   philosophy (read the philosophy section carefully).
2. [Chat/Chat.md](Chat/Chat.md) — the data model everything else builds on.
3. [Agent/Agent.md](Agent/Agent.md) — the `LLM::Agent` class and lifecycle.
4. [Backends/Backends.md](Backends/Backends.md) — backend abstraction and
   provider dispatch.

After these four, branch into whichever subsystem you need:
[Tools/](Tools/), [Provenance/](Provenance/Provenance.md),
[Agent/AgentWorkflow.md](Agent/AgentWorkflow.md),
[Agent/Delegation.md](Agent/Delegation.md), etc.

---

## Reading sequences for common tasks

| Task | Reading sequence |
|---|---|
| **Building my first agent** | Overview → Chat/Chat → Agent/Agent → Agent/AgentWorkflow |
| **Understanding multi-agent systems** | Overview → Agent/Agent → Agent/Delegation → Agent/MultiAgentPatterns → Provenance/Provenance |
| **Adding tool support** | Overview → Chat/Chat → Tools/Tools → (Tools/WorkflowTools · Tools/KnowledgeBase · Tools/MCP) |
| **Understanding inference and backends** | Overview → Chat/Chat → Backends/Backends → Chat/PromptStrategies |
| **Writing idiomatic Scout-AI code** | Overview (read the design philosophy section carefully) → Chat/Chat → Agent/Agent |
| **Tracking and inspecting provenance** | Overview → Chat/Persistence → Provenance/Provenance → Commands/Commands |
| **Using the CLI effectively** | Overview → Commands/Commands |

---

## Table of contents

### Getting started

| Document | Description |
|---|---|
| [Overview.md](Overview.md) | What Scout-AI is, installation, endpoint setup, core abstractions, and design philosophy. The entry point for all readers. |

### Chat

| Document | Description |
|---|---|
| [Chat/Chat.md](Chat/Chat.md) | The `Chat` data model: message roles, the builder DSL, file format, and the processing pipeline. |
| [Chat/PromptStrategies.md](Chat/PromptStrategies.md) | How `prepare_prompt` and `shorten_tools` manage context windows by pruning old tool calls before inference. |
| [Chat/Persistence.md](Chat/Persistence.md) | The `.chat` file format, provenance annotations (`meta:` roles), caching, and load/save drivers. |

### Agent

| Document | Description |
|---|---|
| [Agent/Agent.md](Agent/Agent.md) | The `LLM::Agent` class: lifecycle, `start_chat`/`current_chat`, DSL forwarding, tool wiring, structured outputs, and error handling. |
| [Agent/AgentWorkflow.md](Agent/AgentWorkflow.md) | The `AgentWorkflow` mixin: `chat_task` DSL, `helper :agent`, `log_agent`, and how agents integrate with Scout workflows. |
| [Agent/Delegation.md](Agent/Delegation.md) | Multi-agent delegation mechanics: `socialize`, `delegate`, `ask` tool, `hand_off_to_<name>`, and social inheritance modes. |
| [Agent/MultiAgentPatterns.md](Agent/MultiAgentPatterns.md) | Concrete orchestration patterns: Planned, Manager, Branched, Refined, and InterpretData. Budget management and branch-specific chats. |
| [Agent/Python.md](Agent/Python.md) | How to write Python-backed workflow tasks for Ruby-side agents: auto-loading `python/*.py`, `scout.task(...)`, type mapping, and CLI usage. |

### Backends

| Document | Description |
|---|---|
| [Backends/Backends.md](Backends/Backends.md) | Backend abstraction, the `chain_tools` inference loop, provider table (OpenAI, Anthropic, Ollama, etc.), endpoint YAML configuration, caching, and session continuation. |

### Tools

| Document | Description |
|---|---|
| [Tools/Tools.md](Tools/Tools.md) | Tool definition format (`{name => [handler, definition]}`), the calling protocol, `process_calls`, and output limits. |
| [Tools/WorkflowTools.md](Tools/WorkflowTools.md) | Exposing Scout workflows as agent tools: `LLM.workflow_tools`, `LLM.workflow_ask`, `tool:`/`task:`/`exec_task:` chat roles. |
| [Tools/KnowledgeBase.md](Tools/KnowledgeBase.md) | Knowledge bases as tools, `association:`/`kb:` chat roles, `LLM.knowledge_base_ask`, and RAG with embeddings. |
| [Tools/MCP.md](Tools/MCP.md) | Model Context Protocol integration: `mcp:` chat role, `workflow.mcp_stdio`, and wrapping MCP servers as agent tools. |

### Provenance

| Document | Description |
|---|---|
| [Provenance/Provenance.md](Provenance/Provenance.md) | The provenance data model, `Chat.provenance`, `trace_chats`, recursive job traversal, token accounting, `info` vs `prov` commands, and ChatAnalyst. |

### Commands

| Document | Description |
|---|---|
| [Commands/Commands.md](Commands/Commands.md) | Concise reference for every CLI command: `llm ask`, `llm info`, `agent ask`, `workflow mcp`, and more. Links to detail docs for deeper topics. |

### Improvements

| Document | Description |
|---|---|
| [Improvements.md](Improvements.md) | Known code issues, documentation gaps, architectural suggestions, and anti-patterns to avoid when contributing to Scout-AI. |

---

## About the legacy documentation

The old flat documentation files (`Agent.md`, `Chat.md`, `LLM.md`,
`USER_GUIDE.md`, `RAG.md`, `PythonAgentTasks.md`) have been removed. Their
content is now distributed across the new structured documentation:

- `Agent.md` → [Agent/Agent.md](Agent/Agent.md)
- `Chat.md` → [Chat/Chat.md](Chat/Chat.md)
- `LLM.md` → distributed across [Backends/Backends.md](Backends/Backends.md),
  [Chat/Persistence.md](Chat/Persistence.md), and [Tools/](Tools/) docs
- `USER_GUIDE.md` → folded into [Overview.md](Overview.md) and the
  topic-specific docs
- `RAG.md` → merged into [Tools/KnowledgeBase.md](Tools/KnowledgeBase.md)
- `PythonAgentTasks.md` → incorporated into [Agent/Python.md](Agent/Python.md)

**`Model.md`** remains as a standalone reference for the `ScoutModel` /
`PythonModel` / `TorchModel` / `HuggingfaceModel` subsystem. That subsystem
(wrapping ML models for evaluation and training) is tangential to the
agent/LLM layer and is intentionally kept separate.
