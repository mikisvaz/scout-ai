# Navigating inference provenance

This document explains how Scout-AI links persisted chats, Workflow jobs, agent logs, inference segments, and tool calls. It is intended for framework contributors and developers building provenance-aware tools.

For the detailed investigation and design rationale, see [../../research/provenance-navigation-design.md](../../research/provenance-navigation-design.md).

## Core model

Scout-AI provenance combines two native Scout data models:

- a **Chat file** is a persisted Array of messages;
- a **Workflow Step** is a persisted task execution with dependencies, status, result, and artifacts.

These are the only structural node kinds. Agents, inference segments, tool calls, and token records are observations inside chats or jobs rather than separate runtime wrapper objects.

The structural relations are:

| Parent | Relation | Child | Meaning |
|---|---|---|---|
| chat | `job` | job | A projected response was produced by a Workflow job. |
| chat | `agent_job` | job | A delegated tool call returned an agent whose receipt entry carries a `job` field naming the producer job. |
| job | `dependency` | job | A normal Scout Workflow dependency. |
| job | `log` | chat | A persisted agent conversation under `.files/*.chat`, `.files/*.society/**/*.chat`, or the legacy `.files/log/**/*.chat`. |
| chat | `log` | chat | A saved agent conversation under the chat's own `.files` sidecar, same three families (root copy excluded). |
| job | `result` | chat | The job result is itself a chat file. |

Relations describe root-outward discovery. A renderer may reverse `job` or `dependency` when drawing natural data flow.

The `log` relation covers exactly three file families under `.files`, nothing else:

- `.files/*.chat` — the new top-level chat files (`agent.chat` by default, `worker.chat`/`critic.chat` for named agents);
- `.files/*.society/**/*.chat` — the new society tree (nested societies keep the plain `society` basename deeper down);
- `.files/log/**/*.chat` — the **legacy** layout, still read for back-compat; nothing writes it anymore and old files are never migrated.

Restart snapshots written by `Agent#start` live under `.files/resets/<timestamp>.chat`, directly under `.files` and **outside** all three families: they are recovery artifacts, not logs, and provenance traversal does not follow them, for jobs and for chats alike. Results of both layouts are de-duplicated and sorted, so a files dir holding both layouts is visited exactly once per chat.

The two `log` parents are deliberately asymmetric:

- a **job** root includes its own top-level `<job>.files/<name>.chat` (`agent.chat` and friends, and the legacy `<job>.files/log/agent.chat`) as a real log node; renderers such as `scout-ai llm prov` hide it from the tree because it duplicates the job node itself;
- a **chat** root excludes its root copy — every top-level `<save_file>.files/<name>.chat` and the legacy `<save_file>.files/log/agent.chat` — because the save mechanism writes a full copy of the root conversation there and including it would duplicate the root as its own child. The exclusion is for the **top level** only: society conversations under `<name>.society/<agent>/<conversation>/agent.chat` (and the legacy `log/society/<agent>/<conversation>/agent.chat`) are also named `agent.chat` and **are** included.

Imported and continued chats are **not** provenance relations. They are a chat-compilation concern resolved during `Chat.parse` and `LLM.chat`. The persisted `.chat` file already contains the full inlined conversation. Provenance traversal therefore never follows `import`, `continue`, or `last` chat references.

## Safe persisted-chat loading

Provenance inspection uses `Chat.load(file)`. It parses the persisted messages without compiling the chat. It therefore does not execute `task`, `job`, `file`, `import`, tool, or other control roles.

Do not use `LLM.chat` to inspect historical evidence: that method compiles control roles for inference.

## Structural traversal

`Chat.traverse_provenance` is the authoritative traversal primitive. It accepts a chat file or Step and yields native `Path` and `Step` values:

    Chat.traverse_provenance(root, root_type: :chat) do |
      kind, object, parent_kind, parent, relation, first_visit
    |
      # kind is :chat or :job
    end

