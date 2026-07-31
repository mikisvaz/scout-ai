# Managing Context

This page explains how Scout-AI handles conversations that grow too long for
the model's context window, and what you can do to control this behavior. It
is intended for workflow authors building long-running agents or workflows
with many tool calls.

**You should read this if:** your agents make many tool calls, use large files,
or run for many turns.

---

## The problem

LLMs have a limited **context window** — the total number of tokens they can
process in a single inference call. In agent workflows, the context grows as:

- The conversation accumulates turns.
- Tool calls add `function_call` and `function_call_output` messages.
- File imports add large text blocks.

Without management, a long agent session will eventually exceed the context
window and fail.

---

## How Scout-AI manages context automatically

Scout-AI applies **prompt strategies** — transformations to the conversation
just before sending it to the model. These are **ephemeral**: they modify only
what the model sees, never the saved chat file.

The main strategy is **tool-call pruning**. When tool calls accumulate, older
ones are shortened or removed:

| Threshold | Default | What happens |
|-----------|---------|-------------|
| Max tool calls retained | 40 | Older tool call/result pairs beyond this count are removed |
| Recent tool outputs at full fidelity | 10 | The 10 most recent tool outputs are kept in full |
| Character budget for tool outputs | 100,000 | Total characters for all retained tool outputs |

This means:
- The most recent tool calls are always visible in full.
- Older tool calls are progressively truncated.
- Very old tool calls are removed entirely.

The model never sees a truncated prompt — it simply gets a shorter conversation
that fits within its context window.

---

## The `clear` directive

You can explicitly clear conversation history using the `clear:` role in chat
files:

```text
clear:

# Everything before this point is removed from the model's view
```

This is useful when:
- You want to start a new phase of work without prior context cluttering the
  prompt.
- A large file was imported, used, and is no longer needed.
- You're chaining agents and want each to start fresh.

`clear:` is also ephemeral — it affects what the model sees but does not delete
the messages from the saved chat file.

---

## Tips for keeping context manageable

### Be selective with file imports

Instead of importing an entire directory, import only the files you need:

```text
file: src/main.rb
```

Not:

```text
directory: src/
```

### Use tools instead of pre-loading data

If you're not sure whether data will be needed, declare it as a tool instead of
importing it. The model will fetch it only if needed:

```text
introduce: DataLookup
```

Rather than:

```text
file: huge_dataset.json
```

### Break long workflows into steps

Instead of one giant conversation, use a Scout workflow to break work into
steps, each with its own chat:

```ruby
task :analyze => :string do |input|
  # Each step gets its own chat, keeping context focused
end
```

See [MultiAgentWorkflows.md](MultiAgentWorkflows.md) for patterns.

### Delegate to keep conversations focused

An orchestrator agent can delegate sub-tasks to specialists. Each specialist
has its own conversation, keeping the orchestrator's context clean:

```ruby
agent.socialize  # gives the model an 'ask' tool to delegate
```

See [Delegation.md](Delegation.md) for the delegation API.

---

## What you see vs. what the model sees

It's important to understand that the saved chat file may differ from what the
model actually saw:

| Aspect | Saved chat file | What the model sees |
|--------|----------------|-------------------|
| Tool calls | All of them, in full | Possibly truncated/pruned |
| File contents | Full file text | Same (unless cleared) |
| `clear:` directives | Present as markers | Everything before is removed |
| Conversation history | Complete | Recent turns only (after pruning) |

This is by design: the saved chat is the **ground truth** of what happened;
the model's prompt is an **optimized view** for the current inference call.

---

## Common mistakes

- **Expecting the saved chat to match the model's input**: They can differ.
  The saved chat is the record; the model's prompt is ephemeral.
- **Importing too much data**: Large files eat context. Use tools for
  on-demand data access.
- **Not using `clear:` between phases**: If your workflow has distinct phases,
  clearing between them keeps each phase focused.

---

## Next steps

- [WritingChats.md](WritingChats.md) — the `clear:` directive in context.
- [ToolCalling.md](ToolCalling.md) — tools as an alternative to pre-loading.
- [Delegation.md](Delegation.md) — splitting work across agents.
