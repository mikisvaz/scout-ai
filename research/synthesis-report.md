> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# Synthesis Report: Scout-AI Documentation Revamp

**Purpose:** Identify consistency issues, gaps, overlaps, and produce a concrete
mapping from the 10 research artifacts (SHARED/01–10) to the new documentation
structure. Also flag information from existing docs that must be preserved.

---

## 1. Consistency Issues Between Artifacts

### 1.1 SOCIAL_INHERIT_MODES — Terminology Consistent ✅

All artifacts that mention social inheritance (03, 04, 08, search_brief) agree on
**3 modes**: `none`, `tools` (default), `conversation`. The earlier concern about
"4 modes" was resolved during research and is consistently reported as 3. No
contradiction.

**Action for docs:** State clearly there are exactly 3 modes. Note the legacy
`chat` parameter compatibility shim (`current` → `conversation: current, inherit:
conversation`; bare `none` → no conversation).

### 1.2 Tool-Call Pruning Thresholds — Terminology Drift ⚠️

| Artifact | Term used | Value |
|----------|-----------|-------|
| 02 (Prompt Strategies) | `full_tool_calls` (keep fully) | default 0 |
| 02 (Prompt Strategies) | `max_tool_calls` (remove entirely) | default 40 |
| search_brief | "pruned after 10, removed after 40" | 10 / 40 |
| 04 (AgentWorkflow) | "pruned after 10, removed after 40" | 10 / 40 |
| 05 (Backends) | references `prepare_prompt` and `shorten_tools` | — |

**Issue:** The search_brief and artifact 04 state "pruned after **10**", but
artifact 02 (which is the authoritative source for `prompt.rb`) lists
`full_tool_calls = 0` and `max_tool_calls = 40`. The "10" appears to come from
`full_tool_outputs` (default 10), which is about tool **outputs**, not tool
**calls**. The artifacts conflate two separate thresholds:

- `full_tool_calls` (0): number of recent tool *call* messages kept fully
- `full_tool_outputs` (10): number of recent tool *output* messages kept fully
- `max_tool_calls` (40): hard limit on tool *call* messages before removal
- `max_tool_outputs` (40): hard limit on tool *output* messages before removal

**Action for docs:** `PromptStrategies.md` must clearly distinguish tool calls
from tool outputs and list all four thresholds with their defaults. Do not
repeat the "pruned after 10" shorthand without qualification.

### 1.3 `prepare_prompt` Integration Point — Consistent ✅

Artifacts 02, 04, and 05 all agree that `Chat.prepare_prompt` is called inside
`Backend::Default#ask`, just before the actual API call. The prompt strategies
are ephemeral (not persisted to chat files). No contradiction.

### 1.4 Backend List — Minor Discrepancy

| Source | Backends listed |
|--------|----------------|
| search_brief | openai, anthropic, bedrock, huggingface, ollama, openwebui, relay, responses, vllm |
| doc/LLM.md | responses, openai, anthropic, ollama, vllm, openwebui, bedrock, relay |
| Artifact 05 | (detailed per-provider analysis) |

**Issue:** `huggingface` appears in the search_brief/codebase listing but is NOT
mentioned in the existing `doc/LLM.md`. Artifact 05 covers all providers in
detail. The `responses` backend is described as "default" in LLM.md but this
should be verified against artifact 05.

**Action for docs:** `Backends.md` should have a complete provider table sourced
from artifact 05, including `huggingface`. Mark which are fully featured vs.
thin wrappers.

### 1.5 `info` vs `prov` Command Status — Consistent ✅

Artifacts 07 and 10 both independently confirm that `scout-ai llm info` is the
current, recommended provenance command, and `scout-ai llm prov` is superseded
(uses monkey-patches, has hardcoded fallback path). No contradiction.

### 1.6 ChatAnalyst Location — Ambiguity

Artifact 07 documents ChatAnalyst as part of the SC26 workflow
(`~/git/workflows/SC26/Agent/ChatAnalyst/`), not in the core library. Artifact
08 also references it. The search_brief flags this as an uncertainty.

**Action for docs:** `Provenance.md` should document ChatAnalyst as an
SC26-specific agent, not a core library feature. Note that it may be promoted to
core in the future.

