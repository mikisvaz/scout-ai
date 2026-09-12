# Prompt Processing

This document explains the internal mechanism Scout-AI uses to manage long
contexts before sending a prompt to the LLM. It is intended for framework
contributors.

> For the user-facing guide on what happens when contexts get long, see
> [../user/ManagingContext.md](../user/ManagingContext.md).
> There is no `research/subsys/` study for this subsystem yet; this page is
> the deep reference, and the code remains the source of truth.

---

## What prompt strategies are

Prompt strategies are a **pre-inference transformation layer** that modifies
the chat message list *just before* it is sent to the LLM backend. The primary
motivation is context-window management: in long agent conversations with many
tool calls, the accumulated arguments and return values can consume enormous
amounts of tokens.

The system works by applying named "strategies" to the message array. Each
strategy is a function that takes an Array of message hashes and returns a
(possibly shorter or modified) Array of message hashes.

---

## File layout

Strategy implementations live in `lib/scout/llm/chat/prompt/`:

```
lib/scout/llm/chat/
├── prompt.rb                        # Dispatcher: prepare_prompt, shared constants
└── prompt/
    ├── shorten_tools.rb             # Recomputes the truncation each turn
    ├── shorten_tools_epoch.rb       # Cache-friendly epoch variant
    ├── shorten_tools_epoch_increment.rb # Epochs + growing compacted window (DEFAULT)
    └── inbox.rb                     # Consume-once message inbox (NOT ephemeral)
```

The dispatcher in `prompt.rb` requires the strategy files and delegates to
them via a `case` statement inside `prepare_prompt`.

---

## The ephemeral design (and the one deliberate exception)

**With one exception, prompt strategies never mutate the stored chat.** The
transformation happens entirely inside the backend's `ask` method:

```ruby
# lib/scout/llm/backends/default.rb
prompt = Chat.prepare_prompt(messages, prompt_strategies, save_file: save_file)
```

The variable `prompt` is a local derived from `messages`. The original messages
and the underlying Chat Object are untouched. This means:

- The chat history retains full-fidelity tool outputs for later inspection.
- The agent's persisted memory is not degraded by truncation.
- Only the *next inference* sees the shortened prompt.

This deliberately decouples *what the model sees* from *what the system
remembers*.

**The exception is `inbox`** (see below): it moves consumed files on disk
(side effects survive the inference), although it still never touches the
stored chat transcript.

---

