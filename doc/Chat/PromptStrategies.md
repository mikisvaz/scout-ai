# Prompt Strategies

Long agent conversations with many tool calls can exceed a model's context
window.  **Prompt strategies** are Scout-AI's answer: ephemeral
transformations applied to the chat *just before* it is sent to the model.
They shorten or drop older tool messages so the prompt fits the context budget,
while the **stored chat retains the full, untruncated content**.

This document covers the strategy registry, the `shorten_tools` algorithm in
detail, configuration thresholds, and how agents are informed that pruning may
occur.

Related docs:

- [Chat.md](Chat.md) — the Chat data model and message roles
- [Persistence.md](Persistence.md) — how `.chat` files are stored (full fidelity)
- [../Agent/AgentWorkflow.md](../Agent/AgentWorkflow.md) — where the pruning
  system message is injected into agents
- [../Backends/Backends.md](../Backends/Backends.md) — where `prepare_prompt`
  is called in the inference loop

---

## 1. What prompt strategies are

A prompt strategy is a function that takes an array of message hashes (the
prompt) and returns a *new* array — possibly shortened.  The key property is
**ephemerality**:

- The transformation is applied **inside** `Backend::Default#ask`, on a local
  copy.
- The transformed array is never written back to the chat file.
- The chat on disk always keeps the original, full-fidelity messages.
- Only the API request sees the shortened version.

This design **decouples memory from inference**: the agent remembers everything
it ever saw, but the model only sees what fits in the current context window.

```
  Chat file (full fidelity)           API call (shortened)
  ┌──────────────────────┐           ┌──────────────────────┐
  │ user: ...             │           │ user: ...             │
  │ function_call: ...    │  prepare  │ function_call: ...    │ ← full
  │ function_call_output  │ ────────▶ │ function_call_output  │ ← full (recent)
  │   (15 KB of content)  │  prompt   │   (15 KB of content)  │
  │ function_call: ...    │           │ function_call: ...    │ ← truncated
  │ function_call_output  │           │   "Truncated (8421)…" │ ← shortened
  │   (8 KB)              │           │ …                     │
  │ function_call: ...    │           │                       │ ← dropped
  │ function_call_output  │           │                       │
  │   (12 KB)             │           │                       │
  └──────────────────────┘           └──────────────────────┘
```

---

## 2. The `prepare_prompt` entry point

`Chat.prepare_prompt` is the single entry point.  It is called once per
backend `ask` invocation — i.e., once per API call in the normal path:

```ruby
# Inside Backend::Default#ask (simplified)
messages  = self.messages(question, options)
prompt    = Chat.prepare_prompt(messages, prompt_strategies)   # ← strategy pass
formatted = format_messages(prompt)
response  = query(client, formatted, tools, options)
```

The second argument, `prompt_strategies`, comes from the `options` hash and
supports four input forms:

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil)
  # 1. Proc → call directly, full custom transformation
  return prompt_strategies.call(prompt) if Proc === prompt_strategies

  # 2. nil → fall back to the default strategy list
  prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
  #    DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools)

  # 3. String → comma-separated names
  prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies

  # 4. Apply each named strategy in sequence (chaining)
  prompt_strategies.each do |strategy|
    prompt = case strategy
             when 'shorten_tools' then Chat.shorten_tools(prompt)
             when 'none'          then prompt              # opt-out
             else
               strategy_proc = REGISTERED_STRATEGIES[strategy]
               strategy_proc.call(prompt)
             end
  end
  prompt
