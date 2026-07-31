# Workflow Tools

A Scout **Workflow** is a module of tasks with typed inputs and outputs.
`LLM.workflow_tools` introspects such a workflow and exposes its tasks as
function-calling tools that the LLM can invoke during inference. Because the
parameter schema is derived from the task's input declarations, you get typed,
validated tools for free — no manual JSON Schema authoring required.

This document covers:

- How workflow tasks become tools
- `LLM.workflow_tools` and `LLM.task_tool_definition`
- `LLM.workflow_ask` (convenience helper)
- Chat-file roles: `tool:`, `introduce:`, `task:`, `exec_task:`, `inline_task:`, `job:`, `inline_job:`
- How tool handlers dispatch to workflow jobs (`LLM.call_workflow`)
- Directory-scoped access (`allow_dir` / `allow_read_dir`)
- Practical examples

For the general tools overview (registry shape, dispatcher, output limits), see
[Tools.md](Tools.md). For how the calling loop works at the backend level, see
[../Backends/Backends.md](../Backends/Backends.md).

---

## 1. How workflow tasks become tools

Each Scout workflow task has metadata accessible via `workflow.task_info(name)`:

| Field | Source |
|---|---|
| `:inputs` | Declared input names |
| `:input_types` | Per-input type (`:string`, `:float`, `:file_array`, …) |
| `:input_descriptions` | Per-input description strings |
| `:input_options` | Per-input options (`:required`, `:select_options`, …) |
| `:description` | Task-level description |

`LLM.task_tool_definition` converts this metadata into an OpenAI-style function
schema. The result is an `IndiferentHash`:

```ruby
{
  name: :bake_muffin_tray,
  description: "Bake a tray of muffins",
  parameters: {
    type: "object",
    properties: {
      flavor: { type: :string, description: "Muffin flavor" },
      count:  { type: :integer, description: "Number of muffins" },
      return_path: { type: 'boolean', description: 'Instead of the result...' }
    },
    required: ["flavor"]
  }
}
```

### 1.1 Type mapping

`LLM.scout_to_tool_input_type` maps Scout input types to JSON Schema types:

| Scout input type | JSON Schema type |
|---|---|
| `:text`, `:path` | `:string` |
| `:chat` | `:text` → `:string` |
| `:select` | `:string` (+ `enum` from `select_options`) |
| `:float` | `:number` |
| `:integer` | `:integer` |
| `*_array` | `:array` (with `items: { type: :string }`) |
| other | unchanged |

### 1.2 The `return_path` parameter

For **non-exec** tasks, an extra boolean parameter `return_path` is injected:

```ruby
properties[:return_path] = {
  type: 'boolean',
  description: 'Instead of the result of the job, return the path were it is persisted'
}
```

When the model sets `return_path: true`, the tool returns the file path on disk
rather than loading the result into the context window. This is essential for
large outputs (see [Tools.md](Tools.md) §3.3 on output limits).

### 1.3 Required inputs and defaults

- Only inputs explicitly marked `required: true` in their input options are
  added to the `required` array.
- You can set defaults via the `inputs` filter using `"name=value"` strings.
  These populate `parameters[:defaults]`, which is stripped before sending to
  the model and re-applied during execution.

```ruby
# Expose only :source with a default for :threshold
LLM.task_tool_definition(MyWorkflow, :my_task, [:source, "threshold=0.5"])
```

---

## 2. `LLM.workflow_tools`

**Signature:**

```ruby
LLM.workflow_tools(workflow, tasks = nil)
```

Builds a complete tool registry (`{ name => [executor, definition] }`) from a
workflow.

**Task selection logic:**

1. If `tasks` is provided, only those tasks are exposed.
2. If `tasks` is `nil`, uses `workflow.all_exports` (explicitly exported tasks).
3. If no exports exist, falls back to `workflow.all_tasks`.

**Multi-workflow support:** If `workflow` is an Array, tool definitions from
each workflow are merged recursively.

```ruby
# All exported tasks
tools = LLM.workflow_tools(Baking)

# Specific tasks only
tools = LLM.workflow_tools(Baking, [:bake_muffin_tray, :bake_cake])

# Multiple workflows
tools = LLM.workflow_tools([Baking, Search])
```

Each tool entry is `{ task_name => [workflow_module, definition] }`. The
executor slot holds the workflow module so `LLM.call_workflow` knows which
workflow to dispatch to.

---

## 3. `LLM.call_workflow` — dispatch

When the model calls a workflow tool, `LLM.process_calls` dispatches to
`LLM.call_workflow`:

**Signature:**

```ruby
LLM.call_workflow(workflow, task_name, parameters = {})
```

**Process:**

1. Extract special parameters: `jobname`, `return_path`, `exec_type`,
   `allow_recursive`.
