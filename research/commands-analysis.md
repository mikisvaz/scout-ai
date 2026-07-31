> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# CLI Commands: LLM / Agent / Chat System

> **Scope:** Every command under `scout_commands/` that relates to the
> LLM, agent, chat, or MCP system. Each command is documented for purpose,
> arguments/options, usage examples, library APIs called, and an assessment
> of its currency (current vs. deprecated/outdated).

---

## Command Inventory (Quick-Reference Table)

| Command | Path | Purpose | Last Commit | Status |
|---|---|---|---|---|
| `scout-ai llm ask` | `scout_commands/llm/ask` | Ask an LLM a single question (with file/chat/template support) | 2026-05-19 | ✅ Current |
| `scout-ai llm info` | `scout_commands/llm/info` | Inspect chat provenance graph, jobs, tokens, flow visualization | 2026-07-20 | ✅ Current (recommended) |
| `scout-ai llm prov` | `scout_commands/llm/prov` | Print hierarchical provenance tree with token totals | 2026-07-30 | ⚠️ Superseded by `info` |
| `scout-ai llm json` | `scout_commands/llm/json` | Convert between JSON and Chat format | 2026-03-23 | ✅ Current |
| `scout-ai llm md` | `scout_commands/llm/md` | Format a chat as Markdown (user/assistant turns) | 2026-07-15 | ✅ Current |
| `scout-ai llm word` | `scout_commands/llm/word` | Convert chat to `.docx` via pandoc with custom styles | 2026-07-07 | ✅ Current |
| `scout-ai llm template` | `scout_commands/llm/template` | List available question templates | 2025-01-29 | ✅ Current (simple) |
| `scout-ai llm process` | `scout_commands/llm/process` | Batch-process JSON question files from a directory queue | 2025-10-28 | ⚠️ Legacy queue processor |
| `scout-ai llm process_queries` | `scout_commands/llm/process_queries` | Batch-process JSON message+option files from a directory queue | 2026-04-22 | ⚠️ Legacy queue processor |
| `scout-ai llm server` | `scout_commands/llm/server` | Sinatra web server for the offline chat notebook UI | 2025-08-20 | ✅ Current |
| `scout-ai agent ask` | `scout_commands/agent/ask` | Ask a named LLM agent (full agent loop with tools) | 2026-07-19 | ✅ Current |
| `scout-ai agent find` | `scout_commands/agent/find` | Resolve and print the path of a named agent | 2026-03-23 | ✅ Current |
| `scout-ai agent kb` | `scout_commands/agent/kb` | Launch the Scout KB browser scoped to an agent's KB | 2025-03-26 | ✅ Current (thin wrapper) |
| `scout-ai workflow mcp` | `scout_commands/workflow/mcp` | Expose a workflow as an MCP (Model Context Protocol) service | 2026-03-26 | ✅ Current |
| `scout-ai documenter` | `scout_commands/documenter` | Auto-generate documentation for a library topic using an LLM agent | 2025-08-04 | ⚠️ Early prototype |

---

## Per-Command Detailed Documentation

---

### 1. `scout-ai llm ask`

**File:** `scout_commands/llm/ask`

**Purpose:** Ask an LLM model a question. Supports context injection from
STDIN or files, template-based prompting, multi-turn conversations (via chat
files), inline question answering in source files, and workflow tool
attachment.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `[<question>]` | positional (string) | The question text. Combined from `ARGV * " "`. |
| `-t, --template*` | string | Use a template (file path, or name from `Scout.questions` / `Scout.chats`). Template may contain `???` placeholder for the question. |
| `-c, --chat*` | string (path) | Follow a conversation file. Appends response to the file. |
| `-i, --imports*` | string (comma-separated) | Chat files to import into the conversation. |
| `-in, --inline*` | string (path) | Process inline `# ask:` comments in the given file, inserting responses. |
| `-f, --file*` | string (path) | Incorporate file content at the start of the question (wrapped in `<file>` tag). |
| `-w, --workflow*` | string | Add a workflow as a tool available to the LLM. |
| `-m, --model*` | string | Model to use (overrides endpoint config). |
| `-e, --endpoint*` | string | Endpoint to use (looks up `Scout.etc.AI[endpoint].yaml`). |
| `-b, --backend*` | string | Backend to use (`openai`, `anthropic`, `responses`, `ollama`). |
| `-d, --dry_run` | flag | Print the conversation without calling the LLM. |

