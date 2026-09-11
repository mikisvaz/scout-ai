# 10 - Agent directories and the society harness

> Investigation, not normative documentation. Verified behavior of the
> `Agent/<Name>` directory convention, `load_agent` resolution, the runtime
> society, the on-disk `society/` save tree, chat-level references between
> agents and the CLI harness. Normative reference:
> `doc/user/BuildingAgents.md`, `doc/developer/DelegationInternals.md`,
> `doc/developer/Architecture.md`.

## Scope

The `Agent/<Name>/{start_chat,workflow.rb,agent.rb,knowledge_base,python}`
convention, `LLM::Agent.load_agent` resolution mechanics, the runtime
`@society`/`@chats` state, the on-disk `society/` save tree, chat-level
`import:` references and the `agent ask|find|kb` CLI. Agent class semantics
are owned by `research/subsys/agent-delegation.md`; the `AgentWorkflow`
mixin by `research/subsys/agentworkflow.md`.

## Verified behavior

### What a named agent is on disk

A named agent is a directory whose *name* is resolvable through Scout path
maps. **There is no manifest, no roster file and no declaration step.** A
directory may contain any of:

| entry | effect at load time |
|---|---|
| `start_chat` (also `start_chat.chat`) | chat file -> `agent.start_chat` seed (system prompt, options, `tool:`/`introduce:`/`kb:`/`mcp:` roles) |
| `workflow.rb` | Scout workflow -> tools via `LLM.workflow_tools`; also the fallback `introduce` seed when no `start_chat` exists |
| `agent.rb` | Ruby file whose last expression must be an `LLM::Agent` (Kernel `load`ed) |
| `knowledge_base/` | `KnowledgeBase.load` if it exists |
| `python/` with `*.py` | `PythonWorkflow.load_directory dir, 'ScoutAgent'` -> workflow |
| `workflow.md` / `README.md` | never read by the agent loader; only `Workflow#documentation` reads them from a workflow's own libdir |

Details:

- `start_chat` wins over `start_chat.chat`; if only `start_chat.chat` exists
  the seed is **empty** (see the sharp edges below).
- `agent.rb` and `workflow.rb` in the same directory: `agent.rb` is used for
  the agent *object*, and it must itself return an Agent - a plain
  `agent.rb` that does not ends in an Agent raises `NoMethodError`.
- Deep nested names work (`Agent/Deep/Nested/start_chat` loads as agent name
  `'Deep/Nested'`); snake/lowercase names work; Symbols are accepted.

### `load_agent` resolution algorithm

`lib/scout/llm/agent.rb:174-228`:

1. A Symbol name is stringified.
2. **Filename branch** (`Path.is_filename?(agent_name)` - a string without
   newlines that *exists on disk*; note this is `File.exist?`, not
   `Open.exists?`, so remote names never enter this branch):
   - a directory with `agent.rb` -> `load dir.agent.rb`;
   - any other existing file -> `load agent_name`;
   - an existing directory *without* `agent.rb` falls through to the named
     branch with the full path as the "name" - typically
     `No agent found with name <path>`.
3. **Named branch** - candidates, each tried only when the previous
   `.exists?` is false: `Scout.workflows[name]`, `Scout.Agent[name]`,
   `Scout.var.Agent[name]`, `Scout.chats.Agent[name]`, `Scout.chats[name]`.
   These are user-map lookups (`~/.scout/...`), but Scout pathmap resolution
   still applies the `current` map, which is how `Agent/<name>` in a repo
   root is found; after `Dir.chdir` a previously resolvable PWD agent is no
   longer found (resolution is PWD-at-call-time).
   Ordering nuance: the *workflow* candidate is checked first, and when
   `Scout.workflows[name]` exists it wins for the workflow and
   `agent_path = workflow_path`, so `start_chat`/`knowledge_base` are then
   looked up inside the workflow checkout.
4. `raise ScoutException, "No agent found with name #{agent_name}"` unless
   `workflow_path.exists? || agent_path.exists?`.
5. Workflow selection (first match): `Workflow.require_workflow(name)` when
   `Scout.workflows[name]` exists (the autoinstall/git-clone branch - it can
   hang a probe through the `TryAgain` retry loop); else
   `Workflow.require_workflow_file(agent_path.workflow.rb)` when present;
   else `PythonWorkflow.load_directory(agent_path.python, 'ScoutAgent')`
   when `python/*.py` exist; else the workflow stays nil (start_chat-only
   agent).
6. Knowledge base: `agent_path.knowledge_base` else
   `workflow_path.knowledge_base`.
7. start_chat: `agent_path.start_chat` else `workflow_path.start_chat` else -
   when a workflow exists and `workflow.documentation[:description]` is
   non-empty - `[{role: 'introduce', content: workflow.name}]`; else empty.
8. `LLM::Agent.new(**options.merge(workflow:, knowledge_base:, start_chat:))`
   and `agent.path = agent_path.find` (used by `scout agent find`).

`doc/user/BuildingAgents.md`'s discovery list matches steps 3.1-3.5; it
omits the filename branch entirely and the workflow-checkout redirect.

