# Scout-AI Overview

## What Scout-AI is

Scout-AI is an agent and LLM layer built on top of [Scout](https://github.com/mikisvaz/scout-gear).
It provides three things that work together:

1. **A reproducible conversation format** — chats are plain text files (or plain
   Ruby Arrays) that you can edit, version, and inspect.
2. **Tool calling** — Scout `Workflow`s, `KnowledgeBase`s, and MCP servers can be
   exposed as callable tools for any model.
3. **Agent workflows** — stateful agents and multi-agent orchestration encoded as
   typed Scout workflows, not as prompt-text simulations.

The result is a framework where conversations live in files, tools come from real
typed workflows, artifacts are written by workflow jobs, and multi-agent patterns
are inspectable and reproducible.

---

## Installation and setup

Scout-AI is used together with the rest of the Scout stack.

### Gemfile

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

Ruby entry point:

```ruby
require 'scout-ai'
```

### Your first endpoint

Scout-AI prefers **named endpoints**. An endpoint is a YAML file under:

```
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
- CLI: `-e nano` / `--endpoint nano`

### First CLI tests

```bash
# Smallest possible ask
scout-ai llm ask -e nano "Say hi"

# Dry-run: show the compiled conversation without calling the model
scout-ai llm ask -e nano -d "Summarize what this command would do"

# File-assisted ask
scout-ai llm ask -e nano -f README.md "Summarize this file"
```

### Your first persistent chat file

Create `hello.chat`:

```text
endpoint: nano

user:

Say hello in one short sentence.
```

Run:

```bash
scout-ai llm ask -c hello.chat
```

Scout-AI parses the file, calls the backend, and **appends the assistant reply
back to the same file**. The chat file is both the prompt source and the
persistent conversation record. Append a new `user:` block and re-run to
continue the conversation.

See [Chat/Chat.md](Chat/Chat.md) for the full chat file reference.

---

## Core abstractions

| Abstraction       | Module / Class           | Role                                                                              |
|-------------------|--------------------------|-----------------------------------------------------------------------------------|
| **Chat**          | `Chat` (module/Annotation) | A conversation: a plain `Array` of message `Hash`es annotated with a rich DSL.   |
| **Agent**         | `LLM::Agent`             | Stateful wrapper around a Chat: holds a `start_chat`, a `current_chat`, tools, a workflow, and delegation links. |
| **AgentWorkflow** | `AgentWorkflow` mixin    | A `Workflow` mixin that adds `chat_task`, `helper :agent`, and `helper :log_agent` so multi-agent strategies are encoded as Scout workflows. |
| **Backend**       | `LLM::<Provider>` modules | Stateless adapters to model APIs (OpenAI, Anthropic, Ollama, etc.). Shared logic via `Backend::ClassMethods`; overrides via `prepend`. |
| **Tools**         | `LLM` module methods     | Definition and execution of callable tools: workflow tasks, knowledge-base queries, MCP servers, code execution. |
| **Annotation**    | `Annotation` (scout-essentials) | Non-invasive metadata injection onto existing objects (Arrays, Hashes) without subclassing or wrapping. Chat uses this to add DSL methods to a plain Array. |

### How they compose

```
                     ┌─────────────────────────────────────────────┐
                     │                  LLM (module)                │
                     │  LLM.ask  ← entry point for all inference    │
                     │  LLM.chat ← parse/compile chat files         │
                     │  LLM.load_agent ← resolve agent directories   │
                     └───────────────┬───────────────────────────────┘
                                     │
                 ┌───────────────────┼───────────────────────┐
                 ▼                   ▼                       ▼
           ┌──────────┐       ┌──────────────┐       ┌──────────────┐
           │ Backend  │       │  LLM::Agent  │       │    Tools     │
           │ adapter  │       │ (stateful)   │       │ (WF/KB/MCP)  │
           └──────────┘       └──────┬───────┘       └──────┬───────┘
                                    │ holds                │
                              ┌─────▼─────┐          ┌──────▼──────┐
                              │   Chat    │◄────────►│  Workflow   │
                              │ (Array +  │  task    │  tasks as   │
                              │  DSL)     │  tools   │  tools      │
                              └───────────┘          └─────────────┘
                                    │ extends
                              ┌─────▼─────┐
                              │ Annotation│ (non-invasive mixin)
                              └───────────┘
```

1. **`LLM.ask`** is the universal entry point. It accepts any string, file, or
   Array of Hashes, compiles it via `Chat`, resolves options, selects a
   `Backend`, and returns the response.
2. **`LLM::Agent`** wraps a `Chat` with persistent state (`start_chat`,
   `current_chat`), a `Workflow`, knowledge bases, and delegation methods.
3. **`AgentWorkflow`** is a `Workflow` mixin providing `chat_task` and agent
   lifecycle helpers. Multi-agent strategies are Scout workflows that
   `include_workflow AgentWorkflow`.
4. **Backend** modules translate the Chat format into provider-specific API
   calls and responses back. Composition: `class << self; prepend XMethods; include Backend::ClassMethods; end`.
5. **Tools** are defined as tool-definition Hashes paired with execution
   blocks. They are merged into `options[:tools]` and dispatched by the backend.
6. **Annotation** powers the Chat DSL: a plain Array is annotated
   (`Chat.setup(array)`) so it gains `.user`, `.system`, `.ask`, etc., without
   being a subclass or a wrapper object.

---

## Design philosophy

Scout-AI is written in a specific style. Finding the right abstractions is
paramount. If you are writing code in or around Scout-AI — whether as a human
or as a coding agent — understanding this style is the difference between code
that fits the library and code that fights it.

### Chat-as-data (plain Array)

The single most important design decision: **a Chat is a plain `Array` of
message `Hash`es, not an opaque object.** The `Chat` module *annotates* an
Array to add DSL methods, but the underlying data structure is always accessible:

```ruby
chat = Chat.setup([])
chat.user("Hello")
chat.system("You are helpful")

# chat IS an Array:
chat.class            # => Array
chat.length           # => 2
chat.first[:role]     # => "user"
chat.first[:content]  # => "Hello"
chat.select { |m| m[:role] == 'system' }  # works
```

This means chats are **serializable** (plain text ↔ Array), **composable**
(`intro + coda` concatenates Arrays), **introspectable** (filter, map, select
directly), and **cacheable** (`Persist.persist` hashes the message Array).

### Annotation over wrapping

Scout-AI uses scout-essentials' `Annotation` system to add methods to existing
objects **non-invasively**:

```ruby
module Chat
  extend Annotation          # Chat is now an annotation module
  def user(content)
    message(:user, content)
  end
end

# Usage: annotate a plain Array — it remains an Array
messages = [{ role: 'user', content: 'Hi' }]
Chat.setup(messages)
messages.system("Be brief")  # appends { role: 'system', content: 'Be brief' }
messages.ask                 # calls LLM.ask with the messages
```

The annotation adds methods to the **singleton class** of the specific object
instance. It does not change the object's class, and it is removable via
`Annotation.purge(obj)`.

### Convention over configuration

Scout-AI discovers components by convention rather than registration:

- **Agents** are resolved by directory convention: `workflow.rb`, `start_chat`,
  `knowledge_base/`. `LLM.load_agent` searches `Scout.workflows`,
  `Scout.Agent`, `Scout.var.Agent`, and `Scout.chats.Agent`.
- **Backends** are modules under `LLM::` with `TAG` and `DEFAULT_MODEL`
  constants, composed via the `prepend`/`include` pattern.
- **Endpoints** are YAML files in `~/.scout/etc/AI/<name>`.

### Module composition over inheritance

Scout-AI avoids deep class hierarchies. Behavior is split across Ruby modules
that reopen the same class:

```
lib/scout/llm/agent.rb          — core
lib/scout/llm/agent/chat.rb     — chat delegation methods
lib/scout/llm/agent/iterate.rb  — iteration patterns
lib/scout/llm/agent/delegate.rb — multi-agent delegation
lib/scout/llm/agent/workflow.rb — AgentWorkflow mixin + chat_task DSL
```

### Idiomatic vs. non-idiomatic code

#### Example 1: Processing a chat before sending to the model

**❌ Non-idiomatic** — wrapping Chat in a custom class, reimplementing logic:

```ruby
class ChatProcessor
  def initialize(chat_array)
    @chat = chat_array
  end

  def remove_tool_messages
    @chat.reject! { |m| m[:role] == 'tool' }
  end

  def send_to_model(provider, api_key)
    client = OpenAI::Client.new(api_key)
    response = client.chat(messages: @chat)
    @chat << { role: 'assistant', content: response }
  end
end
```

**✅ Idiomatic** — use the Chat DSL and delegate to `LLM.ask`:

```ruby
chat = Chat.setup(messages)
chat.remove_role(:tool)
chat.ask(endpoint: :nano)
```

*Why:* Uses the existing DSL instead of reimplementing; delegates to `LLM.ask`
which handles backend dispatch, caching, persistence; the Chat remains a plain
Array.

#### Example 2: Building a multi-agent orchestration

**❌ Non-idiomatic** — hand-rolled orchestrator reimplementing API calls:

```ruby
class Orchestrator
  def initialize(question)
    @question = question
  end

  def run
    planner_messages = [{ role: 'user', content: @question }]
    planner_response = call_llm(planner_messages)

    worker_messages = [{ role: 'user', content: planner_response }]
    worker_response = call_llm(worker_messages)
    worker_response
  end

  def call_llm(messages)
    client = OpenAI::Client.new
    response = client.chat(parameters: { messages: messages })
    response.dig('choices', 0, 'message', 'content')
  end
end
```

**✅ Idiomatic** — encode the strategy as a Scout Workflow with AgentWorkflow:

```ruby
require 'scout-ai'

module Orchestration
  extend Workflow
  self.include_workflow AgentWorkflow

  input :chat, :text, 'Chat input'
  extension :chat

  chat_task :ask do
    agent = self.agent(nil, chat: chat)
    agent.start_chat.system "You are an orchestrator."
    agent.socialize
    agent.user "Plan and execute this request using specialists."
    agent.chat
  end
end
```

*Why:* Uses `AgentWorkflow` → gets `chat_task`, `helper :agent`, `helper :log_agent`.
Uses `Agent` → gets stateful chats, tool wiring, delegation. Uses `Chat` DSL →
`.user`, `.system`, `.chat`, `.answer`. The entire strategy is a Scout Workflow
→ inputs are typed, jobs are cached, dependencies tracked, CLI integration is
automatic. No reinvention of API calls, caching, or tool calling.

> **Guiding question when writing Scout-AI code:**
> *"Can I express this as a composition of existing abstractions, or does it
> need a new one? If new, is its boundary crisp?"*

See [Agent/Agent.md](Agent/Agent.md), [Agent/AgentWorkflow.md](Agent/AgentWorkflow.md),
and [Agent/Delegation.md](Agent/Delegation.md) for the full agent story.

---

## Document reading guide

| If you want to... | Read this |
|---|---|
| Understand the conversation format | [Chat/Chat.md](Chat/Chat.md) |
| Understand chat file roles, parsing, compilation | [Chat/Chat.md](Chat/Chat.md) |
| Learn how prompt strategies (tool pruning) work | [Chat/PromptStrategies.md](Chat/PromptStrategies.md) |
| Understand chat persistence and the `.chat` format | [Chat/Persistence.md](Chat/Persistence.md) |
| Build and use stateful agents | [Agent/Agent.md](Agent/Agent.md) |
| Have agents delegate to each other | [Agent/Delegation.md](Agent/Delegation.md) |
| Encode multi-agent strategies as workflows | [Agent/AgentWorkflow.md](Agent/AgentWorkflow.md) |
| See concrete multi-agent patterns | [Agent/MultiAgentPatterns.md](Agent/MultiAgentPatterns.md) |
| Configure endpoints and backends | [Backends/Backends.md](Backends/Backends.md) |
| Define and call tools | [Tools/Tools.md](Tools/Tools.md) |
| Expose Scout workflows as tools | [Tools/WorkflowTools.md](Tools/WorkflowTools.md) |
| Use knowledge bases and RAG | [Tools/KnowledgeBase.md](Tools/KnowledgeBase.md) |
| Integrate MCP servers | [Tools/MCP.md](Tools/MCP.md) |
| Track inference provenance | [Provenance/Provenance.md](Provenance/Provenance.md) |
| Reference CLI commands | [Commands/Commands.md](Commands/Commands.md) |

### Suggested reading order

1. This document (Overview)
2. [Chat/Chat.md](Chat/Chat.md) — the data model everything else builds on
3. [Agent/Agent.md](Agent/Agent.md) — stateful conversations and tool wiring
4. [Tools/Tools.md](Tools/Tools.md) — how tools are defined and called
5. [Backends/Backends.md](Backends/Backends.md) — endpoints and inference
6. Then specialized topics as needed (Delegation, AgentWorkflow, Provenance, etc.)
