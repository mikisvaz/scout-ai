# Path-kind contract fixes 3 and 5 — engine round (scout-ai)

Date: 2026-10-22. Checkout: scout-ai at
`/bulk/mvazque2/git/scout-ai` (same repository as
`/home/mvazque2/git/scout-ai`), HEAD
`ee9c90c0752d7ada7f715313f3e762bc8ffca117`, nothing committed. All
changes of this round are uncommitted working-tree edits; evidence lives
under `tmp/path-kind-fix35/` in this checkout.

This is the engine-side half of the path-kind contract line. It
implements and pins two fixes that a client checkout reported out as
engine-side frictions: root-selector grammar (fix 3) and `path_kinds`
honoring its `kind` input (fix 5). The client round that reported them
is recorded in the ScoutCoder checkout
`research/path-kind-contract-fixes.md` (round 11 of that suite; not
reproduced or modified here).

## What changed and why

The two frictions were first observed in a recorded AGS agent session and
consolidated in the Cortex review artifact
`reports/ags-path-kind-contract-friction.md` (Cortex store of the
scout-gear/AgentSuite workspace; session evidence `main.chat#37-42`,
`#44-48`, `#113-117` per the client round note). The ScoutCoder round 11
fixed its four client-side items and REPORTED the two engine-side ones
out with fresh-process reproductions; this round is that report's
discharge.

### Fix 3 — root selectors address the kind root, never a file

Contract. The empty string, `"."` and `"./"` are ENUMERATION selectors
that address a kind's root as a whole; they are never a path to one file
inside it. The ten file-shaped built-in operations — `path_read`,
`path_write`, `path_patch`, `path_edit`, `path_move`, `path_rename`,
`path_delete`, `path_validate`, `path_smoke`, `path_promote` — reject all
three spellings at argument validation, before resolution and before
authorization, with:

```
ParameterException: Invalid path for <operation>: "<value>" addresses
the kind root; use a path relative to the root, or path_list to
enumerate the root
```

