> **Disclaimer:** This is an architectural investigation, not normative
> documentation. It was produced during a documentation-revamp effort and may
> be outdated relative to the current codebase. Treat it as supporting
> reference material. For maintained documentation, see
> [../../doc/](../../doc/).
>


# Chat Core: Data Model, Roles, Persistence, and Processing Pipeline

This artifact documents the Chat subsystem in `lib/scout/llm/chat.rb` and its supporting files. It covers the class structure, message schema, roles, parsing, persistence, processing pipeline, and provenance annotations.

---

## Chat Class Structure

### What Chat is

`Chat` is **not a standalone class**. It is a **Ruby module** — `module Chat` — that appears in multiple files via Ruby's open-module mechanism:

- `lib/scout/llm/chat/annotation.rb` — `module Chat` (270 lines)
- `lib/scout/llm/chat/parse.rb` — `module Chat` (190 lines)
- `lib/scout/llm/chat/process.rb` — `module Chat` (17 lines)
- `lib/scout/llm/chat/process/*.rb` — each file opens `module Chat` and adds class methods

### The Annotation pattern (Array extension)

The key to understanding Chat is the **`extend Annotation`** line at the top of `annotation.rb`:

```ruby
module Chat
  extend Annotation
  # ...
end
```

`Annotation` is a mixin from `scout-essentials` (`lib/scout/annotation.rb`). When a module or class calls `extend Annotation`:

1. It includes `Annotation::AnnotatedObject` — provides `annotation_types`, `annotation_hash`, `purge`, `annotate`, etc.
2. It extends `Annotation::AnnotationModule` — provides the `.setup`, `.annotation`, and `.annotations` class methods.
3. When `Chat.setup(some_array)` is called, it **extends the Array instance with the `Chat` module**, so the Array gains all of Chat's instance methods (defined in `annotation.rb`) while remaining a plain Array.

This means:
- **A Chat IS an Array** of message hashes.
- All standard Array methods (`each`, `map`, `select`, `<<`, `push`, `reverse`, etc.) work on a Chat.
- Additional methods like `user()`, `assistant()`, `import()`, `ask()`, `save()`, etc. are available as instance methods.
- Calling `Chat.setup(messages)` annotates an Array, turning it into a Chat.

### The `LLM` module as factory

The top-level `LLM` module (in `chat.rb`) serves as the **factory/entry point**:

```ruby
module LLM
  def self.chat(file = [], original = nil)
    # ... parses, imports, clears, configures, processes files/tools
    Chat.setup messages
  end

  def self.messages(question, role = nil)
    # converts a string, Array of strings, or parsed messages
  end
end
```

Key factory methods on `LLM`:
| Method | Purpose |
|---|---|
| `LLM.chat(file_or_messages, original=nil)` | Main entry: parse → process → return Chat |
| `LLM.messages(question, role=nil)` | Convert string/Array into message hashes |
| `LLM.print(chat)` | Serialize a Chat back to text |
| `LLM.options(...)` / `LLM.tools(...)` / `LLM.associations(...)` | Delegate to Chat module methods |

---

## Message Hash Schema

Every message in a Chat is a **Hash** with two mandatory keys:

```ruby
{ role: String, content: String|Hash|Array|nil }
```

### Key: `:role` (String)

Always a string identifying the message type. See the Roles section below for the full list.

### Key: `:content` (String, Hash, Array, or nil)

The message body. The type varies:
- **String** — most common; the text content of the message.
- **Hash or Array** — used for structured content (e.g., multimodal/image data). When serialized via `Chat.print`, Hash/Array content is emitted as JSON.
- **nil or ''** — some messages (like `system:` with no inline content) have empty content, serving as markers.

### IndifferentHash

All message hashes are processed with `IndiferentHash.setup`, meaning keys can be accessed as either symbols (`msg[:role]`) or strings (`msg["role"]`):

```ruby
def self.indiferent(messages)
  messages.collect{|msg| IndiferentHash.setup msg }
end
```

### Metadata fields on messages

Messages do **not** have a separate `metadata` field. Instead, metadata is encoded **within the content** of special-role messages:

