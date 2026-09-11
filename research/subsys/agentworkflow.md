# 06 - AgentWorkflow mixin and job binding

> Investigation, not normative documentation. Verified behavior of the
> `AgentWorkflow` mixin, its seven helpers, `Workflow#chat_task`, the
> `Workflow.require_workflow` agent fallback and the job bindings they
> create. There is no dedicated developer page; the architecture table row
> in `doc/developer/Architecture.md` is the only maintained description.
> User-level context: `doc/user/MultiAgentWorkflows.md`,
> `doc/user/BuildingAgents.md`, `doc/developer/DelegationInternals.md`.

## Scope

`lib/scout/llm/agent/workflow.rb` (184 lines) and the `LLM::Agent#job`
accessor it declares. Delegation *semantics* are owned by
`research/subsys/agent-delegation.md`.

## Verified behavior

### Layout and loading

```
lib/scout/llm/agent/workflow.rb
  3    module AgentWorkflow; extend Workflow
  6-14   helper :chat
  16-18  helper :options
  20-22  helper :agent_options
  24-32  helper :tooling
  34-36  helper :tooling_intro
  38-110 helper :agent
  112-131 helper :log_agent
  134-162 module Workflow#chat_task
  164-166 alias require_workflow_old require_workflow
  168-177 def self.require_workflow(name, ...) - agent fallback
  182-184 class LLM::Agent; attr_accessor :job
```

`AgentWorkflow` is required last in `lib/scout/llm/agent.rb`, so loading
scout-ai always applies the `Workflow` patch and the `job` accessor.

### The seven helpers

| helper | behaviour |
|---|---|
| `chat` | memoized `@chat`; seeded from `recursive_inputs[:chat]`, `Chat.parse` for Strings, `[]` when nil, then `Chat.setup` |
| `options` | memoized `LLM.options(self.chat)` - the chat-embedded options |
| `agent_options` | `IndiferentHash.setup(options.except(:agent, :chat))` - strips the `agent`/`chat` keys before `LLM.load_agent` |
| `tooling` | memoized; **destructively extracts** the `tool`, `kb`, `mcp`, `introduce` roles out of `self.chat` via `Chat#remove_role` (which `reject!`s the receiver) and returns their concatenation |
| `tooling_intro` | `self.tooling.select { role == 'introduce' }` - the non-destructive half |
| `agent` | job binding at creation time (below) |
| `log_agent` | end-of-task sweep (below) |

