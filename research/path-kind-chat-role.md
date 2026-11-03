# `path_kind:` chat role — decision record

Feature: per-agent control over which Path-engine kinds are configured,
replacing the wholesale behavior where incorporating a workflow whole
(`tool: W`) auto-configured every kind it declared. Four steps landed in
/bulk/mvazque2/git/scout-ai (engine) and /home/mvazque2/git/AgentSuite
(suite wiring + docs). This note records the adopted semantics and the
interpretation decisions, not a behavior description — behavior is
documented in `doc/developer/PathEngine.md` §4/§4.1 and
`doc/user/WritingChats.md` ("Declaring tools").

## Adopted semantics (rules 1-6)

1. **Line syntax** `path_kind: <Workflow> [<kind>...]`: first token the
   workflow (resolved via `Chat.load_workflow`), rest kind names.
   Multiple kinds per line and multiple lines accumulate. An **empty**
   kind list means *every* kind of that workflow.
2. **Explicit lines honored anywhere** — start_chat file or live chat.
3. **Agent with a start_chat file ⇒ strict-explicit**: no implicit kind
   loading at all. A start_chat with no `path_kind:` lines loads zero
   kinds; whole-workflow `tool: W` lines configure tools only, never
   kinds, for such agents.
4. **Agent without a start_chat file ⇒ load-all default**: all kinds of
   the agent's own workflow (when it declares `PATH_KINDS` — the old
   synthetic-`introduce` fallback loaded none) plus the whole-workflow
   `tool:` incorporation retained as back-compat.
5. **Loud failures**: unknown kind or unloadable workflow raises
   `ParameterException` naming the workflow, the offending kind(s) and
   the valid kind names; a failed selection registers nothing.
6. **Never model-visible**: `path_kind:` lines are stripped from the
   model view; registration happens from the full message list *before*
   stripping, so `clear_tools` cannot bypass it.

## Why these choices (resolved ambiguities)

- **Subset vs replacement semantics** — a selection *replaces* the
  all-kinds default for that line; it does not intersect with other
  lines. Accumulation is per workflow-kind registration.
- **Selection after normalization** — kind names are matched against the
  workflow's own normalized kind names (so Array-form `PATH_KINDS`
  names work), and the unknown-kind error lists the valid names, so a
  typo cannot silently degrade into a no-op.
- **`start_chat_file?` signal** — `LLM::Agent.load_agent` explicitly
  records whether a real start_chat *file* was found versus the
  synthetic `{introduce: workflow.name}` fallback, and rule 4 gates on
  that signal. The synthetic fallback is NOT deliberate preparation, so
  it keeps the load-all default. Direct-construction agents (tests,
  `LLM::Agent.new(start_chat: ...)`) treat any non-empty start_chat as
  prepared unless the flag is set explicitly; `clone_agent` carries the
  flag so delegation cannot flip a synthetic-fallback agent into
  implicit loading.
- **Deliberate re-scope** of the pinned test
  `test_whole_workflow_tool_line_registers_kinds_and_installs_tools`
  (step 2): the old test used a bare `fresh_agent`, which under the new
  rules is a *prepared* agent only by the start_chat-less default; it
  now builds the agent with `workflow: TestPathKindWorkflowB` so
  `start_chat_file?` is false — the rule-4 precondition the old test
  implicitly relied on. The prepared-agent counterpart (tool line ⇒
  zero kinds) is `test_start_chat_present_zero_kinds_from_tool_lines`.
- **Suite impact audit** (step 3): in AgentSuite only ScoutCoder and
  Research declare `PATH_KINDS`. No start_chat carries `tool: Research`
  (only task-level `tool: Research searxng/html2md`, which register
  nothing), so only ScoutCoder's own start_chat needed the explicit
  `path_kind: ScoutCoder` line. Research/README.md line 14 documented
  the old whole-workflow rule; corrected to the explicit rule with the
  start_chat-less default noted.

## Verification evidence

- Engine tests: `test/scout/llm/agent/test_path_workflow_integration.rb`
  (39 tests / 136 assertions, includes the path_kind subset,
  accumulation, unknown-kind, start_chat gating, and model-visibility
  tests), `test/scout/llm/agent/test_path.rb` (83/634),
  `test/scout/llm/chat/test_parse.rb` (round-trip pin). Whole
  `test/scout/llm/{agent,chat}` subtree green, 38 files, fresh
  processes.
- Live checks (step 3, fresh probe children): (a) suite ScoutCoder
  agent, one mock-backend ask ⇒ all six kinds, 13 path tools, no
  `path_kind` content model-visible; (b) `path_kind: ScoutCoder probe`
  ⇒ exactly `["probe"]` (both the literal start_chat-less variant and
  the prepared-agent variant); (c) start_chat-less agent + whole-workflow
  `tool: ScoutCoder` ⇒ all six (back-compat confirmed).

## Changed files

- Engine (scout-ai): `lib/scout/llm/agent/path/workflow_kinds.rb`
  (`only:` subset selection), `lib/scout/llm/agent.rb` (role
  consumption, `start_chat_file` accessor, gating),
  `lib/scout/llm/agent/construction.rb` (clone carries the signal),
  `lib/scout/llm/chat/process/tools.rb` (strip from model view; role in
  `tooling`), `doc/developer/PathEngine.md` (§4 rewrite, new §4.1),
  `doc/user/WritingChats.md` (role in "Declaring tools"), plus the two
  test files above.
- Suite (AgentSuite): `ScoutCoder/start_chat` (+`path_kind: ScoutCoder`),
  `ScoutCoder/README.md` ("Agent path kinds" loading-rule rewrite),
  `Research/README.md` (line-14 correction).