### 1.7 Tool Definition Format — Consistent ✅

Artifacts 05 and 06 agree: tools are represented as `{name => [handler,
definition]}` hashes. Handler can be a Workflow, KnowledgeBase, or Proc.
Definition is an OpenAI-style function schema. No contradiction.

### 1.8 Agent `ask` vs `chat` Method Semantics — Consistent ✅

Artifacts 03 and 04 agree:
- `ask(messages, options)` → low-level, returns string (or message trace with
  `return_messages: true`)
- `chat(options)` → high-level, calls `ask(current_chat, return_messages: true)`,
  appends messages to `current_chat`, returns assistant content

No contradiction. This matches the existing `doc/Agent.md`.

---

## 2. Gaps Identified

### 2.1 Installation and Setup (HIGH priority gap)

**Gap:** None of the 10 artifacts cover installation, Gemfile setup, or initial
endpoint configuration. This content exists only in `doc/USER_GUIDE.md` and
`doc/LLM.md`.

**Action:** `README.md` and/or `Overview.md` must include a "Getting Started"
section with Gemfile, bundle install, and first endpoint creation. Source from
existing `USER_GUIDE.md` §2 and `LLM.md` §1.

### 2.2 Python Integration (MEDIUM priority gap)

**Gap:** Python-backed agent tasks (auto-loading `python/*.py` files) and the
Python SDK (`../python/README.md`) are NOT covered in any artifact. This content
exists only in `doc/PythonAgentTasks.md`.

**Action:** Add a section to `Agent.md` or a dedicated `Python.md` doc. Source
from existing `PythonAgentTasks.md`. The proposed structure does not include a
Python doc — recommend adding one or folding into `Agent/Agent.md`.

### 2.3 Model Subsystem (LOW priority gap)

**Gap:** The `ScoutModel` / `PythonModel` / `TorchModel` / `HuggingfaceModel`
subsystem (documented in `doc/Model.md`) is NOT covered in any artifact. This is
a separate concern from LLM backends — it's about wrapping ML models for
evaluation/training.

**Action:** This is tangential to the agent/LLM documentation revamp. Recommend
keeping `Model.md` as-is or moving to a separate `doc/Model/` area. Do NOT merge
into the new structure unless explicitly requested.

### 2.4 Endpoint Configuration Details (HIGH priority gap)

**Gap:** Detailed endpoint YAML configuration (keys, examples for different
backends, `~/.scout/etc/AI/<name>` format, config defaults via
`~/.scout/etc/config`) is NOT fully covered in any artifact. Artifact 05 covers
backend internals but not the user-facing endpoint setup.

**Action:** `Backends/Backends.md` or a dedicated section in `Overview.md` must
include endpoint configuration. Source from existing `LLM.md` §1 and §4.

### 2.5 Caching / Persistence Behavior (MEDIUM priority gap)

**Gap:** `LLM.ask` caching behavior (`persist: true` by default, cache key
composition, `persist: false` to disable) is mentioned in existing `LLM.md` §2.3
but NOT in any artifact.

**Action:** Include in `Backends/Backends.md` or `Chat/Persistence.md`.

### 2.6 `LLM.workflow_ask` and `LLM.knowledge_base_ask` Helpers (LOW priority gap)

**Gap:** Convenience helpers documented in existing `LLM.md` §6 are not in any
artifact.

**Action:** Include in `Tools/WorkflowTools.md` and `Tools/KnowledgeBase.md`.

### 2.7 `previous_response_id` Session Continuation (LOW priority gap)

**Gap:** Responses backend session continuation behavior is in existing `LLM.md`
§4.2 but not in any artifact.

**Action:** Include in `Backends/Backends.md`.

### 2.8 Agent Error Handling (`process_exception`) (LOW priority gap)

**Gap:** The `agent.process_exception` Proc for retry-on-exception is in existing
`Agent.md` §11 but not deeply covered in any artifact.

**Action:** Include in `Agent/Agent.md`.

### 2.9 Agent Structured Output Methods (LOW priority gap)

