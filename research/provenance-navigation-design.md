# Provenance navigation in Scout-AI

> This is an investigation and design proposal, not normative documentation.
> It reflects the code inspected in `scout-ai` and the current
> `/bulk/mvazque2/git/workflows/ChatAnalyst` checkout. It intentionally does
> not propose implementations for agent monitoring, `ask_user`, or explicit
> agent-raised failure; those topics are considered only where they constrain
> provenance.

## Executive conclusion

The difficult part of Scout-AI provenance is not recursion. It is that a run
interleaves two already-valid Scout data models:

1. a Chat is an Array of messages and contains conversational lineage,
   inference metadata, imports, and job projections;
2. a Step is a persisted Workflow execution and contains dependencies, status,
   inputs, result files, and log artifacts.

The provenance structure is therefore a heterogeneous directed graph whose
only persistent node kinds are **chat files** and **workflow jobs**. Agents,
tool calls, inference segments, and token events are observations inside those
nodes; they should not be promoted into Session, ProvenanceContext, ChatGraph,
or Node classes merely to make traversal convenient.

The core library should provide one small, block-oriented traversal primitive
that walks native `Path` and `Step` values and yields typed relationships. The
`prov` command and ChatAnalyst should consume that primitive and independently
format or analyse what they receive. Message tracing, tool-call pairing, and
token accounting should remain separate Chat operations layered on top of the
files returned by traversal.

The most important data-model gap is more fundamental: direct inference meta
messages currently have no persisted unique inference/event identifier. The
lineage digest is excellent for recognizing copied conversation history, but
it cannot distinguish two genuinely repeated requests with identical history
and metadata. Consequently, current token deduplication is useful but cannot
be exact in every case. A locally generated inference ID should eventually be
persisted in each direct meta record. This is independent of traversal and
should not block the traversal cleanup.

## Sources examined

The investigation covered:

- `scout_commands/llm/prov`
- `lib/scout/llm/chat/process/meta.rb`
- `lib/scout/llm/chat/provenance.rb`
- `lib/scout/llm/agent/workflow.rb`
- `lib/scout/llm/agent/delegate.rb`
- `lib/scout/llm/tools/call.rb`
- `lib/scout/llm/backends/default.rb`
- provenance and meta tests under `test/scout/llm/`
- the current and previous ChatAnalyst implementations in
  `/bulk/mvazque2/git/workflows/ChatAnalyst/workflow.rb` and
  `workflow.rb.orig`
- persisted jobs and recursively nested agent logs under
  `~/.scout/var/jobs`
- agent examples under `~/chats/Agent`
- Scout Workflow lifecycle and provenance documentation

A real `Refined/ask` result with separate
`log/worker-round-1/agent.chat` and `log/critic-round-1/agent.chat` files was
used as a concrete layout check. The current ChatAnalyst Session found five
chats, two jobs, and six edges from one sampled result, which confirms that the
basic recursive idea works. It does not remove the design and correctness
issues below.

## The crisp model

### Persistent facts

A provenance reader should begin with facts that are already persisted, not
with inferred conceptual objects.

A chat file can directly state:

- conversational messages;
- `import`, `continue`, and `last` references to other chat files;
- direct inference metadata in `meta` messages;
- a producer job reference in `meta job=...`;
- function calls and function-call outputs.

A workflow job can directly state or expose:

- its path and logical Workflow/task identity;
- status, timing, exception, inputs, and dependency paths in Step info;
- its result, which may itself be a chat file;
- recursively named chat artifacts under `.files/log/**/*.chat`.

Nothing else is required to navigate the structural provenance.

### Structural relations

Traversal from a requested root follows five relations:

| Parent | Relation | Child | Meaning |
|---|---|---|---|
| chat | `import` | chat | The parent incorporates another persisted chat. |
| chat | `job` | job | A projected response in the chat was produced by the job. |
| job | `dependency` | job | The job consumes a normal Scout dependency. |
| job | `log` | chat | The job persisted an agent conversation as a log artifact. |
| job | `result` | chat | The job result itself is a chat and must be inspected, especially when traversal starts from a Step. |

