# Chat

Chat is a lightweight builder around an Array of messages that lets you construct, persist, and run LLM conversations declaratively. It integrates tightly with the LLM pipeline (LLM.chat/LLM.ask), Workflows (tool calls), and KnowledgeBase traversal.

A Chat is “just” an Array annotated with Chat behavior (via Annotation). Each element is a Hash like {role: 'user', content: '…'}.

Key capabilities:
- Build conversations programmatically (user/system/assistant/…).
- Declare tools and jobs inline (Workflow tasks, saved Step results).
- Inline files and directories into messages (as tagged content).
- Set per-turn options (format, endpoint, model), request JSON structures.
- Run a conversation (ask), append responses (chat), and save/write to files.

Sections:
- Data model and setup
- Adding messages
- Files, directories and tagging
- Declaring tools, tasks and jobs
- Options, endpoint and formats
- Running a chat: ask/chat/json/json_format
- Persistence helpers and branching
- Interop with LLM.chat
- CLI: using Chat with scout llm and scout agent
- Examples

---

## Data model and setup

A Chat is an Array annotated with Chat, so every method mutates/appends to the underlying array.

- Chat.setup([]) → an annotated empty conversation.
- Each message appended is a Hash with keys:
  - role: String or Symbol (e.g., 'user', 'system', 'assistant', …).
  - content: String (or structured content passed through).

Example
```ruby
chat = Chat.setup []
chat.system "You are an assistant"
chat.user   "Hi"
puts chat.print
```

Chat uses Annotation. You can annotate/cloned arrays and preserve Chat behavior.

---

## Adding messages

All helpers append a message:

- message(role, content) — base append.
- user(text), system(text), assistant(text).
- import(file), continue(file) — declarative import markers for LLM.chat (see Interop).
- file(path), directory(path) — inline content (see next section).
- format(value) — set desired output format (e.g. :json, or JSON Schema Hash).
- tool(workflow, task, inputs?) — register a Workflow task tool declaration (see Tools below).
- task(workflow, task_name, inputs={}) — declare a Workflow task to run, converted to a job (Step) via LLM.chat.
- inline_task(workflow, task_name, inputs={}) — like task but inlined result.
- job(step), inline_job(step) — attach a precomputed Step’s result (file content or function call output).
- association(name, path, options={}) — register a KnowledgeBase association (LLM will build a tool for it).

Utilities:
- tag(content, name=nil, tag=:file, role=:user) — wrap content in a tagged block (e.g., <file name="…">…</file>) and append it as role (default :user).

---

## Files, directories and tagging

Use file/directory/tag to place content into the chat:

- file(path) — appends the contents of path tagged as <file name="…">…</file>.
- directory(path) — appends all files inside as a sequence of <file> tags.
- tag(content, name=nil, tag=:file, role=:user) — manual variant to tag any text.

Tagged content is respected by LLM.parse/LLM.chat and protected from unintended parsing/splitting.

---

## Declaring tools, tasks and jobs

Chat supports wiring external tools into conversations:

- tool workflow task [input options] — declares a callable tool from a Workflow task. Example:
  ```ruby
  chat.tool "Baking", "bake_muffin_tray"
  ```
  LLM.ask will export this task as a function tool; when the model calls it, the function block (or the default runner) will run the job and feed the result back to the model.

- task workflow task [input options] — enqueues a Workflow job to be produced before the conversation proceeds; replaces itself with a job marker.

- inline_task workflow task [input options] — like task, but inlines the result (as a file-like message) for immediate context.

- job(step) / inline_job(step) — attach an existing Step result. job inserts a function_call + tool output pair so models can reason over the output; inline_job inserts the raw result file.

- association name path [options] — registers a KnowledgeBase association file as a tool (e.g., undirected=true, source/target formats). LLM will add a “children” style tool or per-association tool definition.

These declarations are processed by LLM.chat (see Interop) to produce steps and tools before the model is queried.

---

## Options, endpoint and formats

Set transient options as messages; LLM.options will read them and merge into the ask options:

- option(key, value) — arbitrary key/value (e.g., temperature).
- endpoint(value) — named endpoint (merges with Scout.etc.AI[endpoint].yaml).
- model(value) — backend model ID.
- format(value) — request output format:
  - :json or 'json_object' for JSON.
  - JSON Schema Hash for structured object/array replies (Responses/OpenAI support).

You can also insert a previous_response_id message to continue a Responses session.

Note: Most options reset after an assistant turn, except previous_response_id which persists until overwritten.

---

## Running a chat: ask/chat/json/json_format

- ask(…): returns the assistant reply (String) by calling LLM.ask(LLM.chat(self), …).
- respond(…): equivalent to ask(current_chat, …) when used through an Agent.
- chat(…): calls ask with return_messages: true, appends the assistant reply to the conversation, and returns the reply content.
- json(…): sets format :json, calls ask, parses JSON, and returns:
  - obj['content'] if the parsed object is {"content": …}, else the object.
