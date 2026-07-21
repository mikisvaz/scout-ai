# Scout-AI User Guide

This guide is a practical introduction to Scout-AI for people who want to start using chats, agents, and workflow-backed tools without reading the whole codebase first.

The focus here is intentionally narrow:

- chat files
- stateful agents
- workflow tools
- simple multi-agent strategies

For now, ignore the model and network subsystems. Scout-AI is already useful even if you only use it as a framework for reproducible conversations, tool calling, and agent workflows.

For detailed reference material, keep these documents nearby:

- `LLM.md` — endpoints, backends, tool calling, CLI
- `Chat.md` — chat file roles and compilation rules
- `Agent.md` — stateful agents, tool wiring, delegation, workflow-backed `ask`
- `../python/README.md` — Python SDK for `Chat` and `Agent` wrappers
- `PythonAgentTasks.md` — packaging Python-backed tasks in an agent directory
- `Workflow.md` in `scout-gear` — the underlying Workflow system used to expose tools and orchestrate jobs

## 1. What Scout-AI is

Scout-AI adds an agent and LLM layer on top of Scout.

The core ideas are:

- `LLM.ask` talks to a model backend.
- `Chat` gives you a persistent, editable conversation format on disk.
- `LLM::Agent` gives you stateful conversations and tool wiring.
- Scout `Workflow`s can be exposed as callable tools.
- `KnowledgeBase`s can also be exposed as callable tools.

That means Scout-AI is not only a prompt wrapper. It is a way to build inspectable, reproducible agent applications where:

- conversations live in files
- tools come from real Scout workflows
- artifacts can be written by workflow jobs
- multi-agent patterns can be encoded in Ruby workflows instead of hidden inside prompts

## 2. Installation

Scout-AI is normally used together with the rest of the Scout stack.

Typical Gemfile:

```ruby
source "https://rubygems.org"

gem 'scout-essentials', git: 'https://github.com/mikisvaz/scout-essentials'
gem 'scout-gear',       git: 'https://github.com/mikisvaz/scout-gear'
gem 'scout-rig',        git: 'https://github.com/mikisvaz/scout-rig'
gem 'scout-ai',         git: 'https://github.com/mikisvaz/scout-ai'
```

Then install:

```bash
bundle install
```

Ruby example:

```ruby
require 'scout-ai'
```

If you only want to try the CLI on an existing Scout installation, make sure `scout-ai` is installed and available in your environment.

## 3. Configure your first endpoint

Scout-AI prefers named endpoints. An endpoint is just a YAML file under:

```text
~/.scout/etc/AI/<endpoint>
```

A minimal example:

```yaml
# ~/.scout/etc/AI/nano
backend: responses
model: gpt-5-nano
```

A higher-effort endpoint:

```yaml
# ~/.scout/etc/AI/deep
backend: responses
model: gpt-5
reasoning_effort: high
text_verbosity: high
```

You can then use the endpoint by name:

- Ruby: `endpoint: :nano`
- CLI: `-e nano`

For the full list of backends and options, see `LLM.md`.

## 4. First command-line tests

Start with the smallest possible ask:

```bash
scout-ai llm ask -e nano "Say hi"
```

The same command also works through the generic Scout dispatcher:

```bash
scout llm ask -e nano "Say hi"
```

A useful second test is `--dry_run`, which shows the compiled conversation without calling the model:

```bash
scout-ai llm ask -e nano -d "Summarize what this command would do"
```

A simple file-assisted ask:

```bash
scout-ai llm ask -e nano -f README.md "Summarize this file"
```

These three checks usually tell you that:

- the CLI is installed
- the endpoint resolves correctly
- the backend is reachable
- file injection works

## 5. Your first persistent chat file

One of the best parts of Scout-AI is that conversations can live in normal text files.

Create `hello.chat`:

```text
endpoint: nano

user:

Say hello in one short sentence.
```

Then run:

```bash
scout-ai llm ask -c hello.chat
```