These are **root-outward discovery relations**. They are deliberately not
presentation arrows. For example, a flow diagram may render a producer job as
feeding a chat, while recursive discovery follows the chat's `job` reference
toward the producer. `prov` currently mixes discovery hierarchy with natural
data-flow direction, which makes otherwise simple code hard to reason about.
Renderers should decide arrow direction after traversal.

### Observations inside nodes

The following are analyses of node content, not additional structural node
kinds:

- an inference segment is a meta record plus the messages it covers;
- a tool invocation is a paired `function_call` and
  `function_call_output`;
- agent delegation is a tool invocation whose tool is `ask` or
  `hand_off_to_*`;
- an agent log is still a chat file; “agent” is a label inferred from its log
  path or explicit future metadata;
- token usage is attached to direct inference segments;
- a job failure or abort is Step status and exception evidence.

Keeping this distinction prevents the graph from becoming a second runtime
object model.

## What currently works well

Several core decisions are strong and should be retained.

### Chat remains plain data

`Chat.load` reads persisted chat text without recompiling roles. This is the
right safety boundary for provenance: inspection must never execute imports,
tasks, files, or tools.

### Job projections are explicit

`Chat.project` removes direct meta records from the projected output and adds a
single `meta job=<path>` marker. This cleanly distinguishes “tokens spent in
this chat” from “content produced elsewhere and projected here.”

### Conversational lineage is content-addressed

`message_index` hashes each non-meta message with its conversational
predecessor. Copied or inherited histories therefore share lineage identities,
while changed histories diverge. Excluding meta from the conversational chain
is correct because meta is not provider input.

### Segment tracing is independent of job traversal

`trace_indices`, `trace_chats`, `direct_entries`, and `token_totals` operate on
Chats and do not need to know how files were found. This separation is exactly
the direction the rest of the provenance implementation should follow.

### Workflow provenance is already authoritative for jobs

Step info already records dependencies, lifecycle status, timings, exceptions,
and other execution facts. Scout-AI should link to that evidence rather than
replicate it in a Session-like object.

## Current problems

### Traversal is duplicated three times

The same heterogeneous walk is independently implemented in:

- `scout_commands/llm/prov#report`;
- `Chat.provenance` and related helpers;
- `ChatAnalyst::Session` (and previously the much larger
  `ChatAnalyst::ChatGraph`).

Each copy makes slightly different decisions about imports, result chats,
dependencies, logs, deduplication, errors, and edge direction. Fixes therefore
do not propagate to all consumers.

### Core helper contracts are inconsistent

Current examples include:

- `Chat.job_chat_files(job)` recursively includes dependencies;
- `Chat.job_agent_chat_files(job)` includes only the given job's logs;
- the instance `job_agent_chat_files` only expands the chat's immediate jobs;
- documentation describes some of these as recursively traversing all
  dependencies;
- `job_agent_chats` is named as if it returned loaded Chat values but currently
  returns paths.

A caller cannot infer recursion or return type from these names reliably.
Traversal should be centralized, and direct-neighbour helpers should say that
they are direct.

### `Chat.provenance` is not a faithful general traversal

The current implementation follows job logs and then calls
`Chat.provenance(dep.path)` for dependencies. That treats an arbitrary Step
result path as if it were necessarily a chat. It also omits chat imports and
uses a nested Hash whose meaning is limited to chat-to-log relationships;
normal dependency and producer relationships are not represented explicitly.
Broad existence checks and implicit rescues obscure malformed or missing
evidence.

### `prov` combines discovery, printing, graph construction, token analysis,
filtering, naming, and rendering

