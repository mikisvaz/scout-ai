# Sandbox: which tools are confined, and which paths they can reach

This document answers the three sandbox questions agents keep asking: *is
this tool sandboxed?*, *which paths can this action reach?*, and *this path
exists but I cannot see it — what now?*. It explains how path access and
confinement work across Scout-AI tools, with particular attention to
Workspace's two distinct enforcement mechanisms: Ruby-layer path
authorization and OS-level confinement through bwrap. Not every tool uses
both mechanisms, and some tools do not apply these path checks at all. The
asymmetry between the layers is intended, not a bug.

**When access fails**, identify the exact tool first. Run `sandbox_paths`
when available, inspect the relevant grants and mounts, use the path
spelling exposed inside the sandbox, and retry through the tool you actually
need. Never infer a tool's permissions from another tool's success or
failure.

The original evidence base for this document was a labeled-claims facts
sheet (`research/sandbox-docs-facts.md`, built 2026-10-08..2026-10-17: 63+
labeled claims tagged `[code file:line]` or `[probe ...]`, with three dated
correction rounds). That sheet was retired 2026-10-19 once its verified
content was fully absorbed into this document and Layer-1 was re-verified
against the grant-source refactor; a copy survives at
`tmp/notes/cleanup/retired-sandbox-docs-facts.md` (tmp/ is gitignored
scratch — a pointer for anyone holding that checkout, not a durable
reference). The one still-unresolved item from the sheet is tracked in
[Improvements.md](../Improvements.md) R14. Line references below
re-verified 2026-10-17.

## 1. Is this tool sandboxed?

`LLM::Sandbox` (`lib/scout/llm/sandbox.rb`) provides two conceptually
separate interfaces.

The **containment core** — `resolve_path` (:14), `authorize_path` (:76),
`inside?` (:103) — resolves paths and checks them against grants supplied by
the caller. It does not decide which grant sources a particular tool should
use, and `authorize_path` defaults `root: Dir.pwd`, an ambient default that
callers (such as Workspace) must override deliberately.

The **shared grant-resolution layer** — `grant_type_defaults` (:122),
`grant_scope_tokens` (:138), `grant_paths` (:150), `expand_grant_path`
(:163), `writable_grants` (:169), `readable_grants` (:175),
`grant_origin` (:187), `describe_grants` (:218) — resolves configured grant
sources, applies defaults and environment overrides, and collects
thread-local grants. Individual tools use this layer to assemble their
effective grants, then enforce access according to their own execution
model.

Grant resolution, path authorization and OS-level confinement are separate
concerns. Using the shared grant resolver does not, by itself, sandbox a
tool. The grant-registration helpers (`allow_path` :230,
`allow_read_path` :237, `allow_job` :244, `allow_read_job` :250) only write
the pre-existing `Chat` thread-local keys that the resolution layer
collects.

Which enforcement a tool gets is a per-tool property:

| Tool / action | Sandboxed? | Enforcement point |
|---|---|---|
| Workspace `read`/`write`/`delete`/`search`/`list_directory`/`file_stats`/`copy` | Ruby allowlist | filesystem.rb `helper :normalize` :25-47; task bodies :141-:445 (`write` :141, `read` :157, `list_directory` :248, `file_stats` :291, `delete` :366, `copy` :390, `search` :420) |
| Workspace `precise_edit` | Ruby allowlist (`:write`) | precise_edit.rb:18 |
| Workspace `pwd`, `sandbox_paths` | No enforcement (read-only introspection) | filesystem.rb (`task :sandbox_paths` :316, `task :pwd` :352, exported :447) |
| Workspace `patch` | bwrap OS sandbox only (no Ruby-layer normalize) | patch.rb:309-314 (`Dir.chdir(Workspace.root)` then `cmd_json`) |
| Workspace `tsv_*` | No Ruby-layer check | tsv.rb (opens files via Scout `TSV`/`Open` directly) |
| Workspace `bash`/`python`/`ruby`/`r` | bwrap OS sandbox only | exec.rb `cmd_json` :698, `sandbox_run` :534 |
| scout-ai agent `path_*` tools | Yes, when the kind sets `sandbox: true` (the engine default) | path.rb `path_authorize!` :1148-1176 |
| scout-ai `LLM::Agent` / workflow / call tools | Grant registration, not confinement | agent.rb:113 (`Chat.allow_job`), tools/workflow.rb:170, call.rb:192/217, agent/workflow.rb:178 |
| ChatAnalyst-style tasks (`Chat.read`, `LLM.call_workflow`) | No `LLM::Sandbox` path authorization in the inspected task code (verified: no `LLM::Sandbox`/`allow_*` references under `ChatAnalyst/lib/` or `workflow.rb`). Do not assume these tasks are confined without checking their execution environment. | none identified |

