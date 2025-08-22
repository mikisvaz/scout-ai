# LLM

LLM is a compact, extensible layer to interact with Large Language Models (LLMs) and Agentic workflows in Scout. It provides:

- A high-level ask function with pluggable backends (OpenAI-style, Responses, Ollama, OpenWebUI, AWS Bedrock, and a simple Relay).
- A chat/message DSL that parses conversational files or inline text, supporting imports, files, tasks/jobs, and tool wiring.
- First-class tool use: define tools from Workflow tasks or KnowledgeBase queries and let models call them functionally.
- An Agent wrapper that maintains chat context, injects Workflow and KnowledgeBase tools, and provides JSON/iteration helpers.
- Embedding and a tiny RAG helper.
- A set of command-line tools (scout llm … and scout agent …) for interactive and batch usage.

Sections:
- Core API overview
- Message and Chat DSL
- ask function (multi-backend)
- Backends
- Tools and function calling
- Agent (LLM::Agent)
- Embeddings and RAG
- Parse/Utils helpers
- CLI (scout llm, scout agent, documenter)
- Examples

---

## Core API overview

Top‑level entry points:
- LLM.ask(question, options={}, &block) → String or messages
  - Parse question into a structured chat, enrich with options from chat (endpoint/model/format), run the chosen backend, return the assistant output.
  - Tool calling supported via the block (see Tools section).
- LLM.embed(text, options={}) → embedding Array (per backend).
- LLM.messages(text_or_messages, role=nil) → normalized messages Array.
- LLM.chat(file_or_text_or_messages) → messages Array after applying imports, tasks/jobs, files, options, etc.
- LLM.print(messages) → human‑readable chat file serialization.

Auxiliary:
- LLM.workflow_ask(workflow, question, options={}) — ask with tools exported from a Workflow; block triggers workflow jobs.
- LLM.knowledge_base_ask(kb, question, options={}) — ask with KB traversal tool(s); block returns associations (children).

Agent wrapper:
- LLM::Agent — maintains a current Chat, injects tools (workflow, knowledge base), and provides chat, json, iterate helpers.

---

## Message and Chat DSL

LLM can parse either:
- Free-form text in a “chat file” style, or
- Explicit arrays of message hashes ({role:, content:}).

Parsing (LLM.messages and LLM.parse):
- Role headers “role:” mark segments (system:, user:, assistant:, etc.).
- Protected blocks:
  - Triple backticks ```…``` are preserved inside a single message.
  - [[ … ]] structured blocks support actions:
    - cmd TITLE? then content → tag a file with captured command output (via CMD.cmd).
    - file TITLE? then a file path → tag with file contents.
    - directory TITLE? then a directory → inline all files beneath recursively as <file> tags.
    - import TITLE? → handled at LLM.chat level.
- XML-style tags are preserved as protected content.

Chat loader (LLM.chat):
- Accepts:
  - Path to a chat file,
  - Inline text,
  - An Array of messages.
- Expands in order:
  1) imports — role: import / continue loads referenced chats and inlines their messages (continue appends last).
  2) clear — role: clear prunes any messages before it (except previous_response_id).
  3) clean — removes empty/skip lines.
  4) tasks — role: task or inline_task turns “Workflow task input-options” into a produced job (via Workflow.produce), replacing with job/tool messages.
  5) jobs — role: job/inline_job transforms a saved job result into a function_call + tool output pair or inlined result file.
  6) files — role: file or directory inlines files as tagged content.

Options in chat (LLM.options):
- Scans chat messages to collect transient options:
  - endpoint, model, backend, persist, format (JSON schema or :json): role lines that set settings.
  - previous_response_id is “strong” and kept across assistant replies.
  - option lines (role: option) allow free‑form key value.

Printing (LLM.print):
- Pretty‑prints a messages array back to a chat-like text (handy for saving updated conversations).

Chat module (Chat):
- Lightweight builder over an Array with Annotation. Provides:
  - message(role, content), user/system/assistant/import/file/directory/continue/format/tool/task/inline_task/job/inline_job/association.
  - option(:key, value), endpoint(value), model(value), image(file).
  - tag(content, name=nil, tag=:file, role=:user) → wrap as <file>…</file>.
  - ask/respond/chat/json/json_format, print/save/write/write_answer, branch/shed, answer.

Example: building a chat and printing
```ruby
a = LLM::Agent.new
a.start_chat.system 'you are a robot'
a.user "hi"
puts a.print
```

