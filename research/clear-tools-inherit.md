# `clear_tools` social-inheritance mode — decision record

Feature: a fourth `SOCIAL_INHERIT_MODES` entry, `clear_tools`, so that
continuing a specialist conversation drops earlier bouts' tool-call
traces (`function_call`/`function_call_output`) from the context sent to
the model, while the stored chat, logs and provenance keep everything.
Design packet only — no production code changed here; this note pins the
decisions and the evidence for the later implementation packet.

Hard constraint (user): clearing is context-only. Nothing may be removed
from stored chats, logs, or provenance.

## Adopted semantics (rules 1-7)

1. **Mode accepted everywhere `inherit` is**: `SOCIAL_INHERIT_MODES`
   becomes `%w[none tools conversation clear_tools]`. The `ask` tool's
   `enum:` picks it up automatically (delegate.rb references the
   constant); only the separately maintained description string needs an
   edit.
2. **Continuation (the feature's core)**: when `ask_conversation`
   continues an EXISTING conversation (the `@chats[key]` continuation
   branch, no `restart:`), and `inherit == 'clear_tools'`, append
   `agent.current_chat.message :clear_tools, true` immediately before
   `agent.user(prompt)`. One marker per continuation call; repeated
   markers are equivalent by the reverse scan (probe A, case 5).
3. **Marker form**: content `true` (truthy), never `'false'` —
   `Chat.clear` treats `content != 'false'` as active, and the
   print/parse round trip turns `true` into String `"true"`, which is
   still active (probe B).
4. **Insertion site is `ask_conversation`, not `open_conversation`**:
   `load_chat`/`open_conversation` without a following prompt must not
   fire clearing (there is no new round to compile). The implementation
   obtains the "already existed" signal however it likes (pre-check of
   `@chats` under the social key, or a return tweak in
   `open_conversation`); the pinned contract is marker-then-prompt inside
   `ask_conversation` only.
5. **First creation (and any `restart:`) with `clear_tools`**: seed
   exactly like `'conversation'` (`social_inherited_context` case), no
   marker appended, plus ONE informational `Log.low` line (not a
   warning) naming the fallback. Rationale below.
6. **No `Chat.tools` change**: the marker never reaches `Chat.tools` in
   the live ask path, so chat-declared tool definitions survive; see
   probe A verdict.
7. **Both layers already coexist — keep them**: the raw chat-file role
   `clear_tools:` (clear.rb; used by AgentSuite `Planned` via
   `chat.message :clear_tools, true`) remains the low-level marker for
   workflow authors; the inherit mode is the delegation-level policy that
   appends that same marker on continuation. No new chat option is added.

## Why these choices (resolved ambiguities)

- **(c) Marker vs chat-line tool definitions — definitions INTACT.** The
  hazard in `Chat.tools` (`elsif role == 'clear_tools'; tool_definitions
  = {}`, tools.rb:222) is real only for a DIRECT `Chat.tools` call on a
  marker-bearing chat (probe A, case 1: `[]`). In the live ask path the
  marker is consumed earlier: `LLM.chat` runs `Chat.clear` (chat.rb:53)
  BEFORE any backend resolves tools (`backends/default.rb` `tools()` →
  `LLM.tools` → `Chat.tools`, always on the post-clear message list).
  Probe A cases 2-4: post-clear roles contain no `clear_tools`; tool
  definitions `["hi"]` both via `Chat.tools` on the compiled chat and
  end-to-end through `LLM.ask`. So plain insertion needs no re-append of
  tooling and no special insertion point; the smallest fix consistent
  with clear.rb/tools.rb semantics is NO fix. Keep the tools.rb branch as
  a guard for direct/raw consumers (removing it would change behavior no
  current caller exercises). This consumption ORDER in `LLM.chat` is
  load-bearing and must not be reordered.
- **(a) Granularity — one marker per continuation call.** The reverse
  scan in `Chat.clear` sets the drop flag at the nearest marker and never
  resets it before the break role, so one marker and N markers drop the
  same set of traces (probe A, case 5: identical definitions and
  model-visible roles with two markers). Appending unconditionally is
  simpler than dedup and proven harmless; stored-chats grow by one
  marker line per continuation.
- **(b) Creation fallback — 'conversation', silent-with-note.** At
  creation the specialist's own chat has no bouts, so there is nothing of
  its own to clear; seeding like `'conversation'` is the coherent choice
  because that is the mode whose context tool traces can come from. NOT
  chosen: clearing the CALLER's seeded traces at creation — the stated
  problem is the specialist conversation's own accumulation across bouts;
  a caller that wants its context pre-cleared can put a `clear_tools:`
  chat line in its own chat (rule 7). A warning is wrong (nothing failed;
  warnings train users to ignore them); full silence hides a mode
  interaction someone debugging context size will want visible — hence one
  `Log.low` line.
- **Inherit-mode vs the user's originally suggested plain
  `clear_tools: true` chat option.** The chat role already exists and
  stays; the inherit mode was preferred for the delegation surface
  because the `ask` tool's prompt is appended with `Agent#user`
  (deliberate security boundary: role-looking text in a delegated prompt
  cannot become a control message), so a caller CANNOT inject the marker
  through the tool — the `inherit` enum is the sanctioned channel for
  context policy. Both are provided: chat role for chat authors (Planned
  precedent), inherit mode for `ask`-tool callers.
- **Hard constraint already holds today.** Probe B: `LLM.chat`, `LLM.ask`
  and a full `Agent#chat` round leave the stored chat untouched — after
  the round the stored roles still contain `clear_tools` AND
  `function_call`/`function_call_output`; only the compiled model view
  drops them. The marker round-trips through `Chat.print`/`Chat.parse`
  (`"clear_tools:\n\ntrue"` → role `clear_tools`, content `"true"`,
  active), so save/reload keeps it working.
- **Adjacent non-interactions, recorded so nobody re-probes them**: the
  caller's `Chat#tooling` selection (`introduce`/`tool`/`mcp`/`kb`/
  `path_kind`) ignores `clear_tools` markers, so a marker in the caller's
  chat cannot leak into `inherit: 'tools'` seeding; `restart:` re-branches
  from start_chat (no prior content to clear → no marker, rule 5); a
  caller-seeded chat that already contains a `clear_tools` marker copies
  through `social_chat_copy` and behaves under the existing marker
  semantics — coherent, no special handling.

