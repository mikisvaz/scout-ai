# Agent

Agent is a thin orchestrator around LLM, Chat, Workflow and KnowledgeBase that maintains a conversation state, injects tools automatically, and streamlines structured interactions (JSON lists/dictionaries) with helper methods.

Core ideas:
- Keep a live chat (conversation) object and forward the Chat DSL (user/system/…).
- Export Workflow tasks and KnowledgeBase queries as tool definitions so the model can call them functionally.
- Centralize backend/model/endpoint defaults for repeated asks.
- Provide convenience helpers to iterate over structured results (lists/dictionaries).

Sections:
- Quick start
- Construction and state
- Tool wiring (Workflow and KnowledgeBase)
- Running interactions
- Iterate helpers
- Loading an agent from a directory
- API reference
- CLI: scout agent …

---

## Quick start

Build a live conversation and print it

```ruby
a = LLM::Agent.new
a.start_chat.system 'you are a robot'
a.user "hi"
puts a.print   # via Chat#print, forwarded through Agent
```

Run a Workflow tool via tool calling

```ruby
m = Module.new do
  extend Workflow
  self.name = "Registration"

  desc "Register a person"
  input :name, :string, "Last, first name"
  input :age, :integer, "Age"
  input :gender, :select, "Gender", nil, :select_options => %w(male female)
  task :person => :yaml do
    inputs.to_hash
  end
end

agent = LLM::Agent.new workflow: m, backend: 'ollama', model: 'llama3'
agent.ask "Register Eduard Smith, a 25 yo male, using a tool call to the tool provided"
```

Query a KnowledgeBase (tool exported automatically)

```ruby
TmpFile.with_dir do |dir|
  kb = KnowledgeBase.new dir
  kb.format = {"Person" => "Alias"}
  kb.register :brothers, datafile_test(:person).brothers, undirected: true
  kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
  kb.register :parents, datafile_test(:person).parents

  agent = LLM::Agent.new knowledge_base: kb
  puts agent.ask "Who is Miki's brother in law?"
end
```

---

## Construction and state

- LLM::Agent.new(workflow: nil, knowledge_base: nil, start_chat: nil, **kwargs)
  - workflow: a Workflow module or a String (loaded via Workflow.require_workflow).
  - knowledge_base: a KnowledgeBase instance (optional).
  - start_chat: initial messages (Chat or Array) to seed new chat branches.
  - **kwargs: stored as @other_options and merged into calls to LLM.ask (e.g., backend:, model:, endpoint:, log_errors:, etc.).

Conversation lifecycle:
- start_chat → returns a base Chat (Chat.setup []) lazily allocated once.
- start(chat=nil)
  - With chat: adopt it (if not already a Chat, annotate and set).
  - Without: branch the start_chat (non-destructive copy).
- current_chat → the active chat instance (created on demand).

Forwarding:
- method_missing forwards any unknown method to current_chat, so you can call:
  - agent.user "text", agent.system "policy", agent.tool "WF" "task", agent.format :json, etc.

---

## Tool wiring (Workflow and KnowledgeBase)

When you call Agent#ask:
- If workflow or knowledge_base is present, Agent builds a tools array:
  - Workflow: LLM.workflow_tools(workflow) produces one tool per exported task (OpenAI/Responses-compatible function schemas).
  - KnowledgeBase: LLM.knowledge_base_tool_definition(kb) produces a “children” tool that takes {database, entities}.
- Agent invokes LLM.ask(messages, tools: ..., **@other_options, **user_options) with a block that handles tool calls:
  - 'children' → returns kb.children(database, entities)
  - any other tool name → runs workflow.job(name, jobname?, parameters).run or .exec (exec if workflow.exec_exports includes the task).

Notes:
- Tool outputs are serialized back to the model as tool results. If your tool returns a Ruby object, it is JSON-encoded automatically inside the tool response.
- For KnowledgeBase integrations, Agent also enriches the system prompt with markdown descriptions of each registered database (system_prompt).

---

## Running interactions

- ask(messages_or_chat, model=nil, options={}) → String (assistant content) or messages (when return_messages: true)
  - messages_or_chat can be: Array of messages, a Chat, or a simple string (Agent will pass through LLM.chat parsing).
  - model parameter can override the default; typically you set backend/model/endpoint in the Agent constructor.
  - If workflow/knowledge_base is configured, tools are injected and tool calls are handled automatically.

- respond(...) → ask(current_chat, ...)
- chat(...) → ask with return_messages: true, then append the assistant reply to current_chat and return the reply content.
- json(...) → sets current_chat.format :json, runs ask, parses JSON, returns the object (if object == {"content": ...}, returns that inner content).
- json_format(format, ...) → sets current_chat.format to a JSON schema Hash and parses accordingly.

Formatting helpers:
- format_message and prompt are internal helpers for building a system + user prompt (used by some agents). Not required for normal use; Agent relies on LLM.chat to parse and LLM.ask to execute.

---

## Iterate helpers

For models that support JSON schema outputs (e.g., OpenAI Responses), Agent provides sugar to iterate over structured results:

- iterate(prompt=nil) { |item| … }
  - Sets endpoint :responses (so the Responses backend is used).
  - If prompt present, appends as user message.
  - Requests a JSON object with an array property "content".
  - Resets format back to :text afterwards.
  - Yields each item in the content list.

