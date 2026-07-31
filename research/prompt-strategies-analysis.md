> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# Prompt Strategies System

> Source file: `lib/scout/llm/chat/prompt.rb` (143 lines)
> Analysis date: 2025-07-30

---

## Overview

### What prompt strategies are and why they exist

The **prompt strategies system** is a pre-inference transformation layer that
modifies the chat message list *just before* it is sent to the LLM backend.
Its primary motivation is **context-window management**: in long agent
conversations with many tool calls, the accumulated tool-call arguments and
tool-return values can consume enormous amounts of tokens.  Without some form
of summarization or truncation, the prompt rapidly exceeds the model's context
limit or becomes prohibitively expensive.

The system works by applying one or more named "strategies" to the message
array.  Each strategy is a function that takes an array of message hashes and
returns a (possibly shorter or modified) array of message hashes.

### The ephemeral (non-persisted) nature

**Critically, prompt strategies operate on a copy of the messages — they never
mutate the stored chat.**  The transformation happens entirely inside the
backend's `ask` method:

```ruby
# lib/scout/llm/backends/default.rb, line 494
prompt = Chat.prepare_prompt(messages, prompt_strategies)
formatted_prompt = format_messages(prompt)
```

The variable `prompt` is a *local* derived from `messages` (which itself comes
from `self.messages(question, options)`).  The original `messages` and the
underlying `Chat` object are untouched.  Whatever truncation, shortening, or
dropping of tool-call/output content occurs is visible **only to the LLM API
call** — it is never written back to the chat log, the job, or any persisted
artifact.  This means:

- The chat history retains full-fidelity tool outputs for later inspection.
- The agent's "memory" (in persisted chats) is not degraded by truncation.
- Only the *next inference* sees the shortened prompt.

This is a deliberate design choice: it decouples *what the model sees* from
*what the system remembers*.

---

## The `prepare_prompt` Entry Point

### Method signature

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil)
```

| Parameter           | Type                                | Description                              |
|---------------------|-------------------------------------|------------------------------------------|
| `prompt`            | `Array<Hash>`                       | Array of message hashes (the chat)       |
| `prompt_strategies` | `nil`, `String`, `Array<String>`, or `Proc` | Which strategy/strategies to apply |

### How it selects and applies strategies

The method supports four input forms for `prompt_strategies`:

```ruby
def self.prepare_prompt(prompt, prompt_strategies = nil)
  # 1. If a Proc is given, call it directly with the prompt — full custom hook
  return prompt_strategies.call(prompt) if Proc === prompt_strategies

  # 2. If nil, fall back to the default strategy list
  prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
  #    → DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools)

  # 3. If a comma-separated String, split into an array
  prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies

  # 4. Apply each named strategy in sequence
  prompt_strategies.each do |strategy|
    prompt = case strategy
             when 'shorten_tools'
               Chat.shorten_tools(prompt)
             when 'none'
               prompt                       # no-op / opt-out
             else
               strategy_proc = REGISTERED_STRATEGIES[strategy]
               strategy_proc.call(prompt)
             end
  end
  return prompt