- **`meta:` messages** — content is a serialized key=value string (parsed by `Chat.parse_meta`). Example: `meta: job=/path/to/job pt_c=1000 ct_c=500`
- **`option:` messages** — content is `"key value"` pairs (parsed by partitioning on space).
- **`config:` messages** — content is space-separated `key value tokens...`

### Tool calls and tool results in messages

Tool calls and results use two special roles with **JSON content**:

**Tool call (function_call):**
```ruby
{
  role: 'function_call',
  content: '{"name":"task_name","arguments":{...},"id":"some-id"}'
}
```

**Tool result (function_call_output):**
```ruby
{
  role: 'function_call_output',
  content: '{"id":"some-id","content":"result text or data"}'
}
```

These are generated in `Chat.jobs` (tools.rb, lines 69–116) when a `job:` or `inline_job:` message is processed:

```ruby
tool_call = {
  name: function_name,
  arguments: step.provided_inputs,
  id: id,
}
tool_output = {
  id: id,
  content: content   # the job result, loaded from disk
}
# Produces two messages:
[{role: 'function_call', content: tool_call.to_json},
 {role: 'function_call_output', content: tool_output.to_json}]
```

---

## Roles

### Complete Role Catalog

The system supports a large number of roles. They fall into several categories:

#### Standard conversational roles
| Role | Semantics |
|---|---|
| `system` | System instructions/configuration for the model |
| `user` | User input / prompts |
| `assistant` | Model responses. Also triggers option reset in the options processor. |

#### Tool execution roles
| Role | Semantics |
|---|---|
| `function_call` | A tool/function invocation. Content is JSON with `name`, `arguments`, `id`. |
| `function_call_output` | The result of a function call. Content is JSON with `id`, `content`. |
| `tool` | Declares available workflow tools. Format: `"WorkflowName task_name [inputs]"` |
| `introduce` | Introduces a workflow's documentation to the model (auto-generates a user message with workflow docs) |
| `mcp` | Declares MCP (Model Context Protocol) tools. Format: `"url [tool1 tool2 ...]"` or `"stdio command [tools]"` |
| `kb` | Declares knowledge base tools. Format: `"kb_name [database1 database2]"` |
| `association` | Registers a knowledge base association as a tool |
| `clear_tools` | Clears all accumulated tool definitions. Content `false` means don't clear. |

#### Job/Task roles
| Role | Semantics |
|---|---|
| `task` | Schedules a workflow job; result loaded asynchronously via `Workflow.produce`. Replaced with `job:` message. |
| `inline_task` | Schedules a job; replaced with `inline_job:` message (inline content). |
| `exec_task` | Executes a job immediately inline; result placed as a `user:` message. |
| `job` | References a completed Step; resolved into `function_call` + `function_call_output` pair. |
| `inline_job` | References a Step as inline file content; resolved into `file:` message. |

#### File/resource roles
| Role | Semantics |
|---|---|
| `file` | Reads a file from disk and wraps content in `<file name="...">` tags as a `user:` message |
| `directory` | Reads all files in a directory recursively, each as a `file:` message |
| `pdf` | References a PDF file path (resolved but content handled by backend) |
| `image` | References an image file path (handled by backend for multimodal) |

#### Import/composition roles
| Role | Semantics |
|---|---|
| `import` | Imports another chat file, fully resolved and expanded inline |
| `continue` | Imports only the last non-empty message from another chat file |
| `last` | Imports the last message after purging `previous_response_id` messages |
| `step` | Loads a specific Step from the job referenced in meta; produces an assistant message with the step's answer |

#### Configuration/control roles
| Role | Semantics |
|---|---|
| `option` | Sets a per-request option (key value). Resets after assistant reply. |
| `sticky_option` | Sets an option that persists across assistant replies. |
| `endpoint` | Sets the LLM endpoint (sticky) |
| `model` | Sets the model name (sticky) |
| `backend` | Sets the backend type (sticky) |
| `agent` | Sets the agent name (sticky) |
| `persist` | Controls persistence behavior |
| `previous_response_id` | OpenAI Responses API continuation token (sticky) |
| `format` | Response format specification (JSON schema). Can be a filename to load from disk. |
| `config` | Sets Scout::Config values at runtime |
| `meta` | Internal bookkeeping metadata (token counts, job paths). Not sent to provider. |

