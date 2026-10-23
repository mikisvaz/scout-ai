# The Path engine

This document explains how the Path engine (`lib/scout/llm/agent/path.rb`,
with the editing implementation in `lib/scout/llm/agent/path/edit.rb` and
the single-file diff applier in `lib/scout/llm/agent/path/patch.rb`)
exposes filesystem operations to agents: how to register a path kind, how
to declare the kinds a workflow provides (`PATH_KINDS`) so incorporating
agents receive them, how to override a built-in operation, how to introduce
a custom operation, how tool aggregation resolves conflicts, what the
callback contract and trust boundary are, how the single-file patch
operation behaves, and which `path` spellings select the kind root rather
than a file. It is intended for workflow and plugin authors; no
Scout internals knowledge is assumed beyond `LLM.agent`.

---

## 1. Kinds require absolute roots

A path kind maps virtual paths (kind + path + location) to real
filesystem targets. Registration roots must be **absolute path strings**:

```ruby
agent.register_path_kind(
  "scratch",
  "description" => "Scratchpad files",
  "roots" => {
    "project" => File.expand_path("var/scratch", __dir__),
    "tmp"     => File.expand_path("tmp/scratch", __dir__)
  }
)
```

Relative roots are pinned against the effective path map at registration
time (see section 2), so by the time authorization runs every root is an
absolute path string. `path_authorize!` forwards absolute target and root
strings to `LLM::Sandbox.authorize_path`, which fails closed on anything
it cannot compare exactly (symlinks are resolved before comparison). There
is no fallback interpretation, so a relative root never widens access by
accident.

## 2. Path maps

Kinds may be declared with roots that are convenient relative spellings
(`"share/tasks"`, `"tmp/scratch"`) instead of pre-expanded absolute paths.
The engine resolves those spellings once, at registration, against a Scout
path map and stores the result as a pinned absolute `String`. The
filesystem boundary then never re-resolves: `resolve_path` joins
`root[path]` on the pinned string, and the read/write/edit boundary does
plain `File.*` on the result. Nothing downstream can fall back through
Scout's map order again.

**Never re-resolve a target through `Path#find` after authorization.**
Authorization compares the resolved absolute target against the pinned
root exactly; `Path#find` on a missing/unlocated path can fall back
through `map_order` to `:user` (`~/.scout`) or compressed alternatives
(`.gz`/`.bgz`/`.zip`), so a `find`-re-resolved target could point outside
the root that was just authorized. Handlers and overrides receive the
authorized absolute `String` and must treat it as final.
Why pinning exists: Scout's `Path#find` walks `map_order` for a path that
is unlocated and missing, and the final map in that order is
`:default => :user` (`~/.scout`). A relative root held as an unlocated
Scout `Path` therefore targeted `~/.scout` exactly in the "write a NEW
draft" case, where the checkout copy does not exist yet. Pinning removes
the fallback entirely.

Two configuration points govern resolution:

- **Agent-level default**: `LLM.agent(path_map: :current)`. The name is
  `path_map`; it applies whenever a kind does not set its own map and also
  governs the implicit project root used by `resolve_path`/`path_authorize!`
  when no explicit `"project"` root is configured. The default is
  `:current` (the checkout; identical semantics to `Scout.root.find(:current)`).
- **Per-kind override**: the `"path_map"` definition key
  (`"path_map" => :lib`), which takes precedence over the agent default.

Resolution is `Scout.root.find(path_map)`; for `:current` this is a plain
`String` pinned to the checkout root.

Compatibility rule: a root that is already absolute today keeps its
placement unchanged. Whether it was declared absolute or produced by
libdir/workflow-root logic in `workflow_kinds.rb`, it passes through
verbatim — pinning is only applied to relative spellings, and it only
applies even when an agent-level `path_map` is configured. Live kinds with
absolute roots therefore keep their current placement; the new default
only changes behavior for roots that would otherwise be relative
(the leak case).

Validation at registration raises `ParameterException` for:

- a `"path_map"` (or agent `path_map:`) value that is not a `String` or
  `Symbol`;
- a map name Scout cannot resolve (`Path#find` raises `RuntimeError:
  Map not found ...`), which is wrapped into the same `ParameterException`
  envelope with the offending name.

Any `StandardError` raised while resolving the map or the root is wrapped
the same way, so an invalid configuration can never surface as a raw Ruby
exception.

