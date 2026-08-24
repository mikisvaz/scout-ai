# Duplicate agent logs (step 4) — proven and explained

## The phenomenon, proven

The byte-for-byte "duplicated agent logs in two places" are **inlined copies of one job's persisted chat inside other jobs' agent logs**, produced by the chat-import/compilation mechanism when a delegated ask returns and the parent's transcript is persisted.

### Evidence

`Planned/ask/Default_4574d35ff303912b7a4957761e559068.chat` (the main Manager conversation of the scout-essentials audit, 102 lines, one assistant message "Final report") is inlined — byte-for-byte, md5 of the segment = `50f2cc29bcb6...`, length 17,620 bytes — into **five different parent agent logs**:

| Parent agent log | Inlined segment md5 | Size |
|---|---|---|
| `ask/Default_3e2d45a6...` (session A ask) | 50f2cc29bcb6 | 17,620 |
| `plan/Default_9529d895...` (session A plan) | 50f2cc29bcb6 | 17,620 |
| `request/Default_395e25f7...` (session A request) | 50f2cc29bcb6 | 17,620 |
| `work/Default_7b6f7d7f...` (session A work) | 50f2cc29bcb6 | 17,620 |
| `plan/Default_dbe07c55...` (session B plan) | 50f2cc29bcb6 | 17,620 |
| `request/Default_73d4a242...` (session B request) | 50f2cc29bcb6 | 17,620 |
| `work/Default_abb12d37...` (session B work) | 50f2cc29bcb6 | 17,620 |
| `ask/Default_f1fda6bf...` (session B ask) | 50f2cc29bcb6 | 17,620 |

(Eight parents total; the table above lists each. Same md5 = byte-identical.)

Likewise `ask/Default_3e2d45a6...` (session A ask) is inlined into 5 other logs, `plan/Default_dbe07c55...` into 2, `work/Default_abb12d37...` into 2, `request/Default_73d4a242...` into 1, etc. Every `meta: job=` line inside an agent log marks one such inlined copy.

### Why it is not "two copies of the same log"

The originals are single files on disk (13 distinct agent.chat files, all distinct md5s — see 02-event-reconstruction.md). What exists in "two places" is: the **original persisted chat file**, plus one or more **verbatim inlined transcripts of it inside other jobs' logs**. Any reader that flattens a tree of agent logs (as ChatAnalyst traversal does) will see the same content multiple times.

## The mechanism (writer side)

When the Manager (ask) job returns, its chat is persisted, and the caller's transcript is compiled with the child chat **inlined as a `meta: job=<path>` block** in the parent's `log/agent.chat`. Verified in `ask/Default_f1fda6bf...` lines 350-452: user turn "Update: You have already done quite a lot of work..." followed immediately by `meta: job=...4574d35f...` and then that job's full persisted chat. The inlined block matches the source `.chat` file except for a leading blank line and trailing-newline differences (diff shows only `0a1 >` and the final no-newline marker).

Because the session agents used `chat: current` (delegation with shared context), **each** session's four jobs (request/plan/work/ask) received and re-persisted the same conversation history — hence the same inlined 17,620-byte block appears in eight parent logs.

## Consequence for accounting

- Storage duplication is linear in (number of sessions) x (number of delegated jobs per session) — 8 copies x 17.6 KB here; for the big work logs it is much larger (work 7b6f7d7f is 10.9 MB; its inlined copy into ask f1fda6bf is 2.37 MB).
- ChatAnalyst's provenance reader *does* deduplicate token accounting by `inference_id` (provenance.rb: evidence records carry `inference_id`; identity conflict logic exists — see lib/scout/llm/chat/provenance.rb). So tokens are NOT double-counted by design. But **content** (message lists, tool-call counts) IS present multiple times in the raw evidence, and aggregate counters that count records rather than deduplicate by identity will double-count — this is exactly what produced "15,456 tool-call records" mixing sessions.

## Fix direction

1. **Reader-side (ChatAnalyst):** expose the `meta: job=` edges it already parses (provenance edges) and provide a dedup/group mode; do not flatten inlined transcripts into message inventories.
2. **Writer-side (scout-ai):** mark inlined blocks as references (e.g. `meta: job=...` plus digest) and, when persisting a parent log, store the reference without re-embedding the full child transcript (or store a digest + optional lazy-load). This kills the 8x duplication at the source.
3. Either way, tag inlined blocks with `origin: :inlined` in evidence records so consumers can exclude them (`exclude_inlined: true`).