end
```

### Key behaviours

| Input form | Effect |
|---|---|
| `nil` | Uses `DEFAULT_CONTEXT_STRATEGY` → `['shorten_tools']` is always active |
| `Proc` | Escape hatch: called with the full prompt array, return value used as-is |
| `"shorten_tools"` or `"a,b,c"` | Split on commas, each name applied in order |
| `"none"` | Recognised no-op; returns the prompt unchanged |
| `["strategy1","strategy2"]` | Each applied in sequence, output chained |

### Chain semantics

Multiple strategies are applied **in sequence** — each receives the output of
the previous one.  This lets you compose strategies (e.g., a custom summarizer
followed by `shorten_tools`).

### Relay mode

When `relay` is set in options (messages sent to a remote relay server),
`prepare_prompt` is **not called** — the raw messages are uploaded as-is and
the relay server is expected to handle its own context management.

---

## 3. The strategy registry

Two mechanisms coexist:

| Mechanism | Where | Purpose |
|---|---|---|
| Hard-coded `case` dispatch | Inside `prepare_prompt` | Built-in strategies: `shorten_tools`, `none` |
| `REGISTERED_STRATEGIES` hash | Referenced for unknown names | Extension point for plugin-registered strategies |

In practice, only `shorten_tools` and `none` are usable today.  The
`REGISTERED_STRATEGIES` constant is referenced but not yet defined in the
codebase, making it a forward-looking extension point.

---

## 4. The `shorten_tools` strategy

### 4.1 The problem it solves

Agent conversations involving tools accumulate `function_call` and
`function_call_output` messages.  A single tool output (e.g., a file read, a
search result) can be several kilobytes.  After 20–30 tool interactions, the
cumulative tool content easily exceeds 100 KB, blowing past most context
windows.

`shorten_tools` walks the message array **in reverse** (newest-first) and
applies a tiered policy: recent tool messages are kept at full fidelity,
middle-aged ones are truncated, and the oldest are dropped entirely.

### 4.2 The algorithm (reverse traversal)

The method iterates from the end (most recent) to the beginning (oldest),
tracking counters:

| Counter | Initial | Increment |
|---|---|---|
| `tool_ids` | `[]` | +1 per `function_call_output` encountered |
| `tool_chars` | `0` | Cumulative chars of *retained* tool content |
| `user_messages` | `1` | +1 per `:user` message |

For each message, the decision depends on its role:

#### `:function_call` (tool invocation request)

| Condition | Action |
|---|---|
| `tool_ids.length < full_tool_calls` **OR** `user_messages == 0` **OR** `tool_chars < max_tool_chars` | **Keep unchanged** |
| `tool_ids.length > max_tool_calls` | **Drop entirely** (`nil`, later compacted out) |
| Otherwise | **Truncate**: replace string arguments with `shorten_string(v)` |

#### `:function_call_output` (tool return value)

| Condition | Action |
|---|---|
| `tool_ids.length < full_tool_outputs` **OR** `user_messages == 0` **OR** `tool_chars < max_tool_chars` | **Keep unchanged** |
| `tool_ids.length > max_tool_outputs` | **Drop entirely** |
| Otherwise | **Truncate**: replace content with `shorten_string(content)` |

#### `:user`, `:assistant`, others

Passed through unchanged (`user_messages` incremented only for `:user`).

After the reverse pass, the result is `compact`ed (removing `nil`s) and
`reverse`d back to chronological order.

### 4.3 The four thresholds

> **Important:** There are **four count/position thresholds** plus one
> character-budget guard.  The defaults are designed so that `shorten_tools`
> is effectively a **no-op for short conversations** — it only activates when
> cumulative tool content exceeds the character budget.

| Threshold | Config key | ENV var | Default | Meaning |
|---|---|---|---|---|
| `full_tool_calls` | `:full_tool_calls` | `FULL_TOOL_CALLS` | **0** | Number of most-recent tool *call* messages kept at full fidelity |
| `full_tool_outputs` | `:full_tool_outputs` | `FULL_TOOL_OUTPUTS` | **10** | Number of most-recent tool *output* messages kept at full fidelity |
| `max_tool_calls` | `:max_tool_calls` | `MAX_TOOL_CALLS` | **40** | Hard limit on tool *call* messages; beyond this they are dropped |
| `max_tool_outputs` | `:max_tool_outputs` | `MAX_TOOL_OUTPUTS` | **40** (defaults to `max_tool_calls`) | Hard limit on tool *output* messages; beyond this they are dropped |
| `max_tool_chars` | `:max_tool_chars` | `MAX_TOOL_CHARS` | **100 000** | Cumulative character budget for retained tool content (guard) |

All thresholds are read via `Scout::Config.get(:key, :prompt, :context, env: '...')`
and **memoized** in class variables on first access:

```ruby
def self.full_tool_calls
  @@full_tool_calls ||= Scout::Config.get(:full_tool_calls, :prompt, :context,
                                          env: 'FULL_TOOL_CALLS')
