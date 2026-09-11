# 01 - Chat data model and compilation pipeline

> Investigation, not normative documentation. Verified behavior of the chat
> data model, the `LLM.chat` compilation pipeline, prompt strategies and
> `.chat` persistence, recorded as subsystem knowledge for maintainers.
> Normative reference: `doc/developer/ChatLifecycle.md`,
> `doc/developer/PromptProcessing.md`, `doc/user/WritingChats.md`.

## Scope

`lib/scout/llm/chat.rb` and `lib/scout/llm/chat/`:
`annotation.rb`, `parse.rb`, `process.rb` + `process/{tools,files,clear,options,meta}.rb`,
`prompt.rb` + `prompt/{shorten_tools,shorten_tools_epoch,shorten_tools_epoch_increment,inbox}.rb`,
`persist.rb`. `chat/{provenance,tool_calls,agent_meta}.rb` are loaded by
`chat.rb` but owned by the provenance study (`research/subsys/provenance.md`).
The utility modules live at `lib/scout/llm/utils.rb` and `lib/scout/llm/tools.rb`
(siblings of `chat.rb`), not under `chat/`.

## Verified behavior

### Data model

`Chat` is a module that does `extend Annotation`, not a class.
`Chat.setup(array)` annotates the Array's singleton class; the object stays an
`Array` (`chat.class == Array`), `Chat === chat` holds, and
`Annotation.is_annotated?(chat)` is true.

**The annotation is not carried through Array operations.** `dup`, `+`, `-`,
`select`, `reject`, `flatten`, `concat` all return plain Arrays. Only the
`replace`-based DSL methods (`append`, `follow`, `prepend`) and `Chat.setup`
re-annotate. Every strategy or caller that rebuilds a message list must
re-`Chat.setup` (the default strategy ends with `Chat.setup(kept_messages)`;
`LLM.ask` re-annotates its result). This is documented nowhere except an inline
comment at `prompt/inbox.rb:120-121`.

DSL surface (annotation.rb, 270 lines): message constructors `user system
assistant import import_last file introduce pdf directory continue format tool
task exec_task inline_task job inline_job association tag option endpoint model
image message`; conversation ops `ask chat json json_format follow append
prepend remove_role branch`; reporting `print final purge shed answer
print_brief`; persistence `save write write_answer`; meta helpers
`role_messages last_job add_meta meta job_paths`.

### `LLM.chat` - compilation pipeline

`LLM.chat(file = [], original = nil)` (`chat.rb:30-62`), exact order:

1. `original` defaults to the chat file if it exists, else `$0`.
2. `caller_lib_dir = Path.caller_lib_dir(nil, 'chats')`; if
   `ENV['SCOUT_CHAT_DIR']` is unset and a libdir was found it is set to
   `Path.caller_lib_dir(original)` - the per-project library-store anchor.
   An explicit value is never clobbered (chat.rb:34-42).
3. `LLM.messages` -> `Chat.parse` for text, or wraps an Array.
4. `Chat.indiferent` -> `Chat.imports` (`import`/`continue`/`last`) ->
   `Chat.clear` -> `Chat.clean(messages, :skip)` -> `Chat.config` (applies
   `config:` roles through `Scout::Config.set`) -> `Chat.tasks`
   (task/inline_task/exec_task) -> `Chat.jobs` (job/inline_job) ->
   `Chat.files` (file/directory/pdf/image/step/allow_path/allow_read_path) ->
   `Chat.setup`.

`LLM.options` / `LLM.tools` / `LLM.associations` are *not* in this list: they
are extracted on the backend path (`backends/default.rb:320-341`, inside
`tools(messages, options)` and `messages()`).

### Roles

Conversational (kept): `user`, `system`, `assistant`, `function_call`,
`function_call_output`, `image`, `pdf` (resolved to a path, role unchanged),
`websearch`.

Side-channel roles consumed during compilation:

- `option`, `sticky_option`, `endpoint`, `model`, `backend`, `agent`,
  `persist`, `format`, `previous_response_id` -> `Chat.options`
  (`process/options.rb:20-71`). Sticky: `endpoint`, `model`, `backend`,
  `agent`, `previous_response_id`; ordinary options are cleared by the next
  `assistant` message; `persist` is neither sticky nor cleared. `format:` may
  load a JSON schema file.
- `config: <key> <value> <tokens...>` -> `Scout::Config.set` with the trailing
  tokens as scopes.
- `tool`, `introduce`, `mcp`, `kb`, `association`, `clear_tools`,
  `clear_associations` -> `Chat.tools` / `Chat.associations`
  (`process/tools.rb:136-255`). See the tools study.
