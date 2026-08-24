# Tooling root-cause analysis (step 5) — reader side, anchored to source

All line numbers refer to the checked-out trees at the recorded baseline:
scout-ai 733fc623 (with pre-existing local modifications to `lib/scout/llm/ask.rb`, `lib/scout/llm/backends/default.rb`, `lib/scout/llm/chat/prompt/shorten_tools_epoch.rb`), ChatAnalyst 50e369b (with a large uncommitted test/README addition of its own).

## What the traversal actually does (verified)

`Chat.traverse_provenance` — `~/git/scout-ai/lib/scout/llm/chat/provenance.rb:142`.

- BFS from one root (chat file or job Step) over exactly five relations: `:job, :dependency, :log, :result, :agent_job` (`PROVENANCE_RELATIONS`, provenance.rb:4).
- A `:job` edge exists for **every job reference** found in the root/any discovered chat's `meta` messages — `chat.jobs` → `Chat#job_paths` (meta.rb:177-183), i.e. every `meta: job=...` line in any discovered chat.
- An `:agent_job` edge exists for every agent_meta receipt carrying a `job` key (call.rb:175-203 writes them; provenance.rb agent_meta_job_references).
- The comment block at provenance.rb:138-141 states explicitly: *"Imported and continued chats are a chat-compilation concern, not a provenance concern… Provenance traversal therefore never follows import, continue, or last references."* **But import is not the only cross-conversation channel**, and this is the key finding: `meta: job=` messages in agent logs are a *second, unguarded* cross-conversation channel. Traversal follows them unconditionally through the `:job` relation.

## Defect A — the closure crosses conversation boundaries via `meta job=` (tooling + usage mix)

Concrete path (all edges verified on disk, see 02-event-reconstruction.md):
the gear root's sessions used `chat: current`, so their agent logs carry `meta: job=Planned/ask/Default_4574d35f...` (the essentials main conversation); traversal expands that job, whose `log/agent.chat` is the essentials main agent log, whose own `meta: job=` lines reach the request/plan/work society chats, and through them the four delegated Critic gates.

So: the doc-level claim "traversal never follows imports" is literally true yet the analyst still sees the imported conversation — because `chat: current` + persisted `meta job=` receipts are, structurally, imports wearing a different role. **Classification: data structure cannot express "this job reference is context, not provenance"** — the meta schema (meta.rb:73-135 serialize/parse) carries only `job=` and token fields; there is no `origin`/`scope`/`conversation` discriminator. The tooling then faithfully reports what the data says.

## Defect B — no scoping parameter anywhere (tooling)

`ChatAnalyst.provenance_data` (ChatAnalyst/workflow.rb:96-148) calls `Chat.provenance_token_events`, `Chat.provenance_edges`, `Chat.provenance_chat_files`, `Chat.provenance_jobs` **without any options besides on_error**. The underlying scout-ai API supports `follow:` (provenance.rb:142 `follow: :all`) — the relation filter — but ChatAnalyst never exposes it, and `follow:` cannot express "stop at conversation boundary" anyway (it is a relation whitelist, not a depth/scope limit). All eight ChatAnalyst tasks (message_index … chat_report) therefore always analyze the full closure of whatever root you hand them. Instance: analyzing `documentation_fix` returned the four Critic gates from the essentials run.

## Defect C — content duplication in aggregates (tooling)

- `chat_tool_calls` (workflow.rb:453-470) and totals in `chat_overview` (workflow.rb:411-421) count **records** (`chats.sum { |c| c[:tool_calls] }`) over all chats in the closure. Because inlined transcripts (see 03-duplication-evidence.md) mean the same underlying conversation content appears as several *chats* (the persisted original + the parents that embed it in their agent logs), record-level sums double-count. Tokens are deduplicated by inference_id in `provenance_token_events` (provenance.rb:426+); content is not.
- `chat_agents` (workflow.rb:505+) groups by agent name but has no "per conversation/sub-run" grouping, so Critic shares computed across a merged closure blend sessions.

## Defect D — context-size refusals (tooling)

Tasks return the full JSON of the closure (workflow.rb:323 message_index has `page/per_page` only for that one task; chat_overview/chat_tool_calls/chat_tokens/chat_agents have no pagination at all). On a 45-chat, 15k-tool-call closure this exceeds the workflow's own 100k-char result protection, producing refusals (observed live: 136,942-char chat_agents refusal; 4.8MB chat_tokens; 4.27MB chat_tool_calls). Recent commit 50e369b "Add pagination" added it only to message_index.

## Defect E — no cross-root diff (tooling absence)

"What is new in this run?" requires comparing two full closures by hand. No task accepts a second root, and none computes the symmetric difference of chats/jobs/tokens. All manual set-diffing in the earlier postmortem traces to this absence.

## Defect F — instruction-version blindness (data structure)

Nothing in provenance records which agent-start_chat/instruction version produced a run. The Critic strategy change is invisible to the tooling; only prompt prose (readable via message_content) shows it. meta messages carry only job refs + token counters (meta.rb TOKEN_KEYS / serialize_meta).

## Defect G — the writer-side duplication (tooling/design, scout-ai)

Verified mechanism in `Chat.follow`/`Chat#follow` (annotation.rb:115-146) + `LLM::Agent#chat` (agent/chat.rb:30+) + call.rb:170-181: when a delegated agent returns, `content.current_chat.follow(res)` splices the child's *returned messages* (including its meta receipts) into the parent's current_chat; the parent's log is then persisted, embedding a full copy of the child transcript. With `chat: current` × multiple session agents, the same child transcript gets embedded in every parent — the 8 identical copies of job 4574d35f's chat (md5 50f2cc29bcb6…). Storage and analysis both inflate multiplicatively. See 03 for the full table.

## Which layer owns which problem

| Finding | Layer | Where |
|---|---|---|
| Closure crosses conversations via meta job= | data structure (+ usage: chat: current) | meta.rb schema; provenance.rb:job relation |
| No scope/exclude_shared param | tooling | ChatAnalyst workflow.rb provenance_data + tasks |
| Record-level double counting | tooling | workflow.rb totals; needs identity-level dedup |
| Refusals at scale | tooling | workflow.rb missing pagination/summary outside message_index |
| No cross-root diff | tooling | no task accepts second root |
| Instruction version unknown | data structure | meta schema lacks digest field |
| 8× byte-identical copies | design, writer side | annotation.rb follow; call.rb agent splice; persisted logs |