2. Create a job: `workflow.job(task_name, jobname, parameters)`.
3. **Dispatch rules:**

   | Condition | Action | Returns |
   |---|---|---|
   | Task is an `exec_export` or `exec_type == 'exec'` | `job.exec` (synchronous, in-process) | Result value |
   | `return_path == true` | `job.run(true)` (async) then return path | File path string |
   | Default | **Recursion guard**, then return the `Step` | `Step` object (deferred) |

### 3.1 The recursion guard

To prevent infinite loops (an agent calling a workflow task that itself
triggers another agent call), `call_workflow` raises a `ScoutException` if the
job is already running with the current PID:

```ruby
raise ScoutException, 'Potential recursive call' if allow_recursive != 'true' &&
  (job.running? && job.info[:pid] == Process.pid)
```

Bypass with `allow_recursive: 'true'` when intentional recursion is needed.

### 3.2 Deferred Step production

When a tool returns a `Step` (the default path), `LLM.process_calls` collects
all Steps from the current model turn and batch-produces them via
`Workflow.produce(jobs)`, potentially in parallel. Results are then loaded.
This lets the model call multiple workflow tools in one turn and have them
execute concurrently. See [Tools.md](Tools.md) §7.2.

---

## 4. `LLM.workflow_ask` — convenience helper

> Originally documented in the legacy `LLM.md` §6.1; now canonical in this document.

```ruby
LLM.workflow_ask(workflow, question, options = {})
```

This one-liner builds the tools from the workflow and calls `LLM.ask`:

```ruby
def self.workflow_ask(workflow, question, options = {})
  workflow_tools = LLM.workflow_tools(workflow)
  self.ask(question, options.merge(tools: workflow_tools)) do |task_name, parameters|
    workflow.job(task_name, parameters).run
  end
end
```

Example:

```ruby
LLM.workflow_ask(Baking, "Bake a chocolate muffin tray", endpoint: :nano)
```

The block is the fallback executor for tools whose executor slot is `nil`. In
this case the workflow module is the executor, so the block is not normally
reached — but it provides a safety net.

---

## 5. Chat-file roles for workflows

Several chat-file roles interact with workflows. They are processed during
`LLM.chat` compilation (before the model is called) or during tool extraction
(`Chat.tools`).

### 5.1 `tool:` — register workflow tasks as tools

```text
tool: Baking bake_muffin_tray
```

Registers a single task as a tool. Without a task name, registers all tasks:

```text
tool: Baking
```

With input filters:

```text
tool: Baking bake_muffin_tray flavor count=6
```

This is processed by `Chat.tools()`, which calls `LLM.task_tool_definition` or
`LLM.workflow_tools` and accumulates the result into the tool registry. The
`tool:` message is **consumed** (removed from the message array) after
processing.

Remote workflows are also supported:

```text
tool: https://example.com/scout/workflow/MyWorkflow task_name
```

### 5.2 `introduce:` — inject documentation + register all tasks

```text
introduce: Baking
```

This:

1. Loads the workflow.
2. Registers **all** its tasks as tools (same as `tool: Baking` without a task
   name).
3. Injects a `user` message containing the workflow's documentation (title +
   description), so the model knows what the workflow does.

Duplicate introductions of the same workflow are deduplicated.

### 5.3 `task:` — run a task inline and inject the result

```text
task: Baking bake_muffin_tray flavor=chocolate count=6
```

This **executes** the task during compilation (not as a tool call). The job is
created and produced via `Workflow.produce`. The result is injected as a `job:`
message (see §5.5), which is then resolved into `function_call` /
`function_call_output` pairs so the model sees the task output as context.

### 5.4 `exec_task:` — run a task synchronously (no persistence)

```text
exec_task: Baking bake_muffin_tray flavor=chocolate
```

Runs the task via `job.exec` (synchronous, in-process, no Scout persistence).
The result is injected directly as a `user` message. This is faster but does
not benefit from Scout's job caching, dependency tracking, or provenance.

### 5.5 `job:` and `inline_job:` — inject job results

```text
job: ~/.scout/var/jobs/Baking/bake_muffin_tray/abc123
```

Loads a previously-run Scout job and injects its result as a
`function_call` / `function_call_output` pair. If the job is done, the result
is read from disk. If it's streaming, it's joined. If it errored, an exception
JSON is injected.

```text
inline_job: ~/.scout/var/jobs/Baking/bake_muffin_tray/abc123
```

Injects the job's **file path** as a `file:` message, rather than loading the
content. This is useful for large outputs.

### 5.6 Summary table

| Role | When processed | Effect |
|---|---|---|
| `tool:` | `Chat.tools()` | Register task(s) as tools (consumed) |
| `introduce:` | `Chat.tools()` | Register all tasks + inject docs (consumed, deduplicated) |
| `task:` | `Chat.tasks()` | Execute job, inject result as `job:` message |
| `exec_task:` | `Chat.tasks()` | Execute synchronously, inject result as `user` message |
| `inline_task:` | `Chat.tasks()` | Create job, inject path as `inline_job:` message |
| `job:` | `Chat.jobs()` | Load job result, inject as function_call/output pair |
| `inline_job:` | `Chat.jobs()` | Inject job file path as `file:` message |