**Usage Examples:**

```bash
# Simple question
scout-ai llm ask "What is the capital of France?"

# Ask with a file for context
scout-ai llm ask -f report.txt "Summarize this report"

# Use STDIN with '...' placeholder
echo "Some context" | scout-ai llm ask "Based on this: ..., explain X"

# Multi-turn conversation
scout-ai llm ask -c conversation.chat "Follow up question"

# Use a template
scout-ai llm ask -t code_review "src/app.rb"

# Inline questions in a file (processes # ask: comments)
scout-ai llm ask --inline source.rb

# Dry run (preview the prompt)
scout-ai llm ask -d -f data.json "Analyze this data"
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.chat(question)` | `lib/scout/llm/chat.rb:27` |
| `LLM.ask(conversation, options)` | `lib/scout/llm/ask.rb:12` |
| `LLM.options(conversation)` | `lib/scout/llm/chat/process/options.rb:20` |
| `LLM.print(messages)` | `lib/scout/llm/chat/parse.rb:143` |
| `LLM.purge(messages)` | `lib/scout/llm/chat/process/clear.rb:42` |
| `Chat.setup([])` | `lib/scout/llm/chat.rb` |
| `Scout.questions[template]` | Scout Path API |
| `Scout.chats[template]`, `Scout.chats.system[template]` | Scout Path API |

**Context Injection Logic:**
1. If the question contains `...`, replaces it with STDIN (or file content).
2. If `--file` is given (without `...`), prepends file content wrapped in
   `<file basename=...>[[[ ... ]]]</file>`.
3. Template resolution order: filesystem path → `Scout.questions` →
   `Scout.chats.system` → `Scout.chats`. If template contains `???`,
   substitutes the question; otherwise appends as `user:` turn.

**Notes:**
- When using `--inline`, the command scans the file for `# ask: ...` comment
  blocks, sends each to the LLM, and inserts responses between `# Response
  start` / `# Response end` markers.
- The `--chat` mode loads existing conversation, appends the new question,
  calls `LLM.ask`, and appends both user message and response to the file.
- Uses `$0` renaming for display via `$previous_commands`.

---

### 2. `scout-ai llm info`

**File:** `scout_commands/llm/info`

**Purpose:** Inspect the chat, jobs, agent logs, and token trace behind a
Scout-AI chat. Discovers the full provenance graph (imports, job results,
dependencies, agent logs), reports token usage, and optionally produces a
provenance flow diagram (text, Graphviz DOT, or rendered SVG/PNG/PDF).

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<chat>` | positional (string) | Chat file to inspect. Also accepted via `-c`. |
| `-c, --chat*` | string | Chat file to inspect (same as positional). |
| `-f, --flow` | flag | Print a compact provenance flow (numbered nodes + edges). |
| `--dot*` | string (path) | Write the flow as Graphviz DOT to the given file. |
| `--plot*` | string (path) | Render the flow as SVG, PNG, or PDF (requires `dot` CLI). |

**Usage Examples:**

```bash
# Basic inspection (chats, jobs, tokens, warnings)
scout-ai llm info conversation.chat

# Compact flow view
scout-ai llm info -f conversation.chat

# Generate DOT file
scout-ai llm info --dot flow.dot conversation.chat

# Render to PDF
scout-ai llm info --plot flow.pdf conversation.chat
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Chat.load(path)` | `lib/scout/llm/chat/process/meta.rb` |
| `Chat.trace_chats(chats)` | `lib/scout/llm/chat/process/meta.rb` |
| `Chat.find_file(content, path)` | `lib/scout/llm/chat/process/files.rb` |
| `chat.role_messages(role)` | `lib/scout/llm/chat/annotation.rb` |
| `chat.jobs` / `chat.job_paths` | `lib/scout/llm/chat/process/meta.rb` |
| `Step.load(path)` | Scout Step API |
| `job.dependencies`, `job.done?`, `job.type` | Scout Step API |
| `job.file('log')` | Scout Step API |
| `job.info[:workflow]`, `job.info[:task_name]` | Scout Step API |
| `Scout.chats[input].find` | Scout Path API |

**Key Design Features:**
- **No monkey-patching** — uses library APIs directly (unlike `prov`).
- **Job deduplication** — canonical identity by `[workflow, task, basename]`
  so `~/.scout` and `~/.rbbt` mirrors of the same job appear once.
- **Import discovery** — follows `import`/`continue`/`last` role messages.
- **Token accounting** — sums `pt`/`ct`/`tt` from direct inference entries
  only (entries without `:job` key), matching `Backend::Default#update_meta`.