Without a block it returns an Enumerator.

The root has nil parent and relation. Every structural edge is yielded. When a shared dependency or cycle reaches an already visited node, `first_visit` is false and the node is not expanded again. Node identity includes both kind and path, because a chat-producing Step and its result chat can share a filesystem path.

A chat node expands its own `.files` sidecar logs with the `log` relation, exactly like a job does; a job node expands `dependency`, `log`, and `result`. Node identity is `[kind, realpath]`, so a file reachable through both a job log glob and a chat sidecar glob collapses to a single node (first visit wins).

`root_type` decides how the root is loaded. The prov CLI always passes it explicitly, from its own job detection (`.info` sidecar present). Callers that hand over a bare path string should know that traversal infers `:chat` when `Step.type` is empty for that path, which is the case for plain persisted chat files; pass `root_type: :job` whenever the root is known to be a Step, so the node is loaded with `Step.load` and expanded through the job relations instead of the chat ones.

By default, loading and resolution errors are raised. Analytical callers that need partial results can supply `on_error`:

    warnings = []
    records = Chat.traverse_provenance(
      root,
      on_error: ->(error, kind, object, relation, reference) {
        warnings << [error, kind, object, relation, reference]
      }
    ).to_a

This distinguishes absent evidence from evidence that could not be read.

The `follow` option can restrict traversal to selected relations. The supported values are `job`, `dependency`, `log`, `result`, and `agent_job`.

### Collectors

Thin collectors use the same traversal:

- `Chat.provenance_chat_files(root)` returns every discovered chat path;
- `Chat.provenance_jobs(root)` returns every discovered Step;
- `Chat.provenance_edges(root)` returns typed structural edges;
- `Chat.tokens(root)` sums direct inference usage from discovered chats.

`Chat.provenance` remains as a compatibility collector. New code should use the traversal or typed edges because the compatibility Hash does not represent job nodes and relation types fully.

### Direct-neighbour helpers

Direct readers do not recurse:

- `Chat.direct_job_chat_files(job)` returns chat logs owned directly by a job;
- `Chat.direct_chat_sidecar_files(path)` returns chat logs owned directly by a persisted chat's `.files` sidecar (all three families above), excluding the top-level root copies `<save_file>.files/<name>.chat` and the legacy `<save_file>.files/log/agent.chat`;
- `Chat.job_result_chat_file(job)` returns a chat result when present.

Recursion belongs only to `traverse_provenance`.

## Meta messages and inference segments

A meta message has role `meta` and content serialized as key/value pairs. Two important forms are:

1. **Direct inference metadata**, containing fields such as `pt`, `ct`, and `tt`.
2. **Job projection metadata**, containing `job=<path>` and no direct inference cost.

`Chat.project(job, messages)` prepends exactly one producer marker (`job=<path>`, no token fields) and then keeps the response messages in their original order, with the per-inference metas inline, adjacent to the function calls they produced. The projected copy is therefore self-contained for attribution: it carries the same `inference_id` and token fields as the agent log, so a reader does not need to go back to the log to know what a delegated response cost.

Consequences of this contract:

- Duplicated evidence is the norm. The same inference appears in the agent log, in the job result chat, and in any parent conversation that consumed the job chat. `Chat.trace_indices` collapses the copies by `inference_id` (falling back to the digest-based lineage id for legacy metas without `inference_id`), so `Chat.token_totals` counts each inference once. Legacy lineages cannot always be merged across chats; precise deduplication relies on `inference_id`, which every new inference carries.
- The marker is deliberately **separate** from the inference metas: `Chat.direct_entries` excludes metas carrying `job=`, so folding the producer path into an inference meta would silently drop that segment from direct token counting.
- `reas` (reasoning summaries) are stripped from projected copies by default, keeping `inference_id` and the token fields while avoiding the bulk of the projection size cost. Set `chat.project.keep_reas` (env `CHAT_PROJECT_KEEP_REAS`) to keep them.
- Projection is idempotent: re-projecting an already-projected chat (the consumption path in `LLM::Agent#ask`) keeps exactly one `job=` marker and never duplicates inference metas.

