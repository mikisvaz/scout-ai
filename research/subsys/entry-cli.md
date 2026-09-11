# 09 - Entry points, CLI and config surface

> Investigation, not normative documentation. Verified behavior of the
> require entry, `LLM.ask`/`LLM.chat`/`LLM.messages`/`LLM.load_agent`, the
> command surface and the config/env handling at this layer. Normative
> reference: `doc/StartHere.md`, `doc/developer/Architecture.md`,
> `doc/user/RunningInference.md`, `doc/user/GettingStarted.md`.

## Scope

`lib/scout-ai.rb`, the top-level single-inference entry points in
`lib/scout/llm/{ask,chat}.rb`, `bin/scout-ai`, `scout_commands/{llm,agent,
workflow}` and the config/env handling consumed there.

## Verified behavior

### Require entry

`lib/scout-ai.rb` (11 lines): requires `scout`, `scout/path`,
`scout/resource`; registers the `:scout_ai_lib` pathmap
(`Path.add_path :scout_ai_lib, File.join(Path.caller_lib_dir(__FILE__),
"{TOPLEVEL}/{SUBPATH}")`) **before** requiring `scout/llm/{ask,chat,embed,
image,agent}`.

After `require 'scout-ai'`:

- `LLM.constants == [:Agent, :BACKENDS]` (backends load lazily per request).
- `LLM.methods(false)` (34): `agent, ask, associations,
  call_id_name_and_arguments, call_knowledge_base, call_tools,
  call_workflow, chat, database_details_tool_definition,
  database_tool_definition, embed, get_url_config, get_url_server_tokens,
  image, knowledge_base_ask, knowledge_base_tool_definition, load_agent,
  max_content_length, max_content_length=, mcp_tools, messages,
  meta_receipt_from_messages, options, print, process_calls, purge,
  register_backend, run_tools, scout_to_tool_input_type,
  task_tool_definition, tool_response, tools, workflow_ask,
  workflow_tools`.
- `LLM::Agent.methods(false)` = `[:legacy_society_dir_for, :load_agent,
  :load_from_path, :nested_save?, :society_dir_for]`.

### `LLM.ask`

`lib/scout/llm/ask.rb:12-116`, responsibilities in order:

1. `messages = LLM.chat(question)`; `options = IndiferentHash.add_defaults
   options, LLM.options(messages)` (chat-embedded options first).
2. **Agent branch**: when `options[:agent]` is set, `agent =
   LLM::Agent.load_agent(name)`, `agent.save_file = agent_save_file if
   agent_save_file`, `agent.follow messages`, `res = agent.chat options`.
   The agent path is taken entirely inside `LLM.ask` - `agent:` is a
   legitimate `LLM.ask` option, not a separate entry point.
3. Endpoint/persist resolution: `persist` defaults to **true** (env
   `ASK_PERSIST,LLM_PERSIST,PERSIST`); endpoint falls back to config (env
   `ASK_ENDPOINT,LLM_ENDPOINT,ENDPOINT,LLM,ASK`). When
   `Scout.etc.AI[endpoint].find_with_extension(:yaml)` exists, the yaml keys
   are merged as option defaults - `provider` included; a non-empty unknown
   endpoint raises `"Endpoint not found #{endpoint}"`.
4. Provenance context: `job_paths = messages.job_paths`;
   `meta = Chat.meta(messages)`; `options[:current_meta] = meta` when
   non-empty.
5. The relay backend is handed the request early (file-based round-trip).
6. The dispatch is wrapped in `Persist.persist(endpoint, :json, prefix:
   "LLM ask", other: options.merge(messages:), persist:, dir:
   Scout.var.cache.ask)`; `SCOUT_NO_ASK_CACHE` gates the cache.
7. Backend: `Scout::Config.get :backend, :ask, :llm, env:
   'ASK_BACKEND,LLM_BACKEND', default: :responses` (ask.rb:71), then the
   `when` ladder requiring each backend lazily.
8. Knowledge-base sugar: `LLM.knowledge_base_ask(kb, question, options)`
   wraps `self.ask(question, options.merge(tools: knowledge_base_tools))`
   with a block-dispatched `children` lookup.

Return shape: the assistant **String** by default; the full messages Array
with `return_messages: true` (the agent/`chat` paths and both CLIs rely on
this).

### `LLM.chat` / `LLM.messages`

`LLM.messages(question, role = nil)` accepts an Array of Strings (-> `user`
messages) or Hashes (kept) or a String (-> `Chat.parse`).
`LLM.chat(file = [], original = nil)` is the file-aware loader: String/Path
-> `Chat.parse`; Array -> used directly; then `Chat.files(messages,
original, caller_lib_dir)` resolves `file:` roles relative to the chat file,
and `Chat.setup` annotates. The compilation pipeline itself is owned by
`research/subsys/chat.md`.

`Chat#ask` / `Chat#chat` simply re-enter `LLM.ask(LLM.chat(self), options)`.

### Agent loading

