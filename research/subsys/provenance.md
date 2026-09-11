# 02 - Provenance, receipts and token accounting

> Investigation, not normative documentation. Verified behavior of the
> provenance traversal, agent_meta receipts, token-event deduplication, the
> live report and the `prov` CLI. Normative reference:
> `doc/developer/Provenance.md`.

## Scope

`lib/scout/llm/chat/provenance.rb` (1841 lines) and its immediate
collaborators: `chat/agent_meta.rb`, `chat/process/meta.rb` (tracing and
accounting helpers), `chat/tool_calls.rb` (receipt pairing),
`lib/scout/llm/tools/call.rb` (jobs sidecar + receipt writer),
`lib/scout/llm/agent/save.rb` (society layout) and `scout_commands/llm/prov`
(the renderer).

## Verified behavior

### Edge model

`PROVENANCE_RELATIONS = %i[job dependency log result agent_job]`
(provenance.rb:5).

| relation | parent -> child | producer | consumer |
|---|---|---|---|
| `job` | chat -> job | `meta: job=<short path>` written by `Agent#ask` at dispatch (agent.rb:85-88, before `job.produce`) | traversal `chat.jobs` |
| `agent_job` | chat -> job | `meta[].job` field of a receipt inside `function_call_output` JSON (writer `LLM.meta_receipt_from_messages`, tools/call.rb:37-50, 222) | `agent_meta_job_references` -> traversal queue |
| `dependency` | job -> job | Scout-gear Step `.info` `dependencies`, recorded at `reset_info(status: :setup)` after `run_dependencies` | traversal (provenance.rb:372-375) |
| `log` | job -> chat and chat -> chat | save machinery writing `<base>.files/*.chat` / `<base>.files/<name>.society/**/*.chat` | `direct_job_chat_files` / `direct_chat_sidecar_files` |
| `result` | job -> chat | `chat_task` writing the job result chat (`job.type == 'chat'`) | `job_result_chat_file` |

`delegated_result` is **not** a traversal relation - it is a rendering-only
reversal of `:agent_job` in the prov renderer. The `step` auxiliary field of
the tool-output envelope is never an edge source.

Log families: `DIRECT_LOG_CHAT_GLOBS = ['*.chat', '*.society/**/*.chat']`
(provenance.rb:20) - exactly two families. The legacy `.files/log/**` layout
is no longer read; `resets/` snapshots fall outside the globs and are
invisible to traversal. Root-copy asymmetry: the chat root excludes top-level
`<save>.files/*.chat`, while the job root includes its own top-level
`agent.chat`.

### Entry points and shapes

- `traverse_provenance(root, root_type:, follow:, on_error:, &block)` - BFS
  queue yielding `kind, object, parent_kind, parent, relation, first_visit`
  and, optionally, a 7th `detail` value. The 7-argument form is only yielded
  when the block can receive it (`block.arity == -1 || >= 7`,
  provenance.rb:279-283); it carries the full receipt record on `:agent_job`
  edges. Without a block the method returns an `Enumerator`. Node identity is
  `[kind, realpath]`, so a chat-typed job and its result chat sharing one path
  collapse to one node per kind.
- `root_type` inference: `Step === root ? :job : :chat`; a bare path string
  whose `Step.type` is `'chat'` still infers `:chat` (it carries a `.info`
  declaring type chat); `root_type: :job` forces `Step.load` + job relations.
  Unknown `follow` symbols raise `ParameterException`; `follow: []` yields
  zero edges.
- `provenance_edges(root, **options)` returns flat edges
  `{from:, to:, relation:, detail:}`; `:agent_job` edges carry the receipt
  record under `detail:` (keys `agent_meta_index, call_id, evidence_address,
  evidence, job, output_address, raw_entry, reference, tool_name`).
- `provenance_chat_files` / `provenance_jobs` are first-visit collectors;
  `provenance(chat_file, prov = {})` is the legacy chat->chat Hash shim.
- `on_error` callback arity is exactly **5**
  (`error, kind, object, relation, reference`). Only the block has the
  optional 7th `detail` argument.

### Job reference resolution

- `load_job_reference` -> `Step.load(ref)` with `job_reference_fallback_bases`
  tried when the literal path is absent (a candidate is a file or has an
  `.info`). `resolve_job_reference` returns `[step, nil]` or `[nil, step]`;
  unresolved `:agent_job` references are reported, never silently dropped.
