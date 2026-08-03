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
| job | `dependency` | job | A normal Scout Workflow dependency. |
| job | `log` | chat | A persisted agent conversation under `.files/log/**/*.chat`. |
| job | `result` | chat | The job result is itself a chat file. |

Relations describe root-outward discovery. A renderer may reverse `job` or `dependency` when drawing natural data flow.

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

By default, loading and resolution errors are raised. Analytical callers that need partial results can supply `on_error`:

    warnings = []
    records = Chat.traverse_provenance(
      root,
      on_error: ->(error, kind, object, relation, reference) {
        warnings << [error, kind, object, relation, reference]
      }
    ).to_a

This distinguishes absent evidence from evidence that could not be read.

The `follow` option can restrict traversal to selected relations. The supported values are `job`, `dependency`, `log`, and `result`.

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
- `Chat.job_result_chat_file(job)` returns a chat result when present.

Recursion belongs only to `traverse_provenance`.

## Meta messages and inference segments

A meta message has role `meta` and content serialized as key/value pairs. Two important forms are:

1. **Direct inference metadata**, containing fields such as `pt`, `ct`, and `tt`.
2. **Job projection metadata**, containing `job=<path>` and no direct inference cost.

`Chat.project(job, messages)` removes direct inference metadata from projected output and adds one producer marker. The original agent log retains actual inference usage.

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
| `reas` | Optional reasoning summary. |

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

The default tree is a spanning-tree presentation of a DAG. Repeated nodes are displayed as seen references rather than recursively expanded. Compact and graphical flows choose natural data-flow arrow direction during rendering without changing traversal semantics.

Job token values describe direct chat logs owned by that job. They do not silently include the complete dependency subtree.

## ChatAnalyst

ChatAnalyst uses the same core traversal. It does not define Session, ChatGraph, ProvenanceContext, or node wrapper classes. Each Workflow task collects temporary report state in ordinary Hashes and Arrays and applies shared Chat operations for message indexing, tracing, tool-call pairing, and token accounting.

This keeps responsibilities separate:

- Scout-AI owns persisted structural navigation and Chat analysis primitives;
- ChatAnalyst owns agent-oriented JSON reports;
- `prov` owns human and Graphviz rendering;
- Workflow Step info owns execution lifecycle and failure provenance.

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/chat/provenance.rb` | Structural traversal, direct neighbours, and collectors. |
| `lib/scout/llm/chat/process/meta.rb` | Meta parsing, lineage, source-aware tracing, projections, and token totals. |
| `lib/scout/llm/chat/tool_calls.rb` | Tool-call pairing and common status interpretation. |
| `lib/scout/llm/backends/default.rb` | Direct token metadata and inference identities. |
| `lib/scout/llm/agent/workflow.rb` | Agent log persistence and chat-task projection. |
| `scout_commands/llm/prov` | Tree, flow, DOT, and plot rendering. |

## Cross-references

- [ChatLifecycle.md](ChatLifecycle.md) — Chat data and compilation.
- [DelegationInternals.md](DelegationInternals.md) — Socialized and delegated agents.
- [../../research/provenance-navigation-design.md](../../research/provenance-navigation-design.md) — Investigation, alternatives, and migration rationale.
