# Scout-AI runtime availability — status note (research layer)

**Scope:** what the runtime-availability workstream investigated, what is
now established in the committed tree, and what remains open. This is the
research-layer rationale and open-question record; operational contracts
live in `doc/`, not here.

**Status:** ESTABLISHED (committed). `test/support/availability.rb` now
delegates Python/R probes to Scout-Rig (`ScoutRig::Testing::Availability`,
`scout-rig` >= 0.2.6) which itself requires Scout-Essentials
`scout/testing/availability` — commit `2ef066c` ("Delegate test
availability probes to scout-rig and scout-essentials", 2026-10-18).
Scout-AI retains its own `cuda?` (torch + usable CUDA device via
Scout-Rig's embedded-interpreter selection) and `hf_model_cached?`
(cache-only HF checks honoring `HF_HOME`/`HF_HUB_CACHE`, no HTTP); endpoint
reachability stays a TCP-only check and endpoint configuration stays
local. The original probe plan this note supersedes is
`research/scout-ai-runtime-availability-handoff.md` (Cortex, 2026-10-11) —
see "Provenance" below; the durable facts from it are restated here rather
than referenced.

## Transitive Scout-Essentials require — current truth

The old framing ("don't claim installed-consumer support until the
transitive Scout-Essentials require is available in a reproducible package
setup") is now **largely satisfied**: `scout-ai.gemspec` depends on
`scout-rig` (>= 0), and `scout-rig` 0.2.6's own gemspec lists
`scout-essentials (> 0)` as a runtime dependency, so `gem install scout-ai`
resolves both transitively. Verified against installed gem specifications,
not just source checkouts.

Remaining caveat (the residual truth of the warning): the local test setup
also relies on `RUBYOPT` carrying `-I` paths into the `~/git` checkouts
(see `tmp/notes/availability-workstream.md`, gitignored — see "Provenance"
below), so **checkout-based runs may still load a different
scout-essentials than the installed 1.9.1 the code was verified against**.
A clean-environment (`gem-installed-only`) run has not been executed; until
one is, treat "transitive require works in a bare install" as strongly
evidenced but not directly exercised.

## Open questions

1. Does the full suite pass in a clean environment with only the installed
   gems (no `RUBYOPT` checkout overrides)? Record counts vs the baseline in
   `tmp/notes/cleanup/disposition.md` §7.
2. `hf_model_cached?` honoring of `HF_HUB_CACHE` vs `HF_HOME` precedence —
   unit-tested locally, but no probe against a real populated cache has
   been recorded.
3. R-runtime probes are Scout-Rig-delegated only; no scout-ai test
   exercises an R route (acknowledged no-implied-coverage in
   `test/support/availability.rb`'s header comment).

## Provenance

- Cortex handoff (pre-implementation): `research/scout-ai-runtime-availability-handoff.md`
  (Cortex store map `current`, 2026-10-11) — investigated only; it must not
  be cited as implementation evidence (its own header says so).
- Implementation: commit `2ef066c` (files: `test/support/availability.rb`,
  test files updated in the same commit), building on the earlier
  mock-isolation groundwork `71c9df6` (2026-08-21, two months before).
- Ephemeral probe scratch: `tmp/notes/availability-workstream.md`,
  `tmp/notes/availability_probe.{rb,out}`, `tmp/notes/python-prereq-audit.md`
  — **`tmp/` is gitignored ephemeral scratch**; this note carries the
  durable facts itself precisely so they do not depend on those files
  surviving. Do not cite `tmp/notes/*` as durable evidence.