### Job-directory pinning

Separately from kind roots, chat-task workflows built by
`lib/scout/llm/agent/workflow.rb` (`AgentWorkflow` and the
`LLM::Agent#workflow` anonymous module) previously resolved their job
directory through `Workflow.directory`, whose default is the *unlocated*
`Path.setup("var/jobs")`; the first `.find` on a job path then fell back
to `~/.scout/var/jobs`. The module now pins its directory to the
checkout's `var/jobs` (`:current`) the first time a `chat_task` or the
module is used, unless the workflow already declares an explicit
directory (`directory =` beats pinning, so tests and deployments that set
`Workflow.directory` keep their configured location).

### Dormant limitation

`path_list` used to call `Path#glob` on the resolved target when it looked
Path-like. With roots pinned absolute, targets are always plain `String`s,
so the branch has been hardened to always use `Dir.glob` on the pinned
absolute string (never re-resolving through map order). No known caller
supplies a `Path`-like target today.

### Out-of-repo leaks (H3, recorded as follow-ups)

The tool-layer `TmpFile`/`Open.write` scratch traffic that lands in
`~/.scout/tmp` for relative tool paths originates in the
Workspace/ComputerUse tool layer (gem `scout-gear` `TmpFile.tmpdir`
override), not in this engine. No code in this repository resolves those
paths; the fix belongs in the tool layer and is recorded as a follow-up
there. The durable record of the engine-side behavior is
`test/scout/llm/agent/test_path.rb` (absolute roots pass through
untouched even with an agent-level map configured).


## 3. Registering a kind

The full entry shape:

```ruby
agent.register_path_kind(
  "my_kind",
  "description"     => "What this kind is for",
  "roots"           => {"project" => "/abs/root"},
  "locations"       => ["project"],          # optional; defaults to root keys
  "default_location" => "project",            # optional
  "path_map"        => :current,              # optional; see section 2
  "capabilities"    => {"edit" => true, "patch" => true},
  "sandbox"         => true,                  # true/false, or a responder
  "resolve"         => ->(agent, path, location) { ... }
)
```

- `capabilities` accepts an Array of enabled operation names or a Hash
  merged over `DEFAULT_CAPABILITIES` (`read`, `write`, `edit`, `list`,
  `move`, `rename`, `delete` on by default; `validate`, `test`,
  `promote`, `smoke`, and `patch` off by default).
- `"resolve"` returns the real path for a virtual one; the default
  joins the kind root, the location and the path.
- Kind hooks: `"list"`, `"validate"`, `"test"`, `"smoke"`,
  `"promotion_destination"`, `"promotion_post_move"` (besides
  `"resolve"`). Registration is instance-local: kinds registered on one
  agent are invisible to other agents.
- `"sandbox"` gates path authorization per kind: when true (the default),
  every operation is authorized against the kind roots through
  `LLM::Sandbox.authorize_path` before any callback runs. The shared
  sandbox model and its two layers are documented in
  [Sandbox.md](Sandbox.md).

## 4. Declaring kinds in a workflow: `PATH_KINDS`

A workflow may declare the path kinds it provides as a `PATH_KINDS`
constant in its own namespace. When an agent incorporates the **entire
workflow** through a whole-workflow `tool: MyWorkflow` chat line, the
kinds are discovered and registered on that agent. Task-level imports
(`tool: MyWorkflow some_task`) register nothing.

The declaration is part of the workflow's Ruby, and the grant happens
at incorporation: merely loading a workflow's files registers nothing
anywhere, and the constant alone grants nothing. The two supported
shapes are a Hash of kind name to definition, or an Array of definition
Hashes each carrying its own `"name"` key:

```ruby
module MyWorkflow
  extend Workflow

  PATH_KINDS = {
    "notes" => {
      "description" => "Agent-visible notes area",
      "roots" => {"project" => File.expand_path("var/notes", __dir__)},
      "capabilities" => {"read" => true, "edit" => true, "list" => true}
    },
    "scratch" => {
      "description" => "Disposable scratch files",
      "roots" => {"tmp" => File.expand_path("tmp/scratch", __dir__)}
    }
  }
end
```

The same content as an Array:

```ruby
module MyWorkflow
  PATH_KINDS = [
    {
      "name" => "notes",
      "description" => "Agent-visible notes area",
      "roots" => {"project" => File.expand_path("var/notes", __dir__)}
    }
  ]
end
```

