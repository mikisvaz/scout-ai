# Path engine fixes DC-1 / DC-2 / DC-3 — consolidated report

Date: 2026-10-23. Checkout: scout-ai at `/bulk/mvazque2/git/scout-ai`
(same repository as `/home/mvazque2/git/scout-ai`), HEAD `37195515`,
nothing committed. All changes are uncommitted working-tree edits;
disposable evidence lives under `tmp/dc-fixes/` in this checkout.
Methodology follows `research/path-kind-contract-fixes-engine.md`
(probe scripts under `tmp/…/probes/`, before/after JSON logs under
`tmp/…/logs/`, suites run before and after, all in fresh processes).

## Overview

Three defects in the Scout workflow Path kinds engine
(`lib/scout/llm/agent/path.rb`, `lib/scout/llm/agent/path/edit.rb`),
labeled DC-1/DC-2/DC-3, were identified during the ScoutCoder round-12
"auto-run on write" investigation in the ScoutCoder checkout and
source-confirmed in this checkout's HEAD during step 1 of this round.
The user explicitly authorized fixing them in this checkout. The
engagement ran as a 7-step plan (recon + red reproduction; DC-1 fix;
DC-2 fix; DC-3 doc amendment; full fresh-process validation; Critic
gate with two producer-defect repairs; consolidated report — this
file). The Critic gate returned NEEDS_WORK (86) on two producer
defects (one doc contradiction, one evidence-durability failure), both
were repaired, and the re-gate returned PASS (96) with no residual
defect and no next action.

Defect set, confirmed against HEAD `37195515` (line numbers as
measured then; step-1 anchor list in `tmp/dc-fixes/recon.md`):

- **DC-1** — operation overrides were accepted at registration for ANY
  of the ten built-in operations, but only `edit` and `patch` ever
  consulted the operation table. A `write` (and equally
  `read`/`list`/`move`/`rename`/`delete`) override was stored and then
  never dispatched: `path_write` never called
  `path_operation_implementation`, so the engine default silently ran.
  Anchors: `path_normalize_operation_overrides` (path.rb:630 at step 1,
  discarding any declared `type`), `path_operation_table` (437,
  hardcoding `"type" => :full` for override entries), `path_write`
  (1357), `path_operation_implementation` (621).
- **DC-2** — edit overrides: the declared handler `type` was silently
  dropped at normalization; `path_edit` (edit.rb:161, override consult
  at 176) always routed through `path_apply_content_handler`
  (path.rb:1242), which calls `handler.call(original, args)` — a
  3-arity `:full`-intended handler raised `ArgumentError` (given 2,
  expected 3) — and then `result.end_with?("\n")`, so a Hash return
  raised `NoMethodError` that ESCAPED `path_install_tool`'s
  ScoutException-only rescue (~863) and left the agent tool boundary as
  a raw exception. Side behavior: under a `:content` edit override,
  `selector`/`replacement` were argument-validated but silently never
  applied.
- **DC-3** — `doc/developer/PathEngine.md` §5 (~245, call-shape text
  ~299), §6 (~310) and §9 (~421) read as if overrides were honored per
  built-in operation, which the code did not do.

A consumer scan (step 1) found ZERO override declarations in any
installed scout gem (1.1.6–2.1.0, camp, essentials, gear, rig, web), in
sibling checkouts, or in this repository outside the engine itself —
so tightening the override surface could break no live consumer.

## DC-1 — write overrides now dispatch, type-aware; dead overrides reject loudly

**Defect.** `path_write` never consulted the override table (DC-1 above).

**Decision.** Dispatch, not reject, for `write`: the override mechanism
is the engine's sanctioned way to replace a built-in implementation
without changing its public tool schema, and a working write override
is exactly what a workflow wants for mediated writes (the round-12
"auto-run on write" revisit path). Built-ins with no dispatch path —
`read`, `list`, `move`, `rename`, `delete`, `validate`, `promote`,
`smoke` — now REJECT loudly at registration with a `ParameterException`
naming the supported set (`write`, `edit`, `patch`) and pointing the
customizable ones at their existing hook mechanisms (`"list"` via the
`"list"` definition key; `"validate"`/`"smoke"` via the
`"validate"`/`"smoke"` definition keys dispatched by
`path_kind_operation`; `"promote"` via `"promotion_destination"` /
`"promotion_post_move"`). Hooks are a separate mechanism and keep
working — the rejection set was settled from the source dispatch graph,
not by disabling hooks.

**Implementation** (`lib/scout/llm/agent/path.rb`):
`path_normalize_operation_overrides` preserves and validates the
override's declared `type` against `PATH_HANDLER_TYPES`
(`:content`/`:full`), defaulting to `:content` when absent;
`path_operation_table` stores the declared per-override type (engine
defaults come from `BUILTIN_DEFAULT_HANDLER_TYPES`); per-operation
supported types live in `OVERRIDE_HANDLER_TYPES` (write and edit
`[:content, :full]`, patch `[:content]` only) with the overridable set
in `OVERRIDE_DISPATCH_OPERATIONS`. `path_write` dispatches AFTER
`path_authorize!`:

