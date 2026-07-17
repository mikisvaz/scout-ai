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

## 11. Inspecting provenance, token usage, and agent flow

Scout-AI conversations can span several kinds of persistent objects. Before trying to explain a run, distinguish them:

- a **top-level chat file** is the user-facing conversation and may import earlier chats
- a **Workflow job result** is the persisted result of one Scout task, usually under `~/.scout/var/jobs/<Workflow>/<task>/...`
- a job's **`.info` file** records its Workflow identity, inputs, status, and explicit dependencies
- a job's **`.files` directory** stores artifacts and diagnostic logs
- an **agent log** is normally stored at `<job>.files/log/agent.chat`
- additional agents may be stored at `<job>.files/log/<agent-or-branch>/agent.chat`

These objects overlap intentionally. A later chat may import an earlier chat, an agent log may contain inherited conversation history, and a task result may summarize usage from nested jobs. Do not sum every number or every metadata line you find.

### 11.1 Start with `llm info`

The main inspection command is:

```bash
scout-ai llm info path/to/chat
```

It first discovers the relevant object graph and then reports:

- top-level and imported chat files
- message counts and role counts
- endpoints serialized in chats or saved job inputs
- function-call counts
- request token events
- referenced Workflow jobs and their dependencies
- all `agent.chat` files under each job's `.files/log` tree
- nested `ask` jobs found while reading those logs
- aggregate usage with request and job identities deduplicated

Use the compact flow when the detailed report is too large:

```bash
scout-ai llm info path/to/chat --flow --nocolor
```

Each Workflow node includes an eight-character job hash, which is the easiest way to correlate a text node with a job directory or a node in a figure.

To create a reusable graph description:

```bash
scout-ai llm info path/to/chat --dot flow.dot
```

To render a figure directly:

```bash
scout-ai llm info path/to/chat --plot flow.svg
scout-ai llm info path/to/chat --plot flow.pdf
scout-ai llm info path/to/chat --plot flow.png
```

SVG or PDF is generally preferable for papers. Graphviz must be installed for `--plot`; `--dot` remains useful when rendering is done elsewhere.

### 11.2 Reading the flow graph

The flow graph contains chat nodes and Workflow job nodes. Its edge types have different meanings:

- `import`: one top-level chat imports another chat
- `result`: a Workflow job produced the result recorded in a chat
- `dependency`: a persisted Scout Workflow dependency
- `call`: an orchestration job invoked a nested `ask` job
- `session`: ordering inferred from matching session-token prefixes when no stronger relation was available

Treat explicit `dependency`, `import`, and `result` edges as stronger evidence than inferred session edges.

A job mentioned in an agent log is not automatically a new call. For example, a result from an earlier chat may be imported into a later chat and immediately presented to the later agent. `llm info` suppresses a `call` edge when the same relationship is already explained by:

1. the earlier job producing an earlier chat,
2. that chat being imported into the later chat, and
3. the later job producing the later chat.

This avoids presenting inherited context as a fresh agent invocation.

### 11.3 Workflow provenance is complementary

For a specific job, use Scout's normal provenance command:

```bash
scout workflow prov /path/to/job.chat --nocolor
```

This reports the persisted Workflow dependency chain. It is authoritative for Scout dependencies, but it does not by itself explain:

- imported top-level chats
- all nested agent logs
- session-prefix relationships
- token events inside chats
- apparent calls that are actually inherited through chat imports

Use `workflow prov` to understand the task DAG and `llm info` to understand the combined chat, agent, and token flow.

### 11.4 Token metadata vocabulary

Backend request metadata uses these fields:

- `pt`, `ct`, `tt`: prompt, completion, and total tokens reported for one backend request
- `usage_id`: stable identity for that request; shared history and copied chats can therefore be deduplicated
- `pt_s`, `ct_s`, `tt_s`: running process/thread session snapshots
- `pt_c`, `ct_c`, `tt_c`: cumulative values represented by the current chat lineage

Workflow task summaries use:

- `usage_scope=task`: identifies an aggregate task record rather than a backend request
- `usage_job`: stable job identity used to deduplicate repeated imports or follows
- `pt_d`, `ct_d`, `tt_d`: tokens local to that Workflow task
- `pt_c`, `ct_c`, `tt_c`: inherited task usage plus the local delta

The distinction between delta and cumulative values is essential:

- use `*_d` when adding sibling or dependency task costs
- use `*_c` when continuing a normal chat from one completed task result
- never sum all `*_c` values from successive messages or logs

A zero-token orchestration job can be correct. A task such as `Branched/work` may only coordinate several `InterpretData/ask` jobs. In that case the orchestration task has `tt_d=0`, while the nested `ask` jobs contain the actual model cost.

### 11.5 Request usage, session usage, and unattributed usage

The detailed report distinguishes:

- **Request token events**: request records with a `usage_id`
- **Legacy cumulative baseline**: an opaque final snapshot from chats created before request identities were recorded
- **Session running snapshot**: the latest `*_s` values in that file
- **Session-only/unattributed**: the session snapshot minus request events present in that file

Session counters are not chat counters. They can include requests made earlier in the same process, socialized agents, or other work not serialized into the current file.

