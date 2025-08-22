# scout-ai

Agentic AI and machine‑learning for Scout: a compact layer to train/evaluate models (Ruby, Python/PyTorch, Hugging Face), talk to LLMs across multiple backends, wire Workflow tasks as tools, and build persistent, declarative conversations and agents.

This package sits on top of the Scout stack:

- scout-essentials — low level functionality (Open, TSV, Persist, Path, ConcurrentStream, Log, etc.)
- scout-gear — core data modules (TSV, KnowledgeBase, Entity, Association, Workflow, WorkQueue, etc.)
- scout-rig — language bridges (notably Python via PyCall)
- scout-camp — remote servers, cloud deployments, web interfaces
- scout-ai — LLMs, agents and model wrappers (this repository)

All packages are available under github.com/mikisvaz:
- https://github.com/mikisvaz/scout-essentials
- https://github.com/mikisvaz/scout-gear
- https://github.com/mikisvaz/scout-rig
- https://github.com/mikisvaz/scout-camp
- https://github.com/mikisvaz/scout-ai

Scout originates from the Rbbt ecosystem (bioinformatics workflows). Numerous end‑to‑end examples live in the Rbbt‑Workflows organization:
- https://github.com/Rbbt-Workflows

The sections below summarize the main components (LLM, Chat, Agent, Model), quick starts, and the command‑line interface. For full APIs, see the doc/ directory.

- doc/LLM.md — multi‑backend LLM orchestration, tool calling, embeddings
- doc/Chat.md — conversation builder/serializer
- doc/Agent.md — stateful agents wired to Workflows and KnowledgeBases
- doc/Model.md — model wrappers (ScoutModel, Python/Torch/Hugging Face)


## Installation and requirements

Scout is a Ruby framework. Add scout-ai (and the other packages you need) to your project and require as needed.

- Ruby 3.x recommended
- For Python‑backed models (Torch/Hugging Face):
  - Python 3 (installed and visible in PATH)
  - pycall gem (Ruby ↔ Python bridge)
  - Python packages: torch, transformers, numpy, pandas (as needed)
- For OpenAI or similar backends: set API keys in environment or config (see LLM backend docs)

Typical Gemfile fragment:
```ruby
gem 'scout-essentials', git: 'https://github.com/mikisvaz/scout-essentials'
gem 'scout-gear',       git: 'https://github.com/mikisvaz/scout-gear'
gem 'scout-rig',        git: 'https://github.com/mikisvaz/scout-rig'
gem 'scout-ai',         git: 'https://github.com/mikisvaz/scout-ai'
```

Backends and endpoints can be configured under Scout.etc.AI/<endpoint>.yaml (merged into asks), or via environment variables per backend (see doc/LLM.md).


## Quick starts

### Ask a model

```ruby
require 'scout-ai'
answer = LLM.ask "What is the capital of France?", backend: :openai, model: "gpt-4.1-mini"
puts answer
```

Chat builder:

```ruby
chat = Chat.setup []
chat.system "You are a terse assistant"
chat.user   "List three colors"
puts chat.ask
```

### Tool calling with a Workflow

Export Workflow tasks as callable tools—let the model call them functionally.

```ruby
require 'scout-gear'  # defines Workflow

m = Module.new do
  extend Workflow
  self.name = "Registration"

  input :name, :string
  input :age, :integer
  input :gender, :select, nil, select_options: %w(male female)
  task :person => :yaml do inputs.to_hash end
end

puts LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male, using a tool call",
                      backend: 'ollama', model: 'llama3')
```

### Stateful agent with a KnowledgeBase

```ruby
require 'scout-gear'  # defines KnowledgeBase

TmpFile.with_dir do |dir|
  kb = KnowledgeBase.new dir
  kb.register :brothers, datafile_test(:person).brothers, undirected: true
  kb.register :marriages, datafile_test(:person).marriages,
             undirected: true, source: "=>Alias", target: "=>Alias"
  kb.register :parents, datafile_test(:person).parents

  agent = LLM::Agent.new knowledge_base: kb
  puts agent.ask "Who is Miki's brother in law?"
end
```

### Structured iteration