- **Flow visualization** — nodes (chat/agent/job), edges (import/result/
  dependency/log), token annotations, Graphviz shapes/colors per type.
- **Warnings** — records and reports load failures gracefully.

**Output Format (default):**

```
Chats
=====
~/.scout/var/.../conversation.chat
  messages=15 user=5 assistant=5 meta=5
  jobs=~/.scout/var/jobs/.../ask

Jobs
====
~/.scout/var/jobs/.../ask
  Agent/Worker/ask
  logs=3 dependencies=2

Token usage
-----------
Root chat: prompt=1500 completion=800 total=2300
All traced chats: prompt=5000 completion=3000 total=8000
Trace records: 45
```

**Flow Output (with `-f`):**

```
Flow
====
[ 1] Job   Agent/Worker/ask                    2.3k a1b2c3d4
[ 2] Chat  conversation                        1.5k e5f6g7h8

[ 1] --result     --> [ 2]
```

**Assessment:** ✅ **Current and well-maintained.** This is the recommended
command for provenance inspection. It does NOT use monkey-patching, correctly
references all current library APIs, and was last updated 2026-07-20. Artifact
07's assessment that `info` is NOT outdated is **confirmed**.

---

### 3. `scout-ai llm prov`

**File:** `scout_commands/llm/prov`

**Purpose:** Examine the provenance of a chat. Prints a hierarchical, indented
tree showing jobs, agent logs, and dependencies with token totals at each node.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<filename>` | positional (string) | Chat file or job path to examine. |
| `-h, --help` | flag | Print help. |

**Usage Examples:**

```bash
scout-ai llm prov conversation.chat
```

**Library APIs Called:**

| API | Source File | Note |
|---|---|---|
| `LLM.chat(filename)` | `lib/scout/llm/chat.rb` | ✅ Direct call |
| `Step.load(job)` | Scout Step API | ✅ Direct call |
| `Chat.trace_chats` | `lib/scout/llm/chat/process/meta.rb` | ⚠️ **Redefined** via monkey-patch |
| `Chat.token_totals` | (library) | ⚠️ **Redefined** via monkey-patch |
| `Chat.provenance` | — | ⚠️ **New** monkey-patch (not in library) |
| `Chat.provenance_chat_files` | — | ⚠️ **New** monkey-patch |
| `Chat.tokens` | — | ⚠️ **New** monkey-patch |
| `Chat.job_agent_chat_files` | `lib/scout/llm/chat/process/meta.rb` | ⚠️ **Redefined** via monkey-patch |
| `Step#agent_chats` | — | ⚠️ **New** monkey-patch |

**Output Format:**

```
job   total=1.2k prompt=800 cont=400 ~/.scout/var/jobs/.../ask
  chat   total=500 prompt=300 cont=200  agent.chat
  job   total=700 prompt=500 cont=200 ~/.scout/var/jobs/.../subtask
```

**Assessment:** ⚠️ **Superseded by `info`.** Still functional, but:
- Relies on runtime monkey-patches that redefine library methods.
- No import discovery.
- No job deduplication (`~/.scout` and `~/.rbbt` mirrors appear twice).
- No flow visualization or DOT/plot output.
- No JSON/machine-readable output.
- **Hardcoded fallback path:** `~/git/workflows/SC26/chats/network_usecase/3.1.themes`
  (line: `filename ||= "~/git/workflows/SC26/chats/network_usecase/3.1.themes"`).

---

### 4. `scout-ai llm json`

**File:** `scout_commands/llm/json`

