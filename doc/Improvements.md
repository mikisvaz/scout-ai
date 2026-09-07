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

### 1. ~~`prov` command monkey-patches the `Chat` class~~

**Priority:** High

> **Status: Resolved.** The `info` command has been removed entirely. Its
> traversal logic is shared `Chat` library code (`Chat.traverse_provenance`),
> and its flow-graph rendering lives inline in `scout_commands/llm/prov`;
> there is no separate `Chat::ProvenanceFlow` class. The flow-graph
> capabilities of `info` (imports, job deduplication, DOT, SVG/PNG/PDF) are
> available via `scout-ai llm prov -f`, `--dot`, and `-p`/`--plot`.

**Sources:** [../research/commands-analysis.md](../research/commands-analysis.md), [../research/provenance-analysis.md](../research/provenance-analysis.md).

---

### 2. ~~`prov` command has a hardcoded fallback path~~

**Priority:** High

> **Status: Resolved.** The hardcoded fallback path has been removed. The
> `prov` command now raises `MissingParameterException` if no filename is
> provided, matching the behavior of other CLI commands.

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
implemented similar logic (`LLMInfoReport`). Having two implementations of the
same traversal algorithm is a maintenance burden.

> **Partial progress:** The `info` command has been removed, and `prov`
> renders its flow graph inline in `scout_commands/llm/prov` on top of the
> shared `Chat` traversal primitives; there is no separate
> `Chat::ProvenanceFlow` class. ChatAnalyst should be updated to consume the
> shared `Chat` primitives as well.

**Recommended action:**
Update ChatAnalyst's `Session` class to delegate to the shared `Chat`
provenance primitives (`Chat.traverse_provenance`, `Chat.agent_meta_evidence`,
`Chat.provenance_token_events`) instead of maintaining its own BFS traversal.

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

### A3. ~~Remove `prov` command; let `info` subsume it entirely~~

**Priority:** Medium

> **Status: Resolved (inverted).** The `info` command has been removed instead.
> Its flow-graph rendering lives inline in `scout_commands/llm/prov`, on top of
> the shared `Chat` traversal primitives; there is no separate
> `Chat::ProvenanceFlow` class. The `prov` command provides both the
> text-tree report and the flow/DOT/SVG capabilities that were formerly in
> `info`. `prov` is the sole provenance CLI command.

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

## Refactor Log

Resolved entries from the delegation-machinery refactor (steps tracked in the
Cortex artifacts `refactor/delegation-conversation-pipeline.md` and
`refactor/delegation-execution-reference.md`):

### R1. Shared tool-definition builder and strict schemas

The four hand-built JSON-schema tool definition sites (delegate `hand_off_to_*`,
`ask`, `attach`, workflow tasks) now build through one helper,
`LLM.tool_definition` in `lib/scout/llm/tools/definition.rb` (envelope/strict/
defaults aware). All four sites emit strict schemas
(`additionalProperties: false`); previously only two did. The `defaults`
replay side-channel (`parameters[:defaults]`, consumed by
`LLM.process_calls`) is preserved.

### R2. Conversation-open pipeline

The specialist setup sequence that lived inline in `delegate.rb`
(template resolve, seed, anchor, register, restart) is now
`Agent#open_conversation` in `lib/scout/llm/agent/conversation.rb`, with
`ask_conversation` as the prompt-appending companion and `load_agent`/
`load_chat`/`ask_agent` as thin wrappers. New kwargs: `preamble:`, `anchor:`,
`restart:`, `template:`, `adopt: :current` (folds a template's own progress
into the seed), `job:` (reserved).

### R3. Delegate default hand-off block rebuilt on the pipeline

The default `delegate` block no longer mutates the passed agent. It runs
`ask_conversation` with a sanitized conversation slot (the delegated name),
`inherit: 'none'`, `template:` the passed agent, `adopt: :current`, and
`restart:` from `new_conversation`. Hand-off children persist under
`<save>.society/<Agent>/<slot>/agent.chat` and are swept by the parent save;
the live conversation is reachable with `conversation_agent("<name>/<slot>")`.
Custom blocks and non-Agent objects keep the direct-mutation contract; the
passed Agent is pre-registered as the `@society` template for its name. A
failed hand-off now returns the exception instead of aborting the tool round.

