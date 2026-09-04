# Provenance token accounting for continued conversations (design, not implemented)

Step 3, Part 2 of the provenance-gap plan. Part 1 (provenance follows `job=`
receipt edges) is done and validated; this document designs token accounting
for continuation chains (Cortex `continue` jobs and any `chat_task` that
follows a previously projected chat). No library code was changed for this
design; probes live in `tmp/prov-cont/measure*.rb` and
`tmp/cortex-continuation-accounting-probes.md`.

All numbers below are measured on the real example chain unless marked
otherwise. Jobs live under `/home/mvazque2/.scout/var/jobs/Cortex/continue/`.

## Evidence

### The example chain

Three sequential continuations of one conversation, `fin_fixes_recon`
(workspace copy not found in this environment, see Open questions):

| job | result chat (`Default_<k>.chat`) | inference metas | pt sum |
|-----|----------------------------------|-----------------|--------|
| `c0b45189` | 445 messages, 1 `job=` marker, 147 metas | 147 | 6,297,210 |
| `68b5b7fa` | 711 messages, 1 `job=` marker, 237 metas | 237 | 10,707,400 |
| `80070846` | 60 messages, 1 `job=` marker, 20 metas  | 20  | 1,124,684 |

Each result chat starts with its own `job=` meta marker followed by exactly
that job's own new inferences (this is `Chat.project(self.short_path, result)`
with `result = agent.current_chat - agent.start_chat`,
lib/scout/llm/agent/workflow.rb:127-139, projection at
lib/scout/llm/chat/process/meta.rb:410).

### What the agent log actually contains (replay measured)

`Default_80070846...chat.files/agent.chat` (the third, latest job):

- 404 inference metas, 404 *distinct* `inference_id`s, 0 duplicated ids
  (`tmp/prov-cont/measure41.rb`).
- Organized in projected segments delimited by `job=` meta markers:
  - segment `job=...c0b45189...chat`: 147 metas, pt 6,297,210,
    timestamps 2026-09-02T20:32:48Z .. 21:53:59Z;
  - segment `job=...68b5b7fa...chat`: 257 metas, pt 11,832,084,
    timestamps 21:54:59Z .. 22:48:55Z
    (`measure43.rb`, `measure47.rb`).
- The last segment is MIXED: 257 = 237 inferences authored by job
  `68b5b7fa` + 20 authored by `80070846` itself. There is no marker between
  the second job's projected result and the third job's own new turns; the
  third job appended its turns after `start_chat.follow chat`
  (lib/scout/llm/agent/workflow.rb:85-87) of the projected second result.
- `Default_68b5b7fa...files/agent.chat`: 384 metas, all inside the
  `job=c0b45189` segment (147 replayed + 237 own new, unmarked).
- `Default_c0b45189...files/agent.chat`: 147 unmarked metas, nothing replayed.

So: a continuation log carries the entire grown conversation; every replayed
inference retains its original per-call token fields (`pt`, `ct`, `tt`,
`cct`, `cwt`, `rt`, plus cumulative `*_c` and session `*_s` keys, all 404
rows), original `inference_id`, `provider_response_id` and `timestamp`.

### Inference identity is stable across copies

Shared `inference_id`s between the second and third logs: 384; token-field
(`pt/ct/tt/cct`) mismatches among them: 0 (`measure39.rb`). The third log's
inherited rows sum to pt 17,004,610 / cct 16,288,896, byte-identical totals
to the second job's own log content. Identity, not position, is the reliable
key.

### Traversal already reaches the whole chain

`Chat.provenance_chat_files(third result chat)` returns 6 files: the three
result chats plus the three `.files/agent.chat` logs (`measure44.rb`), via
the `job=` marker edges (Part 1). Per-call meta keys observed in the third
log, all 404 rows: `inference_id`, `timestamp`, `provider_response_id`,
`pt/ct/tt/cct/cwt/rt`, `pt_c...rt_c`, `pt_s...rt_s`, plus `reas` on 12 rows.

## Current behavior (measured)

`Chat.provenance_token_totals(root)` (lib/scout/llm/chat/provenance.rb:729)
collects per-inference events (`provenance_token_events`, line 499),
deduplicates them by identity (`[:inference_id, id]`, else
`provider_response_id`, else lineage, else receipt address; lines 577-608),
then sums the canonical event's tokens (lines 706-708).

Measured per-root totals (`measure44.rb`):

| root | pt | interpretation |
|------|----|----------------|
| `c0b45189` | 6,297,210 | own only |
| `68b5b7fa` | 17,004,610 | cumulative: own 10,707,400 + first's 6,297,210 |
| `80070846` | 18,129,294 | cumulative: own 1,124,684 + 17,004,610 |