- `:content` — `handler(content, args)` returns a String (non-String →
  `ParameterException` naming the contract); the engine writes that
  string through the normal write path; result shape unchanged
  (`{doc_id, kind, path, location, target_file, written}`).
- `:full` — `handler(agent, target, args)` with the resolved, authorized
  target; the handler performs the write itself; returns a Hash payload
  (non-Hash → `ParameterException`). Canonical keys
  (`doc_id/kind/path/location/target_file/written`) are
  engine-authoritative — a handler attempt to set one is ignored — and
  other payload keys merge additively. `written`/`target_file` reflect
  verified reality (existence at the authorized target), honoring the
  sandbox pin that write success is at the authorized target.

Authorization failure invokes no handler, either type.

## DC-2 — type-aware edit dispatch; return-shape guards; selector-bypass pinned

**Defect.** See DC-2 above.

**Decision.** Same type-aware dispatch for `path_edit`
(`lib/scout/llm/agent/path/edit.rb`), reusing the step-2 plumbing:

- `:content` stays today's `(content, args)` transform; its String
  return contract is now enforced (the guard lives in
  `path_apply_content_handler`, shared with write/patch), and the
  returned content is written by the engine exactly as before.
- `:full` — `handler(agent, target, args)` returns a Hash payload
  (non-Hash → `ParameterException` envelope); edit's canonical result
  shape (`{doc_id, kind, path, changed, content}`) is preserved — no
  shape normalization across operations — with engine-authoritative
  canonical keys and additive payload merge, and `content`/`changed`
  read back from the authorized target (verified reality) rather than
  trusting the handler's claim.

The **selector-bypass semantics were kept and made explicit**: under a
`:content` edit override, `selector`/`replacement` remain validated
(the tool schema requires them) but are NOT applied; the handler's
returned content IS the edited file. This is pinned by a test and
stated in the doc, rather than changed — the alternative (applying a
selector to handler output) would give the handler two interacting
editing mechanisms and no way to opt out.

**Alternatives considered and rejected.** `patch :full` was rejected at
registration ("patch dispatches its override as a content transform"):
`patch` is a strict unified-diff applier whose engine loop reads,
applies hunks with strict context verification, and writes once at the
authorized target; a `:full` patch override would bypass exactly that
verification, so patch keeps `:content` only. Making `path_edit` shape
itself like `path_write`'s result was rejected: shapes are
operation-specific and pinned by existing tests.

## DC-3 — documentation states the implemented contract

`doc/developer/PathEngine.md` §5 now states the overridable set
(write/edit/patch), the per-operation type table, the default type,
the loud rejection with hook pointers, the real call shapes (`:content`
`(content, args)` → String; `:full` `(agent, target, args)` → Hash
payload with engine-authoritative canonical keys, additive merge, and
verified-reality results), the authorization-before-handler ordering,
and the pinned selector-bypass semantics. §6's registration-validation
list gained the two new rejections. §9 scopes "handlers must normalize
their own failures" to custom-operation handlers and states the
engine's own guards (non-String `:content` / non-Hash `:full` →
`ParameterException` envelope, never a raw escape); its pin list was
extended. The Critic found one contradiction in the new §5 text
("promote has no customization surface" vs the document's own hook
list) — corrected to name the `promotion_destination` /
`promotion_post_move` hooks before the re-gate. Every behavioral
sentence in the amended sections is backed by a named green test or a
probe log (the backing map is in the step-4 record inside
`tmp/dc-fixes/recon.md`'s history and the section text itself cites the
pin lists).

## Changed files (measured `git diff --numstat` at close)

| file | + | − |
|---|---|---|
| `lib/scout/llm/agent/path.rb` | 130 | 6 |
| `lib/scout/llm/agent/path/edit.rb` | 43 | 11 |
| `test/scout/llm/agent/test_path.rb` | 176 | 0 |
| `test/scout/llm/agent/test_path_edit.rb` | 147 | 0 |
| `doc/developer/PathEngine.md` | 74 | 13 |

(`.vimproject` +2/−0 is a pre-existing local edit, not part of this
work.) Tests are purely additive; no existing test was modified.

## Evidence

All disposable evidence is under `tmp/dc-fixes/` in this checkout:

- **Probes** (`probes/`, one fresh Ruby process each):
  `dc_common.rb` (harness) plus `a1_write_override.rb` (write override
  dead at HEAD), `a2_default_write.rb` (control), `b4_edit_full_type.rb`
  (`:full` edit arity), `b3_edit_hash_return.rb` (Hash return escape),
  and `step5_smoke_kinds.rb` (installed-kinds registration + round-trip
  smoke). The harness selects the engine with `DC_ENGINE`
  (`pristine` → `tmp/dc-fixes/pristine/lib`, a snapshot extracted with
  `git archive HEAD lib` and byte-verified against
  `git show HEAD:lib/scout/llm/agent/path.rb`; `checkout` → the
  working tree) and the log mode with `DC_MODE` (`before`/`after`);
  mode and engine are cross-checked and overwriting an existing
  `before-` log is refused, so the step-6 evidence clobber cannot recur.
