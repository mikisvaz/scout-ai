# prov verbosity fix notes

## Problem

The `scout-ai llm prov` command output was too verbose and token counts were
wrong.

Two issues:

1. **Verbosity**: The output showed many redundant nodes — `agent.chat` log
   files, zero-token result chats, `(seen)` repeated nodes, inline relation
   labels, and long filesystem paths.

2. **Token counts**: The root chat showed `total=0` because it had no direct
   inference tokens. Every parent node should show the aggregate cost of its
   entire provenance subtree.

## Root causes

### Job resolution

`Step.load` with a relative workflow reference like
`Planned/ask/Default_xyz.chat` resolved via `Path.find` to
`~/.scout/Planned/ask/Default_xyz.chat`, but the actual job data lives at
`~/.rbbt/var/jobs/Planned/ask/Default_xyz.chat`. The `.scout` directory did not
contain the job files, so traversal stopped immediately.

### Redundant nodes

The traversal visits chat files connected to jobs via four relations: `job`,
`dependency`, `log`, `result`. Of these:

- **`log` relation with `agent.chat`**: This is the chat produced by the
  inference backend, stored at `<job>.files/log/agent.chat`. Its tokens are the
  same tokens counted as the job's direct cost. Showing it as a separate node
  duplicates the parent's cost.
- **`result` relation**: A chat-typed job's persisted result file IS the same
  path as the job itself. The `[:chat, path]` node is a duplicate of the
  `[:job, path]` node.
- **Repeated nodes in shared DAG branches**: When a dependency appears in
  multiple branches, it was shown as `(seen)` in the old verbose output.

### Token aggregation

The old code only showed each node's **direct** token cost (from its own
`agent.chat` or log files). This meant a root chat with no direct inference
showed `total=0`. The correct behavior is to aggregate the entire subtree's
inference cost.

## Fixes applied

### `lib/scout/llm/chat/provenance.rb`

Added `Chat.load_job_reference(reference)` helper that tries the standard
`~/.rbbt/var/jobs/` storage location as a fallback when `Step.load` resolves to
a non-existent path. The traversal uses this for all `chat.jobs` references.

### `scout_commands/llm/prov`

1. **Hidden nodes**: `agent.chat` log files and result-relation chats are
   skipped entirely in tree mode (not printed, not traversed into).

2. **No `(seen)` lines**: Repeated nodes are silently skipped in tree mode.

3. **No inline relation labels**: Tree lines show just `kind tokens label`.

4. **Shortened paths**: Log chats under jobs show their path relative to the
   job's `.files/log/` directory (e.g. `society/Worker/cli_investigation.chat`).

5. **Aggregate mode** (default): Each node shows the total cost of all
   reachable chat files in its provenance subtree, deduplicated by path.

6. **Component mode** (`--component`): Each node shows only its own direct
   token cost.

7. **Flow and DOT modes**: Same hidden-node filtering applied. Flow mode shows
   data-flow arrows (result/dependency/log) between visible nodes.
