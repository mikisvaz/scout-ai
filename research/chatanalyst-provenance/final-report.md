# Final report: provenance/accounting failure across two chats, and how to fix it

Read with: 02-event-reconstruction.md, 03-duplication-evidence.md, 04-tooling-root-cause.md, 05-fix-plan.md.

## What happened

You asked ChatAnalyst to analyze `scout-gear/chat/documentation_fix` as its own conversation, isolated from the imported `scout-essentials/chat/doc_inconsistencies` history — in particular to isolate the new Critic work from the old. Three things went wrong, in three layers:

### 1. The data layer has no concept of "context, not provenance"

The scout-gear sessions delegated with `chat: current`. Every delegated agent job that shared context received and re-persisted the running main conversation as a `meta: job=` message. Provenance traversal (`Chat.traverse_provenance`, scout-ai `lib/scout/llm/chat/provenance.rb:142`) follows **every** `meta job=` reference through its `:job` relation. So from the gear root, traversal walked: session logs → `meta job=...4574d35f...` (the essentials main ask job) → that job's own logs → the essentials request/plan/work society → the four delegated Critic gates. The docs' claim that "traversal never follows imports" is true — but `chat: current` receipts are an **unguarded second cross-conversation channel** that behaves exactly like an import. Nothing in the meta schema (only `job=` + token counters) can say "this reference is shared context, not this conversation's work."

### 2. The tooling layer never asks the question you asked

ChatAnalyst's `provenance_data` (workflow.rb:96-148) hands the root to four `Chat.provenance_*` APIs with no scope options whatsoever — even though scout-ai's API already accepts a `follow:` relation filter, and even though a relation filter alone wouldn't suffice anyway (you need a *conversation-boundary* limit, which is expressible today only by hand). Every ChatAnalyst task therefore always analyzes the full closure. Combined with record-level (not identity-level) content counting, aggregates blended both sessions plus the shared society; and because the heavy tasks lack pagination (only `message_index` got it in commit 50e369b), the closures that most needed analysis refused at ~100k chars — we reproduced one live refusal at 136,942 characters.

### 3. The duplicated byte-for-byte logs — mystery solved

This is not a filesystem bug. When a delegated agent returns, scout-ai splices the child's returned messages into the parent's current chat (`lib/scout/llm/tools/call.rb:170-181` → `content.current_chat.follow(res)`; `Chat#follow` at `lib/scout/llm/chat/annotation.rb:115-146`), and the parent's log is then persisted **with the child's transcript embedded**. The child's chat also exists at its own job path. So: one original + one embedded copy per consuming parent. Here, the essentials main conversation (17,620 bytes, md5 `50f2cc29bcb6…`) appears **byte-identical inside eight different parent logs** (both sessions' request/plan/work/ask) plus once as the original. Storage inflates multiplicatively with sessions × delegation depth — the work log of session B alone embeds a 2.37 MB copy of session A's conversation.

Consequence for accounting: token totals are *correct* (deduplicated by `inference_id`, corroborated by both the code and ChatAnalyst's README), but message/tool-call/content inventories are duplicated, because the same conversation content physically exists as several "chats" in the closure.

## How to fix it (decision-ready; details in 05-fix-plan.md)

Quick wins (hours, no core changes):
1. **Expose the provenance edges + filters** — `chat_overview` already returns typed edges with full `agent_job` detail; add edge lists/filters (`relation:`, `call_id:`, `job:`) so focused analyses iterate edges instead of loading whole JSON.
2. **Paginate/summarize the heavy tasks** (`chat_tool_calls`, `chat_tokens`, `chat_agents`, `meta_evidence`) exactly like `message_index` — removes the refusals outright.

The core of your request (conversation separation):
3. **Pass `follow:` through in ChatAnalyst** (trivial) and add **conversation-boundary scoping** in scout-ai traversal: `job_refs: :own | :all` (default `:all`), where `:own` follows a `meta job=` only when it belongs to the root conversation, and skipped shared references are reported as a new `:context` edge kind — never silently hidden. Recommendation: **configurable, not the default**; the full closure is ChatAnalyst's core forensic value, and the missing capability was the ability to *say* "just this conversation".
4. **Add a `chat_diff` task** — symmetric difference of two closures (chats/jobs/edges/tokens). This is literally "what is new in this run" as a single call.

Structural (do deliberately):
5. **Writer-side dedup**: persist a reference (`meta: job=<child>` + digest) instead of re-embedding child transcripts; readers fall back to inline content for old logs. Kills the 8× duplication class.
6. **Instruction-version metadata**: extend meta with `agent=`/`instructions_digest=`/`conversation=` per delegated run, making "which Critic instructions ran here" a metadata query instead of prose archaeology.

Also worth adding: content-count dedup keyed by lineage/message identity (not byte digest — the splice normalizes trailing newlines, so digests only catch exact copies).

## What we could not verify

The two chat directories (`chats/doc_inconsistencies`, `chats/documentation_fix`) and `chat/doc_learning` are **gone from disk** — the `chats` symlinks dangle and only the 14 Planned job trees remain. All root-level claims from the earlier postmortem (the import message, "45 chats", shared lineage id) are therefore marked UNVERIFIED in 02-event-reconstruction.md. Everything load-bearing in this report — the duplication, the reachability path, the tooling gaps — was re-derived from the surviving job trees and from source code, both re-checked independently in 07-critic-review.md.

## Baseline

scout-ai 733fc623 (with pre-existing local mods to ask.rb / default.rb / shorten_tools_epoch.rb — not this session's), ChatAnalyst 50e369b (+ its own uncommitted test/README work), scout-gear 3d9c26b7, scout-essentials 0f00a696. Nothing was modified: read-only on all chats/jobs; no source touched; research artifacts written only under `research/chatanalyst-provenance/`.