**Purpose:** Translate chats to and from JSON format. Reads a file as either
JSON or Chat format and outputs the opposite format.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<filename>` | positional (string) | Input file to convert. |
| `-c, --chat` | flag | Load input as Chat format (output will be JSON). |
| `-j, --json` | flag | Load input as JSON format (output will be Chat). **Default.** |
| `-o, --output*` | string (path) | Save to file instead of printing to STDOUT. |

**Usage Examples:**

```bash
# Convert JSON chat to Chat format
scout-ai llm json -j input.json

# Convert Chat format to JSON
scout-ai llm json -c conversation.chat

# Save to file
scout-ai llm json -c conversation.chat -o output.json
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.chat(filename)` | `lib/scout/llm/chat.rb` |
| `LLM.print(messages)` | `lib/scout/llm/chat/parse.rb` |
| `Chat.setup(json_hash)` | `lib/scout/llm/chat.rb` |
| `Open.json(filename)` | Scout Open API |

**Assessment:** ✅ **Current.** Simple, straightforward converter. Note: using
both `-c` and `-j` simultaneously raises a `ParameterException`.

---

### 5. `scout-ai llm md`

**File:** `scout_commands/llm/md`

**Purpose:** Format a chat file as Markdown with emoji headers for user and
assistant turns.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<chat>` | positional (string) | Chat file to format. |
| `<markdown>` | positional (string, optional) | Output Markdown file path. If omitted, prints to STDOUT. |
| `-l, --last` | flag | Format only the last user/assistant interaction. |

**Usage Examples:**

```bash
# Print to stdout
scout-ai llm md conversation.chat

# Save to file
scout-ai llm md conversation.chat output.md

# Only the last exchange
scout-ai llm md -l conversation.chat output.md
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Chat.parse(text)` | `lib/scout/llm/chat/parse.rb` |
| `Open.read(chat)` | Scout Open API |

**Output Format:**

```markdown
---
# 👤 User
---

What is Ruby?

---
# 🤖 Assistant
---

Ruby is a dynamic, object-oriented programming language...
```

**Assessment:** ✅ **Current.** Clean, simple formatter. Filters only `user`
and `assistant` roles; ignores `system`, `tool`, `meta`, etc.

---

### 6. `scout-ai llm word`

**File:** `scout_commands/llm/word`

**Purpose:** Convert a chat file to a Word `.docx` document using pandoc,
with custom paragraph styles for user blocks.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<chat>` | positional (string) | Chat file to convert. |
| `<word>` | positional (string, optional) | Output `.docx` path. Defaults to `<chat>.docx`. |
| `-r, --reference*` | string (path) | Custom `reference.docx` for pandoc styling. Defaults to `Scout.share.word["reference.docx"]`. |
| `-l, --last` | flag | Format only the last user/assistant interaction. |

**Usage Examples:**

```bash
# Basic conversion
scout-ai llm word conversation.chat

# Specify output file
scout-ai llm word conversation.chat report.docx

# Use custom reference doc
scout-ai llm word -r my-reference.docx conversation.chat report.docx
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Chat.parse(text)` | `lib/scout/llm/chat/parse.rb` |
| `Scout.share.word["reference.docx"]` | Scout Path API |
| `CMD.cmd(:pandoc, ...)` | Scout CMD API |
| `TmpFile.with_file(...)` | Scout TmpFile API |

**Notes:**
- Requires the `pandoc` CLI to be installed.
- User messages are wrapped in `::: {custom-style="UserBlock"}` blocks.
- Assistant messages are output as-is (no wrapper).

**Assessment:** ✅ **Current.** External dependency: pandoc.

---

### 7. `scout-ai llm template`

**File:** `scout_commands/llm/template`

**Purpose:** List all available question templates.

**Arguments:** None beyond `--help`.

**Usage Examples:**

```bash
scout-ai llm template
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Scout.questions.glob_all("*")` | Scout Path API |

**Assessment:** ✅ **Current.** Minimal one-liner command. Lists all files
found under the `Scout.questions` path collection.

---

### 8. `scout-ai llm process`

**File:** `scout_commands/llm/process`

**Purpose:** Batch-process JSON question files from a directory queue.
Continuously polls a directory for `*.json` files, each containing
`{"question": "...", "model": "...", ...}`, sends each to the LLM, writes
the reply to `<directory>/reply/<id>.json`, and removes the input file.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `[<directory>]` | positional (string) | Directory to poll. Defaults to `Scout.var.ask`. |

**Usage Examples:**

```bash
# Start processing from default directory
scout-ai llm process

