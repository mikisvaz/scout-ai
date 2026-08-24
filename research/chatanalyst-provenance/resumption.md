# Resumption reference — ChatAnalyst provenance investigation

Task: diagnose why ChatAnalyst could not analyze `~/git/scout-gear/chat/documentation_fix` separately from its imported predecessor `~/git/scout-essentials/chat/doc_inconsistencies`, explain the byte-duplicated agent logs, and produce an implementable fix plan. Source is authoritative; read-only on chats/jobs.

## Status: COMPLETE (all 8 plan steps done)

| Step | Artifact | Status |
|---|---|---|
| 1 baseline | 00-baseline.md | done |
| 2 repo map | 01-repo-map.md | done |
| 3 event reconstruction | 02-event-reconstruction.md | done |
| 4 duplication | 03-duplication-evidence.md | done |
| 5 tooling root cause | 04-tooling-root-cause.md | done |
| 6 fix plan | 05-fix-plan.md | done |
| 7 critic review | 07-critic-review.md | done (PASS with notes, all resolved) |
| 8 final report | chat | done |

## Key facts established (do not re-derive)
- ChatAnalyst: `/home/mvazque2/git/workflows/ChatAnalyst` rev 50e369b + its own uncommitted test/README work. scout-ai: 733fc623 + pre-existing local mods (ask.rb, default.rb, shorten_tools_epoch.rb). scout-gear 3d9c26b7, scout-essentials 0f00a696.
- The two chats are **not on disk** anymore (chats symlinks dangling; only 14 Planned job trees remain under `~/.rbbt/var/jobs`, ro-bound into the sandbox). The prior postmortem's root-level claims (import message, 45 chats) could not be re-verified and are marked UNVERIFIED in 02.
- The duplication is **inlined child transcripts in parent agent logs**: job `ask/Default_4574d35f...`'s 17,620-byte persisted chat appears byte-identical (md5 50f2cc29bcb6…) inside **8 parent logs** (both sessions' request/plan/work/ask). Mechanism: `Chat#follow`/`LLM::Agent#chat` splice the child's returned messages (incl. meta receipts) into the parent, then the parent log is persisted → embedding.
- Cross-conversation reachability: gear sessions used `chat: current`; their logs carry `meta: job=...4574d35f...` (the essentials main ask job); `traverse_provenance` follows every meta job= via the `:job` relation → reaches the essentials society + 4 Critic gates. provenance.rb's "never follows imports" comment (lines 138-141) is true but `chat: current` + persisted meta receipts are an unguarded second channel.
- Traversal: `Chat.traverse_provenance` provenance.rb:142; relations whitelist; `follow:` option exists in scout-ai but ChatAnalyst never exposes it (workflow.rb provenance_data:96-148 passes only on_error).
- chat_agents refuses at scale (observed 136,942 chars); chat_tokens/chat_tool_calls multi-MB refusals; only message_index has pagination (commit 50e369b).

## Fix plan summary (05-fix-plan.md)
1. QW expose edges + filters (already 90% built into chat_overview) → 3
2. QW pagination/summary for heavy tasks → 5
3. M conversation scoping: pass `follow:` through + `job_refs: :own/:all` boundary semantics in scout-ai with a new `:context` edge kind → 1+2
4. M cross-root diff task → 7
5. QW/M content dedup by lineage/digest → 4
6. S writer-side: persist references not transcripts; add conversation/agent/instructions_digest meta → 6
Do NOT: make follow-filtering default; silently drop shared jobs; touch token accounting (already correct).

## Open items for the user
- The two chat directories are gone from disk; if copies exist elsewhere, 02's UNVERIFIED section can be upgraded.
- Fix 6 changes persisted formats (migration concern) — decide deliberately.