Verdicts:

1. Global deduplicated total does NOT double count. 18,129,294 =
   6,297,210 + 10,707,400 + 1,124,684 exactly. Replayed copies of the same
   inference in later logs collapse onto one event; the code's `next if
   meta[:job]` filters (lines 534, 557) plus identity grouping do their job.
2. Per-job root totals ARE cumulative. A continuation job's root total
   includes every ancestor inference, so summing per-root totals across a
   chain double counts (6,297,210 would be counted three times), and a
   naive per-job cost read overstates job `68b5b7fa` by 6.3M pt. Today
   there is no per-job "owned" breakdown: scope symbols
   (`:deduplicated_total`, `:chat_evidence`, `:receipt_evidence`,
   `:receipt_only`, lines 737-750) partition evidence coverage, not authorship.
3. Re-send cost is present but unseparated. The third job's own 20 calls
   cost pt 1,124,684 with cct 1,028,352 (91.5% of prompt tokens served from
   cache; uncached prompt = pt - cct = 96,332). Per-call `pt` already
   includes re-sent history for every call, which is the honest provider
   view, but nothing at job level separates "what this job authored" from
   "history this job re-paid for".
4. Degraded case (missing child `81e265cf`): root
   `Planned/work/Default_de207a52...chat` totals pt 37,969,140 with 2
   warnings, both `unresolved_job_reference` for
   `Cortex/continue/Default_81e265cf...chat` (file absent on disk). The
   parent's log carries that job's projected segment with 0 inference metas
   (its result was an exception receipt), so nothing is silently counted or
   lost; the missing job's own cost is simply unknown, reported only as a
   warning.

## Attribution rules

Core rule: **an inference belongs to exactly one job - the job that issued
the model call - and its tokens are attributed to that job only; any other
copy of the same `inference_id` is evidence, never a second charge.**

1. Ownership set of a job J = the `inference_id`s of the inference metas in
   J's persisted result chat (for `chat` result-type jobs, `job_result_chat_file`,
   provenance.rb:83). Measured: this reproduces the exact deltas above
   (147 / 237 / 20).
2. Fallback ownership (result chat absent, e.g. non-chat jobs or pruned
   results): inference metas in J's own logs (`direct_job_chat_files`,
   provenance.rb:44) whose `timestamp` >= J's start time. Measured: job
   `68b5b7fa` issued 2026-09-02T21:54:53Z; the 237 rows with
   `timestamp >= issued` equal its result-chat set exactly (set difference 0).
3. Rows in J's logs belonging to other jobs are labeled inherited, with
   provenance `{owning job id -> count}` derived from the `job=` segment
   markers around them; they never enter J's owned sums.
4. Global total = sum over distinct `inference_id`s (unchanged; already
   correct today). Per-job owned totals must sum to the global total when
   the chain is complete; the residual (global - sum of known owners) is
   attributed to `unknown`, driven by missing jobs.
5. A missing job referenced by a receipt keeps its `unresolved_job_reference`
   warning; its contribution is reported as `missing`, never as zero-owned
   and never dropped from the residual.

## Continuation-point detection

Three independent signals, used in this priority:

1. **Inference identity** (primary). `inference_id` is unique per call and
   stable across copies (0 token-field mismatches over 384 shared ids).
   Ownership from the result chat (Attribution rule 1) needs no markers at
   all and survives arbitrary re-projection.
2. **Timestamps** (secondary/corroborating). Every inference meta carries
   `timestamp`; job issue time bounds the owned set. Use to cross-check rule
   1 and to recover ownership when a result chat is missing. Measured
   boundary in the chain: first's rows end 21:53:59Z, second starts 21:54:59Z,
   second job issued 21:54:53Z.
3. **`job=` segment markers** (structural, not authoritative). Markers delimit
   projected segments and are what the traversal follows, but the FINAL
   segment of a continuation log mixes the parent's projected result with the
   current job's own turns (measured: 257 = 237 + 20). Therefore markers
   alone can only give an upper bound on inherited content; they must not be
   the sole attribution mechanism. Markers are also where duplicate/cycle
   safety and re-projection idempotence already live
   (`Chat.project` `seen_inference` guard, meta.rb:410-431).

## Cost vs content (honest cost model)

Two quantities must both stay visible and stay distinct:

- **Authored (content) cost**: tokens of inferences the job itself issued.
  Report per job: owned `{pt, ct, tt, cct, cwt, rt}` over its owned set.
- **Re-send (transmission) cost**: history re-paid on each of the job's own
  calls. It is already inside per-call `pt`; surface it as a derived view per
  job: `uncached_prompt = sum(pt) - sum(cct)` over owned calls, plus
  `cache_read = sum(cct)`, `cache_write = sum(cwt)`. Example, job `80070846`:
  pt 1,124,684, cache_read 1,028,352, uncached 96,332 - the continuation was
  cheap precisely because history was cached, and that is now legible.
- Do NOT hide re-send by subtracting history tokens from per-call `pt`: each
  call really did pay its prompt; the cache fields carry the discount.
- Do NOT add inherited rows into the job's cost "because they were sent":
  they were paid inside the job's own calls' `pt` already; adding them again
  is exactly the double count being removed.
- Cumulative keys (`pt_c` etc.) stay out of all sums; they are linear-chat
  checkpoints (`Chat.meta`, meta.rb:140-160), not per-call evidence.

## Safety (dupes / cycles / degraded)

- **Duplicate inference copies**: already handled by identity grouping in
  `provenance_token_events`; the attribution layer only adds an owner label
  per event, so a row replayed into N logs is still one event with N
  evidence records.
- **Conflicting token fields across copies**: existing conflict machinery
  (immutable core `pt/ct/tt` + distinct `provider_response_id`, lines
  632-662) stays authoritative; ownership never overrides a conflict, and
  `strict:` keeps raising.
- **Cycles / self-edges**: traversal visited-set (`provenance_key`, lines
  227-231) and the sidecar root-copy exclusion (`direct_chat_sidecar_files`,
  provenance.rb:68-76) already prevent infinite recursion and self-duplication.
- **Mixed final segment**: attribution by identity/timestamp (not markers)
  is immune; if both identity and timestamps were missing, fall back to
  markers and flag the final segment as `ambiguous_tail` rather than
  guessing.
- **Missing jobs**: unresolved receipt references produce warnings (measured
  2 for `81e265cf`); attribution reports the job as `missing` with its
  reference, and the residual accounting keeps global honesty (unknown, not
  zero).
- **Log inspectability**: unchanged. Nothing is trimmed from logs; only the
  accounting view filters.

## Future implementation surface (not implemented)

- `lib/scout/llm/chat/provenance.rb`
  - new `Chat.provenance_token_attribution(root, warnings: nil, **opts)`:
    reuse `provenance_token_events` (no new traversal), then resolve owners:
    per job node from the same traversal, owned set = inference ids in
    `job_result_chat_file` (fallback: log metas with `timestamp >= job
    start`, from `Step#started`/info), inherited counts from `job=` markers.
  - optional `scope: :owned` (or `attribution:` keyword) on
    `provenance_token_totals` that filters events by owner == root job.