# Process from a specific queue directory
scout-ai llm process /path/to/queue
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.ask(question, options)` | `lib/scout/llm/ask.rb` |
| `Scout.var.ask` | Scout Path API |
| `require 'scout/llm/backends/relay'` | Backend relay module |

**Assessment:** ⚠️ **Legacy queue processor.** This is an older pattern for
asynchronous LLM processing. The `require 'scout/llm/backends/relay'`
suggests it was designed for a relay/backend model. The infinite loop with
`sleep 1` makes it a daemon-like process. Still functional but represents an
earlier architecture. Last meaningful update: 2025-10-28.

---

### 9. `scout-ai llm process_queries`

**File:** `scout_commands/llm/process_queries`

**Purpose:** Similar to `process` but handles files containing `[messages,
options]` tuples (an array of two elements) rather than `{"question":
"..."}`. Processes each query by calling `LLM.ask(messages, options.merge(process:
id))`.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `[<directory>]` | positional (string) | Directory to poll. Defaults to `Scout.var.query`. |

**Usage Examples:**

```bash
scout-ai llm process_queries /path/to/queue
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.ask(messages, options)` | `lib/scout/llm/ask.rb` |
| `Scout.var.query` | Scout Path API |
| `require 'scout/llm/backends/relay'` | Backend relay module |

**Assessment:** ⚠️ **Legacy queue processor.** A variant of `process` with a
different JSON schema (`[messages, options]` vs. `{question:, ...}`). More
recently updated (2026-04-22) but still represents the queue-based async
processing pattern. The `process: id` option suggests it registers the
processing ID with the backend.

---

### 10. `scout-ai llm server`

**File:** `scout_commands/llm/server`

**Purpose:** A Sinatra-based web server that provides a chat notebook UI for
browsing, editing, and running chat files stored under `./chats`. Serves an
embedded HTML/JS frontend and provides REST API endpoints for file management
and LLM execution.

**Configuration:**

| Env Var | Default | Description |
|---|---|---|
| `SCOUT_BIND` | `127.0.0.1` | Bind address. |
| `SCOUT_PORT` | `4567` | Port number. |

**API Endpoints:**

| Method | Route | Description |
|---|---|---|
| GET | `/` | Serve the chat HTML UI (`share/server/chat.html`). |
| GET | `/chat.js` | Serve the client JavaScript (`share/server/chat.js`). |
| GET | `/list` | List all files under `./chats` (excludes dotfiles). |
| GET | `/load?path=<rel>` | Load a chat file's content. |
| POST | `/save` | Save a chat file. Body: `{path, content}`. |
| POST | `/run` | Run a chat through the LLM. Body: `{path, content?, convo_options?, options?}`. |
| GET | `/ping` | Health check. |

**Usage Examples:**

```bash
# Start server in a directory with a chats/ subdirectory
mkdir -p chats
scout-ai llm server

# Custom bind/port
SCOUT_BIND=0.0.0.0 SCOUT_PORT=8080 scout-ai llm server
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.chat(file_text)` / `LLM.chat(full)` | `lib/scout/llm/chat.rb` |
| `LLM.ask(conversation, options)` | `lib/scout/llm/ask.rb` |
| `LLM.print(messages)` | `lib/scout/llm/chat/parse.rb` |
| `Scout.share['server']['chat.html']` | Scout Path API |
| `Scout.share['server']['chat.js']` | Scout Path API |

**Security Features:**
- Path sanitization: strips leading slashes, rejects `..` traversal, ensures
  resolved path is inside `CHATS_DIR`.
- Dotfile filtering: hides files/directories with path segments starting with `.`.

**Assessment:** ✅ **Current.** A functional web UI backend. Has a fallback
simulated reply if LLM is not available. Error responses include diagnostics
(backtrace, conversation preview). External dependency: `sinatra`.

---

### 11. `scout-ai agent ask`

**File:** `scout_commands/agent/ask`

**Purpose:** Ask a named LLM agent. Unlike `llm ask` which does a single LLM
call, this loads a full agent (with system prompt, tools, workflows,
knowledge base) and runs the agent loop.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<agent_name>` | positional (string) | Name of the agent to load (resolved by `LLM::Agent.load_agent`). |
| `[question]` | positional (string) | The question text. Combined from remaining `ARGV`. |
| `-l, --log*` | integer | Log level. |
| `-t, --template*` | string | Use a template (same logic as `llm ask`). |
| `-c, --chat*` | string (path) | Follow a conversation file. |
| `-m, --model*` | string | Model to use. |
| `-e, --endpoint*` | string | Endpoint to use. |
| `-f, --file*` | string (path) | Incorporate file content. |
| `-w, --workflow*` | string | Add an additional workflow as a tool. |
| `-wt, --workflow_tasks*` | string | Export specific tasks from the workflow to the agent. |
| `-i, --imports*` | string (comma-separated) | Chat files to import. |