Scout-AI will:

1. parse the file into chat messages
2. call the backend
3. append the assistant reply back to the same file

That means the chat file becomes both:

- the prompt source
- the persistent conversation record

This is the easiest way to understand Scout-AI.

A second turn can simply be appended to the same file:

```text
user:

Now say it in Spanish.
```

Run the same command again and the file will continue to grow.

For more examples and exact parser rules, see `Chat.md`.

## 6. Chat file structure

A chat file is not just a list of prompts. It supports a set of roles that are expanded before the model is called.

At the simplest level you have the normal roles:

- `system`
- `user`
- `assistant`

But the real power comes from the control roles.

### 6.1 Imports and composition

Use these to reuse or continue other chats:

- `import:` — inline another chat
- `continue:` — take only the last non-empty message
- `last:` — take the last non-empty message after removing continuation markers

### 6.2 Files and directories

Use these to attach local context:

- `file:`
- `directory:`
- `image:`
- `pdf:`

### 6.3 Options

Use these to control the backend or output format:

- `endpoint:`
- `backend:`
- `model:`
- `format:`
- `persist:`
- `previous_response_id:`
- `option:`
- `sticky_option:`

### 6.4 Workflow and tool integration

This is where Scout-AI becomes especially interesting.

Use these roles to expose Scout workflows or run workflow jobs:

- `introduce:` — inject workflow documentation into the chat
- `tool:` — expose workflow tasks as callable tools
- `task:` — run a workflow task before the model call
- `inline_task:`
- `exec_task:`
- `job:`
- `inline_job:`

### 6.5 Knowledge base and MCP integration

- `association:`
- `kb:`
- `mcp:`

### 6.6 Maintenance roles

- `clear:`
- `skip:`
- `clear_tools:`
- `clear_associations:`

You do not need to memorize every role at first. The practical approach is:

- learn `user`, `system`, `file`, `endpoint`
- then learn `tool:` and `introduce:`
- then consult `Chat.md` when you need the rest

## 7. Agents

`LLM::Agent` is the stateful wrapper around `LLM.ask` and `Chat`.

Use an Agent when you want:

- a reusable `start_chat`
- a current conversation branch
- default options like `endpoint:` or `model:`
- tools automatically wired from a workflow or knowledge base
- a place to implement multi-step control loops

A minimal Ruby example:

```ruby
require 'scout-ai'

agent = LLM::Agent.new(endpoint: :nano)
agent.start_chat.system "You are a concise assistant"

agent.start
agent.user "List three planets"
puts agent.chat
```

Important concepts:

- `start_chat` is the base conversation template
- `start` creates a new working conversation from it
- `current_chat` is the active branch

For details, see `Agent.md`.

### 7.0 Using Scout-AI from Python

Scout-AI also ships a thin Python SDK in `python/scout_ai`. The SDK mirrors the Ruby chat and agent builder style rather than inventing a second runtime.

A minimal example:

```python
from scout_ai import load_agent

agent = load_agent("Planner", endpoint="nano")
agent.file("README.md")
agent.user("Summarize this repository")
message = agent.chat()
print(message.content)
```

The most important semantic distinction is:

- `ask()` returns a new `Chat` containing only the newly added messages
- `chat()` mutates the current chat and returns the last meaningful new message

For the full Python-side API, see `../python/README.md`.

### 7.1 Agent directories

An agent can also be loaded from a directory or a named chat bundle.

A typical agent directory can contain:

```text
<agent_dir>/workflow.rb
<agent_dir>/knowledge_base/
<agent_dir>/start_chat
<agent_dir>/python/*.py
```

If `workflow.rb` is absent but `python/*.py` files are present, Scout-AI can auto-load them as workflow tasks for the agent. See `PythonAgentTasks.md` for the Python-backed pattern.

This is a very important pattern in Scout-AI because it lets you package:

- instructions
- toolkits
- optional knowledge bases
- optional Python-backed tasks