end

def self.max_tool_outputs
  @@max_tool_outputs ||= Scout::Config.get(:max_tool_outputs, :prompt, :context,
                                           env: 'MAX_TOOL_OUTPUTS',
                                           default: max_tool_calls)
end
```

### 4.4 The three-tier policy in action

For tool outputs (the same logic applies to tool calls with their respective
thresholds):

```
   Position (from end)     Condition                                  Action
  ─────────────────────────────────────────────────────────────────────────────
   Most recent N           tool_ids.length < full_tool_outputs        FULL FIDELITY
   (default N = 10)

   Middle band             between full_tool_outputs and              TRUNCATED
                           max_tool_outputs                           (~400 chars)

   Beyond max              tool_ids.length > max_tool_outputs         DROPPED
   (default 40)
```

The character-budget guard (`max_tool_chars`, default 100 000) overrides
position: if cumulative retained tool content is still under the budget, a
message is kept at full fidelity regardless of its position.  This means
**for short conversations nothing is ever truncated** — the thresholds only
bite once the budget is exceeded.

### 4.5 How shortened messages look

Truncation uses `shorten_string`, which calls `Log.truncate_string` from
scout-essentials.  The middle of the string is replaced with an MD5-based
marker, preserving both the beginning and the end:

```ruby
DEFAULT_SHORT_STRING_LENGTH = 200   # target length

def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH,
                        warning = 'Truncated')
  new = Log.truncate_string(string, DEFAULT_SHORT_STRING_LENGTH)
  new = "#{warning} (#{string.length}): " + new if new.length < string.length
  new
end
```

A truncated value looks like:

```
Truncated (15432): The first ~70 chars of the content...<...15432 - a1b2c...>...last ~70 chars of the content
```

The marker `<...15432 - a1b2c...>` embeds:
- `15432` — the original string length
- `a1b2c` — the first 5 chars of the MD5 digest of the full content

This hash lets you match a truncated value back to the original in logs or the
chat file — useful for debugging "why did the model forget this?" issues.

---

## 5. How agents are informed about pruning

Inside `AgentWorkflow`'s `agent` helper, a system message is injected into the
agent's `start_chat` telling it that old tool content may not be available:

```ruby
agent.start_chat.system <<-EOF
Tool call content may be truncated after #{Chat.full_tool_calls},
and forgoten after #{Chat.max_tool_outputs}.
EOF
```

This nudges the LLM to rely on more recent context and not assume old tool
outputs are still visible.  See [../Agent/AgentWorkflow.md](../Agent/AgentWorkflow.md)
for the full `agent` helper flow.

---

## 6. Configuration

### 6.1 Scout config files

Thresholds live under the `[prompt]` / `[context]` hierarchy:

```yaml
# ~/.scout/config.yaml (or scout@config)
prompt:
  context:
    full_tool_outputs: 20
    max_tool_calls: 60
    max_tool_chars: 200000
```

### 6.2 Environment variables

Each threshold has an uppercase ENV var fallback:

```bash
export FULL_TOOL_OUTPUTS=20
export MAX_TOOL_CHARS=200000
```

### 6.3 Per-call strategy selection

You can override **which strategies** run on a single call via the
`prompt_strategies` option:

```ruby
# Disable all strategies for one call
agent.ask(messages, prompt_strategies: 'none')