## `prepare_prompt` entry point

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil, save_file: nil)
```

The method supports four input forms for `prompt_strategies`:

| Input type | Behavior |
|---|---|
| `Proc` | Called directly with the prompt array — full custom hook. |
| `nil` | Falls back to `Scout::Config` (`prompt_strategies`, env `PROMPT_STRATEGY`), then `DEFAULT_CONTEXT_STRATEGY` = `['shorten_tools_epoch_increment','inbox']`. |
| `String` | Split by comma into strategy names (e.g., `"inbox,shorten_tools_epoch_increment"`). |
| `Array<String>` | Apply each named strategy in sequence. |

Strategies are applied **in sequence**: each receives the output of the
previous.

The string `"none"` is a recognized no-op that returns the prompt unchanged.

`save_file` is an optional chat-level context (the file the chat is saved to).
It is forwarded to the strategies that declare the keyword — the single-argument
`shorten_*` strategies are unaffected — and is currently consumed by `inbox`.

---

## The `shorten_tools` strategy

### Algorithm

`shorten_tools` walks the message array **in reverse** (newest-first) and
applies a tiered truncation/dropping policy to `function_call` and
`function_call_output` messages. The most recent tool interactions get priority
for full retention; older ones are progressively degraded.

Three counters are tracked during the reverse traversal:

| Counter | Meaning |
|---|---|
| `tool_ids` | Count of tool output messages encountered (from the end) |
| `tool_chars` | Cumulative characters of retained tool content |
| `user_messages` | Number of user messages encountered |

### Three-tier degradation

For tool outputs (the same logic applies to tool calls with separate thresholds):

| Position (from end) | Condition | Action |
|---|---|---|
| Most recent N | `count < full_tool_outputs` | **Full fidelity** |
| Middle band | Between `full_tool_outputs` and `max_tool_outputs` | **Truncated** (content shortened, hash-stamped) |
| Beyond max | `count > max_tool_outputs` | **Dropped entirely** |

There is also a character-budget override: if cumulative tool content is below
`max_tool_chars`, messages are kept at full fidelity regardless of position.
This means **short conversations are never truncated** — the system is a no-op
until context pressure is real.

A second guard, easy to miss from the counters table alone: both keep-tests
also read `user_messages == 0`. The counter starts at 1 and increments only
when a `user` message is passed, so during the reverse (newest-first) walk
every tool message met before the *first earlier user message* still sees
`user_messages == 0` and is kept at full fidelity — the whole newest user
turn is protected, whatever the age of the tool messages inside it.

---

## The `shorten_tools_epoch` strategy (cache-friendly)

### Motivation

`shorten_tools` recomputes the truncation boundary on **every single
inference**. When a new tool call is added, the boundary shifts by one
position, causing every previously-truncated message to be re-evaluated with a
different offset. This means the prompt prefix changes on every turn,
**defeating KV-cache and prompt-cache mechanisms** offered by LLM providers.

`shorten_tools_epoch` solves this by **freezing the compaction boundary** for
windows of N tool calls called *epochs*. Within an epoch, the compacted prefix
is byte-for-byte identical across consecutive inferences, maximizing cache hit
rates.

### Algorithm

The conversation is divided into four regions (newest at the bottom):

```
[ dropped ]      tool calls older than (compacted + full) → removed entirely
[ compacted ]    up to epoch_compacted_tool_calls tool calls, truncated
[ full-recent ]  epoch_full_tool_calls tool calls at full fidelity
[ full-new ]     any tool calls that arrived after the epoch boundary (full fidelity)
```

### Configuration

| Config key | ENV var | Default | Description |
|---|---|---|---|
| `epoch_tool_call_threshold` | `EPOCH_TOOL_CALL_THRESHOLD` | 50 | Total tool calls at or below which no compaction happens |
| `epoch_full_tool_calls` | `EPOCH_FULL_TOOL_CALLS` | 20 | Most-recent tool calls kept at full fidelity |
| `epoch_compacted_tool_calls` | `EPOCH_COMPACTED_TOOL_CALLS` | 80 | Tool calls (before full-recent) to truncate |
| `epoch_size` | `EPOCH_SIZE` | 20 | New tool calls allowed before boundary advances |

All thresholds are read via `Scout::Config.get` and memoized in class
variables, following the same pattern as `shorten_tools`.

---

## The `shorten_tools_epoch_increment` strategy (default)

This is the **current default** (first element of `DEFAULT_CONTEXT_STRATEGY =
['shorten_tools_epoch_increment','inbox']`, `lib/scout/llm/chat/prompt.rb`).
It keeps the epoch-frozen compaction boundary of `shorten_tools_epoch` and
grows two windows over the life of the conversation: the epoch size itself
(periodically, and additionally whenever an epoch contains repeated calls) and,
for each extra call of effective epoch size, the compacted region (growth ratio
2.0, capped at 160 compacted calls). The amount of retained truncated history
therefore increases as the conversation lengthens, instead of always resetting
to a fixed window.

Key extra constants (all read through `Scout::Config` accessors on
`Chat.prompt`/`context`, same memoization pattern):

| Config key | ENV var | Default | Description |
|---|---|---|---|
| `epoch_tool_call_threshold` | `EPOCH_TOOL_CALL_THRESHOLD` | 50 | No compaction below this many tool calls |
| `epoch_full_tool_calls` | `EPOCH_FULL_TOOL_CALLS` | 20 | Most-recent full-fidelity tool calls |
| `epoch_compacted_tool_calls` | `EPOCH_COMPACTED_TOOL_CALLS` | 80 | Compacted window size at epoch start |
| `epoch_size` | `EPOCH_SIZE` | 20 | Initial epoch size |
| `epoch_increment_epochs_per_increase` | `EPOCH_INCREMENT_EPOCHS_PER_INCREASE` | 3 | Completed epochs before the epoch grows |
| `epoch_increment_size_increase` | `EPOCH_INCREMENT_SIZE_INCREASE` | 10 | Periodic epoch-size increase |
| `epoch_increment_repeat_increase` | `EPOCH_INCREMENT_REPEAT_INCREASE` | 10 | Epoch-size increase for epochs with repeated calls |
| `epoch_increment_max_size` | `EPOCH_INCREMENT_MAX_SIZE` | 60 | Upper bound for epoch growth |
| `epoch_increment_compacted_growth_ratio` | `EPOCH_INCREMENT_COMPACTED_GROWTH_RATIO` | 2.0 | Extra compacted calls retained per extra epoch call |
| `epoch_increment_max_compacted_tool_calls` | `EPOCH_INCREMENT_MAX_COMPACTED_TOOL_CALLS` | 160 | Upper bound of the grown compacted window |

Like the other shorten strategies it is **ephemeral**: it only changes what
the model sees; the stored chat keeps full fidelity.

---

## The `inbox` strategy (consume-once message inbox)

`inbox` is the one strategy that deliberately breaks the ephemerality
contract: it has **side effects on disk** (it moves files), although it still
never writes to the chat transcript.

### What it does

On every real inference, when the chat has a `save_file`:

1. Lists the regular files in the chat's inbox directory (dotfiles and
   subdirectories ignored), sorted by filename for deterministic delivery
   order.
2. For each file, **moves it first** into the matching `.inbox_removed`
   sibling (created lazily at the moment of the first move; a name collision
   gets a `.1`, `.2`, ... suffix so previous deliveries are never
   overwritten), then reads it and appends
   `{ role: 'user', content: <file content> }` to the outgoing prompt.
3. The file's mtime is preserved through the move.

### Reserved filename: `abort`

`abort` (exactly, no extension, case-sensitive) is a reserved inbox filename:
when the sorted pickup reaches it, the file is consumed like any other (moved
into `.inbox_removed`, mtime preserved, exactly once) but its content is
**never appended to the prompt**. Instead the strategy raises the
framework-native `Aborted` exception (`scout-essentials`
`lib/scout/exceptions.rb`, the class scout-gear's `Step` raises for SIGTERM
and records as `:aborted` rather than `:error`), so the surrounding job ends
up visibly interrupted instead of silently succeeding. The stripped file
content becomes the abort reason (blank content falls back to a reason
carrying the consumed file's path).

Files that sort **before** `abort` in the same pickup have already been
consumed normally (moved and appended; those appends are lost with the raise,
they are not re-delivered); files sorting **after** it stay in the inbox for
the next run. No other filename is special: `abort.txt`, `Abort`, or a file
whose name merely contains the word are delivered as ordinary messages.

**Move-before-append is deliberate**: a crash between the move and the read
may silently drop a notice, but can never deliver the same notice twice.
Delivery is at-most-once, not exactly-once.

### Gating

- No `save_file` (or blank) → returns messages untouched.
- Inbox directory missing → silent no-op. **The read path never creates
  directories**: writers (you) create the `<stem>.inbox` sibling when there is
  something to deliver, ideally by writing the file elsewhere and renaming it
  in, so a reader never sees a half-written file.

### Paths (the sibling rule)

The inbox is a **sibling of the chat's save_file**, in the save_file's own
directory. The rule: take the save_file basename, strip its **last**
extension if one exists (an extension-less basename keeps the whole name),
and append the suffix:

| save_file | inbox | removed log |
|---|---|---|
| `<X>.files/agent.chat` | `<X>.files/agent.inbox` | `<X>.files/agent.inbox_removed` |
| `dir/a.b.chat` | `dir/a.b.inbox` | `dir/a.b.inbox_removed` |
| `dir/agent` (no extension) | `dir/agent.inbox` | `dir/agent.inbox_removed` |

Use `Chat.inbox_dir(save_file)` / `Chat.inbox_removed_dir(save_file)` rather
than deriving the paths by hand.

### Robustness

Per-file handling is isolated: an unreadable or unmovable file is skipped in
place (logged at low severity) and never raises into the ask path; the other
files are still delivered. Strategies never let a filesystem hiccup break an
inference.

### Semantics to be aware of

- **Injected messages are not persisted**: the model sees them, the saved
  chat file does not. The `.inbox_removed` sibling (with preserved mtimes) is
  the record of what was delivered and when.
- **Cache hits skip the inbox**. `prepare_prompt` runs inside the backend,
  after `LLM.ask`'s persistence layer. A cached answer is replayed without
  any backend code running, so inbox files are neither seen nor consumed on
  that call; they stay for the next real inference.
- **Tool-call rounds**: `prepare_prompt` runs once per round, including every
  `chain_tools` re-entry within one logical turn. The strategy list is
  re-threaded through `chain_tools` like `save_file`, so a user-specified list
  applies on every round. Because a file is moved on consumption, a notice
  delivered on round 1 is not re-delivered on round 2.
- **Invisible to provenance**: the `.inbox` and `.inbox_removed` siblings are
  not matched by the chat-file globs in `Chat::DIRECT_LOG_CHAT_GLOBS`
  (`'*.chat'`, `'*.society/**/*.chat'`), so inbox files are never mistaken
  for chat logs.

### Enabling

`inbox` is part of `DEFAULT_CONTEXT_STRATEGY`, so it is **on by default** for
every chat that passes a `save_file`. You only need to name it when you want
to *extend* the default list (a user-supplied `prompt_strategies` **replaces**
the default rather than appending to it), or to *reorder* it:

```ruby
# In chat options (delivered notices are unaffected by the shortener, but
# inbox-first keeps the semantics obvious)
options[:prompt_strategies] = 'inbox,shorten_tools_epoch_increment'