as a reusable unit.

## 8. Workflows as toolkits for agents

This is one of the biggest conceptual differences between Scout-AI and many other LLM frameworks.

In Scout-AI, the main executable capability abstraction is not a custom “skill” object. It is a Scout `Workflow`.

A Workflow already gives you:

- named tasks
- typed inputs
- dependencies
- persistent job outputs
- artifact directories through `Step#file`
- provenance and reproducibility

Scout-AI can expose workflow tasks as tools in two main ways.

### 8.1 Programmatically through an Agent

```ruby
agent = LLM::Agent.new(workflow: 'Baking', endpoint: :nano)
agent.start
agent.user "Bake muffins using the tool"
puts agent.chat
```

### 8.2 Declaratively in a chat file

```text
introduce: Baking
tool: Baking

user:

Bake muffins using the workflow tool.
```

### 8.3 Running tasks ahead of time

If you want a workflow step to run before the model is queried, use `task:` or `exec_task:` in the chat file.

That lets you choose between two styles:

- expose the workflow so the model can call it when needed
- run the workflow first and give the result as context

### 8.4 How this relates to “skills”

Many agent systems talk about “skills” as bundles of instructions plus tools.

In Scout-AI, the closest equivalents are:

- a `Workflow` for executable capabilities
- a `start_chat` file for instructions and conventions
- an optional `KnowledgeBase` for retrieval tools
- an agent directory that bundles those together

So in practice:

- a workflow is your toolkit
- a chat or agent directory is your policy and presentation layer
- together they play the role that other systems might call a skill pack

The advantage of the Scout version is that the executable part is a real typed workflow, not just prompt text.

For the underlying workflow system itself, see `scout-gear`'s `Workflow.md` documentation.

## 9. Multi-agent strategies

Scout-AI supports multi-agent work in more than one way.

### 9.1 Simple delegation

An agent can register another agent as a tool with `delegate`.

This is good when you want:

- a supervisor agent
- a reviewer agent
- a specialist that answers focused subquestions

Example uses:

- one agent writes, another judges
- one agent proposes options, another ranks them
- one agent searches, another implements

### 9.2 Workflow-controlled multi-agent loops

For more serious orchestration, the stronger pattern is to put the control loop in a Workflow.

This is important.

Instead of asking one model to simulate an entire manager runtime in prompt text, you can:

- define a workflow task such as `ask`
- call specialist agents in a fixed sequence
- write artifacts with `Step#file`
- use `json_format` only for the few handoffs that need structure

This gives you a much more reliable way to build patterns such as:

- intake -> plan -> execute -> review
- search only when blocked
- validation chains
- repair loops
- resumable sessions with artifacts on disk

In Scout-AI, this is usually the best place to experiment with advanced patterns: inside workflows and agent directories, not inside the core runtime.

### 9.3 Artifact-first collaboration

A good Scout-AI multi-agent pattern usually writes explicit artifacts such as:

- `query.md`
- `reference.md`
- `plan.md`
- `work.md`
- `review.json`
- `final_report.md`

That way:

- every agent sees explicit inputs
- the run is inspectable afterwards
- follow-up work can continue from real files instead of vague chat memory

### 9.4 Socialized agent chats

When a Manager or supervisor agent dispatches work to a specialist agent using the
`ask` tool with a named `conversation`, Scout-AI records the interaction as a
**socialized chat file**. These files are distinct from the regular agent log at
`<job>.files/log/agent.chat`.

Socialized chats are persisted at:

```text
<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat
```

For example, if a Manager dispatches three parallel batches to different specialist
conversations, you will find:

```text
<job>.files/log/chats/Specialist/batch_one.chat
<job>.files/log/chats/Specialist/batch_two.chat
<job>.files/log/chats/Specialist/batch_three.chat
```

#### What is inside a socialized chat

A socialized chat file is a **projection** of the specialist's work, not a full
agent log. It typically contains:

- an `introduce:` line for the specialist agent
- `option:` lines propagated from the caller — including `endpoint`, `model`,
  `backend`, and potentially API keys or other credentials
- the `user:` prompt that the caller sent
- a `meta: job=<path>` marker pointing to the specialist's ask-job
- the assistant response

The actual model inferences and tool calls happen inside the referenced ask-job's
own `agent.chat` log and its dependencies, not in the socialized chat file.

#### Why this matters

Socialized chats keep the Manager's context clean: each specialist batch produces
a compact result that is returned to the Manager without polluting its
conversation with raw tool outputs. But for inspection and provenance, you must
follow the `meta: job=...` reference to find the real token usage and tool-call
activity. Socialized chat files themselves report zero direct inference.

This pattern is documented in detail in `Agent.md` § 8.1.

#### Option propagation and credentials

The caller's sticky options are copied into each socialized chat as `option:`
lines. This is convenient for reproducibility — each socialized chat is
self-contained — but it means that credentials such as API keys embedded in
endpoint configurations will appear in the file. Be aware of this when sharing
or archiving session logs.


## 10. A boiled-down Session-style reasoning agent

A useful pattern in Scout-AI is to replace the agent’s default `ask` behavior with a workflow task that orchestrates several specialist agents.

This is how you can encode a simple reasoning loop without changing Scout-AI core.

Below is a deliberately small sketch inspired by the `Session` approach. It is not meant to be the production implementation, only a guide to the pattern.

```ruby
require 'scout-ai'
require 'json'

module MiniSession
  extend Workflow

  helper :critic_schema do
    {
      name: 'critic_review',
      type: 'object',
      properties: {
        status: { type: :string },
        summary: { type: :string }
      },
      required: [:status, :summary],
      additionalProperties: false
    }
  end

  helper :specialist do |name, options, files: []|
    agent = LLM::Agent.load_agent name, options
    agent.start
    files.each do |path|
      target = file(path)
      agent.file target if target.exists?
    end
    agent
  end

  input :chat, :text, 'Chat in Scout-AI format', nil, required: true
  extension :chat
  task :ask => :text do |chat|
    messages = LLM.chat chat
    options = LLM.options messages

    file('conversation.chat').write Chat.print(messages)

    user = specialist 'User', options
    user.follow messages
    user.user 'Restate the request for the other agents.'
    file('query.md').write user.chat

    planner = specialist 'Planner', options, files: ['query.md']
    planner.user 'Create one short plan with acceptance tests.'
    file('plan.md').write planner.chat

    worker = specialist 'Worker', options, files: ['query.md', 'plan.md']
    worker.user 'Execute the task and summarize what you did.'
    file('work.md').write worker.chat

    critic = specialist 'Critic', options, files: ['query.md', 'plan.md', 'work.md']
    critic.user 'Review the result against the request and the plan.'
    review = critic.json_format critic_schema
    file('review.json').write JSON.pretty_generate(review)

    final_user = specialist 'User', options, files: ['query.md', 'plan.md', 'work.md', 'review.json']
    final_user.user 'Produce the final report.'
    LLM.print [{ role: :assistant, content: final_user.chat }]
  end
end
```

Why this example matters:

- `Chat` is still the entry format
- `Agent`s do the specialist reasoning
- `Workflow` controls the order of stages
- `Step#file` stores artifacts in the job directory
- `json_format` is used only where a strict handoff helps

That is often enough to build a useful multi-agent strategy without making the system hard to understand.

## 11. Inspecting chat provenance and token usage

A Scout-AI session can contain a top-level chat, imported chats, persisted
Workflow jobs, job dependencies, agent logs under `<job>.files/log/`, and
socialized chat projections under `<job>.files/log/chats/`.
Use:

```bash
scout-ai llm info path/to/chat
scout-ai llm info path/to/chat --flow
```

