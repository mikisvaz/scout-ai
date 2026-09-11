# Improvements Advisory

This document catalogs known code issues, documentation gaps, architectural
suggestions, and anti-patterns to avoid when contributing to Scout-AI. It is
derived from the research artifacts in [../research/](../research/) and from
the Cortex subsystem studies under `scout-ai/subsys/` (probed 2026-09-10/11),
and is intended as a living reference for maintainers and contributors.

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

### 3. Model restore precedence: saved `options.json` wins over constructor args

**Priority:** Medium

> **Finding: F6** (`scout-ai/subsys/model-ml.md`).

**Problem:**
`ScoutModel#load_options` merges the persisted `options.json` **over** the
options passed to the constructor, and `HuggingfaceModel#initialize` assigns
`checkpoint` after `super` runs, so the saved value overwrites a fresh
constructor argument. Reloading
`HuggingfaceModel.new("CausalLM", "NEW/ckpt", dir)` over a state dir saved
with `checkpoint: "saved/ckpt"` still reports `saved/ckpt`.

The same inversion makes a *fresh* `checkpoint` argument silently ignored
whenever a state directory exists: the intended override-on-restore flow
("pass new values when resuming") cannot be expressed without deleting the
state dir or hand-editing `options.json`.

**Fix direction:** restore should treat saved options as defaults and
explicit constructor arguments as overrides, with the resolved set written
back only on `save`.

---

### 4. Dead and broken dispatch branches in embed + image

**Priority:** Low

> **Finding: F11** (`scout-ai/subsys/embed-image.md`, `backends.md` §1).

**Problem:**
- `LLM.embed`'s `case` accepts `:relay` and `:openwebui` branches that fail
  with `NoMethodError` at runtime (the relay branch expects a real client;
  the openwebui branch hashes a client object that is a plain Hash).
- `LLM.image`'s dispatch has the same shape: `:relay` and `:bedrock`
  branches raise `NoMethodError`, and `:glm` is missing entirely although
  `LLM::GLM.image` works when called directly.
- `LLM.embed` has no `:anthropic`, `:vllm`, `:bedrock`, `:glm` branch
  (Anthropic raises `does not offer embeddings`; Bedrock embeddings must be
  reached through `LLM::Bedrock.embed` directly, since no dispatch branch
  reaches it).
- `Backend#encode_image` maps only `jpg`/`jpeg`/`png`; every other extension
  gets the literal MIME string `image/extension`, producing a malformed data
  URI (`data:image/extension;base64,...`) that providers reject.

**Fix direction:** generate the MIME from a real extension table, and either
implement or delete the unreachable branches rather than carrying both.

---

### 5. Symbol-named KB databases break the tool layer on reload

**Priority:** Low

> **Finding: F15** (`scout-ai/subsys/tools.md` §2.4).

**Problem:**
`KnowledgeBase#register(:name, ...)` + `save` round-trips the registry YAML
with symbol keys. On `KnowledgeBase.load`,
`knowledge_base_tool_definition` calls `get_database(database)` with a
**String**, and the plain `Hash#[]` lookup misses symbol keys, raising
`RuntimeError: Repo <name> not found and not registered`. Registering the
same database with a String name works.

This is a scout-gear/scout-ai boundary trap: the scout-ai tool layer assumes
String-keyed registries.

**Fix direction:** normalize keys on one side (stringify in
`get_database`, or document that `register` must receive String names).

---

### 6. Agent KB root and `Chat.load_workflow` diverge

**Priority:** Low

> **Finding: F16** (`scout-ai/subsys/agent-society.md`, `tools.md` §2.8).

**Problem:**
Two divergent lookup roots for agent resources:

- `Chat.load_workflow` (the loader behind `tool:`/`introduce:` chat roles)
  resolves agent names against `Scout.chats.Agent` only (falling back to
  `Workflow.require_workflow`), while `LLM.load_agent` uses five roots
  (filename path, `Scout.workflows[name]`, `Scout.Agent[name]`,
  `Scout.var.Agent[name]`, `Scout.chats.Agent[name]`, `Scout.chats[name]`),
  so the same name can load in one entry point and not the other.
- `scout agent kb` hard-codes `Scout.var.Agent[agent]` — just one of the
  five — leaving agents living in `Scout.Agent` or `Scout.chats.Agent`
  unreachable from the CLI.

A chat that mixes `tool:` and `kb:` declarations against the same project can
therefore resolve them against different directories depending on the entry
point (workflow job vs CLI chat vs agent society).