Each entry is exactly what `register_path_kind` accepts for a single
kind (section 3), so `roots`, `locations`, `capabilities`, `overrides`
and `operations` all mean the same thing here.

Behavior at incorporation:

- **Discovery is namespace-local.** The constant is looked up with
  `const_defined?(:PATH_KINDS, false)` on the workflow's own namespace,
  so a constant inherited from a parent module or superclass is not
  discovered.
- **Only whole-workflow lines grant.** `tool: MyWorkflow` registers the
  kinds; `tool: MyWorkflow some_task` does not. Remote `tool:` targets
  and workflow names that cannot be resolved are skipped silently, and
  a workflow with no `PATH_KINDS` constant is a silent no-op.
- **Definitions are deep-copied before registration.** `register_path_kind`
  copies only one level and `Hash#freeze` is shallow, so the
  incorporation path makes a full copy first; the shared frozen
  `PATH_KINDS` constant is never mutated through the registry, and
  mutating a registered definition never changes the workflow's
  constant.
- **Provenance is recorded per kind.** Each incorporated kind name is
  mapped to its workflow in `agent.path_kind_sources` (bookkeeping
  only; the authoritative registry is `agent.path_kind_registry`).
- **A kind name belongs to one workflow.** If two different
  incorporated workflows declare the same kind name, incorporation
  raises `ParameterException` naming both workflows and the kind; the
  order of the two `tool:` lines never decides. Incorporating the same
  workflow again is idempotent: the kind is re-registered in place and
  the aggregated tools are refreshed without duplicates.
- **Malformed declarations fail loudly.** A `PATH_KINDS` that is not a
  Hash (or Array of Hashes), or an entry that is not a Hash, raises
  `ParameterException` naming the workflow, the kind and the actual
  class, for example:
  `Workflow "MyWorkflow" declares PATH_KINDS as a String; expected a
  Hash of kind name => definition (or an Array of definition Hashes
  with a "name" key)`.- **Malformed declarations fail loudly.** A `PATH_KINDS` that is not a
  Hash (or Array of Hashes), or an entry that is not a Hash, raises
  `ParameterException` naming the workflow, the kind and the actual
  class, for example:
  `Workflow "MyWorkflow" declares PATH_KINDS as a String; expected a
  Hash of kind name => definition (or an Array of definition Hashes
  with a "name" key)`.

Incorporation behavior is pinned by
`test/scout/llm/agent/test_path_workflow_integration.rb`
(`test_whole_workflow_tool_line_registers_kinds_and_installs_tools`,
`test_task_level_tool_line_registers_nothing`,
`test_conflict_between_two_workflows_raises_naming_both`,
`test_frozen_path_kinds_constant_is_never_mutated`,
`test_path_role_no_longer_installs_path_tools`); registration and
registry rollback by `test/scout/llm/agent/test_path.rb`
(`test_register_path_kind`,
`test_invalid_location_root_and_default_declarations_are_atomic`,
`test_failed_kind_registration_rolls_back_registry_and_tool_surface_recovers`,
`test_conflicting_contracts_are_rejected_at_installation`).

There is no chat-level Path role: enabling a kind is done either by
registering it directly in Ruby (`register_path_kind`, iterated over a
mapping of kinds when needed, `load_path_plugins`) or by incorporating a
workflow that declares `PATH_KINDS`. Authorization is unchanged in both
cases: every operation still goes through `LLM::Sandbox.authorize_path`,
which fails closed.

## 5. Overriding a built-in without changing its schema

A kind may replace a built-in's implementation through the `"overrides"`
key. The engine always owns the public tool schema: the agent still sees
the same `path_edit` (or `path_read`, ...) arguments, and the kind
capability gate still applies — an override cannot resurrect an
operation the kind lacks the capability for.

**Only `write`, `edit` and `patch` can be overridden.** These are the
built-ins whose dispatch actually consults the operation table, so an
override registered for any other built-in could never run. Such a
registration is rejected loudly at `register_path_kind` time with a
`ParameterException` naming the supported set. The remaining built-ins
are customized through their own hook mechanisms, not overrides:
`"list"` via the `"list"` definition key, `"validate"`/`"smoke"` via the
`"validate"`/`"smoke"` definition keys (dispatched by
`path_kind_operation`), and `"promote"` via the `"promotion_destination"`
and `"promotion_post_move"` definition keys (its legacy mover hook is
retired). `read`, `move`, `rename` and
`delete` have none at all.