**Gap:** `agent.json`, `agent.json_format(schema)`, `agent.iterate`,
`agent.iterate_dictionary` are documented in existing `Agent.md` §6–7 but not
deeply covered in any artifact (artifact 03 mentions `iterate` but not
`json_format`).

**Action:** Include in `Agent/Agent.md`.

### 2.10 Chat Server / Web UI (LOW priority gap)

**Gap:** The `scout-ai llm server` Sinatra web UI is documented in artifact 10
but not in any other artifact. It is a user-facing feature.

**Action:** Include in `Commands/Commands.md`.

### 2.11 Inline Question Processing (`# ask:` comments) (LOW priority gap)

**Gap:** The `--inline` mode for `scout-ai llm ask` (processing `# ask:`
comments in source files) is documented in artifact 10 but could use a
standalone example.

**Action:** Include in `Commands/Commands.md`.

---

## 3. Overlaps to Consolidate

### 3.1 Chat Processing Pipeline (Artifacts 01, 02, 06)

The chat processing pipeline (meta → tools → files → options → clear) is
described from different angles in:
- **01 (Chat Core):** Full processing pipeline order, role families
- **02 (Prompt Strategies):** The `prepare_prompt` step (pre-inference)
- **06 (Tools System):** Tool extraction from chat (`Chat.associations`)

**Consolidation:** `Chat/Chat.md` should own the processing pipeline narrative.
`PromptStrategies.md` should focus only on the `prepare_prompt` step and
reference `Chat.md` for the overall pipeline. `Tools/Tools.md` should reference
`Chat.md` for how tools are declared in chat files.

### 3.2 Tool Calling Loop (Artifacts 05, 06)

The `chain_tools` recursive loop is described in:
- **05 (Backends):** `Backend::Default#chain_tools` — the inference-side loop
- **06 (Tools System):** `LLM.process_calls` — the execution pipeline

**Consolidation:** `Tools/Tools.md` should own the tool-calling protocol
description (definition → model calls → execution → re-ask).
`Backends/Backends.md` should reference `Tools.md` rather than duplicating the
loop mechanics. The boundary: Backends.md owns "how the backend orchestrates
inference + tool calls"; Tools.md owns "how tools are defined, called, and
executed."

### 3.3 Agent Delegation (Artifacts 03, 04, 08)

Delegation mechanics appear in:
- **03 (Agent & Delegation):** `SOCIAL_INHERIT_MODES`, `socialize`, `delegate`,
  `ask_agent`, `hand_off_to_<name>`
- **04 (AgentWorkflow):** How `chat_task` uses agents, `log_agent`
- **08 (Multi-Agent Patterns):** Planned, Manager, Branched, Refined patterns

**Consolidation:** Three docs with clear boundaries:
- `Agent/Delegation.md` — the mechanics (socialize, delegate, inherit modes,
  ask tool, hand_off tool). Source: artifact 03.
- `Agent/AgentWorkflow.md` — the workflow bridge (chat_task, agent helper,
  log_agent, tooling extraction). Source: artifact 04.
- `Agent/MultiAgentPatterns.md` — the patterns (Planned, Manager, Branched,
  Refined, InterpretData). Source: artifact 08. References Delegation.md for
  mechanics.

### 3.4 Provenance (Artifacts 07, 10)

Provenance appears in:
- **07 (Provenance):** `Chat.provenance`, `trace_chats`, `prov`/`info` commands,
  ChatAnalyst
- **10 (Commands):** Detailed `prov` and `info` command documentation

**Consolidation:** `Provenance/Provenance.md` should own the provenance data
model and concepts. `Commands/Commands.md` should have concise command
references that link to `Provenance.md` for concepts. Do not duplicate the full
command documentation in both places.

### 3.5 Prompt Strategies (Artifacts 02, 04, 05)

`prepare_prompt` / `shorten_tools` is mentioned in:
- **02 (Prompt Strategies):** Full implementation detail
- **04 (AgentWorkflow):** System message injection about pruning
- **05 (Backends):** Integration point in `Backend::Default#ask`

**Consolidation:** `Chat/PromptStrategies.md` is the single source. Other docs
reference it. The system message injection (from 04) belongs in
`PromptStrategies.md` as a "How agents learn about pruning" subsection.

---

## 4. Artifact-to-Doc Mapping Table

