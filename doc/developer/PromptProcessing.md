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

## The ephemeral design

**Prompt strategies never mutate the stored chat.** The transformation happens
entirely inside the backend's `ask` method:

```ruby
# lib/scout/llm/backends/default.rb
prompt = Chat.prepare_prompt(messages, prompt_strategies)
```

The variable `prompt` is a local derived from `messages`. The original messages
and the underlying Chat object are untouched. This means:

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

## The `shorten_tools` strategy

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

## Configuration thresholds

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

1. **Hard-coded `case` dispatch** for built-in strategies (`shorten_tools`, `none`).
2. **`REGISTERED_STRATEGIES` hash** for user/plugin-registered strategies.

> **Note:** `REGISTERED_STRATEGIES` is referenced in the code but not yet
> defined anywhere in the codebase. Passing an unknown strategy name will raise
> a `NameError`. This is a planned but unimplemented extension point. For now,
> use a `Proc` to supply custom strategies.

---

## Known issues

- **`shorten_string` ignores its `size` parameter** — always uses
  `DEFAULT_SHORT_STRING_LENGTH` (200) regardless of the argument passed.
- **`REGISTERED_STRATEGIES` is undefined** — will raise `NameError` if an
  unknown strategy name is passed.

See [../Improvements.md](../Improvements.md) for the full advisory.

---

## Cross-references

- [../user/ManagingContext.md](../user/ManagingContext.md) — User guide for long contexts.
- [Backends.md](Backends.md) — Where `prepare_prompt` is called in the inference loop.
- [../../research/prompt-strategies-analysis.md](../../research/prompt-strategies-analysis.md) — Deep investigation.