- Live resolution (`load_live_job_reference`) tries `Workflow.directory`
  **first** (because `Step.load` relocates a bare short path onto an empty
  mirror of the jobs tree), then the absolute form, then `load_job_reference`.
  Corollary: an observer must run in the directory that owns `var/jobs` or set
  `Workflow.directory`; with the default PWD-relative tree, `--live` from
  another cwd prints nothing and exits 0.

### Run-scoped parse-once cache

`Thread.current[:scout_ai_provenance_run_cache]` is opened by every public
entry point (`traverse_provenance`, `provenance_token_events`,
`provenance_token_totals`/`tokens`, and the collectors). One top-level call
parses each chat file once even when traversal and token collection both load
it; nested public calls reuse the outer cache.

### Token events and totals

`provenance_token_events(root, warnings:, strict:, **traversal_options)`:

- Sources: chat-side trace records with no `:job` and at least one
  TOKEN_KEYS field -> `origin: :chat_meta`; receipt-side `agent_meta_evidence`
  records with no `:job` and at least one field -> `origin: :agent_meta`. A
  `job=` projection meta is never a token event.
- Identity priority: `inference_id` -> `provider_response_id` ->
  `[:lineage, lineage_id]` (chat-side legacy) -> `[:receipt, evidence_address]`
  (marked `receipt_unresolved`, never merged; documented possible overcount
  for legacy receipt data).
- Canonical evidence: `origin_rank = {chat_meta: 0, agent_meta: 1}`, then
  discovery order; tokens come only from the canonical record; all duplicate
  evidence records are retained in `event[:evidence]`.
- Conflicts: disagreement on any TOKEN_KEYS value (as integers, missing = 0)
  or on two different non-empty `provider_response_id`s -> `conflict: true`
  plus one warning `{reason: :identity_conflict, ...}` per conflicting event;
  `strict: true` raises `ScoutException` instead. Missing-vs-present
  `provider_response_id` and missing optional `cct/cwt/rt` are
  `incomplete_evidence: true` (counted, never warned).
- Warning routing: with a `warnings` Array, traversal-stage agent_meta
  problems (malformed receipts, unresolved references) are routed into it with
  a `message:` key while the traversal continues; unrelated errors still
  raise. Without the Array, agent_meta problems raise exactly as in strict
  traversal. The receipt-problem buffer is de-duplicated against
  traversal-stage warnings on `[reason, output_address, agent_meta_index]`.
- `provenance_token_totals(root, scope:, warnings:, conflicts:, **opts)`
  scopes: `:deduplicated_total` (default), `:chat_evidence`,
  `:receipt_evidence`, `:receipt_only` (receipt evidence with no chat
  evidence - the disjoint delegated contribution); unknown scope raises
  `ParameterException`. The scopes are coverage, **not** a partition:
  `chat_evidence` and `receipt_evidence` overlap and must not be summed.
  `conflicts:` receives `events`, `incomplete_evidence_events`,
  `authoritative` (true iff no conflicts).
- `Chat.tokens(root)` aliases `provenance_token_totals`.
- Checkpoint fields `*_c`/`*_s` are never read or summed here (a chat with
  `pt=10` + `pt_c=999` totals 10).
- `USAGE_FIELD_MAP`/`normalize_usage` (process/meta.rb:23-71) map
  OpenAI/GLM/Anthropic spellings to `pt/ct/tt/cct/cwt/rt`; only *wrapped*
  `usage` hashes are normalized - a bare top-level token hash passes through.

### Receipts (agent_meta)

- Writer: `LLM.meta_receipt_from_messages` deserializes the child's `meta`
  messages into plain field Hashes; entries parsing to no fields are dropped.
- Reader: one record per valid entry, `origin: :agent_meta`,
  `evidence_address` suffix `[:meta, index]`, `raw_message` always nil.
- Only the current `meta` key is read; the legacy serialized `agent_meta` key
  contributes no evidence and no warnings.
- Malformed taxonomy: `:not_an_array`, `:not_a_hash`, `:empty_meta` (plus
  role/content-shape rejections) - skipped, never reinterpreted; only output
  JSON parsing to a Hash with an explicit receipt key is inspected.
- Envelope auxiliary fields (`step`, `start_timestamp`, `timestamp`) are
  bookkeeping; the sole receipt-driven edge source is `meta[].job`.