| New Doc File | Primary Artifacts | Secondary Sources | Gaps to Fill |
|---|---|---|---|
| `doc/README.md` | 00, 09 | search_brief §Themes | Entry point, audience guide, TOC. Pull philosophy from 09. Write from scratch. |
| `doc/Overview.md` | 00, 09, 01 (§architecture) | search_brief §Themes, existing USER_GUIDE §1 | High-level architecture diagram (text), key abstractions, design philosophy. Installation/setup from USER_GUIDE §2. |
| `doc/Chat/Chat.md` | 01 | 06 (tool roles), existing Chat.md | Core data model, all roles, message types, builder DSL. Processing pipeline narrative owner. |
| `doc/Chat/PromptStrategies.md` | 02 | 04 (system msg injection), 05 (integration point) | `prepare_prompt`, `shorten_tools`, all thresholds (calls vs outputs), custom strategies, ephemeral nature. Fix the "10 vs 40" confusion. |
| `doc/Chat/Persistence.md` | 01 (§persistence), 07 (§annotations) | existing Chat.md, existing LLM.md §2.3 | `.chat` file format, provenance annotations (`meta:` roles), caching/persist behavior. |
| `doc/Agent/Agent.md` | 03 (§Agent class) | existing Agent.md §1–7,9,11 | Agent class lifecycle, `start_chat`/`current_chat`, DSL forwarding, tool wiring, `ask` vs `chat`, structured outputs (`json`, `json_format`, `iterate`), error handling, agent loading. |
| `doc/Agent/AgentWorkflow.md` | 04 | 03 (§delegation ref) | `chat_task` pattern, `agent`/`chat`/`tooling`/`log_agent` helpers, `require_workflow` fallback, workflow-provided `ask` task. |
| `doc/Agent/Delegation.md` | 03 (§delegation) | search_brief §Delegation | `SOCIAL_INHERIT_MODES` (3 modes), `socialize`/`ask` tool, `delegate`/`hand_off_to_<name>`, `ask_agent`, socialized chat files, legacy `chat` param. |
| `doc/Agent/MultiAgentPatterns.md` | 08 | 04 (chat_task ref) | Planned, Manager, Branched, Refined, InterpretData patterns. Budget management. Branch-specific chats. |
| `doc/Backends/Backends.md` | 05 | existing LLM.md §1,4 | Backend abstraction, `chain_tools` loop (reference Tools.md), provider table (all 9+), endpoint YAML config, `previous_response_id`, caching. |
| `doc/Tools/Tools.md` | 06 | 05 (chain_tools ref) | Tool definition format, `{name => [handler, definition]}`, calling protocol, `process_calls`, output limits (`max_content_length`). |
| `doc/Tools/WorkflowTools.md` | 06 (§workflow tools) | existing LLM.md §5.2, §6.1 | `LLM.workflow_tools`, `LLM.workflow_ask`, `tool:` chat role, task/exec_task/inline_task/job roles. |
| `doc/Tools/MCP.md` | 06 (§MCP) | 10 (`workflow mcp` cmd) | MCP integration, `mcp:` chat role, `workflow.mcp_stdio`, MCP tool wrapping. |
| `doc/Tools/KnowledgeBase.md` | 06 (§KB tools) | existing LLM.md §5.3, §6.2, existing RAG.md | KB as tool, `association:`/`kb:` roles, `LLM.knowledge_base_ask`, RAG (`LLM::RAG.index`, embeddings). Merge existing RAG.md content. |
| `doc/Provenance/Provenance.md` | 07 | 10 (`info`/`prov` cmds) | `Chat.provenance`, `trace_chats`, `job_agent_chat_files`, token accounting, `info` vs `prov` comparison, ChatAnalyst (SC26-specific). |
| `doc/Commands/Commands.md` | 10 | existing LLM.md §7 | All CLI commands with concise reference. Link to detail docs. Cover: `llm ask`, `llm info`, `llm prov` (deprecated), `llm json`, `llm md`, `llm word`, `llm template`, `llm server`, `llm process`/`process_queries` (legacy), `agent ask`, `agent find`, `agent kb`, `workflow mcp`, `documenter` (prototype). |
| `doc/Improvements.md` | 09 (§recommendations), 10 (§issues) | 07 (prov monkey-patches) | Code improvement recommendations: hardcoded paths in `prov`, monkey-patching, `documenter` prototype issues, `llm server` fallback behavior, inline mode inconsistency, `agent kb` missing require. |