end
```

**Key behaviors:**

1. **Proc bypass:** If `prompt_strategies` is a `Proc`, it is called directly
   with the full prompt array and its return value is used as-is.  This is an
   escape hatch for fully custom, programmatic transformations that don't fit
   the named-strategy model.

2. **Default:** When `prompt_strategies` is `nil` (the common case, since the
   backend passes the value from `options` which defaults to `nil`), the
   constant `DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools)` is used.  This means
   **`shorten_tools` is always active unless explicitly disabled**.

3. **String shorthand:** A comma-separated string like `"shorten_tools,other"`
   is split into individual strategy names.

4. **Chaining:** Multiple strategies are applied **in sequence** — each
   strategy receives the output of the previous one.

5. **Opt-out with `'none'`:** The string `"none"` is a recognized no-op that
   returns the prompt unchanged.  To completely disable all strategies, pass
   `prompt_strategies: 'none'` (or `["none"]`).

### Strategy registration mechanism

Two mechanisms coexist:

| Mechanism                    | Where                                   | Purpose                                                     |
|------------------------------|-----------------------------------------|-------------------------------------------------------------|
| Hard-coded `case` dispatch   | Inside `prepare_prompt`                 | Built-in strategies (`shorten_tools`, `none`)              |
| `REGISTERED_STRATEGIES` hash | Referenced at line 137                  | Extension point for user/plugin-registered strategies      |

The `REGISTERED_STRATEGIES` constant is **referenced but not defined in this
file**.  A grep across the entire codebase finds no definition:

```
$ grep -rn "REGISTERED_STRATEGIES" lib/
lib/scout/llm/chat/prompt.rb:137:  strategy_proc = REGISTERED_STRATEGIES[strategy]
```

This means `REGISTERED_STRATEGIES` is either:
- Defined in another file that `require`s or reopens the `Chat` module (not
  found in the current codebase), or
- A forward-looking extension point that is **not yet wired up** — if an
  unknown strategy name is passed and `REGISTERED_STRATEGIES` is undefined, it
  will raise a `NameError`.

In practice, only `shorten_tools` and `none` are usable today.

---

## Each Strategy

### `shorten_tools`

**Name:** `'shorten_tools'`

**What it does:** Walks the message array **in reverse** (newest-first) and
applies a tiered truncation/dropping policy to `function_call` and
`function_call_output` messages.  The goal is to keep the most recent tool
interactions at full fidelity while progressively shortening or removing older
ones.

**Algorithm (reverse traversal):**

The method iterates messages from the end (most recent) to the beginning
(oldest), tracking three counters:

| Counter            | Initial | Increment                                                |
|--------------------|---------|----------------------------------------------------------|
| `tool_ids`         | `[]`    | One entry per `function_call_output` encountered         |
| `tool_chars`       | `0`     | Cumulative characters of *retained* tool message content |
| `user_messages`    | `1`     | +1 for each `:user` message                              |

For each message, depending on its role:

#### `:function_call` (tool invocation request)

1. If `tool_ids.length < full_tool_calls` **OR** `user_messages == 0` **OR**
   `tool_chars < max_tool_chars` → **keep unchanged** (add to `tool_chars`).
2. Else if `tool_ids.length > max_tool_calls` → **drop entirely** (`next`
   returns `nil`, later `compact`ed out).
3. Else → **truncate string arguments**: iterate over the `arguments` hash;
   for each string value, replace with `shorten_string(v)`.  If nothing
   actually changed, keep original.  Otherwise, rebuild JSON and update
   `tool_chars`.

#### `:function_call_output` (tool return value)

1. Append `id` to `tool_ids`.
2. If `tool_ids.length < full_tool_outputs` **OR** `user_messages == 0` **OR**
   `tool_chars < max_tool_chars` → **keep unchanged** (add to `tool_chars`).
3. Else if `tool_ids.length > max_tool_outputs` → **drop entirely**.
4. Else → **truncate content**: call
   `shorten_string(content, DEFAULT_SHORT_STRING_LENGTH * 2)` (i.e., target
   length 400).  If unchanged, keep original; otherwise rebuild JSON.

#### `:user`, `:assistant`, other → **pass through unchanged**

(`user_messages` is incremented for `:user` messages only.)

After the reverse pass, the result is `compact`ed (removing `nil`s from
dropped messages) and then `reverse`d back to chronological order.

**When it activates:** It is the **default strategy** — it runs on every
backend `ask` call unless `prompt_strategies` is set to `'none'`, a custom
`Proc`, or an empty array.

**The `shorten_string` helper:**

```ruby
DEFAULT_SHORT_STRING_LENGTH = 200

def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH, warning = 'Truncated')
  new = Log.truncate_string(string, DEFAULT_SHORT_STRING_LENGTH)
  if new.length < string.length
    new = "#{warning} (#{string.length}): " + new
  end
  new
