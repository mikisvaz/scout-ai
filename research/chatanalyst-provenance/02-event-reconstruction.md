# Event reconstruction (step 3) — data-level

## Critical environment finding: chats moved since the postmortem

- `~/git/scout-essentials/chats` → symlink to `/home/mvazque2/chats/scout-essentials/` (created Feb 2 2026)
- `~/git/scout-gear/chats` → symlink to `/home/mvazque2/chats/scout-gear/` (created Nov 5 2025)
- **`/home/mvazque2/chats` DOES NOT EXIST NOW.** Both symlinks are dangling from inside this sandbox.
- `~/git/scout-ai/chats` does not exist at all (earlier report listed it as existing; it does not in this environment).
- The ChatAnalyst `chats` symlink → `/home/mvazque2/chats/ChatAnalyst` is also dangling.

Implication: **the two root chat files (`doc_inconsistencies.chat`, `documentation_fix.chat`) are NOT readable from this session.** The postmortem (`tmp/gear-retro-05-separation-postmortem.md`) was written when they were readable. What remains readable:
- the 14 `Planned/*` job trees under `~/.rbbt/var/jobs/` (individually bind-mounted into the sandbox), and
- the prior retrospective artifacts in `~/git/scout-gear/tmp/` (gear-retro-*).

This is an environment access constraint, not a data-destruction event (symlinks themselves survive; targets may be unmounted in this sandbox). Recorded as CAVEAT-E1.

## Verified: the shared parent ask job 4574d35f

`~/.rbbt/var/jobs/Planned/ask/Default_4574d35ff303912b7a4957761e559068.chat`
- 102 lines; single persisted assistant message = the scout-essentials "Final report" (elaborated).
- `meta: job=Planned/ask/Default_4574d35f...` line 2.
- `.files/log/agent.chat` (59,560 bytes) = the FULL agent log:
  - `system:` block (Agent Operating Instructions — the Worker agent instructions seen in this conversation's own system prompt)
  - 3 user + 4 assistant turns (grep counts: `^user:` 3, `^assistant:` 4)
  - **nested `meta: job=` references at lines 349, 440, 539**:
    - `Planned/request/Default_6ad9e52a9a8118f853b0f74231ecd866.chat`
    - `Planned/plan/Default_f375a4eea58845f9888afc9fb7ff09ff.chat`
    - `Planned/work/Default_c0fa69abdf19fbd120ed6c1e339b1fb6.chat`
  - final usage meta line with `inference_id=1eca85e8-...`, `provider_response_id=2026082218102034537c0b4e2242f6`.

This is the mechanism by which one persisted agent log carries references to other jobs: every delegated `ask` appends the child job's persisted chat as a nested `meta: job=...` message **inside the parent's agent log** (chat compilation / import inlining).

## Job inventory (all 14 trees present under Planned/)

ask: 3972f1db(info only), 3e2d45a6, 4574d35f, f1fda6bf
plan: 9529d895, dbe07c55, f375a4ee
request: 395e25f7, 6ad9e52a, 73d4a242
search: 6e14e9a8
work: 7b6f7d7f, abb12d37, c0fa69ab

Matches the postmortem's job set (A: work 7b6f7d7f + plan 9529d895 + request? + ask?; B: work abb12d37 + plan dbe07c55 + request? + ask?; C: work c0fa69ab under the essentials run).

## Postmortem claims status (to verify against remaining data)

| Claim | Status |
|---|---|
| Gear root `documentation_fix` message #1 is `role=import` of essentials chat; shared lineage `693d623f...` | UNVERIFIABLE now (root chat unreadable) — recorded from postmortem |
| Four Critic gate jobs (5eeea726, 32807d27, a20b029b, fc3a7058) byte-identical in both roots | UNVERIFIABLE now (not in the 14 mounted job trees — they live under the unreadable chats tree) |
| Only ONE Critic society run exists (no second delegated gate run in gear sessions) | Supported by postmortem; cannot re-verify directly; the mounted trees contain NO critic_gate* job |
| Sessions A/B logs reference `meta job=4574d35f` | PARTIALLY verifiable: need to grep the mounted plan/work/ask logs for that reference (next step) |
| `chat_agents` refused at 136,942 chars | Refusal is consistent with tool code: aggregate tasks have no pagination except `message_index` (workflow.rb lines 318–322); large outputs hit the 100k guard in the tool layer |

## Next steps
1. Grep the mounted agent logs for `meta job=` references to build the actual cross-job edge set from data.
2. Look for byte-duplicate agent logs among the 14 mounted trees (hash scan).
