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

- doc/LLM.md — multi‑backend LLM orchestration, tool calling, endpoints, CLI
- doc/Chat.md — chat files: roles/options, compilation pipeline, persistence
- doc/Agent.md — stateful agents wired to Workflows and KnowledgeBases
- doc/Model.md — model wrappers (ScoutModel, Python/Torch/Hugging Face)


## Installation and requirements

Scout is a Ruby framework. Add scout-ai (and the other packages you need) to your project and require as needed.

- Ruby 3.x recommended
- For Python‑backed models (Torch/Hugging Face):
  - Python 3 (installed and visible in PATH)
  - pycall gem (Ruby ↔ Python bridge)
  - Python packages: torch, transformers, numpy, pandas (as needed)
- For OpenAI/Anthropic/etc backends: set API keys in environment or config (see `doc/LLM.md`)

Typical Gemfile fragment:

```ruby
gem 'scout-essentials', git: 'https://github.com/mikisvaz/scout-essentials'
gem 'scout-gear',       git: 'https://github.com/mikisvaz/scout-gear'
gem 'scout-rig',        git: 'https://github.com/mikisvaz/scout-rig'
gem 'scout-ai',         git: 'https://github.com/mikisvaz/scout-ai'
```

### Endpoints (recommended)

Backends and endpoints can be configured via:

- per-endpoint YAML files (recommended): `~/.scout/etc/AI/<endpoint>`
- environment variables per backend (see `doc/LLM.md`)

Most teams create a few named endpoints (e.g. `nano`, `deep`, `ollama`) and then reference them with:

- Ruby: `endpoint: :nano`
- CLI: `-e nano`


## Quick starts

### Configure an endpoint (once)

Create `~/.scout/etc/AI/nano`:

```yaml
backend: responses
model: gpt-5-nano
```

Or a higher-effort endpoint `~/.scout/etc/AI/deep`:

```yaml
backend: responses
model: gpt-5
reasoning_effort: high
text_verbosity: high
```

Keys beyond `backend/url/model` are passed through to the backend.

### Ask a model

Ruby:

```ruby
require 'scout-ai'
answer = LLM.ask "What is the capital of France?", endpoint: :nano
puts answer
```

CLI:

```bash
scout-ai llm ask -e nano "What is the capital of France?"
```

Chat builder:

```ruby
chat = Chat.setup []
chat.system "You are a terse assistant"
chat.user   "List three colors"
puts chat.ask(endpoint: :nano)
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
  task :person => :yaml do
    inputs.to_hash
  end
end

puts LLM.workflow_ask(m, "Register Eduard Smith, a 25 yo male, using a tool call",
                      endpoint: :nano)
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

  agent = LLM::Agent.new(knowledge_base: kb, endpoint: :nano)
  agent.start
  agent.user "Who is Miki's brother in law?"
  puts agent.chat
end
```

### Structured iteration

