# Scout-AI

Scout-AI is a programmable agent harness: it supplies the machinery — persistent
conversations, real tools, context management, delegation, workflow-based
orchestration, provenance, and swappable inference backends — that turns an
LLM's reasoning into inspectable, reproducible agents. The model provides the
reasoning; Scout-AI provides everything else, and all of it is programmable.

Scout-AI is reasoning layered onto Scout's computational model: Scout turns
computation into persistent, composable, inspectable work; Scout-AI extends
that model to reasoning. It is an agent and LLM layer built on top of
[Scout](https://github.com/mikisvaz/scout-gear): tool calls run as real
workflow jobs, multi-agent orchestration as typed, inspectable workflow
tasks. New here? Start at **[doc/StartHere.md](doc/StartHere.md)**.

## The problem

An LLM call is not an agent: a raw API call produces one answer and leaves
nothing behind — no conversation to inspect, no grounding in your data, no
tools, no record of what ran. An agent needs machinery around the model:
**state** that persists and can be versioned, **context** as a view not a
destructive edit, **tools** that query real data and run real code,
**provenance** for the calls, jobs, and tokens behind an answer,
**iteration** so tool calls loop to a final answer, **orchestration** to
compose agents and jobs into pipelines. Scout-AI supplies each as a
first-class object.

None of that machinery is invented here: Scout already gives deterministic
computation persistence and provenance — a workflow runs as jobs, jobs
produce artifacts, steps record what ran. Scout-AI brings reasoning into
the same model — the agent's reasoning runs as a workflow job, its
conversation is a persisted artifact, and the next tool call or your own
code picks up from there.

## The four building blocks

| Concept | What it is | What problem it solves |
|---------|-----------|----------------------|
| **Chat** | A conversation format (plain text on disk, Array of hashes in memory) | Reproducibility: every conversation is inspectable, editable, and versionable |
| **Agent** | A stateful wrapper around a Chat with persistent defaults and tools | Persistence: your agent keeps its system prompt, tools, and options across conversations |
| **Tools** | Callable functions the LLM can invoke during inference | Grounding: the model can query real data and run real code instead of hallucinating |
| **Inference Endpoint** | A named configuration for a provider + model + credentials | Portability: switch provider or model without changing application code |

They compose: an agent holds a chat, carries tools, and sends the chat to a named
endpoint — [CoreConcepts](doc/user/CoreConcepts.md).

## What makes it different

**Conversations are plain data.** A Chat is a plain-text file on disk and an Array of message
hashes in memory; `Chat` is an annotation over Array (`chat.class # => Array`), so standard
Array operations work and every conversation serializes to the same diffable format. Context
management is ephemeral: strategies reshape what the model sees while the stored chat
retains full-fidelity data.
→ [WritingChats](doc/user/WritingChats.md) · [ManagingContext](doc/user/ManagingContext.md)

**Tools are real Scout workflow jobs.** Tools come from three sources — Scout workflow
tasks, knowledge base databases, MCP servers. A task's typed inputs and outputs become
the tool parameter schema, the call runs as a real workflow job with dependency resolution
and caching, and the tool-calling loop is automatic, including multi-tool iterations.
→ [ToolCalling](doc/user/ToolCalling.md)

**Agent architecture as code.** An agent is a named directory — `start_chat`, `workflow.rb`,
`knowledge_base/`, `python/` — discovered by convention, no registration calls or plugin
manifests. Agents delegate to each other: `socialize` exposes one generic `ask` tool where
the model picks the specialist, `delegate` pre-registers named `hand_off_to_<name>` tools,
and inheritance modes (`none`, `tools`, `conversation`) control how much caller context
flows to the specialist; named conversations persist across calls.
→ [BuildingAgents](doc/user/BuildingAgents.md) · [Delegation](doc/user/Delegation.md)

**Multi-agent orchestration as typed, inspectable workflow jobs.** Include the
`AgentWorkflow` mixin and use `chat_task`: each agent run becomes a Scout workflow job
with caching, provenance, and dependency tracking; documented patterns include linear
pipelines, manager-worker, critic loops, branched exploration, and artifact-first
collaboration.
→ [MultiAgentWorkflows](doc/user/MultiAgentWorkflows.md)

**Provenance and inspectable, reproducible runs.** Provenance is modeled over exactly two
node kinds — chat files and workflow steps — traversed by `Chat.traverse_provenance`.
Per-inference metadata records token usage with `inference_id`-based deduplication,
delegated-agent receipts embed child inference evidence in parent tool outputs, and
inference results are persisted by default; `scout-ai llm prov <chat>` renders tree, flow,
DOT, and evidence views. The inspectability story is one chain: agent decision → tool call
→ workflow job → dependent jobs → artifacts → provenance.
→ [Provenance](doc/developer/Provenance.md)

**Model independence as an architectural property.** Backends are stateless module
adapters composed with the shared inference pipeline — no abstract base class — and unknown
backend names resolve as module names, so third-party backends load dynamically. Providers
are addressed through named endpoints: your agent code and chat files stay the same across
OpenAI, Anthropic, Ollama, vLLM and other OpenAI-compatible servers, AWS Bedrock, and more.
→ [Backends](doc/developer/Backends.md) · [RunningInference](doc/user/RunningInference.md)

```text
The Scout stack (each layer sits on the one below):
  scout-ai          chats, agents, tools, orchestration
  scout-gear        workflow engine, knowledge bases, TSV
  scout-essentials  paths, IO, persistence, caching, log

Inside scout-ai:
  LLM.ask     LLM.chat     LLM.load_agent
    |            |               |
 Backend     LLM::Agent       Tools
(adapter)    (stateful)    (WF/KB/MCP)
               | holds         | task tools
               v               v
          Chat <--------- Workflow jobs
    (Array + Annotation)     as tools
```

Dependency direction is Agent → Chat → Annotation: Chat and backends work without an
agent, agents without the workflow mixin — [Architecture](doc/developer/Architecture.md).

## Quick taste

```bash
scout-ai llm ask "What is the capital of France?"   # one question
scout-ai llm ask -c hello.chat                      # or a saved conversation
```

A chat file — write it by hand, run it, edit it, diff it:

```text
system:

You are a friendly assistant.

user:

What is 2 + 2?
```

An agent is a directory, invoked by name
(`scout-ai agent ask Greeter "Hi, I'm Alice!"`):

```text
Agent/Greeter/
  start_chat   # system prompt + tool declarations
  workflow.rb  # optional Scout workflow providing tools
```

A multi-agent pipeline is an ordinary Scout workflow (module with
`extend Workflow; include AgentWorkflow`); more recipes in
[Cookbook](doc/user/Cookbook.md):

```ruby
chat_task :analyze do |input|
  agent = self.agent('Analyst', chat: chat)
  agent.socialize    # may delegate to specialists
  agent.start
  agent.user input
  agent.chat
end
```

## Installation

```bash
gem install scout-ai
export OPENAI_API_KEY="sk-..."
scout-ai config set openai model=gpt-4o
```

Requires Ruby 3.0+. Endpoints, providers, CLI:
[RunningInference](doc/user/RunningInference.md); first-run walkthrough:
[GettingStarted](doc/user/GettingStarted.md).

## Python

Use chats and agents from Python through the thin SDK in
[python/README.md](python/README.md) (`from scout_ai import load_agent`),
which delegates execution to the Ruby runtime; and write agent tools in Python — a `python/` subdirectory of an agent directory is auto-loaded as workflow tasks ([doc/user/Python.md](doc/user/Python.md)).

## Where to go next

[doc/StartHere.md](doc/StartHere.md) is the documentation entry point:

| Task | Reading path |
|---|---|
| Build my first agent | [GettingStarted](doc/user/GettingStarted.md) → [CoreConcepts](doc/user/CoreConcepts.md) → [BuildingAgents](doc/user/BuildingAgents.md) |
| Wire up tools | [ToolCalling](doc/user/ToolCalling.md) → [Python](doc/user/Python.md) |
| Configure inference | [RunningInference](doc/user/RunningInference.md) → [ManagingContext](doc/user/ManagingContext.md) |
| Build multi-agent systems | [Delegation](doc/user/Delegation.md) → [MultiAgentWorkflows](doc/user/MultiAgentWorkflows.md) → [DelegationInternals](doc/developer/DelegationInternals.md) |
| Understand the internals | [Architecture](doc/developer/Architecture.md) → [ChatLifecycle](doc/developer/ChatLifecycle.md) → [Backends](doc/developer/Backends.md) |
| Track provenance | [Provenance](doc/developer/Provenance.md) |
| Deep code investigations | [research/](research/) (unmaintained reports) |

## Ecosystem

Scout-AI is part of the Scout stack, all under
[github.com/mikisvaz](https://github.com/mikisvaz): the two layers shown above, plus
[scout-rig](https://github.com/mikisvaz/scout-rig) (language bridges, Python) and
[scout-camp](https://github.com/mikisvaz/scout-camp) (servers, cloud, web). Scout
originates from the Rbbt ecosystem; example workflows live in
[Rbbt-Workflows](https://github.com/Rbbt-Workflows). The machine-learning model
subsystem is documented separately in [doc/Model.md](doc/Model.md) and is intentionally
standalone from the agent layer.

## License

MIT-style, see [LICENSE.txt](LICENSE.txt). Issues and PRs welcome.
