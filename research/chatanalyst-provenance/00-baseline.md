# Baseline and discovery record

## Date of work
2025-XX-XX (session: ChatAnalyst provenance investigation)

## Git revisions (recorded before any substantive investigation)

| Repository | Revision at start | Notes |
|---|---|---|
| `~/git/scout-gear` | `3d9c26b7a15b5992ca95138b8ba4383e5863e44e` | uncommitted: `.vimproject` modified; `tmp/` untracked (probe scripts from prior audit work) |
| `~/git/scout-essentials` | `0f00a6965ff5486cceba32dd0c951ae838e834af` | clean |
| `~/git/scout-ai` | `733fc623f81373a5aed400fa691a3838bf9f729e` | uncommitted: `.vimproject`, `lib/scout/llm/ask.rb`, `lib/scout/llm/backends/default.rb`, `lib/scout/llm/chat/prompt/shorten_tools_epoch.rb` (pre-existing concurrent LLM work, NOT touched by this audit) |

## Locations recorded

- Chat A (earlier conversation): `~/git/scout-essentials/chat/doc_inconsistencies`
- Chat B (later conversation, imports Chat A): `~/git/scout-gear/chat/documentation_fix`
- ChatAnalyst session that analyzed Chat A: `~/git/scout-essentials/chat/doc_learning`
- ChatAnalyst workflow directory: NOT YET LOCATED (to be discovered in step 2; user said "workflow directories" have been given — verify by registration)
- Prior postmortem artifact (hypothesis source, to re-verify): `~/git/scout-gear/tmp/gear-retro-05-separation-postmortem.md`

## Read-only confirmation
- All chats, `doc_learning`, and every `var/jobs` tree are treated as read-only evidence.
- No code changes are in scope (design-only fix plan, unless user later confirms implementation).

## Revision boundary policy
If any of the three repositories move during this investigation, a revision boundary will be recorded here rather than silently absorbing the change.

## Untracked-probe note
`scout-gear/tmp/` contains untracked probe scripts (P057* identifiers probes and earlier audit probes). These are prior work, not modified by this session.