# Run a custom Proc
summarizer = ->(msgs) { my_summarize_old_tools(msgs) }
agent.ask(messages, prompt_strategies: summarizer)

# Chain strategies
agent.ask(messages, prompt_strategies: ['shorten_tools', 'my_strategy'])
```

> **Note:** The threshold *values* themselves (e.g., `full_tool_outputs`) are
> always read from global config accessors — they **cannot** be overridden
> per-call.  Only the strategy *selection* can be changed per-call.

### 6.4 Memoization caveat

Thresholds are memoized with `@@foo ||= ...`, so they are **frozen for the
process lifetime** after first access.  Changing the config file or ENV var
mid-process has no effect.  This is fine for typical CLI/agent usage but could
surprise long-running daemons.

---

## 7. Registering a custom strategy

> ⚠️ The `REGISTERED_STRATEGIES` hash is referenced but **not yet defined** in
> the codebase.  The following describes the intended extension point.

The planned API is to add a `Proc` to the `REGISTERED_STRATEGIES` hash:

```ruby
# Hypothetical registration (extension point not yet wired up)
Chat::REGISTERED_STRATEGIES['summarize_old'] = ->(prompt) do
  # Custom logic: summarize tool outputs older than N turns
  prompt.map do |msg|
    if msg[:role] == 'function_call_output' && too_old?(msg)
      msg.merge(content: summarize(msg[:content]))
    else
      msg
    end
  end
end

# Then use it:
agent.ask(messages, prompt_strategies: 'summarize_old')
```

For now, the **Proc escape hatch** is the reliable way to add custom logic:

```ruby
agent.ask(messages, prompt_strategies: ->(msgs) {
  msgs.map { |m| m[:role] == 'function_call_output' ? shorten(m) : m }
})
```

---

## 8. Why strategies are ephemeral

The most important design decision: **strategies never mutate the stored
chat.**  `prepare_prompt` returns a new array (via `reverse` + `collect` +
`compact` + `reverse`), and the backend assigns it to a local variable
(`prompt`), not back to `messages` or the chat object.

| What | Where | Fidelity |
|---|---|---|
| Chat file on disk | `Persist.save_drivers[:chat]` | **Full** — every message preserved |
| `Chat` object in memory | `Agent#current_chat` | **Full** — strategy output never written back |
| API request payload | `Backend::Default#ask` local `prompt` | **Shortened** — what the model actually sees |

This means:
- You can inspect the full conversation later via `ChatAnalyst` or
  `scout llm prov`.
- Re-running the same conversation with a larger context window (higher
  `max_tool_chars`) will show more content — nothing was permanently lost.
- The truncated hash markers (`<...15432 - a1b2c...>`) can be matched against
  the original to identify what was shortened.

---

## 9. Summary

| Aspect | Detail |
|---|---|
| **Purpose** | Fit long tool-heavy conversations into context windows |
| **Entry point** | `Chat.prepare_prompt(prompt, prompt_strategies)` inside `Backend::Default#ask` |
| **Default strategy** | `shorten_tools` (always active unless overridden) |
| **Policy** | Three-tier: full → truncated → dropped (reverse traversal, recency bias) |
| **Guard** | `max_tool_chars` (100 KB) — no truncation until budget exceeded |
| **Ephemerality** | Transformed prompt never saved; chat file retains full fidelity |
| **Agent awareness** | System message injected by `AgentWorkflow` |
| **Custom** | Pass a `Proc` as `prompt_strategies:` option |

---

## Related docs

- [Chat.md](Chat.md) — the Chat data model and message roles
- [Persistence.md](Persistence.md) — `.chat` file format and provenance
- [../Agent/AgentWorkflow.md](../Agent/AgentWorkflow.md) — the `agent` helper that injects the pruning system message
- [../Backends/Backends.md](../Backends/Backends.md) — the inference loop where `prepare_prompt` is called
- [../Tools/Tools.md](../Tools/Tools.md) — tool definitions and the calling protocol