- `import`, `continue`, `last` -> `Chat.imports` (`process/files.rb:38-60`):
  inline the whole chat, only its last non-empty message, or its last purged
  message. File resolution: relative to the chat dir, caller libdir, literal
  path, remote URL, then `Scout.chats`.
- `file`, `directory` -> `<file name="...">`-tagged user messages / recursive
  per-file expansion. `step` -> loads the job named in chat meta and substitutes
  the step's answer as an assistant message.
- `allow_path`, `allow_read_path` -> thread-local path whitelists; the message
  is dropped.
- `clear`, `clear_tools`, `clear_role`/`clean_role` -> `Chat.clear`
  (`process/clear.rb:2-31`): reverse scan stops at the last `clear:`;
  `clear_tools:` drops `function_call*` pairs from that point back;
  `clear_role`/`clean_role` name roles to drop. Ephemeral with respect to the
  saved file.
- `meta` -> provenance bookkeeping, stripped by `Chat.meta` before inference.
- `job`, `inline_job`, `task`, `inline_task`, `exec_task` -> `Chat.jobs` /
  `Chat.tasks` (`process/tools.rb:43-135`): produce function_call/output pairs
  (job/task) or inline file content (inline_*); `exec_task` runs synchronously.
  `Chat.jobs` error handling honours `ENV['SCOUT_CHAT_JOB_EXCEPTION']`
  (tools.rb:113-119).
- `cmd` (`llm/tools.rb:58-71`) converts to a `tool` message with command
  output.

`Chat.clean` default dropped roles are `['skip','previous_response_id']`, plus
empty-content messages. `Chat.purge(chat, role = :previous_response_id)`
strips only that role; the backend's non-`return_messages` path produces the
final string as `Chat.clean` + `Chat.purge(...).last['content']`
(default.rb:610-617).

### Parse / print round-trip

`Chat.parse` (parse.rb:10-141):

- Header regex `^([a-z0-9_]+):(.*)$` (parse.rb:99). An inline header
  (`user: hello`) makes the message inline and resets the *next* block's role
  to `user` (also for `previous_response_id` and `agent`).
- **No blank line is required** between header and content. The blank line in
  `doc/user/WritingChats.md` is a convention, not a parser requirement.
- Escaping: a line matching `^\\([a-z0-9_]+):` is taken literally minus the
  leading backslash; `Chat.print` escapes `^([a-z]+:)(\s)` in content.
- Protected blocks (headers inside them are not recognized): fenced ` ``` `
  blocks, `[[ ... ]]`, `<tag>...</tag>` XML blocks whose closing tag appears
  somewhere in the text, and the scout `name :-- cmd {{{` / `... }}}`
  command-output markers, rewritten to `<cmd_output cmd="...">`.
- `option/previous_response_id/function_call/function_call_output/meta` print
  inline (`role: content`); Hash/Array content prints as JSON; empty content
  prints a bare `role:`.
- `Chat.parse_json` unwraps a ` ```json ` fence then `JSON.parse`.
- Round-trip invariant `Chat.parse(Chat.print(m))` is covered by
  `test/scout/llm/chat/test_parse.rb` and holds for the conversational and
  control roles.

### Meta messages and token accounting

- Canonical short keys `pt ct tt cct cwt rt` with `_s` (session) and `_c`
  (chat-cumulative) variants (meta.rb:14-18). `USAGE_FIELD_MAP` normalizes
  OpenAI Chat/Responses, GLM and Anthropic usage spellings; `normalize_usage`
  recomputes `tt` as `pt+ct` when both are present but `tt` is missing. The
  map is the inclusivity boundary: unknown spellings leave `cct/cwt/rt` nil
  while `pt/ct/tt` still count.
- `serialize_meta` sorts keys by value length and quotes values containing
  `=`; `parse_meta` reverses it exactly.
- `update_meta` (default.rb:415-448) stamps `inference_id` (UUID per request),
  `provider_response_id`, per-request token fields, `_s` session cumulatives
  and `_c` chat cumulatives computed as `current_meta[k_c] + tokens[k]` -
  deliberately not the session total.
- The backend appends a `{role: :meta, ...}` message after each logged
  response, marks `orphan=true` on reasoning-only rounds, and `Chat.project`
  prepends exactly one `meta: job=<short path>` producer marker.
- `Chat.meta(messages)` strips meta messages (mutating) and returns the last
  meta with the last `_c` checkpoint restored. Lineage/tracing helpers skip
  metas carrying `job`.

### Prompt strategies

`Chat.prepare_prompt(prompt, strategies = nil, save_file: nil)`
(prompt.rb:37-63):

