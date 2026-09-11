# 03 - Agent class and delegation semantics

> Investigation, not normative documentation. Verified behavior of the
> `LLM::Agent` class, its lifecycle, structured output, socialization and
> delegation. Normative reference: `doc/user/BuildingAgents.md`,
> `doc/developer/DelegationInternals.md`, `doc/user/Delegation.md`.

## Scope

`lib/scout/llm/agent.rb` plus `agent/{chat,iterate,delegate,conversation,attach,save}.rb`.
Job binding (`AgentWorkflow`) is covered by
`research/subsys/agentworkflow.md`; agent directory resolution and the society
save tree by `research/subsys/agent-society.md`.

## Verified behavior

### Class surface

`Agent` is a stateful wrapper over a Chat:

- Construction: `Agent.new(workflow:, knowledge_base:, start_chat:, **kwargs)` -
  extra kwargs land in `other_options`.
- Conversation state: `start_chat` (lazily `Chat.setup([])`), `current_chat`
  (lazily `= start_chat`), `chats`, `society`; unknown message-like methods
  are forwarded to `current_chat` through `method_missing`.
- Rounds: `chat(options = {})` appends the assistant message(s) and
  auto-saves; bare `ask(messages = nil, options = {})` performs a round via
  `LLM.ask` with **no** auto-save.
- `start(chat = nil)` re-branches: `current_chat = start_chat.follow(chat)` -
  a fresh branch object seeded by `start_chat` plus the optional chat.
- `prompt` parses its String argument as Scout chat-file syntax (role-looking
  lines become real roles); `user` appends one literal user message. This is
  precisely why delegated prompts must be built with `user`.
- Structured output: `json` (retries once with a system message asking for
  bare JSON on parse failure), `json_format(format, options)` (appends the
  `option format <json-schema>` message and sets the chat option),
  `iterate(prompt, &block)`.
- Persistence: `save_file`, `save(path = nil)`, per-round auto-save in `chat`,
  restart snapshots in `start`.

### `iterate`

Forces `endpoint :responses`, appends the prompt, sets a
dictionary-of-strings JSON schema via `json_format`, sets
`option :format, :text`, then `TSV.traverse dict, **kwargs, &block` - the
dictionary entries are streamed to the block as items.

### Delegation mechanics

`socialize(options = {})` installs a narrow `ask` tool. Parameters (all
required only `agent` and `prompt`): `agent`, `prompt`, `conversation`
(pattern `^[A-Za-z0-9][A-Za-z0-9_.-]*$`), `inherit` (enum
`SOCIAL_INHERIT_MODES` = `none/tools/conversation`, default `tools`). The tool
block never receives the specialist Chat object; it calls `ask_agent` ->
`ask_conversation` -> `open_conversation` + `agent.user(prompt)`.

`delegate(agent, name, description, task_name = nil, &block)` registers the
`hand_off_to_<name>` tool (or `task_name`). For an `LLM::Agent` target it
pre-registers `@society[name] ||= agent` (the template cache) and the default
block calls

```
ask_conversation(name, message,
  conversation: sanitized_slot(name), inherit: 'none',
  template: agent, adopt: :current, restart: new_conversation)
```

Duck-typed targets keep the legacy direct mutation (`agent.start if
new_conversation; agent.user message; agent`).

`open_conversation(name, conversation: 'default', inherit: 'tools',
options: {}, preamble:, anchor:, restart:, template:, adopt:, job:)`:

1. Normalize name/conversation/inherit/adopt. Name pattern
   `SOCIAL_AGENT_NAME = /\A[a-z_.-]+\z/i`, conversation pattern
   `SOCIAL_CONVERSATION_NAME = /\A[a-z0-9][a-z0-9_.-]*\z/i`; invalid values
   raise `ParameterException`.
2. `key = social_chat_key(name, conversation)` = `"Name/conversation"`. An
   existing key returns the **same** agent object (identity per key; the
   `inherit` argument is ignored). `restart: true` re-branches in place -
   the same object, the chat reset to the seeded prefix.
3. A new conversation: `start_social_chat` clones the template
   (`clone_social_agent`: fresh `start_chat`/`other_options` copies,
   `society = nil`, `chats = nil`, `current_chat = nil`); the initial chat is
   `copy(template.start_chat)` + (`adopt: :current` -> the template's progress
   delta) + the inherited context + the preamble; then `agent.start(initial_chat)`;
   `save_file = anchor || society_save_file(name, conversation)`; and
   `@chats[key] ||= agent`.
4. `job:` is accepted and ignored (reserved).

Inherit semantics:

- `none` -> empty Chat.
- `tools` -> `self.current_chat.tooling` (the `introduce`/`tool`/`mcp`/`kb`
  roles). Note the code uses the *whole current chat's* tooling, not the
  caller task's - see the mismatch below.
- `conversation` -> `social_caller_context` = `social_context_delta(self)` =
  `current_chat` minus `start_chat` (by object identity when the start-chat
  messages are shared Hash objects, else longest-common-prefix drop).

`social_context_delta` implements one rule for both directions (caller
context and `adopt: :current` template progress): identity-set match against
`start_chat`, with common-prefix fallback.

Option propagation: `social_agent_options(options)` = deep-dup of
`other_options` merged with the supplied options, minus
`SOCIAL_PRIVATE_OPTIONS` (`agent, client, current_meta, format, messages,
no_ask_override, previous_response_id, process, return_messages, tool_choice,
tools`). Specialists therefore never inherit the caller's tools or format by
accident; `endpoint`/`model` style options do flow.

