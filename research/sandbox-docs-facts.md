# Sandbox documentation facts sheet (code-verified)

Date: 2026-10-16. Agent: Worker (read-only reconnaissance pass).
Scope: verified facts for the MANDATORY sandbox documentation in scout-ai.
Every claim carries exactly one label: `[code <file>:<line>]` (read from the
checkout at the cited line), `[probe <command> → <result>]` (executed and
recorded here), or `[unverified: <reason>]`.

Host paths used:
- scout-ai: `/bulk/mvazque2/git/scout-ai` (this job's rw root)
- Workspace: `/home/mvazque2/git/AgentSuite/Workspace` (rw; the `/bulk`
  spelling of AgentSuite/Workspace resolves to a nearly-empty dir inside this
  job — see §3).
- ScoutCoder / ChatAnalyst: `/home/mvazque2/git/AgentSuite/<name>`.

---

## 1. Tool landscape (sandboxed vs not)

### scout-ai core

- `LLM::Sandbox` (`lib/scout/llm/sandbox.rb`) is the shared primitive:
  - `resolve_path(path, base_path: nil)` at `lib/scout/llm/sandbox.rb:14`
  - `authorize_path(path, root: Dir.pwd, writable_paths: [], read_paths: [], mode: :read, base_path: nil)` at `lib/scout/llm/sandbox.rb:76`
  - `inside?(path, root)` at `lib/scout/llm/sandbox.rb:103`
  - grant registration helpers `allow_path` (:109), `allow_read_path` (:116),
    `allow_job` (:123), `allow_read_job` (:129) — these write the
    pre-existing `Chat` thread keys (`Thread.current['allowed_paths']`,
    `'allowed_read_paths'`, `'allowed_jobs'`, `'allowed_read_jobs'`).
    [code lib/scout/llm/sandbox.rb:103-135]
- `Chat.allow_*` wrappers are one-line delegations to `LLM::Sandbox`:
  `Chat.allow_path` → `LLM::Sandbox.allow_path` etc., all four.
  [code lib/scout/llm/chat/process/tools.rb:6-20]
- Chat-file message roles `allow_path` / `allow_read_path` are processed into
  `Chat.allow_*` calls during chat-file loading (so a chat file itself can
  extend its grants). [code lib/scout/llm/chat/process/files.rb:97-104]
- Callers that register grants (not enforcement, but the grant SOURCES that
  make enforcement permissive):
  - `LLM.ask` allows read of `job_paths` and all recursive dependencies.
    [code lib/scout/llm/ask.rb:78-88]
  - The workflow tool registers read grants for jobs it runs.
    [code lib/scout/llm/tools/workflow.rb:170]
  - The call/chat tools allow read of `Step` content and of child agent
    answers. [code lib/scout/llm/tools/call.rb:192, call.rb:217]
  - `LLM::Agent` allows the agent's own job (write) before produce.
    [code lib/scout/llm/agent.rb:113]
  - `AgentWorkflow` chat tasks allow the job `files_dir` (write) at task
    start. [code lib/scout/llm/agent/workflow.rb:178]
- scout-ai's own enforcement point for agent-facing virtual paths: the agent
  Path engine `path_authorize!` calls `LLM::Sandbox.authorize_path` and raises
  `ParameterException` on denial; kinds declaring `"sandbox" => false` skip
  authorization. [code lib/scout/llm/agent/path.rb:1148-1177]

### Workspace (AgentSuite/Workspace)

- All filesystem tasks go through `helper :normalize` (→ `LLM::Sandbox.authorize_path`
  with `root: Workspace.root`, writable = `Workspace.allowed_paths`, read =
  `Workspace.allowed_read_paths`; denial → `SandboxAccessViolation`):
  [code /home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/filesystem.rb:50-77]
  - `read` (filesystem.rb:~216 `file = normalize file`), `write`
    (filesystem.rb:~200 `file = normalize file, :write`), `list_directory`
    (:308 `directory = normalize directory`), `file_stats` (:~348
    `normalize file`), plus `delete`, `search`, `copy`, `pwd`/`sandbox_paths`
    in the same file. [code .../tasks/filesystem.rb:200-370]
  - `precise_edit` normalizes with `:write`. [code .../tasks/precise_edit.rb:18]
- `patch` does NOT call `normalize` at the Ruby layer; it runs the `patch`
  CLI through `cmd_json` inside bwrap (writes confined to `Workspace.root` via
  `Dir.chdir(Workspace.root)`). [code .../tasks/patch.rb:294-321]
- TSV tasks (`tsv_*`) do NOT call `normalize`; they open files via Scout
  `TSV`/`Open` directly (no Ruby-layer authorization). [code .../tasks/tsv.rb:181-467]
- Exec tasks (`bash`, `python`, `ruby`, `r`, and `cmd_json` callers) are
  enforced by bwrap at the OS level: `cmd_json` collects
  `Workspace.get_allowed_paths(:allowed_paths)` plus the job `files_dir` as
  writable and delegates to `sandbox_run`. [code .../tasks/exec.rb:698-757]
- `sandbox_run` builds the mount set: writable = per-call extras +
  `Workspace.allowed_paths` + optional config `bwrap_paths` + `Workspace.root`;
  read = `Workspace.allowed_read_paths` + optional `bwrap_read_paths` +
  `/etc/resolv.conf` (network on) + runtime dirs of the resolved executable +
  relocatable runtime dirs from `$PATH`. [code .../tasks/exec.rb:534-593]
- Note: the bwrap allowlist is therefore BROADER than the Ruby read/write
  allowlist in specific ways: exec adds `/etc/resolv.conf`, executable runtime
  dirs, `$PATH`-scanned runtime dirs, and always makes `Workspace.root`
  writable. [code .../tasks/exec.rb:560-593]

### Contrast: ChatAnalyst

- ChatAnalyst (`/home/mvazque2/git/AgentSuite/ChatAnalyst`) has no
  `LLM::Sandbox` / `normalize` / `authorize` usage anywhere in `lib/`; its
  tasks (`timeline_index`, `chat_timeline`) read chat files directly with no
  path authorization. [probe `grep -rn 'Sandbox|normalize|authorize' lib/` in
  ChatAnalyst → only textual `normalized` string-cleanup variables at
  lib/ChatAnalyst/tasks/timeline.rb:77-89; no sandbox calls]

### Contrast: ScoutCoder path kinds

- ScoutCoder declares three path kinds (`task`, `entity`, `entity_property`)
  with `'sandbox' => true`. [code
  /home/mvazque2/git/AgentSuite/ScoutCoder/lib/ScoutCoder/path_kinds.rb:535, 718]
- Enforcement is NOT in ScoutCoder: the scout-ai agent Path engine's
  `path_authorize!` performs the check (see above), gated on the kind's
  `"sandbox"` flag with roots taken from the kind's `roots` map for the
  location. [code /bulk/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb:1148-1171]
- The `sandbox` key is documented in the engine reference. [code
  /bulk/mvazque2/git/scout-ai/doc/developer/PathEngine.md:136]

### Tool landscape table

| Tool / action | Sandboxed? | Enforcement point |
|---|---|---|
| Workspace `read`/`write`/`delete`/`search`/`list_directory`/`file_stats`/`copy` | Ruby allowlist (LLM::Sandbox) | filesystem.rb:50-77 (`helper :normalize`), task bodies :200-370 |
| Workspace `precise_edit` | Ruby allowlist | precise_edit.rb:18 (`normalize(path, :write)`) |
| Workspace `sandbox_paths`, `pwd` | No enforcement (read-only introspection) | filesystem.rb:363-505 |
| Workspace `patch` | No Ruby-layer normalize; bwrap OS confinement | patch.rb:294-321 (`cmd_json` in `Dir.chdir(Workspace.root)`) |
| Workspace `tsv_*` | No Ruby-layer normalize | tsv.rb:181-467 |
| Workspace `bash`/`python`/`ruby`/`r` | bwrap OS sandbox only | exec.rb:698-757 (cmd_json), 534-620 (sandbox_run) |
| scout-ai agent `path_*` tools | Yes, when kind sets `sandbox: true` | path.rb:1148-1177 (`path_authorize!`) |
| scout-ai `LLM::Agent` jobs | Grant registration (`Chat.allow_job`) | agent.rb:113; sandbox.rb:123 |
| scout-ai chat `allow_path`/`allow_read_path` roles | Grant registration | files.rb:97-104; tools.rb:6-20 |
| ChatAnalyst tasks (`timeline_index`, `chat_timeline`) | No | none in lib/ (grep negative) |
| ScoutCoder `path_*` over its kinds | Yes (via engine) | path_kinds.rb:535,718 + scout-ai path.rb:1148-1177 |

---

## 2. Allowlist difference (bwrap exec vs read/write)

- `get_allowed_paths(type)` resolves six grant sources with type defaults:
  `exec_paths: "/bin /usr /lib /lib64 /etc"`, `allowed_paths: TMP_DIRS +
  "/tmp ~/tmp"`, `dirs: ""`, `read_paths: ""`, `thread:
  Thread.current['allowed_paths']`, `thread_read:
  Thread.current['allowed_read_paths']`; each is overridable by
  `Scout::Config.get(type, :Workspace, :workspace, :sandbox, ...)` or env
  `TYPE` (e.g. `ALLOWED_PATHS`). [code
  /home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/filesystem.rb:5-33]
- `Workspace.allowed_paths` = `get_allowed_paths(:allowed_paths)` + `:dirs` +
  `:thread`. [code .../filesystem.rb:40-46]
- `Workspace.allowed_read_paths` = `get_allowed_paths(:allowed_read_paths)` +
  `:exec_paths` + `:read_paths` + `:thread_read`. [code .../filesystem.rb:48-54]
- `TMP_DIRS = Path.setup("tmp").find_all` — the Scout pathmap expansion of
  `tmp`, which is why concrete entries include each project checkout's
  `tmp/` directory. [code .../filesystem.rb:3]
- bwrap mount planning: `plan_mounts(read_paths, writable_paths)` creates a
  `Mount(source: safe_realpath(expanded), destination: expanded, mode: :ro/:rw,
  requested_path:)` per granted path (read first, then writable).
  [code .../tasks/exec.rb:77-95]
- Mount destination adjustment for symlinks: if a mount destination traverses
  a symlink whose parent is itself in the mount set, the destination is
  redirected to the realpath (bwrap cannot mount onto a symlink when the
  parent is already mounted — ENOENT). [code .../tasks/exec.rb:97-140,
  comment at 102-116]
- `sandbox_run` composes: writable += `Workspace.allowed_paths` +
  config `bwrap_paths` + `Workspace.root`; read += `Workspace.allowed_read_paths`
  + config `bwrap_read_paths` + `/etc/resolv.conf` when network enabled +
  `runtime_dirs(resolved_exec)` + `path_runtime_dirs`; then `plan_mounts`,
  `--bind /tmp /tmp`, `--proc /proc`, `--dev /dev`. [code .../tasks/exec.rb:534-605]
- The `sandbox_paths` diagnostic task reports `root`, `pwd`, `pwd_realpath`,
  `home`, `bwrap`, a `note` describing the two permission layers, `writable`
  and `readable` arrays (each entry with path/symlink/readlink/realpath/
  exists/type/origin), planned `mounts` (source/destination/mode/
  requested_path/redirect) and `realized_mounts` from `/proc/mounts`.
  [code .../tasks/filesystem.rb:363-460; doc contract in the task `desc`
  at :342-351]
- Probes (this job):
  - [probe `sandbox_paths` tool → root=/bulk/mvazque2/git/scout-ai,
    pwd=/home/mvazque2/git/scout-ai, pwd_realpath=/bulk/mvazque2/git/scout-ai;
    writable origins root/allowed_paths/thread; readable origins
    exec_paths/thread_read; mounts include `/bulk/.../scout-ai` rw at the
    `/bulk` spelling, `/home/mvazque2/git/AgentSuite` ro (source
    /bulk/mvazque2/git/AgentSuite), `/home/mvazque2/git/AgentSuite/Workspace`
    rw (source /bulk/mvazque2/git/AgentSuite/Workspace); realized_mounts shows
    host devices /dev/sda4→/home, /dev/sdb1→/fast, /dev/sdc1→/bulk]
  - [probe `gem which rake` →
    /home/mvazque2/.rvm/rubies/ruby-3.3.1/lib/ruby/gems/3.3.0/gems/rake-13.1.0/lib/rake.rb;
    `head -1 <that path>` from bash → "# frozen_string_literal: true"
    (EXEC-READ-OK) — readable from exec]
  - [probe `read` task on the same rake.rb → REJECTED: "Path ... not read
    allowed. Allowed paths: <list>" with the allowlist appended and "Run task
    'sandbox_paths' for details"; exception_line points at
    .../Workspace/lib/Workspace/tasks/filesystem.rb:72 — the asymmetry is
    confirmed: exec sees the rvm tree (via runtime dirs), the Ruby read
    allowlist does not]
  - [probe `ruby tmp/sandbox_facts_probe.rb` (loads Workspace workflow, prints
    grants) → allowed_paths: /home/mvazque2/git/AgentSuite/Workspace/tmp,
    /home/mvazque2/.scout/tmp, /home/mvazque2/tmp/scout, /tmp/scout,
    /bulk/mvazque2/git/scout-ai/tmp, /home/mvazque2/git/scout-essentials/tmp,
    /tmp, /home/mvazque2/tmp; allowed_read_paths: /bin /usr /lib /lib64 /etc;
    get_allowed_paths(:exec_paths): ["/bin","/usr","/lib","/lib64","/etc"];
    Workspace.root: /home/mvazque2/git/AgentSuite/Workspace. Probe saved at
    /bulk/mvazque2/git/scout-ai/tmp/sandbox_facts_probe.rb]

Key asymmetry (documented in the `sandbox_paths` note itself): Layer 1 (Ruby
allowlist) governs read/write/delete/search/list_directory/file_stats; Layer
2 (bwrap mounts) governs bash/ruby/python/r built from the same lists PLUS
exec extras — so a path can be readable from bash yet rejected by `read`, or
granted by the allowlist yet read-only inside bwrap. [code
.../filesystem.rb:342-351 (task desc); note text observed in the
sandbox_paths probe output]

---

## 3. Symlink aliasing / per-spelling mounts

- `resolve_path` resolves component-by-component: each existing component is
  `File.realpath`-ed (so symlinks collapse to physical paths), `.` skipped,
  and the FIRST missing component switches to lexical mode — after that,
  `exists=false` and later components are appended without resolution.
  [code /bulk/mvazque2/git/scout-ai/lib/scout/llm/sandbox.rb:14-50]
- Fail-closed cases in `resolve_path`: a `..` reached after a missing
  component returns `exists:false, canonical_path:nil` (a walk cannot reach
  it; lexical collapse could authorize an unresolvable target); `..` after a
  non-directory returns `Errno::ENOTDIR`; a dangling symlink or
  unresolvable-existing component (ENOTDIR/EACCES on an existing parent)
  returns the error rather than treating it as lexical space.
  [code lib/scout/llm/sandbox.rb:26-38, 50-63]
- `authorize_path` resolves the target AND every grant with `resolve_path`,
  then accepts when the target's canonical path is `inside?` a resolved
  grant; a symlink therefore cannot make a grant escape its physical target
  (both sides are canonicalized). Boundary-aware `inside?` rejects sibling
  prefixes (`/a-b` not inside `/a`). [code lib/scout/llm/sandbox.rb:76-107]
- Relative inputs to `authorize_path` require an explicit `base_path` because
  relative-to-`Dir.pwd` would make decisions depend on ambient process
  state. [code lib/scout/llm/sandbox.rb:69-75 (comment), 14-19]
- WHY spellings diverge: bwrap mounts are constructed from the granted /
  requested path SPELLINGS (`plan_mounts` uses the expanded grant as the
  destination, realpaths only the source), so two spellings of one host
  directory produce two different destinations — and only the spellings that
  were granted get mounts at all. [code
  /home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/exec.rb:77-95,
  97-140]
- Redirect behavior: when a mount destination traverses a symlink whose
  parent is already mounted, the destination moves to the realpath and the
  plan records `redirect: true`. [code .../tasks/exec.rb:102-140]
- Probes (this job's topology):
  - [probe `sandbox_paths` → mounts list contains `source=/bulk/mvazque2/git/AgentSuite,
    destination=/home/mvazque2/git/AgentSuite, mode=ro` and
    `source=/bulk/mvazque2/git/AgentSuite/Workspace,
    destination=/home/mvazque2/git/AgentSuite/Workspace, mode=rw` — the same
    host directory tree is mounted at TWO different in-sandbox destinations
    with DIFFERENT modes (parent ro, child rw), both sourced from /bulk]
  - [probe `ls -d /home/mvazque2/git/scout-ai` from bash → "No such file or
    directory"; `ls -d /home/mvazque2/git/AgentSuite/Workspace` → exists]
  - [probe `realpath /bulk/mvazque2/git/AgentSuite/Workspace` → itself;
    `realpath /home/mvazque2/git/AgentSuite/Workspace` → itself (each
    spelling is canonical INSIDE its own mount; they are distinct mount
    points, not aliases, inside this sandbox)]
  - [probe `stat` device/inode on `/bulk/mvazque2/git/AgentSuite` vs
    `/home/mvazque2/git/AgentSuite` → different device ids (178 vs 2081):
    inside the bwrap namespace they are genuinely different filesystem
    objects; the host-level aliasing (`/home/mvazque2/git/...` is a symlink to
    `/bulk/mvazque2/git/...` on this class of host) is resolved differently
    per grant]
  - [probe `sandbox_paths.realized_mounts` → host mounts: `/dev/sda4` on
    `/home`, `/dev/sdb1` on `/fast`, `/dev/sdc1` on `/bulk`; `/home/mvazque2/tmp`
    readlink → `/fast/mvazque2/tmp/` (an in-home symlink to another device)]
- Host-side aliasing premise: the task description says this host aliases
  `/home/mvazque2/...` ↔ `/bulk/mvazque2/...`. Inside THIS job the two
  spellings are NOT equivalent: `/home/mvazque2/git/scout-ai` does not exist
  in the bwrap namespace (no mount at that spelling), while
  `/bulk/mvazque2/git/scout-ai` is the rw root. [probe `ls -d
  /home/mvazque2/git/scout-ai` → ENOENT; `pwd` inside bash is
  /home/mvazque2/git/scout-ai but `cd /home/mvazque2/git/scout-ai` fails]
  - Correction/nuance: `sandbox_paths` reports `pwd: /home/mvazque2/git/scout-ai`
    and `pwd_realpath: /bulk/mvazque2/git/scout-ai`, i.e. the PROCESS cwd
    spelling is `/home/...` and resolves through to the `/bulk` mount — the
    cwd spelling works from the Ruby layer (Process-relative) while fresh
    bash `cd`s to that spelling fail because no `/home/mvazque2/git/scout-ai`
    mount exists. This is exactly the "exists but invisible" trap.
    [probe sandbox_paths pwd/pwd_realpath fields]

### Recovery procedure (evidence-grounded)

1. Run `sandbox_paths` (Workspace) — it prints both permission layers with
   per-entry origin, symlink/readlink/realpath, and the planned mounts
   including `redirect` flags; its denial messages already point at it
   ("Run task 'sandbox_paths' for details"). [code
   .../filesystem.rb:342-351, 120-128 (describe_allowed_paths message)]
2. Use the granted SPELLING, not the equivalent one: authorization and mounts
   are keyed to expanded grant spellings; a path visible under one spelling
   may be absent under another. [code .../tasks/exec.rb:77-95]
3. In exec, `cd` to a granted root (e.g. the rw root from `sandbox_paths.root`)
   rather than a spelling that has no mount. [probe `cd /home/mvazque2/git/scout-ai`
   → ENOENT inside bash; the `/bulk` spelling works]
4. Do not infer one tool's restrictions from another: a ComputerUse/Workspace
   `read` rejection is not evidence about `bash`, and vice versa. The
   doctrine's guidance ("run the designated sandbox/path diagnostic before
   hypothesizing stale copies") maps to running `sandbox_paths` first.

---

## 4. test_filesystem.rb existence (contradiction resolved)

- `/home/mvazque2/git/AgentSuite/Workspace/test/Workspace/tasks/test_filesystem.rb`
  EXISTS. [probe `ls test/Workspace/tasks/` in the Workspace checkout →
  test_exec_helpers.rb, test_filesystem.rb, test_patch.rb,
  test_precise_edit.rb, test_tsv.rb]
- It was added by commit `0e18835` "Use the scout-ai sandbox for paths" (the
  same commit that routed `helper :normalize` through
  `LLM::Sandbox.authorize_path`). [probe `git log --oneline -1 --
  test/Workspace/tasks/test_filesystem.rb` → 0e18835]
- So "earlier material claims it is missing" is stale: the gap cited by the
  migration brief has since been closed by the refactor commit itself.

## 5. Workspace suite results (verifying refactor 0e18835 is green)

All run read-only from `/home/mvazque2/git/AgentSuite/Workspace` with
`ruby -Ilib:test[:test/Workspace/tasks] test/Workspace/tasks/<file>.rb`:

| Suite | Tests | Assertions | Failures | Errors | Verdict |
|---|---|---|---|---|---|
| test_filesystem.rb | 10 | 42 | 0 | 0 | PASS 100% |
| test_patch.rb | 1 | 1 | 0 | 0 | PASS |
| test_precise_edit.rb | 3 | 10 | 0 | 0 | PASS |
| test_exec_helpers.rb | 10 | 32 | 0 | 0 | PASS |
| test_tsv.rb | 23 | 139 | **1** | 0 | FAIL |

- test_filesystem counts: [probe `ruby -Ilib:test:test/Workspace/tasks
  test/Workspace/tasks/test_filesystem.rb` → "10 tests, 42 assertions, 0
  failures, 0 errors ... 100% passed"]
- test_tsv failure: `test_read_returns_scout_tsv_text_and_supports_csv_empty_header_hash`
  at test/Workspace/tasks/test_tsv.rb:97 — a `run_with_harness_return_path`
  harness assertion comparing `tsv_read` output bytes for CSV/empty-header
  input. [probe run output; failure detail at tsv.rb:97]
- Pre-existing or new? The tsv failure is in a suite unrelated to the
  sandbox refactor (tsv.rb has no `normalize`), and the Workspace tree has no
  uncommitted changes under `lib/` or `test/` ([probe `git status
  --porcelain=v1 -- Workspace` from the AgentSuite root → empty]). Whether it
  fails on the parent commit is not established here. [unverified: would
  require checking out the parent commit, which is outside this read-only
  pass]

## Sources

- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/sandbox.rb` (135 lines)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/chat/process/tools.rb` (258 lines; wrappers :6-20)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/chat/process/files.rb` (:97-104)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/ask.rb` (:78-88)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/tools/workflow.rb` (:170)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/tools/call.rb` (:187-222)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/agent.rb` (:108-118)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/agent/workflow.rb` (:172-182)
- `/bulk/mvazque2/git/scout-ai/lib/scout/llm/agent/path.rb` (:1148-1177)
- `/bulk/mvazque2/git/scout-ai/doc/developer/PathEngine.md` (:136)
- `/home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/filesystem.rb` (506 lines)
- `/home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/exec.rb`
- `/home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/patch.rb` (:294-321)
- `/home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/precise_edit.rb` (:18)
- `/home/mvazque2/git/AgentSuite/Workspace/lib/Workspace/tasks/tsv.rb` (:181-467)
- `/home/mvazque2/git/AgentSuite/ChatAnalyst/lib/ChatAnalyst/tasks/timeline.rb` (negative grep)
- `/home/mvazque2/git/AgentSuite/ScoutCoder/lib/ScoutCoder/path_kinds.rb` (:535, :718)
- Probes recorded: sandbox_paths output (tool), gem which/head vs read
  rejection, grant-lists ruby probe (`tmp/sandbox_facts_probe.rb`), mount
  topology probes (ls/realpath/stat), Workspace suite runs.

Claim count (occurrences): 56 labeled claims — 33 `[code ...]`, 20 `[probe ...]`, 3 `[unverified: ...]`.

---

## Corrections (dated append, 2026-10-16, doc-authoring pass)

Spot-checks re-run live before writing `doc/developer/Sandbox.md`; two minor
drifts found, corrected here rather than rewritten above:

1. `lib/scout/llm/sandbox.rb` is **139 lines** (Sources list above says 135).
   Method anchors re-verified at their current lines: `resolve_path` :14,
   `authorize_path` :76, `inside?` :103, `allow_path` :109,
   `allow_read_path` :116, `allow_job` :123, `allow_read_job` :129.
   [code lib/scout/llm/sandbox.rb:14,76,103,109,116,123,129; `wc -l` → 139]
2. §1 "ScoutCoder declares three path kinds ... with `'sandbox' => true`"
   (citing path_kinds.rb:535,718) is imprecise for the `task` kind: only
   `entity` (:535) and `entity_property` (:718) declare it explicitly; the
   `task` kind carries no `sandbox` key and relies on the engine default
   (`definition["sandbox"] = true unless definition.key?("sandbox")`,
   lib/scout/llm/agent/path.rb:126). Net effect identical (all three kinds
   are sandboxed), mechanism differs for `task`. [code
   ScoutCoder lib/ScoutCoder/path_kinds.rb:268-302 (no sandbox key in the
   `task` entry), :535, :718; scout-ai lib/scout/llm/agent/path.rb:126]

All other spot-checked anchors matched the sheet as written: Workspace
filesystem.rb (get_allowed_paths :5, allowed_paths :35, allowed_read_paths
:42, normalize :57-79, write :200, read :216, list_directory :308,
file_stats :350, sandbox_paths :374, pwd :410, delete :425, copy :449-450,
search :479), exec.rb (plan_mounts :77, Mount.new :86/:94, sandbox_run :534,
root-writable :560-568, resolv.conf :578, runtime_dirs :587/:590), patch.rb
(:309 Dir.chdir), precise_edit.rb (:18), scout-ai path.rb (:1148-1176
path_authorize!, :1522 TOCTOU advisory), ask.rb (:78-88), agent.rb (:113),
tools/workflow.rb (:170), agent/workflow.rb (:178), call.rb (:192,:217),
chat/process/tools.rb (:6-20), chat/process/files.rb (:97-104).

## Corrections (dated append, 2026-10-17, grant-source refactor pass)

The grant-source layer moved from Workspace into `LLM::Sandbox`
(`reports/scout-ai-sandbox-grant-sources.md` in Cortex). Anchors above that
moved, re-verified against the current tree:

- Workspace filesystem.rb shrank from 448 to 448 lines but the helpers moved:
  `get_allowed_paths` :3, `allowed_paths` :10, `allowed_read_paths` :14,
  `helper :normalize` :25-47, `classify_path` :59, `describe_allowed_paths`
  :91-95 (now delegates to `LLM::Sandbox.describe_grants`), `path_origin`
  :98-101 (delegates to `LLM::Sandbox.grant_origin`), `realized_mounts`
  :126-135, `task :write` :141, `task :read` :157, `task :list_directory`
  :248, `task :file_stats` :291, `task :sandbox_paths` :314-347, `task :pwd`
  :352, `task :delete` :366, `task :copy` :390, `task :search` :420,
  `export_exec` :447. `TMP_DIRS` no longer exists there.
  [code Workspace lib/Workspace/tasks/filesystem.rb:3-101,126,141,157,248,291,314,352,366,390,420,447]
- scout-ai sandbox.rb anchors at current lines: `resolve_path` :14,
  `authorize_path` :76, `inside?` :103, `grant_type_defaults` :122-132,
  `grant_scope_tokens` :138, `grant_paths` :150, `expand_grant_path` :163,
  `writable_grants` :169, `readable_grants` :175, `grant_origin` :187,
  `describe_grants` :218, `allow_path` :230, `allow_read_path` :237,
  `allow_job` :244, `allow_read_job` :250. [code
  lib/scout/llm/sandbox.rb:14,76,103,122,138,150,163,169,175,187,218,230,237,244,250]
- exec.rb anchors re-verified: `safe_realpath` :24, `plan_mounts` :77-95,
  mount redirect `m.destination = m.source` :131, redirect+ro-target phases
  :97-174, `sandbox_run` :534-594 (bwrap grants :548-555, root-writable
  :561-568, resolv.conf :578, runtime_dirs :587, path_runtime_dirs :590),
  `cmd_json` :698. [code Workspace lib/Workspace/tasks/exec.rb]
- ChatAnalyst confirmed to contain no `LLM::Sandbox` or `allow_*` references
  (grep over `ChatAnalyst/lib/` and `workflow.rb` returned none), so the
  doc's "none identified" row reflects a positive check, not an omission.
  [probe grep -rn "LLM::Sandbox|allow_path|allow_read"
  ~/git/AgentSuite/ChatAnalyst/{lib,workflow.rb} -> no matches]
- Labeled-claim recount after this pass: 34 `[code ...]`, 20 `[probe ...]`,
  3 `[unverified ...]`.

## Corrections (dated append, 2026-10-17, second doc-revision pass)

Line anchors in `doc/developer/Sandbox.md` re-verified against the live
checkouts after the grant-source refactor; all corrected anchors below were
confirmed by direct sed/grep reads.

- Workspace exec.rb: `sandbox_run` helper now starts at :534 (was :548);
  `Workspace.root` unconditional writable addition is :561-568 (was :560-570);
  `bwrap_paths` :554, `bwrap_read_paths` :555, `/etc/resolv.conf` :578,
  interpreter runtime dirs :587, `$PATH` runtime scan :590; `plan_mounts`
  destination/source build :77-95; Phase 3 redirect (`m.destination = m.source`,
  `redirect: true`) :97-134; Phase 4 symlink dependency mounts :137-175
  (`mounts.concat(additional)` at :175). [code exec.rb]
- Workspace filesystem.rb (448 lines after refactor): `get_allowed_paths` :3,
  `allowed_paths` :10, `allowed_read_paths` :14 (delegates),
  `helper :normalize` :25-47, `task :write` :141, `task :read` :157,
  `task :list_directory` :248, `task :file_stats` :291,
  `task :sandbox_paths` :316, `task :pwd` :352, `task :delete` :366,
  `task :copy` :390, `task :search` :420, `realized_mounts` :126,
  `export_exec` :447. [code filesystem.rb]
- Workspace patch.rb: `Dir.chdir(Workspace.root)` block :309-314 (the
  `cmd_json` call sits inside it). [code patch.rb]
- scout-ai sandbox.rb: `grant_type_defaults` :122-132,
  `grant_scope_tokens` :138-142, `grant_paths` :150, `expand_grant_path` :163,
  `writable_grants` :169, `readable_grants` :175, `grant_origin` :187,
  `describe_grants` :218, `allow_path` :230, `allow_read_path` :237,
  `allow_job` :244, `allow_read_job` :250; `resolve_path` :14-68,
  `authorize_path` :76-99, `inside?` :103-105. [code sandbox.rb]
- ChatAnalyst verified NOT sandboxed: no `LLM::Sandbox` / `allow_path` /
  `allow_read_path` / `allow_job` references under
  `~/git/AgentSuite/ChatAnalyst/lib/` or its `workflow.rb` (only an unrelated
  local variable named `normalized` in tasks/timeline.rb:77). [probe grep]
- Facts-sheet label recount: 37 `[code ...]`, 22 `[probe ...]`,
  4 `[unverified ...]` = 63 total. [probe grep -c]
