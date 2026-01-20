Agent

Agent is a thin, stateful façade over the LLM and Chat systems that:
- Maintains a live conversation (Chat) and forwards the Chat DSL (user/system/file/…)
- Automatically exposes Workflow tasks and KnowledgeBase queries as callable tools
- Centralizes backend/model/endpoint defaults for repeated asks
- Provides convenience helpers for structured outputs (JSON schema, iteration)
- Provides a simple way to delegate work to other Agent instances

The Agent API makes it convenient to build conversational applications that call registered Workflow tasks, query a KnowledgeBase, include files/images/pdfs in the conversation, and iterate over structured outputs.

Sections:
- Quick start
- Conversation lifecycle (start_chat / start / current_chat)
- Including files, images, PDFs in a chat
- Tools and automatic wiring (Workflow and KnowledgeBase)
- Delegation (handing a message to another Agent)
- Asking, chatting and structured outputs (json/json_format/iterate)
- Loading an Agent from a directory
- API reference

---

Quick start

Create an Agent and run a simple conversation

```ruby
agent = LLM::Agent.new
agent.start_chat.system 'You are a helpful assistant'
agent.user 'Hi'
puts agent.print  # forwarded to Chat#print
```

You can also use the convenience factory:

```ruby
agent = LLM.agent(endpoint: 'ollama', model: 'llama3')
```

Conversation lifecycle and state

- start_chat
  - A Chat instance that is used as the immutable base for new conversation branches. Use start_chat to seed messages that should always be present (policy, examples, templates).
  - Messages added to start_chat are preserved across calls to start (they form the base).

- start(chat = nil)
  - With no argument: branches the start_chat and makes the branch the current conversation (non-destructive copy).
  - With a Chat/message array: adopts the provided chat (annotating it if necessary) and sets it as current.

- current_chat
  - Returns the active Chat (created via start when needed).

Forwarding and Chat DSL

Agent forwards unknown method calls to the current_chat (method_missing), so you can use the Chat DSL directly on an Agent:

```ruby
agent.user "Please evaluate this sample"
agent.system "You are a domain expert"
agent.file "paper.md"   # expands the file contents into the chat (see files handling below)
agent.pdf "/path/to/figure.pdf"
agent.image "/path/to/figure.png"
```

Including files, PDFs and images in a chat

The Chat DSL supports roles for file, pdf, image and directory. The behaviours are:
- file: the contents of the file are read and inserted into the chat wrapped in a <file>...</file> tag
- directory: expands to a list of files and inserts each file as above
- pdf / image: the message content is replaced with a Path (the file is not inlined). These message roles are left for backends that support uploading files (LLM backends may upload them when supported)

Example (from the project examples):

```ruby
agent.start_chat.system <<-EOF
You are a technician working in a molecular biology laboratory...
EOF

agent.start_chat.user "The following files are from a bad sequence"
agent.start_chat.pdf bad_sequence_pdf_path
agent.start_chat.image bad_sequence_png_path
```

Tool wiring (Workflow and KnowledgeBase)

When you call Agent#ask / Agent#chat and the Agent has a Workflow or KnowledgeBase, the Agent will automatically expose those as "tools" to the model.

- Workflow: LLM.workflow_tools(workflow) is called and produces a tool (function) definition for each exported task. The model may call these functions and the Agent (via LLM.ask internal wiring) will execute the corresponding workflow.job(task_name, ...) via LLM.call_workflow.

- KnowledgeBase: LLM.knowledge_base_tool_definition(kb) produces one tool per registered database and optionally a *_association_details tool when the database has fields. Calls to those functions invoke LLM.call_knowledge_base which returns associations or association details.

How tools are merged:
- The Agent stores default call options in @other_options (constructor kwargs). If @other_options[:tools] are present they are merged with any tools injected from workflow/knowledge_base and with any tools passed explicitly to ask() via options[:tools].

Agent#ask(messages, options = {})
- messages may be a Chat, an Array of messages, or a single string (converted to messages via the LLM.chat parsing helpers).
- options are merged with @other_options and passed to LLM.ask. If workflow or knowledge_base are present, their tools are merged into options[:tools].
- Exceptions raised during ask are routed through process_exception if set: if process_exception is a Proc it is called with the exception and may return truthy to retry.

Delegation (handing messages to other Agent instances)

Agent#delegate(agent, name, description, &block)
- Adds a tool named "hand_off_to_<name>" to the Agent's tools. When the model calls that tool the provided block will be executed.
- If no block is given, a default block is installed which:
  - logs the delegation
  - if parameters[:new_conversation] is truthy, calls agent.start to create/clear the delegated agent conversation, otherwise calls agent.purge
  - appends the message (parameters[:message]) as a user message to the delegated agent and runs agent.chat to get its response
- The function schema for delegation expects:
  - message: string (required)
  - new_conversation: boolean (default: false)

Example (from multi_agent.rb):

```ruby
joker = LLM.agent endpoint: :mav
joker.start_chat.system 'You only answer with knock knock jokes'

judge = LLM.agent endpoint: :nano, text_verbosity: :low, format: {judgement: :boolean}
judge.start_chat.system 'Tell me if a joke is funny. Be a hard audience.'

supervisor = LLM.agent endpoint: :nano
supervisor.start_chat.system 'If you are asked a joke, send it to the joke agent. To see if it\'s funny ask the judge.'

supervisor.delegate joker, :joker, 'Use this agent for jokes'
supervisor.delegate judge, :judge, 'Use this agent for testing if the jokes land or not'

supervisor.user <<-EOF
Ask the joke agent for jokes and ask the judge to evaluate them, repeat until the judge is satisfied or 5 attempts
EOF
```

