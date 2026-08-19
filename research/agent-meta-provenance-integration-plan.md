# Agent-meta provenance integration: implementation and test plan

> This is an implementation report for Scout-AI and ChatAnalyst coding agents.
> It describes a change to provenance handling for `agent_meta` receipts that
> are embedded in `function_call_output` records. It does not introduce a
> Session, ChatGraph, ProvenanceContext, or database abstraction.

## Decision summary

Scout-AI should treat `agent_meta` as **embedded provenance evidence**.

It must be included in two places:

1. **Structural traversal** must follow `job=` values found in an `agent_meta`
   receipt, so a delegated agent whose answer is produced by a `chat_task`
   exposes the actual producer Step, dependencies, logs, and result.
2. **Token accounting** must include direct token meta records found in
   `agent_meta`, so socialized delegation remains auditable even when there is
   no separately saved child chat.

It must not be represented as a third graph-node kind, converted into ordinary
parent-chat `meta:` messages, or assigned its own stateful context object.

The saved child chat and the receipt may both contain the same direct inference
metadata. They are two evidence locations for one inference event. Deduplicate
by `inference_id`, preserve both locations for auditing, and count the event
once.

## Current behavior and gap

`LLM.process_calls` already creates the required receipt. When a tool returns
an `LLM::Agent`, it:

1. runs `agent.chat(return_messages: true)`;
2. appends the resulting messages to the child agent's current chat;
3. extracts `Chat.find_role(res, :meta)`;
4. serializes those records as `agent_meta` in the parent
   `function_call_output` JSON.

The receipt shape is therefore intentionally narrow and stable:

    function_call_output: {
      "name": "ask",
      "content": "child answer",
      "id": "call_...",
      "agent_meta": [
        {"role": "meta", "content": "pt=... tt=... inference_id=..."},
        {"role": "meta", "content": "job=Workflow/ask/..."}
      ],
      "start_timestamp": "...",
      "timestamp": "..."
    }

The current provenance walker only reads ordinary persisted Chat `meta:`
messages through `chat.jobs`. It does not parse `function_call_output` JSON,
so it misses `job=` records stored in `agent_meta`.

Likewise, `Chat.token_totals` and the current `llm prov` aggregate direct
messages found in discovered chat files. They do not see direct token events
inside a receipt. ChatAnalyst can recover this only through specialized agent
instructions, which is exactly the framework responsibility that should move
into Scout-AI primitives.

## Semantics and invariants

### The three relevant persisted facts

| Fact | Authoritative use |
|---|---|
| Parent function call/output | The parent asked a tool or agent and received this result. |
| `agent_meta` receipt | Portable evidence of direct child inference events and child producer jobs. It is especially important when no child log is discoverable. |
| Child chat / Step logs | Full child execution history: messages, tool calls, direct inference traces, dependencies, files, statuses, and exceptions. |

The receipt is not a replacement for a saved child log. It is a compact
projection of some of the same evidence.

### What is authoritative for token counting

The authoritative counted unit is a **direct inference event**, identified by
`inference_id`.

- A direct meta record in a saved child `agent.chat` and the same record in an
  `agent_meta` receipt represent one event if their `inference_id` matches.
- Both source locations must remain visible in an audit report.
- The event's token fields are counted once.
- A `job=` meta record is not a token event. It is a producer reference and
  must cause traversal into the referenced Step.
- `*_c` and `*_s` remain checkpoints and must never be summed.

### Why `inference_id` is specifically justified here

The receipt/log duplication is a real and common ambiguity, unlike a merely
hypothetical retry:

- parent output contains the Worker’s two direct metas;
- Worker `agent.chat`, when saved, contains the same two metas;
- both are valid persisted evidence;
- only the event identity says they are the same paid requests.

Without `inference_id`, no exact general rule can distinguish a receipt copy
from an independent request with matching metadata. The field is therefore a
join key between two persisted representations of one actual inference.

### Never inject receipt records into the parent Chat

Do not append `agent_meta` records to the parent Chat as ordinary `role: meta`
messages.

That would corrupt parent conversational bookkeeping:

- `Chat.meta` selects checkpoints used by later parent requests;
- child `*_c` values belong to the child conversation;
- parent and child session totals must remain separate;
- a delegated receipt is evidence attached to a tool output, not a new parent
  response segment.

Extraction must be read-only and happen only in provenance analysis.

## Proposed Scout-AI primitives

The implementation should be small, procedural, and return ordinary Arrays
and Hashes.

### 1. Parse agent-meta evidence from tool outputs

Add a Chat helper near `lib/scout/llm/chat/tool_calls.rb`, reusing
`Chat.tool_calls` to avoid reparsing output pairing logic.

Suggested API:

    Chat.agent_meta_evidence(chat, source: nil)