The recursive `report` both prints and builds a nested graph. Later flow code
must reverse or reinterpret edges based on whether a Hash key happens to be a
Step or a String. Global instance variables cache nodes, edges, chats, and
tokens. This makes the command longer and less reliable than the underlying
problem warrants.

There are also concrete fragilities:

- identity alternates between Step objects and paths;
- `report` may return `nil` for a seen object while callers expect a Hash to
  merge;
- imports are absent;
- an unused `load_chat` helper remains;
- root detection relies on the presence of `<filename>.files`;
- display suppression of `agent.chat` is entangled with token attribution;
- “agent” type is guessed from `'.files/log/'` in a path.

### ChatAnalyst's Session is a cache plus recursive side effects

`Session` eagerly resolves and traverses everything in its constructor, stores
four mutable collections, embeds path resolution and warning policy, and adds
token methods that already exist on Chat. Every task constructs a fresh
Session and then reads those caches.

This abstraction adds no domain concept. It is an execution context for one
algorithm. More importantly, it encourages future agent-written code to add
more convenience methods until traversal, accounting, tool semantics, and
reporting are coupled again.

The earlier `ChatGraph` demonstrates that failure mode clearly: it grew path
canonicalization, hidden-path policy, tool parsing, success inference, usage
accounting, overlap analysis, message storage, job fallbacks, and graph
construction inside one class. Replacing it with a smaller Session reduced the
amount of code but not the architectural cause.

### Error handling is mostly invisible

Some library traversal helpers rescue all exceptions and return empty arrays.
ChatAnalyst catches exceptions and stores warning strings. `prov` often lets
errors escape. These policies make the same missing log or unreadable legacy
Step look like “no provenance,” a warning, or a fatal error depending on the
consumer.

The traversal primitive should not invent an error-monitoring subsystem, but
it must expose failures with their source node and attempted relation so that a
CLI can warn, an analyst can report incomplete evidence, and a strict caller
can raise.

### Location identity and lineage identity are conflated

There are two legitimate identities:

- a **message address**, such as `[chat_path, index]`, identifies where a
  persisted message can be retrieved;
- a **lineage ID** identifies equivalent conversational content and is useful
  for recognizing inherited or copied history.

ChatAnalyst creates strings such as `path#index` and calls them IDs, while Chat
also calls the lineage digest an ID. Reports should name these fields
`address` and `lineage_id` explicitly. An address should remain structured
until final JSON formatting rather than relying on parsing a path containing a
separator.

### Exact inference identity is not persisted

`Backend::Default#update_meta` currently stores token fields and cumulative
snapshots, but the tests explicitly assert that `usage_id` is absent.
`trace_chats` deduplicates segments by the lineage-derived meta ID. This is
correct for a copied historical segment but can collapse two genuinely
repeated requests when all of the following are identical:

- preceding conversational lineage;
- meta token fields;
- response content.

Conversely, session counters are process snapshots and cannot identify a
request. Exact cost and execution counting requires a unique persisted direct
inference identity generated by Scout-AI, independent of provider request IDs.

### Delegation is not always structurally linked to its log

Workflow-backed agent calls have strong job and log links. Socialized agents
are returned by the `ask` tool, executed later by `process_calls`, and finally
written by `log_agent` under a society path. The function call says which
agent/conversation was requested, and the path convention often allows a
match, but no explicit durable ID links that call to the precise specialist
chat or inference segment. This should be reported as a semantic association,
not presented as an authoritative structural edge.

## Proposed core primitives

### 1. Direct-neighbour readers

First make direct facts explicit and non-recursive. Suggested responsibilities
are:

- resolve a persisted chat reference without compiling it;
- return direct import files for a chat and its source path;
- return direct job references from a chat;
- return direct dependencies of a Step;
- return direct log chat files of a Step;
- return the Step result chat when its type is chat.

Existing APIs can supply several of these, but names and contracts should be
made consistent. In particular, methods named `*_chats` should return Chat
values and methods named `*_files` should return paths. Recursion should not be
hidden inside either.