- `Proc` strategies short-circuit everything.
- Default `DEFAULT_CONTEXT_STRATEGY = %w(shorten_tools_epoch_increment inbox)`
  (prompt.rb:9); resolved from `Scout::Config.get(:prompt_strategies, :chat,
  :scout_ai, env: 'PROMPT_STRATEGY', default: ...)` when nil; comma-split
  strings supported. A user-supplied list replaces the default; strategies
  apply in list order.
- Dispatch: hard-coded `case` for `shorten_tools`, `shorten_tools_epoch`,
  `shorten_tools_epoch_increment`, `inbox` (with `save_file:`), `none`; then
  `REGISTERED_STRATEGIES[strategy]`; then `Chat.send(strategy, prompt)` as
  fallback. `REGISTERED_STRATEGIES = {}` starts empty and nothing in-repo
  populates it.
- Called inside `Backend::ClassMethods#ask` in the non-relay path, i.e.
  **after** `LLM.ask`'s `Persist` cache, so a cache hit never runs strategies.
  The list is re-threaded through `chain_tools` (default.rb:584-588) so it
  applies on every tool-call round.
- Thresholds are `Scout::Config.get`-backed and **memoized in class
  variables** - setting the env var after the first read does not change the
  value. Defaults in this checkout:

| strategy | constants (shorten_tools_*.rb) |
|---|---|
| `shorten_tools` | full_tool_calls 0, full_tool_outputs 10, max_tool_calls 40, max_tool_outputs 40, max_tool_chars 100000 |
| `shorten_tools_epoch` | epoch_tool_call_threshold 50, epoch_full_tool_calls 20, epoch_compacted_tool_calls 80, epoch_size 20 |
| `shorten_tools_epoch_increment` | threshold 50, full 20, compacted 80, initial size 20, epochs_per_increase 3, size_increase 10, repeat_increase 10, max_size 60, growth ratio 2.0, max compacted 160 |

`shorten_string` builds the `[CONTEXT-COMPACTED ...]` envelope with a preview
and an optional job pointer; `Log.truncate_string` adds an MD5 fingerprint.
When compaction actually drops something, `shorten_tools_epoch_increment`
inserts a `=== Context Management ===` user message after the first kept
message ("Compacted tool messages: N / Removed tool messages: M").

### `inbox` strategy

- Paths derived from `save_file` (`inbox.rb:133-185`): inbox dir, `.inbox_removed`
  dir, and a `.jobs` sibling file for live workload tracking. The stem strips
  only the last extension (`agent.chat` -> `agent`, `a.b.chat` -> `a.b`).
- Pickup (inbox.rb:64-131): no `save_file` or missing dir is a silent no-op;
  otherwise top-level regular files are listed sorted by name and **moved into
  `.inbox_removed` (created lazily, mtime preserved, numeric suffix on
  collision) before being read**, then appended as `{role:'user', content:}` -
  at-most-once delivery.
- Reserved `abort` file: consumed once, its content never reaches the model,
  raises the framework-native `Aborted` (StandardError subclass) with the
  stripped content as reason. Files sorted before it were already consumed;
  files sorted after remain.
- Per-file failures are logged at low severity and skipped; they never break
  the ask path.
- Provenance globs (`DIRECT_LOG_CHAT_GLOBS` = `['*.chat', '*.society/**/*.chat']`)
  do not match inbox siblings.

### Persistence

`chat/persist.rb` (25 lines):

- `Persist.save_drivers[:chat]`: an `LLM::Agent` saves the `current_chat -
  start_chat` diff; a `Chat`-annotated array saves `Chat.print`; anything else
  saves `content.to_s`. Writes go through `Open.sensible_write`.
- `Persist.load_drivers[:chat]` is `LLM.chat(file)` - loading **recompiles**
  (imports/tasks/jobs/files re-run). `Chat.load(file)` (meta.rb:185-189) is
  the parse-only, non-compiling loader used by provenance inspection.
- `Workflow::TYPE_EXTENSIONS[:chat] = :chat` registers the type extension, so
  a job of type `:chat` produces `.chat` files driven by these procs.
- Instance `save/write/write_answer` (annotation.rb:222-247) resolve
  non-existent relative paths through `Scout.chats.find` and write
  `LLM.print(self)`.

### LLM facade

`LLM.messages/chat/options/print/tools/associations/purge` delegate to the
`Chat` module functions (chat.rb:64-82); `LLM.ask` wraps chat construction +
the `Persist` cache + backend dispatch and re-annotates Array results with
`Chat.setup`.

