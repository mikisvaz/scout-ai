# Core Concepts

This page gives you a conceptual map of Scout-AI's main abstractions. It is
intended for workflow authors — both human developers and coding agents — who
want to understand what Scout-AI offers before diving into specifics.

**You should read this if:** you have installed Scout-AI and want a high-level
orientation before building anything.

---

## The big picture

Scout-AI sits between your application code and an LLM provider. It gives you
four building blocks:

| Concept | What it is | What problem it solves |
|---------|-----------|----------------------|
| **Chat** | A conversation format (plain text on disk, Array of hashes in memory) | Reproducibility: every conversation is inspectable, editable, and versionable |
| **Agent** | A stateful wrapper around a Chat with persistent defaults and tools | Persistence: your agent keeps its system prompt, tools, and options across conversations |
| **Tools** | Callable functions the LLM can invoke during inference | Grounding: the model can query real data and run real code instead of hallucinating |
| **Inference Endpoint** | A named configuration for a provider + model + credentials | Portability: switch between OpenAI, Anthropic, Ollama, etc. without changing application code |

These compose. An **Agent** has a **Chat** and a set of **Tools**, and it sends
the chat to an **Inference Endpoint** to get a response.

---

## Chat: the conversation format

A Chat is simultaneously two things:

1. **On disk:** a plain-text file where each line block starts with a role
   name and colon (`system:`, `user:`, `assistant:`, etc.).
2. **In memory:** an Array of message hashes, each with `role:` and `content:`
   keys.

This dual nature is the foundation of Scout-AI's reproducibility. You can
write a conversation by hand in a text editor, run it through the CLI, inspect
the output, and feed it back as input.

```text
system:

You are a helpful assistant.

user:

Hello!

assistant:

Hi there! How can I help?
```

**Key idea:** Every conversation — whether a one-shot CLI question, an agent
session, or the output of a workflow job — is serialized to the same
plain-text format. This means you can always inspect, edit, and reproduce
what happened.

→ See [WritingChats.md](WritingChats.md) for the full format.

---

## Agent: the stateful wrapper

An Agent bundles a Chat with persistent configuration:

- **A start chat** — the system prompt, tool declarations, file imports, and
  other seed messages that prefix every new conversation.
- **Tools** — workflows, knowledge bases, or MCP tools the agent can call.
- **Options** — endpoint, model, format, and other defaults.

Agents are **named directories**. You create an agent by making a directory
under your Scout Agent path and adding a `start_chat` file:

```
Agent/
  Researcher/
    start_chat        # system prompt + tool declarations
    workflow.rb       # optional: Scout workflow providing tools
```

Once defined, an agent is invoked by name:

```bash
scout-ai agent ask Researcher "Find papers about protein folding."
```

Agents can also **delegate** to other agents — an orchestrator agent can hand
off sub-tasks to specialists, each with its own tools and persona.

→ See [BuildingAgents.md](BuildingAgents.md) for agent lifecycle and DSL.
→ See [Delegation.md](Delegation.md) for multi-agent delegation.

---

## Tools: grounding the model

Tools let the LLM call functions during inference. Scout-AI supports several
kinds:

| Tool source | How you declare it | What it gives the model |
|-------------|-------------------|----------------------|
| **Scout Workflow** | `tool:` or `introduce:` in chat, or auto-wired from agent workflow | Tasks with typed inputs/outputs become callable functions |
| **Knowledge Base** | `kb:` in chat | Database lookups (gene→protein, drug→disease, etc.) |
| **MCP Server** | `mcp:` in chat | Any MCP-compatible external tool |

The model sees a tool definition (name, description, JSON Schema parameters),
decides when to call it, and receives the result as a tool-return message that
is appended to the conversation.

→ See [ToolCalling.md](ToolCalling.md) for the full tool system.

---

## Inference endpoint: provider abstraction

An **endpoint** is a named bundle of provider + model + credentials. You
configure endpoints once and reference them by name everywhere:

```bash
# Use the 'anthropic' endpoint for this conversation
scout-ai llm ask -e anthropic "Hello"
```

Scout-AI supports OpenAI, Anthropic, Ollama, vLLM, and other OpenAI-compatible
providers. Endpoints are provider-agnostic from the application's perspective —
you write your agent once and switch models by changing the endpoint name.

→ See [RunningInference.md](RunningInference.md) for endpoint configuration
and CLI usage.

---

## How they compose

Here is the typical flow when an agent answers a question:

```
User question
    │
    ▼
Agent receives question
    │
    ├── Appends to current_chat (a Chat object)
    ├── Sends chat to inference endpoint
    │       │
    │       ├── Model responds with text → done
    │       └── Model calls a tool → execute tool, append result, re-send
    │
    └── Returns final answer
```

The tool-calling loop is automatic: if the model calls a tool, Scout-AI
executes it, append the result, and re-sends the conversation until the model
responds with plain text.

---

## When to use what

| If you want to... | Use... |
|-------------------|--------|
| Ask a one-off question | `scout-ai llm ask` |
| Run a saved conversation | `scout-ai llm ask -c file.chat` |
| Create a reusable persona with tools | An Agent (directory with `start_chat`) |
| Give the model data to query | Knowledge Base tools (`kb:`) |
| Give the model code to run | Workflow tools (`tool:` / `introduce:`) |
| Use external tools | MCP (`mcp:`) |
| Build multi-agent systems | Delegation (`socialize` / `delegate`) |
| Build reproducible pipelines | AgentWorkflow (Scout Workflow + Agent) |

---

## Next steps

- [WritingChats.md](WritingChats.md) — master the chat-file format.
- [BuildingAgents.md](BuildingAgents.md) — create your first agent.
- [ToolCalling.md](ToolCalling.md) — wire up tools.
- [Delegation.md](Delegation.md) — build multi-agent systems.