### 2. One block-oriented traversal

Add a module function on Chat, not a class. A possible contract is:

    Chat.traverse_provenance(root, follow: :all, on_error: nil) do |
      kind, object, parent_kind, parent, relation
    |
      # kind is :chat or :job
      # object is a Path for :chat and a Step for :job
      # root has nil parent and relation
    end

Without a block it should return an Enumerator. The implementation needs only
a queue or recursion and a Set. The visited key must include node kind, because
a chat-typed job result may have the same filesystem path as its Step.

The traversal should:

1. normalize a root explicitly as a chat file or Step;
2. yield the root once;
3. read only direct neighbours;
4. yield each newly visited child together with the relation that discovered
   it;
5. retain cycle safety and shared dependency deduplication;
6. preserve native values rather than wrapping them in node classes;
7. expose read/load failures through `on_error` with the parent and relation.

The exact block argument order can change, but the essential contract is that
consumers receive native objects plus explicit type and relation. A flat stream
is sufficient to print a tree, collect JSON nodes and edges, calculate tokens,
or produce DOT.

An error callback can receive:

    error, kind, object, relation, referenced_value

If no callback is supplied, raising is the clearest library default. CLI and
analysis callers can opt into “record warning and continue.” Silent rescue and
empty output should not be the default because absence of evidence differs
from unreadable evidence.

### 3. Small collectors implemented from traversal

Convenience is still useful when it preserves the same semantics. Small module
functions can collect from the stream:

- `Chat.provenance_chat_files(root)`;
- `Chat.provenance_jobs(root)`;
- `Chat.provenance_edges(root)`.

These should be thin collectors, not alternate traversal implementations.
The existing `Chat.provenance` can either become a compatibility collector or
be deprecated after consumers migrate.

### 4. Source-aware tracing

Keep `Chat.trace_chats` for compatibility, but add a source-aware form that
accepts `[path, chat]` pairs and retains addresses:

    { meta_address: [path, index],
      lineage_id: ...,
      meta: ...,
      messages: [[path, index], ...],
      message_lineages: [...] }

Deduplication should remain based on explicit inference ID when present and
fall back to the current lineage rule for legacy chats. Retrieval should use
addresses; overlap analysis should use lineage IDs.

### 5. Tool-call pairing as a Chat primitive

Pairing calls and outputs is message analysis used by any future analyst, not
only ChatAnalyst. Add a small operation that returns plain Hash records and
preserves both addresses. It should support current provider-normalized roles
and fields (`function_call`, `mcp_call`, `function_call_output`, `id`,
`call_id`, nested function name).

Success/failure interpretation should be separate. Pairing can authoritatively
say whether an output exists and what it contains. Deciding that JSON with
`exit_status != 0` means a failed shell call is a reporting policy, not generic
Chat structure. A helper may provide the common policy, but the raw pair must
remain available.

## Suggested traversal implementation shape

The implementation can be short and procedural:

1. a queue contains tuples of kind, native object, parent kind, parent, and
   relation;
2. a Set contains `[kind, canonical_path]` keys;
3. visiting a chat loads it once, enqueues direct imports and producer jobs;
4. visiting a job enqueues direct dependencies, logs, and its result chat;
5. each loading operation is wrapped only at the boundary needed to call the
   configured error handler.

There is no need for Session state, a Graph object, node subclasses, edge
classes, visitor classes, or a provenance database.

A consumer that needs a graph can use ordinary Hashes and Arrays:

    nodes = {}
    edges = []

    Chat.traverse_provenance(root, on_error: record_warning) do |
      kind, object, parent_kind, parent, relation
    |
      key = [kind, provenance_path(object)]
      nodes[key] ||= object
      edges << [[parent_kind, provenance_path(parent)], relation, key] if parent
    end

That state belongs to the report being built, not to the core traversal.

## How `prov` should change

