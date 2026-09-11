# Delegation Internals

This document explains how Scout-AI implements multi-agent delegation at the
code level: the `SOCIAL_INHERIT_MODES` system, the `ask` tool mechanics, the
`delegate` method, and the template-clone lifecycle. It is intended for
framework contributors.

> For the user-facing guide to delegation, see
> [../user/Delegation.md](../user/Delegation.md).
> For deep code investigation, see
> [../../research/agent-delegation-analysis.md](../../research/agent-delegation-analysis.md).

---

## Overview

Delegation is implemented in `lib/scout/llm/agent/delegate.rb` and the shared
conversation pipeline in `lib/scout/llm/agent/conversation.rb` (moved there
from `delegate.rb`; tool definitions are built by `LLM.tool_definition` in
`lib/scout/llm/tools/definition.rb`). It provides two mechanisms for one
Agent to invoke another:

1. **`socialize`** — Registers a generic `ask` tool that lets the LLM delegate
   to any specialist agent by name at runtime.
2. **`delegate`** — Registers a named `hand_off_to_<name>` tool for a specific,
   pre-loaded Agent instance.

Both mechanisms build on a common infrastructure: the **open_conversation
pipeline**, the **template-clone pattern**, the **socialized chat store**, and
the **inheritance modes**.

---

## The template-clone pattern

Each specialist agent type is loaded **once** as an immutable template and stored
in `@society`:

```
@society = {
  "Worker"  => Agent (template, loaded once),
  "Critic"  => Agent (template, loaded once)
}
```

When a new conversation with a specialist is needed, the template is **deep
cloned** (`clone_social_agent`):

```ruby
def clone_social_agent(template)
  agent = template.clone
  agent.start_chat     = social_chat_copy(template.start_chat)
  agent.other_options  = IndiferentHash.setup(social_duplicate(template.other_options || {}))
  agent.society        = nil    # prevent cross-contamination
  agent.chats          = nil    # of delegation state
  agent.instance_variable_set(:@current_chat, nil)
  agent
end
```

Each clone gets:
- Its own `start_chat` (deep-copied).
- Its own `other_options` (deep-copied via `social_duplicate`).
- Nilled `society` and `chats` — no accidental access to the caller's delegation state.
- A nilled `current_chat` — forces lazy re-creation.

The deep-copy (`social_duplicate`) is recursive for Hash, Array, and String,
and passes Procs by reference (since they can't be marshalled but are safe to
share).

---

## The socialized chat store

Live specialist instances are stored in `@chats`, keyed by `"agent_name/conversation"`:

```
@chats = {
  "Worker/default"     => Agent (clone, persistent conversation),
  "Worker/analysis_1"  => Agent (clone, named conversation),
  "Critic/default"     => Agent (clone)
}
```

Conversation keys are **scoped by agent**: `Worker/work_A` and
`Critic/work_A` are independent conversations.

### Persisted society layout

Live conversations are also mirrored to disk, but **lazily**: nothing is
created until an agent actually saves. `Agent#save` decides the canonical
location from the save target of the *parent* agent:

- The root chat saved at `p.chat` produces a society tree rooted at
  `p.chat.files/agent.society/<agent_name>/<conversation>/agent.chat`
  (named agents use `<name>.society`, e.g. `worker.society`).
- A nested chat already stored at
  `.../society/<a>/<c>/<file>` makes the society of *its* children the
  **sibling** directory `.../society/<a>/<c>/society/...`. A nested
  `agent.chat` never grows a second `.files` tree of its own. Only the
  depth-0 society directory is named after the chat (`<name>.society`);
  every deeper level keeps the plain `society` basename.
- `chat_task` jobs and the `scout-ai agent ask` CLI always write the agent's
  own chat at `<chat_or_job_path>.files/<name>.chat`: `agent.chat` for an
  unnamed/`agent` agent, `worker.chat`/`critic.chat` for named ones.
- For a persisted **chat** root that file is a full copy of the root
  conversation; provenance scanning of the sidecar excludes exactly that
  top-level copy, while the society conversations under
  `<chat>.files/<name>.society/<agent_name>/<conversation>/agent.chat` are
  included even though they are also named `agent.chat`. Job roots keep
  their own top-level `<name>.chat` as a normal log node (renderers hide
  it), and the `:log` relation covers exactly
  `*.files/*.chat` and `*.files/*.society/**/*.chat`, so `resets/` snapshots
  stay out.

An agent with no live society writes only its own chat file and creates no
`.files` tree at all; parent directories are created on demand by
`Open.sensible_write`. Children get their `save_file` assigned during a
parent save, so later independent child turns keep auto-saving in place.
Saves are cycle-safe (visited paths + seen agents + a depth limit of 32) and
non-fatal: a failure is logged as a warning and the run continues.

#### Sibling state: the one-derivation convention