- json_format(schema, …): sets format to the provided schema (Hash), calls ask, and parses the JSON accordingly. Returns obj or obj['content'] when applicable.

These helpers adapt the conversation to common usage patterns: accumulate messages, call the model, and parse outputs when needed.

---

## Persistence helpers and branching

- print — pretty-prints the conversation (using LLM.print of the processed chat).
- save(path, force=true) — writes print output. If path is a name (Symbol/String without path), it resolves via Scout.chats.
- write(path, force=true) — alias writing with print content.
- write_answer(path, force=true) — writes the last assistant answer only.
- branch — returns a deep-annotated dup so you can explore branches without mutating the original.
- shed — returns a Chat containing only the last message (useful for prompts that must include only the latest instruction).
- answer — returns the content of the last message.

---

## Interop with LLM.chat

A Chat instance can be passed to LLM.ask by Chat#ask; internally it runs:

1) LLM.chat(self) — expands the Array of messages into a pipeline:
   - imports, clear, clean,
   - tasks → produces dependencies (Workflow.produce),
   - jobs → turns Steps into function calls or inline files,
   - files/directories → expand into <file> tags.

2) LLM.options to collect endpoint/model/format/etc.

3) Backend ask with optional tool wiring (from tool/association declarations).

Thus, your Chat can be both a declarative script (like a “chat file”) and a runnable conversation object.

---

## CLI: using Chat with scout llm and scout agent

The CLI uses the same message DSL and processing. Useful commands:

- Ask an LLM:
  - scout llm ask [options] [question]
    - -t|--template <file_or_key> — load a prompt template; if it contains “???”, the trailing question replaces it; otherwise concatenates as a new user message.
    - -c|--chat <chat_file> — open a conversation file; the response is appended to the file (using Chat.print).
    - -i|--inline <file> — answer comments of the form “# ask: …” inside a source file; writes answers inline between “# Response start/end”.
    - -f|--file <file> — prepend the file contents as a tagged <file> message; or embed STDIN/file where “...” appears in the question.
    - -m|--model, -e|--endpoint, -b|--backend — select backend and model (merged with per-endpoint configs).
    - -d|--dry_run — expand and print the conversation (LLM.print) without asking.

- Ask via an Agent (workflow + knowledge base):
  - scout agent ask [options] [agent_name] [question]
    - Loads the agent from:
      - Scout.workflows[agent_name] (workflow.rb) or
      - Scout.chats[agent_name] or a directory with workflow.rb, knowledge_base/, start_chat.
    - Same flags as llm ask; adds:
      - -wt|--workflow_tasks list — export only these tasks to the agent as callable tools.

- Auxiliary:
  - scout llm template — list prompt templates (Scout.questions).
  - scout llm server — minimal chat web UI over ./chats with a REST API (save/run lists).
  - scout agent kb <agent_name> … — runs KnowledgeBase CLI pre-wired to the agent’s KB.

This CLI uses the same LLM.chat pipeline and Chat.print/save semantics as the Ruby API.

---

## Examples

Create and print a minimal conversation
```ruby
a = LLM::Agent.new
a.start_chat.system 'you are a robot'
a.user "hi"
puts a.print
```

Compile messages with roles inline
```ruby
text = <<~EOF
system:

you are a terse assistant that only write in short sentences

assistant:

Here is some stuff

user: feedback

that continues here
EOF
LLM.chat(text)  # → messages array ready to ask
```

Register and use a Workflow tool
```ruby
chat = Chat.setup []
chat.user "Use the provided tool to learn the instructions of baking a tray of muffins. Don't give me your own recipe."
chat.tool "Baking", "bake_muffin_tray"
LLM.ask(chat)
```

Declare KnowledgeBase associations and ask
```ruby
chat = Chat.setup []
chat.system "Query the knowledge base of familiar relationships to answer the question"
chat.user "Who is Miki's brother in law?"
chat.message(:association, "brothers #{datafile_test(:person).brothers} undirected=true")
chat.message(:association, "marriages #{datafile_test(:person).marriages} undirected=true source=\"=>Alias\" target=\"=>Alias\"")
LLM.ask(chat)
```

Request structured JSON
```ruby
chat = Chat.setup []
chat.system "Respond in json format with a hash of strings as keys and string arrays as values, at most three in length"
chat.user "What other movies have the protagonists of the original gost busters played on, just the top."
chat.format :json
puts chat.ask
```

Iterate structured results with an Agent
```ruby
agent = LLM::Agent.new
agent.iterate("List the 3 steps to bake bread") do |step|
  puts "- #{step}"
end
```

---

Chat provides an ergonomic, declarative way to build conversations in code and on disk. It composes seamlessly with LLM.chat/ask, Workflows (as tools), KnowledgeBases (as associations), and the Scout CLI, making it easy to author, run, and persist agentic interactions.