- Data shape: hash keyed by job path:
  `{owned: {pt:, ct:, tt:, cct:, cwt:, rt:, uncached_prompt:, cache_read:},
    inferences: n, inherited: {job_id => count}, missing: [refs],
    ambiguous_tail: bool, warnings: [...]}`.
- CLI: `scout llm prov --tokens=owned` (and an `--attribution` table view),
  reusing the existing totals plumbing.
- Flag/feature name suggestion: `token_attribution` (no env/config knob
  needed; it is a view, not a change of evidence collection).
- Tests would mirror `test/scout/llm/chat/test_agent_meta_tokens.rb` with
  fixture chats containing projected segments, a mixed final segment, a
  missing referenced job, and a re-projected chat.

## Open questions

- **Unverified** - `pt` semantics vs `cct`: whether `pt` includes cached
  tokens (provider convention) or excludes them. The uncached_prompt
  derivation assumes inclusion; confirm against the API adapter code before
  implementing.
- **Unverified** - `fin_fixes_recon` workspace copy: not found under
  `/bulk` or `/home` (only `.scout/tmp` chat copies exist); the design rests
  on job artifacts only. If the Cortex store reappears, confirm its
  conversation file carries the same projected segments.
- **Unverified** - parentage claimed in the task brief (continuations as
  children of `Planned/work 4bf865b6`): not measured; the measured structure
  is a linear chain `c0b45189 -> 68b5b7fa -> 80070846` plus the separate
  `de207a52 -> (missing) 81e265cf` case.
- **Open** - job start time source for the timestamp fallback: `Step` info
  fields vs file mtime vs first owned inference timestamp; pick the most
  robust and document it.
- **Open** - whether ownership should also attach to non-`chat` jobs whose
  logs contain inference metas (e.g. `:json`/`:text` tasks that ran an
  agent); the fallback rule covers them, but naming the owner for log-only
  jobs needs a decision.
- **Open** - should `receipt_only` and owned views be combined in one CLI
  table, or kept separate reports to avoid the documented non-additivity of
  the coverage scopes?