### Docs Missing from Proposed Structure

The proposed structure does NOT include:
1. **Python integration** — Recommend adding `doc/Agent/Python.md` or a section
   in `Agent/Agent.md`. Source: existing `PythonAgentTasks.md`.
2. **Getting Started / Installation** — Recommend a section in `Overview.md`
   or a standalone `doc/GettingStarted.md`. Source: existing `USER_GUIDE.md` §2.
3. **Model subsystem** — Tangential. Keep `doc/Model.md` as-is or move to
   `doc/Model/` separately. Do NOT merge into this structure.

---

## 5. Information from Existing Docs to Preserve

### From `doc/USER_GUIDE.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| §1 "What Scout-AI is" (conceptual overview) | ✅ Covered in 00, 09 | Rewrite for `Overview.md` |
| §2 Installation (Gemfile, bundle install) | ❌ NOT in artifacts | **PRESERVE** → `Overview.md` or `GettingStarted.md` |
| §3 Endpoint setup walkthrough | ❌ NOT in artifacts | **PRESERVE** → `Backends/Backends.md` |
| §4 Chat file tutorial | ✅ Covered in 01 | Rewrite for `Chat/Chat.md` |
| §5 Agent tutorial | ✅ Covered in 03 | Rewrite for `Agent/Agent.md` |
| §6 Workflow tools tutorial | ✅ Covered in 06 | Rewrite for `Tools/WorkflowTools.md` |
| §7 Multi-agent patterns | ✅ Covered in 08 | Rewrite for `Agent/MultiAgentPatterns.md` |
| Step-by-step learning sequence | ❌ NOT in artifacts | **PRESERVE** → `README.md` (audience guide / reading path) |

### From `doc/Agent.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| §1–2 Quick start, factory shortcut | ✅ Covered in 03 | Rewrite for `Agent/Agent.md` |
| §3 DSL forwarding (`method_missing`) | ⚠️ Mentioned in 03 but not detailed | **PRESERVE** → `Agent/Agent.md` |
| §4 Tool wiring (merge rules) | ✅ Covered in 06 | Rewrite for `Agent/Agent.md` + `Tools/Tools.md` |
| §4.4 "Skills" vs Workflow distinction | ❌ NOT in artifacts | **PRESERVE** → `Overview.md` or `Agent/Agent.md` |
| §5 `ask` vs `chat` | ✅ Covered in 03 | Rewrite for `Agent/Agent.md` |
| §6 Structured outputs (`json`, `json_format`) | ❌ NOT deeply in artifacts | **PRESERVE** → `Agent/Agent.md` |
| §7 Iteration helpers (`iterate`, `iterate_dictionary`) | ⚠️ Partially in 03 | **PRESERVE** → `Agent/Agent.md` |
| §8 Delegation (basic example) | ✅ Covered in 03 | Rewrite for `Agent/Delegation.md` |
| §8.1 Socialized chats | ✅ Covered in 03, 04 | Rewrite for `Agent/Delegation.md` |
| §9 Agent loading / directory layout | ✅ Covered in 03 | Rewrite for `Agent/Agent.md` |
| §10 Workflow-provided `ask` task | ✅ Covered in 04 | Rewrite for `Agent/AgentWorkflow.md` |
| §11 Error handling (`process_exception`) | ❌ NOT in artifacts | **PRESERVE** → `Agent/Agent.md` |
| §12 CLI integration | ✅ Covered in 10 | Rewrite for `Commands/Commands.md` |

### From `doc/Chat.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| §0 Mental model (chat as conversation + control surface) | ✅ Covered in 01 | Rewrite for `Chat/Chat.md` |
| §1 Data model | ✅ Covered in 01 | Rewrite for `Chat/Chat.md` |
| Full role reference (all roles with syntax) | ✅ Covered in 01 | Rewrite for `Chat/Chat.md` |
| `option:` / `sticky_option:` behavior | ⚠️ Partially in 01 | **PRESERVE** details → `Chat/Chat.md` |

