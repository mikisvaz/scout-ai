# The Path engine

This document explains how the Path engine (`lib/scout/llm/agent/path.rb`)
exposes filesystem operations to agents: how to register a path kind, how
to override a built-in operation, how to introduce a custom operation, how
tool aggregation resolves conflicts, what the callback contract and trust
boundary are, and how the single-file patch operation behaves. It is
intended for workflow and plugin authors; no Scout internals knowledge is
assumed beyond `LLM.agent`.

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

Relative roots are rejected at authorization time: `path_authorize!`
forwards absolute target and root strings to `LLM::Sandbox.authorize_path`,
which fails closed on anything it cannot compare exactly (symlinks are
resolved before comparison). There is no fallback interpretation, so a
relative root never widens access by accident.

## 2. Registering a kind

The full entry shape:

```ruby
agent.register_path_kind(
  "my_kind",
  "description"     => "What this kind is for",
  "roots"           => {"project" => "/abs/root"},
  "locations"       => ["project"],          # optional; defaults to root keys
  "default_location" => "project",            # optional
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

## 3. Overriding a built-in without changing its schema

A kind may replace a built-in's implementation through the `"overrides"`
key. The engine always owns the public tool schema: the agent still sees
the same `path_edit` (or `path_read`, ...) arguments, and the kind
capability gate still applies — an override cannot resurrect an
operation the kind lacks the capability for.

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

Override call shapes follow the handler `type`:

- `:content` (default for content transforms): the engine resolves and
  authorizes the target, reads it, calls `implementation.call(content,
  args)`, and writes the result back through the same authorized
  target. The handler receives **no path** and cannot redirect the
  write. The result's final-newline state is normalized to the
  ORIGINAL file's termination, whatever the handler returned.
- `:full`: `implementation.call(agent, target, args)` receives the
  resolved, authorized target and returns the operation result. This is
  trusted plugin code (see §6).

## 4. Introducing a custom operation

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
parameters. Query methods answer everything deterministically from the
registry: `path_operation_support?(kind, op)`,
`path_operation_override?(kind, op)`, `path_custom_operations`,
`path_custom_operation(kind, op)`,
`path_operation_authorization(kind, op)` and
`path_operation_implementation(kind, op)`.

Registration validation raises `ParameterException` for: an operation
name colliding with a built-in, a non-callable implementation, an
unknown authorization mode or handler type, an override whose target is
not a built-in, or a declared parameter colliding with the reserved
`kind`/`path`/`location` arguments.

## 5. Parameter collision policy

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

## 6. Callback contract and trust boundary

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
not caught there — handlers must normalize their own failures.

## 7. Single-file patch; multi-file changes are not supported

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
