# Improvements Advisory

This document catalogs known code issues, documentation gaps, architectural
suggestions, and anti-patterns to avoid when contributing to Scout-AI. It is
derived from the research artifacts in [../research/](../research/) and is
intended as a living reference for maintainers and contributors.

Each entry includes a priority to help triage effort:

| Priority | Meaning |
|---|---|
| **High** | Correctness bug, security concern, or actively misleading behavior. Fix soon. |
| **Medium** | Technical debt that hampers maintainability or extensibility. Address when touching the area. |
| **Low** | Cleanup, deprecation, or polish. Good first issue or background work. |

---

## Code Issues

### 1. `prov` command monkey-patches the `Chat` class

**Priority:** High

**File:** `scout_commands/llm/prov`

**Problem:**
The `prov` command redefines existing library methods at runtime by
monkey-patching the `Chat` class and `Step`:

| Method | Status |
|---|---|
| `Chat.trace_chats` | Redefined (overrides library version in `lib/scout/llm/chat/process/meta.rb`) |
| `Chat.token_totals` | Redefined |
| `Chat.job_agent_chat_files` | Redefined |
| `Chat.provenance` | New monkey-patch (not in library) |
| `Chat.provenance_chat_files` | New monkey-patch |
| `Chat.tokens` | New monkey-patch |
| `Step#agent_chats` | New monkey-patch |

This means running `prov` mutates global class behavior for the duration of
the process. The newer `info` command achieves the same provenance inspection
**without any monkey-patching**, using library APIs directly.

**Recommended action:**
Deprecate `prov` in favor of `info`. Consider removing `prov` entirely once
`info` is confirmed to cover all use cases. If `prov` is kept temporarily,
document it clearly as superseded.

**Sources:** [../research/commands-analysis.md](../research/commands-analysis.md), [../research/provenance-analysis.md](../research/provenance-analysis.md).

---

### 2. `prov` command has a hardcoded fallback path

**Priority:** High

**File:** `scout_commands/llm/prov`, near the end of the script

**Problem:**
When no argument is provided, `prov` falls back to a developer-specific path:

```
~/git/workflows/SC26/chats/network_usecase/3.1.themes
```

This path will be missing or broken on any other machine, producing a confusing
error rather than a clear usage message.

**Recommended action:**
Remove the hardcoded fallback. If no argument is provided, print usage
instructions and exit. The `info` command has no such hardcoded path.

**Sources:** [../research/commands-analysis.md](../research/commands-analysis.md).

---

## Documentation Gaps

### D1. ~~Python integration not integrated into the new documentation structure~~

**Priority:** Medium

> **Status: Resolved.** See [user/Python.md](user/Python.md).

**Sources:** [../research/synthesis-report.md](../research/synthesis-report.md).

---

### D2. Model subsystem documentation remains standalone

**Priority:** Low

**Problem:**
`doc/Model.md` documents the `ScoutModel` / `PythonModel` / `TorchModel` /
`HuggingfaceModel` subsystem — wrapping ML models for evaluation and training.
This is tangential to the agent/LLM layer and is intentionally kept separate,
but it is not linked from the new documentation structure.

**Recommended action:**
Keep `Model.md` as a standalone reference. Add a note in [StartHere.md](StartHere.md)
pointing to it. Optionally move it to `doc/developer/Model.md` for structural
consistency. Do not merge into the LLM docs unless explicitly requested.

**Sources:** [../research/synthesis-report.md](../research/synthesis-report.md).

---

### D3. No dedicated getting-started / installation guide

**Priority:** Low

**Problem:**
Installation, Gemfile setup, and first-endpoint configuration are covered in
[user/GettingStarted.md](user/GettingStarted.md), but it may be too terse for
users who want a guided walkthrough.

**Recommended action:**
Consider expanding the Getting Started guide with a more linear tutorial (install →
configure endpoint → first `ask` → first chat file → first agent → first
workflow). Low priority since the current guide covers the essentials.

**Sources:** [../research/synthesis-report.md](../research/synthesis-report.md).

---

## Architectural Suggestions

### A1. Promote ChatAnalyst provenance traversal from SC26 to the core library

**Priority:** Medium

**Problem:**
The `ChatAnalyst` agent (currently in `~/git/workflows/SC26/Agent/ChatAnalyst/`)
implements a `Session` class with BFS-based provenance discovery, token
accounting, and edge-graph construction. The `info` CLI command independently
implements similar logic (`LLMInfoReport`). Having two implementations of the
same traversal algorithm is a maintenance burden.

**Recommended action:**
Promote the shared provenance traversal logic (discovery, token accounting,
graph edges) into the core library (e.g., `lib/scout/llm/chat/provenance/`).
Both `info` and `ChatAnalyst` should consume the same core implementation.
This would also make the traversal available to third-party tools.

**Sources:** [../research/provenance-analysis.md](../research/provenance-analysis.md), [../research/multi-agent-patterns-analysis.md](../research/multi-agent-patterns-analysis.md).

---

### A2. Wire up the custom prompt strategy registry (`REGISTERED_STRATEGIES`)

**Priority:** Medium

**Problem:**
The prompt strategy system has a designed extension point
(`REGISTERED_STRATEGIES`) that is not implemented. This prevents plugins or
users from registering custom named strategies without modifying the source.

