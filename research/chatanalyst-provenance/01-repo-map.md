# Repository map: ChatAnalyst + Scout-AI provenance + chat/job storage

## ChatAnalyst workflow

- Directory: `/home/mvazque2/git/workflows/ChatAnalyst` (git `50e369b`, uncommitted modifications to `workflow.rb`, `README.md`, `start_chat`; staged new tests).
- `chats` symlink → `/home/mvazque2/chats/ChatAnalyst` (target dir currently does not exist/empty).
- `workflow.rb` (749 lines) — all tasks + helpers in one file.
  - **Helpers (lines ~9–120):** `short_path`, `short_address`, `resolve_root` (19–30: resolves chat path vs job path; `.info`/`.files` ⇒ job), `normalize_provenance_warning`, `warning_key`.
  - **`provenance_data(file)` helper (lines ~92–160)** — THE central collector. Calls, in order:
    1. `Chat.provenance_token_events(root, root_type:, warnings:, on_error:)`
    2. `Chat.provenance_edges(root, root_type:, on_error:)`
    3. `Chat.provenance_chat_files(root, root_type:, on_error:)` → loads every chat
    4. `Chat.provenance_jobs(root, root_type:, on_error:)`
    - No scoping option: always full closure. Memoized per `file` per process.
  - **Tasks:** `message_index` (paginated), `message_content`, `chat_overview` (edges + totals), `chat_tool_calls`, `chat_tokens` (dedup totals + events), `chat_agents`, `meta_evidence`, `chat_reasoning`, `chat_report`.
  - Every task input: `file` = "Root chat file or chat-producing job" only. **No `follow:` / scope inputs exist anywhere.**

## Scout-AI provenance core (`lib/scout/llm/chat/provenance.rb`, 715 lines)

- `PROVENANCE_RELATIONS = [:job, :dependency, :log, :result, :agent_job]`.
- `Chat.traverse_provenance(root, root_type:, follow:, on_error:, &block)` (~line 132):
  - BFS queue; `seen` set keyed by `provenance_key(kind, object)`.
  - chat node → `chat.jobs` references ⇒ `:job` edges (via `load_job_reference`);
    chat node → `agent_meta_job_references` ⇒ `:agent_job` edges;
    job node → `object.dependencies` ⇒ `:dependency`; job's `log` dir ⇒ `:log` chats; job result of type chat ⇒ `:result`.
  - **`follow:` option EXISTS in core** (line ~137: `follow == :all ? PROVENANCE_RELATIONS : Array(follow)`), but ChatAnalyst **never exposes it** — always defaults to `:all`.
  - Comment at lines ~152–156: "Imported and continued chats are a chat-compilation concern, not a provenance concern… Provenance traversal therefore never follows import, continue, or last references."
- `load_job_reference` (~59–75): resolves refs like `Planned/ask/Default_abc.chat` via `Step.load` with `~/.rbbt/var/jobs` fallback.
- `provenance_edges` (~271): dedups edges; `:agent_job` edges carry `detail:` = receipt record (call_id, tool_name, output/evidence addresses, job).
- `provenance_chat_files` / `provenance_jobs` (~297–308): first-visit collectors.
- `provenance_token_events` (~430): chat-side events from `trace_chat_sources(sources, false)` + receipt-side from `agent_meta_evidence`; identity grouping (`inference_id` → `provider_response_id` → `lineage` → `receipt`); canonical = first chat_meta evidence in discovery order.
- `provenance_token_totals` (~644): scopes `deduplicated_total / chat_evidence / receipt_evidence / receipt_only`.
- **Import handling:** import/continue/last are resolved in `Chat.parse` and inlined into the persisted chat file (per comment); traversal does NOT follow them. ⇒ The closure boundary follows `chat.jobs` references, `agent_meta` receipts, job deps, and job log dirs.

## Chat parsing / import semantics (scout-ai)

- `lib/scout/llm/chat/parse.rb` (to be verified for import inlining).
- Agent logs live in `job.files_dir/log/*.chat` (per workflow docs: "agent chat logs live in the `log` subdir of a job's files_dir").

## Storage layout (observed bind-mount paths from execution sandbox)

Jobs referenced by the chats live under `/bulk/mvazque2/rbbt/var/jobs/Planned/...` (= `~/.rbbt/var/jobs/Planned/...`):
- `ask/Default_3e2d45a63e170462ad77cbcbf4e07d71.chat` (+ `.files` + `.info`)
- `ask/Default_4574d35ff303912b7a4957761e559068.chat` (+ files/info)  ← the shared parent ask job
- `ask/Default_f1fda6bf9b75c2031a6abb5b3dc240c6.chat`
- `plan/Default_9529d8954a9f77e3225270d650f3c049.chat`
- `plan/Default_dbe07c55ba7e901ad6236082c0521459.chat`
- `plan/Default_f375a4eea58845f9888afc9fb7ff09ff.chat`
- `request/Default_395e25f752070b45e61461f0686eef3b.chat`
- `request/Default_6ad9e52a9a8118f853b0f74231ecd866.chat`
- `request/Default_73d4a24207c6d60389de626de7240ed7.chat`
- `search/Default_6e14e9a86d94c4e563b8a25146fc0bd6.chat`
- `work/Default_7b6f7d7ff8e292d86b9ccb168abffadd.chat`
- `work/Default_abb12d374a6eac6295af76b595168579.chat`
- `work/Default_c0fa69abdf19fbd120ed6c1e339b1fb6.chat`
- Note: job paths are shared globally under `~/.rbbt/var/jobs/Planned/` regardless of which repo's chat produced them.

## Sandbox note

The ComputerUse `bash` sandbox binds read-only most trees but the earlier `ls` of `~/git/scout-essentials/chats/` failed with ENOENT inside bwrap (mount issue with this specific bash call). Workaround: use `list_directory`/`read` tools or ruby/python with explicit `/bulk/...` realpaths.