Each overridable built-in accepts a specific set of handler types:

| operation | accepted `type` values | undeclared default |
|---|---|---|
| `write` | `:content`, `:full` | `:content` |
| `edit`  | `:content`, `:full` | `:content` |
| `patch` | `:content` only | `:content` |

A `type` outside the operation's accepted set is rejected at
registration with a `ParameterException` naming the accepted values;
declaring `"type" => :full` for `patch` fails because patch dispatches
its override as a strict content transform (it applies a unified diff
and never hands the handler a write).

```ruby
agent.register_path_kind(
  "fancy",
  "roots" => {"/tmp/fancy" => "/tmp/fancy"},
  "capabilities" => {"edit" => true},
  "overrides" => {
    "edit" => ->(content, args) { content.upcase }
  }
)
```

The example above registers a `:content` edit override (the undeclared
default). Override call shapes follow the declared `type`:

- `:content` (the default): the engine resolves and authorizes the
  target, reads it, calls `implementation.call(content, args)`, and
  writes the result back through the same authorized
  target. The handler receives **no path** and cannot redirect the
  write. The result's final-newline state is normalized to the ORIGINAL
  file's termination, whatever the handler returned. The handler **must
  return a String**; a non-String return is converted to a
  `ParameterException` naming the contract (see section 9).
  - For `edit` specifically: under a `:content` edit override the
    `selector` and `replacement` arguments are still **validated** (they
    are required by the tool schema) but are **not applied** — the
    handler's returned content IS the edited file, wholesale. A
    `:content` edit override replaces the edit transform entirely; a
    kind that wants selector semantics must not override `edit` at all.
- `:full`: `implementation.call(agent, target, args)` receives the
  resolved, authorized target and must return a **Hash payload**; a
  non-Hash return is converted to a `ParameterException` naming the
  contract. The handler performs the write itself, but the canonical
  result keys stay **engine-authoritative**: the engine composes
  `doc_id`/`kind`/`path`/`location`/`target_file`/`written` (write) or
  `doc_id`/`kind`/`path`/`changed`/`content` (edit) itself and
  **ignores** any attempt by the payload to set them; other payload keys
  are merged into the result additively. The engine verifies reality
  instead of trusting the handler's claim: `write` reports `target_file`
  as the authorized target and `written` as actual existence there;
  `edit` reads `content`/`changed` back from the authorized target after
  the handler returns. This is trusted plugin code (see section 9).

Authorization completes **before** any handler call, for both types: an
authorization failure invokes no override and mutates nothing.

## 6. Introducing a custom operation

New operations are declared under `"operations"`:

```ruby
agent.register_path_kind(
  "notes",
  "roots" => {"/tmp/notes" => "/tmp/notes"},
  "operations" => {
    "precise_edit" => {
      "description" => "Replace exactly count occurrences",
      "parameters" => {
        "properties" => {
          "old_text" => {"type" => "string"},
          "new_text" => {"type" => "string"},
          "count"    => {"type" => "integer", "default" => 1}
        },
        "required" => ["old_text", "new_text"]
      },
      "implementation" => ->(agent, target, args) {
        # :full handler; :content handlers get (content, args) instead
        { "replaced" => ... }
      },
      "authorization" => :write,   # :read or :write; default :write
      "type" => :full              # :content or :full; default :full
    }
  }
)
```

The registered operation appears as one agent tool (`precise_edit`)
whose arguments are `kind` + `path` + `location` + the declared
parameters. Support, authorization mode and implementation are all read
from the canonical `operation_table` stored in the kind definition at
registration time: `path_operation_support?(kind, op)` and
`path_operation_implementation(kind, op)` wrap the table lookups
(`operation_table[op]["authorization"]` is the mode;
`path_kind_definition(kind)["operations"][op]` the custom spec;
`["overrides"][op]` the override).

Registration validation raises `ParameterException` for: an operation
name colliding with a built-in, a non-callable implementation, an
unknown authorization mode or handler type, an override whose target is
not a built-in, an override of a built-in outside the dispatchable set
(`write`/`edit`/`patch`, see section 5), an override whose declared
`type` is not accepted by its target operation, or a declared parameter
colliding with the reserved `kind`/`path`/`location` arguments.