When an unattributed prefix exactly matches the session snapshot of another discovered agent log, `llm info` reports only `Session prefix matches`. The match explains the difference and is also useful for ordering the report. If no match exists, the running and unattributed values remain visible as a warning that some session work has not been assigned to a discovered file.

Do not add session snapshots from several files. They often overlap by construction.

### 11.6 Finding where tokens were spent

Use this sequence when answering a cost question:

1. Run `scout-ai llm info <chat> --flow` to identify the top-level chats and expensive jobs.
2. Locate the job hash in the detailed `llm info` report.
3. Read the job's task-local `pt_d`, `ct_d`, and `tt_d`.
4. If the task delta is zero, follow its `dependency` and `call` edges to nested `ask` jobs.
5. Inspect `<job>.files/log/agent.chat` and every `<job>.files/log/*/agent.chat` file.
6. Use `scout workflow prov <job>` to confirm persisted dependencies.
7. Inspect `<job>.info` when paths, inputs, or dependency resolution are unclear.

The job result is intentionally compact. Full request traces are kept in agent logs for auditing. A task result carrying one summary is not evidence that only one model request occurred.

Jobs may appear under both `~/.scout` and `~/.rbbt` because older default resource paths were unstable. `llm info` merges jobs with the same Workflow, task, and result basename. Do not count the two physical paths as separate model executions.

### 11.7 Understanding tool-call cost

A persisted invocation normally appears as a pair:

- `function_call`: the model requested a function
- `function_call_output`: Scout recorded the function result

The `id` or `call_id` links the two records. Count `function_call` messages, not both halves. A `tool` role usually declares a tool; it does not prove that the tool was invoked.

To count calls by function in an agent log, parse the chat rather than relying on line-oriented `grep`, because JSON content may span lines:

```ruby
require 'scout-ai'
require 'json'

messages = LLM.messages(Open.read(ARGV.first))
counts = Hash.new(0)

messages.each do |message|
  next unless %w(function_call mcp_call).include?(message[:role].to_s)
  info = JSON.parse(message[:content])
  name = info['name'] || info.dig('function', 'name') || '(unknown)'
  counts[name] += 1
end

counts.sort.each { |name, count| puts "#{name}\t#{count}" }
```

Providers report tokens per model request, not per function call. A tool call itself therefore has no exact provider token bill. The next model request includes the tool output along with the rest of the conversation, so its prompt-token count is only an upper bound on the cost attributable to that tool output.

When several functions are called before one follow-up model request, do not divide the next request's prompt tokens equally unless you explicitly label that as an estimate. A defensible report should separate:

- number of calls per function
- size or character count of each function output
- token usage of the following model request
- whether several outputs shared that request

This is especially important for search, file-reading, and data-analysis tools: the expensive part is often the large output inserted into the next prompt, not the function invocation record itself.

### 11.8 Common mistakes and how to avoid them

**Summing cumulative metadata**

Successive `*_c` and `*_s` values are snapshots. Summing them produces triangular or explosive totals. Sum request events by `usage_id` or task deltas by `usage_job`.

**Counting shared chat history repeatedly**

Branches and imported chats may share many messages. Repeated text is not necessarily repeated billing. Use request and job identities.

**Treating an imported result as a new call**

If an earlier job produced an imported chat, its appearance in a later agent log can be inherited context. Follow `result` and `import` edges before claiming a `call` occurred.

**Charging an orchestration task for nested work**

A manager or branched task may have zero local tokens while nested `ask` jobs are expensive. Report both the zero-cost coordinator and the called jobs.

**Counting declarations as calls**

`tool:` and the `tool` role expose capabilities. Count `function_call` or `mcp_call` records for actual invocations.

**Counting both call and output**

A `function_call_output` completes a call; it is not a second invocation.

**Assuming prompt plus completion always equals total**

Some providers or legacy records report only total tokens. Keep unknown components as unknown or zero in tabular summaries; do not manufacture a split.

**Trusting session-only usage as exact attribution**

An unmatched session remainder is a clue, not proof. It may include prior work in the same process. Exact session-prefix matches are stronger evidence.

**Treating cached replay as a new paid request**

Persisted/cached responses can carry the original metadata and `usage_id`. The request identity means it should be counted once as an actual historical model request, not once per replay.

**Missing sub-agent logs**

Do not inspect only `<job>.files/log/agent.chat`. Search recursively for `<job>.files/log/**/agent.chat` because branches, workers, critics, and socialized agents may each have their own log.

**Confusing resource roots**

The same logical job may be reachable through both `~/.scout` and `~/.rbbt`. Compare Workflow, task, and result hash before treating paths as distinct.

**Using a wrong chat path**

Check `chat` versus `chats`, extensionless files versus `.chat`, and symlinked chat directories. A command that reports `Chat not found` performed no provenance analysis.

### 11.9 A concise provenance answer template

When an Agent is asked where time or tokens went, a good answer should state:

1. which top-level chat was inspected
2. which earlier chats it imported
3. which Workflow job produced each chat result
4. the expensive jobs ranked by task-local `tt_d`
5. which zero-cost jobs were only orchestrators
6. which nested agents or tools were called
7. whether any session usage remained unmatched
8. whether duplicate resource-root paths or cached request identities were deduplicated
9. any attribution that is estimated rather than provider-reported

This structure is much safer than quoting the largest `tt_c` or `tt_s` value found in a log.

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