#### Chat manipulation roles
| Role | Semantics |
|---|---|
| `clear` | Acts as a cut point: everything before the last `clear:` is discarded |
| `clear_role` / `clean_role` | Marks roles to be cleaned/removed during processing |
| `clean_role` | Used in `Chat.clean` to remove specific role messages |

#### Special parsing roles
| Role | Semantics |
|---|---|
| `agent` | In the parser, an `agent:` header sets the next block role to `user` |

---

## Parsing (parse.rb)

### Overview

`Chat.parse(text, role = nil)` converts a text string into an Array of message hashes. It is a **line-oriented parser** with support for:

1. **Role headers** — `role: content` lines
2. **Protected blocks** — code fences, `[[...]]`, XML tags, command output markers
3. **Escaped role headers** — `\role:` lines that are kept as literal content

### Role header parsing

Each line is matched against `/^([a-z0-9_]+):(.*)$/`:

```ruby
if line =~ /^([a-z0-9_]+):(.*)$/
  role = $1
  inline_content = $2.strip
  # ...
end
```

- **Block form**: `role:` with no inline content → sets current_role, accumulates subsequent lines as content
- **Inline form**: `role: some text` → immediately creates a message with that text

Special handling for `previous_response_id` and `agent` roles: after an inline message, the next block defaults to `user`:

```ruby
current_role = 'user' if role == 'previous_response_id'
current_role = 'user' if role == 'agent'
```

### Escaped headers

A line like `\user: this is literal` (matching `/^\\([a-z0-9_]+):(.*)$/`) is treated as literal content, not a role header. This allows embedding role-like patterns in content.

### Protected block types

The parser protects certain blocks from being interpreted as role headers:

1. **Triple-backtick fences** (``` ... ```): Content between fences is preserved literally.
2. **`[[ ... ]]` blocks**: Square-bracket delimited protected regions.
3. **XML tags**: If a line matches `<tagname ...>` and the text contains a matching `</tagname>`, the parser enters XML protected mode with a stack-based tag matcher.
4. **Command output markers**: Lines matching `something:-- cmd {{{` ... `something:-- cmd }}}` are converted to `<cmd_output cmd="cmd">` ... `</cmd_output>`.

### `parse_json` helper

```ruby
def self.parse_json(text)
  re = /.*\`\`\`json\n(.*)\`\`\`\n?.*/sm
  text = text.gsub(re, '\1') if text.include?('```json')
  JSON.parse text
end
```

Strips markdown JSON code fences and parses the inner JSON.

### Serialization: `Chat.print(chat)`

The inverse of parse — converts an Array of messages back to text:

```ruby
def self.print(chat)
  "\n" + chat.collect do |message|
    IndiferentHash.setup message
    case message[:content]
    when Hash, Array
      message[:role].to_s + ":\n\n" + message[:content].to_json
    when nil, ''
      message[:role].to_s + ":"
    else
      if %w(option previous_response_id function_call function_call_output meta).include? message[:role].to_s
        message[:role].to_s + ": " + message[:content].to_s   # inline form for these roles
      else
        message[:role].to_s + ":\n\n" +
          message[:content].to_s.gsub(re, '\\\\\1\2')          # block form, escaped
      end
    end
  end * "\n\n"
end
```

Key serialization rules:
- Hash/Array content → JSON in block form
- nil/empty content → just `role:`
- `option`, `previous_response_id`, `function_call`, `function_call_output`, `meta` → **inline form** (`role: content`)
- Everything else → **block form** (`role:\n\ncontent`) with role-like patterns escaped with `\`

### `Chat.print_brief(chat, expand = [])`

A compact serialization using `Log.fingerprint` for non-expanded roles (produces short hash-like summaries instead of full content).

---

## Persistence (persist.rb)

### Persist driver registration

Chat persistence is registered with Scout's `Persist` system via custom save/load drivers:

```ruby
Persist.save_drivers[:chat] = proc do |file, content|
  case content
  when LLM::Agent
    new_chat = content.current_chat - content.start_chat
    Open.sensible_write(file, LLM.print(new_chat))
  when Array
    Open.sensible_write(file, LLM.print(content))
  else
    # handles streams
    stream = content.respond_to?(:stream) ? content.stream :
             content.respond_to?(:dumper_stream) ? content.dumper_stream :
             content
    Open.sensible_write(file, stream)
  end