### Token fields

| Field | Meaning |
|---|---|
| `pt`, `ct`, `tt` | Prompt, completion, and total tokens for one request. |
| `cct`, `cwt`, `rt` | Cache-hit, cache-write, and reasoning tokens for one request. |
| `*_c` | Running total represented by this chat. It is a checkpoint, not an additive event. |
| `*_s` | Process/thread session snapshot. It is not attributable by itself. |
| `inference_id` | Scout-generated identity for one actual backend request. |
| `provider_response_id` | Provider response identity when available. |
| `job` | Producer Step for a projected response segment. |
| `orphan` | Request produced no persisted message (reasoning-only round; its segment covers zero messages). Real cost, marked explicitly at meta-creation time by the backend. |
| `reas` | Optional reasoning summary; stripped from projected copies unless `chat.project.keep_reas` is set. |

Every new direct inference receives a locally generated `inference_id`. This distinguishes genuinely repeated requests even when their conversation, response, and token counts are identical. Copied chat history retains the original ID and is counted once.

Legacy chats without an inference ID fall back to conversational lineage deduplication. Reports that require precision should expose whether an entry used `inference_id` or `legacy_lineage` deduplication.

Never sum `*_c` or `*_s` snapshots. Sum direct fields from deduplicated direct inference segments.

## Message identity and location

Scout-AI distinguishes two concepts:

- a **lineage ID** identifies equivalent conversational content;
- a **message address** identifies one persisted location as `[chat_path, index]`.

`chat.message_index(source: path)` includes both. Meta messages do not advance conversational lineage because providers do not receive them.

Use lineage IDs for detecting copied history. Use addresses to retrieve exact persisted messages.

## Response tracing

`Chat.trace_chats(chats)` groups messages into response segments. A meta message opens a segment; another meta or a user/system turn closes it.

`Chat.trace_chat_sources(path_to_chat)` is the source-aware form. Its records include:

- `lineage_id`;
- `inference_id` when present;
- `deduplication`, either `inference_id` or `legacy_lineage`;
- `meta_address`;
- covered message lineage IDs;
- covered `message_addresses`;
- parsed metadata;
- orphan status.

An orphan segment covers zero messages: the request produced no persisted message (typically a reasoning-only round whose output was consumed internally before the meta was written). Such metas are marked `orphan=true` at creation time by the backend, so the persisted meta is self-explanatory; `trace_indices` derives the same fact independently. The marker is inert for accounting — orphan requests still carry real token cost.

`Chat.direct_entries(chats)` selects direct inference segments. `Chat.token_totals(chats)` sums all canonical direct token fields.

## Tool-call analysis

`Chat.tool_calls(chat, source: path)` pairs `function_call` and `mcp_call` messages with `function_call_output` messages by call ID. It returns plain Hash records containing call/output addresses, parsed records, arguments, and output content.

Pairing is structural. Success interpretation is separate:

    call = Chat.tool_calls(chat, source: path).first
    status = Chat.tool_call_status(call)

The common status policy treats:

- missing output as unknown;
- JSON containing `exception` as failure;
- JSON containing non-zero `exit_status` as failure;
- any other persisted output as success.

Provider call IDs are scoped to a chat; do not assume they are globally unique across files.

Calls named `ask` or `hand_off_to_*` provide semantic evidence of delegation. Workflow-backed calls have structural job/log links. A socialized call's association with a society log may still be inferred from naming conventions, so reports should label that association as inferred rather than authoritative.

## Delegated agent receipts (`meta` / legacy `agent_meta`)

When a tool returns an `LLM::Agent`, `LLM.process_calls` embeds the child agent's inference evidence in the parent `function_call_output` JSON envelope. The envelope is generic: it is produced for any tool returning an agent, not only for `ask`.