Every piece of derived agent state is a **sibling of the save_file**, never a
nested `.files` entry and never an appended suffix on the full chat path. For
save_file `<dir>/<base>.chat` the siblings are:

| Sibling | Written by | Meaning |
|---|---|---|
| `<base>.society/` | `Agent#save` (society tree) | delegated conversations, layout above |
| `<base>.inbox/` | inbox strategy (`Chat.inbox_dir`) | files delivered into the next round |
| `<base>.inbox_removed/` | `Chat.inbox_removed_target` | delivered files moved out of the inbox, kept with collision suffixes |
| `<base>.jobs` | `LLM.process_calls` | transient snapshot of in-flight workflow jobs |

Derivation strips only a **trailing** `.chat` and appends the suffix
(`Chat.inbox_stem` + suffix in `lib/scout/llm/chat/prompt/inbox.rb`;
`Chat.jobs_file` for `.jobs`); an extension-less basename keeps its whole
name, and a multi-dot base strips only the last extension. The
`<job>.chat.files/agent.chat` path shape never appears as a state base: the
canonical agent chat of a job is `<job>.files/<name>.chat`, and its siblings
are `<job>.files/<name>.inbox` etc.

#### Live traceability of delegated work

Delegation is observable *while it runs*, not only afterwards:

- **Type 4 (ask/hand_off)** — each delegated conversation is its own
  `agent.chat` under the society tree, and `Agent#chat` auto-saves after every
  round, so the file grows round by round while the parent's tool round is
  open. Its sibling inbox is honoured by the child's next real round.
- **Type 5 (tool-calling delegation)** — `LLM.process_calls` writes the
  caller's `<base>.jobs` sidecar just before `Workflow.produce` and removes it
  in an `ensure`, so the in-flight workload is visible for the whole blocking
  window (child `.info` follows within a fraction of a second of the fork).
- **Type 3 (chat_task `ask`)** — the chat_task writes an immediate `job=`
  `meta` line into the agent's current_chat and saves agent state *before* the
  task completes, so the job reference exists while the answer is still being
  computed.

**Plain agents (no workflow)** never write a `job=` meta at all: their `ask`
calls `LLM.ask` directly with `save_file: self.save_file`, producing no
workflow job, so their liveness is observable only through save-file growth.

#### The activity predicate

The live pass classifies an agent save file from its **trailing
conversational message**, skipping control roles (`meta`, `option`,
`sticky_option`, `previous_response_id`, `agent`, `import`, `socialize`,
`attachments`) so a file that ends with the dispatch-time `meta: job=…`
line still reads as its real trailing turn. Encoded rules
(`Chat.agent_log_activity`):

| trailing message | verdict |
|---|---|
| `user` | active, `:dispatched` |
| `function_call` with no later `function_call_output` | active, `:tool_round_in_flight` |
| `function_call_output` | active, `:next_round_pending` |
| `assistant` with no open call | inactive, `:idle` |
| empty file | inactive, `:no_messages` |
| unreadable/missing file | inactive, `:unreadable` |
| any other role (system, introduce, tool) | inactive, `:no_inference` |

`rounds:` is the count of `assistant` messages. The predicate is sound only
because two writers rewrite the save file on a known cadence: the backend
writes the outgoing transcript at every round boundary, and the agent layer
rewrites the completed round afterwards (`Agent#chat` ensure →
`save_if_configured`). Accepted false negative: an `assistant`-terminated
file reads idle during the brief round-boundary window in which a completed
round is saved but the next dispatch is not flushed yet — a mid-conversation
agent can be missed for that instant, never falsely reported.

#### The dangling `job=` meta lifecycle

Type-3 dispatch (`Agent#ask` on a workflow-backed agent) writes
`self.message(:meta, Chat.serialize_meta(job: job.short_path))` and
immediately `self.save`, both **before** `job.produce` blocks: the reference
is on disk in the agent's own save file — for a societal child, the society
child file itself, never the parent's root chat — for exactly the duration
of the child run, and stays there afterwards pointing at a terminal job.
The live pass follows these references to jobs and reports only the ones
that are still running; the parent's root chat gets no `function_call`
record for the child until the tool round completes, which is why the
society tree and the child save files, not the parent chat, are the live
evidence for type 4.

#### Waiting wrappers and the dependency fallback