**Recommended action:**
Implement the registry: define `REGISTERED_STRATEGIES = {}` and add a
`Chat.register_prompt_strategy(name, &block)` class method. Document the
extension point in [developer/PromptProcessing.md](developer/PromptProcessing.md).

**Sources:** [../research/prompt-strategies-analysis.md](../research/prompt-strategies-analysis.md).

---

### A3. Remove `prov` command; let `info` subsume it entirely

**Priority:** Medium

**Problem:**
The `info` command is strictly more capable than `prov` (import discovery, job
deduplication, flow visualization, Graphviz output, no monkey-patching, no
hardcoded paths). Maintaining both commands is unnecessary.

**Recommended action:**
After confirming that `info` covers all `prov` use cases, deprecate `prov`
with a deprecation warning, then remove it in a future release. Update
[../research/commands-analysis.md](../research/commands-analysis.md) to remove the `prov` entry once removed.

**Sources:** [../research/commands-analysis.md](../research/commands-analysis.md), [../research/provenance-analysis.md](../research/provenance-analysis.md).

---

### A4. Ensure consistent endpoint configuration documentation

**Priority:** Low

**Problem:**
Endpoint configuration (YAML keys, `~/.scout/etc/AI/<name>` format, config
defaults via `~/.scout/etc/config`, environment variables) is documented in
[user/GettingStarted.md](user/GettingStarted.md) and [developer/Backends.md](developer/Backends.md),
but the two should be checked for consistency. The research artifacts noted
that endpoint configuration was a HIGH-priority gap in the original docs.

**Recommended action:**
Review both documents to ensure the endpoint YAML examples, key names, and
configuration precedence are identical. Cross-link them so readers can find
the canonical reference.

**Sources:** [../research/synthesis-report.md](../research/synthesis-report.md).

---

## Anti-patterns to Watch For

These anti-patterns are drawn from the Scout-AI coding philosophy
([../research/coding-philosophy-analysis.md](../research/coding-philosophy-analysis.md)).
They are the most common ways that well-intentioned code fights the library
instead of composing with it.

---

### AP1. Don't create wrapper classes for Chat

**❌ Non-idiomatic:**
```ruby
class MyConversation
  def initialize
    @messages = []
  end
  def add_user(text)
    @messages << { role: 'user', content: text }
  end
end
```

**✅ Idiomatic:**
```ruby
chat = Chat.setup([])
chat.user("Hello")
```

**Why:** `Chat` is an annotation on a plain `Array`. Wrapping it in a custom
class breaks serialization, composition, caching, and every helper that
expects an Array. Use `Chat.setup(any_array)` and the DSL methods.

---

### AP2. Don't hardcode provider logic in `LLM.ask`

**❌ Non-idiomatic:**
```ruby
def self.ask(question, options = {})
  if options[:provider] == 'openai'
    # 50 lines of OpenAI-specific code inline
  end
end
```

**✅ Idiomatic:**
```ruby
def self.ask(question, options = {})
  options = IndiferentHash.setup(options)
  backend = LLM.resolve_backend(options)
  backend.ask(messages, options, &block)
end
```

**Why:** Provider logic belongs in backend modules (composed via
`prepend`/`include`). `LLM.ask` should dispatch, not implement.

---

### AP3. Don't use plain `Hash` for options that come from user input

**❌ Non-idiomatic:**
```ruby
def ask(question, options = {})
  model = options[:model]  # fails if user passed 'model' as a string key
end
```

**✅ Idiomatic:**
```ruby
def ask(question, options = {})
  options = IndiferentHash.setup(options)
  model = options[:model]  # works for both :model and 'model'
end
```

**Why:** Options arrive from YAML files, CLI flags, and Ruby hashes with
inconsistent key types. `IndiferentHash` normalizes access. Always call
`IndiferentHash.setup` on any options hash at the entry point.

---

### AP4. Don't subclass to add behavior

**❌ Non-idiomatic:**
```ruby
class SpecialChat < Array
  def user(content)
    self << { role: 'user', content: content }
  end
end
```

**✅ Idiomatic:**
```ruby
module Chat
  extend Annotation
  def user(content)
    message(:user, content)
  end
end
# Then: Chat.setup(any_array)
```

**Why:** Subclassing creates a rigid hierarchy and breaks the "plain Array"
contract. Annotation and module composition add behavior non-invasively.

---

### AP5. Don't scatter file I/O without `Path` / `Open`

**❌ Non-idiomatic:**
```ruby
File.read("/hardcoded/path/#{name}")
```

**✅ Idiomatic:**
```ruby
path = Scout.var.Agent[name].start_chat
content = Open.read(path.find) if path.exists?
```

**Why:** Scout's `Path` API handles convention-based resolution, annotation,
and existence checks. `Open` provides atomic writes and encoding safety.
Hardcoded paths break portability and testability.

---

### AP6. Don't define methods on `Agent` that duplicate `Chat`

**❌ Non-idiomatic:**
```ruby
class Agent
  def add_user_message(text)
    current_chat << { role: 'user', content: text }
  end
end
```

**✅ Idiomatic:**
```ruby
agent.user(text)  # works automatically via method_missing → current_chat
```

**Why:** `Agent` already delegates unknown methods to `current_chat` via
`method_missing`. Defining wrapper methods on `Agent` creates redundancy and
maintenance overhead. If the method exists on `Chat`, it already works on
`Agent`.
