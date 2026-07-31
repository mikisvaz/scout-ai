# Getting Started with Scout-AI

This guide helps you install Scout-AI, configure your first inference endpoint,
and run your first conversation. It is intended for anyone new to the
framework — both human developers and coding agents.

**You should read this if:** you have never used Scout-AI before.

---

## What is Scout-AI?

Scout-AI is a framework for building AI applications on top of LLMs. It gives
you:

- **Chats**: plain-text conversation files you can inspect, edit, and version.
- **Agents**: reusable, stateful assistants with tools and personas.
- **Tools**: let the model call functions, query databases, or run code.
- **Multi-agent workflows**: orchestrate specialists to solve complex tasks.

Scout-AI is written in Ruby and uses the Scout Workflow engine for
reproducibility and provenance.

---

## Installation

### Prerequisites

- Ruby 3.0+
- An LLM provider account (OpenAI, Anthropic, etc.) or a local model
  (Ollama, vLLM)

### Install Scout-AI

```bash
gem install scout-ai
```

Or, if you're working from the source repository:

```bash
git clone https://github.com/mvazque2/scout-ai.git
cd scout-ai
bundle install
```

### Set your API key

```bash
# For OpenAI
export OPENAI_API_KEY="sk-..."

# For Anthropic
export ANTHROPIC_API_KEY="sk-ant-..."
```

---

## Configure your first endpoint

An **endpoint** is a named configuration for a provider + model. Configure one
once and reference it by name.

```bash
# OpenAI
scout-ai config set openai model=gpt-4o

# Anthropic
scout-ai config set anthropic provider=anthropic model=claude-sonnet-4-20250514
```

---

## Your first conversation

### From the command line

```bash
scout-ai llm ask "Hello! What can you do?"
```

You should see a response from the model.

### Using a specific endpoint

```bash
scout-ai llm ask -e anthropic "Hello!"
```

---

## Your first chat file

Create a file `hello.chat`:

```text
system:

You are a friendly assistant. Keep your answers short.

user:

What is 2 + 2?
```

Run it:

```bash
scout-ai llm ask -c hello.chat
```

---

## Your first agent

Agents are **named directories**. Create one:

```bash
mkdir -p ~/chats/Agent/Greeter
```

Create `~/chats/Agent/Greeter/start_chat`:

```text
system:

You are a friendly greeter. Always greet by name.
```

Use it from the CLI:

```bash
scout-ai agent ask Greeter "Hi, I'm Alice!"
```

Or from Ruby:

```ruby
require 'scout-ai'

agent = LLM.load_agent('Greeter')
agent.start
agent.user "Hi, I'm Alice!"
puts agent.chat
```

---

## Where to go next

- **[CoreConcepts.md](CoreConcepts.md)** — understand chats, agents, tools, and
  endpoints.
- **[WritingChats.md](WritingChats.md)** — master the chat-file format.
- **[BuildingAgents.md](BuildingAgents.md)** — create agents with tools.
- **[Cookbook.md](Cookbook.md)** — quick recipes for common tasks.

If you want to understand how Scout-AI is implemented internally, see the
[../developer/](../developer/) documentation.