Asking, responding and structured outputs

- ask(messages, options = {})
  - Low level: calls LLM.ask with the Agent defaults merged. Returns the assistant content string (or raw messages when return_messages: true is used).

- respond(...) → ask(current_chat, ...)
  - Convenience to ask the model using the current chat.

- chat(options = {})
  - Calls ask(current_chat, return_messages: true). If the response is an Array of messages, it concatenates them onto current_chat and returns current_chat.answer (the assistant message). If the response is a simple string it pushes that as an assistant message and returns it.

- json(...)
  - Sets the current chat format to :json, runs ask(...) and parses the returned JSON. If the top-level parsed object is a Hash with only the key "content" it returns that inner value.

- json_format(format_hash, ...)
  - Similar but sets the chat format using a provided JSON schema (format_hash) instead of the generic :json shorthand.

- get_previous_response_id
  - Utility to find a prior message with role :previous_response_id and return its content (if present).

Iterate helpers

Agent provides helpers to request responses constrained by a JSON schema and iterate over the returned items:

- iterate(prompt = nil){ |item| ... }
  - Sets endpoint :responses (intended for the Responses backend), optionally appends the prompt as a user message, then requests a JSON object with schema {content: [string,...]}. The helper resets format back to :text and yields each item of the returned content array.

- iterate_dictionary(prompt = nil){ |k,v| ... }
  - Similar but requests an arbitrary object whose values are strings (additionalProperties: {type: :string}). Yields each key/value pair.

These helpers are convenient for model outputs that should be returned as a structured list/dictionary and handled item-by-item in Ruby.

File and chat processing behaviour

Chat processing includes several convenient behaviours when a Chat is expanded prior to sending to a backend:
- import / continue / last: include the contents of other chat files (useful to compose long prompts or templates)
- file / directory: inline file contents in a tagged <file> block or expand directories into multiple file blocks
- pdf / image: keep a message whose content is the Path to the file; some backends will upload these to the model (behaviour depends on backend)

Loading an Agent from a directory

- LLM::Agent.load_from_path(path)
  - path is a Path-like object representing a directory that may contain:
    - workflow.rb — a Workflow definition (optional)
    - knowledge_base — a KnowledgeBase directory (optional)
    - start_chat — a Chat file to seed the agent (optional)
  - Returns a configured Agent instance with those components loaded.

API reference (high-level)

- LLM.agent(...) → convenience factory for LLM::Agent.new(...)
- LLM::Agent.new(workflow: nil|String|Module, knowledge_base: nil, start_chat: nil, **kwargs)
  - kwargs are stored under @other_options and merged into calls to LLM.ask (e.g., backend:, model:, endpoint:, log_errors:, tools: etc.)

- start_chat → Chat (the immutable base messages for new conversations)
- start(chat=nil) → Chat (branch or adopt provided chat)
- current_chat → Chat (active conversation)

- ask(messages, options = {}) → String or messages (if return_messages: true)
- respond(...) → ask(current_chat, ...)
- chat(options = {}) → append assistant output to current_chat and return it
- json(...), json_format(format_hash, ...) → parse JSON outputs and return Ruby objects
- iterate(prompt = nil) { |item| ... } — use Responses-like backend and expected schema {content: [string]}
- iterate_dictionary(prompt = nil) { |k,v| ... } — expected schema {<key>: string}
- delegate(agent, name, description, &block) — add a hand_off_to_* tool that forwards a message to another Agent

Notes and caveats

- Tools are represented internally as values in @other_options[:tools] and have the form {name => [object_or_handler, function_definition]}. The Agent injects Workflow and KnowledgeBase tools automatically when present.
- Backends differ in how they handle file/pdf/image uploads — some backends support uploading and special message role handling, others do not. When you add pdf/image messages to the chat the Chat processing step replaces the content with a Path object; whether the endpoint uploads the file is backend dependent.
- Errors raised while calling LLM.ask are handled by the Agent#process_exception hook if you set it to a Proc. If the Proc returns truthy the ask is retried; otherwise the exception is raised.

Examples

Minimal conversation
```ruby
agent = LLM::Agent.new
agent.start_chat.system 'You are a bot'
agent.start
agent.user 'Tell me a joke'
puts agent.chat
```

Workflow tool example

```ruby
m = Module.new do
  extend Workflow
  self.name = 'Registration'
  input :name, :string
  input :age, :integer
  input :gender, :select, nil, select_options: %w(male female)
  task :person => :yaml do
    inputs.to_hash
  end
end

agent = LLM::Agent.new workflow: m, backend: 'ollama', model: 'llama3'
agent.ask 'Register Eduard Smith, a 25 yo male, using a tool call'
```

Delegation example (see multi_agent.rb in the repo)

```ruby
supervisor = LLM.agent
supervisor.delegate joker_agent, :joker, 'Use this agent for jokes'
# The model can then call the hand_off_to_joker function and the delegate block
# will forward the message to joker_agent.
```

Command-line integration

The scout CLI provides commands that work with Agent directories and workflows (scout agent ask, scout agent kb ...). The CLI resolves agent directories via the Path subsystem and can load workflow.rb / knowledge_base / start_chat automatically.

---

Agent gives you a stateful, tool-aware façade over LLM.ask and Chat so you can build conversational applications that call Workflows and explore KnowledgeBases with minimal ceremony—both from Ruby APIs and via the scout command-line.