- **Logs** (`logs/`): `before-*.json` regenerated against the pristine
  snapshot (step-6 repair) carrying genuine red outcomes
  (`engine: pristine`; a1 handler never fires / `defect_reproduced:
  true`; a2 `control_holds: true`; b4 `ArgumentError given 2 expected
  3`; b3 raw `NoMethodError` through the tool callable);
  `after-*.json` re-run on the fixed tree (`engine: checkout`; a1
  handler fires through engine and tool callable; a2 control holds; b4
  3-arity works, String-returning probe lambda now yields the proper
  `ParameterException`; b3 Scout error envelope, no raw escape);
  interim `step2-after-*` / `step3-after-*`; `step5-smoke-kinds.json`
  (`ok: true`).
- **Recon** (`recon.md`): step-1 anchors and dispatch-set grep, consumer
  scan, probe inventory; step-5 validation appendix (probe table, suite
  counts, smoke outcomes, git delta); step-6 repairs appendix.

**Tests.** `test/scout/llm/agent/test_path.rb` (83 tests / 634
assertions, 0 failures / 0 errors; includes the 9-test "Step 2 (DC-1)"
block: `write_content_override_transforms_content_and_keeps_result_shape`,
`write_content_override_default_type_is_content`,
`write_full_override_fires_with_agent_target_and_args`,
`write_full_override_non_string_return_is_parameter_error`,
`write_full_override_non_string_return_serializes_through_tool`,
`write_override_invalid_type_rejected_at_registration`,
`patch_full_override_rejected_at_registration`,
`override_on_non_dispatching_builtin_rejected_at_registration`,
`write_override_authorization_failure_runs_no_handler`).
`test/scout/llm/agent/test_path_edit.rb` (46 / 133, 0 / 0; includes the
5-test "Step 3 (DC-2)" block:
`full_edit_override_fires_with_agent_target_and_args`,
`full_edit_override_non_hash_return_is_parameter_error_envelope`,
`content_edit_override_receives_content_and_args_and_writes_string`,
`content_edit_override_selector_replacement_not_applied`,
`full_edit_override_authorization_failure_runs_no_handler`).
Unchanged and green: `test_path_errors.rb` 15/281,
`test_path_filesystem.rb` 33/68 (incl.
`test_path_write_success_is_at_the_authorized_target`),
`test_path_patch.rb` 11/32, `test_path_promotion.rb` 19/79,
`test_path_workflow_integration.rb` 21/68; neighbors
`test/scout/llm/test_sandbox.rb` 16/57 and `test_agent.rb` 1/2.
Pre-existing pins
(`test_dispatch_edit_override_authorization_failure_runs_no_override`)
remain green.

**Critic gates.** First gate: NEEDS_WORK (86) — engine changes
independently verified sound (pristine-HEAD red reproduction, full
suites, invariant and hygiene checks pass); two producer defects only:
(1) the §5 promote sentence contradicted the document's own hook list
and `path.rb`'s `definition["promotion_post_move"]`; (2) the
`before-*.json` logs had been clobbered by a post-fix rerun and were
byte-identical to their after twins (impossible content at HEAD). Both
repaired (sentence reworded; before-logs regenerated against the
byte-verified pristine snapshot; `DC_MODE`/`DC_ENGINE` clobber guards
added). Re-gate: PASS (96), no residual defect, no next action.

## Verification status per claim

- Dispatch of write/edit overrides, both types, with the documented
  call shapes and return contracts — **validated** (the 14 new tests,
  all suites, and the after-probes) and **independently reviewed**
  (Critic re-gate reran the suites and the pristine-HEAD red
  reproduction).
- Loud rejection set and hook pointers — **validated**
  (`test_override_on_non_dispatching_builtin_rejected_at_registration`,
  message content) and **independently reviewed**.
- No live consumer broken — **validated** (consumer re-grep at step 5:
  only engine sources declare `"overrides"`) and **independently
  reviewed**.
- Documentation matches implementation — **validated** (doc-cites-green
  pass at step 4; corrected sentence at step 6) and **independently
  reviewed** (re-gate PASS).
- Evidence integrity (before/after provenance) — **validated** at step
  6 (regeneration method byte-verified) and **independently reviewed**;
  the earlier clobber is recorded honestly in `tmp/dc-fixes/recon.md`.

## Closing note

DC-1, DC-2 and DC-3 are resolved. The round-12/13 historical documents
and the ScoutCoder checkout were not touched (the original round-12
note and its evidence files were never reachable from this sandbox and
were re-derived here from source anchors). Nothing was committed,
pushed or merged: the work exists as local working-tree diffs on
branch `dc-fixes` (five files, measured numstat above), additive tests,
the amended doc, the disposable evidence tree under `tmp/dc-fixes/`,
and this report. Auto-run-on-write remains retired (round-12 outcome
C) and is now expressible as a `:full` write override should that
revisit path ever be taken — recorded here as a fact, not a design
commitment.