end
```

> **Note:** The `size` parameter is accepted but **not actually used** — the
> method always passes `DEFAULT_SHORT_STRING_LENGTH` (200) to
> `Log.truncate_string`.  This appears to be a minor bug or oversight; the
> `size` argument is effectively dead code.

`Log.truncate_string` (from `scout-essentials`) replaces the middle of the
string with an MD5-based marker:

```ruby
FP_MAX_STRING = 150

def self.truncate_string(string, max = FP_MAX_STRING)
  if string.length > max
    digest = Digest::MD5.hexdigest(string)
    middle = "<...#{string.length} - #{digest[0..4]}...>"
    s = (max - middle.length) / 2
    string.slice(0, s-1) + middle + string.slice(-s, string.length)
  else
    string
  end
end
```

So a truncated value looks like:
`Truncated (15432): The first ~70 chars...<...15432 - a1b2c...>...last ~70 chars`

This preserves the beginning and end of the value and embeds a content hash
for debugging/identification.

### `'none'`

A simple no-op — returns the prompt unchanged.  Used to explicitly opt out of
all strategies.

---

## Thresholds and Configuration

All five thresholds are read via `Scout::Config.get` with the config path
`:prompt, :context` and a corresponding uppercase ENV var fallback.  They are
**memoized** in class variables (`@@foo ||= ...`) on first access.

### Summary table

| Config key           | ENV var               | Default                         | Memoized in          | Description                                                              |
|----------------------|-----------------------|---------------------------------|----------------------|--------------------------------------------------------------------------|
| `full_tool_calls`    | `FULL_TOOL_CALLS`     | `0`                             | `@@full_tool_calls`  | Number of most-recent tool *call* messages kept at full fidelity         |
| `full_tool_outputs`  | `FULL_TOOL_OUTPUTS`   | `10`                            | `@@full_tool_outputs`| Number of most-recent tool *output* messages kept at full fidelity       |
| `max_tool_calls`     | `MAX_TOOL_CALLS`      | `40`                            | `@@max_tool_calls`   | Hard limit; tool *call* messages beyond this count are dropped entirely  |
| `max_tool_outputs`   | `MAX_TOOL_OUTPUTS`    | defaults to `max_tool_calls` (→ `40`) | `@@max_tool_outputs` | Hard limit; tool *output* messages beyond this count are dropped entirely |
| `max_tool_chars`     | `MAX_TOOL_CHARS`      | `100_000`                       | `@@max_tool_chars`   | Cumulative character budget for retained tool content                    |

### Config accessors (all follow the same pattern)

```ruby
def self.full_tool_calls
  @@full_tool_calls ||= Scout::Config.get(:full_tool_calls, :prompt, :context, env: 'FULL_TOOL_CALLS')
end

def self.full_tool_outputs
  @@full_tool_outputs ||= Scout::Config.get(:full_tool_outputs, :prompt, :context, env: 'FULL_TOOL_OUTPUTS')
end

def self.max_tool_calls
  @@max_tool_calls ||= Scout::Config.get(:max_tool_calls, :prompt, :context, env: 'MAX_TOOL_CALLS')
end

def self.max_tool_outputs
  @@max_tool_outputs ||= Scout::Config.get(:max_tool_outputs, :prompt, :context, env: 'MAX_TOOL_OUTPUTS', default: max_tool_calls)
end

def self.max_tool_chars
  @@max_tool_chars ||= Scout::Config.get(:max_tool_chars, :prompt, :context, env: 'MAX_TOOL_CHARS')