## Verification evidence (probes)

- Probe A — `tmp/clear-tools-design/probe_compiled_tools.rb`
  (`ruby tmp/clear-tools-design/probe_compiled_tools.rb`), the
  discriminating run. Stored chat: `tool: ProbeCTWF hi` line, one
  user/assistant round WITH a function_call/function_call_output pair,
  then `clear_tools true`, then the follow-up user prompt. Key output:
  - `direct_chat_tools_on_stored_chat: []` (the hazard, direct call only)
  - `compiled_roles_after_llm_chat: [system, tool, user, assistant,
    assistant, user]`, `compiled_marker_present: false`,
    `compiled_function_call_pairs: 0`
  - `chat_tools_on_compiled_chat: ["hi"]`
  - `ask_path_tool_definitions: ["hi"]`,
    `ask_path_model_visible_roles: [system, user, assistant, assistant,
    user]` (mock backend, end-to-end)
  - `repeat_marker_*`: same as single marker.
  - VERDICT: definitions INTACT in the ask pipeline; stripped only for a
    direct `Chat.tools` call on the marker-bearing stored chat.
- Probe B — `tmp/clear-tools-design/probe_constraints.rb`
  (`ruby tmp/clear-tools-design/probe_constraints.rb`, mock backend via
  `Scout::Config.set({backend: :mock}, :ask, :llm)`). Key output:
  - `stored_roles_after_llm_chat` / `stored_roles_after_llm_ask` still
    contain `clear_tools`, `function_call`, `function_call_output`
    (`llm_chat_mutates: false`, `llm_ask_mutates: false`)
  - `agent_stored_roles_after_round: [..., clear_tools, user,
    assistant]`, `agent_round_preserves_marker_and_traces: true`
  - `Chat.print`/`Chat.parse` round trip: marker survives as String
    `"true"`, active (`!= 'false'`); `Chat.tools` on that recompiled chat
    returns `["hi"]` (the `marker_roundtrip_*` keys in the probe are null
    because that check ran `LLM.chat` — the compiled view — which
    consumes the marker by design; the parse-only round trip was
    confirmed separately: `Chat.parse(Chat.print(chat))` →
    `[["clear_tools","true"],["user","hi"]]`).

## Files to change (implementation packet, not done here)

- `lib/scout/llm/agent/conversation.rb` — add `'clear_tools'` to
  `SOCIAL_INHERIT_MODES`; `social_inherited_context` case `'clear_tools'`
  → same as `'conversation'`; `ask_conversation` continuation-branch
  marker append (rule 2/4) with the `Log.low` creation fallback note
  (rule 5).
- `lib/scout/llm/agent/delegate.rb` — the `inherit` description string
  only (enum already derives from the constant).
- `test/scout/llm/agent/test_conversation.rb` — pin tests: creation seeds
  like conversation with no marker (+ log note); continuation appends the
  marker before the user prompt; stored chat retains marker and traces
  after a round; repeated continuations equivalent; restart emits no
  marker.
- `doc/developer/DelegationInternals.md` — mode table row, continuation
  semantics, and the note that `inherit` now has one mode with
  continuation-time behavior (the others remain creation-only).
- NOT changed: `lib/scout/llm/chat/process/clear.rb`,
  `lib/scout/llm/chat/process/tools.rb` (rule 6).

## Working-tree note

`lib/scout/llm/chat/process/tools.rb` carries a PRE-EXISTING uncommitted
modification (the `path_kind` registration moved out of `Chat.tools`;
commit 9fd2269 follow-up). It belongs to the prior feature, is orthogonal
to `clear_tools` (the `clear_tools` branch at tools.rb:222 is untouched
by it), and was left exactly as found. All probe evidence above was
gathered against the working tree WITH that diff applied.