**Fix direction:** one resolution helper for "project-relative resource used
by a chat message", used by both paths.

---

### 7. `start_chat.chat` is silently ignored and agent workflows are never reloaded

**Priority:** Medium

> **Finding: F19** (`scout-ai/subsys/agent-society.md`).

**Problem:**
Two related behaviors surprise anyone building agent societies:

1. Naming the seed file `start_chat.chat` (instead of `start_chat`) is
   silently mishandled. When a literal `start_chat` file exists, the `.chat`
   variant is skipped entirely; used alone,
   `find_with_extension` returns the missing literal path, the read fails, and
   the seed comes out **empty** — the agent starts with no system prompt and
   no tools, with nothing reported. A silent empty seed is a misconfiguration
   trap, not a feature.
2. The agent workflow module cache (`@@agent_workflow`) is process-global
   and never invalidated: the first `Workflow.require_workflow` of a session
   wins, and later edits to `Agent/<Name>/workflow.rb` are invisible until
   the process restarts.

**Fix direction:** raise when a directory offers both `start_chat` and
`start_chat.chat`, and raise (or fall back to the directory-assembly seed)
when only the `.chat` variant exists; and key the workflow cache on the
file's mtime/digest.

---

### 8. OpenAI `defaults` stripping is dead code

**Priority:** Low

> **Finding: F21** (`scout-ai/subsys/backends.md` §7.8).

**Problem:**
`openai.rb` deletes `:defaults` at the wrapper level, where `:parameters` is
always `nil` (parameters live under `function:` after wrapping), so the
`defaults` subschema survives in the OpenAI payload. `huggingface.rb` digs
correctly (`definition.dig(:function, :parameters).delete(:defaults)`) and is
the only adapter that actually strips it; ollama/anthropic never do.

**Fix direction:** either strip it consistently for every Chat-Completions
family adapter (and drop the dead line), or stop pretending the field is
provider-private and keep it everywhere.

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

### D4. Documentation vs. verified code behavior (2026-09-11 promotion)

**Priority:** Medium

**Problem:**
The Cortex subsystem studies (`scout-ai/subsys/`, probed 2026-09-10/11) found
eleven places where maintained docs described behavior that does not exist or
has since changed: the nonexistent `scout-ai config set` (F3), `introduce:`
generating tools (F4), backend retry/backoff and streaming (F8/F9), dynamic
backend name resolution (F13), context-strategy bounds (F14), `#` chat
comments (F12), the incomplete chat compilation pipeline listing and key-file
table, the `inherit: 'tools'` scope (F17), Anthropic image blocks (F18), the
MultiAgentWorkflows first snippet (F20), and the `agent.rb` require tree /
`start_chat.chat` seed handling (F19).

**Status: Resolved (uncommitted).** `doc/` has been corrected against the
owning artifacts (`scout-ai/subsys/README.md` is the F1–F22 index); each fix
is described in the corresponding page. The code half lives in issues 3–8
above, tagged with their finding numbers; R9–R13 in the Refactor Log record
the fixes that landed in the same sweep.

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

**Status: Resolved (uncommitted).** [user/RunningInference.md](user/RunningInference.md)
is now the single canonical endpoint reference (hand-written
`~/.scout/etc/AI/<name>.yaml`, recognized keys, `-ck key=value`, provider
table, `Endpoint not found` semantics); GettingStarted and Backends
cross-reference it instead of restating the details.

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

### R9–R13. The 2026-09-11 fix sweep (uncommitted)

R9–R13 below record the 2026-09-11 fix sweep verified by the Cortex subsystem
studies (`scout-ai/subsys/`). All changes sit uncommitted in the working tree
together with their tests; findings F1, F2, F5, F7 and the `ask.rb`
`persist:false` fix are resolved by them.

The findings identified by the same studies but **not** covered by the sweep
(F6, F11, F15, F16, F19, F21) correspond to code issues 3, 4, 5, 6, 7 and 8
above; they remain open.

### R9. `attach` tool can attach PDFs again

Normalization used to overwrite an explicit `file_type: 'pdf'` to `'image'`,
and the dispatcher's bare `case` matched its first branch unconditionally, so
`when 'pdf'` was unreachable and every attach routed to
`Agent#image(path)`. Fixed by matching on the subject form and normalizing
only on `auto`; the `ATACH_TYPES` typo and the schema/code default divergence
(auto vs image) went with it. `lib/scout/llm/agent/attach.rb` +
`test/scout/llm/agent/test_attach.rb` (8 tests, 0 failures). Uncommitted.