The asymmetry is intended: each tool has its own capability and permission
model. A restriction observed with one tool is **not evidence** about
another — a `read` rejection tells you nothing about `bash`, and an exec
success tells you nothing about `write`. When a path is rejected or a
visibility mismatch appears, diagnose the specific tool involved.

## 2. Which paths can this action reach?

There are two layers, and they differ on purpose.

**Layer 1 — Ruby allowlist (Workspace filesystem tasks).** All filesystem
tasks route through `helper :normalize`, which calls
`LLM::Sandbox.authorize_path` with `root: Workspace.root`,
`writable_paths: Workspace.allowed_paths`,
`read_paths: Workspace.allowed_read_paths`, `base_path: Dir.pwd`, and raises
`SandboxAccessViolation` on denial (filesystem.rb:25-47). The grant lists
are composed by the shared grant-resolution layer
(`LLM::Sandbox.writable_grants(scope: 'Workspace')` /
`readable_grants(scope: 'Workspace')`), to which `Workspace.allowed_paths`
and `Workspace.allowed_read_paths` simply delegate (filesystem.rb:3-16;
`get_allowed_paths` :3, `allowed_paths` :10, `allowed_read_paths` :14).
`Workspace.get_allowed_paths(type)` delegates to the same layer
(`LLM::Sandbox.grant_paths`). Any other sandboxed workflow can adopt the
identical vocabulary by calling the same functions with its own scope.

The two grant sets compose these sources:

| Grant set | Sources |
|---|---|
| Writable | `allowed_paths`, `dirs`, `thread` |
| Readable | `allowed_read_paths`, `exec_paths`, `read_paths`, `thread_read` |

Seven source categories in total. Two carry non-empty literal defaults in
`grant_type_defaults` (sandbox.rb:122-132): `exec_paths` defaults to
`/bin:/usr:/lib:/lib64:/etc`, and `allowed_paths` defaults to the Scout
pathmap expansion of `tmp` plus `/tmp` and `~/tmp`. `thread` and
`thread_read` read the live Chat thread keys (the same keys
`allow_path`/`allow_read_path` write; empty until something registers a
grant). `dirs`, `read_paths` and `allowed_read_paths` default to empty,
meaning they contribute nothing unless configured. Every source is
overridable through `Scout::Config`
under the workflow scope tokens (`grant_scope_tokens`, sandbox.rb:138-142)
or an env var such as `ALLOWED_PATHS`
(the key name upper-cased); a scoped config entry beats the env var, which
in turn beats the default.

Two introspection helpers round out the layer: `grant_origin(path, scope:,
root:)` (sandbox.rb:187-216) reports which source category an expanded path
came from, by expanded-spelling equality over the full origin vocabulary
(`root`, `dirs`, `allowed_paths`, `thread`, `exec_paths`, `read_paths`,
`allowed_read_paths`, `thread_read`, `bwrap_paths`, `bwrap_read_paths`),
returning `nil` for unlisted paths; and `describe_grants(scope:, root:,
hint:)` (:218-229) renders one annotated line per grant — writable entries
marked `(read-write)`, remaining readable entries `(read-only)`, with the
caller's `hint` appended verbatim as the last line. `scope: nil` degrades
the token chain to `['sandbox']` (sandbox.rb:145-148); `expand_grant_path`
(:163-167) expands located spellings in place and resolves unlocated Scout
spellings (such as `tmp`) through `Path#find_all`.

`Workspace.root` is **not** part of that composition: it is supplied as the
separate `root:` boundary of `authorize_path`, which is why it appears
separately in the diagnostics.

**Layer 2 — bwrap OS sandbox (Workspace exec tasks).** `sandbox_run` starts
from the same two lists but is strictly broader (exec.rb:534-594): writable
gains `Workspace.root` unconditionally (:560-569) plus optional config
`bwrap_paths` (:554); read gains optional `bwrap_read_paths` (:555),
`/etc/resolv.conf` when networking is enabled (:578), the runtime
directories of the resolved interpreter (:587), and relocatable runtime
layouts scanned from `$PATH` (:590). Each grant becomes a bind mount planned
from its expanded spelling
(`plan_mounts`, exec.rb:77-95: `File.expand_path` for the destination,
`safe_realpath` for the source), plus `/tmp`, `/proc` and `/dev`.