`LLM.load_agent(...)` and `LLM::Agent.load_agent(...)` are equivalent; both
`LLM.ask` and the CLIs use them. Resolution for a non-filename name (see
`research/subsys/agent-society.md` for the full algorithm):

1. `Scout.workflows[name]`
2. `Scout.Agent[name]`
3. `Scout.var.Agent[name]`
4. `Scout.chats.Agent[name]`
5. `Scout.chats[name]`

None -> `raise ScoutException, "No agent found with name #{agent_name}"`.
The **filename branch runs first**: an existing path whose directory has an
`agent.rb` loads that file (Kernel `load`; last expression must be an
Agent). This branch is documented only in `doc/developer/Architecture.md` -
`doc/user/BuildingAgents.md` never mentions `agent.rb`.

### `bin/scout-ai` and command discovery

- Repo `bin/scout-ai` (53 lines) is a thin launcher: it prepends
  `<repo>/lib` to `$LOAD_PATH`, pre-parses `--log`/`--dev` (`SCOUT_DEV` env
  also accepted; `--dev DIR` adds `DIR/scout-*/lib` and `DIR/rbbt-*/lib`),
  requires `'scout-ai'`, then `load Scout.bin.scout.find` - **the real
  dispatcher is scout-gear's `bin/scout`**, which is why `scout-ai` and
  `scout` share the generic help.
- The installed `scout-ai` wrapper is RubyGems-generated.
- Subcommands are found by globbing `Scout.scout_commands.find_all` for the
  current command path, merging and sorting. From the repo root that
  resolves to the repo's `scout_commands/` plus both gems'; from elsewhere
  (e.g. `/tmp`) the local entry disappears and the commands come from the
  gems only. This is why `scout agent` works from the repo root while
  `scout llm` from `/tmp` errors - and `scout-ai llm` works everywhere,
  because its gem ships the commands.
- `cmd_alias` (from `Scout.etc.cmd_alias.yaml`) rewrites ARGV before
  dispatch. Unknown command -> `## ERROR Command '<x>' not understood`,
  exit 255.

### Subcommand inventory

Top level (`scout-ai`, and `scout` where its command dir resolves):
`agent alias batch cat doc entity find glob kb llm log purge rbbt resource
system template update workflow`. `agent`, `llm` (+ `workflow/mcp`) come
from scout-ai; the rest from scout-gear.

`scout_commands/llm/*`:

| command | purpose | key options |
|---|---|---|
| `llm ask` | one-shot inference; STDIN as context via a `...` placeholder, template questions, chat continuation, inline rewriting | `-f/--file`, `-c/--chat`, `-i/--inline`, `-t/--template*`, `-w/--workflow*`, `-m/--model`, `-e/--endpoint`, `-b/--backend`, `-d/--dry_run` |
| `llm json` | convert a chat file to/from JSON | `--chat`, `--json`, `--output`, `-l/--last` |
| `llm md` | convert a chat file to Markdown | `--output`, `-l/--last` |
| `llm word` | convert a chat file to docx (uses the `reference.docx` option) | `--reference`, `-l/--last` |
| `llm process` | daemon: loop over `Scout.var.ask` files, run `LLM.ask(messages, options.merge(process: id))`, delete the file, `sleep 1` when idle | `-p/--process` |
| `llm process_queries` | the same pattern for query files | - |
| `llm prov` | provenance rendering (tree, flow, DOT, timeline) from `Chat.traverse_provenance` | `--evidence`, `--live`, `--flow=svg|png|pdf`, `--timeline=svg|png|pdf|dot` |
| `llm server` | sinatra server backing the offline notebook UI | - |
| `llm template` | list question templates under `Scout.questions` | - |

`llm ask` flow: `--template` loads `Scout.questions[template].read` and
appends `user: <question>`; `...` in the question is replaced by STDIN (or
`--file` contents); `--file` without `...` wraps the content in a
`<file basename=...>` block; `--chat <path>` loads/appends the conversation,
computes `agent_save_file = Agent.canonical_chat_file(chat + '.files')`,
calls `LLM.ask(..., return_messages: true, agent_save_file: ...)` and
appends the new messages back; `--inline <file>` repeatedly finds `# ask:`
comment blocks and rewrites the file with the responses; otherwise
`conversation = LLM.chat question` (+ a `tool: workflow` message when
`--workflow`) and `puts LLM.ask(conversation, options)`. `-d/--dry_run`
skips the model call and prints the prompt.

`scout_commands/agent/*`:

| command | purpose |
|---|---|
| `agent ask` | ask a named agent; same STDIN/file/chat/inline/template handling as `llm ask` but through `LLM::Agent` (load -> `current_chat.concat` -> `agent.chat`); extra `-wt/--workflow_tasks`, `-i/--imports` |
| `agent find` | load an agent by name/path and print (`LLM.load_agent`) |
| `agent kb` | run `scout kb` with `--knowledge_base <agent_dir.knowledge_base>` and `--agent` |

`agent ask` sets `agent_save_file` **before** the first chat call so the
ensure-hook and the restart snapshot see it.