end

Persist.load_drivers[:chat] = proc do |file|
  String === file ? LLM.chat(file) : file
end

Workflow::TYPE_EXTENSIONS[:chat] = :chat
```

### File format

Chats are persisted as **plain text files** using `Chat.print` format — the same text format that `Chat.parse` reads. This creates a **round-trippable** text format.

### How saving works on Chat instances

The annotation module provides `save`, `write`, and `write_answer` methods:

```ruby
def save(path, force = true)
  path = path.to_s if Symbol === path
  if not (Open.exists?(path) || Path === path || Path.located?(path))
    path = Scout.chats.find[path]  # default to chats directory
  end
  return if Open.exists?(path) && ! force
  Open.write path, LLM.print(self)
end
```

- `save(path)` — writes full chat using `LLM.print(self)`
- `write(path)` — writes full chat using `self.print` (processed form)
- `write_answer(path)` — writes only the final answer text

### Loading without re-processing

`Chat.load(file)` reads a chat file **without** compiling it (no task execution, file reads, or import resolution):

```ruby
def self.load(file)
  Chat.setup(LLM.messages(Open.read(file.to_s)))
end
```

This is used for provenance inspection where side effects must be avoided.

### Integration with Workflow

`Workflow::TYPE_EXTENSIONS[:chat] = :chat` registers `:chat` as a workflow task type extension, allowing Scout workflow tasks to declare `:chat` as their output type and get automatic serialization.

---

## Processing Pipeline

### Entry point: `LLM.chat`

The full processing pipeline is orchestrated in `LLM.chat`:

```ruby
def self.chat(file = [], original = nil)
  original ||= (String === file and Open.exists?(file)) ? file : Path.setup($0.dup)
  caller_lib_dir = Path.caller_lib_dir(nil, 'chats')

  # 1. Parse into messages
  if Path.is_filename? file
    messages = self.messages Open.read(file), file
  else
    messages = self.messages file
  end

  # 2. Make all hashes IndiferentHash
  messages = Chat.indiferent messages

  # 3. Resolve imports/continues/lasts
  messages = Chat.imports messages, original, caller_lib_dir

  # 4. Apply clear/clean directives
  messages = Chat.clear messages
  messages = Chat.clean messages

  # 5. Apply config options
  messages = Chat.config messages

  # 6. Execute tasks and schedule jobs
  messages = Chat.tasks messages
  messages = Chat.jobs messages

  # 7. Resolve file/directory references
  messages = Chat.files messages, original, caller_lib_dir

  # 8. Annotate as Chat
  Chat.setup messages
end
```

### Pipeline stages (in order)

#### 1. Parse → Messages
Converts text input to `[{role:, content:}, ...]` via `LLM.messages`/`Chat.parse`.

#### 2. `Chat.indiferent`
Applies `IndiferentHash.setup` to every message hash.

#### 3. `Chat.imports` (files.rb)
Resolves `import:`, `continue:`, and `last:` messages:
- **`import:`** — recursively calls `LLM.chat` on the referenced file, fully expanding it
- **`continue:`** — imports only the last non-empty message from the referenced file
- **`last:`** — imports the last message after purging `previous_response_id` messages
- Uses `Chat.find_file` to resolve paths across multiple search locations (relative to original, caller lib dir, Scout.chats, absolute)

#### 4. `Chat.clear` (clear.rb)
Implements chat truncation:
- Walks messages in **reverse** from the end
- Stops at the last `clear:` message (everything before it is discarded)
- Respects `clear_tools:` (controls whether function_call/function_call_output messages survive)
- Processes `clean_role:` / `clear_role:` markers to remove specific role messages

```ruby
def self.clear(messages, role = 'clear')
  new = []
  clear_tools = false
  clean_roles = []
  messages.reverse.each do |message|
    if message[:role].to_s == role.to_s
      break  # everything before this point is discarded
    elsif message[:role].to_s == 'clear_tools'
      clear_tools = message['content'].to_s != 'false'
    elsif ['function_call', 'function_call_output'].include?(message[:role].to_s)
      new << message unless clear_tools
    elsif ['clean_role', 'clear_role'].include?(message[:role].to_s)
      clean_roles << message[:content].strip
    else
      new << message
    end
  end
  new = Chat.setup new.reverse
  clean_roles.each { |role| new = self.clean(new, role) }
  new