On a query failure the backend writes `<save_file>.error` plus a tmpdir trio
(`.chat`, `.options`, `.meta`) and attaches it to the exception via
`e.extend LLM::Backend::BackendException; e.chat tmpfile` (default.rb:506-517,
566-579).

## Sharp edges and known issues

No code-side bugs were found in this subsystem; all mismatches below are
documentation staleness.

- **Comments do not exist in the chat format** (F12). `doc/user/WritingChats.md`
  documents `#` comment lines; the parser has no comment branch - a `#` line
  becomes a user message, and a `#` line after `user:` merely joins the
  content.
- **Stale default-strategy snippet** in `doc/developer/PromptProcessing.md`
  (`%w(shorten_tools_epoch_increment)`); the code default includes `inbox`.
- **Stale `shorten_tools_epoch` config table** in PromptProcessing.md
  (10/40/10); the constants are 20/80/20. Related: Backends.md still cites the
  `shorten_tools` MAX_TOOL_CALLS 40 bound, which is not the default strategy
  (see the backends study, F14).
- **Compilation pipeline listing incomplete** in ChatLifecycle.md: it omits
  `indiferent`, `imports`, `config`, `tasks`, `jobs`, `files` and places
  options/tools extraction inside `LLM.chat`.
- **Annotation fragility** (code behavior, undocumented): any Array-derived
  copy of a Chat is a plain Array; only `replace`-based DSL methods preserve
  the annotation. A silent class of bugs for code that does
  `chat.select {...}`.
- **Protected-block inventory** (fences, `[[ ]]`, XML tags with a closing tag
  present, `{{{ }}}` command markers) is not enumerated in any doc; a
  `<tag>`-looking line without a matching closer is parsed as content with a
  recognized header.
- `Chat.jobs` honours `ENV['SCOUT_CHAT_JOB_EXCEPTION']`; not mentioned in any
  maintained doc.
- `Chat.associations` hard-codes the inline KB to
  `Scout.var.Agent.Chat.knowledge_base` (process/tools.rb:237).

## Open questions

- Whether `epoch_increment`'s repeat protection ("the most recent instance of
  each repeated (name,arguments) pair is protected from dropping") interacts
  with the epoch-growth accounting exactly as read; only sanity-checked with a
  120-pair probe, not with repeated identical calls.
- The interleaving of `shorten_tools`'s character budget with its call budget
  was read but not exercised end-to-end with a real backend. Low risk.
- The `agent:` role is sticky in `Chat.options` and recognized by the parser;
  its consumer (`LLM.load_agent`) is covered by the agent studies.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep (attach/MCP/embed/torch); no fix in this sweep touches this subsystem.

Code anchors (line numbers as of that tree):

- `lib/scout/llm/chat.rb:14-28` (messages), `:30-62` (pipeline),
  `:64-82` (facade)
- `lib/scout/llm/chat/annotation.rb:1-270`
- `lib/scout/llm/chat/parse.rb:2-8,10-141,143-163,165-189`
- `lib/scout/llm/chat/process.rb:1-21`; `process/clear.rb:2-31,32-42,44-64`;
  `process/options.rb:2-18,20-71`; `process/tools.rb:3-41,43-135,136-229,231-255`;
  `process/files.rb:2-36,38-60,62-109`;
  `process/meta.rb:14-71,73-134,135-175,177-241,243-340,342-379,381-434`
- `lib/scout/llm/chat/prompt.rb:8-11,15-27,37-63`;
  `prompt/shorten_tools.rb:5-110`; `prompt/shorten_tools_epoch.rb:8-40`;
  `prompt/shorten_tools_epoch_increment.rb:13-132,135-749`;
  `prompt/inbox.rb:18-52,64-131,133-185`
- `lib/scout/llm/chat/persist.rb:4-25`
- `lib/scout/llm/backends/default.rb:273-289,300-341,415-448,481-528,540-617`
- `lib/scout/llm/ask.rb:5-11,12+`; `lib/scout/llm/tools.rb:8-71`
- Tests: `test/scout/llm/test_chat.rb`,
  `test/scout/llm/chat/{test_parse,test_process,test_prompt,test_tool_calls}.rb`

Probe receipts (offline, no repository modifications): annotation
identity/dup/select behaviour; parse round-trips (comments, blank-line,
inline headers, protected blocks, escaping); options stickiness;
clear/clean/purge; meta serialize/parse round-trip and `_c` checkpoint;
live strategy-config default reads; a 120-pair
`shorten_tools_epoch_increment` compaction probe; inbox delivery, ordering,
consume-once, abort-file and removed-dir naming (inside `Dir.mktmpdir`).