It returns one plain Hash per valid receipt meta record, for example:

    {
      origin: :agent_meta,
      meta: <IndiferentHash parsed by Chat.parse_meta>,
      source: "/path/to/parent.chat",
      output_address: ["/path/to/parent.chat", 17],
      evidence_address: ["/path/to/parent.chat", 17, :agent_meta, 0],
      call_id: "call_123",
      tool_name: "ask",
      agent_meta_index: 0,
      raw_message: {role: "meta", content: "..."}
    }

`source` is optional, matching existing source-aware Chat APIs. If omitted,
the address can use only message indexes.

Extraction rules:

- inspect parsed `function_call_output` records, not raw text with regular
  expressions;
- accept an `agent_meta` Array only;
- accept entries only when they are Hashes with `role == "meta"` and a String
  `content`;
- parse content through `Chat.parse_meta`;
- retain malformed receipt entries as warnings when the caller asks for
  warnings, but never silently reinterpret arbitrary output JSON as
  provenance;
- do not limit the logic to tool name `ask`: the envelope is safe to support
  generically, although reports may label agent-oriented tools specially.

### 2. Expose all meta evidence without altering ordinary Chat semantics

Add:

    Chat.meta_evidence(chat, source: nil)

This returns normal persisted `role: meta` records plus
`Chat.agent_meta_evidence` records, with a shared shape that includes
`origin`.

Suggested origins:

- `:chat_meta` for a normal Chat message;
- `:agent_meta` for a receipt embedded in a function output.

Do not change `Chat#meta`, `chat.role_messages(:meta)`, or the current
meaning of `Chat.token_totals([chat])`. Those APIs describe the local Chat and
must not unexpectedly absorb delegated receipts.

### 3. Expose embedded producer-job references

Add:

    Chat.agent_meta_job_references(chat, source: nil)

This filters `agent_meta_evidence` to records with `meta[:job]`. It returns the
reference and the evidence location.

The existing `chat.jobs` can remain a local-chat API. Do not silently redefine
it to include nested receipt jobs; callers need to distinguish direct visible
projection from delegated receipt provenance.

### 4. Add a provenance-aware token-event collector

Add a root-oriented API, for example:

    Chat.provenance_token_events(root, **traversal_options)
    Chat.provenance_token_totals(root, **traversal_options)

This API should:

1. invoke `Chat.traverse_provenance` to discover persisted chats and jobs;
2. load every discovered chat once;
3. collect ordinary direct events from source-aware chat tracing;
4. collect direct receipt events from `agent_meta_evidence`;
5. discard projection records with `meta[:job]` from token addition;
6. group direct events by `inference_id`;
7. return one event record with all evidence locations;
8. sum canonical direct fields only: `pt`, `ct`, `tt`, `cct`, `cwt`, and `rt`.

A returned event should include enough audit information to explain a total:

    {
      inference_id: "...",
      meta: <canonical parsed direct meta>,
      tokens: {pt: ..., ct: ..., tt: ...},
      evidence: [
        {origin: :agent_meta, evidence_address: [...]},
        {origin: :chat_meta, meta_address: [...]}
      ],
      deduplication: :inference_id
    }

### Legacy records without `inference_id`

Do not claim exact receipt/log deduplication for old data.

For ordinary persisted chat meta, preserve the existing lineage-based fallback
already used by `Chat.trace_chats`.

For an embedded receipt meta without an inference ID, there is no full child
conversation in which to compute its lineage. Use a receipt-address-based
fallback and mark it clearly, for example:

    deduplication: :receipt_unresolved

If a provider response ID is present and Scout-AI considers it stable enough,
it may be used as an explicit secondary identity. Do not silently use
heuristic equality of token counts, timestamps, or reasoning text as proof of
identity.

Reports should warn that legacy receipt/log records can be overcounted when no
shared inference or provider identity exists.

### Identity conflicts

If two records share an `inference_id` but disagree on direct token fields,
provider response ID, or other immutable event facts:

- do not sum both;
- retain both evidence records;
- emit a provenance conflict warning;
- make the conflict visible in `prov` and ChatAnalyst.

This detects a broken producer rather than hiding it behind deduplication.

## Traversal changes

### Add `:agent_job` as a relation

Extend `Chat::PROVENANCE_RELATIONS` with `:agent_job`.

When visiting a Chat node, the walker should enqueue both:

- ordinary direct `chat.jobs` as `:job` edges;
- receipt `agent_meta_job_references` as `:agent_job` edges.

The parent remains the enclosing Chat node and the child remains a native
Step. There is no receipt node.

This relation is useful because it preserves why the job was discovered:

| Relation | Meaning |
|---|---|
| `job` | A visible response segment in this chat was projected from the job. |
| `agent_job` | A delegated agent receipt inside a tool output says its response was projected from the job. |

The referenced Step then follows normal `dependency`, `log`, and `result`
relations. Existing cycle and shared-node handling applies unchanged.