`prov` should become three clearly separated stages.

### Discovery

Call `Chat.traverse_provenance` once and collect the flat visit stream or edges.
Do not print during recursion. Do not infer edge types from Ruby classes after
the fact.

### Analysis

Load each discovered chat once. Use Chat operations for direct token entries,
totals, and any future tool-call summaries. Job token totals can be defined as
the totals of chat logs directly owned by that job; subtree totals should be
named explicitly because they include dependencies and can overlap in a DAG.

The current command sometimes presents a job total that recursively includes
its logs and descendants without making scope obvious. Reports should label
`direct` versus `subtree` totals.

### Rendering

Tree, compact flow, DOT, and plots should consume the same node/edge arrays.
Tree indentation is a spanning-tree presentation of a DAG; repeated nodes
should be shown as references rather than recursively expanded. Flow arrow
direction should be selected by relation in rendering only.

This removes the global `@flow_*` caches and most type/path guesses from the
command.

## How ChatAnalyst should change

ChatAnalyst does not need Session.

Each task can use one Workflow helper that returns the traversal stream or a
plain collected Hash for the duration of that task. A helper is appropriate
because it is local executable reuse, not a new domain abstraction. For
example:

    helper :provenance_records do |file, warnings = []|
      Chat.traverse_provenance(file, on_error: ->(...) { warnings << ... }).to_a
    end

Tasks can then remain focused:

- `message_index`: iterate discovered chat files and emit address plus lineage;
- `message_content`: retrieve exact addresses;
- `chat_overview`: collect structural nodes and edges;
- `chat_tool_calls`: call the shared Chat pairing primitive;
- `chat_tokens`: call source-aware trace/token operations;
- `chat_agents`: filter paired tool calls, while marking inferred log matches as
  inferred;
- `chat_report`: use Workflow dependencies on the smaller tasks if caching is
  desirable, or combine their plain helper results.

`chat_report` should not rerun a hidden second traversal for each subreport
inside one task. Either collect once locally or make reports proper Workflow
dependencies. That decision is normal Workflow composition, not provenance
architecture.

## Identity and deduplication rules

### Chats

For one filesystem, use an expanded real path where possible. Preserve the
original reference as an alias for reporting. Do not silently merge different
files merely because their contents overlap.

### Jobs

Use the loaded Step path as the physical identity. A logical identity such as
workflow, task, and result basename can identify mirrored `~/.scout` and
`~/.rbbt` candidates, but merging them is safe only if their relevant info and
result agree. If two physical jobs share a logical identity but disagree,
retain both and issue a warning rather than selecting one silently.

### Messages

Use `[chat_path, index]` as the address and the existing digest as
`lineage_id`.

### Inference events

Introduce a random locally generated `inference_id` (or equivalently named
field) in each direct meta record. Generate it once per actual backend request
and preserve it through cached replay and copied chat history. Provider request
IDs can be stored separately when available, but should not be required.
Legacy records fall back to lineage identity with an explicit
`deduplication: legacy_lineage` qualification in precise reports.

### Tool calls

Use provider/tool call ID scoped by chat lineage or chat address. Do not assume
a provider call ID is globally unique across all files.

## Correctness tests to add before migration

Traversal tests should use temporary persisted jobs/chats and cover:

1. a root chat with no references;
2. a chat importing another chat;
3. a chat projected from a job;
4. a job with multiple recursive log chats;
5. a job with a chat dependency and a non-chat dependency;
6. shared dependencies visited once but represented by all relevant edges;
7. a cycle caused by a chat result projecting its own producer job;
8. missing import, missing job, malformed chat, and unreadable Step info under
   both strict and warning policies;
9. two physical job roots with the same logical digest;
10. an aborted or error Step with partial log files;
11. traversal starting from a Step rather than a chat;
12. deterministic traversal order.

Tracing/accounting tests should cover:

1. copied direct inference history deduplicated once;
2. two identical real requests with distinct `inference_id` counted twice;
3. legacy identical records reported with fallback deduplication;
4. job projection meta excluded from direct token totals;
5. cache, cache-write, and reasoning token fields;
6. source addresses retained for every segment and covered message;
7. orphan and consecutive meta records;
8. the same tool call ID appearing in two chat files;
9. missing tool output versus an output containing an exception;
10. socialized agent calls where a log association is only inferred.

Consumer tests should run `prov` and ChatAnalyst against the same fixture and
assert that they discover the same chat paths, jobs, and structural edges.

## Concrete defects worth fixing opportunistically

These are small enough to address while introducing the primitive:

- make `job_agent_chats` actually load and return Chat values, or rename it;
- document and test whether each `job_*` helper is direct or recursive;
- remove broad rescue-to-empty behavior from structural readers;
- remove the unused `load_chat` in `prov`;
- stop detecting job roots only through `<filename>.files`;
- avoid `merge!` on a recursive result that may be `nil` for a seen node;
- require `set` explicitly in `prov` if it continues to use Set directly;
- stop classifying an agent as a distinct persistent node based solely on a
  path substring;
- make token scope explicit (`direct file`, `direct job logs`, or `subtree`);
- correct maintained documentation that currently claims recursive behavior or
  APIs that do not match the code.

## Relationship to the deferred concerns

### Exceptions, aborted managers, and active-agent monitoring

The proposed traversal already helps historical failures because it must visit
jobs regardless of `done?`, expose Step status, and discover partial log files.
It should not require a new monitoring abstraction.

If active agents later write state under `var`, the clean integration is to
make that state another persisted artifact referenced by a Step or chat, not to
put live-agent state into the provenance walker. Historical provenance and
live monitoring have different consistency requirements.

Backend failure snapshots currently written to anonymous TmpFile paths are
weak provenance because the path is logged but not structurally linked to the
Step/chat. A future change could save the snapshot under the owning job's
files directory when `agent.job` is available, or record its path in Step info.
That would make it discoverable without changing traversal semantics. This is
not required for the provenance refactor.

### `ask_user`

An `ask_user` operation should appear as an ordinary tool call. Its spool item
and eventual response can carry the tool call ID or a derived request ID. The
generic tool-call pairing and provenance addresses proposed here are enough;
the walker should not special-case human interaction.

### Agents declaring impossible work

An explicit failure should become either a tool output containing structured
failure or a normal Workflow/Step exception and status. Again, traversal only
needs to preserve and expose that evidence. It should not decide whether the
failure was justified.

## Recommended implementation sequence

1. **Specify and test direct relations.** Correct helper names/return types and
   add fixtures for chats, jobs, dependencies, logs, and imports.
2. **Add `Chat.traverse_provenance`.** Keep it procedural, block-oriented, and
   explicit about errors.
3. **Reimplement existing collectors from traversal.** Preserve compatibility
   where inexpensive.
4. **Migrate `prov`.** Separate discovery, analysis, and rendering; compare
   output against current real jobs.
5. **Add source-aware tracing and tool-call pairing.** Keep plain Hash/Array
   results.
6. **Migrate ChatAnalyst and delete Session.** Use Workflow helpers and tasks,
   not replacement classes.
7. **Add persisted inference IDs.** Update accounting to prefer them while
   retaining legacy lineage fallback.
8. **Revise maintained developer documentation.** Keep this investigation as
   the detailed rationale and document only the stable concepts/API in
   `doc/developer/Provenance.md`.

## Final design rule

A useful test for every proposed provenance abstraction is:

> Does this represent a persisted fact in Chat or Workflow, or is it only state
> needed while producing one report?

Persisted facts belong in Chat/Step primitives. Temporary report state belongs
in local Arrays, Hashes, Sets, and blocks. If an object exists only to hold a
queue, a seen set, loaded chats, edges, and warnings, it should not be a class.
