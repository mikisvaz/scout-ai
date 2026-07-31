# Prompt Processing

This document explains the internal mechanism Scout-AI uses to manage long
contexts before sending a prompt to the LLM. It is intended for framework
contributors.

> For the user-facing guide on what happens when contexts get long, see
> [../user/ManagingContext.md](../user/ManagingContext.md).
> For deep code investigation, see
> [../../research/prompt-strategies-analysis.md](../../research/prompt-strategies-analysis.md).

---

## What prompt strategies are

Prompt strategies are a **pre-inference transformation layer** that modifies
the chat message list *just before* it is sent to the LLM backend. The primary
motivation is context-window management: in long agent conversations with many
tool calls, the accumulated arguments and return values can consume enormous
amounts of tokens.

The system works by applying named "strategies" to the message array. Each
strategy is a function that takes an Array of message hashes and returns a
(possibly shorter or modified) Array.

---

## File layout

Strategy implementations live in `lib/scout/llm/prompt/`:

```
lib/scout/llm/
├── chat/
│   └── prompt.rb              # Dispatcher: prepare_prompt, shared constants
└── prompt/
    ├── shorten_tools.rb       # Default strategy (recomputes each turn)
    └── shorten_tools_epoch.rb # Cache-friendly epoch variant
```

The dispatcher in `prompt.rb` requires both strategy files and delegates to
them via a `case` statement inside `prepare_prompt`.

---

## The ephemeral design

**Prompt strategies never mutate the stored chat.** The transformation happens
entirely inside the backend's `ask` method:

```ruby
# lib/scout/llm/backends/default.rb
prompt = Chat.prepare_prompt(messages, prompt_strategies)
```

The variable `prompt` is a local derived from `messages`. The original messages
and the underlying Chat Object are untouched. This means:

- The chat history retains full-fidelity tool outputs for later inspection.
- The agent's persisted memory is not degraded by truncation.
- Only the *next inference* sees the shortened prompt.

This deliberately decouples *what the model sees* from *what the system
remembers*.

---

## `prepare_prompt` entry point

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil)
```

The method supports four input forms for `prompt_strategies`:

| Input type | Behavior |
|---|---|
| `Proc` | Called directly with the prompt array — full custom hook. |
| `nil` | Falls back to `DEFAULT_CONTEXT_STRATEGY` = `%w(shorten_tools)`. |
| `String` | Split by comma into strategy names (e.g., `"shorten_tools,custom"`). |
| `Array<String>` | Apply each named strategy in sequence. |

Strategies are applied **in sequence**: each receives the output of the previous.

The string `"none"` is a recognized no-op that returns the prompt unchanged.

---

## The `shorten_tools` strategy (default)

This is the **default strategy** — it runs on every backend `ask` call unless
explicitly disabled.

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

---

## The `shorten_tools_epoch` strategy (cache-friendly)

### Motivation

The default `shorten_tools` strategy recomputes the truncation boundary on
**every single inference**. When a new tool call is added, the boundary shifts
by one position, causing every previously-truncated message to be re-evaluated
with a different offset. This means the prompt prefix changes on every turn,
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

The `compacted` and `full-recent` regions are **pinned** relative to the epoch
boundary, not the live tool-call count. Their content stays stable until the
boundary advances.

### Epoch boundary calculation

```
overflow  = total_tool_calls - threshold        # how many beyond threshold
epoch_idx = overflow > 0 ? (overflow - 1) / epoch_size : 0
pinned_total = threshold + (epoch_idx * epoch_size)
new_calls = total_tool_calls - pinned_total     # tool calls that arrived this epoch
```

The `pinned_total` determines where the `full-recent` region starts. Any tool
calls beyond `pinned_total` are treated as "new" and kept at full fidelity.

### Worked example (threshold=100, full=10, compacted=40, epoch_size=10)

| Tool calls | pinned_total | new_calls | keep_full | compacted | dropped |
|---|---|---|---|---|---|
| 100 | 100 | 0 | 10 | 40 | 50 |
| 101 | 100 | 1 | 11 | 40 | 50 |
| 105 | 100 | 5 | 15 | 40 | 50 |
| 110 | 100 | 10 | 20 | 40 | 50 |
| 111 | 110 | 1 | 11 | 40 | 60 |

From tool calls 101–110 the compacted region (calls 11–50 from the pinned
boundary) is **identical**, so the prompt prefix is cache-stable for 10
consecutive inferences. At call 111 the boundary advances and the compacted
region shifts.

### Configuration

| Config key | ENV var | Default | Description |
|---|---|---|---|
| `epoch_tool_call_threshold` | `EPOCH_TOOL_CALL_THRESHOLD` | 50 | Total tool calls at or below which no compaction happens |
| `epoch_full_tool_calls` | `EPOCH_FULL_TOOL_CALLS` | 10 | Most-recent tool calls kept at full fidelity |
| `epoch_compacted_tool_calls` | `EPOCH_COMPACTED_TOOL_CALLS` | 40 | Tool calls (before full-recent) to truncate |
| `epoch_size` | `EPOCH_SIZE` | 10 | New tool calls allowed before boundary advances |

All thresholds are read via `Scout::Config.get` and memoized in class variables,
following the same pattern as `shorten_tools`.

### Enabling the epoch strategy

To use it instead of the default, pass the strategy name:

```ruby
# In options
options[:prompt_strategies] = 'shorten_tools_epoch'