Two receipt formats exist, and the reader accepts both:

- **Current format — the `meta` key.** The writer deserializes the child agent's `meta` messages (`LLM.meta_receipt_from_messages`) and emits an Array of plain field Hashes, each already parsed:

  ```
  function_call_output: {"name":"ask","content":"child answer","id":"call_1","meta":[{"pt":100,"ct":50,"tt":150,"inference_id":"aaa"},{"job":"Cortex/continue/Default_x.chat"}]}
  ```

  An entry carries either the child's direct inference metadata (`pt`, `ct`, `tt`, ..., `inference_id`) or a producer reference: a `job` key holding the child job path, e.g. `{"job":"Cortex/continue/Default_x.chat"}`. Job references may be job-typed or chat-typed paths; both resolve to a Step. Entries that would carry no fields are dropped by the writer.

  The same `function_call_output` may also carry auxiliary fields next to the receipt: `step` (the producing step of the same execution), `start_timestamp`, and `timestamp`. They are bookkeeping only: the sole receipt-driven provenance edge source is the `job` field of a receipt entry (`meta[].job`); the `step` field is never followed as a parent-child edge.

- **Legacy format — the `agent_meta` key.** Older data stores serialized meta messages:

  ```
  "agent_meta":[{"role":"meta","content":"pt=100 ct=50 tt=150 inference_id=aaa"}, ...]
  ```

  This shape is **no longer written**, but it is still read: each `content` String is parsed with `Chat.parse_meta`, so historical chats remain fully addressable.

When both keys are present in one envelope the current `meta` key wins and the legacy one is ignored (the current writer emits exactly one of the two).

See [../../research/agent-meta-provenance-integration-plan.md](../../research/agent-meta-provenance-integration-plan.md) for the design record of the original (serialized) shape; the `meta` key replaced it in commit `efd8ebbc`.

Receipts are embedded provenance evidence, **not** parent-chat messages, and must never be injected into the parent chat. `Chat#meta`, `chat.role_messages(:meta)`, and `Chat.token_totals([chat])` keep describing the local chat only. A receipt is read as an observation attached to the paired tool output.

### Receipt extraction helpers

- `Chat.agent_meta_evidence(chat, source: nil, warnings: nil)` returns one Hash per valid receipt entry across the paired tool outputs of a chat. Pairing is delegated to `Chat.tool_calls`; raw text is never scanned. Records carry `origin: :agent_meta` (for **both** formats), the `meta` fields (already deserialized for current-format entries, parsed from the legacy content String for legacy entries), `source`, `output_address`, `evidence_address`, `call_id`, `tool_name`, `agent_meta_index`, and `raw_message`. The evidence address suffix mirrors the persisted key: `[:meta, index]` for current-format entries and `[:agent_meta, index]` for legacy ones, so an address always points at the JSON element that is actually on disk. `raw_message` is nil for current-format entries (they are born deserialized) and `{role:, content:}` for legacy entries.
- `Chat.meta_evidence(chat, source: nil, warnings: nil)` returns the local `meta` messages (`origin: :chat_meta`, with `meta_address`) followed by the receipt records.
- `Chat.agent_meta_job_references(chat, source: nil, warnings: nil)` filters receipt records whose parsed meta has a `job` key and adds the reference at the top level as `job:`.

Malformed receipts (the receipt key not holding an Array; an entry that is not a Hash, has the wrong role, has non-String content, parses to nothing, or — current format only — is a field Hash with no fields) are skipped and never reinterpreted as provenance. When the caller supplies a `warnings` Array, each malformed item appends one warning Hash with the reason, the output address, `call_id`, `tool_name`, and the raw entry. Warning reasons are:

| Reason | Applies to | Meaning |
|---|---|---|
| `:not_an_array` | both | The receipt value is not an Array. |
| `:not_a_hash` | both | An entry is not a Hash. |
| `:invalid_role` | legacy | An entry's role is not `meta`. |
| `:invalid_content` | legacy | An entry's content is not a String. |
| `:unparseable_meta` | legacy | The content String parses to no fields. |
| `:empty_meta` | current | An already-deserialized field Hash carries no fields. |