### R4. First-round anchoring for workflow agents

`AgentWorkflow#agent` (chat_task agents) assigns the agent's canonical
`<files_dir>/<name>.chat` save file at creation via
`Agent.canonical_chat_file`, so autosave and restart snapshots apply from the
first round; mid-round socialized children get a real parent anchor. The
`scout-ai agent ask` and `scout-ai llm ask` CLIs route through the same
helper; `LLM.ask`'s `agent_save_file` option stays a caller-supplied explicit
path (deliberately unconverted).

### R5. Duplicate-agent answer attribution fixed

`LLM.process_calls` paired tool outputs with agent answers via
`agents.index(content)` (object identity); when the same Agent object answered
two calls in one round (two `ask` calls to the same conversation, or two
hand-offs to the same specialist), both outputs embedded the first answer.
Pairing is now by tool-call position. Regression test:
`test/scout/llm/tools/test_agent_pairing.rb`.

### R6. Legacy `.files/log` layouts dropped (breaking)

Reader-side support for the legacy `log/` subtree inside the chat files dir
(`<files_dir>/log/agent.chat` and
`<files_dir>/log/chats/<Agent>/<conversation>.chat`, plus the
`log/society/...` variant) is removed: provenance traversal, meta sidecar
sweep, the `prov` CLI, and `Agent.legacy_society_dir_for` no longer see that
tree. Nothing wrote it anymore; old trees are not migrated and are now
invisible to provenance. Canonical layouts unchanged:
`<files_dir>/<name>.chat` and `<save>.society/<Agent>/<conversation>/agent.chat`
(and, since the inbox feature, `<save>.inbox` / `<save>.inbox_removed`).

### R7. Receipt field `agent_meta` renamed to `meta` (breaking)

`function_call_output` receipts carry agent evidence under `meta` (an Array
of already-deserialized field Hashes); the legacy serialized `agent_meta`
key is no longer read, so legacy envelopes contribute no receipt evidence
(and no warnings). Ruby identifiers (`agent_meta.rb`, `Chat.agent_meta_evidence`,
`agent_meta_index`, the `:agent_meta` origin symbol) are unchanged — they
name the machinery, not the persisted field.

### R8. Live workload: one sibling sidecar, all jobs, consumer-side classification

Three design decisions turned the live view from an idea into a small,
verifiable contract:

1. **Sibling-state unification** — every piece of derived agent state is now
   a sibling of the save_file (`<base>.society/`, `<base>.inbox/`,
   `<base>.inbox_removed/`, `<base>.jobs`), derived by stripping only a
   trailing `.chat`. This replaces both the legacy nested
   `<save_file>.files/...` derivations and the historical unanchored
   `sub(/\.chat/)` that mangled paths such as
   `Default.chat.files/agent.chat`. One derivation rule
   (`Chat.inbox_stem` + suffix) backs all four helpers.
2. **Flat transient `.jobs`, not a pointer directory** — an earlier design
   sketched a `<save_file>.files/jobs/` directory of per-dispatch pointer
   JSON files annotated in place. It was deliberately **not** built that way:
   the sidecar is a single flat file, rewritten per tool round as a snapshot
   of the current in-flight set (newline-joined short paths) and removed in
   an `ensure` when `Workflow.produce` returns. Snapshot semantics beat an
   append log here: no orphaned pointer files to GC, no partial writes to
   reconcile, and the absent file is unambiguously "nothing in flight".
3. **List all jobs; classify in the consumer** — `.jobs` deliberately lists
   *every* in-flight workflow job, not only chat_tasks. The writer stays
   dumb (short paths only); `Chat.live_workload` owns the discriminators:
   live chat_task = `step.type.to_s == 'chat'`, reconciliation through
   `.info` status plus `/proc/<pid>` liveness (with the `kill -9` and
   LocalExecutor-retry caveats documented at the consumer, where they can
   actually be acted on).

The consumer is rendered by `scout-ai llm prov --live`; the forensic
behaviour of the command is untouched.

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