end
```

### How they can be overridden

1. **Scout config files** — under the `[prompt]` / `[context]` hierarchy
   (e.g., `scout@config` entries or config YAML).
2. **Environment variables** — uppercase names listed above (e.g.,
   `export FULL_TOOL_OUTPUTS=20`).
3. **Direct Ruby assignment** — since the accessors use `||=` memoization,
   assigning to the class variable before first access overrides the config
   lookup: `Chat.class_variable_set(:@@full_tool_calls, 5)`.  (Not a public
   API but technically possible.)
4. **`options` hash at call time** — The backend's `ask` method extracts
   `prompt_strategies` from `options`, but the *threshold values themselves*
   are **not** passed per-call; they are always read from the global config
   accessors.  You cannot override thresholds for a single API call — only
   globally.

### Three-tier policy in action

For tool outputs (the same logic applies to tool calls with their respective
thresholds):

| Position (from end) | Condition                              | Action            |
|---------------------|----------------------------------------|-------------------|
| Most recent N       | `tool_ids.length < full_tool_outputs`  | **Full fidelity** |
| Middle band         | Between `full_tool_outputs` and `max_tool_outputs` | **Truncated** (content shortened to ~400 chars) |
| Beyond max          | `tool_ids.length > max_tool_outputs`   | **Dropped**       |

There is also a character-budget override: if `tool_chars < max_tool_chars`,
the message is kept at full fidelity regardless of position.  This means for
short conversations, nothing is ever truncated — the thresholds only bite
once cumulative tool content exceeds 100 KB by default.

---

## Integration with Backend

### Where and when `prepare_prompt` is called

In `lib/scout/llm/backends/default.rb`, inside the `ask` method (line ~476–500):

```ruby
def ask(question, options = {}, &block)
  # ...
  return_messages, log_response, current_meta, relay, process, prompt_strategies =
    IndiferentHash.process_options options,
      :return_messages, :log_response, :current_meta, :relay, :process, :prompt_strategies,
      return_messages: false, log_response: true

  messages = self.messages(question, options)

  if relay
    # Relay mode: messages sent to a remote relay server — NO prompt strategies applied
    id = upload_messages(relay, messages, options)
    response = gather_response(relay, id)
    formatted_prompt = format_messages(messages)    # ← uses raw messages
    tools = tools(formatted_prompt, options)
  else
    # Normal mode: prompt strategies applied here
    client = prepare_client(options, messages)
    prompt = Chat.prepare_prompt(messages, prompt_strategies)  # ← LINE 494
    formatted_prompt = format_messages(prompt)
    tools = tools(formatted_prompt, options)

    response = query(client, formatted_prompt, tools, options)
    # ...
  end