```ruby
agent = LLM::Agent.new
agent.iterate("List three steps to bake bread") { |step| puts "- #{step}" }

agent.iterate_dictionary("Give capital cities for FR, ES, IT") do |country, capital|
  puts "#{country}: #{capital}"
end
```

### Use a Hugging Face classifier inside a Workflow

From the ExTRI2 workflow (see below):

```ruby
model = HuggingfaceModel.new 'SequenceClassification', tri_model_dir, nil,
  tokenizer_args: { model_max_length: 512, truncation: true },
  return_logits: true

model.extract_features do |_, rows|
  rows.map do |text, tf, tg|
    text.sub("[TF]", "<TF>#{tf}</TF>").sub("[TG]", "<TG>#{tg}</TG>")
  end
end

model.init
preds = model.eval_list tsv.slice(%w(Text TF Gene)).values
tsv.add_field "Valid score" do
  non_valid, valid = preds.shift
  Misc.softmax([valid, non_valid]).first rescue 0
end
```


## Components overview

### LLM (doc/LLM.md)

A compact, multi‑backend layer to ask LLMs, wire function‑calling tools, parse/print chats, and compute embeddings.

- ask(question, options={}, &block) — normalize a question to messages (LLM.chat), merge endpoint/model/format, run backend, and return assistant output (or messages with return_messages: true)
- Backends: OpenAI‑style, Responses (multimodal, JSON schema), Ollama, OpenWebUI, AWS Bedrock, and a simple Relay
- Tools: export Workflow tasks (LLM.workflow_tools) and KnowledgeBase lookups; tool calls are handled via a block
- Embeddings and a tiny RAG helper
- Chat/print pipeline: imports, clean, tasks/jobs as function calls, files/directories as tagged content
- Configuration: endpoint defaults in Scout.etc.AI/endpoint.yaml are merged into options automatically

### Chat (doc/Chat.md)

A lightweight builder over an Array of {role:, content:} messages with helpers:

- user/system/assistant, file/directory tagging, import/continue
- tool/workflow task declarations, jobs/inline jobs
- association declarations (KnowledgeBase)
- option, endpoint, model, format (including JSON schema requests)
- ask, chat, json/json_format, print/save/write/write_answer, branch/shed

Use Chat to author “chat files” on disk or build conversations programmatically.

### Agent (doc/Agent.md)

A thin orchestrator around Chat and LLM that keeps state and injects tools:

- Maintains a live conversation (start_chat, start, current_chat)
- Auto‑exports Workflow tasks and a KnowledgeBase traversal tool
- ask/chat/json/iterate helpers; structured iteration over lists/dictionaries
- load_from_path(dir) — bootstrap from a directory containing workflow.rb, knowledge_base, start_chat

### Model (doc/Model.md)

A composable framework to wrap models with a consistent API:

- ScoutModel — base: define init/eval/eval_list/extract_features/post_process/train; persist behavior and state to a directory
- PythonModel — initialize and drive a Python class via ScoutPython
- TorchModel — helpers for PyTorch: training loop, tensors, save/load state, layer introspection
- HuggingfaceModel — Transformers convenience; specializations:
  - SequenceClassificationModel — text classification, logits→labels
  - CausalModel — chat/causal generation (supports apply_chat_template)
  - NextTokenModel — simple next‑token fine‑tuning loop

Pattern:
- Keep feature extraction separate from evaluation
- Use eval_list to batch large tables
- Persist directory state and behavior to reuse


## Example: ExTRI2 workflow (models in practice)

The ExTRI2 Workflow (Rbbt‑Workflows) uses HuggingfaceModel to score TRI sentences and determine Mode of Regulation (MoR):

- Feature extraction marks [TF]/[TG] spans as inline tags for the model
- Batch evaluation over a TSV (“Text”, “TF”, “Gene” columns)
- Adds fields “Valid score” and “Valid” to the TSV
- Runs a second SequenceClassification model to produce “MoR” and “MoR scores”

See workflows/ExTRI2/workflow.rb in that repository for the full implementation.


## Command‑Line Interface

The bin/scout dispatcher locates scripts under scout_commands across installed packages and workflows using the Path subsystem. Resolution works by adding terms until a file is found to execute:

- If the fragment maps to a directory, a listing of available subcommands is shown
- Scripts can be nested arbitrarily (e.g., agent/kb)
- Other packages or workflows can define their own scripts under share/scout_commands, and bin/scout will find them

### scout llm …

Ask an LLM, manage chat files, run a minimal web UI, or process queued requests. Scripts live under scout_commands/llm.

- Ask
  - scout llm ask [options] [question]
    - -t|--template <file_or_key> — load a prompt template; substitutes “???” or appends
    - -c|--chat <chat_file> — load/extend a conversation (appends the reply)
    - -i|--inline <file> — answer “# ask: …” directives inline in a source file
    - -f|--file <file> — prepend file content or substitute where “...” appears
    - -m|--model, -e|--endpoint, -b|--backend — select backend/model; merged with Scout.etc.AI
    - -d|--dry_run — expand and print the conversation (no ask)

- Relay processor (for the Relay backend)
  - scout llm process [directory] — watches a queue directory and answers ask JSONs

- Web UI server
  - scout llm server — static chat UI over ./chats with a small JSON API

- Templates
  - scout llm template — list installed prompt templates (Scout.questions)

Run “scout llm” alone to see available subcommands. If you target a directory (e.g., “scout llm”), a help‑like listing is printed.

### scout agent …

Stateful agents with Workflow and KnowledgeBase tooled up. Scripts live under scout_commands/agent.

- Ask via an Agent
  - scout agent ask [options] [agent_name] [question]
    - -l|--log <level> — set log severity
    - -t|--template <file_or_key>
    - -c|--chat <chat_file>
    - -m|--model, -e|--endpoint
    - -f|--file <path>
    - -wt|--workflow_tasks <comma_list> — export only selected tasks
    - agent_name resolves via Scout.workflows[agent_name] (a workflow) or Scout.chats[agent_name] (an agent directory with workflow.rb/knowledge_base/start_chat)

- KnowledgeBase passthrough
  - scout agent kb <agent_name> <kb subcommand...>
    - Loads the agent’s knowledge base and forwards to “scout kb …” (see scout-gear doc/KnowledgeBase.md for kb CLI)

As with other Scout CLIs, if you target a directory of commands (e.g., “scout agent”), bin/scout will show the subcommand listing.

Note: Workflows also have extensive CLI commands (scout workflow …) for job execution, provenance, orchestration, and queue processing. When you integrate models inside tasks, you drive them through the workflow CLI (see scout-gear doc/Workflow.md).


## Configuration, persistence and reproducibility

- Endpoint presets: place YAML under Scout.etc.AI/<endpoint>.yaml to preconfigure URLs, models, headers, etc.; CLI options and chat inline options override defaults
- Tool calling: Workflow tasks are exported as JSON schemas per backend; results are serialized back to the model as tool replies
- Caching: LLM.ask persists responses (by default) using Persist.persist; disable with persist: false
- Models: pass a directory to persist options/behavior/state (Torch/HF use state files or save_pretrained directories); save/restore to reuse
- Chats: save printable conversations with Chat#save; reuse with “scout llm ask -c <file>”

For Python models, ensure scout-rig (ScoutPython) is installed and Python packages are present. See doc/Python.md in scout-rig for details.


## Where to go next

- Explore the API docs shipped in this repository:
  - doc/LLM.md — orchestration, backends, tools, CLI
  - doc/Chat.md — conversation DSL and file format
  - doc/Agent.md — stateful agents, Workflow/KB wiring, iterate helpers
  - doc/Model.md — model wrappers; ScoutModel, Python/Torch/Hugging Face

- Browse real‑world workflows (including ExTRI2) in Rbbt‑Workflows:
  - https://github.com/Rbbt-Workflows

- Learn core building blocks (TSV, KnowledgeBase, Workflow, etc.) in scout-gear and scout-essentials:
  - https://github.com/mikisvaz/scout-gear
  - https://github.com/mikisvaz/scout-essentials

- Integrate Python with scout-rig:
  - https://github.com/mikisvaz/scout-rig


## License and contributions

Issues and PRs are welcome across the Scout repositories. Please open tickets in the relevant package (e.g., scout-ai for LLM/Agent/Model topics).