# Cookbook

This page collects small, ready-to-use examples for common Scout-AI tasks. It
is intended for workflow authors who want quick, practical patterns.

**You should read this if:** you want copy-paste examples for specific tasks.

---

## Quick one-shot question

```bash
scout-ai llm ask "What is the capital of France?"
```

```ruby
agent = LLM.agent(endpoint: :openai)
agent.start
agent.user "What is the capital of France?"
puts agent.chat
```

---

## Simple assistant with a system prompt

```ruby
agent = LLM.agent(endpoint: :openai)
agent.start_chat.system "You are a helpful assistant. Answer concisely."
agent.start
agent.user "Explain recursion in one sentence."
puts agent.chat
```

---

## Chat file with endpoint and model

```text
endpoint: anthropic
model: claude-sonnet-4-20250514

system:

You are a code reviewer.

user:

Review this function for bugs:

def add(a, b)
  a + b
end
```

Save as `review.chat` and run:

```bash
scout-ai llm ask -c review.chat
```

---

## Agent with a workflow tool

```ruby
agent = LLM.agent(endpoint: :openai)
agent.workflow do
  task :search => :string do |query|
    "Results for '#{query}': ..."
  end
end
agent.start
agent.user "Search for Ruby tutorials."
puts agent.chat
```

---

## Agent from a directory

Directory layout:

```
Agent/
  Greeter/
    start_chat
```

`start_chat`:

```text
system:

You are a friendly greeter. Always greet by name.

user:

Hello!
```

Use it:

```ruby
agent = LLM.load_agent('Greeter')
agent.start
agent.user "Hi, I'm Alice."
puts agent.chat
```

From CLI:

```bash
scout-ai agent ask Greeter "Hi, I'm Alice."
```

---

## Structured JSON output

```ruby
agent = LLM.agent(endpoint: :openai)
agent.start
agent.user 'Return a JSON object: {"name": "Ruby", "type": "language", "year": 1995}'
result = agent.json
puts result["name"]   # => "Ruby"
```

With a schema:

```ruby
schema = {
  name: 'evaluation',
  type: 'object',
  properties: {
    score: { type: :integer },
    feedback: { type: :string }
  },
  required: [:score, :feedback]
}

agent.json_format(schema)
```

---

## Importing a file into the conversation

```text
system:

You are a document analyzer.

file: report.pdf

user:

Summarize the key findings.
```

---

## Multi-turn conversation

```ruby
agent = LLM.agent(endpoint: :openai)
agent.start_chat.system "You are a patient tutor."
agent.start

agent.user "What is a variable?"
puts agent.chat

agent.user "How is it different from a constant?"
puts agent.chat   # remembers the previous turn
```

---

## Delegation: orchestrator with specialist

```ruby
# Load a specialist
searcher = LLM.load_agent('Searcher')

# Set up the orchestrator
orchestrator = LLM.load_agent('Manager')
orchestrator.socialize  # model can call ask(agent: 'Searcher', prompt: ...)

orchestrator.start
orchestrator.user "Research the latest advances in protein folding."
orchestrator.chat
```

---

## Multi-agent pipeline in a workflow

```ruby
class AnalysisPipeline < Workflow
  include AgentWorkflow

  chat_task :plan do |objective|
    agent = self.agent('Planner', chat: chat)
    agent.start
    agent.user objective
    agent.chat
  end

  chat_task :execute do |objective, plan|
    agent = self.agent('Executor', chat: chat)
    agent.start
    agent.user "Objective: #{objective}\nPlan: #{plan}"
    agent.chat
  end

  chat_task :review do |result|
    agent = self.agent('Critic', chat: chat)
    agent.start
    agent.user "Review: #{result}"
    agent.chat
  end
end
```

---

## Python task in an agent

```text
MyAgent/
├── start_chat
└── python/
    └── analyze.py
```

```python
# python/analyze.py
import scout

def word_count(text: str) -> dict:
    """
    Count words in text.

    Args:
        text: Input text.

    Returns:
        Dictionary with word counts.
    """
    words = text.lower().split()
    counts = {}
    for w in words:
        counts[w] = counts.get(w, 0) + 1
    return counts

scout.task(word_count)
```

```ruby
agent = LLM::Agent.load_agent('MyAgent', endpoint: :openai)
agent.start
agent.user "Count the words in: the quick brown fox"
puts agent.chat
```

---

## Error handling with retry

```ruby
agent = LLM.agent(endpoint: :openai)
agent.process_exception = Proc.new do |e|
  if e.message =~ /rate limit/i
    sleep 10
    true  # retry
  else
    false # re-raise
  end
end
```

---

## Clearing context between phases

```text
system:

You are a project manager.

user:

Phase 1: Analyze requirements.

clear:

user:

Phase 2: Design the system. (Phase 1 context is cleared)
```

---

## Knowledge base tool

```text
system:

You are a bioinformatics assistant.

kb: gene_db [genes proteins diseases]

user:

What proteins are associated with BRCA1?
```

---

## MCP tool

```text
system:

You have access to an external search service.

mcp: https://api.example.com/mcp/ [search]

user:

Search for recent papers on climate change.
```