### R10. MCP serving works against the `mcp` gem

`Workflow#mcp`'s tool block declared two positional parameters while the
`mcp` gem (1.1.0) invokes `tool.call(**args)` with keywords, and `self`
inside `MCP::Tool.define`'s anonymous class was not the Workflow module, so
every served tool call failed with `Internal error`. The block now takes
`|server_context: nil, **parameters|`, captures the workflow module in a
local, returns a real `MCP::Tool::Response`, and registers tools under the
String name the JSON-RPC lookup expects. `lib/scout/llm/mcp.rb` +
`test/scout/llm/tools/test_mcp.rb` (3 tests, 0 failures). Uncommitted; the
supported `mcp` gem version range is still undecided.

### R11. `LLM.embed` reads endpoint YAML

`embed.rb` used the extensionless `Scout.etc.AI[endpoint].exists?`, unlike
`ask`/image which use `find_with_extension(:yaml)`, so `<endpoint>.yaml`
could not configure embeddings and a missing endpoint failed silently
instead of raising. `lib/scout/llm/embed.rb` +
`test/scout/llm/test_embed.rb` (6 tests, 0 failures). Uncommitted.

### R12. TorchModel trains with a real criterion by default

`@criterion ||= TorchModel.optimizer(...)` assigned an **SGD optimizer** to
the criterion slot (copy-paste), so default training computed the loss on an
optimizer object unless the user set `model.criterion` manually — which the
documented example did, masking the bug. Now builds a proper default
criterion. `lib/scout/model/python/torch.rb`; covered by
`test/scout/model/python/test_torch.rb` (torch-gated). Uncommitted.

### R13. `ask` honors an explicit `persist: false`

`ask.rb` read `persist` as `persist ||= config_lookup`, which is falsy for
`false`: an explicit opt-out was silently discarded and the round persisted
anyway into the shared `Scout.var.cache.ask` store. The config lookup now
runs only when the caller said nothing (`persist.nil?`), so `persist: false`
genuinely bypasses the cache. `lib/scout/llm/ask.rb`; covered by
`test/scout/llm/test_ask.rb`. Uncommitted.

---

## Documentation promotion ledger (2026-09-11)

The research file `research/coding-philosophy-analysis.md` is superseded by
[developer/DesignPrinciples.md](developer/DesignPrinciples.md). What was
promoted, and where it landed:

- **Annotation mechanics** (`Annotation.purge`, singleton-class installation,
  `annotation_types`) — *Chat-as-data (annotate, don't wrap)*.
- **The four executor kinds of the tool registry** (`Proc`, workflow
  name/module, `KnowledgeBase`, plus the bare-Hash degenerate case) and
  "prefer Proc blocks for tools" — *Idiomatic patterns to follow*.
- **Proc/block-based DSLs** (task blocks run only on cache miss,
  `Persist.persist` as compute-once) — *Idiomatic patterns to follow*.
- **`include_workflow` over plain `include`** for mixins carrying class-level
  state such as `AgentWorkflow` — *Module composition over inheritance* and
  the anti-pattern list.
- **Configuration cascade** (`Scout::Config.get` precedence: options →
  env → config file → default) — *IndiferentHash everywhere*.
- **Environment keys are `<TAG>_KEY`, not `<PROVIDER>_API_KEY`** —
  *IndiferentHash everywhere*.
- **Adding a role by extending the Chat annotation module** rather than
  post-processing parsed messages — *Idiomatic patterns to follow* /
  anti-pattern list.
- **Naming conventions** (file paths mirror module nesting; DSL verbs,
  predicate `?` suffixes, `setup` class methods, `options`/`path`/`agent`
  variables) — *File and method naming*.

Everything else in the file was either already covered by DesignPrinciples.md
or was example-flavored duplication of the rules above, so the file can be
deleted without loss. Its remaining references were removed from
[StartHere.md](StartHere.md) (reading-path row and the research/ tree
listing).

---

## Anti-patterns to Watch For

The catalogue has moved: these are now maintained in
[developer/DesignPrinciples.md](developer/DesignPrinciples.md)
("Anti-patterns to avoid"), which is the single normative source. The AP1–AP6
entries that used to live here were deleted in the 2026-09-11 documentation
promotion once their content was fully covered there.