### Caching and module identity

- `@@agent_workflow ||= {}` caches **workflows** per name - a class variable
  shared across all callers. Two different directories defining the same
  module name yield the **same** module object (first definition wins; the
  second `require_workflow_file` does not redefine it). Editing
  `workflow.rb` mid-process does not invalidate the cache. The module is
  shared across agent *templates* too.
- The **Agent object is not cached**: `load_agent` returns a fresh Agent each
  call. The per-name template identity that matters at runtime is
  `@society[name]` inside each parent (`@society[agent_name] ||=
  load_agent(...)`) - one immutable template per specialist per parent,
  cloned per conversation.
- `socialize` does not preload anything: `@society` stays empty until the
  model actually calls `ask`.

### Tooling provisioning

Nothing tool-related happens inside `load_agent`. Tools are assembled at
**ask time** in `Agent#ask`: `options[:tools]` merged with
`@other_options[:tools]` (where `socialize`'s `ask` tool and the
`hand_off_to_*` tools live), then `LLM.workflow_tools(workflow)` for a
workflow with tasks, then the KB tools.

The start_chat seed carries tool roles which the chat pipeline expands at
prepare time: `tool:` -> `Chat.load_workflow(name)` + one tool per task (or
a single task with input restriction); `introduce:` ->
`Workflow.require_workflow` + a `user`-role documentation block; `kb:` ->
`KnowledgeBase.load`, falling back to `LLM.load_agent(name).knowledge_base`.

`Chat.load_workflow` has its own resolution: a constant first, then
`Scout.chats.Agent[workflow]['workflow.rb']` (**only** the chats.Agent map),
then `Workflow.require_workflow`. So a `tool: Name` in a start_chat can
resolve against an agent directory even when `load_agent('Name')` would find
it elsewhere.

### The runtime society

- `@society` (per parent): `name -> immutable template Agent`. `@chats`:
  `"<name>/<conversation>" -> conversation holder`.
- Names are validated by `SOCIAL_AGENT_NAME = /\A[a-z_.-]+\z/i` in
  `normalize_social_agent_name` (a bad name raises `ParameterException`);
  conversations by `SOCIAL_CONVERSATION_NAME = /\A[a-z0-9][a-z0-9_.-]*\z/i`.
- Inheritance modes `none/tools/conversation`; private options are stripped
  by `SOCIAL_PRIVATE_OPTIONS` - only things like `endpoint`/`model` flow to
  specialists.
- The roster is a **free string parameter**: the `ask` tool's `agent`
  property is `{type: string, description: "Name of the specialist agent to
  ask"}` with `required ["agent","prompt"]` - no enum, no schema-level
  validation, no discovery of available specialists. Availability is decided
  at call time by `load_agent(name)`; an unknown name surfaces as the
  `ScoutException` returned as the tool result.
- **No "society import" or "specialization" feature exists in the code.**
  Those words appear only in unmaintained research notes describing another
  repository's conventions. The closest real mechanism is N sibling agent
  directories plus `import:`/`tool:`/`introduce:` chat-file references and
  an orchestrator that `socialize`s.

### Chat-level references between agents

- `import:` (and `continue:`/`last:`) roles are expanded by `Chat.imports`
  via `find_file`, which resolves in order: relative to the importing chat's
  directory, the caller's libdir, the literal path, a remote URL, then
  `Scout.chats[file]`.
- `Chat#import(file)` just appends `{role: 'import', content: file}`; the
  expansion happens later in the pipeline.
- A `main.chat` with `import: other.chat` expands into the other chat's
  messages inline, resolved relative to `main.chat`. This is how one agent's
  start_chat can absorb another agent's chat file, including its
  `tool:`/`introduce:` declarations - the practical "society import".

### The on-disk `society/` tree

- `Agent::SOCIETY_DIR = 'society'`, `SOCIETY_CHAT_FILE = 'agent.chat'`,
  `SAVE_DEPTH_LIMIT = 32`.
- Root rule `society_dir_for(chat_path)`: `<name>.chat` -> sibling
  `<name>.society`. Nested rule `society_dir(path)`: a chat already inside a
  society tree (`nested_save?` - exactly three directory levels up named
  `society` or `*.society`) keeps a plain `society` sibling.
- `canonical_chat_file(files_dir, name)` = `<files_dir>/<name || 'agent'>.chat`
  - the single source of truth for `AgentWorkflow#log_agent`,
  `scout agent ask` and `llm ask --chat`.
- A parent with one open child conversation saves `root.chat` plus
  `root.society/Child/work_1/agent.chat`, matching the documented layout.
  `Agent#save` assigns a save_file to every reachable child so later turns
  auto-save in place.
- The society tree is *scanned* by provenance (`society_dir_of`,
  `society_agent_chats` - bounded scan, depth limit 128, `agent.chat` files
  only, no symlinks - and `society_live`). `Chat.society_dir_of` delegates
  to the Agent rules when the class is loaded and mirrors save.rb otherwise.