---

## ask function

LLM.ask(question, options={}, &block):
- question:
  - String (free text or filename) or messages Array.
  - Internally normalized via LLM.chat (expands imports/tasks/files).
- options:
  - endpoint — selects endpoint presets (Scout.etc.AI[endpoint].yaml merged as defaults).
  - backend — one of: :openai, :responses, :ollama, :openwebui, :bedrock, :relay. Defaults per Scout::Config (ASK_BACKEND/LLM_BACKEND).
  - model — backend‑specific model ID (e.g., gpt‑4.1, mistral).
  - persist — default true; responses are cached with Persist.persist keyed by endpoint+messages+options.
  - format — request JSON or schema‑based outputs (backend dependent).
  - return_messages — when true, returns an array of messages (including tool call outputs) rather than just the content.
  - Additional backend‑specific keys (e.g., tool_choice, previous_response_id, websearch).

- Tool calling:
  - If you pass a block, it is invoked for each function call the model asks to perform:
    - block.call(name, parameters_hash) → result
    - The result is serialized back into a “tool” message for the model to continue.

- workflow_ask / knowledge_base_ask:
  - Prepares tools automatically (Workflow tasks or KB traversal), and supplies an appropriate block.

Example (OpenAI backend, JSON output)
```ruby
prompt = <<~EOF
system:

Respond in json format with a hash of strings as keys and string arrays as values, at most three in length

user:

What other movies have the protagonists of the original gost busters played on, just the top.
EOF

LLM.ask prompt, format: :json
```

---

## Backends

All backends share the block‑based tool calling contract and honor options extracted from the chat (endpoint/model/format/etc.).

Common configuration:
- Per endpoint defaults can be stored under Scout.etc.AI[endpoint].yaml.
- Env/config helpers are used for URLs/keys (LLM.get_url_config and Scout::Config.get).

1) OpenAI (LLM::OpenAI)
- client: Object::OpenAI::Client (supports uri_base for Azure-compatible setups).
- process_input filters out unsupported image role (use :responses for images).
- tools: converted via LLM.tools_to_openai.
- format: response_format {type: 'json_object'} for JSON or other formats.
- Embedding: LLM::OpenAI.embed(text, model: …).
- Example tool calls (from tests):
  - Provide tools array (OpenAI schema). The block returns a result string; ask loops until tools exhausted.

2) Responses (LLM::Responses)
- Designed for OpenAI Responses API (multimodal):
  - Supports images (role: image file → base64) and PDFs (role: pdf file).
  - websearch opt: adds a 'web_search_preview' tool.
  - Tool message marshalling via tools_to_responses/process_input/process_response.
- Handles previous_response_id to continue a session.
- Image creation: Responses.image with messages → client.images.generate.

3) Ollama (LLM::OLlama)
- Local models via Ollama server (defaults to http://localhost:11434).
- Converts tools via tools_to_ollama.
- ask returns last message content or messages when return_messages.
- embed uses /api/embed.

4) OpenWebUI (LLM::OpenWebUI)
- REST wrapper to chat/completions endpoint on OpenWebUI‑compatible servers.
- Note: focuses on completions; tool loops example stubbed.

5) Bedrock (LLM::Bedrock)
- AWS Bedrock Runtime client. Supports:
  - type: :messages or :prompt modes.
  - model options via model: {model:'…', …}.
- Tool call loop: inspects message['content'] for tool_calls, and re‑invokes with augmented messages.
- Embeddings via titan embed endpoint by default.

6) Relay (LLM::Relay)
- Minimal “scp file, poll for reply” relay:
  - LLM::Relay.ask(question, server: 'host') → uploads JSON to server’s ~/.scout/var/ask/, waits for reply JSON.

---

## Tools and function calling

Define tools from Workflows or KnowledgeBase and use them with LLMs that support function calling.

- LLM.task_tool_definition(workflow, task, inputs=nil) → OpenAI-like tool schema.
- LLM.workflow_tools(workflow) → list of exportable task schemas for the workflow.
- LLM.knowledge_base_tool_definition(kb) → a single tool “children” with database/entity parameters (KB traversal).
- LLM.association_tool_definition(name) → generic association tool (source~target edges).

- In chats:
  - role: tool lines (e.g., “tool: Baking bake_muffin_tray”) register tasks as callable tools.
  - role: association lines register KB databases dynamically (path + options like undirected/source/target) and expose KB lookups.