end
```

**Key integration points:**

1. **Called on every `ask` invocation** (i.e., every API call in the normal
   path).  There is no conditional gating beyond the `relay` vs. normal-path
   split.

2. **Not applied in relay mode.** When `relay` is set, the raw `messages` are
   uploaded to a remote server and strategies are skipped.  Presumably the
   relay server handles its own context management, or the expectation is that
   relayed conversations are shorter.

3. **Applied before `format_messages`.** The shortened `prompt` is what gets
   formatted into the final API payload.  This means strategy output directly
   determines token consumption.

4. **Applied after `prepare_client`.** The client is prepared with the original
   `messages`, but the query uses the shortened `prompt`.  (This may matter if
   `prepare_client` does any token estimation — it would overestimate.)

5. **`prompt_strategies` comes from `options`.** Callers can pass
   `prompt_strategies: 'none'` or `prompt_strategies: ['custom_strategy']` or
   `prompt_strategies: ->(msgs) { ... }` in the options hash to override the
   default.

### Where options originate

The `options` hash passed to `ask` typically comes from the agent or workflow
layer.  In the agent workflow helper (`lib/scout/llm/agent/workflow.rb`), the
system prompt even informs the agent about the current truncation thresholds:

```ruby
agent.start_chat.system <<-EOF
Tool call content may be truncated after #{Chat.full_tool_calls}, and forgoten after #{Chat.max_tool_outputs}.
EOF
```

This tells the LLM that old tool content may not be available, encouraging it
to rely on more recent context.

---

## Key Design Notes

### 1. Ephemeral transformation — decouples memory from inference

The most important design decision is that strategies **never mutate the
stored chat**.  The `prepare_prompt` method receives the messages array, but
it returns a *new* array (via `reverse` + `collect` + `compact` + `reverse`),
and the backend assigns it to a local variable (`prompt`), not back to
`messages` or the chat object.  The chat retains full-fidelity data; only the
API call sees the shortened version.

### 2. Reverse traversal for recency bias

`shorten_tools` iterates in reverse so that the **most recent** tool
interactions are counted first and thus get priority for full retention.
Older messages are the ones truncated or dropped.  This mirrors how human
context windows work: recent context is most relevant.

### 3. Three-tier degradation (keep → truncate → drop)

Instead of a binary keep/drop, the system offers graceful degradation:
- Recent: full content
- Middle: truncated strings (hash-stamped for traceability)
- Old: completely removed

This avoids abrupt context loss where the model suddenly can't see a tool
result it was just referencing.

### 4. Character budget as a global guard

The `max_tool_chars` threshold (default 100,000) acts as a total budget.  If
the conversation is small enough that all tool content fits within the budget,
**no truncation happens at all** — regardless of the count thresholds.  This
means the system is effectively a no-op for short conversations and only
activates when context pressure is real.

### 5. Proc escape hatch

Supporting `Proc` as a strategy type allows fully custom, programmatic
transformations without modifying the framework.  This is an extensibility
point for advanced users who want, e.g., LLM-based summarization of old tool
outputs.

### 6. Content-hash in truncated strings

`Log.truncate_string` embeds an MD5 hash prefix (`digest[0..4]`) in the
truncation marker.  This means a truncated value like
`<...15432 - a1b2c...>` can be matched against logs or the original chat to
identify what was removed — useful for debugging "why did the model forget
this?" issues.

### 7. Config memoization trade-off

Thresholds are memoized in class variables (`@@foo ||= ...`).  This means:
- **Pro:** No repeated config lookups during a session; consistent values.
- **Con:** Values are **frozen for the process lifetime** after first access.
  Changing the config file or ENV var mid-process has no effect.  This is
  fine for typical CLI/agent usage but could be surprising in long-running
  daemons.

### 8. Minor issues observed

- **`shorten_string` ignores its `size` parameter** — always uses
  `DEFAULT_SHORT_STRING_LENGTH` (200).  The call at line ~115 passes
  `DEFAULT_SHORT_STRING_LENGTH * 2` (400) as the size, but it has no effect.
- **`REGISTERED_STRATEGIES` is undefined** — referenced at line 137 but never
  defined anywhere in the codebase.  Passing an unknown strategy name will
  raise `NameError` rather than a helpful error.  This is likely a planned
  but unimplemented extension point.

---

## Appendix: Full source listing of `lib/scout/llm/chat/prompt.rb`

```ruby
module Chat

  DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools)
  DEFAULT_SHORT_STRING_LENGTH = 200
  DEFAULT_SHORT_JSON_LENGTH = 2000

  DEFAULT_FULL_TOOL_CALLS = 0
  DEFAULT_FULL_TOOL_OUTPUTS = 10
  DEFAULT_MAX_TOOL_CALLS = 40
  DEFAULT_MAX_TOOL_OUTPUTS = DEFAULT_MAX_TOOL_CALLS
  DEFAULT_MAX_TOOL_CHARS = 100_000

  def self.shorten_string(string, size = DEFAULT_SHORT_STRING_LENGTH, warning = 'Truncated')
    new = Log.truncate_string(string, DEFAULT_SHORT_STRING_LENGTH)
    if new.length < string.length
      new = "#{warning} (#{string.length}): " + new
    end
    new
  end

  def self.full_tool_calls
    @@full_tool_calls ||= Scout::Config.get(:full_tool_calls, :prompt, :context, env: 'FULL_TOOL_CALLS')
  end

  def self.full_tool_outputs
    @@full_tool_outputs ||= Scout::Config.get(:full_tool_outputs, :prompt, :context, env: 'FULL_TOOL_OUTPUTS')
  end

  def self.max_tool_calls
    @@max_tool_calls ||= Scout::Config.get(:max_tool_calls, :prompt, :context, env: 'MAX_TOOL_CALLS')
  end

  def self.max_tool_outputs
    @@max_tool_outputs ||= Scout::Config.get(:max_tool_outputs, :prompt, :context, env: 'MAX_TOOL_OUTPUTS', default: max_tool_calls)
  end

  def self.max_tool_chars
    @@max_tool_chars ||= Scout::Config.get(:max_tool_chars, :prompt, :context, env: 'MAX_TOOL_CHARS')
  end

  def self.shorten_tools(messages)
    tool_ids = []
    tool_chars = 0
    user_messages = 1
    assistant_messages = 0

    full_tool_calls = self.full_tool_calls || DEFAULT_FULL_TOOL_CALLS
    full_tool_outputs = self.full_tool_outputs || DEFAULT_FULL_TOOL_OUTPUTS
    max_tool_calls = self.max_tool_calls || DEFAULT_MAX_TOOL_CALLS
    max_tool_outputs = self.max_tool_outputs || DEFAULT_MAX_TOOL_OUTPUTS
    max_tool_chars = self.max_tool_chars || DEFAULT_MAX_TOOL_CHARS

    full_tool_calls = full_tool_calls.to_i
    full_tool_outputs = full_tool_outputs.to_i
    max_tool_calls = max_tool_calls.to_i
    max_tool_outputs = max_tool_outputs.to_i
    max_tool_chars = max_tool_chars.to_i

    messages.reverse.collect do |msg|
      case msg[:role].to_sym
      when :function_call
        json = msg[:content]
        next msg unless json

        tool_call = JSON.parse json
        name, arguments, id = tool_call.values_at 'name', 'arguments', 'id'

        if tool_ids.length < full_tool_calls || user_messages == 0 || tool_chars < max_tool_chars
          tool_chars += json.length
          msg
        elsif tool_ids.length > max_tool_calls
          Log.medium "Skipped tool call #{id} #{name} #{json.length}"
          next
        else
          new_arguments = {}
          arguments.each do |k,v|
            new_arguments[k] = String === v ? shorten_string(v) : v
          end if arguments

          next msg if arguments.values == new_arguments.values

          tool_call['arguments'] = new_arguments
          json = tool_call.to_json
          tool_chars += json.length
          Log.medium "Truncated tool call #{id} #{name} #{msg[:content].length} to #{json.length}"
          msg = msg.dup
          msg[:content] = json
          msg
        end
      when :function_call_output
        json = msg[:content]
        next msg unless json

        tool_call = JSON.parse json
        name, content, id = tool_call.values_at 'name', 'content', 'id'
        tool_ids << id

        if tool_ids.length < full_tool_outputs || user_messages == 0 || tool_chars < max_tool_chars
          tool_chars += json.length
          msg
        elsif tool_ids.length > max_tool_outputs
          Log.medium "Skipped tool output #{id} #{name} #{json.length}"
          next
        else
          tool_call['content'] = shorten_string(content, DEFAULT_SHORT_STRING_LENGTH*2)
          next msg if content == tool_call['content']
          json = tool_call.to_json
          tool_chars += json.length
          Log.medium "Truncated tool output #{id} #{name} #{msg[:content].length} to #{json.length}"
          msg = msg.dup
          msg[:content] = json
          msg
        end
      when :user
        user_messages += 1
        msg
      when :assistant
        assistant_messages += 1
        msg
      else
        msg
      end
    end.compact.reverse
  end

  def self.prepare_prompt(prompt, prompt_strategies = nil)
    return prompt_strategies.call(prompt) if Proc === prompt_strategies
    prompt_strategies = DEFAULT_CONTEXT_STRATEGY if prompt_strategies.nil?
    prompt_strategies = prompt_strategies.split(',') if String === prompt_strategies
    prompt_strategies.each do |strategy|
      prompt = case strategy
               when 'shorten_tools'
                 Chat.shorten_tools(prompt)
               when 'none'
                 prompt
               else
                 strategy_proc = REGISTERED_STRATEGIES[strategy]
                 strategy_proc.call(prompt)
               end
    end
    return prompt
  end
end
```