### From `doc/LLM.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| §1 Endpoint configuration (YAML examples) | ❌ NOT in artifacts | **PRESERVE** → `Backends/Backends.md` |
| §2 `LLM.ask` input types, option resolution | ✅ Covered in 05 | Rewrite for `Backends/Backends.md` |
| §2.3 Caching (`persist`) | ❌ NOT in artifacts | **PRESERVE** → `Chat/Persistence.md` or `Backends/Backends.md` |
| §3 Chat compilation (`LLM.chat`) | ✅ Covered in 01 | Reference `Chat/Chat.md` |
| §4 Backend list and options | ✅ Covered in 05 | Rewrite for `Backends/Backends.md` |
| §4.2 `previous_response_id` | ❌ NOT in artifacts | **PRESERVE** → `Backends/Backends.md` |
| §5 Tools and function calling | ✅ Covered in 06 | Rewrite for `Tools/Tools.md` |
| §6 Convenience helpers (`workflow_ask`, `knowledge_base_ask`) | ❌ NOT in artifacts | **PRESERVE** → `Tools/WorkflowTools.md` and `Tools/KnowledgeBase.md` |
| §7 CLI usage | ✅ Covered in 10 | Rewrite for `Commands/Commands.md` |
| §9 Minimal end-to-end example | ❌ NOT in artifacts | **PRESERVE** → `Overview.md` or `GettingStarted.md` |

### From `doc/RAG.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| `LLM::RAG.index` (HNSW index building) | ❌ NOT in artifacts | **PRESERVE** → `Tools/KnowledgeBase.md` |
| Embedding flow (`LLM.embed`) | ❌ NOT in artifacts | **PRESERVE** → `Tools/KnowledgeBase.md` |
| End-to-end RAG example | ❌ NOT in artifacts | **PRESERVE** → `Tools/KnowledgeBase.md` |

### From `doc/PythonAgentTasks.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| Python task auto-loading (`python/*.py`) | ❌ NOT in artifacts | **PRESERVE** → `Agent/Agent.md` (section) or new `Agent/Python.md` |
| `PythonWorkflow.load_directory` integration | ❌ NOT in artifacts | **PRESERVE** → same |
| When to use Python vs Ruby guidance | ❌ NOT in artifacts | **PRESERVE** → same |

### From `doc/Model.md`

| Content | Status in Artifacts | Action |
|---|---|---|
| Entire Model subsystem (ScoutModel, PythonModel, etc.) | ❌ NOT in artifacts | **OUT OF SCOPE** — keep as separate doc, do not merge |

---

## 6. Priority Order for Writing New Docs

### Phase 1: Foundation (write first — everything else references these)

| Priority | Doc | Rationale |
|---|---|---|
| 1 | `doc/Overview.md` | Sets the conceptual frame. All other docs are read in its context. Needs installation + setup from existing USER_GUIDE. |
| 2 | `doc/Chat/Chat.md` | The Chat data model is the foundation of everything. Must define roles, message types, and the processing pipeline before Agent/Tools/Backends can reference them. |
| 3 | `doc/README.md` | Entry point with TOC. Can only be written once the doc structure is populated. Write a draft now, finalize last. |

### Phase 2: Core Systems (depend on Chat)

| Priority | Doc | Rationale |
|---|---|---|
| 4 | `doc/Agent/Agent.md` | Central to the agent story. Depends on Chat.md for role definitions. Must preserve structured outputs, error handling, DSL forwarding from existing Agent.md. |
| 5 | `doc/Tools/Tools.md` | Tool definition and calling protocol. Depends on Chat.md for tool roles. Referenced by Backends, WorkflowTools, KB, MCP. |
| 6 | `doc/Backends/Backends.md` | Backend abstraction and inference loop. Depends on Tools.md (chain_tools) and Chat.md (prepare_prompt). Must preserve endpoint config from existing LLM.md. |

### Phase 3: Specialized Topics (depend on Agent + Tools)