- The block passed to LLM.ask(name, params) receives function name and parameters and returns a value:
  - String → used as tool output content.
  - Any Object → serialized as JSON for content.
  - Exception → serialized exception + backtrace.

Examples:
```ruby
# Using a tool to bake muffins
question = <<~EOF
user:
Use the provided tool to learn the instructions of baking a tray of muffins.
tool: Baking bake_muffin_tray
EOF

LLM.ask question
```

Knowledge base traversal:
```ruby
TmpFile.with_dir do |dir|
  kb = KnowledgeBase.new dir
  kb.register :brothers, datafile_test(:person).brothers, undirected: true
  kb.register :parents,  datafile_test(:person).parents
  LLM.knowledge_base_ask(kb, "Who is Miki's brother in law?")
end
```

---

## Agent (LLM::Agent)

An Agent is a thin orchestrator that:
- Keeps a current chat (Chat.setup []),
- Injects system content (including KnowledgeBase markdown overview),
- Automatically exports Workflow tasks and KnowledgeBase traversal as tools,
- Forwards prompts to LLM.ask with configured defaults.

Constructor:
- LLM::Agent.new(workflow: nil|Module or String name, knowledge_base: kb=nil, start_chat: messages=nil, **other_options)
  - If workflow is a String, Workflow.require_workflow is called.

Methods:
- start_chat → initializes an empty chat (Chat.setup []).
- start(chat=nil) → start new branch or adopt provided chat/messages.
- current_chat → returns the active chat; method_missing forwards Chat DSL methods (user/system/tool/task/etc.).
- ask(messages, model=nil, options={}) → calls LLM.ask with tools+options; internal block dispatch:
  - 'children' → KB.children(db, entities)
  - other function names → calls Workflow job run/exec based on workflow.exec_exports.
- chat(model=nil, options={}) → ask with return_messages: true, append assistant reply to chat, return content.
- json, json_format(format, …) → set format and parse JSON outputs into Ruby objects.
- iterate(prompt=nil) { |item| … } → ask with a JSON schema requesting an array 'content', iterate through items; then resets format to text.
- iterate_dictionary(prompt=nil) { |k,v| … } → ask with object schema with arbitrary string values.

Agent loader:
- LLM::Agent.load_from_path(path) expects:
  - path/workflow.rb → Require a workflow.
  - path/knowledge_base → Initialize a KB from path.
  - path/start_chat → A chat file to bootstrap conversation.

Example (tests)
```ruby
m = Module.new do
  extend Workflow
  self.name = "Registration"
  input :name, :string
  input :age, :integer
  input :gender, :select, nil, :select_options => %w(male female)
  task :person => :yaml do inputs.to_hash end
end

LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male, using a tool call",
                 backend: 'ollama', model: 'llama3')
```

---

## Embeddings and RAG

Embeddings:
- LLM.embed(text, options={}) → Vector
  - Selects backend via options[:backend] or ENV/Config.
  - Supports openai, ollama, openwebui, relay (bedrock embeds via LLM::Bedrock.embed directly).
  - If text is an Array, returns array of vectors per backend convention (Ollama returns arrays).

Simple RAG index:
- LLM::RAG.index(data) → Hnswlib::HierarchicalNSW index
  - data: array of embedding vectors.
  - Example:
    ```ruby
    data = [ LLM.embed("Crime, Killing and Theft."),
             LLM.embed("Murder, felony and violence"),
             LLM.embed("Puppies, cats and flowers") ]
    i = LLM::RAG.index(data)
    nodes, _ = i.search_knn LLM.embed('I love the zoo'), 1
    # => 2 (closest to “Puppies, cats and flowers”)
    ```

---

## Parse/Utils helpers