**Usage Examples:**

```bash
# Ask the AGI agent
scout-ai agent ask AGI "Analyze this codebase"

# Ask with a conversation file
scout-ai agent ask -c session.chat Worker "Process this data"

# Ask with a file for context
scout-ai agent ask -f input.txt Searcher "Find relevant information"

# Specify model/endpoint
scout-ai agent ask -m gpt-4o -e production AGI "Complex task"
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM::Agent.load_agent(agent_name)` | `lib/scout/llm/agent.rb:152` |
| `agent.start(chat)` | `lib/scout/llm/agent.rb` |
| `agent.ask(chat, options)` | `lib/scout/llm/agent.rb` |
| `agent.current_chat` | `lib/scout/llm/agent.rb` |
| `agent.import(file)` | `lib/scout/llm/agent.rb` |
| `agent.chat` | `lib/scout/llm/agent.rb` |
| `LLM.chat(question)` | `lib/scout/llm/chat.rb` |
| `LLM.options(conversation)` | `lib/scout/llm/chat/process/options.rb` |
| `LLM.print(messages)` | `lib/scout/llm/chat/parse.rb` |
| `LLM.purge(messages)` | `lib/scout/llm/chat/process/clear.rb` |
| `LLM.tag('file', file, name)` | `lib/scout/llm/chat/process/files.rb` |
| `Scout.questions`, `Scout.chats` | Scout Path API |

**Key Differences from `llm ask`:**
- Uses `LLM::Agent.load_agent` to load a full agent definition (system prompt,
  tools, workflow, KB).
- The agent manages its own chat loop (multi-turn with tool calls).
- Sets `agent.other_options[:endpoint]` and `[:model]` for override.
- The inline mode uses `LLM.tag` (not `Chat.tag`) for file references.
- The default (no chat, no inline) mode calls `agent.chat` which runs the full
  agent loop and prints the final conversation.

**Assessment:** ✅ **Current.** Last updated 2026-07-19 (fixed bug with
endpoint/model options). Well-maintained and the primary entry point for
agent-based interactions.

---

### 12. `scout-ai agent find`

**File:** `scout_commands/agent/find`

**Purpose:** Find (resolve) an agent by name and print its path.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<agent_name>` | positional (string) | Name of the agent to find. |

**Usage Examples:**

```bash
scout-ai agent find AGI
# Output: ~/.scout/var/Agent/AGI (or wherever the agent is defined)
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM.load_agent(agent_name, options)` | `lib/scout/llm/agent.rb:8` (delegates to `LLM::Agent.load_agent`) |

**Assessment:** ✅ **Current.** Simple utility for resolving agent paths.

---

### 13. `scout-ai agent kb`

**File:** `scout_commands/agent/kb`

**Purpose:** Launch the Scout knowledge base browser, scoped to a specific
agent's KB directory. This is a thin wrapper that delegates to the main
`scout kb` command.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<agent>` | positional (string) | Agent name. The KB is resolved from `Scout.var.Agent[agent].knowledge_base`. |
| `[args...]` | remaining args | Passed through to the `scout kb` command. |

**Usage Examples:**

```bash
# Open KB browser for AGI agent's knowledge base
scout-ai agent kb AGI
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Scout.var.Agent[agent]` | Scout Path API |
| `Scout.bin.scout.find` | Scout Path API (loads the main scout binary) |

**How It Works:**
1. Resolves `agent_dir = Scout.var.Agent[agent]`.
2. If additional arguments are given, appends `--knowledge_base`, the KB path,
   and the current log level to `ARGV`.