`path_list` is the enumeration surface and is NOT guarded: it normalizes
`""`, `"."` and `"./"` to the empty prefix and lists the kind root, exactly
like an omitted path. `path_dispatch` is NOT guarded either: custom
operations own their path grammar and may legitimately receive `"."`
(an enumeration client's suite scope does exactly that), so the raw value
passes through untouched.

Why the rejection must precede resolution: on an extension-bearing kind a
`"."` path previously resolved through `set_extension` to the junk target
`<root>/..rb`. Pre-fix behavior (from `logs/red.log`): `path_write` with
`"."` SILENTLY CREATED `<root>/..rb` (`"written"=>true`); `path_read` of
`"."` reported `Path does not exist or is not readable: <root>/..rb`;
`path_list` of `"."` returned an EMPTY list; `path_move`/`path_rename`
with `""` reported `moved=>true` or leaked raw `Errno::ENOENT` mentioning
the junk target. The guard removes the whole class of behavior, and its
message never contains the resolved junk target.

Code points (`lib/scout/llm/agent/path.rb`, current working tree):

- `ROOT_SELECTOR_PATHS = ["", ".", "./"].freeze` (line 1198);
- `path_reject_root_selector!(operation, path)` (line 1200) — raises the
  ParameterException above, naming the operation that received the value;
- `path_root_selector_normalize(path)` (line 1213) — path_list's
  counterpart, maps a root selector to the empty prefix;
- guard call at the top of `path_read` / `path_write` / `path_patch` /
  `path_move` / `path_rename` / `path_delete` / `path_promote`
  (in `path.rb`), `path_edit` (`lib/scout/llm/agent/path/edit.rb`,
  `path_edit` line ~163), and `path_kind_operation` (line 1615, which
  backs `path_validate` and `path_smoke`); `path_dispatch` (line 915) and
  `path_list` (line 1423) are deliberately unguarded, and `path_list`
  calls the normalizer instead.

### Fix 5 — path_kinds honors its kind input

Contract. `path_kinds` takes an optional `kind`. With no `kind`, or an
empty string, it returns one entry per registered kind (the full map, as
before). With a `kind` it returns EXACTLY that kind's entry, in the same
per-kind shape as a full-map entry (`description`, `locations`,
`default_location`, `sandbox`, `capabilities`). An unknown `kind` raises
`ParameterException: Unknown path kind: <kind> (available: <sorted kind
names>)`. The tool description was updated to say "Supply kind to return
only that kind's entry", and the tool schema exposes `kind` as an
optional enum of the registered kinds.

Pre-fix, the handler signature was `def path_kinds(_args = {})` — the
argument was discarded by the signature itself, so every call returned
the full map regardless of `kind` (client reproduction: with
`kind=entity|entity_property|test_file` and no kind, all four calls
returned `count: 4`).

Code points: `path_kinds(args = {})` and the extracted
`path_kind_registry_entry(definition)` helper (lines 1314/1330).

## Red-to-green evidence

All logs under `tmp/path-kind-fix35/logs/` in this checkout; the probe
itself is `tmp/path-kind-fix35/probe.rb` (fresh-process, explicit inputs;
it registers an extension-bearing kind, an extension-free kind, and a
kind with a custom `peek` operation that records the raw path it
receives).

- Pre-fix (red): `logs/red.log` — 42 CHECK lines. Key failures quoted
  above: `path_write ext_kind path="."` returns `NO-ERROR ... written=true`
  with `target_file=<root>/..rb`; `B3` shows the junk file `..rb` now on
  disk; `path_list path="."` returns `[]`; `D1` shows
  `path_kinds kind=ext_kind` returning ALL THREE kinds (filter ignored);
  `D2` shows `kind=missing` NOT raising.
- Post-fix (green): `logs/green.log` — every file-shaped op rejects every
  root selector with the message naming the operation and `path_list`;
  zero occurrences of `..rb` anywhere in the log; `B3`/`Z1` show the kind
  root still contains only `alpha.rb` and `sub/beta.rb` (no junk file);
  `C1`/`I1` show `path_list` of `"."`/`"./"` listing the root;
  `D1` returns exactly `["ext_kind"]`; `D2` raises the unknown-kind
  ParameterException; `E1`/`E2` show the custom operation receiving `"."`
  as given.
- Independent re-run (this verification pass): `logs/verify-green.log` —
  byte-identical to `green.log` modulo the tmpdir path prefix (diff of
  both with the prefix normalized is empty). The suite confirms it is
  reproducible in a fresh process, not a warm-state artifact.
- Unit suites: `logs/test_path_errors.log` (15 tests, 281 assertions, 0
  failures, 0 errors), `logs/test_path.rb.log` (74 tests, 599 assertions,
  0F 0E), `logs/test_path_edit.sanity.log` (41 tests, 113 assertions, 0F
  0E, untouched-by-this-round edit suite), and `logs/rake-test.log`
  (full repo suite: 695 tests, 3480 assertions, 0 failures, 0 errors,
  7 omissions — all environmental, Python/Torch modules absent; identical
  omission set in the fresh verification re-run
  `logs/verify-rake.log`).
- Doc round did not touch code; `logs/doc-verify.log` re-ran the two
  touched suites (both green) and grepped the doc.

## Test coverage — the seven new tests and what each pins

`test/scout/llm/agent/test_path_errors.rb` (4 new):

1. `test_error_matrix_root_selector_rejected_by_every_file_shaped_operation`
   — the full matrix: two kind shapes (extension-bearing and
   extension-free) x ten file-shaped operations x the `""` and `"."`
   spellings (plus `"./"` pinned on one operation per kind), asserting
   the ParameterException names the operation, matches "addresses the
   kind root", mentions `path_list`, and never matches `\.\.rb` (the
   resolved junk target must not leak).
2. `test_path_write_root_selector_creates_no_file` — a rejected
   `path_write` with `"."` leaves the kind root empty: no `..rb`, no
   `.rb`, `Dir.children` empty.
3. `test_error_matrix_path_kinds_unknown_kind_lists_available_kinds` —
   unknown kind raises `Unknown path kind: nope` and the message names an
   available kind.
4. `test_error_matrix_path_kinds_empty_kind_returns_full_map` — `kind:
   ""` and `kind: nil` both enumerate everything (the filter is opt-in).

`test/scout/llm/agent/test_path.rb` (3 new):

5. `test_path_kinds_kind_input_returns_only_that_kind` — with two kinds
   registered, `kind: "other"` returns exactly `["other"]`, in the same
   per-kind shape (same keys, same capabilities) as the full map's entry.