end
```

#### 5. `Chat.clean` (clear.rb)
Removes messages with empty content and optionally messages of specified roles:

```ruby
def self.clean(messages, role = ['skip', 'previous_response_id'])
  messages.reject do |message|
    ((String === message[:content]) && message[:content].empty?) ||
      (Array === role ? false : message[:role].to_s == role.to_s)
  end
end
```

#### 6. `Chat.config` (options.rb)
Processes `config:` messages to set `Scout::Config` values at runtime:

```ruby
def self.config(chat)
  new = []
  chat.select do |info|
    if info[:role].to_s == 'config'
      key, value, *tokens = info[:content].split(" ")
      Scout::Config.set({key => value}, *tokens)
      next  # removed from chat
    end
    new << info
  end
  chat.replace new
end
```

#### 7. `Chat.tasks` (tools.rb)
Processes `task:`, `inline_task:`, and `exec_task:` messages:
- Parses workflow name, task name, and options from content
- Creates workflow jobs via `Chat.load_workflow`
- `exec_task:` — executes immediately, result becomes a `user:` message
- `inline_task:` — replaced with `inline_job:` message (for later file processing)
- `task:` — replaced with `job:` message
- All non-exec tasks are batched and produced via `Workflow.produce(jobs)`

```ruby
def self.tasks(messages, original = nil)
  jobs = []
  new = messages.collect do |message|
    if ['task', 'inline_task', 'exec_task'].include?(message[:role])
      workflow, task = info.split(" ").values_at 0, 1
      options = IndiferentHash.parse_options info
      job = workflow.job(task, jobname, options)
      jobs << job unless message[:role] == 'exec_task'
      # exec_task → immediate result as user message
      # inline_task → inline_job message
      # task → job message
    else
      message
    end
  end.flatten
  Workflow.produce(jobs) if jobs.any?
  new
end
```

#### 8. `Chat.jobs` (tools.rb)
Resolves `job:` and `inline_job:` messages into tool call/result pairs or file references:
- `inline_job:` — produces a `file:` message pointing to the Step's path
- `job:` — loads the Step result and produces a `function_call` + `function_call_output` message pair

Handles job states: done (load result), streaming (join), error (optionally return exception as JSON).

#### 9. `Chat.files` (files.rb)
Resolves `file:`, `directory:`, `pdf:`, `image:`, and `step:` messages:
- **`file:`** — reads file content, wraps in `<file name="path">content</file>` tags, produces a `user:` message
- **`directory:`** — recursively expands all files in a directory as individual `file:` messages
- **`pdf:`/`image:`** — resolves the file path (content handled by the backend)
- **`step:`** — loads a specific Step from the meta-referenced job, produces an `assistant:` message with the step's answer

#### Tool extraction (called separately, not in `LLM.chat` pipeline)

`Chat.tools(messages)`, `Chat.options(messages)`, and `Chat.associations(messages, kb)` are called separately (typically by `LLM.ask` or the backend) to extract:
- **Tool definitions** from `tool:`, `introduce:`, `mcp:`, `kb:` messages
- **Options** from `option:`, `sticky_option:`, `endpoint:`, `model:`, etc.
- **Associations** from `association:` messages

These are side-channel extractions: they **remove** the control messages from the chat and return the extracted data separately.

### `Chat.options` (options.rb)

```ruby
def self.options(chat)
  options = IndiferentHash.setup({})
  sticky_options = IndiferentHash.setup({})
  new = []

  chat.each do |info|
    role = info[:role].to_s
    if %w(endpoint model backend agent).include? role       # sticky
      sticky_options[role] = info[:content]
      next  # removed
    elsif role == 'persist'
      options[role] = info[:content]
      next
    elsif role == 'previous_response_id'
      sticky_options[role] = info[:content]                  # sticky, NOT removed
    elsif role == 'format'
      options[role] = resolve_format(info[:content])
      next
    elsif role == 'option'
      options[key] = value                                   # non-sticky
      next
    elsif role == 'sticky_option'
      sticky_options[key] = value
      next
    elsif role == 'assistant'
      options.clear   # non-sticky options reset after assistant reply
    end
    new << info
  end
  chat.replace new
  sticky_options.merge(options)