- LLM.parse(question, role=nil) — split text into role messages and preserve protected blocks.
- LLM.tag(tag, content, name=nil) — build an XML‑like tagged snippet (used by Chat#tag).
- LLM.get_url_server_tokens(url, prefix=nil) — token expansion helper for config.
- LLM.get_url_config(key, url=nil, *tokens) — layered config lookup using URL tokens and namespaces.

---

## Command Line Interface

The scout command locates scripts by path fragments (scout_commands/…), showing directory listings when the fragment maps to a directory. Scripts use SOPT for options parsing.

LLM-related commands installed by scout-ai:

- Ask an LLM
  - scout llm ask [options] [question]
    - Options:
      - -t|--template <file_or_key> — load a prompt template; if it contains “???”, question is substituted.
      - -c|--chat <chat_file> — load/extend a chat; append model reply to the file.
      - -i|--inline <file> — answer questions embedded as “# ask: …” comments inside a file; inject responses inline between “# Response start/end”.
      - -f|--file <file> — prepend file contents, or use “...” in question to insert STDIN/file content in place.
      - -m|--model, -e|--endpoint, -b|--backend — backend selection; options are merged with per-endpoint config (Scout.etc.AI).
      - -d|--dry_run — print the fully expanded conversation (LLM.print) and exit without asking.
    - Behavior:
      - If chat is given, the conversation is expanded via LLM.chat(chat) and new messages appended to the file.
      - If inline is given, scans the file for ask directives and writes responses inline.
      - Otherwise prints the model’s answer.

- Agent ask (agent awareness: workflow + knowledge base)
  - scout agent ask [options] [agent_name] [question]
    - agent_name resolves via Scout.workflows[agent_name] or Scout.chats[agent_name] (Path subsystem).
    - Same flags as llm ask; additionally:
      - -wt|--workflow_tasks <tasks> — export selected tasks to the agent as tools.
    - The script loads the agent via a workflow.rb or a whole agent directory (workflow.rb, knowledge_base, start_chat). The agent is used to ask the question and append to chat if requested.

- Agent KnowledgeBase passthrough:
  - scout agent kb <agent_name> <kb_subcommand...>
    - Utility to run knowledge base CLI with the agent’s preconfigured kb (sets --knowledge_base to agent_dir/knowledge_base).

- LLm relay processor (for Relay backend)
  - scout llm process [directory]
    - Watches a directory (defaults to ~/.scout/var/ask) for queued ask JSON files, runs them, writes replies under reply/.

- LLM server (simple chat web UI)
  - scout llm server
    - Starts a small Sinatra server serving a static chat UI and a JSON API to list/load/save/run chat files under ./chats.
    - Endpoints: GET /, /chat.js, /list, /load, POST /save, POST /run, GET /ping.

- List templates
  - scout llm template
    - Lists templates found under Scout.questions.

- Documentation builder (meta)
  - scout-ai documenter <topic>
    - An internal documentation tool that scans source/tests for topic modules and uses an LLM agent to generate markdown docs.

CLI discovery:
- The scout command resolves fragments to files under scout_commands (including other packages/workflows).
- E.g., “scout llm” shows available subcommands; “scout agent” lists agent commands.

---

## Examples

Ask with OpenAI, tool calls:
```ruby
prompt = <<~EOF
user:
What is the weather in London. Should I take my umbrella?
EOF

tools = [
  {
    "type": "function",
    "function": {
      "name": "get_current_temperature",
      "description": "Get the current temperature and raining conditions for a specific location",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {"type": "string"},
          "unit": {"type": "string", "enum": ["Celsius","Fahrenheit"]}
        },
        "required": ["location","unit"]
      }
    }
  },
]
LLM::OpenAI.ask prompt, tool_choice: 'required', tools: tools, model: "gpt-4.1-mini" do |name, args|
  "It's 15 degrees and raining."
end
```

Ask with Responses (images, PDF)
```ruby
prompt = <<~EOF
image: #{datafile_test 'cat.jpg'}

user:
What animal is represented in the image?
EOF

LLM::Responses.ask prompt
```

Use a Workflow tool from chat:
```ruby
question = <<~EOF
user:

Use the provided tool to learn the instructions of baking a tray of muffins.
tool: Baking bake_muffin_tray
EOF

LLM.ask question
```

Agent with Workflow tool-calling:
```ruby
m = Module.new do
  extend Workflow
  self.name = "Registration"
  input :name, :string
  input :age, :integer
  input :gender, :select, nil, select_options: %w(male female)
  task :person => :yaml do inputs.to_hash end
end
LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male",
                 backend: 'ollama', model: 'llama3')
```

RAG:
```ruby
data = [ LLM.embed("Crime, Killing and Theft."),
         LLM.embed("Murder, felony and violence"),
         LLM.embed("Puppies, cats and flowers") ]
idx = LLM::RAG.index(data)
nodes, scores = idx.search_knn LLM.embed('I love the zoo'), 1
# => nodes.first == 2
```

---

LLM integrates chat parsing, tool wiring, multiple model backends, and agentic orchestration in a compact API. Use chat files (or the Chat builder) to define conversations and tools declaratively, pick a backend with a single option, and compose model calls with Workflow/KnowledgeBase tools for powerful, reproducible automations.