# Delegation Internals

This document explains how Scout-AI implements multi-agent delegation at the
code level: the `SOCIAL_INHERIT_MODES` system, the `ask` tool mechanics, the
`delegate` method, and the template-clone lifecycle. It is intended for
framework contributors.

> For the user-facing guide to delegation, see
> [../user/Delegation.md](../user/Delegation.md).
> For deep code investigation, see
> [../../research/agent-delegation-analysis.md](../../research/agent-delegation-analysis.md).

---

## Overview

Delegation is implemented in `lib/scout/llm/agent/delegate.rb` (323 lines). It
provides two mechanisms for one Agent to invoke another:

1. **`socialize`** — Registers a generic `ask` tool that lets the LLM delegate
   to any specialist agent by name at runtime.
2. **`delegate`** — Registers a named `hand_off_to_<name>` tool for a specific,
   pre-loaded Agent instance.

Both mechanisms build on a common infrastructure: the **template-clone
pattern**, the **socialized chat store**, and the **inheritance modes**.

---

## The template-clone pattern

Each specialist agent type is loaded **once** as an immutable template and stored
in `@society`:

```
@society = {
  "Worker"  => Agent (template, loaded once),
  "Critic"  => Agent (template, loaded once)
}
```

When a new conversation with a specialist is needed, the template is **deep
cloned** (`clone_social_agent`):

```ruby
def clone_social_agent(template)
  agent = template.clone
  agent.start_chat     = social_chat_copy(template.start_chat)
  agent.other_options  = IndiferentHash.setup(social_duplicate(template.other_options || {}))
  agent.society        = nil    # prevent cross-contamination
  agent.chats          = nil    # of delegation state
  agent.instance_variable_set(:@current_chat, nil)
  agent
end
```

Each clone gets:
- Its own `start_chat` (deep-copied).
- Its own `other_options` (deep-copied via `social_duplicate`).
- Nilled `society` and `chats` — no accidental access to the caller's delegation state.
- A nilled `current_chat` — forces lazy re-creation.

The deep-copy (`social_duplicate`) is recursive for Hash, Array, and String,
and passes Procs by reference (since they can't be marshalled but are safe to
share).

---

## The socialized chat store

Live specialist instances are stored in `@chats`, keyed by `"agent_name/conversation"`:

```
@chats = {
  "Worker/default"     => Agent (clone, persistent conversation),
  "Worker/analysis_1"  => Agent (clone, named conversation),
  "Critic/default"     => Agent (clone)
}
```

Conversation keys are **scoped by agent**: `Worker/work_A` and
`Critic/work_A` are independent conversations.

### `load_chat` — get-or-create

```ruby
def load_chat(agent_name, options = {}, conversation = nil, inherit: 'tools')
  key = social_chat_key(agent_name, conversation)   # "Worker/work_A"
  @chats[key] ||= start_social_chat(agent_name, options, inherit)
end
```

The `inherit` parameter is only consulted **once** — when the conversation is
first created. Follow-up turns reuse the existing conversation with its
accumulated history.

---

## SOCIAL_INHERIT_MODES

Three modes control how much caller context flows to a specialist on first
contact:

| Mode | What is inherited | Use case |
|---|---|---|
| `none` | Nothing. Specialist starts with its own `start_chat` only. | Fully isolated sub-agent. |
| `tools` *(default)* | Tooling roles (`introduce`, `tool`, `mcp`, `kb`) from the caller's current chat. | Shared capabilities, private history. |
| `conversation` | The caller's entire current chat minus its own `start_chat` prefix. | Full context sharing for tight collaboration. |

### Implementation: `social_inherited_context`

```ruby
def social_inherited_context(inherit)
  case inherit
  when 'none'
    Chat.setup([])
  when 'tools'
    tooling = self.current_chat.tooling
    social_chat_copy(tooling)
  when 'conversation'
    social_caller_context
  end
end
```

### `social_caller_context` — extracting non-start-chat messages

For `conversation` mode, the method extracts the "new" messages the caller
has added beyond its own `start_chat`. It uses a fast path (object identity
comparison) when the same Hash objects are shared, and a fallback (prefix
matching) for separately parsed Chats.

The specialist's rebuilt `start_chat` becomes:

```
[specialist's original start_chat] + [inherited context from caller]
```