# Or directly
Chat.prepare_prompt(messages, 'shorten_tools_epoch')
```

To switch the default system-wide, set:

```ruby
Chat::DEFAULT_CONTEXT_STRATEGY.replace(['shorten_tools_epoch'])
```

---

## Configuration thresholds (`shorten_tools`)

All thresholds are read via `Scout::Config.get` and **memoized** in class
variables on first access:

| Config key | ENV var | Default | Description |
|---|---|---|---|
| `full_tool_calls` | `FULL_TOOL_CALLS` | 0 | Recent tool calls kept at full fidelity |
| `full_tool_outputs` | `FULL_TOOL_OUTPUTS` | 10 | Recent tool outputs kept at full fidelity |
| `max_tool_calls` | `MAX_TOOL_CALLS` | 40 | Hard limit; tool calls beyond this are dropped |
| `max_tool_outputs` | `MAX_TOOL_OUTPUTS` | 40 (defaults to `max_tool_calls`) | Hard limit; outputs beyond this are dropped |
| `max_tool_chars` | `MAX_TOOL_CHARS` | 100,000 | Cumulative character budget for retained tool content |

### Memoization trade-off

Because thresholds use `||=` memoization, they are **frozen for the process
lifetime** after first access. Changing config files or ENV vars mid-process
has no effect. This is fine for CLI/agent usage but could be surprising in
long-running daemons.

---

## Content hashing in truncated strings

When a value is truncated, `Log.truncate_string` embeds an MD5 hash prefix:

```
Truncated (15432): The first ~70 chars...<...15432 - a1b2c...>...last ~70 chars
```

This allows truncated content to be matched against logs or the original chat
for debugging.

---

## Integration with the backend

`prepare_prompt` is called inside `Backend::Default#ask`, in the normal
(non-relay) path:

```ruby
client = prepare_client(options, messages)
prompt = Chat.prepare_prompt(messages, prompt_strategies)
formatted_prompt = format_messages(prompt)
tools = tools(formatted_prompt, options)
response = query(client, formatted_prompt, tools, options)
```

Key points:
- Applied on every `ask` invocation in the normal path.
- **Not applied in relay mode** (raw messages are uploaded to a remote server).
- Applied **before** `format_messages` — strategy output directly determines
  token consumption.
- `prompt_strategies` comes from the `options` hash, so callers can override
  per-call.

---

## Extension point: custom strategies

Two mechanisms coexist:

1. **Hard-coded `case` dispatch** for built-in strategies (`shorten_tools`,
   `shorten_tools_epoch`, `none`).
2. **`REGISTERED_STRATEGIES` hash** for user/plugin-registered strategies.

> **Note:** `REGISTERED_STRATEGIES` is referenced in the code but not yet
> populated with entries. Passing an unknown strategy name will result in
> `nil.call(prompt)`, raising a `NoMethodError`. For now, use a `Proc` to
> supply custom strategies.

---

## Cross-references

- [../user/ManagingContext.md](../user/ManagingContext.md) — User guide for long contexts.
- [Backends.md](Backends.md) — Where `prepare_prompt` is called in the inference loop.
- [../../research/prompt-strategies-analysis.md](../../research/prompt-strategies-analysis.md) — Deep investigation.