3. Prepends `kb` to `ARGV`.
4. Loads and executes the main `scout` binary (delegation pattern).

**Assessment:** ✅ **Current.** Thin wrapper using Scout's standard delegation
pattern (`load Scout.bin.scout.find`).

---

### 14. `scout-ai workflow mcp`

**File:** `scout_commands/workflow/mcp`

**Purpose:** Run a Scout workflow as an MCP (Model Context Protocol) service
over stdio. This exposes workflow tasks as MCP tools that can be called by
MCP-compatible clients (e.g., Claude Desktop, other MCP consumers).

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<workflow>` | positional (string) | Name of the workflow to export. |
| `[task_name]*` | positional (string, repeatable) | Specific tasks to export. If none given, exports explicitly exported tasks. If no tasks are explicitly exported, exports all tasks. |

**Usage Examples:**

```bash
# Export a workflow as MCP (all tasks)
scout-ai workflow mcp MyWorkflow

# Export specific tasks only
scout-ai workflow mcp MyWorkflow task1 task2
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `Workflow.require_workflow(name)` | Scout Workflow API |
| `workflow.mcp_stdio(*task_names)` | `lib/scout/llm/mcp.rb:30` |

**How It Works:**
1. Requires the named workflow (loads its `workflow.rb`).
2. Calls `workflow.mcp_stdio(*task_names)` which starts an MCP server on stdio,
   exposing the selected tasks as MCP tools.

**Assessment:** ✅ **Current.** Integrates with the MCP standard for tool
exposure. Clean implementation delegating to the library's `mcp_stdio` method.

---

### 15. `scout-ai documenter`

**File:** `scout_commands/documenter`

**Purpose:** Automatically generate technical documentation for a Scout
library topic by analyzing Ruby source files and their corresponding test
files using an LLM agent.

**Arguments:**

| Argument/Option | Type | Description |
|---|---|---|
| `<topic>` | positional (string) | The topic name (e.g., `chat`, `agent`, `llm`). |

**Usage Examples:**

```bash
scout-ai documenter chat
scout-ai documenter agent
```

**Library APIs Called:**

| API | Source File |
|---|---|
| `LLM::Agent.new` | `lib/scout/llm/agent.rb` |
| `documenter.start_chat.system(...)` | Agent chat API |
| `documenter.start_chat.file(...)` | Agent chat API |
| `documenter.start_chat.user(...)` | Agent chat API |
| `documenter.start` | Agent API |
| `documenter.file(...)` | Agent API |
| `documenter.respond` | Agent API |
| `documenter.user(...)` | Agent API |
| `documenter.chat` | Agent API |
| `Scout.lib.scout.glob(...)` | Scout Path API |
| `Scout.scout_commands.glob(...)` | Scout Path API |
| `Scout.doc.lib.scout[topic + '.md']` | Scout Path API (output location) |

**How It Works:**
1. Locates source files matching `lib/scout/<topic>*` and corresponding test
   files (via `source_to_test` substitution `./lib/` → `./test/`).
2. Creates an `LLM::Agent` with a documentation-author system prompt.
3. Feeds the main source + test file and asks for initial documentation.
4. For each subtopic, feeds the subtopic's source + test files and asks for
   subtopic documentation.
5. Aggregates all subtopic docs and asks the agent to produce a comprehensive
   main documentation.
6. Revises each subtopic doc in light of the main documentation.
7. Writes outputs to `Scout.doc.lib.scout[topic + '.md']` and
   `Scout.doc.lib.scout[topic][subtopic + '.md']`.