**Concrete consequence.** A path readable from `bash` can be rejected by
`read`, and that is expected: the exec layer sees the interpreter's runtime
tree through runtime-dir grants the Ruby read allowlist does not carry. The
reverse also happens — a path granted by the allowlist can be bound
read-only inside bwrap. Run the Workspace `sandbox_paths` task for the exact
inventory of both layers: every allowed read/write path with its origin, the
planned mounts (source, destination, ro/rw, redirect), and the realized
mounts from `/proc/mounts` (`task :sandbox_paths` filesystem.rb:316;
`realized_mounts` helper :126).

## 3. This path exists but I cannot see it — what next?

1. **Run the Workspace `sandbox_paths` diagnostic and read the origins.** It
   reports both layers, so you can tell "not granted at all" from "granted
   but not mounted". Denial messages from `normalize` already point at it
   ("Run task 'sandbox_paths' for details").
2. **Prefer the granted spelling in sandboxed execution environments.**
   Ruby-layer authorization resolves existing path components to canonical
   paths (see `resolve_path` below), whereas bwrap mount destinations are
   based on expanded grant spellings: `plan_mounts` uses the expanded grant
   as the mount *destination* and realpaths only the *source*
   (`safe_realpath` helper, exec.rb:24; mounts built at :77-95),
   so two spellings of one host directory may be equivalent for
   authorization but not equally visible inside the execution sandbox — and
   a spelling that was never granted gets no mount at all. On hosts that
   alias `/home/user/...` with `/bulk/user/...`, a directory can be fully
   visible under one spelling and `ENOENT` under the other (recorded
   divergence probe in the facts sheet §3). When a mount destination
   traverses a symlink whose parent is already mounted, the destination is
   redirected to the realpath — `m.destination = m.source` — and the plan
   records `redirect: true` (`destination != requested_path`,
   exec.rb:97-134; the symlink target is additionally mounted read-only so
   the host symlink still resolves, exec.rb:137-175).
3. **In exec tools, `cd` to the granted root** (e.g. the `root` field
   reported by `sandbox_paths`) rather than a spelling that has no mount.
4. **Re-check with the specific tool you actually need.** The layers differ,
   so the definitive answer is the behavior of that one tool, not of a
   proxy: verify with the `read`/`write` task, or with `bash`, as
   appropriate.

### `resolve_path` semantics and TOCTOU

`LLM::Sandbox.resolve_path` walks component by component (sandbox.rb:14-68):
each existing component is `File.realpath`-ed, so symlinks collapse to
physical paths; `.` is skipped; the first *missing* component switches the
walk to lexical mode, after which `exists` stays false and later components
are appended unresolved. It fails closed on the unresolvable cases: a `..`
reached after a missing component returns `exists: false,
canonical_path: nil`; `..` after a non-directory raises `ENOTDIR`; a
dangling symlink or an `ENOTDIR`/`EACCES` on an existing parent surfaces the
error instead of treating the path as lexical space. Both the target and
every grant are resolved this way in `authorize_path`, so a symlink cannot
make a grant escape its physical target, and the boundary-aware `inside?`
rejects sibling prefixes (`/a-b` is not inside `/a`) (`authorize_path`
sandbox.rb:76-99, `inside?` :103-105).

Authorization is **policy, not an atomic capability**: it applies to a path
spelling at check time. Nothing prevents the filesystem from changing between
the check and the operation (see the same limitation recorded for the Path
engine's advisory existence checks, path.rb:1521-1523). TOCTOU hardening is
explicitly out of scope.

## Sources / verification

Every factual claim above originally traced to the retired
`research/sandbox-docs-facts.md` (final count 63 labeled claims: 37
`[code file:line]`, 22 `[probe]`, 4 `[unverified]`), whose line anchors
were spot-checked against the live checkouts on 2026-10-16; two drifts
were appended as dated corrections there before this document was
written, and further dated corrections (2026-10-17) record the
grant-source refactor's moved anchors and the ChatAnalyst positive check
— both already folded into the line references above. The durable facts
live in this document; the sheet itself was retired 2026-10-19 (copy at
`tmp/notes/cleanup/retired-sandbox-docs-facts.md`, gitignored scratch).
Its `[unverified]` items were label recounts plus the Workspace
`test_tsv.rb` failure's history; that failure's pre-existence (identical
failure with the grant refactor reverted) was established 2026-10-17 and
is recorded in Improvements.md R14 and R17.
