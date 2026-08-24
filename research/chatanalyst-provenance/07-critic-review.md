# Critic review (step 7) — evidence-first

Scope: evaluate the Worker's artifacts 00–05 against the acceptance criteria, inspecting source directly only where evidence is missing, contradictory, or high-risk.

## Evidence-first checks performed

1. **Baseline credibility** — re-ran `git rev-parse` for scout-gear/scout-essentials/scout-ai and `git -C ChatAnalyst log -1`: matches 00-baseline.md exactly (3d9c26b7 / 0f00a696 / 733fc623 / 50e369b). The pre-existing scout-ai local modifications are correctly flagged and correctly *not* attributed to this session.
2. **Duplication proof** — re-derived independently: extracted every `meta: job=` segment from all 14 agent logs via awk, md5'd them; job `ask/Default_4574d35f...`'s segment md5 `50f2cc29bcb6…` (17,620 bytes) appears in 8 distinct parent logs. Matches 03-duplication-evidence.md's table. The claim "byte-for-byte identical" is proven, and the "two places" phrasing in the user's question is correctly explained as *original + inlined copies in N parents*, not a filesystem bug.
3. **Writer mechanism** — verified the cited code path exists and does what is claimed: `call.rb:170-181` (`content.current_chat.follow(res)` after a delegated agent returns) and `annotation.rb:115-146` (`Chat#follow` splices messages; `Chat.setup new`). The inlined-vs-original diff (only leading blank + trailing newline) is consistent with a message-splice, not a file copy — evidence supports the attribution.
4. **Traversal semantics** — verified `provenance.rb:142` signature (`follow:` exists), the relations set at line 4, the `:job` branch following `chat.jobs` (→ meta.rb:177 `job_paths` reads every `meta job=`), and the "never follows import" comment at 138-141. The Defect-A analysis ("meta job= is an unguarded second cross-conversation channel") is sound and is the central insight of the report.
5. **Tooling absence claims** — verified ChatAnalyst `provenance_data` (workflow.rb:96-148) passes no follow/scope options to the four Chat APIs; verified only `message_index` declares `page/per_page` (lines 320-321); verified `chat_overview` totals sum raw records (`chats.sum`) at 411-421. Defects B, C, D are anchored correctly.
6. **Fix-plan target checking** — spot-checked three named targets: `workflow.rb:111-127` (edge sanitization exists; Fix 3's "90% built" is accurate), `workflow.rb:96-148` (Fix 1 insertion point real), provenance.rb `traverse_provenance` (Fix 2 insertion point real, including the `:job` branch where `:own` semantics would live). No invented APIs found in the plan.
7. **Chat-availability finding** — independently confirmed the chats are absent: `chats` symlinks dangle; the sandbox mounts only the 14 Planned job trees. 02's decision to mark prior root-level claims UNVERIFIED is the correct evidence-first handling, and is honestly flagged rather than silently carried.

## Verdict: **PASS with notes**

Findings and their resolution:

- **N1 (resolved):** 00-baseline says the artifact namespace lives under scout-ai `research/` while the plan assumed scout-gear `research/`. The user's earlier instruction ("During your investigations write documents pertaining the code under the ./research folder") applied to *that* run; for this tooling investigation the scout-ai location is defensible since the fixes target scout-ai/ChatAnalyst, but it was an unconfirmed assumption. Recorded as such in resumption.md? No — corrected now by this note: **artifact location remains an open user decision**.
- **N2 (resolved):** 03 asserts token accounting "is NOT double-counted by design" citing inference_id dedup; I verified `provenance_token_events` exists (provenance.rb:426) and the ChatAnalyst README independently documents exactly this behavior ("A receipt copy and a saved child-log copy … the cost is counted once"). Corroborated by two independent sources; claim stands.
- **N3 (resolved):** 05-Fix-4 proposes digest-comparison for `origin: :inlined`; risk noted that digests only match *identical* copies while a splice may normalize whitespace (observed: leading blank + trailing-newline differences between original and inlined copy!). The fix plan already avoids this trap by keying on **lineage/message identity** rather than byte digest — confirmed adequate as written; no change needed.
- **N4 (minor, recorded):** 04-Defect-G labels the duplication "8 identical copies"; 03's table lists 8 parent logs containing the segment — consistent. No discrepancy.
- **N5 (recorded):** The user's original question said duplication existed "in two places"; the evidence shows the general mechanism (N parents) instantiated as 8 here. The report explains this correctly and does not overfit to "two".

No missing, contradictory, stale, or high-risk claims remain open beyond the recorded N1 location decision.