6. `test_path_list_root_selector_lists_the_kind_root` — on a populated
   extension-bearing kind, omitted path, `""`, `"."` and `"./"` all list
   exactly `["alpha.rb", "sub/beta.rb"]`.
7. `test_path_dispatch_passes_root_selector_to_custom_operation` — a
   kind-defined `peek` operation receives `"."` verbatim (`["."]`
   recorded) and returns `PEEK .`; the engine applies no grammar of its
   own on dispatch.

## Client regression (read-only): the ScoutCoder checkout

The AgentSuite/ScoutCoder checkout (`/bulk/mvazque2/git/AgentSuite/ScoutCoder`,
mounted read-only at `/home/mvazque2/git/AgentSuite/ScoutCoder` for this
round) loads THIS engine checkout — its before-run log carries the
evidence line
`engine path_kinds source: /home/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb:1285`,
and `/home/mvazque2/git/scout-ai` and `/bulk/mvazque2/git/scout-ai` are
the same repository. Its suite was run before and after the engine
change, read-only, from its own tree (`logs/scoutcoder-before.log`,
`logs/scoutcoder-before-full.log`, `logs/scoutcoder-after.log`,
`logs/scoutcoder-after-full.log`).

Regression statement. Both runs report IDENTICAL totals —
`test_path_kinds.rb`: 29 tests, 429 assertions; `test_path_kinds.rb` +
`test_path_kinds_roundtrip.rb`: 11 tests, 18 assertions, 0F 0E — and
IDENTICAL failure signature sets (5 signatures, names + exception
classes, compared mechanically in
`tmp/path-kind-fix35/signatures-before.txt` / `signatures-after.txt`;
md5-identical):

1. `Failure: test_engine_authorized_set_excludes_paired_test_destination(TestPathKinds): ParameterException(<Path access denied by sandbox (outside_grants)>)` — environmental sandbox grant failure;
2. `Failure: test_run_test_suite_scope_discovers_both_sides_and_empty_is_error(TestPathKinds)` — expects an empty-discovery error, gets the sandbox denial instead;
3. `Failure: test_task_smoke_constructs_job_without_executing(TestPathKinds)` — `<true> expected but was <nil>`;
4. `Error: test_test_file_list_honors_prefixes(TestPathKinds): ParameterException: Path access denied by sandbox (outside_grants)`;
5. `Error: test_test_file_list_round_trips_virtual_paths(TestPathKinds): ParameterException: Path access denied by sandbox (outside_grants)`.

All five PREDATE this change (they are environmental: the client tests
provoke paths that fall outside the sandbox grants of the environment the
suite ran in). No signature appeared, disappeared, or changed class. The
textual differences between the full logs are: three backtrace line
shifts inside this engine file — `path.rb:1174` -> `:1175` in
`path_authorize!` (three occurrences, one per outside_grants backtrace)
and `path.rb:1387` -> `:1433` in `path_list` (two occurrences) — caused
by the new guard methods and the `path_kinds`/`path_kind_registry_entry`
restructure moving code down; the after log's additional
`test_path_kinds_roundtrip.rb` section (11 tests, 18 assertions, 0F 0E;
the summary logs already counted it), which the before run of the same
commands did not produce; and the before-log's two header comment lines.
None is a behavioral change.