end
```

### `Chat.tools` (tools.rb)

```ruby
def self.tools(messages)
  tool_definitions = IndiferentHash.setup({})
  new = messages.collect do |message|
    role = message[:role]
    case role
    when 'mcp'        # MCP tools (stdio or URL)
    when 'tool'       # Workflow task tools
    when 'introduce'  # Workflow documentation injection
    when 'kb'         # Knowledge base tools
    when 'clear_tools' # Reset tool definitions
    else
      message  # pass through
    end
  end.compact.flatten
  messages.replace new
  tool_definitions
end
```

Each tool-related role is consumed (removed from chat) and its definition is accumulated in `tool_definitions`:
- **`mcp:`** — connects to an MCP server (stdio or HTTP) and loads tool definitions via `LLM.mcp_tools`
- **`tool:`** — loads a workflow and creates task tool definitions via `LLM.task_tool_definition` or `LLM.workflow_tools`
- **`introduce:`** — loads a workflow and injects its documentation as a `user:` message (NOT consumed silently)
- **`kb:`** — loads a knowledge base and creates tool definitions via `LLM.knowledge_base_tool_definition`

---

## Annotation/Provenance (annotation.rb)

### The Annotation mixin

As described above, `Chat` uses `extend Annotation` to become an annotation module. This means any Array can be turned into a Chat via `Chat.setup(array)`.

### Chat instance methods (defined in annotation.rb)

The annotation module adds a rich DSL of instance methods to Chat (Array) objects:

#### Message building methods
```ruby
def message(role, content)   # append {role:, content:}
def user(content)            # append user message
def system(content)          # append system message
def assistant(content)       # append assistant message
def import(file)             # append import: message
def import_last(file)        # append last: message
def file(file)               # append file: message
def introduce(workflow)      # append introduce: message
def pdf(file)                # append pdf: message
def directory(directory)     # append directory: message
def continue(file)           # append continue: message
def format(format)           # append format: message
def tool(*parts)             # append tool: message
def task(workflow, task_name, inputs = {})
def exec_task(workflow, task_name, inputs = {})
def inline_task(workflow, task_name, inputs = {})
def job(step)                # append job: message
def inline_job(step)         # append inline_job: message
def association(name, path, options = {})
def tag(content, name=nil, tag=:file, role=:user)
```

#### Option/configuration methods
```ruby
def option(name, value)
def endpoint(value)
def model(value)
def image(file)
```

#### Inference methods
```ruby
def ask(options = {})          # calls LLM.ask with this chat
def chat(options = {})         # ask + append response
def json(*args, only_ask:, **) # ask with JSON format, parse result
```

#### Chat composition methods
```ruby
def self.follow(intro, coda)   # merges two chats, handling previous_response_id
def append(coda)               # append messages to this chat
def follow(coda)               # same as append (alias semantics)
def prepend(intro)             # prepend messages to this chat
def branch                     # return a duplicate (annotated copy)
```

#### Provenance and reporting methods
```ruby
def print              # serialize to text
def final              # last message after purge
def purge              # remove previous_response_id messages
def shed               # return a new chat with just the final message
def answer             # content of the final message
def save(path, force=true)
def write(path, force=true)
def write_answer(path, force=true)
```

#### Meta/provenance inspection methods
```ruby
def add_meta(key, value)         # add/update meta key-value
def meta                         # parse last meta message
def job_paths / jobs             # extract job paths from meta
def last_job                     # last job reference from meta
def message_index                # lineage IDs for all messages
def job_chat_files               # find chat files from referenced jobs
def job_chats                    # load those chat files
def job_agent_chat_files         # find agent chat files from jobs
def job_agent_chats              # load agent chat files
```

### Meta message system

Meta messages are the **provenance backbone** of the Chat system. They carry key=value pairs serialized as space-delimited strings:

```ruby
def self.serialize_meta(meta)
  keys = meta.keys.sort_by { |key| String === meta[key] ? meta[key].length : 0 }
  keys.collect { |key| [key, meta[key]] * '=' } * ' '