# Or in a chat file:
# option prompt_strategies inbox,shorten_tools_epoch_increment
```

To disable it, set `prompt_strategies` to a list without `inbox` (the string
`"none"` is the recognized no-op that turns every strategy off).

See [../user/ManagingContext.md](../user/ManagingContext.md) for the
user-facing story.

---

## Configuration thresholds (`shorten_tools`, non-default)

`shorten_tools` is **not** in the default strategy list; the numbers below
apply only when you select it explicitly. All thresholds are read via
`Scout::Config.get` and **memoized in class variables** on first access:

| Config key | ENV var | Default | Description |
|---|---|---|---|
| `full_tool_calls` | `FULL_TOOL_CALLS` | 0 | Recent tool calls kept at full fidelity |
| `full_tool_outputs` | `FULL_TOOL_OUTPUTS` | 10 | Recent tool outputs kept at full fidelity |
| `max_tool_calls` | `MAX_TOOL_CALLS` | 40 | Hard limit; tool calls beyond this are dropped |
| `max_tool_outputs` | `MAX_TOOL_OUTPUTS` | 40 (defaults to `max_tool_calls`) | Hard limit; outputs beyond this are dropped |
| `max_tool_chars` | `MAX_TOOL_CHARS` | 100,000 | Cumulative character budget for retained tool content |

These are `shorten_tools`' own limits. They are not the default-strategy
bounds (see the `shorten_tools_epoch_increment` table above: threshold 50,
20 full, 80 compacted) and they are not a request round limit — the ask loop
has no round counter.

### Memoization trade-off

Because thresholds use `||=` memoization, they are **frozen for the process
lifetime** after first access. Changing config files or ENV vars mid-process
has no effect. This is fine for CLI/agent usage but could be surprising in
long-running daemons.

---

## Content hashing in truncated strings

When a value is truncated, `Log.truncate_string` embeds an MD5 hash prefix:

```
Truncated (15432): The first ~70 chars...<...15432 - a1b2c3...>...last ~70 chars
```

This allows truncated content to be matched against logs or the original chat
for debugging.

---

## Integration with the backend

`prepare_prompt` is called inside `Backend::ClassMethods#ask`, in the normal
(non-relay) path:

```ruby
client = prepare_client(options, messages)
prompt = Chat.prepare_prompt(messages, prompt_strategies, save_file: save_file)
formatted_prompt = format_messages(prompt)
tools = tools(formatted_prompt, options)
response = query(client, formatted_prompt, tools, options)
```

Key points:
- Applied on every `ask` invocation in the normal path, **including every
  `chain_tools` re-entry round** (the strategy list is re-threaded through the
  `chain_tools` options merge alongside `save_file`, so user-specified lists
  apply on every round rather than degrading to the default).
- **Not applied in relay mode** (raw messages are uploaded to a remote server).
- **Not applied on a cache hit**: `LLM.ask`'s `Persist.persist` layer answers
  before any backend code runs. This is the documented reason the `inbox`
  strategy is consume-once *per real inference*, not per logical call.
- Applied **before** `format_messages` — strategy output directly determines
  token consumption.
- `prompt_strategies` comes from the `options` hash, so callers can override
  per-call.

---

## Extension point: custom strategies

Three mechanisms coexist:

1. **Hard-coded `case` dispatch** for the built-in strategies
   (`shorten_tools`, `shorten_tools_epoch`, `shorten_tools_epoch_increment`,
   `inbox`, `none`).
2. **`REGISTERED_STRATEGIES` hash** for user/plugin-registered strategies.
3. **`Chat.send(strategy)` fallback**: any unrecognized name is dispatched to
   the Chat class method of the same name, so defining `def self.my_strategy`
   (plus a `require` of its file) makes it selectable without touching the
   dispatcher.

> **Note:** `REGISTERED_STRATEGIES` starts empty; nothing in the repo
> populates it. It is used by tests and plugins. Its procs receive the prompt
> array only — they do not receive the `save_file:` context; a strategy that
> needs it belongs in the `case` dispatch or in a Chat class method.

---

## Cross-references

- [../user/ManagingContext.md](../user/ManagingContext.md) — User guide for long contexts.
- [Backends.md](Backends.md) — Where `prepare_prompt` is called in the inference loop.
- [../../research/subsys/chat.md](../../research/subsys/chat.md) — Chat subsystem study (parsing, roles, compilation); strategies themselves live here.