The inspector reads persisted files; it does not compile chats or execute task
roles again. It follows `import`, `continue`, `last`, `meta job=...`, persisted
Workflow dependencies, and all `log/**/*.chat` files, including socialized
chats stored under `log/chats/<AgentName>/<conversation>.chat`.

### 11.1 Metadata semantics

A `meta` line starts a response segment. It covers the following assistant,
function-call, and function-output messages until another `meta`, a new
user/system turn, or the end of the chat. Consecutive meta lines mean the
earlier segment is empty and is retained as an orphan record. This commonly
happens when a tool call is removed but its usage metadata remains useful.

There are two deliberately different metadata forms:

- `meta: pt=... ct=... tt=...` records a direct model inference in that chat.
- `meta: job=<path>` says the next message was projected from an ask-job
  result. It is a producer reference, not a second inference bill.

Ask-task agent logs retain the direct inference metadata. The ask result strips
that metadata and places one `meta job=...` at the start of the returned tool
calls, tool outputs, and assistant response. Following the job discovers the
actual agent logs and nested dependencies.

### 11.2 Token totals

`pt`, `ct`, and `tt` are prompt, completion, and total tokens for one direct
inference. `pt_c`, `ct_c`, and `tt_c` are the running total of the linear chat
branch; `*_s` fields are running session checkpoints. Do not sum `*_c` or
`*_s` values across messages or files.

The inspector totals direct metadata through `Chat.trace_chats`. A trace message
is identified by its non-meta conversation history, so the same text after a
different history is distinct. Exact duplicate lineage/metadata records are
collapsed. A projected `job` record and a direct inference record can coexist
for the same lineage message: the former triggers job traversal and the latter
is the actual cost.

A root chat can correctly report little or no direct usage while its traced
agent logs contain substantial usage. That means the root is projecting ask-job
results rather than performing the inference itself.

### 11.3 Tool calls and workflow provenance

A tool invocation is represented by `function_call` plus
`function_call_output`; count the call, not both records. Provider tokens are
charged to model requests, not to the tool invocation itself.

Use Scout's normal dependency view when needed:

```bash
scout workflow prov /path/to/job.chat --nocolor
```

`workflow prov` explains persisted task dependencies. `llm info` explains how
those jobs, chats, projected results, and agent logs combine into a session.

### 11.4 Common mistakes

- Do not count a `meta job=...` projection as a local token event.
- Do not sum every cumulative `*_c` or session `*_s` value.
- Do not inspect only `log/agent.chat`; workers and branches can be stored
  anywhere below `log/**/*.chat`, including under
  `log/chats/<AgentName>/<conversation>.chat`.
- Do not treat a socialized chat file as the place where inference happens; it
  carries zero direct tokens. Follow its `meta: job=...` reference to the
  specialist's ask-job and its dependencies for the real cost.
- Do not use `LLM.chat` to inspect provenance: it compiles a chat and may run
  task/job roles. Use `Chat.load` for persisted evidence.


## 12. Where to go next

A practical learning path is:

1. Configure one endpoint and run `scout-ai llm ask`
2. Create and continue a chat file with `-c`
3. Read `Chat.md` once you want more than `user/system/file`
4. Create a small stateful `LLM::Agent`
5. Expose one Scout workflow as a tool
6. Move your first multi-step strategy into a workflow-backed `ask`
7. Inspect it with `scout-ai llm info --flow` and `scout workflow prov`

Reference documents:

- `USER_GUIDE.md` — this file
- `LLM.md` — backend and CLI reference
- `Chat.md` — chat file reference
- `Agent.md` — agent reference
- `../python/README.md` — Python SDK reference for chats and agents
- `PythonAgentTasks.md` — Python-backed task packaging for agents
- `Workflow.md` in `scout-gear` — workflow engine reference

If you keep one idea in mind, make it this one:

Scout-AI becomes most powerful when you combine three things:

- chat files for explicit conversational state
- agents for specialist reasoning
- Scout workflows for typed tools and orchestration