| Priority | Doc | Rationale |
|---|---|---|
| 7 | `doc/Chat/PromptStrategies.md` | Focused topic. Depends on Chat.md and Backends.md (integration point). Must fix the threshold confusion. |
| 8 | `doc/Agent/Delegation.md` | Depends on Agent.md. Key differentiator for Scout-AI. |
| 9 | `doc/Agent/AgentWorkflow.md` | Depends on Agent.md and Delegation.md. The workflow bridge. |
| 10 | `doc/Chat/Persistence.md` | Depends on Chat.md. Provenance annotations bridge to Provenance.md. |
| 11 | `doc/Tools/WorkflowTools.md` | Depends on Tools.md. Straightforward extraction from artifact 06. |
| 12 | `doc/Tools/KnowledgeBase.md` | Depends on Tools.md. Must merge existing RAG.md content. |
| 13 | `doc/Tools/MCP.md` | Depends on Tools.md. Shortest doc, can be written quickly. |

### Phase 4: Patterns and Provenance (depend on multiple core docs)

| Priority | Doc | Rationale |
|---|---|---|
| 14 | `doc/Agent/MultiAgentPatterns.md` | Depends on Agent.md, Delegation.md, AgentWorkflow.md. Synthesizes artifact 08. |
| 15 | `doc/Provenance/Provenance.md` | Depends on Chat/Persistence.md, AgentWorkflow.md. Covers artifact 07 + command details. |

### Phase 5: Reference and Meta (write last)

| Priority | Doc | Rationale |
|---|---|---|
| 16 | `doc/Commands/Commands.md` | Reference doc. Best written last when all concepts are defined. Concise entries with links to detail docs. |
| 17 | `doc/Improvements.md` | Meta doc. Synthesize issues found across all artifacts. Source from 09 (recommendations) and 10 (command issues). |
| 18 | `doc/README.md` (finalize) | Finalize TOC, reading paths, and cross-references now that all docs exist. |

### Summary Priority Order

```
1.  Overview.md
2.  Chat/Chat.md
3.  Agent/Agent.md
4.  Tools/Tools.md
5.  Backends/Backends.md
6.  Chat/PromptStrategies.md
7.  Agent/Delegation.md
8.  Agent/AgentWorkflow.md
9.  Chat/Persistence.md
10. Tools/WorkflowTools.md
11. Tools/KnowledgeBase.md
12. Tools/MCP.md
13. Agent/MultiAgentPatterns.md
14. Provenance/Provenance.md
15. Commands/Commands.md
16. Improvements.md
17. README.md (finalize)
```

**Parallelization opportunity:** Docs 10–12 (WorkflowTools, KnowledgeBase, MCP)
can be written in parallel once Tools.md (priority 4) is complete. Similarly,
docs 6–8 (PromptStrategies, Delegation, AgentWorkflow) can be parallelized once
Agent.md (priority 3) and Backends.md (priority 5) are complete.

---

## Appendix: Artifact Quality Assessment

| Artifact | Completeness | Code-Verified | Ready for Doc Writing |
|---|---|---|---|
| 00 (Scope) | ✅ Full | N/A (meta) | ✅ Yes |
| 01 (Chat Core) | ✅ Full | ✅ Yes | ✅ Yes |
| 02 (Prompt Strategies) | ✅ Full | ✅ Yes | ✅ Yes (fix threshold naming) |
| 03 (Agent & Delegation) | ✅ Full | ✅ Yes | ✅ Yes |
| 04 (AgentWorkflow) | ✅ Full | ✅ Yes | ✅ Yes |
| 05 (Backends) | ✅ Full | ✅ Yes | ✅ Yes |
| 06 (Tools System) | ✅ Full | ✅ Yes | ✅ Yes |
| 07 (Provenance) | ✅ Full | ✅ Yes | ✅ Yes |
| 08 (Multi-Agent Patterns) | ✅ Full | ✅ Yes | ✅ Yes |
| 09 (Coding Philosophy) | ✅ Full | ✅ Yes | ✅ Yes |
| 10 (Commands) | ✅ Full | ✅ Yes | ✅ Yes |

All 10 research artifacts are complete and code-verified. No re-investigation
is needed before writing documentation. The main work is synthesis, gap-filling
(from existing docs), and ensuring consistent terminology.