So the specialist always gets its own system prompt first, then optionally the
caller's tools or full conversation.

---

## The `socialize` method

Registers a single tool named `:ask` that the LLM can invoke to delegate to
any specialist:

**Tool schema exposed to the model:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `agent` | string | Yes | Name of the specialist agent. |
| `prompt` | string | Yes | Plain-text prompt. |
| `conversation` | string | No | Named conversation ID (omit for one-shot). |
| `inherit` | enum `[none, tools, conversation]` | No (default `tools`) | Context policy for new conversations only. |

**Security boundary:** The tool block calls `ask_agent`, which uses
`agent.user(prompt)` rather than `agent.prompt(prompt)`. This is deliberate:
`prompt` parses chat-file syntax, which could allow prompt injection to inject
`tool:` or `system:` directives. The `user` method only appends a single
user-role message, making delegation safe even with untrusted LLM-generated
prompts.

**Option stripping:** Private options (`SOCIAL_PRIVATE_OPTIONS`) are stripped
before being passed to the specialist:

```ruby
SOCIAL_PRIVATE_OPTIONS = %i[
  agent client current_meta format messages no_ask_override
  previous_response_id process return_messages tool_choice tools
].freeze
```

This prevents leaking session state, tool blocks, or message arrays from the
caller to the specialist.

### Delegated inference receipts

When a delegation tool returns an `LLM::Agent`, `LLM.process_calls`
serializes the child agent's `meta` messages into the parent
`function_call_output` envelope as an `agent_meta` array. These receipts are
provenance evidence, not parent-chat messages: the child's inference metadata
and producer job reference are read from the paired tool output and never
injected into the parent chat. Provenance tooling consumes them through
`Chat.agent_meta_evidence` and the `:agent_job` relation; see
[Provenance.md](Provenance.md) for the extraction and accounting rules.

---

## The `delegate` method — named hand-off

```ruby
def delegate(agent, name, description, task_name = nil, &block)
```

Creates a tool named `hand_off_to_#{name}` for a **specific, pre-loaded**
Agent instance. Unlike `socialize`, the agent is not chosen by the model at
call time — it is hard-coded at registration time.

| Parameter | Description |
|---|---|
| `agent` | A pre-loaded `LLM::Agent` instance. |
| `name` | Tool name suffix (e.g., `worker` → `hand_off_to_worker`). |
| `description` | Tool description for the LLM. |
| `&block` | Optional custom tool block. Defaults to: `agent.user(message); agent.chat`. |

### Differences from `socialize`

| Aspect | `socialize` | `delegate` |
|---|---|---|
| Agent name | Model chooses at call time | Hard-coded at registration |
| Tool name | `:ask` (one tool for all agents) | `hand_off_to_#{name}` (one per agent) |
| Custom block | No (fixed block) | Yes |
| Conversation mgmt | Named conversations via `conversation` param | Single conversation, resettable via `new_conversation` |

---

## Legacy parameter handling

The old `chat` parameter is silently accepted for backward compatibility via
`social_tool_parameters`:

| Legacy `chat` value | Maps to `conversation` | Maps to `inherit` |
|---|---|---|
| `'current'` | `'current'` | `'conversation'` |
| `''`, `'none'`, `'false'` | `nil` (one-shot) | `'none'` |
| Any other name | That name | `'tools'` |

New code should use `conversation` and `inherit` as separate parameters.

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/agent/delegate.rb` | All delegation logic |
| `lib/scout/llm/agent.rb` | `Agent` class, `ask` entry point, `load_agent` class method |
| `lib/scout/llm/agent/chat.rb` | `start_chat`, `current_chat`, Chat proxy via `method_missing` |
| `lib/scout/llm/agent/workflow.rb` | `chat_task`, `log_agent` — workflow integration |

---

## Cross-references

- [../user/Delegation.md](../user/Delegation.md) — User guide to delegation.
- [Provenance.md](Provenance.md) — Receipt-based provenance for delegated inference.
- [../user/MultiAgentWorkflows.md](../user/MultiAgentWorkflows.md) — Orchestration patterns.
- [../../research/agent-delegation-analysis.md](../../research/agent-delegation-analysis.md) — Deep investigation.
- [../../research/multi-agent-patterns-analysis.md](../../research/multi-agent-patterns-analysis.md) — SC26 patterns.