### Error handling

Malformed receipt JSON or unreadable receipt job references must be reported
through the existing `on_error`/warning path with:

- enclosing chat path;
- tool output address;
- call ID and tool name when available;
- relation `:agent_job`;
- original reference.

A malformed receipt should not hide other normal provenance from the same
chat.

### Do not follow ordinary imports

The current traversal intentionally treats imports as compilation composition,
not persisted provenance edges. Preserve that policy. The agent-meta work does
not require reintroducing import traversal.

## `scout-ai llm prov` changes

The command already separates graph discovery from token computation. Update
only those layers.

### Graph discovery and rendering

1. Call the enhanced traversal.
2. Include `:agent_job` in adjacency sorting, after direct `:job` and before
   ordinary dependency/log display as appropriate.
3. In default tree mode, show a job discovered through a receipt with an
   explicit label, for example:

       chat Manager.chat
         delegated-job Worker/ask abc12345

   The job remains a normal job node; `delegated-job` is the edge label.

4. In flow and DOT modes, reverse `:agent_job` in the same way as `:job`,
   because the job produces content used by the parent chat. Use a distinct
   visual style or label such as `delegated_result` so it is not confused with
   a direct projected job result.

5. Do not make a Graphviz node for every receipt or every direct inference.
   The graph should remain a Chat/Step structural graph.

### Token display

Replace direct uses of `Chat.token_totals(chats)` in `prov` aggregate logic
with `Chat.provenance_token_totals` or the equivalent event collector.

The default total must include receipt-only child usage. It must not add it
again when the same child log is reachable.

The current `--component` mode should become explicit about source scope. The
recommended output distinctions are:

- `local`: direct meta events physically stored in the chat/log;
- `receipt`: child direct events found only or also in `agent_meta` receipts;
- `aggregate`: deduplicated union of all reachable event identities.

For a compact tree, do not print a separate line for every receipt by default.
Instead, append a concise annotation to the parent chat or tool call summary,
for example:

    delegated receipt: 2 events, total=17.0k, Worker/test_sum

When `--component` is enabled, print receipt components individually with call
ID and source address.

### New CLI option

Add a focused diagnostic option rather than overloading flow output. Suggested
name:

    --evidence

It prints the deduplicated direct inference event table:

| Inference ID | Tokens | Evidence | Status |
|---|---:|---|---|
| `eed7eb...` | 8463 | parent ask output; Worker agent.chat | counted once |
| `a477d8...` | 8550 | parent ask output; Worker agent.chat | counted once |

It should also display:

- receipt-only events;
- legacy unresolved events;
- inference-ID conflicts;
- job projection references, but with no direct tokens.

This is the right command for diagnosing why a total contains child work. The
normal tree and flow should remain compact.

## ChatAnalyst changes

ChatAnalyst should consume the Scout-AI primitives and delete any bespoke
receipt-parsing logic it currently has. It should not need special agent
instructions to discover `agent_meta`.

### `chat_overview`

Add:

- `agent_job` structural edges;
- number of receipt records per chat;
- number of receipt-only direct events;
- provenance warnings for malformed receipts or conflicts.

### `chat_tool_calls`

For each function call output, add a compact receipt summary:

    agent_meta: {
      direct_events: 2,
      job_references: ["Worker/ask/..."],
      token_total: {tt: 17013},
      event_ids: ["eed7...", "a477..."]
    }

Keep the raw answer content and tool success status separate from token
attribution.

### `chat_tokens`

This task should switch from plain `Chat.token_totals` to the new provenance
event collector. Return:

- aggregate deduplicated totals;
- `events` or a compact per-event index;
- per-chat local totals;
- receipt-derived totals;
- receipt-only totals;
- duplicate evidence count;
- unresolved legacy receipt count;
- identity conflict warnings.

Do not describe a receipt contribution as a second paid inference when its ID
also appears in a saved child log.

### `chat_agents`

An agent interaction should report:

- call ID;
- target agent and conversation when present in arguments;
- receipt event IDs and totals;
- linked `agent_job` Steps, if any;
- whether child evidence was receipt-only, log-only, or both;
- whether the log association is structural, inferred by naming convention, or
  absent.

### `message_index` and `message_content`

Do not pretend embedded receipt metas are ordinary child-chat messages.

Either:

1. add a dedicated `meta_evidence` task; or
2. allow `message_index --role meta` to include an `origin` field and a nested
   receipt address.

A dedicated task is clearer. It can return normal and embedded meta evidence
without asserting that an embedded record has a full child message history.

Suggested address format:

    [parent_chat_path, function_output_index, :agent_meta, meta_index]

`message_content` may resolve this address by re-parsing the parent output;
there is no separate physical child message at that address.

### `chat_report`

Include concise highlights only:

- total deduplicated direct tokens;
- local versus receipt-only contribution;
- number of event IDs with multiple evidence locations;
- count of `agent_job` edges;
- conflicts and unresolved legacy receipts.

## Test plan

All fixtures must be offline and use persisted chat text plus temporary job
layouts. Do not call model providers.

### A. Receipt-only socialized delegation

Fixture:

- parent chat has one `ask` function call/output;
- output includes two direct `agent_meta` records with distinct inference IDs;
- no saved Worker chat or Worker job exists.

Assertions:

- traversal still has only the parent Chat node;
- provenance token events include both Worker events;
- aggregate total includes parent plus Worker tokens;
- `prov --evidence` identifies both events as receipt-only;
- ChatAnalyst `chat_agents` reports the receipt and its total.

### B. Receipt plus saved Worker log

Fixture extends A with a discoverable Worker job/log containing the same two
metadata records and inference IDs.

Assertions:

- traversal discovers the Worker Step and log through normal structure;
- token total is identical to fixture A plus any additional known worker log
  events, not doubled;
- event records retain both receipt and log source locations;
- `prov` default total and ChatAnalyst aggregate total agree;
- component output labels receipt evidence rather than charging it twice.

### C. Receipt with `job=` projection

Fixture:

- parent output contains `agent_meta` with `job=Worker/ask/...`;
- Worker Step has a normal agent log with direct token metadata.

Assertions:

- traversal emits an `:agent_job` edge;
- Worker dependencies and logs are recursively reached;
- the receipt job meta itself contributes zero direct tokens;
- actual Worker direct log tokens are counted once;
- tree, flow, and DOT label the delegated producer relationship.

### D. Nested receipt chain

Fixture:

- Manager receipt points to Worker;
- Worker log contains a second socialized receipt for Critic;
- Critic has either direct receipt-only events or a `chat_task` producer job.

Assertions:

- recursion terminates safely;
- all direct event IDs appear once in aggregate accounting;
- graph edges preserve both delegation paths;
- no Session-like recursive state object is needed.

### E. Malformed and incomplete receipts

Fixtures:

- invalid outer function-output JSON;
- `agent_meta` is not an Array;
- entry lacks role/content;
- malformed meta content;
- unresolved `job=` path.

Assertions:

- normal chat/job provenance remains available;
- warnings include source address and call ID when available;
- no malformed record is accidentally counted as tokens;
- strict and warning callback modes behave as documented.

### F. Identity conflict

Fixture contains two evidence locations with the same `inference_id` but
different `tt` or provider response ID.

Assertions:

- total does not silently add both;
- event records retain both facts;
- warning is emitted in `prov --evidence` and ChatAnalyst;
- automated tests make the chosen conflict policy explicit.

### G. Legacy records

Fixture has ordinary and receipt metadata without inference IDs.

Assertions:

- normal Chat records retain current lineage fallback behavior;
- receipt records are marked unresolved unless an explicit secondary identity
  is available;
- reports do not claim exact receipt/log deduplication;
- no regression occurs for old chats without `agent_meta`.

### H. Output truncation

Fixture uses an oversized agent answer whose parent output content is replaced
with the standard truncation exception but whose `agent_meta` remains present.

Assertions:

- receipt token events remain discoverable;
- truncation state is reported separately from model cost;
- no child tokens are lost merely because parent context omitted the full text.

## Acceptance criteria

The implementation is complete when:

1. a root chat with only an `ask` receipt reports delegated direct token usage;
2. a receipt plus saved child log counts each `inference_id` once;
3. receipt `job=` entries create discoverable normal Steps through
   `:agent_job` traversal edges;
4. parent Chat checkpoint semantics remain unchanged;
5. existing `Chat.token_totals([chat])` remains local-Chat compatible;
6. `llm prov`, ChatAnalyst, and the new core collector return the same
   deduplicated aggregate total for shared fixtures;
7. every receipt-derived amount is traceable to a parent output address and
   call ID;
8. malformed receipts and identity conflicts are warnings, not silent
   undercounting or double counting;
9. no wrapper class is introduced merely to hold traversal or accounting state;
10. all new tests run offline.

## Recommended delivery order

1. Add receipt/meta evidence extraction and unit tests.
2. Add embedded job-reference extraction and `:agent_job` traversal tests.
3. Add root-oriented event collection and exact inference-ID deduplication.
4. Update `Chat.tokens` and any provenance-specific aggregate callers to use
   the new collector, while retaining local `Chat.token_totals` semantics.
5. Update `scout-ai llm prov`, including `--evidence` and component labels.
6. Update ChatAnalyst to consume the core APIs and remove bespoke receipt
   recovery logic.
7. Add cross-consumer fixtures asserting equal totals and equivalent job
   discovery.
8. Update maintained developer documentation and preserve this plan as the
   deeper design record.