## 7. Parameter collision policy

When several kinds register the same operation name, exactly one tool
is installed. Their parameter contracts must match exactly after
normalization:

- Hash keys are compared stringified.
- `type` entries must be equal.
- `required` and `enum` are compared as unordered sets.
- `default` values are compared by equality.
- Nested hashes (and lists of hashes) are compared recursively with the
  same rules.

The `description` is **not** compared; the description of the tool is
the one from the **last registration** (registry insertion order). A
contract mismatch raises `ParameterException` naming the operation, both
kinds, and the concrete differences, e.g.
`parameters.properties.old_text.type differs: "string" vs "integer"`.

Tool installation is refreshed on every registration: custom tools
become available immediately and no previously installed tool is
dropped. Registration is atomic — if tool installation fails, the
half-registered kind is removed again.

The installed surface is `path_kinds` plus one tool per built-in
operation that at least one registered kind enables: the seven generic
operations (`read write edit list move rename delete`), the four special
operations (`validate promote smoke patch`), plus `path_kinds` itself —
at most 12 engine tools, before any kind-specific custom operations.

`path_kinds` takes an optional `kind`. With no `kind` (or an empty
string) it returns one entry per registered kind; with a `kind` it
returns exactly that kind's entry, in the same per-kind shape as the
full-map entries (`description`, `locations`, `default_location`,
`sandbox`, `capabilities`). An unknown `kind` raises `ParameterException`
(`Unknown path kind: <kind> (available: <sorted kind names>)`).

## 8. Root selectors address the kind root, never a file

The empty string, `"."` and `"./"` all address the kind **root as a
whole**. They are enumeration selectors, not file paths, and the ten
file-shaped built-in operations reject them at the argument-validation
point, before resolution or authorization:

- rejected by `path_read`, `path_write`, `path_patch`, `path_edit`,
  `path_move`, `path_rename`, `path_delete`, `path_validate`,
  `path_smoke` and `path_promote`;
- every rejection is `ParameterException`:
  `Invalid path for <operation>: "<value>" addresses the kind root; use
  a path relative to the root, or path_list to enumerate the root`.
  Without the rejection, a `"."` on an extension-bearing kind would
  resolve to the junk target `<root>/..<ext>` (previously a silent
  create on write and an empty listing on read);
- `path_list` is the enumeration surface: a `.`/`./` prefix is
  normalized to the empty prefix and lists the kind root, exactly like
  an omitted path;
- `path_dispatch` is deliberately exempt. Custom operations own their
  path grammar and may legitimately receive `"."` (for example a
  suite-scope enumeration); the engine passes the value through as
  given. A custom operation's `path` argument still names one file
  unless that operation documents otherwise.

The grammar is pinned by
`test/scout/llm/agent/test_path_errors.rb`
(`test_error_matrix_root_selector_rejected_by_every_file_shaped_operation`,
`test_path_write_root_selector_creates_no_file`) and
`test/scout/llm/agent/test_path.rb`
(`test_path_list_root_selector_lists_the_kind_root`,
`test_path_dispatch_passes_root_selector_to_custom_operation`).

## 9. Callback contract and trust boundary

Callbacks run **only after** kind validation, path resolution,
capability checks and authorization have all succeeded. An
authorization failure invokes no callback and mutates nothing.

- `:content` handlers are engine-mediated: the engine reads the
  authorized target, passes the content, and writes the result back to
  the same target. The handler cannot name another file, and returned
  text is content, never a redirection.
- `:full` handlers are trusted plugin code. The engine authorizes the
  declared target before invoking, but cannot constrain what files the
  handler touches after that; `:full` handlers default to write
  authorization and their authors are responsible for staying inside
  authorized roots.

Errors follow the engine contract: invalid arguments, missing files and
failed authorization raise `ParameterException` (a Scout exception).
The agent-facing tool callables serialize Scout exceptions as
`{"exception": ..., "exception_line": ...}`; non-Scout exceptions are
not caught there. Custom-operation handlers must therefore normalize
their own failures. The engine guards its own mediated call sites:
an override `:content` handler returning a non-String (for `write`,
`edit` or `patch`) or a `:full` handler returning a non-Hash is
converted to a `ParameterException` naming the contract and serialized
as an error envelope, never a raw `NoMethodError`/`ArgumentError`
escape.