### Agent-round fan-out

`LLM.process_calls` (tools/call.rb:140-193) collects tool results that are
`LLM::Agent` and fans them out with `Open.traverse cpus:` (config
`:cpus,:agent_ask,:agents`, env `ASK_AGENTS`, default 3), calling
`agent.chat(return_messages: true)`. Each answer is paired with its own call
**by tool-call position** (the n-th agent-returning call consumes the n-th
answer) - this avoids the first-occurrence bug with duplicate agents. A
`.jobs` sidecar of in-flight workflow job short paths is written per round
and removed in `ensure`.

### Attachments

`Agent#attachments` registers a single `attach` Proc tool with properties
`file` (string, required) and `file_type` (enum `ATACH_TYPES` =
`auto image pdf png jpeg`, default `auto`). Current behavior (fixed
2026-09-11, uncommitted): `file_type` defaults to `auto`; only `auto` is
normalized (pdf by lowercase `.pdf` extension, else `image`); the dispatcher
is `case file_type` with a subject, so `image`/`png`/`jpeg` route to
`self.image(path)`, `pdf` routes to `self.pdf(path)`, and an unknown type
raises `ScoutException` (returned as the tool error). Before the fix the
normalization overwrote every explicit type to `image` and the dispatcher was
a bare `case`, so the pdf branch was unreachable (finding F1, fixed with
`test/scout/llm/agent/test_attach.rb`, 8/0). Only `.pdf` is sniffed under
`auto`: a PDF with another extension still needs an explicit
`file_type: 'pdf'`.

## Sharp edges and known issues

- **`inherit: 'tools'` scope drift** (F17, open). `doc/developer/DelegationInternals.md`
  says it copies "caller's task chat tooling"; the code copies
  `self.current_chat.tooling` (the whole current chat, which for a
  mid-conversation agent may include tooling added after start). The
  commented-out `social_caller_context.tooling` line in conversation.rb:256-266
  shows the intent drifted. Contained by `SOCIAL_PRIVATE_OPTIONS`, but real.
- **Fixed 2026-09-11, uncommitted:** F1 `attach` never attached PDFs
  (normalization overwrite + bare-`case` always matching the image branch);
  now normalized to `auto`-only with a subject-form dispatcher.
- `ATACH_TYPES` typo (should be `ATTACH_TYPES`) and the
  `ScoutException "Unkown file type"` message typo remain, deliberately -
  renaming a constant is API-visible.
- `open_conversation(job:)` is accepted and ignored.
- The `LLM.process_calls` cpus knobs (`:agent_ask`, `:agents`, env
  `ASK_AGENTS`) and the `.jobs` sidecar lifecycle are documented only in code
  comments; `doc/user/MultiAgentWorkflows.md` does not mention them.
- Restart snapshots (`.files/resets/<timestamp>.chat`) are written lazily -
  nothing to snapshot means no `resets` directory. The collision-suffix rule
  was read but not probed.

## Open questions

- Whether `inherit: 'tools'` should be caller-task-scoped (docs) or
  whole-current-chat-scoped (code); a regression test pinning the intended
  semantics would help. See `research/subsys/agentworkflow.md` for the
  `tooling` helper's role.
- Probing constraint worth knowing when reproducing: a probe that requires
  scout-ai inside a forked worker must pin the checkout lib via
  `RUBYLIB`/`-I` **and** pass explicit `backend:`/`endpoint:` in each Agent's
  own options - `Scout::Config` pinning does not survive the forked
  `Open.traverse` workers, and host `Scout.etc` endpoint files otherwise leak
  in. Recorded as the Cortex probe artifact `probe/subprocess_exec_in_property.rb`.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep. The attach fix (F1) in that sweep is the only change in scope here;
described above as current behavior.

- Code: `lib/scout/llm/agent.rb:15-21` (construction), `:85-88` (`job=` meta
  at dispatch), `:100-140` (ask/tool assembly, `process_exception`),
  `:159-163` (`prompt` vs `user`), `:174-228` (`load_agent`);
  `agent/chat.rb:1-6,33-61,62-90`; `agent/iterate.rb:7-42`;
  `agent/delegate.rb`; `agent/conversation.rb:4-12` (constants), `:44-62`
  (`open_conversation`), `:107` (name validation), `:174-195`
  (`social_agent_options`), `:235-266` (`social_context_delta`, inherit);
  `agent/attach.rb:4,14-35,44-52`; `agent/save.rb`;
  `lib/scout/llm/tools/call.rb:140-193`.
- Tests: `test/scout/llm/agent/{test_attach,test_chat,test_conversation,
  test_delegate,test_save,test_workflow}.rb`; `test/scout/llm/test_agent.rb`.
- Probe receipts: Cortex probe artifact `probe/scout_agent_delegation_api.rb`
  (Observation `scout_agent_delegation_api`), run through the
  `Observation/probe` property; its JSON output covers ask/chat auto-save,
  json/iterate, the inherit-mode role sets, `open_conversation` identity and
  restart, delegate clone/template semantics, the `ask` tool schema
  (parameters `[agent, conversation, inherit, prompt]`, inherit enum with
  default `tools`, conversation pattern), `process_calls` answer pairing and
  the society save layout.