### Projection and tracing

`Chat.project(job, messages)` prepends exactly one `meta: job=<short path>`
marker, keeps response messages in order with per-inference metas inline, is
idempotent on re-projection, and strips `reas` unless
`chat.project.keep_reas`. Trace records carry `lineage_id`, `inference_id`,
`deduplication` (`:inference_id` / `:legacy_lineage`), `meta_address`,
covered lineage ids and message addresses, parsed meta and `orphan`; job
projection metas appear as `legacy_lineage` records with nil `inference_id`
and are excluded from token events by the `meta[:job]` filter. `orphan` is set
at meta-creation time by the backend for rounds whose output covers zero
messages; it is inert for accounting.

### Live report

`Chat.live_report(save_file, captured: [])` folds three passes and returns
`{entries:, scanned: {sidecar:, agent_view:, society:}}`:

- **Sidecar** - `live_workload(reference)` derives `<base>.jobs` via
  `Chat.jobs_file` (trailing `.chat` stripped); an absent sidecar is `[]`.
  Entries are newline-separated job short paths. Classification
  `classify_live_job_info`: terminal status (`done|error|aborted|cleaned`) ->
  `:finished`; non-terminal with a live pid (`/proc/<pid>` exists, not
  zombie) -> `:running`; non-terminal with dead/absent pid -> `:crashed`;
  unreadable/non-Hash -> `:unknown`/nil. The chat-task discriminator is
  `step.type.to_s == 'chat'`. `expand_live_jobs` walks *direct* dependencies
  (not `rec_dependencies`), cycle-guarded, `LIVE_DEPENDENCY_DEPTH_LIMIT = 5`,
  collecting only `:running` jobs; `via:` records the sidecar entry that
  reached the job.
- **Waiting-wrapper fallback** - `live_dependency_candidates`: when a step
  has no recorded dependencies and no terminal status, glob
  `<workflow namespace>/*/*.info` siblings for running jobs (`.info` files,
  because a chat_task path is a file). The wrapper is then reported once as
  workload context with `state: :waiting`.
- **Agent view** - `agent_log_activity(save_file)` classifies from trailing
  messages, skipping `AGENT_CONTROL_ROLES`; verdicts `dispatched`,
  `tool_round_in_flight` (function_call without output),
  `next_round_pending` (function_call_output), `idle`, `no_messages`,
  `unreadable`, `no_inference`. `dangling_agent_job_metas` reads the save
  file's `job=` metas with the same `Chat#jobs` reader the forensic traversal
  uses (not receipt-borne references) and follows each to a running job;
  terminal or already-captured ids are not reported.
- **Society** - `society_dir_of` delegates to the `LLM::Agent` rules
  (nested chat -> plain `society` sibling; root chat -> `<name>.society`
  sibling). `society_agent_chats` scans for `agent.chat` files only, bounded
  to `SOCIETY_SCAN_DEPTH_LIMIT = 128` levels, no symlinks, sorted.
  `society_live` reports each child whole: `:dangling_job` when
  workflow-backed, `:agent_activity` otherwise.
- **Folding** - entries keyed by job id (sidecar short path, the same form a
  `job=` meta stores) or agent-log path; captured ids (normalized by
  `live_captured_ids` from the forensic report's `:job`/`:agent_job` job
  nodes) are dropped in every pass; two passes naming the same job deep-merge
  with earlier scalar facts winning.
- **CLI `--live`** - the live section is appended after the normal report and
  omitted entirely (header included) when there are no entries. Kinds are
  relabelled `chat_task`/`dangling_job`/`agent_active`/`workflow`, inference
  first. Live entries carry no token figures.

### prov CLI

- Root classification uses the `.info` sidecar only:
  `Open.exists?(filename + '.info')` -> `Step.load` + `root_type: :job`, else
  `Path.setup`.
- One traversal feeds nodes/edges/tokens/renderers; `captured_references`
  for the live section are taken from that same traversal's
  `:job`/`:agent_job` records, in both the Step path form and the raw string
  form.
- Footer `root deduplicated_total=<tt> (<N> events) prompt=... cache=<abs>@<rate>%
  fresh=... [cache_write=...] cont=... reason=...`; `--component` relabels
  per-node numbers `direct=`; job nodes add `delta=`. Per-job deltas sum to
  the root total on continuation chains but **not** on general DAGs - the
  evidence closures of two parents overlap.