end
```

Example meta content: `job=/path/to/job pt_c=1000 ct_c=500 tt_c=2000`

Key meta fields:
| Key | Meaning |
|---|---|
| `job` | Path to the workflow job that produced this chat segment |
| `pt_c` | Prompt token count |
| `ct_c` | Completion token count |
| `tt_c` | Total token count |

### Meta processing (meta.rb)

`Chat.meta(messages)` extracts and **removes** meta messages from the chat:

```ruby
def self.meta(messages)
  meta_messages = []
  messages.reject! do |message|
    match = message[:role].to_s == 'meta'
    meta_messages << message if match
    match
  end
  return nil if meta_messages.empty?

  metas = meta_messages.collect { |message| parse_meta(message[:content]) }
  current = IndiferentHash.setup(metas.last.dup)
  # Find the last checkpoint with token counts
  checkpoint = metas.reverse.find do |meta|
    %w[pt_c ct_c tt_c].any? { |name| meta.include?(name) }
  end
  if checkpoint
    %w[pt_c ct_c tt_c].each do |name|
      current[name] = checkpoint[name] if checkpoint.include?(name)
    end
  end
  current
end
```

The meta system is designed so that:
- Meta messages are **local bookkeeping** and are **not sent to the provider**
- The last checkpoint with token counts supplies the running total for the next request
- Job metadata deliberately contributes no token counts

### Message lineage and tracing

`message_index` assigns a unique digest-based ID to each message (excluding meta from the chain):

```ruby
def message_index
  previous = nil
  collect do |message|
    id = Misc.digest([previous, role, content])
    info = { id: id, role: role.to_sym, prev: previous, fingerprint: Log.truncate_string(content) }
    if role == 'meta'
      info[:meta] = Chat.parse_meta(content)
    else
      previous = id  # meta doesn't advance the lineage chain
    end
    info
  end
end
```

`trace_indices` segments the chat into response segments, each beginning with a meta marker:

```ruby
def self.trace_indices(indices)
  # A meta starts a segment; the segment continues until another meta,
  # a new user/system turn, or the end of the chat.
  # Consecutive/final metas with no covered messages are "orphan" records.
end
```

### Projection

`Chat.project(job, messages)` creates a chat segment from job output with a producer marker:

```ruby
def self.project(job, messages)
  projected = Array(messages).reject { |m| m[:role].to_s == 'meta' }.collect(&:dup)
  return [] if projected.empty?
  [{ role: :meta, content: serialize_meta(job: job.to_s) }] + projected
end
```

### Job chat file discovery

The system can trace provenance through job dependencies:

```ruby
def self.job_chat_files(job, seen = Set.new)
  # Collects result chats and logged agent chats for a job and ALL its dependencies
  # Uses a Set to avoid infinite recursion on cycles and shared dependencies
end
```

---

## Key Abstractions and Design Patterns

### 1. Module-as-Annotation (Annotation mixin)

The most distinctive pattern. `Chat` is a module that extends `Annotation`, enabling any Array to be "annotated" as a Chat. This avoids subclassing Array (which is fragile) and allows Chat behavior to be mixed into existing arrays.

```ruby
module Chat
  extend Annotation
  # instance methods become available on Arrays via Chat.setup(array)
