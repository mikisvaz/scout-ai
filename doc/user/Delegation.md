# Delegation

This page explains how one Scout-AI agent can delegate work to other agents.
It is intended for workflow authors building multi-agent systems.

**You should read this if:** you want an orchestrator agent to hand off
sub-tasks to specialist agents.

---

## What delegation is

Delegation lets one agent (the **caller**) invoke another agent (the
**specialist**) during inference. Each specialist has its own persona, tools,
and conversation history.

Scout-AI provides two delegation mechanisms:

| Mechanism | How it works | When to use |
|-----------|-------------|-------------|
| **`socialize` (the `ask` tool)** | Exposes a single generic `ask` tool. The model chooses which agent to call and what to ask. | When the model should decide when and whom to delegate to |
| **`delegate` (named hand-off tools)** | Pre-registers a `hand_off_to_<name>` tool for a specific agent. | When you want explicit, named delegation to specific agents |

Both mechanisms share a common concept: **inheritance modes** that control how
much context flows from caller to specialist.

---

## Inheritance modes

When a specialist is invoked, you control how much of the caller's context it
receives:

| Mode | What the specialist gets | Use case |
|------|------------------------|----------|
| **`none`** | Only its own system prompt | Fully isolated sub-agent |
| **`tools`** *(default)* | Its own prompt + the caller's tools (but not conversation history) | Same capabilities, private history |
| **`conversation`** | Its own prompt + the caller's entire current conversation | Deep collaboration with shared context |

The specialist always gets **its own** system prompt first. Inherited context
is appended after.

> **Important:** The inheritance mode only applies when a conversation is first
> created. Subsequent turns in the same conversation reuse the accumulated
> history regardless of the mode.

---

## The `ask` tool (socialize)

`socialize` registers a single tool called `ask`. When the LLM calls it, it
provides an agent name and a prompt. Scout-AI loads the specialist, sends the
prompt, and returns the text answer.

### Enabling delegation

```ruby
agent = LLM.load_agent('Orchestrator')
agent.socialize
```

Now the model can call the `ask` tool during inference.

### What the model sees

The model sees a tool with these parameters:

| Parameter | Required | Description |
|-----------|----------|-------------|
| `agent` | Yes | Name of the specialist agent |
| `prompt` | Yes | Plain-text prompt for the specialist |
| `conversation` | No | Named conversation. Omit for one-shot; reuse to continue |
| `inherit` | No (default `tools`) | Context policy for new conversations |

### Conversation persistence

If the model provides a `conversation` name, the specialist keeps that
conversation across multiple calls:

```
Call 1: ask(agent="Worker", prompt="Do X", conversation="task_1")
Call 2: ask(agent="Worker", prompt="Now do Y", conversation="task_1")
# Worker remembers the full conversation from task_1
```

Without a `conversation` name, each call is one-shot (the specialist answers
and the conversation is not reused).

Each delegated call leaves provenance evidence in the parent chat: the
specialist's token usage is recorded next to the tool answer, so token costs
can be traced afterwards with `scout-ai llm prov --evidence`. See the
[developer provenance guide](../developer/Provenance.md) for details.

---

## Named hand-off tools (delegate)

`delegate` creates a specific tool for a pre-loaded agent:

```ruby
worker = LLM.load_agent('Worker')
agent.delegate(worker, :worker, "Delegate work to the Worker agent")
```

This creates a tool called `hand_off_to_worker`. The model calls it with a
`message` parameter.

### Custom delegation blocks

You can customize what happens when the tool is called:

```ruby
agent.delegate(worker, :worker, "Delegate to Worker") do |_name, params|
  worker.start if params[:new_conversation]
  worker.user params[:message]
  worker.chat
end
```

---

## `socialize` vs `delegate`

| Aspect | `socialize` | `delegate` |
|--------|------------|------------|
| Agent selection | Model chooses at call time | Hard-coded at registration |
| Tool count | One `ask` tool for all agents | One tool per agent |
| Conversation management | Named conversations via `conversation` param | Single conversation, resettable |
| Flexibility | High (model decides) | Controlled (you decide) |

**Rule of thumb:** Use `socialize` when the model should decide delegation
dynamically. Use `delegate` when you want explicit control over which agents
are available.

---

## Security: safe delegation

When the model delegates, it provides a prompt string. Scout-AI uses a safe
method to send this prompt to the specialist — it adds it as a plain user
message, not as chat-file syntax. This prevents the model from injecting
control directives (like `tool:` or `system:`) into the specialist's
conversation.

This is important: it means delegation is safe even if the model produces
untrusted output.

---

## Building a multi-agent system

A typical pattern:

1. **Create specialist agents** — each in its own directory with a `start_chat`
   and optional workflow.

2. **Create an orchestrator agent** — its `start_chat` describes the task and
   the available specialists.

3. **Enable delegation** — call `socialize` or `delegate` on the orchestrator.

```ruby
# Orchestrator
orchestrator = LLM.load_agent('Manager')
orchestrator.socialize
orchestrator.start
orchestrator.user "Plan and execute a data analysis pipeline."
orchestrator.chat
```

The model can now delegate sub-tasks to any specialist by name.

---

## Common mistakes

- **Forgetting to call `socialize` or `delegate`**: Without one of these, the
  model has no tool to delegate with.
- **Expecting specialists to share the orchestrator's tools by default**: Only
  if `inherit` is `tools` or `conversation`. With `none`, specialists are
  isolated.
- **Using `conversation: 'current'`**: This is a legacy value. Use explicit
  conversation names or omit the parameter.

---

## Next steps

- [MultiAgentWorkflows.md](MultiAgentWorkflows.md) — orchestration patterns.
- [BuildingAgents.md](BuildingAgents.md) — creating agents.
- [ManagingContext.md](ManagingContext.md) — how delegation affects context.
