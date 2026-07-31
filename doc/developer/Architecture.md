# Architecture

This document explains the overall system architecture of Scout-AI and how its
subsystems interact. It is intended for framework contributors who need a
mental map before diving into specific subsystems.

For deeper investigation of any subsystem, see the corresponding
[research document](../../research/).

---

## Subsystem map

```
                     ┌─────────────────────────────────────────────┐
                     │                  LLM (module)                 │
                     │  LLM.ask  — entry point for all inference     │
                     │  LLM.chat — parse/compile chat files          │
                     │  LLM.load_agent — resolve agent directories    │
                     └───────────────┬───────────────────────────────┘
                                     │
                 ┌───────────────────┼───────────────────────┐
                 ▼                   ▼                       ▼
           ┌──────────┐       ┌──────────────┐       ┌──────────────┐
           │ Backend  │       │  LLM::Agent  │       │    Tools     │
           │ adapter  │       │ (stateful)   │       │ (WF/KB/MCP)  │
           └──────────┘       └──────┬───────┘       └──────┬───────┘
                                    │ holds                │
                              ┌─────▼─────┐          ┌──────▼──────┐
                              │   Chat    │◄────────►│  Workflow   │
                              │ (Array +  │  task    │  tasks as   │
                              │  DSL)     │  tools   │  tools      │
                              └───────────┘          └─────────────┘
                                    │ extends
                              ┌─────▼─────┐
                              │ Annotation│ (non-invasive mixin)
                              └───────────┘
```

### The six core abstractions

| Abstraction | Realized by | Responsibility |
|---|---|---|
| **Chat** | `Chat` module (Annotation on Array) | A conversation: a plain Array of message Hashes, annotated with DSL methods. |
| **Agent** | `LLM::Agent` class | A stateful conversation holder with tools, a workflow, knowledge bases, and delegation capabilities. |
| **AgentWorkflow** | `AgentWorkflow` mixin | A `Workflow` mixin that adds `chat_task`, `helper :agent`, and `helper :log_agent` for multi-agent strategies. |
| **Backend** | `LLM::Backend` module + provider modules | Stateless adapter to a specific LLM provider API. Shares logic via `Backend::ClassMethods`, overrides via `prepend`. |
| **Tools** | `LLM` module methods | Definition and execution of callable tools: workflow tasks, KB queries, MCP servers. |
| **Annotation** | `Annotation` (from scout-essentials) | Non-invasive metadata injection onto existing objects without subclassing or wrapping. |

---

## Dependency direction

```
scout-ai.rb
  └─ scout/llm/ask.rb       (requires scout, chat)
  └─ scout/llm/chat.rb      (requires chat/annotation, parse, process, prompt, persist, tools, utils)
  └─ scout/llm/agent.rb     (requires ask, agent/chat, iterate, delegate, workflow)
  └─ scout/llm/embed.rb
  └─ scout/llm/image.rb
  └─ scout/llm/tools/       (workflow, knowledge_base, mcp, call)
  └─ scout/llm/backends/    (default + provider adapters)
```

The key direction is **Agent → Chat → Annotation**.

Backends depend on Chat and `Backend::ClassMethods`, not on Agent.
AgentWorkflow depends on Agent and Chat, not on specific Backends.

This means you can use Chat and Backends without ever instantiating an Agent,
and you can use Agents without AgentWorkflow. Each layer adds capability
without creating hard downward dependencies.

---

## How data flows through the system

A single inference request flows through the layers as follows:

1. **Entry**: `LLM.ask(messages, options)` or `Agent#ask(messages, options)`.
2. **Chat compilation**: The messages (string, file, or Array) are compiled
   into a canonical Array of Hashes via `Chat.parse`. Options embedded in the
   chat (via `option:`, `model:`, `endpoint:` directives) are extracted into
   the options hash.
3. **Tool extraction**: Tool/introduce/association roles are extracted from
   messages. Workflow tasks and KB databases are converted to tool definitions.
4. **Prompt preparation**: The message array passes through
   `Chat.prepare_prompt` which applies context-management strategies
   (e.g., `shorten_tools`). This is **ephemeral** — the stored chat is never
   mutated.
5. **Backend dispatch**: `LLM.ask` selects the appropriate Backend module
   (OpenAI, Anthropic, etc.) via a registry/case dispatch and calls its
   `ask` method.
6. **API call + tool loop**: The Backend formats the prompt for the provider,
   calls the API, parses the response. If the model emitted a tool call, the
   tool is executed and the result appended; then the Backend re-calls the
   API with the growing message list (the `chain_tools` recursive loop).
7. **Response**: The Backend returns the response as an annotated Chat (Array
   of Hashes), with provenance metadata (`meta:` messages) interleaved.

---

## Extension points

| To extend... | Where to add | Pattern |
|---|---|---|
| A new LLM provider | `lib/scout/llm/backends/<provider>.rb` | Define a module that `prepend`s `<Provider>Methods` and `include`s `Backend::ClassMethods`. Override `query`, `process_response`, `format_messages` as needed. |
| A new tool type | `lib/scout/llm/tools/<type>.rb` | Define a module method that returns `{ name => [executor, definition] }` hashes. |
| A new prompt strategy | Register in `REGISTERED_STRATEGIES` (currently undefined) or pass a `Proc` via `prompt_strategies:` option. |
| A new agent type | `Agent/<Name>/` directory with `start_chat`, `agent.rb`, or `workflow.rb`. | Conventional discovery. |
| A new chat-task workflow | `include_workflow AgentWorkflow` in your Workflow module. | Use `chat_task`, `helper :agent`, etc. |

---

## Cross-references

- [ChatLifecycle.md](ChatLifecycle.md) — Chat data model, compilation, annotations.
- [PromptProcessing.md](PromptProcessing.md) — Context management internals.
- [Backends.md](Backends.md) — Backend abstraction and inference loop.
- [DelegationInternals.md](DelegationInternals.md) — Multi-agent mechanics.
- [Provenance.md](Provenance.md) — Provenance data model and traversal.
- [DesignPrinciples.md](DesignPrinciples.md) — Coding philosophy and idioms.

> For detailed code investigations of each subsystem, browse the
> [research/](../../research/) directory.