**Assessment:** ⚠️ **Early prototype.** Last updated 2025-08-04 ("first
version"). The two-pass approach (generate → aggregate → revise) is
interesting but:
- No options for output directory, model selection, or dry-run.
- Assumes a fixed file layout (`lib/scout/<topic>*` and `test/` mirroring).
- Relies on `LLM::Agent` API that may have evolved since.
- No error handling for missing source files.
- The system prompt is hardcoded in the script.

---

## Summary: Current vs. Deprecated/Outdated

### ✅ Current and Recommended

| Command | Notes |
|---|---|
| `llm ask` | Primary LLM question command. Well-maintained. |
| `llm info` | **Recommended** provenance inspector. No monkey-patching, full feature set. |
| `llm json` | Simple format converter. |
| `llm md` | Chat → Markdown formatter. |
| `llm word` | Chat → Word converter (requires pandoc). |
| `llm template` | Lists templates. |
| `llm server` | Web UI backend (requires sinatra). |
| `agent ask` | Primary agent interaction command. |
| `agent find` | Agent path resolver. |
| `agent kb` | Agent KB browser wrapper. |
| `workflow mcp` | MCP service exporter. |

### ⚠️ Superseded or Legacy

| Command | Issue |
|---|---|
| `llm prov` | **Superseded by `llm info`.** Uses monkey-patches, lacks imports/dedup/flow. Has hardcoded fallback path. |
| `llm process` | Legacy queue-based async processor. Older architecture. |
| `llm process_queries` | Legacy queue-based async processor (variant schema). |
| `documenter` | Early prototype (2025-08-04, "first version"). No options, no error handling. |

---

## Issues Found

### 1. Hardcoded Path in `llm prov`

**File:** `scout_commands/llm/prov`, near the end:

```ruby
filename ||= "~/git/workflows/SC26/chats/network_usecase/3.1.themes"
```

This is a developer-specific fallback path that will be confusing or broken
for other users. Should be removed or changed to raise an error if no filename
is provided.

### 2. Monkey-Patching in `llm prov`

The `prov` command redefines `Chat.trace_chats`, `Chat.token_totals`,
`Chat.job_agent_chat_files`, and adds `Chat.provenance`,
`Chat.provenance_chat_files`, `Chat.tokens`, and `Step#agent_chats` at
runtime. This diverges from the library API and creates maintenance risk.
The `info` command achieves the same results without monkey-patching.

### 3. `llm process` and `process_queries` Use Relay Backend

Both commands explicitly `require 'scout/llm/backends/relay'`. This backend
may not be the standard path for current LLM operations. The infinite-loop
daemon pattern is dated compared to Scout's workflow-based job execution
model.

### 4. `documenter` Has No Options

The documenter command accepts only a topic positional argument. There is no
way to specify output directory, model, endpoint, agent configuration, or
dry-run mode. The system prompt and documentation strategy are entirely
hardcoded.

### 5. `documenter` Source-Test File Mapping

The `source_to_test` method assumes a rigid `./lib/` → `./test/` path mapping
with `test_` prefix on filenames. This will not work for all project
layouts.

### 6. `llm server` Fall-back Behavior

The `/run` endpoint falls back to a simulated reply (`"assistant: (simulated
reply)\n"`) when no LLM is defined. This could be confusing in production
use—users may not realize their LLM configuration is missing.

### 7. `agent ask` Inline Mode: `break if post.empty?` vs `break if question.empty?`

The `agent ask` inline mode uses `break if post.empty?` (checking the
remainder after the match), while `llm ask` uses `break if question.empty?`
(checking the matched question). This is a subtle behavioral difference that
could cause the last section of a file to be skipped in one but not the
other.

### 8. `agent kb` Lacks `require 'scout-ai'`

The `agent kb` command does not explicitly `require 'scout-ai'` at the top
(though it relies on `Scout.var.Agent`). It may work because the parent
`scout-ai` process already loaded the library, but this is an implicit
dependency.

---

## `info` vs. `prov`: Final Verdict

The research artifact 07 states that `info` is NOT outdated and is in fact
the more modern command. **This is confirmed.**

| Criterion | `info` | `prov` |
|---|---|---|
| Last meaningful update | 2026-07-20 | 2026-07-30 (but monkey-patches remain) |
| Uses library API directly | ✅ | ❌ (monkey-patches) |
| Import discovery | ✅ | ❌ |
| Job deduplication | ✅ | ❌ |
| Flow visualization (text) | ✅ (`-f`) | ❌ |
| Graphviz DOT/SVG/PNG/PDF | ✅ (`--dot`, `--plot`) | ❌ |
| Warnings on load failures | ✅ | ❌ |
| Hardcoded paths | ❌ (none) | ✅ (`~/git/workflows/SC26/...`) |
| Machine-readable output | Partial (DOT is text) | ❌ |

**Recommendation:** `info` should be documented as the primary provenance
command. `prov` should be marked as deprecated/superseded in user-facing
documentation, though it remains functional.