`scout_commands/workflow/mcp` (43 lines) ships the MCP export for workflows
(`scout-ai workflow mcp [--tasks]`); the rest of the `workflow` namespace
comes from scout-gear. `scout_commands/llm/prov` is by far the largest
script (~1200 lines; the flow/DOT rendering lives inline).

All commands are listed in `scout-ai.gemspec` (lines 161-172) and shipped in
the gem.

### Config and environment

| what | tokens | env | default |
|---|---|---|---|
| persist (cache) | `persist` (`ask`, `llm`) | `ASK_PERSIST, LLM_PERSIST, PERSIST` | `true` |
| endpoint | `endpoint` (`ask`, `llm`) | `ASK_ENDPOINT, LLM_ENDPOINT, ENDPOINT, LLM, ASK` | none |
| backend | `backend` (`ask`, `llm`) | `ASK_BACKEND, LLM_BACKEND` | `:responses` |

- Endpoint YAML files at `~/.scout/etc/AI/<endpoint>.yaml`; keys merged as
  option defaults.
- `--log N` sets `Log.severity` in every command script.
- `-ck/--config_keys k=v,...` applies `Scout::Config.process_config` per
  comma-separated item; values may be a yaml file, a named profile
  (`Scout.etc.config_profile[<name>]`) or `key=value` pairs.
- Config files read at boot: `Path.setup("etc").config.find_all` reversed -
  `etc/config` files across path maps.
- `SCOUT_DEV` / `--dev DIR`; `SCOUT_CHAT_DIR` (consumed by the chat
  machinery); `SCOUT_NO_ASK_CACHE`.

## Sharp edges and known issues

- **`scout-ai config set ...` does not exist** (F3, open): both
  `doc/user/RunningInference.md:28` and `doc/user/GettingStarted.md:67-70`
  instruct it; it fails with `Command 'config' not understood` (exit 255),
  no `config` command exists in either command dir, and no code path writes
  endpoint YAML. Workaround: hand-write `~/.scout/etc/AI/<endpoint>.yaml`
  (what `LLM.ask` actually reads) or use `-ck key=value` per invocation.
- **The `agent.rb` convention is undocumented in user docs** (open):
  BuildingAgents.md documents only `start_chat` + optional `workflow.rb`,
  `knowledge_base/`, `python/`.
- **`scout` vs `scout-ai` prefix availability is location-dependent**
  (open): the `llm`/`agent` subcommands resolve only where the scout-ai
  `scout_commands/` is on the path maps; the docs show both forms without
  flagging the distinction.
- **Repo vs installed gem**: repo `VERSION` 2.1.0, installed gem 2.0.0 at
  study time; findings probed against the gem whenever `scout-ai` was
  invoked outside the repo. The command surface observed is the same.
- The legacy `llm info` alias mentioned in `research/commands-analysis.md`
  is background only; `llm prov` is current and consistent with
  `doc/developer/Provenance.md`.

## Open questions

- `llm server` requires sinatra; its routes/endpoints are unprobed (help
  printing fails in a sandbox on a missing dir).
- `llm prov`'s full option surface is documented in Provenance.md but owned
  by `research/subsys/provenance.md`.
- Whether any env var beyond `SCOUT_DEV`/`SCOUT_CHAT_DIR`/
  `SCOUT_NO_ASK_CACHE` is consumed in `bin/scout-ai` itself (only those
  three appear in the file).
- Python agents (`PythonWorkflow.load_directory(agent_path.python,
  'ScoutAgent')`) are reachable from `load_agent` but were not executed in
  the study environment.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch); no fix in this sweep touches this subsystem.

- Code: `lib/scout-ai.rb` (11 lines); `lib/scout/llm/ask.rb:12-116`
  (`:71` default backend), `:127-141` (knowledge_base_ask);
  `lib/scout/llm/chat.rb:13-62`; `lib/scout/llm/agent.rb:174-228`
  (load_agent); `bin/scout-ai`; `scout_commands/llm/{ask,json,md,word,
  process,process_queries,prov,server,template}`; `scout_commands/agent/
  {ask,find,kb}`; `scout_commands/workflow/mcp`; scout-gear `bin/scout`
  (command discovery, `cmd_alias`); scout-essentials config.rb:29, 166-179.
- Docs: `doc/StartHere.md`, `doc/developer/Architecture.md`,
  `doc/user/{RunningInference,GettingStarted,BuildingAgents,ManagingContext,
  CoreConcepts}.md`.
- Probes (`tmp/entry_probe/`, offline): agent discovery kinds and the exact
  exception; `LLM.chat`/`LLM.messages` shapes; command-surface capture;
  env/config token grep; `LLM.ask` offline/stubbed behaviour and return
  shapes; the `agent.rb` shortcut and `agent_save_file`; `Scout.*` map
  roots; endpoint-YAML merge (a yaml with `provider: ollama / model: qwen /
  other: 1` merges all three keys as defaults); module surface summary.