`LLM.process_calls` calls `init_info` on every in-flight job **and its
`rec_dependencies`** before writing the sidecar, so `.info` files exist for
reconciliation even for dependency-nested running work. But scout-gear
records a job's `dependencies:` in `.info` only at
`reset_info(status: :setup)`, which runs after `run_dependencies` returns:
while a chat_task dependency runs, the wrapper `.info` is still
`{"status":"waiting"}` — no pid, no dependencies. The live traversal covers
that window by scanning the wrapper's own workflow namespace
(`var/jobs/<Workflow>/*/*.info`, sibling task directories; `.info` glob, not
a directory glob, because a chat_task job path is itself a file) for running
jobs, reporting the wrapper once as workload context with `state:
:waiting`. The workflow definition is never loaded (the `workflows` pathmap
cannot see an arbitrary jobs tree), attribution stays bounded to the
wrapper's workflow directory, the walk uses direct `dependencies` with a
visited-path cycle guard plus a depth cap (`LIVE_DEPENDENCY_DEPTH_LIMIT` 5),
and everything is fail-soft: absent sidecar, absent save file, absent
society tree and unreadable jobs each yield nothing, never an error.

After conclusion the forensic trail takes over: `step:` short paths, receipts
under the `meta` key of the `function_call_output` envelope, and the projected
chat_task answer in the conversation. See
[Provenance.md](Provenance.md#live-work---live) for the consumer side.

### The `open_conversation` pipeline — get-or-create

All setup goes through one method (in `lib/scout/llm/agent/conversation.rb`),
which runs five ordered steps:

```ruby
open_conversation(name, conversation: 'default', inherit: 'tools', options: {},
                  preamble: nil, anchor: nil, restart: false,
                  template: nil, adopt: nil, job: nil)
```

1. **Resolve template** — an explicit `template:` (a pre-built Agent) wins;
   otherwise `load_agent(name, options)` loads and caches one immutable
   template per specialist in `@society`.
2. **Seed** — clone via `clone_social_agent`, then build the initial chat:
   the specialist's own `start_chat` copy, optionally the adopted template
   delta (`adopt: :current` folds the template's progress beyond its own
   `start_chat` into the seed), then the inherited context per `inherit:`,
   then any `preamble:`.
3. **Anchor** — `agent.save_file = anchor || society_save_file(name,
   conversation)` is assigned at creation, so autosave and `restart:`
   snapshots apply from the first round.
4. **Register** — `@chats["<name>/<conversation>"] ||= agent`.
5. **Restart** — `restart: true` re-branches the existing conversation in
   place (start_chat kept, tail dropped); no new key is minted.

`load_chat`, `load_agent`, and `ask_agent` remain as thin wrappers over this
pipeline, and `ask_conversation` is the prompt-appending companion.
`conversation_agent(key)` returns the registered live conversation (nil when
absent). The `delegate` default hand-off block uses exactly this pipeline
(conversation slot = the delegated name, `inherit: 'none'`, `template:` the
passed agent, `adopt: :current`, `restart:` from `new_conversation`), so
hand-off children persist under
`<save>.society/<agent>/<slot>/agent.chat` and are swept by the parent save;
the passed agent object is only the template, not the conversation holder.
Custom blocks and non-Agent duck objects keep the legacy direct-mutation
contract. The passed Agent is also pre-registered in `@society[name] ||=`,
making it the template for later `ask` calls to that name.

The `inherit` parameter is only consulted **once** — when the conversation is
first created. Follow-up turns reuse the existing conversation with its
accumulated history.

---

## SOCIAL_INHERIT_MODES

Three modes control how much caller context flows to a specialist on first
contact:

| Mode | What is inherited | Use case |
|---|---|---|
| `none` | Nothing. Specialist starts with its own `start_chat` only. | Fully isolated sub-agent. |
| `tools` *(default)* | Tooling roles (`introduce`, `tool`, `mcp`, `kb`) from the caller's **whole current chat**. | Shared capabilities, private history. |
| `conversation` | The caller's entire current chat minus its own `start_chat` prefix. | Full context sharing for tight collaboration. |

### Implementation: `social_inherited_context`

```ruby
def social_inherited_context(inherit)
  case inherit
  when 'none'
    Chat.setup([])
  when 'tools'
    tooling = self.current_chat.tooling
    social_chat_copy(tooling)   # whole current chat's tooling — see Known drift
  when 'conversation'
    social_caller_context
  end
end
```

### `social_caller_context` — extracting non-start-chat messages

For `conversation` mode, the method extracts the "new" messages the caller
has added beyond its own `start_chat`. It uses a fast path (object identity
comparison) when the same Hash objects are shared, and a fallback (prefix
matching) for separately parsed Chats.

The specialist's rebuilt `start_chat` becomes:

```
[specialist's original start_chat] + [inherited context from caller]
```

So the specialist always gets its own system prompt first, then optionally the
caller's tools or full conversation.

---

## The `socialize` method

Registers a single tool named `:ask` that the LLM can invoke to delegate to
any specialist:

**Tool schema exposed to the model:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `agent` | string | Yes | Name of the specialist agent. |
| `prompt` | string | Yes | Plain-text prompt. |
| `conversation` | string | No | Named conversation ID (omit for one-shot). |
| `inherit` | enum `[none, tools, conversation]` | No (default `tools`) | Context policy for new conversations only. `tools` reads the whole current chat's tooling, not the delegating task's. |

**Security boundary:** The tool block calls `ask_agent`, which uses
`agent.user(prompt)` rather than `agent.prompt(prompt)`. This is deliberate:
`prompt` parses chat-file syntax, which could allow prompt injection to inject
`tool:` or `system:` directives. The `user` method only appends a single
user-role message, making delegation safe even with untrusted LLM-generated
prompts.

**Option stripping:** Private options (`SOCIAL_PRIVATE_OPTIONS`) are stripped
before being passed to the specialist:

```ruby
SOCIAL_PRIVATE_OPTIONS = %i[
  agent client current_meta format messages no_ask_override
  previous_response_id process return_messages tool_choice tools
].freeze
```

This prevents leaking session state, tool blocks, or message arrays from the
caller to the specialist.

### Delegated inference receipts

When a delegation tool returns an `LLM::Agent`, `LLM.process_calls` embeds
the child agent's `meta` messages in the parent `function_call_output`
envelope under the `meta` key, as an Array of **already-deserialized** field
Hashes (one for the child's own inference metadata, one per producer
reference: a `job` key holding the child job path). These receipts are provenance evidence, not parent-chat
messages: the child's inference metadata and producer job reference are read
from the paired tool output and never injected into the parent chat. Provenance
tooling consumes them through `Chat.agent_meta_evidence` and the `:agent_job`
relation; see [Provenance.md](Provenance.md) for the extraction, precedence
(the `meta` key only; the legacy `agent_meta` envelope is no longer read), and accounting rules.

---

## The `delegate` method — named hand-off

```ruby
def delegate(agent, name, description, task_name = nil, &block)
```

Creates a tool named `hand_off_to_#{name}` for a **specific, pre-loaded**
Agent instance. Unlike `socialize`, the agent is not chosen by the model at
call time — it is hard-coded at registration time.

| Parameter | Description |
|---|---|
| `agent` | A pre-loaded `LLM::Agent` instance. |
| `name` | Tool name suffix (e.g., `worker` → `hand_off_to_worker`). |
| `description` | Tool description for the LLM. |
| `&block` | Optional custom tool block. Defaults to: `agent.user(message); agent.chat`. |

### Differences from `socialize`

| Aspect | `socialize` | `delegate` |
|---|---|---|
| Agent name | Model chooses at call time | Hard-coded at registration |
| Tool name | `:ask` (one tool for all agents) | `hand_off_to_#{name}` (one per agent) |
| Custom block | No (fixed block) | Yes |
| Conversation mgmt | Named conversations via `conversation` param | Single conversation, resettable via `new_conversation` |

---

## Known drift

- **`inherit: 'tools'` is chat-scoped, not task-scoped.** The implementation
  reads `self.current_chat.tooling`, i.e. the tooling of the caller's *whole*
  current chat — which is what [user/Delegation.md](../user/Delegation.md)
  now documents. A commented-out alternative (`social_caller_context.tooling`)
  in the source shows caller-delta (task) scoping was the original intent.
  Pin the intended semantics with a regression test before changing either
  side.

---

## Legacy parameter handling

The old `chat` parameter is silently accepted for backward compatibility via
`social_tool_parameters`:

| Legacy `chat` value | Maps to `conversation` | Maps to `inherit` |
|---|---|---|
| `'current'` | `'current'` | `'conversation'` |
| `''`, `'none'`, `'false'` | `nil` (one-shot) | `'none'` |
| Any other name | That name | `'tools'` |

New code should use `conversation` and `inherit` as separate parameters.

---

## Key source files

| File | Responsibility |
|---|---|
| `lib/scout/llm/agent/delegate.rb` | All delegation logic |
| `lib/scout/llm/agent.rb` | `Agent` class, `ask` entry point, `load_agent` class method |
| `lib/scout/llm/agent/chat.rb` | `start_chat`, `current_chat`, Chat proxy via `method_missing` |
| `lib/scout/llm/agent/workflow.rb` | `chat_task`, `log_agent` — workflow integration |
| `lib/scout/llm/chat/provenance.rb` | Live passes over save files, society trees and `.jobs` sidecars |
| `lib/scout/llm/tools/call.rb` | `<base>.jobs` writer/removal in `LLM.process_calls` |

---

## Cross-references

- [../user/Delegation.md](../user/Delegation.md) — User guide to delegation.
- [Provenance.md](Provenance.md) — Receipt-based provenance for delegated inference.
- [../user/MultiAgentWorkflows.md](../user/MultiAgentWorkflows.md) — Orchestration patterns.
- [../../research/agent-delegation-analysis.md](../../research/agent-delegation-analysis.md) — Deep investigation.
- [../../research/multi-agent-patterns-analysis.md](../../research/multi-agent-patterns-analysis.md) — SC26 patterns.
