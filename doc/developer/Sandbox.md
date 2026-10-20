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

See [Improvements.md](../Improvements.md) R14 for the one still-open item (the Workspace `test_tsv.rb` failure history).

## 1. Is this tool sandboxed?

`LLM::Sandbox` (`lib/scout/llm/sandbox.rb`) provides two conceptually
separate interfaces.

The **containment core** — `resolve_path` (`LLM::Sandbox#resolve_path`),
`authorize_path` (`#authorize_path`), `inside?` (`#inside?`) — resolves
paths and checks them against grants supplied by the caller. It does not
decide which grant sources a particular tool should use, and
`authorize_path` defaults `root: Dir.pwd`, an ambient default that callers
(such as Workspace) must override deliberately.

The **shared grant-resolution layer** — `grant_type_defaults`,
`grant_scope_tokens`, `grant_paths`, `expand_grant_path`, `writable_grants`,
`readable_grants`, `grant_origin`, `describe_grants` (all
`LLM::Sandbox.<name>`, `lib/scout/llm/sandbox.rb`) — resolves configured
grant sources, applies defaults and environment overrides, and collects
thread-local grants. Individual tools use this layer to assemble their
effective grants, then enforce access according to their own execution
model.

Grant resolution, path authorization and OS-level confinement are separate
concerns. Using the shared grant resolver does not, by itself, sandbox a
tool. The grant-registration helpers (`allow_path`, `allow_read_path`,
`allow_job`, `allow_read_job`) only write the pre-existing `Chat`
thread-local keys that the resolution layer collects.

Which enforcement a tool gets is a per-tool property. Line anchors below
point into the Workspace workflow (a separate repository), so treat the
file names as stable identifiers and re-grep the method when the line
drifts:

| Tool / action | Sandboxed? | Enforcement point |
|---|---|---|
| Workspace `read`/`write`/`delete`/`search`/`list_directory`/`file_stats`/`copy` | Ruby allowlist | filesystem.rb `helper :normalize` and the task bodies (`write`, `read`, `list_directory`, `file_stats`, `delete`, `copy`, `search`) |
| Workspace `precise_edit` | Ruby allowlist (`:write`) | precise_edit.rb (`task :precise_edit`) |
| Workspace `pwd`, `sandbox_paths` | No enforcement (read-only introspection) | filesystem.rb (`task :sandbox_paths`, exported `task :pwd`) |
| Workspace `patch` | bwrap OS sandbox only (no Ruby-layer normalize) | patch.rb (`Dir.chdir(Workspace.root)` then `cmd_json`) |
| Workspace `tsv_*` | No Ruby-layer check | tsv.rb (opens files via Scout `TSV`/`Open` directly) |
| Workspace `bash`/`python`/`ruby`/`r` | bwrap OS sandbox only | exec.rb (`cmd_json`, `sandbox_run`) |
| scout-ai agent `path_*` tools | Yes, when the kind sets `sandbox: true` (the engine default) | path.rb `path_authorize!` |
| scout-ai `LLM::Agent` / workflow / call tools | Grant registration, not confinement | agent.rb (`Chat.allow_job`), tools/workflow.rb, tools/call.rb, agent/workflow.rb |
| ChatAnalyst-style tasks (`Chat.read`, `LLM.call_workflow`) | No `LLM::Sandbox` path authorization in the inspected task code (no `LLM::Sandbox`/`allow_*` references under `ChatAnalyst/lib/`). Do not assume these tasks are confined without checking their execution environment. | none identified |

**Tests:** `test/scout/llm/test_sandbox.rb` pins the core semantics —
`test_authorization_uses_root_and_nested_boundary_not_sibling_prefix`,
`test_grant_sources_compose_defaults_thread_and_config`,
`test_grant_scope_tokens_and_expand` among its 16 cases.

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
`SandboxAccessViolation` on denial (filesystem.rb `helper :normalize`). The
grant lists are composed by the shared grant-resolution layer
(`LLM::Sandbox.writable_grants(scope: 'Workspace')` /
`readable_grants(scope: 'Workspace')`), to which `Workspace.allowed_paths`
and `Workspace.allowed_read_paths` simply delegate (`get_allowed_paths`,
`allowed_paths`, `allowed_read_paths`).
`Workspace.get_allowed_paths(type)` delegates to the same layer
(`LLM::Sandbox.grant_paths`). Any other sandboxed workflow can adopt the
identical vocabulary by calling the same functions with its own scope.

The two grant sets compose these sources:

| Grant set | Sources |
|---|---|
| Writable | `allowed_paths`, `dirs`, `thread` |
| Readable | `allowed_read_paths`, `exec_paths`, `read_paths`, `thread_read` |