Malformed warnings mirror the persisted key in their `evidence_address`, and always carry `origin: :agent_meta` regardless of format.

### The `agent_job` relation

`Chat::PROVENANCE_RELATIONS` includes `agent_job`: chat to delegated producer job, resolved from the `job` field of receipt entries (`meta[].job`; the auxiliary `step` field on the tool output is not an edge source). The child is a normal Step and follows `dependency`, `log`, and `result` as usual. A job reference whose Step path and `.info` sidecar both do not exist is not followed and is reported instead.

Diagnostics go through `Chat.provenance_error` with relation `:agent_job`; the error itself is a plain `ScoutException` whose message is built by `Chat.agent_meta_error_message`, and every structured fact (enclosing chat path, tool output address, receipt address, call id, tool name, malformed entry, reference, reason) travels in the `on_error` reference Hash. In strict mode (no `on_error`) a malformed receipt raises; with `on_error` each problem is reported once per receipt, while the rest of the chat's provenance still expands. Only output JSON that parses to a Hash carrying an explicit receipt key (current `meta`, legacy `agent_meta`) is ever inspected: unparseable tool outputs are never scanned for the substring `agent_meta`.

### Provenance-aware token accounting

`Chat.provenance_token_events(root, warnings: nil, **options)` returns one Hash per deduplicated direct inference event across discovered chats and their receipts, with `inference_id`, `identity`, `deduplication`, canonical `meta`, `tokens`, `evidence`, and `conflict`:

- identity priority: `inference_id`, then `provider_response_id`, then conversational lineage for chat-side legacy metas, then the receipt evidence address itself (`:receipt_unresolved`, never merged, so legacy receipt data may overcount);
- canonical evidence: `:chat_meta` beats `:agent_meta`; within one origin the first in discovery order wins. Tokens come from the canonical evidence only, never from a sum of duplicates;
- conflicting evidence that shares an identity keeps every evidence record with its own meta, counts only the canonical one, sets `conflict: true`, and appends an `:identity_conflict` warning when a `warnings` Array was supplied. `strict: true` raises instead.

Deduplication happens exactly once, inside this collector: chat-side records are collected with `deduplicate: false`, so an inference persisted in several saved chats/logs plus one receipt yields a single event whose `evidence` array lists every address.

A missing `provider_response_id` in one evidence record and a present one in another is *incomplete evidence*, not a conflict: such events set `incomplete_evidence: true`, are counted normally, and never trigger conflict warnings. Only two different non-empty `provider_response_id` values (or disagreement on `pt`/`ct`/`tt`) conflict. A conflicting event still contributes its canonical tokens, so any total containing conflicts is best-effort, not authoritative; `Chat.provenance_token_totals(root, conflicts: hash)` reports that flag explicitly.

`Chat.provenance_token_totals(root, scope:)` sums event tokens by scope. Scopes are **evidence coverage**, not a partition of cost: an event stored both in a saved child log and in a receipt belongs to `:chat_evidence` and to `:receipt_evidence`, so those two must never be summed together. `:deduplicated_total` (default) counts every event once and `:receipt_only` is the disjoint delegated contribution with no saved-chat evidence. `Chat.tokens(root)` delegates to the collector, so provenance aggregates include receipt-only child usage without double counting when the same child inference is also persisted in a job.

## Workflow failures and partial provenance

Traversal visits jobs regardless of `done?`. Error and aborted Steps may still have dependencies, Step info, results, or partial agent logs. Status and exception details remain authoritative in Step info.

Backend request failures currently preserve emergency chat/options/meta snapshots through the backend exception mechanism. If these snapshots are later moved under an owning Step's files directory or linked from Step info, normal provenance traversal can expose them without introducing a separate Session abstraction.