```ruby
agent = LLM::Agent.new(endpoint: :nano)
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

- `LLM.ask(question, options={}, &block)` — compile `question` via `LLM.chat`, merge endpoint/model/format options, call backend
- Backends: Responses, OpenAI, Anthropic, Ollama, vLLM, OpenWebUI, AWS Bedrock, Relay
- Tools: export Workflow tasks and KnowledgeBase databases as function tools
- Chat compilation pipeline: imports, clear/skip, tasks/jobs, files/directories
- Endpoint configuration: `~/.scout/etc/AI/<endpoint>`

### Chat (doc/Chat.md)

Chat is both:

- a builder over an Array of `{role:, content:}` messages
- a stable on-disk “chat file” format used by the CLI

See `doc/Chat.md` for the full list of special roles (options, tools, imports, files, tasks, MCP, KB).

### Agent (doc/Agent.md)

An Agent is a stateful wrapper around Chat and LLM:

- maintains a current conversation (`start_chat`, `start`, `current_chat`)
- auto-exports Workflow tasks and KnowledgeBase databases as tools
- provides `chat/json/json_format/iterate` helpers

### Model (doc/Model.md)

A composable framework to wrap models with a consistent API:

- ScoutModel — base: define init/eval/eval_list/extract_features/post_process/train; persist behavior and state to a directory
- PythonModel — initialize and drive a Python class via ScoutPython
- TorchModel — helpers for PyTorch: training loop, tensors, save/load state, layer introspection
- HuggingfaceModel — Transformers convenience; specializations:
  - SequenceClassificationModel — text classification, logits→labels
  - CausalModel — chat/causal generation (supports apply_chat_template)
  - NextTokenModel — simple next‑token fine‑tuning loop


## Example: ExTRI2 workflow (models in practice)

The ExTRI2 Workflow (Rbbt‑Workflows) uses HuggingfaceModel to score TRI sentences and determine Mode of Regulation (MoR):

- Feature extraction marks [TF]/[TG] spans as inline tags for the model
- Batch evaluation over a TSV (“Text”, “TF”, “Gene” columns)
- Adds fields “Valid score” and “Valid” to the TSV
- Runs a second SequenceClassification model to produce “MoR” and “MoR scores”

See workflows/ExTRI2/workflow.rb in that repository for the full implementation.


## Command‑Line Interface

The bin/scout dispatcher locates scripts under scout_commands across installed packages and workflows using the Path subsystem.

You can run it as:

- `scout ...` (the standard Scout CLI), or
- `scout-ai ...` (a thin wrapper that loads Scout with `scout-ai` available)

### scout llm …

Ask an LLM, manage chat files, run a minimal web UI, or process queued requests. Scripts live under scout_commands/llm.

- Ask
  - `scout llm ask [options] [question]`
  - `scout-ai llm ask [options] [question]`
    - -t|--template <file_or_key> — load a prompt template; substitutes “???” or appends
    - -c|--chat <chat_file> — load/extend a conversation (appends the reply)
    - -i|--inline <file> — answer “# ask: …” directives inline in a source file
    - -f|--file <file> — prepend file content or substitute where “...” appears
    - -m|--model, -e|--endpoint, -b|--backend — select backend/model; merged with endpoint configs
    - -d|--dry_run — expand and print the conversation (no ask)

- Relay processor (for the Relay backend)
  - `scout llm process [directory]` — watches a queue directory and answers ask JSONs

- Web UI server
  - `scout llm server` — static chat UI over ./chats with a small JSON API

- Templates
  - `scout llm template` — list installed prompt templates (Scout.questions)

Run `scout llm` alone to see available subcommands.

### scout agent …

Stateful agents with Workflow and KnowledgeBase tooled up. Scripts live under scout_commands/agent.

- Ask via an Agent
  - `scout agent ask [options] [agent_name] [question]`
  - `scout-ai agent ask [options] [agent_name] [question]`
    - -l|--log <level> — set log severity
    - -t|--template <file_or_key>
    - -c|--chat <chat_file>
    - -m|--model, -e|--endpoint
    - -f|--file <path>
    - -wt|--workflow_tasks <comma_list> — export only selected tasks
    - agent_name resolves via Scout.workflows[agent_name] (a workflow) or Scout.chats[agent_name] (an agent directory with workflow.rb/knowledge_base/start_chat)

- KnowledgeBase passthrough
  - `scout agent kb <agent_name> <kb subcommand...>`

Note: Workflows also have extensive CLI commands (`scout workflow …`) for job execution, provenance, orchestration, and queue processing.


## Configuration, persistence and reproducibility

- Endpoint presets: place YAML under `~/.scout/etc/AI/<endpoint>` to preconfigure url/model/backend and backend-specific knobs
- Tool calling: Workflow tasks are exported as JSON schemas per backend; results are serialized back to the model as tool replies
- Caching: `LLM.ask` persists responses (by default) using `Persist.persist`; disable with `persist: false`
- Chats: save printable conversations with Chat#save; reuse with `scout-ai llm ask -c <file>`


## Where to go next

- Explore the API docs shipped in this repository:
  - doc/LLM.md — orchestration, endpoints, backends, tools, CLI
  - doc/Chat.md — chat files: roles/options and compilation behavior
  - doc/Agent.md — stateful agents, Workflow/KB wiring, delegation, iterate helpers
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