- `--evidence` prints per-event identity, raw values, evidence locations
  (receipt addresses as `base:idx[meta,i]`) and statuses (`counted once`,
  `receipt-only`, `legacy unresolved`, `conflict`), followed by
  receipt-only / legacy-unresolved / identity-conflict / job-projection
  sections and a trailing warnings block.

## Sharp edges and known issues

- **"Three log families" is two globs** (F22). `doc/developer/Provenance.md`
  says the `log` relation covers three families and lists two; the third was
  the legacy `.files/log/**` layout, no longer read.
- **The optional 7th `detail` yield is undocumented but load-bearing** (F22):
  receipt-aware renderers depend on it; `provenance_edges` exposes it as
  `detail:`.
- **`resets/` snapshots are invisible to traversal** (F22): outside the
  globs, by construction.
- **Checkout-vs-gem trap** (F22, operational): the installed gem (2.0.0 at
  study time; checkout 2.1.0) may lack checkout-only methods such as
  `Chat.live_report`; running the checkout's `prov` without
  `-I<checkout>/lib` raises NoMethodError. Pin the load path or `RUBYOPT`
  when reproducing.
- **`--live` needs the owning cwd**: without `Workflow.directory` pointing at
  the tree that owns `var/jobs`, sidecar entries resolve to nothing and the
  command exits 0 silently.
- **Snapshot races are expected** (sidecar read vs `.info` read); `kill -9`
  leaves `.info` non-terminal and only pid liveness rescues the
  classification.
- **`Chat#jobs` returns raw reference strings verbatim**, including
  `.chat`-suffixed chat-typed paths and non-existent paths; consumers must
  resolve them.
- Prior artifacts describing write-before-produce / jobs-sidecar removal /
  type-3 immediate `job=` metas as *recommendations* are history: all are
  implemented (`Open.write(jobs_file, ...)` before `Workflow.produce`,
  `Open.rm jobs_file` in `ensure`, and the meta written at dispatch).

## Open questions

- Exec-dispatched children (`exec_export`) and fork-vs-exec `.info` latency
  are marked NEEDS-LIVE-PROBE; measuring them requires a real running
  workflow.
- Live cost attribution is deferred by design until a backend reports usage
  in flight.
- Whether ChatAnalyst consumes the receipt primitives (documented as pending
  in Provenance.md) is outside this subsystem.
- Emergency backend snapshots (failed requests) are not under any Step's
  files dir; if that ever changes, traversal picks them up automatically.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch); no fix in this sweep touches this subsystem.

- Code: `lib/scout/llm/chat/provenance.rb` (1841 lines; constants at :5 and
  :20, `LIVE_DEPENDENCY_DEPTH_LIMIT` :1109, `SOCIETY_SCAN_DEPTH_LIMIT`
  :1683), `chat/agent_meta.rb`, `chat/tool_calls.rb`,
  `chat/process/meta.rb`, `lib/scout/llm/tools/call.rb:124-193`
  (jobs sidecar, agent fan-out), `lib/scout/llm/agent/save.rb`,
  `lib/scout/llm/agent/workflow.rb` (`chat_task`),
  `lib/scout/llm/backends/default.rb:415-448,540-602`,
  `scout_commands/llm/prov`.
- Docs: `doc/developer/Provenance.md`, `doc/developer/Architecture.md`,
  `doc/developer/ChatLifecycle.md` (meta grammar, `*_c`/`*_s` checkpoints).
- Probes: 26 offline scripts on synthetic fixtures under `Dir.mktmpdir`
  (`tmp/subsys-provenance/probe1_traversal.rb` ...
  `probe26_malformed.rb`), each printing a JSON verdict. Representative
  findings: traversal arity and root-type inference; `detail` key set of
  `:agent_job` edges; run-cache parse counts; scope overlap demonstrated
  numerically (`chat_evidence` + `receipt_evidence` both 165 for an event
  with chat-side canonical evidence, `receipt_only` 0); `classify_live_job_info`
  verdict table; `agent_log_activity` verdict table; receipt-envelope
  variants (`meta` absent / not-an-array / empty entry / legacy
  `agent_meta` key -> 0 events, 0 warnings); wrapped-vs-bare usage hash
  normalization.