## `scout-ai llm prov`

The `prov` command consumes `Chat.traverse_provenance` once and then separates:

1. discovery of nodes and typed edges;
2. direct token analysis;
3. tree, compact flow, DOT, and plot rendering.

Usage:

    scout-ai llm prov path/to/chat
    scout-ai llm prov path/to/chat --flow
    scout-ai llm prov path/to/chat --dot flow.dot
    scout-ai llm prov path/to/chat --plot flow.svg
    scout-ai llm prov path/to/chat --evidence

Root classification uses the `.info` sidecar only: a path is a job iff `<path>.info` exists, and is loaded with `Step.load`. The presence of a `.files` sidecar is **not** evidence of a job, because saved agent chats also carry one; a chat root is simply `Path.setup`'d.

The default tree is a spanning-tree presentation of a DAG. Repeated nodes are displayed as seen references rather than recursively expanded. Compact and graphical flows choose natural data-flow arrow direction during rendering without changing traversal semantics.

Job token values describe direct chat logs owned by that job. They do not silently include the complete dependency subtree.

Delegated calls are reported from receipts (current `meta` key or legacy `agent_meta` key; both formats are accepted transparently). The tree labels a job reached through a receipt as `delegated-job`, adds one `delegated receipt: N events, total=<tt>, <tools>` annotation line under chats that carry receipts, and `--component` prints `scope local:` / `scope receipt:` / `scope aggregate:` lines when receipt evidence exists. Flow and DOT render receipt edges as `delegated_result`.

`--evidence` prints the deduplicated direct inference events behind the totals: identity, raw token values, evidence locations (parent output address plus call id), and status (`counted once`, `receipt-only`, `legacy unresolved`, `conflict`), followed by receipt-only, legacy-unresolved, identity-conflict, and job-projection sections. Receipt addresses print as `base:idx[meta,i]` for current-format entries and `base:idx[agent_meta,i]` for legacy ones, mirroring the persisted key. Receipt problems and identity conflicts are listed in the trailing warnings block.

## ChatAnalyst

ChatAnalyst uses the same core traversal. It does not define Session, ChatGraph, ProvenanceContext, or node wrapper classes. Each Workflow task collects temporary report state in ordinary Hashes and Arrays and applies shared Chat operations for message indexing, tracing, tool-call pairing, and token accounting.

This keeps responsibilities separate:

- Scout-AI owns persisted structural navigation and Chat analysis primitives;
- ChatAnalyst owns agent-oriented JSON reports;
- `prov` owns human and Graphviz rendering;
- Workflow Step info owns execution lifecycle and failure provenance.

ChatAnalyst is expected to consume the receipt primitives above — `Chat.agent_meta_evidence`, `Chat.meta_evidence`, `Chat.agent_meta_job_references`, and the `:agent_job` relation — instead of re-deriving delegated inference evidence. That update is pending and out of this change.

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/chat/provenance.rb` | Structural traversal, direct neighbours, collectors, and token events. |
| `lib/scout/llm/chat/agent_meta.rb` | Delegated-agent receipt evidence extraction. |
| `lib/scout/llm/chat/process/meta.rb` | Meta parsing, lineage, source-aware tracing, projections, and token totals. |
| `lib/scout/llm/chat/tool_calls.rb` | Tool-call pairing and common status interpretation. |
| `lib/scout/llm/backends/default.rb` | Direct token metadata and inference identities. |
| `lib/scout/llm/agent/workflow.rb` | Agent log persistence and chat-task projection. |
| `scout_commands/llm/prov` | Tree, flow, DOT, and plot rendering. |

## Cross-references

- [ChatLifecycle.md](ChatLifecycle.md) — Chat data and compilation.
- [DelegationInternals.md](DelegationInternals.md) — Socialized and delegated agents.
- [../../research/provenance-navigation-design.md](../../research/provenance-navigation-design.md) — Investigation, alternatives, and migration rationale.