Because `tooling` mutates `self.chat`, calling it (directly or through the
`agent` helper's default) permanently removes those messages from the job's
chat view. `tooling_intro` is the read-only half intended for specialists.

### `Workflow#chat_task`

Defines one input `[:chat, :text, "Chat in Scout-AI chat-file format"]` and a
task of **type `:chat`** (extension `.chat`). The type is what makes
`Workflow::TYPE_EXTENSIONS[:chat]` meaningful: the job's persist path goes
through the chat driver, whose save arm computes `current_chat - start_chat`
for an `LLM::Agent` content.

Inside the task:

- `Chat.allow_path files_dir` whitelists the files dir before the block runs;
  there is no eager `mkdir` - the directory appears lazily when the save
  machinery writes into it.
- The user block is run via `self.instance_exec(&block)` with **no
  arguments**; the wrapper's `|chat|` parameter is never forwarded, so blocks
  declaring parameters get nil/empty and must read the chat through the
  `chat` helper.
- Every successful result gets exactly one leading `meta: job=<short path>`
  marker via `Chat.project`.

Return-value contract:

| block returns | outcome |
|---|---|
| `LLM::Agent` | if `current_chat` does not already end in an assistant message -> `agent.chat(return_messages: true)` (a real inference round); if it does -> no inference, result is the delta `current_chat - start_chat`. Either way `log_agent(agent)` runs and the delta is projected. |
| `Hash` | wrapped as `[hash]` |
| `Array` / `Chat` | used directly, roles preserved |
| `String` / `Integer` / `nil` | `Chat.project` fails with a `TypeError` (`no implicit conversion of Symbol into Integer`) and the job ends in `error` status |
| `raise ScoutException` | rescued: the result is an assistant message whose content is JSON `{exception: {...}, job: <short_path>}`; job status `done` |
| `raise` anything else | propagates; job `error` status |

When the block raises, `log_agent` never runs - a mid-round-created child
conversation survives only through its creation-time anchor.

### The `agent` helper

```ruby
helper :agent do |name = nil, chat: nil, options: nil, tooling: nil,
                 job_path_message: true, files: nil, **kwargs|
```

1. `options` defaults to `self.options`, `tooling` to `self.tooling`; extra
   kwargs are merged over them with `IndiferentHash.add_defaults`.
2. `agent = LLM.load_agent(name, agent_options(options))`. The named form
   resolves through the five agent roots; an explicit *path* form returns
   `true` from `Kernel#load`, not an Agent.
3. **`agent.job = self`** - the Step is wired onto the agent *before* the
   first chat/start call, so per-round auto-save, restart snapshots and
   mid-round socialization all see a real parent anchor.
4. `agent.start_chat.follow tooling` unless empty - the extracted tooling
   seeds the new agent's start chat.
5. `agent.save_file = LLM::Agent.canonical_chat_file(files_dir, name)` ->
   `<job>.files/<name || 'agent'>.chat`.
6. `job_path_message: true` (default) appends a system message
   `Your current working directory is <Dir.pwd>. You are working through an
   ask job with path <path> and files_dir <files_dir>.` With `false` the
   message is absent. The code marks it "useful in multi-step inference
   workflows but which may interfere with cache mechanisms".
7. When the job `dependencies.any?`, a second system message lists
   `rec_dependencies.collect(&:path)` - with the code's own misspelling
   **"depencencies"**.
8. `files:` - each path is tried as `file(path)` (under the job's files dir)
   then as the raw path; existing ones are attached with
   `agent.start_chat.file`. Plain Strings break
   (`undefined method 'find' for String`); `Path.setup(...)` objects are the
   supported form.
9. With a non-empty `chat`: `other_jobs = chat.jobs`; any -> system message
   `There are other jobs found in this chat:` plus the list. The chat is then
   `reject!`-filtered of recycled prompts - messages starting with
   `You have been assigned`, `This workflow job has the following`,
   `There are other jobs found in this chat` - and followed into
   `start_chat`.
10. The helper body runs in the **job process** (fork); a test must read the
    persisted `<job>.files/<name>.chat` after `produce` - in-process
    instrumentation around `job.produce` never sees these lines.

### `log_agent`

- `agent.save_file = LLM::Agent.canonical_chat_file(files_dir, agent_name)
  if agent.save_file.nil?` - it only fills a missing anchor, never overrides
  the one the `agent` helper assigned. `agent_name` defaults to `'agent'` and
  "names the file, never a directory".
- `agent.save` - delegates to the Agent save machinery so every path
  (`chat_task` jobs, CLI, plain `agent.save`) writes the identical canonical
  layout: this agent's full chat at `<files_dir>/<name>.chat` and nested
  conversations under `<files_dir>/<name>.society/<agent>/<conversation>/agent.chat`.
- `update_info :dependencies, dependencies.collect { |d| d.path.find }` -
  rewrites the job info's dependency list with resolved paths, fixing
  dependencies created *during* the block.
- returns the agent.

### `Workflow.require_workflow` agent fallback

Patched onto `module Workflow` itself: on failure of the normal
`require_workflow`, it tries `LLM.load_agent(name).workflow` and re-raises
the original error if that also fails.

- Only the **named** form works: `LLM.load_agent(name)` returns an Agent
  whose `#workflow` accessor holds the loaded module; the path form returns
  `true` and the fallback then fails with the original workflow error.
- The returned module is a *fresh* object per call (`fallback_same_object`
  false), distinct from the `@@agent_workflow` cache entry of a prior
  `load_agent` call - whether anything relies on module identity across
  those two entry points is unexplored.
- Purpose: agent directories (`Agent/<Name>` with `agent.rb`, `workflow.rb`,
  `python/`) can be `require_workflow`-ed as if they were workflows;
  `agent.rb` is `load`ed for side effects, `workflow.rb` goes through
  `Workflow.require_workflow_file`, and a python agent directory through
  `PythonWorkflow.load_directory`.

### `LLM::Agent#job`

Declared both in `agent/workflow.rb:182-184` and in `lib/scout/llm/agent.rb`'s
accessor list. It is what lets `Agent#chat` route through `workflow.job(...)`
when a workflow with a matching task is attached.

## Sharp edges and known issues

- **`tooling` is destructive** (F20, open): it extracts tool/kb/mcp/introduce
  roles out of the job chat permanently. Undocumented; explains why
  `tooling_intro` exists.
- **The "depencencies" misspelling is load-bearing** (F20, open): the
  dependencies system message literally says "depencencies" and the recycle
  filter matches that same misspelled prefix - fixing the spelling would
  break the filter.
- **`chat_task` non-message returns fail opaquely** (open): a `String`/
  `Integer`/`nil` return surfaces as a `TypeError` deep inside
  `Chat.project`. A coercion or clearer error would be a cheap DX win.
- **MultiAgentWorkflows.md's first snippet would fail** (F20, open): it shows
  `extend Workflow` + bare `chat_task` whose block calls `self.agent(...)`;
  `self.agent` needs `include AgentWorkflow`. `chat_task` itself is patched
  onto `Workflow`, so the task *registers* without the mixin, but the block
  then cannot use the helpers.
- **No dedicated developer doc** for the mixin (F20, open): the architecture
  row names only `chat_task`, `helper :agent` and `helper :log_agent`,
  omitting `chat`/`options`/`agent_options`/`tooling`/`tooling_intro` and the
  `require_workflow` patch.
- **Mix in with `include_workflow`, not `include`** (F20, open):
  `include AgentWorkflow` alone does not copy the helper blocks into the
  module's helpers hash (helpers are class-level state), so `Workflow#job`
  would extend the Step with an empty `step_module` and `log_agent` would be
  missing at run time. Documented verbatim in
  `test/scout/llm/agent/test_workflow.rb:50-53`.

## Open questions

- Whether anything relies on module identity between
  `Workflow.require_workflow`'s fallback result and the `@@agent_workflow`
  cache entry of a `load_agent` call for the same name.
- The `agent` helper's `files:` branch calls `file(path)` (job-relative)
  before the raw path; the precedence is verified only by inspection.
- Documenting `tooling`'s destructive mutation next to `tooling_intro`.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch); no fix in this sweep touches this subsystem.

- Code: `lib/scout/llm/agent/workflow.rb` (all line references above);
  `lib/scout/llm/agent.rb:174-232`; `lib/scout/llm/chat/persist.rb`;
  `lib/scout/llm/chat/annotation.rb:150-155` (`remove_role`);
  `lib/scout/llm/chat/process/meta.rb:408` (`Chat.project`);
  scout-gear `lib/scout/workflow/definition.rb` (`Workflow::TYPE_EXTENSIONS`,
  `include_workflow`).
- Tests read: `test/scout/llm/agent/test_workflow.rb` (the mixin/step_module
  hazard and the socialize-then-ScoutException path are documented in its
  comments).
- Probe receipts (Cortex artifacts `probe/agentworkflow_{surface,chat_task,
  agent_helper}.rb`, run with `ruby -Ilib` from the repo root, asserting on
  the persisted job files because the helper body runs in the job fork):
  helper inventory and `Workflow` patch surface; `chat_task` task shape and
  the full return-value table; block arity; `agent` helper keyword surface
  and `job_path_message` on/off; the dependencies message and the
  "depencencies" spelling; `files:` with Path vs String; the other-jobs
  message and the three recycled prefixes; `log_agent` fallback anchor;
  `require_workflow` fallback mechanics; `include` vs `include_workflow`
  helper lists.