end
```

### 2. Open Module Pattern

`module Chat` is opened across 10+ files, each adding class or instance methods. This is idiomatic Ruby for organizing large modules:

```
chat.rb          → LLM factory methods
chat/parse.rb    → Chat.parse, Chat.print (class methods)
chat/process.rb  → Chat.content_tokens, Chat.indiferent (class methods)
chat/process/clear.rb    → Chat.clear, Chat.clean, Chat.purge (class methods)
chat/process/files.rb    → Chat.imports, Chat.files (class methods)
chat/process/options.rb  → Chat.config, Chat.options (class methods)
chat/process/tools.rb    → Chat.tasks, Chat.jobs, Chat.tools (class methods)
chat/process/meta.rb     → Chat.meta + provenance methods (class + instance methods)
chat/annotation.rb       → Chat instance methods (message building, inference, reporting)
chat/prompt.rb           → Chat.prepare_prompt, Chat.shorten_tools (class methods)
```

### 3. Text-as-Serialization Format

The entire chat is serialized to/from a human-readable text format. This is both the persistence format and the authoring format. Users can write chat files directly in a text editor:

```
system: You are a helpful assistant.

user: What is 2+2?

assistant: 4
```

### 4. Side-Channel Extraction Pattern

Tool definitions, options, and associations are extracted from the chat **separately** from the main processing pipeline. They modify the message array in place (using `messages.replace new`) and return the extracted data:

```ruby
def self.tools(messages)
  tool_definitions = {}
  new = messages.collect { ... }.compact.flatten
  messages.replace new          # mutate original array
  tool_definitions              # return extracted data
end
```

### 5. Clear/Cut Semantics

The `clear:` role implements a **cut point** — everything before the last `clear:` message is discarded. This allows chat templates to include setup that is stripped before the actual conversation:

```
system: Setup instructions
clear:
user: Actual question
```

### 6. Sticky vs. Non-Sticky Options

Options have two lifetimes:
- **Non-sticky** (`option:`, `persist:`, `format:`) — reset after an `assistant:` reply
- **Sticky** (`endpoint:`, `model:`, `backend:`, `agent:`, `sticky_option:`, `previous_response_id:`) — persist across the entire conversation

### 7. IndiferentHash everywhere

All message hashes use `IndiferentHash.setup` for symbol/string key indifference, avoiding `Symbol === String` comparison bugs.

### 8. Role-Polymorphic Content

The same `content` field holds different data types depending on the role:
- String text for `user`/`assistant`/`system`
- JSON for `function_call`/`function_call_output`
- Space-delimited key=value for `meta`
- Space-delimited key value for `option`
- File paths for `file`/`pdf`/`image`/`import`
- Workflow specs for `task`/`tool`

### 9. Protected Block Parsing

The parser's multi-format protected block handling (backtick fences, `[[...]]`, XML tags, command output markers) allows embedding code, structured data, and command output within chat text without false-positive role header detection.

### 10. Thread-Local Access Control

Tool processing uses thread-local variables for directory access control:

```ruby
def self.allow_dir(dir)
  Thread.current['allowed_dirs'] ||= []
  return if Thread.current['allowed_dirs'].include?(dir)
  Thread.current['allowed_dirs'] << dir
end
```

This provides per-thread sandboxing of file operations without explicit parameter passing.

---

## Summary Table: File Inventory

| File | Lines | Responsibility |
|---|---|---|
| `chat.rb` | ~70 | `LLM` module factory; orchestrates pipeline |
| `chat/parse.rb` | ~190 | Text ↔ messages parsing; `print`/`print_brief` |
| `chat/persist.rb` | ~24 | Persist save/load drivers for `:chat` type |
| `chat/process.rb` | ~17 | `content_tokens`, `indiferent` helpers |
| `chat/process/clear.rb` | ~63 | `clear`, `clean`, `purge`, `pull` |
| `chat/process/files.rb` | ~103 | `imports`, `files`, `find_file`, `tag` |
| `chat/process/options.rb` | ~72 | `config`, `options` (sticky/non-sticky) |
| `chat/process/tools.rb` | ~250 | `tasks`, `jobs`, `tools`, `associations`, access control |
| `chat/annotation.rb` | ~270 | Chat instance DSL (message building, inference, provenance) |
| `chat/prompt.rb` | ~190 | Context strategies (`shorten_tools`), prompt preparation |