---

## 6. How tool handlers dispatch to workflow jobs

The full dispatch chain when the model calls a workflow tool:

```
Model emits tool_call(name="bake_muffin_tray", args={flavor:"chocolate"})
    │
    ▼
LLM.process_calls(tools, [tool_call])
    │
    ├─ Look up: obj, definition = tools["bake_muffin_tray"]
    │  obj = Baking (Workflow module)
    │
    ├─ Apply defaults from definition[:parameters][:defaults]
    │
    ├─ Dispatch: obj is a Workflow → LLM.call_workflow(Baking, "bake_muffin_tray", args)
    │
    ├─ call_workflow:
    │    job = Baking.job(:bake_muffin_tray, nil, flavor: "chocolate")
    │    Returns Step (deferred)
    │
    ├─ process_calls collects Step
    │
    ├─ Workflow.produce([job]) — batch production (parallel if multiple)
    │
    ├─ Load result: job.load
    │
    └─ Build output messages:
         { role: "function_call", content: tool_call.to_json }
         { role: "function_call_output", content: { name:, content:, id: }.to_json }
```

The model then sees the tool result and can continue its response.

---

## 7. Directory-scoped access: `allow_dir` / `allow_read_dir`

When workflow tools are registered, Scout grants filesystem access so the model
can reference workflow source files and job outputs.

### 7.1 `Chat.allow_read_dir`

Called by `LLM.workflow_tools`:

```ruby
Chat.allow_read_dir(workflow.directory)
```

This adds the workflow's source directory to a thread-local list of allowed
read directories. When tools are executed inside a sandbox (e.g., `bwrap`),
these directories are whitelisted for read access.

### 7.2 `Chat.allow_dir`

Grants full (read/write) access to a directory. Used less frequently than
`allow_read_dir`.

### 7.3 Job directory access

When `LLM.ask` processes messages containing `meta job=...` references (from
prior tool calls or imports), it grants read access to those jobs'
`files_dir`:

```ruby
job_paths.each do |job_path|
  job = Step.load(Path.setup(job_path))
  jobs = [job] + job.rec_dependencies.to_a
  jobs.each { |j| Chat.allow_read_dir(j.files_dir) if Open.exist?(j.files_dir) }
end
```

This allows the model to reference files produced by upstream jobs during tool
execution. See [../Chat/Persistence.md](../Chat/Persistence.md) §7.3.

---

## 8. Practical examples

### 8.1 Expose a workflow programmatically

```ruby
module Baking
  extend Workflow

  task :bake_muffin_tray => :text do |flavor = "blueberry", count = 6|
    "Baking a #{count}-count #{flavor} muffin tray..."
  end
end

tools = LLM.workflow_tools(Baking)
LLM.ask("Bake a chocolate muffin tray", tools: tools, endpoint: :nano)
```

### 8.2 Subset of tasks

```ruby
tools = LLM.workflow_tools(Baking, [:bake_muffin_tray])
```

### 8.3 Multiple workflows

```ruby
tools = LLM.workflow_tools([Baking, Search])
LLM.ask("Search for muffin recipes and bake one", tools: tools, endpoint: :nano)
```

### 8.4 Using the convenience helper

```ruby
LLM.workflow_ask(Baking, "Bake muffins", endpoint: :nano)
```

### 8.5 Chat file with `tool:` role

```text
tool: Baking bake_muffin_tray

user:

Bake a chocolate muffin tray using the tool.
```

```bash
scout-ai llm ask -c baking.chat -e nano
```

### 8.6 Chat file with `introduce:` role

```text
introduce: Baking

user:

I want to bake something. What can you do?
```

### 8.7 Chat file with `task:` (inline execution)

```text
task: Baking bake_muffin_tray flavor=chocolate count=12

user:

Based on the baking result above, suggest a beverage pairing.
```

The task runs during compilation, and its output is injected as context before
the model sees the user message.

### 8.8 Using `return_path` for large outputs

When the model calls a workflow tool, it can set `return_path: true` to get the
file path instead of loading the full result:

```ruby
# The model decides to call:
#   bake_large_dataset(return_path: true)
# → Returns: "~/.scout/var/jobs/MyWorkflow/bake_large_dataset/abc123"
```

This keeps the context window small. The model can then use a `file:` role or a
follow-up tool to read specific portions.

---

## 9. Cross-references

- [Tools.md](Tools.md) — the unified tool registry, `process_calls` dispatcher,
  output limits
- [../Backends/Backends.md](../Backends/Backends.md) — `chain_tools` loop,
  `format_tool_definitions`
- [../Chat/Chat.md](../Chat/Chat.md) — chat-file roles, compilation pipeline
- [../Chat/Persistence.md](../Chat/Persistence.md) — job directories, `files_dir`
- [../Agent/Agent.md](../Agent/Agent.md) — how agents auto-wire workflow tools
