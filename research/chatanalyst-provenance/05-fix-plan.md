# Fix plan (step 6) — prioritized, implementation-ready

Legend: **QW** = quick win (hours, local), **M** = medium (1-2 days, one workflow), **S** = structural (scout-ai core, needs design care).

All targets verified against current code. ChatAnalyst = `~/git/workflows/ChatAnalyst/workflow.rb` (rev 50e369b + its own uncommitted test work); scout-ai = `~/git/scout-ai/lib/scout/llm/chat/provenance.rb` etc. (rev 733fc623 with pre-existing local mods).

## Fix 1 — QW: pass `follow:` through and add a conversation-scope option
**Defects fixed:** A (cross-conversation closure), B (no scoping). **Files:** ChatAnalyst/workflow.rb `provenance_data` (lines 96-148) + each task's input declarations.
Add task inputs `follow` (default `:all`, forwarded as `**{follow: follow}` to the four `Chat.provenance_*` calls) and `root_only` (boolean, default false) implemented as `follow: %i[job log result]` minus cross-conversation job refs — see Fix 2 for the precise semantics. Recommendation: **make `follow` configurable, not the default**; the full closure is the right default for forensic "where did this come from" questions, and the README already markets closure as a feature. The new capability is *saying* "just this conversation", which today requires hand-set-diffing.

## Fix 2 — M: conversation-boundary scoping in scout-ai traversal
**Defect fixed:** A properly. **Files:** provenance.rb `traverse_provenance` (142-275) + `Chat#job_paths` (meta.rb:177).
Today every `meta: job=` in any discovered chat is a `:job` edge. Add option `job_refs: :all | :own` (default `:all`). `:own` only follows a `job=` reference when the referenced job's result-chat *is* the chat being read or when the reference's segment belongs to the root conversation (the socialized-projection case described in ChatAnalyst README: the projection references its producer job; following that one is still wanted). Concretely: in the `:job` branch, skip a reference when `Chat.load(ref).first_user_message != root_chat.first_user_message` (i.e. different lineage root) — or simpler and more robust: add `conversation_id` to meta (Fix 6) and compare it. Risk: distinguishing "shared context" from "true producer" is exactly the hard part; the lineage comparison is cheap but imperfect for `continue:`-style splits. Mitigation: keep `:all` the default and report skipped refs under a new edge kind `:context` so nothing is silently hidden. This converts the shared-parent problem from invisible to visible-and-excludable.

## Fix 3 — QW: expose provenance edges to focused analysis (already 90% built)
**Defect fixed:** analyst needs edges for focused work. **Files:** ChatAnalyst/workflow.rb — nothing to build in `chat_overview` (it already returns `edges:` with full `detail` for agent_job, lines 412-417, and provenance_data already sanitizes them at 111-127). Missing pieces: (a) `message_index`/`chat_tool_calls` should also return the edge list (or a new tiny `chat_edges` task) so a focused pass can filter `relation == :agent_job && detail.call_id == X` without loading overview; (b) a `filter` input on `meta_evidence`/`chat_reasoning` (e.g. `relation:`, `call_id:`, `job:`) so analysts iterate edges instead of full JSON. Cost: small; risk: none.

## Fix 4 — QW/M: dedup content counts by lineage, not by file
**Defect fixed:** C (record double counting). **Files:** ChatAnalyst/workflow.rb `chat_overview` totals (411-421), `chat_tool_calls` (453-470).
For chats that are byte-identical inlined projections, count once. Cheapest correct version: key tool-call records by `(chat lineage root, tool_call_id)`; add a `unique_tool_calls` total next to the raw one. Tokens already dedup by inference_id — leave alone. Alternatively expose `origin: :inlined` by comparing each chat's content digest against every `meta job=` target in the closure (the md5 trick from 03-duplication-evidence.md) and skip inlined copies in `chats.sum` unless `include_inlined: true`.

## Fix 5 — QW: pagination/summary beyond message_index
**Defect fixed:** D (refusals). **Files:** ChatAnalyst/workflow.rb `chat_tool_calls`, `chat_tokens`, `chat_agents` + `meta_evidence`.
Commit 50e369b added `page/per_page` only to message_index (line 320-321). Add the same inputs + envelope to the three heavy tasks, and a `summary: true` mode that returns only totals plus top-N. This alone would have made the earlier postmortem a one-call operation instead of three refusals.

## Fix 6 — S: writer-side fixes in scout-ai
**Defects fixed:** G (duplication) and F (instruction blindness). **Files:** annotation.rb `Chat#follow`/`follow` (115-146), call.rb agent splice (170-181), meta.rb meta schema.
- G: when a delegated agent's returned messages are spliced into the parent, persist only a reference (`meta: job=<child>` + optional digest), not the full transcript. The child's chat is already persisted at its own job path; parents never need the bytes again. Migration-safe: readers fall back to inline content when no reference resolves. Kills the 8× duplication class entirely.
- F: extend meta with `agent=<name>` / `instructions_digest=<sha1>` / `conversation=<id>` written once per delegated run. Makes "which Critic version ran here" a metadata query instead of a prose-reading exercise. Needs coordination with meta serialization (meta.rb:81-135) and backward parsing.

## Fix 7 — M: cross-root diff task
**Defect fixed:** E. **Files:** ChatAnalyst/workflow.rb, new task `chat_diff(file, other_file, follow:...)`.
Compute both closures, symmetric-difference chats/jobs/edges, report `only_in_a`/`only_in_b` plus per-side token totals. Implementation is 30 lines over two `provenance_data` calls; the value is high (it is literally the user's recurring question: "what is new in this run?").

## Recommended order
1. Fix 3 (expose edges + filters) — free capability, immediately useful.
2. Fix 5 (pagination/summary) — removes the refusals that block any large analysis.
3. Fix 1+2 together — the conversation-scoping the user asked for; `follow:` pass-through is trivial, boundary semantics deserves the careful `:own`/`:all` design with the new `:context` edge kind.
4. Fix 7 (diff) — cheap once 1-3 exist.
5. Fix 4 (content dedup) — after Fix 6's `origin: :inlined` lands, or standalone via digest comparison.
6. Fix 6 — the structural one; do it last and deliberately, since it changes persisted formats (migration concern).

## What NOT to do
- Do not make `follow:` filtering the default. The closure is ChatAnalyst's core forensic value; scoping is an analyst choice.
- Do not silently drop shared-context jobs from the graph. Report them as `:context` edges so "hidden" is never a failure mode.
- Do not fix token accounting — it is already correct (inference_id dedup); the bugs are all content/structure-side.