Seven source categories in total. Two carry non-empty literal defaults in
`grant_type_defaults`: `exec_paths` defaults to
`/bin:/usr:/lib:/lib64:/etc`, and `allowed_paths` defaults to the Scout
pathmap expansion of `tmp` plus `/tmp` and `~/tmp`. `thread` and
`thread_read` read the live Chat thread keys (the same keys
`allow_path`/`allow_read_path` write; empty until something registers a
grant). `dirs`, `read_paths` and `allowed_read_paths` default to empty,
meaning they contribute nothing unless configured. Every source is
overridable through `Scout::Config` under the workflow scope tokens
(`grant_scope_tokens`), or an env var such as `ALLOWED_PATHS` (the key name
upper-cased); a scoped config entry beats the env var (the env var only
replaces the *default*), which in turn beats the built-in default.

Two introspection helpers round out the layer: `grant_origin(path, scope:,
root:)` reports which source category an expanded path came from, by
expanded-spelling equality over the full origin vocabulary (`root`, `dirs`,
`allowed_paths`, `thread`, `exec_paths`, `read_paths`, `allowed_read_paths`,
`thread_read`, `bwrap_paths`, `bwrap_read_paths`), returning `nil` for
unlisted paths; and `describe_grants(scope:, root:, hint:)` renders one
annotated line per grant — writable entries marked `(read-write)`, remaining
readable entries `(read-only)`, with the caller's `hint` appended verbatim
as the last line. `scope: nil` degrades the token chain to `['sandbox']`;
`expand_grant_path` expands located spellings in place and resolves
unlocated Scout spellings (such as `tmp`) through `Path#find_all`.

`Workspace.root` is **not** part of that composition: it is supplied as the
separate `root:` boundary of `authorize_path`, which is why it appears
separately in the diagnostics.

**Layer 2 — bwrap OS sandbox (Workspace exec tasks).** `sandbox_run` starts
from the same two lists but is strictly broader (exec.rb): writable gains
`Workspace.root` unconditionally plus optional config `bwrap_paths`; read
gains optional `bwrap_read_paths`, `/etc/resolv.conf` when networking is
enabled, the runtime directories of the resolved interpreter, and
relocatable runtime layouts scanned from `$PATH`. Each grant becomes a bind
mount planned from its expanded spelling (`plan_mounts`:
`File.expand_path` for the destination, `safe_realpath` for the source),
plus `/tmp`, `/proc` and `/dev`.

**Concrete consequence.** A path readable from `bash` can be rejected by
`read`, and that is expected: the exec layer sees the interpreter's runtime
tree through runtime-dir grants the Ruby read allowlist does not carry. The
reverse also happens — a path granted by the allowlist can be bound
read-only inside bwrap. Run the Workspace `sandbox_paths` task for the exact
inventory of both layers: every allowed read/write path with its origin, the
planned mounts (source, destination, ro/rw, redirect), and the realized
mounts from `/proc/mounts` (`task :sandbox_paths` and the
`realized_mounts` helper, both in filesystem.rb).

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
   (`safe_realpath` helper; mounts built in `plan_mounts`),
   so two spellings of one host directory may be equivalent for
   authorization but not equally visible inside the execution sandbox — and
   a spelling that was never granted gets no mount at all. On hosts that
   alias `/home/user/...` with `/bulk/user/...`, a directory can be fully
   visible under one spelling and `ENOENT` under the other. When a mount destination
   traverses a symlink whose parent is already mounted, the destination is
   redirected to the realpath — `m.destination = m.source` — and the plan
   records `redirect: true` (`destination != requested_path`, in the
   mount-planning code of exec.rb; the symlink target is additionally mounted
   read-only so the host symlink still resolves).
3. **In exec tools, `cd` to the granted root** (e.g. the `root` field
   reported by `sandbox_paths`) rather than a spelling that has no mount.
4. **Re-check with the specific tool you actually need.** The layers differ,
   so the definitive answer is the behavior of that one tool, not of a
   proxy: verify with the `read`/`write` task, or with `bash`, as
   appropriate.

### `resolve_path` semantics and TOCTOU

`LLM::Sandbox.resolve_path` walks component by component
(`LLM::Sandbox#resolve_path`):
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
rejects sibling prefixes (`/a-b` is not inside `/a`)
(`LLM::Sandbox#authorize_path`, `LLM::Sandbox#inside?`).

Authorization is **policy, not an atomic capability**: it applies to a path
spelling at check time. Nothing prevents the filesystem from changing between
the check and the operation (see the same limitation recorded for the Path
engine's advisory existence checks; see
[PathEngine.md](PathEngine.md)). TOCTOU hardening is
explicitly out of scope.

## Sources / verification

Behavioral claims in this document are pinned by
`test/scout/llm/test_sandbox.rb` (16 cases; notably
`test_authorization_uses_root_and_nested_boundary_not_sibling_prefix`,
`test_grant_sources_compose_defaults_thread_and_config`,
`test_grant_scope_tokens_and_expand`) and by the code anchors cited
inline (`lib/scout/llm/sandbox.rb`, the Workspace `filesystem.rb` /
`exec.rb` / `tsv.rb` / `patch.rb` / `precise_edit.rb` task files, and
`lib/scout/llm/agent/path.rb`). Workspace-side file names refer to the
Workspace workflow repository.