The trust boundary is pinned by
`test/scout/llm/agent/test_path_filesystem.rb`
(`test_sandbox_denies_custom_operation_before_callback`,
`test_sandbox_fails_closed_when_authorizer_is_unavailable`,
`test_path_write_success_is_at_the_authorized_target`,
`test_path_write_denies_resolver_target_outside_root`,
`test_path_write_filesystem_failure_does_not_return_success`),
`test/scout/llm/agent/test_path.rb`
(`test_dispatch_authorization_failure_runs_no_callback_and_mutates_nothing`,
`test_dispatch_content_op_cannot_redirect_write_to_other_file`,
`test_dispatch_edit_override_authorization_failure_runs_no_override`,
`test_write_override_authorization_failure_runs_no_handler`) and
`test/scout/llm/agent/test_path_edit.rb`
(`test_full_edit_override_authorization_failure_runs_no_handler`).

The error surface per failure class is pinned by
`test/scout/llm/agent/test_path_errors.rb` (its `test_error_matrix_*`
cases: unknown kind/location, missing argument, invalid or malformed
selector, path outside grant, unsupported operation, the root-selector
rejections of section 8, and the `path_kinds` unknown-kind error of
section 7).

## 10. Single-file patch; multi-file changes are not supported

`patch` is a built-in operation, default-off (`"patch" => true` in
capabilities to enable). Its tool takes `kind`, `path`, optional
`location`, and `patch` — a standard single-file unified diff:

```
--- a/notes.txt
+++ b/notes.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+BETA
 gamma
```

- Exactly one `---`/`+++` header pair; a second pair is rejected as a
  multi-file patch before any mutation.
- Header filenames are ignored as target selectors: the target is
  always the kind/path-resolved file, and a header naming another file
  never redirects or creates it.
- `@@ -l[,s] +l[,s] @@` hunks with context, `-` and `+` lines; `\ No
  newline at end of file` markers are honored on both sides.
- Application is strict: hunks apply in order with exact context
  matching at the stated line (plus the accumulated offset of earlier
  hunks). There is no fuzz and no offset search. Any mismatch rejects
  the whole patch with `ParameterException` — all hunks apply or none,
  and a failed patch writes zero bytes.

Multi-file patching is **not** part of the Path engine: coordinated
changes across several targets belong to the sandboxed terminal
mechanism (`bash` etc.), not to a Path operation.

The patch contract is pinned by `test/scout/llm/agent/test_path_patch.rb`
(`test_patch_applies_simple_diff_and_preserves_untouched_bytes`,
`test_patch_multi_file_rejected_before_mutation`,
`test_patch_header_filename_cannot_redirect_target`,
`test_patch_multi_hunk_is_all_or_nothing`,
`test_patch_no_newline_marker_adds_and_removes_final_newline`,
`test_patch_default_off_and_capability_enables`,
`test_patch_on_unauthorized_target_writes_nothing`).

## 11. `edit` selector semantics are byte-exact (pinned by tests)

`path_edit` never normalizes whitespace. Untouched content is copied
byte-identically; only the selected span changes. The contracts below are
pinned by the newline test matrix in
`test/scout/llm/agent/test_path_edit.rb` (the original 12-case matrix has
grown; any change to these behaviors must update those tests deliberately,
never by deleting them):

- `lines` selectors are 0-based with an **exclusive** `end`; each line
  includes its terminator and the final line may lack one.
- `start == lines.length` (insertion-at-end) is allowed and appends;
  `start > lines.length` raises. `end` beyond the document clamps to the
  end (clamping is deliberate, not leniency).
- At an **interior** boundary (a line follows the span) the replacement is
  terminated with exactly one newline: a missing one is added, repeated
  ones collapse.
- At an **EOF-spanning** boundary the result's final-newline state is
  inherited from the ORIGINAL document, bidirectionally: a replacement
  ending in `\n` must not introduce a final newline the original lacked,
  and deleting the last line of a file without a final newline must not
  add one. A replacement's trailing newlines are stripped in that case.
- `regexp` selectors use `Regexp.new` with a narrow `RegexpError` rescue
  (invalid patterns surface as `ParameterException`, never a raw Ruby
  exception); `chars` selectors use byte/character-index splice with
  `start <= end` enforced.