- iterate_dictionary(prompt=nil) { |k,v| … }
  - Similar, but requests a JSON object with string values (arbitrary properties).
  - Yields each key/value pair.

Example:
```ruby
agent = LLM::Agent.new
agent.iterate("List three steps to bake bread") { |s| puts "- #{s}" }

agent.iterate_dictionary("Give capital cities for FR, ES, IT") do |country, capital|
  puts "#{country}: #{capital}"
end
```

---

## Loading an agent from a directory

- LLM::Agent.load_from_path(path)
  - Expects a directory containing:
    - workflow.rb — a Workflow definition (optional),
    - knowledge_base — a KnowledgeBase directory (optional),
    - start_chat — a chat file (optional).
  - Returns a configured Agent with those components.

Paths are resolved via the Path subsystem; files like workflow.rb can be located relative to the given directory.

---

## API reference

Constructor and state:
- Agent.new(workflow: nil|String|Module, knowledge_base: nil, start_chat: nil, **kwargs)
- start_chat → Chat
- start(chat=nil) → Chat (branch or adopt provided)
- current_chat → Chat

Chat DSL forwarding (method_missing):
- All Chat methods available: user, system, assistant, file, directory, tool, task, inline_task, job, inline_job, association, format, option, endpoint, model, image, save/write/print, etc.

Asking and replies:
- ask(messages, model=nil, options={}) → String (or messages if return_messages: true)
- respond(...) → ask(current_chat, ...)
- chat(...) → append answer to current_chat, return answer String
- json(...), json_format(format, ...) → parse JSON outputs

Structured iteration:
- iterate(prompt=nil) { |item| ... } — endpoint :responses, expects {content: [String]}
- iterate_dictionary(prompt=nil) { |k,v| ... } — endpoint :responses, expects arbitrary object of string values

System prompt (internal):
- system_prompt / prompt — build a combined system message injecting KB database descriptions if knowledge_base present.

Utilities:
- self.load_from_path(path) → Agent

---

## CLI: scout agent commands

The scout command resolves subcommands by scanning “scout_commands/**” paths using the Path subsystem, so packages and workflows can add their own. If you target a directory instead of a script, a listing of subcommands is shown.

Two commands are provided by scout-ai:

- Agent ask
  - scout agent ask [options] [agent_name] [question]
    - Options:
      - -l|--log <level> — set log severity.
      - -t|--template <file_or_key> — use a prompt template; positional question replaces '???' if present.
      - -c|--chat <chat_file> — load/extend a conversation file; appends new messages to it.
      - -m|--model, -e|--endpoint — backend/model selection (merged with per-endpoint config at Scout.etc.AI).
      - -f|--file <path> — include file content at the start (or substitute where “...” appears in the question).
      - -wt|--workflow_tasks <names> — limit exported workflow tasks for this agent call.
    - Resolution:
      - agent_name is resolved via Scout.workflows[agent_name] (a workflow) or Scout.chats[agent_name] (an agent directory with workflow.rb/knowledge_base/start_chat). The Path subsystem handles discovery across packages.
    - Behavior:
      - If --chat is given, the conversation is expanded (LLM.chat) and the new model output is appended (Chat.print).
      - Supports inline file Q&A mode (not typical for agent ask).

- Agent KnowledgeBase passthrough
  - scout agent kb <agent_name> <kb subcommand...>
    - Loads the agent’s knowledge base (agent_dir/knowledge_base) and forwards to “scout kb …” with --knowledge_base prefilled (and current Log level).
    - Useful to manage the KB tied to an agent from the CLI.

Command resolution:
- The bin/scout dispatcher walks nested directories (e.g., “agent/kb”) and lists available scripts when a directory is targeted.

---

## Examples

Minimal conversation with an Agent (tests)
```ruby
a = LLM::Agent.new
a.start_chat.system 'you are a robot'
a.user "hi"
puts a.print
```

Register and run a simple workflow tool call
```ruby
m = Module.new do
  extend Workflow
  self.name = "Registration"
  input :name, :string
  input :age, :integer
  input :gender, :select, nil, :select_options => %w(male female)
  task :person => :yaml do
    inputs.to_hash
  end
end

puts LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male, using a tool call",
                      backend: 'ollama', model: 'llama3')
# Or equivalently through an Agent:
agent = LLM::Agent.new workflow: m, backend: 'ollama', model: 'llama3'
puts agent.ask "Register Eduard Smith, a 25 yo male, using a tool call to the tool provided"
```

Knowledge base reasoning with an Agent (tests pattern)
```ruby
TmpFile.with_dir do |dir|
  kb = KnowledgeBase.new dir
  kb.format = {"Person" => "Alias"}
  kb.register :brothers, datafile_test(:person).brothers, undirected: true
  kb.register :marriages, datafile_test(:person).marriages, undirected: true, source: "=>Alias", target: "=>Alias"
  kb.register :parents, datafile_test(:person).parents

  agent = LLM::Agent.new knowledge_base: kb
  puts agent.ask "Who is Miki's brother in law?"
end
```

Iterate structured results
```ruby
agent = LLM::Agent.new
agent.iterate("List three steps to bake bread") do |step|
  puts "- #{step}"
end
```

---

Agent gives you a stateful, tool‑aware façade over LLM.ask and Chat, so you can build conversational applications that call Workflows and explore KnowledgeBases with minimal ceremony—both from Ruby APIs and via the scout command-line.