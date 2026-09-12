# Managing Context

This page explains how Scout-AI handles conversations that grow too long for
the model's context window, and what you can do to control this behavior. It is
intended for workflow authors building long-running agents or workflows with
many tool calls.

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

The default strategy list is `['shorten_tools_epoch_increment', 'inbox']`:
a tool-call pruning strategy with stable compaction boundaries (so provider
prompt caches stay useful), plus the one-off inbox described below. When tool
calls accumulate, older ones are compacted while the recent ones stay whole:

| Threshold | Default | What happens |
|-----------|---------|-------------|
| Tool-call threshold | 50 | At or below this total, nothing is compacted |
| Recent tool calls kept full | 20 | The newest calls stay at full fidelity |
| Compacted tool calls | 80 | The calls before the full-recent window get truncated |

This means:
- The most recent tool calls are always visible in full.
- Older tool calls are progressively truncated (a 400-character short form).
- The boundary only advances in **epochs**, so the same prefix is sent again
  and provider prompt caches stay valid.

The model never sees a truncated prompt — it simply gets a shorter conversation
that fits within its context window. The exact configuration keys and the
(non-default) `shorten_tools` limits are tabulated in
[../developer/PromptProcessing.md](../developer/PromptProcessing.md).

---

## The `inbox` strategy: injecting one-off notices

Sometimes an external process (a workflow step, a cron job, a human dropping
a file) needs to hand the agent a message without going through the chat file.
The **inbox strategy** does that: on each inference it consumes the files in the
chat's inbox directory and injects them as one-off user messages.

The strategy is **on by default**: `inbox` is part of
`DEFAULT_CONTEXT_STRATEGY`, so every chat that passes a `save_file` gets it.
You only need to set `prompt_strategies` to *extend* the default list (a
user-supplied list **replaces** the default rather than appending to it) or to
reorder it:

```text
option prompt_strategies inbox,shorten_tools_epoch_increment
```

or programmatically:

```ruby
options[:prompt_strategies] = 'inbox,shorten_tools_epoch_increment'
```

To turn it off, set `prompt_strategies` to a list without `inbox` (the string
`none` is the recognized no-op that disables every strategy).

### Where the inbox lives

The inbox is a **sibling of the chat's `save_file`**, in the save_file's own
directory: take the save_file basename, strip its **last** extension if it has
one (an extension-less basename keeps the whole name), and append `.inbox`.
The log of delivered files is the same derivation with `.inbox_removed`:

| Context | save_file | Inbox | Removed log |
|---|---|---|---|
| `scout agent ask -c <chat>` | `<chat>.files/<agent>.chat` | `<chat>.files/<agent>.inbox` | `<chat>.files/<agent>.inbox_removed` |
| Agent workflow (`chat_task`) job | `<job>.files/<name>.chat` | `<job>.files/<name>.inbox` | `<job>.files/<name>.inbox_removed` |

A multi-dot save_file strips only the last extension (`a.b.chat` ->
`a.b.inbox`); an extension-less save_file keeps its whole name (`agent` ->
`agent.inbox`).

- Drop a regular file (any name, any extension) into the inbox directory.
  Files are delivered in **sorted filename order**, so name them
  (`001-first.md`, `002-second.md`) if order matters.
- On each inference the file is **moved** to the `.inbox_removed` sibling
  (original modification time preserved; a name collision gets a numeric
  suffix), and its content is appended to the prompt as a `user`-role
  message.
- Write files elsewhere and rename them into the inbox if you want to be sure
  the agent never reads a half-written file.

### Reserved filename: `abort`

One filename is special: a file named exactly `abort` (no extension,
case-sensitive). When the pickup reaches it, the file is consumed like any
other (moved to `.inbox_removed`, never delivered again) but its content is
**not** sent to the model: the inference is aborted instead, with the file
content as the abort reason. The job ends up marked as interrupted/aborted
rather than failing with an ordinary error.

Use it to stop a running agent from outside: `touch <inbox>/abort` for a
plain abort, or write a short reason into the file (`stop, budget exhausted`)
to have it recorded in the job's abort message.

Files that sort before `abort` are consumed in that same run (and not
delivered again); files sorting after it stay in the inbox for the next
inference. No other filename is special: `abort.txt` or `Abort` are ordinary
messages.

### What it does NOT do

- **Injected messages are not persisted.** The model sees them, but the saved
  chat file does not record them; the `.inbox_removed` sibling is the log of
  what was delivered.
- **Delivery is at-most-once.** The file is moved before the message is built,
  so an interrupted inference may drop a notice but never delivers the same
  notice twice.
- **A cached answer skips the inbox.** When a cached answer is replayed, no
  inference runs, so inbox files are left untouched for the next real
  inference (see [RunningInference.md](RunningInference.md) on the ask cache).
- **No inbox, no effect.** If the inbox directory does not exist, the strategy
  is a no-op and creates nothing.

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

Two related directives are honoured inside the `clear:` scan, which walks the
chat backwards and stops at the last `clear:`:

- `clear_tools:` — drops `function_call` / `function_call_output` pairs from
  that point forward as well (`clear_tools: false` keeps them; dropping tool
  calls is the default behaviour of the scan).
- `clear_role: <role>` (alias `clean_role:`) — after the cut, removes every
  message of the named role from what survives.

`import:` has two narrower siblings worth knowing: `continue:` imports only
the last non-empty message of the referenced chat, and `last:` imports its
last message after purging `previous_response_id` messages.

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
tool: DataLookup
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
| Inbox notices | **Absent** (see the `.inbox_removed` sibling) | Injected once, then gone |
| Conversation history | Complete | Recent turns only (after pruning) |

This is by design: the saved chat is the **ground truth** of what happened;
the model's prompt is an **optimized view** for the current inference call.

---

## Common mistakes

- **Expecting the saved chat to match the model's input**: They can differ.
  The saved chat is the record; the model's prompt is ephemeral.
- **Expecting inbox notices in the chat transcript**: Inbox messages are
  delivered to the model only; check the `<files dir>/<name>.inbox_removed`
  sibling of the save_file for the
  delivery record.
- **Importing too much data**: Large files eat context. Use tools for
  on-demand data.
- **Not using `clear:` between phases**: If your workflow has distinct phases,
  clearing between them keeps each phase focused.
- **Expecting `shorten_tools` limits**: those belong to the non-default
  strategy; the default `shorten_tools_epoch_increment` numbers are
  50 / 20 / 80 (see the table above).

---

## Next steps

- [WritingChats.md](WritingChats.md) — The `clear:` directive in context.
- [ToolCalling.md](ToolCalling.md) — Tools as an alternative to pre-loading.
- [Delegation.md](Delegation.md) — Splitting work across agents.
