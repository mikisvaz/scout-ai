# ChatAnalyst — required changes for the new scout-ai save layout

Commentary only (NOT an implementation plan executed here). Grounded in the
actual files of `/home/mvazque2/git/workflows/ChatAnalyst` (workflow.rb,
README.md, test/, tmp/ verify scripts) and in the scout-ai changes of steps
1-3b (artifacts `var/cortex/artifacts/society-save/*.md`).

New layout recap: `<chat>.files/<name>.chat` (`agent.chat` default,
`worker.chat` for named), society tree `<name>.society/<Agent>/<conv>/agent.chat`
(plain `society` sibling at depth >= 1). Legacy `.files/log/**` stays readable,
never written, never migrated.

## 1. What already works for free (no change needed)

`workflow.rb` contains **no layout hardcoding at all**. Its only `.files`
mention is a comment in `helper :resolve_root` ("a `.files` directory alone is
not evidence: saved agent chats carry one too. Only the `.info` test decides,
and the chat branch then relies on scout-ai provenance to scan the sidecar"),
and that reasoning is layout-independent and still correct: the new layout
also gives saved chats a `.files` dir without `.info`, while jobs keep `.info`.

All discovery goes through the shared scout-ai APIs, which are now
dual-layout:

- `Chat.provenance_token_events` / `Chat.provenance_edges` /
  `Chat.provenance_chat_files` / `Chat.provenance_jobs` (called in
  `helper :provenance_data`, lines ~194-228) all wrap
  `Chat.traverse_provenance`, which now globs `*.files/*.chat`,
  `*.files/*.society/**/*.chat` and the legacy `*.files/log/**/*.chat`,
  de-duplicated and sorted;
- job-vs-chat classification, the root-copy exclusion
  (`Chat.direct_chat_sidecar_files`) and the `:log` relation semantics live in
  scout-ai (`lib/scout/llm/chat/provenance.rb`), not here;
- no task input consumes a log path, no task globs `.files` itself
  (`grep -n "task :"` shows only `file/ids/role/…` inputs; the only path
  computation is `resolve_root`, which resolves a *chat or job path*, never a
  log path);
- `short_path` only collapses `$HOME`, so the longer
  `<name>.society/<Agent>/<conv>/agent.chat` paths just render fully — no
  truncation or matching by suffix anywhere.

Consequence: every task that takes a chat or job root (message_index,
message_content, chat_overview, chat_tool_calls, chat_tokens, chat_agents,
meta_evidence, chat_reasoning, chat_report, provenance_relationships,
chat_accounting) keeps working on chats produced by the new layout, and on
mixed old+new trees, with zero code change.

## 2. What WOULD break (if scout-ai had not been dual-layout)

Nothing in ChatAnalyst hardcodes `log/`, so nothing breaks outright. The
failure mode the scout-ai change guards against — and which ChatAnalyst would
have inherited if it had hardcoded anything — is:

- assuming society chats live under `.files/log/society/...`: a glob or
  regex pinned to that prefix would silently find nothing in new trees;
- assuming a chat's own copy is exactly `<chat>.files/log/agent.chat`: the
  new equivalent is any top-level `<chat>.files/<name>.chat` (and named agents
  write `<name>.chat`);
- assuming `resets/` is the only sibling of `log/`: in the new layout the
  society dir is `<name>.society`, so any "everything under `.files` except
  `resets`" sweep would now also pick up society trees twice.

## 3. README is outdated (real gap)

`README.md` states the OLD layout as current:

- line 5: "all `.files/log/**/*.chat` files — including the regular
  `log/agent.chat` logs";
- lines 9-11: "`<chat>.files/log/society/<agent>/<conversation>/agent.chat`
  appear as chats (the chat's own root copy at `log/agent.chat` is skipped)";
- line 70: `<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat`
  for socialized chat *projections* (this is a different, older projection
  mechanism that predates the society tree; it should be described as
  historical/legacy).

Needed: describe the three glob families (`*.files/*.chat`,
`*.files/*.society/**/*.chat`, legacy `*.files/log/**/*.chat` read-only), the
named-file rule (`agent.chat` default, `worker.chat` for named agents), the
nested plain-`society` sibling rule, and label `log/chats/…` projections and
the whole `log/` layout as legacy. Recommended wording for the projection
path: keep the `<caller_job>.files/log/chats/...` line but prefix it with
"(legacy mechanism)" and add the current society path
`<caller_job>.files/<name>.society/<AgentName>/<conversation>/agent.chat`.

## 4. Tests: keep the legacy fixtures, they are on purpose

`test/scout/agent_meta_fixtures.rb` builds the OLD layout deliberately:

- `make_job(..., logs: {...})` writes `<job>.files/log/<name>` — this is the
  **legacy job-log emulation** and must keep working: traversal stays
  dual-layout, so these fixtures keep passing unchanged. This is exactly the
  read-only compatibility guarantee step 3 added tests for
  (`test/scout/llm/chat/test_new_layout_provenance.rb` in scout-ai).
- `make_saved_chat(...)` writes the root copy at `log/agent.chat` plus society
  under `log/society/<agent>/<conv>/agent.chat` — again the legacy chat
  sidecar shape.
- `test/test_agent_meta_tasks.rb` line ~193 asserts
  `%r{files/log/society/Worker/default/agent\.chat}` and line ~199 counts
  copies matching `%r{\.files/log/agent\.chat\z}`; both still pass because
  the fixtures are legacy and the traversal reads legacy.

What to do if new-layout coverage is ever wanted (commentary, not done here):

- add `make_job`/`make_saved_chat` keyword variants (e.g. `layout: :new`) or
  two new builders writing `<job>.files/agent.chat` +
  `<job>.files/agent.society/...`, rather than changing the existing ones —
  the existing ones ARE the legacy coverage;
- keep the regexes layout-agnostic where the intent is layout-independent,
  e.g. `%r{\.files/(?:agent\.society|log/society)/Worker/default/agent\.chat}`
  and `%r{\.files/(?:agent|log/agent)\.chat\z}`;
- add one fixture where both layouts coexist in one `.files` dir to cover the
  de-duplication guarantee (a chat must be counted once).

## 5. tmp/ verify scripts use old-layout fixtures (scratch only)

All five are one-off scratch scripts, not part of any suite:

- `tmp/verify_society_dedupe.rb` — builds `base + '.files/log/society/Worker/default/agent.chat'`;
- `tmp/verify_root_sidecar.rb` — root chat + `log/agent.chat` + legacy society;
- `tmp/check_current_format.rb` — `job + '.files/log/agent.chat'`;
- `tmp/check_resets_visibility.rb` — `root_save = job + '.files/log/agent.chat'`;
- `tmp/verify_resets2.rb` — `base + '.files/log/agent.chat'` and a deliberately
  mis-placed `log/resets/…` snapshot to prove `resets/` under `log/` IS swept.

None of them needs a fix to keep running (they still exercise the legacy
read path), but note for `verify_resets2.rb`: the "hypothetical wrong
placement" it tests is now doubly legacy — in the new layout a wrongly placed
reset would be `<name>.society/resets/…` or a top-level `<name>.chat`-adjacent
path, so if the script is ever refreshed, add the new-layout equivalents
(resets next to `agent.society/`, resets next to top-level `agent.chat`) to
keep the "resets are invisible" guarantee meaningful.

## 6. Task-input / tooling implications

- **Inputs are unaffected.** Every task takes a chat file or job path as
  `file`; the new layout only changes what is *inside* `<that path>.files`.
- **Consuming new-layout chats is automatic.** A chat saved by the new
  `scout-ai llm ask -c` / `agent ask -c` (root copy at
  `<chat>.files/agent.chat`, society under `<chat>.files/agent.society/…`) is
  resolved by `resolve_root` exactly like before, and its society
  conversations appear in `:chats` via the shared traversal.
- **The hidden top-level `agent.chat` rule affects tooling that assumes job
  log visibility.** `scout-ai llm prov` hides a basename `agent.chat` whose
  parent is `<something>.files` or a legacy `.../log` dir, because it
  duplicates the job node. ChatAnalyst does NOT apply that rule — it reports
  every chat `provenance_chat_files` returns, including a job's own
  `<job>.files/agent.chat` — which is intentional there (the analyst is
  supposed to show the full conversation per file), but any tooling copied
  from `prov`'s tree renderer must replicate the hiding rule or it will show a
  job twice. Conversely, any tooling that assumed "a job always has a visible
  `log/agent.chat` child" now sees nothing under `log/` for new jobs and must
  look at top-level `agent.chat` / `<name>.society/` instead.
- **Mixed trees are the norm during rollout.** Old `.files/log/**` next to new
  `*.files/*.chat` in the same dir yields a single de-duplicated visit per
  chat (scout-ai guarantee), so reports do not double count; ChatAnalyst's own
  `warning_key` deduplication of warnings is unaffected.

## 7. Summary of concrete actions (for the ChatAnalyst owner)

1. Update `README.md` sections quoted in §3 to the new layout, labeling
   `log/**` (and `log/chats/…` projections) as legacy/read-only. **Only real
   change needed.**
2. Optionally add new-layout fixtures + assertions to
   `test/test_agent_meta_tasks.rb` following §4 (add, do not rewrite).
3. Optionally refresh the five `tmp/verify_*` scripts per §5.
4. No `workflow.rb` change required: it is fully layout-agnostic through the
   shared `Chat.traverse_provenance` / `Chat.provenance_*` APIs.