- Provenance deliberately treats society chats as independent recovery
  artifacts, not logs (`DIRECT_LOG_CHAT_GLOBS`).

### CLI harness

- `scout_commands/agent/ask` - `LLM::Agent.load_agent(agent_name)` with
  ARGV[0] the agent name; endpoint/model overrides; `-t` template (resolved
  against `Scout.questions`, `Scout.chats.system`, `Scout.chats`);
  `-c` chat (follow + `save_file = canonical_chat_file(chat + '.files',
  agent_name)` -> auto-append to the chat file); `-w` extra workflow tool;
  `-i` imports; `-f` files; inline `# ask:` rewriting in files.
- `scout_commands/agent/find` - loads the agent and prints `agent.path`.
- `scout_commands/agent/kb` - `agent_dir = Scout.var.Agent[agent]` **only**
  (not the five-way lookup), then delegates to `scout kb` with
  `--knowledge_base <dir>`.

## Sharp edges and known issues

- **`start_chat.chat` is silently ignored when `start_chat` exists, and
  yields an empty seed when alone** (F19, open): `find_with_extension`
  returns the missing literal `start_chat` path, and `LLM.chat(path)` then
  reads a missing file silently - a silent misconfiguration.
- **The `@@agent_workflow` cache is process-global, shared and never
  invalidated** (F19, open): first module definition wins; `workflow.rb`
  edits are invisible until restart; two directories with the same module
  name share the first module.
- **`scout agent kb` hard-codes `Scout.var.Agent[agent]`** (F16, open): one
  of the five lookup roots, so agents living in `Scout.Agent` or
  `Scout.chats.Agent` are unreachable; and `Chat.load_workflow` (`tool:`
  roles) uses only `Scout.chats.Agent`, diverging from `load_agent`'s five
  roots for the same name.
- **`agent.rb` undocumented in user docs** (open): the Kernel-`load` branch
  and its "last expression must be an Agent" contract appear only in
  Architecture.md's table.
- **Workflow-only agents do not always get an `introduce` seed** (open): the
  seed comes only from `workflow.documentation[:description]`; a
  `workflow.rb` with task descriptions but no workflow-level description
  yields no seed - and `description 'x'` inside a module body raises
  `ArgumentError` because `Workflow#description` is an accessor, not a DSL
  setter.
- **`Path.is_filename?` requires existence** (open): a non-existing absolute
  path is silently treated as a *name*, so
  `load_agent('/abs/path/that/does/not/exist')` fails with
  `No agent found with name /abs/...` - a confusing error message.
- `agent.path` is set only in the named branch; filename-branch agents have
  `path == nil` (`scout agent find` prints nothing useful for them).
- `load_from_path` exists but is dead code in the repo - no caller in lib/,
  test/ or scout_commands/.
- Architecture.md's require list for `agent.rb` is stale (it omits
  `conversation`, `attach`, `save`).
- The third `elsif` in the `start_chat` lookup (agent.rb:219-224) is an
  unreachable cosmetic dead branch.
- Python agents: the `python/` branch requires `python/*.py`;
  `PythonWorkflow.load_directory` shells out to the gem's own python env and
  could not be executed in the study environment - mechanism code-confirmed,
  not execution-verified.

## Open questions

- Does anything (ChatAnalyst, SC26-style suites) rely on
  `Agent/<Name>` being found via `Scout.chats.Agent` specifically, given
  `Chat.load_workflow` uses only that root for `tool:` roles? A silent
  divergence between `load_agent` and `Chat.load_workflow` for the same name
  is possible.
- Is there a supported way to reload an agent's workflow in-process (the
  cache is never invalidated; tests use fresh processes)?
- Whether the filename-branch-vs-name behaviour for non-existing paths is
  intended.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch); no fix in this sweep touches this subsystem.

- Code: `lib/scout/llm/agent.rb:160-238` (load_agent, requires);
  `lib/scout/llm/agent/{conversation,delegate,save,workflow,chat}.rb`;
  `lib/scout/llm/chat/process/{tools,files}.rb`;
  `lib/scout/llm/chat/annotation.rb`;
  `lib/scout/llm/chat/provenance.rb:1683-1810` (society scan);
  `lib/scout/llm/tools/workflow.rb:79-94`;
  `scout_commands/agent/{ask,find,kb}`; scout-essentials
  `lib/scout/path/util.rb:8-15` (`is_filename?`); scout-gear
  `lib/scout/workflow.rb`, `lib/scout/workflow/documentation.rb`.
- Probes (throwaway agent directories, no repo modifications, no LLM calls):
  resolution order, error messages, caching and module identity,
  `agent.rb` contract, `start_chat` extension precedence, mixed directories,
  the doc-seed behaviour, `@@agent_workflow` sharing, tooling roles on
  start_chat, nested/snake/symbol names, the PWD map and post-chdir
  behaviour, `@society` templates and cloning, `chats` keys, name
  normalization, `social_agent_options`, `Agent#import`, chat-file import
  expansion, the society save tree, the `ask` tool schema. The import/save
  probe is preserved as the Cortex probe artifact
  `probe/agent_society_import.rb`.