The checkout was not modified by this round: `git status --porcelain`
there is unchanged relative to its own round (uncommitted client-round
edits at HEAD `bab41ebfd8eeb1d68c538e9569f0f1c01d1e2c77`, latest mtimes
18:35 today, before this round's first artifact at 18:56), and the
engine-side evidence directory
(`/bulk/mvazque2/git/scout-ai/tmp/path-kind-fix35/`) is in THIS
repository, not that one. Note the initial probe attempt through the
`/bulk/...` spelling failed (`No such file or directory`) because the
bwrap sandbox mounts that checkout only at the `/home/...` spelling; the
read-only check succeeded through `/home/mvazque2/git/AgentSuite/ScoutCoder`.

## Documentation changes

`doc/developer/PathEngine.md`:

- new section 8 "Root selectors address the kind root, never a file" —
  the full contract, the junk-target rationale, the path_list
  normalization and the path_dispatch exemption, plus the pinning tests;
- a `path_kinds` filter paragraph in section 7 (the installed tool
  surface): filter, full-map on omission/empty, unknown-kind error;
- the pinned-test inventory in section 9 extended with the root-selector
  rejections (section 8) and the `path_kinds` unknown-kind error
  (section 7);
- the pre-existing duplicated paragraph in section 9 ("Errors follow the
  engine contract: ... handlers must normalize their own failures." was
  present twice back-to-back) removed in passing — one copy deleted, the
  other kept verbatim. Disclosed drive-by, not part of either fix;
- sections renumbered: old 8 -> 9, old 9 -> 10, old 10 -> 11, and the
  intro paragraph plus the in-file cross-reference in section 5 updated;
- `doc/Improvements.md` R16 cross-reference updated from §8 to §9.

## Deviations from the delivered-plan-as-written

None in scope or content. Two disclosed incidental changes inside the
planned file set, both recorded by the implementing agent and confirmed
here against the diff:

- `test/scout/llm/agent/test_path_filesystem.rb`
  `test_path_write_filesystem_failure_does_not_return_success` was
  re-pointed: it used `path: "."` to provoke `Errno::EISDIR` from
  `File.write`; the new guard rejects `"."` earlier, so the test now
  creates an explicit `directory_target` directory and writes to it —
  the same real write-failure path, no stubbing.
- the PathEngine.md duplicated-paragraph removal described above.

One more incidental, engine-internal: in `path_kind_operation` the guard
runs AFTER the capability check and the "has no validate/smoke
implementation" check, exactly where path resolution sat before the round
(HEAD `ee9c90c…`: capability -> implementation -> resolve -> authorize;
working tree: capability -> implementation -> guard -> resolve ->
authorize). On kinds without those implementations a root selector
therefore raises the missing-implementation error, not the root-selector
error — which is what the probe's validate/smoke lines in
`verify-green.log` show ("Path kind ext_kind has no validate/smoke
implementation", six lines), because the probe kinds genuinely lack
implementations; the matrix tests register real implementations precisely
so the guard is what their assertions observe. The guard's position
relative to the implementation check is unchanged from pre-round; this
ordering is incidental and deliberately unpinned; see open items.

## Lineage

- Motivating review: Cortex artifact `reports/ags-path-kind-contract-friction.md`
  (AgentSuite/scout-gear Cortex store) — six tool-contract frictions
  observed in a recorded AGS agent session; two were engine-side.
- Reporting round: ScoutCoder checkout
  `research/path-kind-contract-fixes.md` (round 11, 2026-10-22) — fixed
  its four client-side items, REPORTED fixes 3 and 5 out with
  fresh-process reproductions (`tmp/path-kinds-contract-fixes/logs/...`
  in that checkout). This engine round discharges exactly those two
  reported items, with the same contracts the report stated.
- Earlier rounds of the client line are named in that note (rounds 8/9,
  9, 10) and are not engine-side.

## Open items

1. The five pre-existing ScoutCoder failures/errors deserve re-baselining
   by that checkout's owner: three are sandbox-grant environmental
   (outside_grants), two follow from them or from that suite's
   expectations (`test_task_smoke_constructs_job_without_executing`,
   `test_run_test_suite_discovers_both_sides_and_empty_is_error`). They
   predate this round and are unchanged by it, but they mask any future
   client regression signal in `test_path_kinds.rb`.
2. The guard-versus-missing-implementation ordering in
   `path_kind_operation` (the root-selector rejection sits after the
   "no validate/smoke implementation" raise, where path resolution always
   was) is incidental and deliberately unpinned; if anyone wants the
   opposite precedence, that is a deliberate contract decision to make
   explicitly, not a bug.
3. The drive-by paragraph deduplication in PathEngine.md section 9 could
   be split out into its own change if a reviewer prefers a pure
   fixes-only diff.
4. Nothing is committed anywhere: the engine changes live as working-tree
   edits at HEAD `ee9c90c0752d7ada7f715313f3e762bc8ffca117` (plus three
   pre-existing uncommitted edits from earlier rounds in
   `lib/scout/llm/agent.rb`, `lib/scout/llm/agent/delegate.rb`,
   `lib/scout/llm/chat/process/tools.rb`, untouched by and unrelated to
   this round), and the ScoutCoder checkout keeps its own uncommitted
   client-round state at HEAD `bab41ebfd8eeb1d68c538e9569f0f1c01d1e2c77`.
