# Python-Backed Agent Tasks

This document explains how to write Scout-AI agent tasks in Python. It is
concerned with writing **Python-backed workflow tasks for Ruby-side agents**.
For using Scout-AI chats and agents from Python, see `../python/README.md`.

---

## 1. Key idea

A normal Scout agent is packaged as a directory. If that directory contains a
`python/` subdirectory with `*.py` files, `LLM::Agent.load_agent` auto-loads
those files as workflow tasks and exposes them to the agent exactly like
regular workflow tasks.

This lets you keep:

- **Chat and agent orchestration** in Scout-AI and Ruby
- **Task logic** in Python (with direct access to Python libraries)

For the underlying generic mechanism, see `~/git/scout-rig/doc/PythonWorkflow.md`.

---

## 2. When to use Python-backed tasks

Use Python-backed tasks when:

- The logic is easier to write in Python
- You want access to Python libraries directly
- The task is naturally a standalone function with typed inputs and a structured return value
- You still want Scout workflow behavior (persistence, job directories, provenance, CLI integration)

The most effective pattern is usually:

- Use **Ruby and Scout workflows** to orchestrate the overall control loop
- Use **Python** for the tasks that benefit from Python libraries or Python-first implementations

---

## 3. How agent auto-loading works

`LLM::Agent.load_agent` resolves an agent in this order:

1. Named workflow
2. Agent directory with `workflow.rb`
3. Agent directory with `knowledge_base/`
4. Agent directory with `start_chat`
5. Agent directory with `python/*.py`

The important part for Python-backed agents is in `lib/scout/llm/agent.rb`:

- If the agent directory has a `python/` subdirectory
- And that directory contains `*.py` files
- Scout requires `scout/workflow/python`
- Then calls `PythonWorkflow.load_directory(agent_path.python, 'ScoutAgent')`

> **Convention note:** For agent directories the convention differs slightly
> from the generic `PythonWorkflow` case:
>
> - Generic workflow usage often uses `python/task/<name>.py`
> - Agent auto-loading uses all `*.py` files **directly** under `python/`
>
> Every `*.py` file directly under `python/` is considered during
> auto-loading. Each file may register one or more functions with
> `scout.task(...)`.

---

## 4. Minimal agent directory layout

```text
MyAgent/
├── start_chat
└── python/
    ├── hello.py
    └── summarize.py
```

Optional additions:

```text
MyAgent/
├── start_chat
├── knowledge_base/
└── python/
    ├── hello.py
    └── summarize.py
```

You do **not** need a `workflow.rb` file if the Python tasks are enough.

---

## 5. Minimal Python task example

Create `python/hello.py`:

```python
import scout

def hello(name: str, excited: bool = False) -> str:
    """
    Generate a greeting.

    Args:
        name: Name of the person to greet.
        excited: Whether to add an exclamation mark.

    Returns:
        Greeting text.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(hello)
```

This file does three things:

1. Defines a normal Python function
2. Uses type hints and defaults
3. Registers the function with `scout.task(...)`

That registration is what makes the function visible to `PythonWorkflow`. A
single file can register multiple functions if you want a small family of
related tasks in one place.

---

## 6. Minimal `start_chat`

```text
system:

You are a helpful assistant with a few Python-backed tools.
Use them when helpful.
```

If the agent is loaded with `LLM::Agent.load_agent("MyAgent")`, the Python
tasks are loaded as workflow tasks, and the agent can expose them
automatically just as it would for any other workflow-backed agent.

---

## 7. Loading the agent

```ruby
require 'scout-ai'

agent = LLM::Agent.load_agent('MyAgent', endpoint: :nano)
agent.start
agent.user 'Greet Alice using your tool'
puts agent.chat
```

If the backend supports function calling, the Python-backed tasks are
available as tools through the workflow auto-export mechanism.

---

## 8. Writing good Python tasks

A Python-backed task should behave like a clean, standalone function.

Recommended rules:

- Use explicit **type hints**
- Use **defaults** where possible
- Write a short **docstring** preamble
- Document arguments in Google-style `Args:` sections
- Return plain strings, arrays, or JSON-serializable objects
- Keep side effects explicit and minimal

A better example:

```python
import scout

def top_words(text: str, limit: int = 10) -> list[str]:
    """
    Return the most frequent words in a text.

    Args:
        text: Input text to analyze.
        limit: Maximum number of words to return.

    Returns:
        A list of the most frequent words.
    """
    counts = {}
    for word in text.lower().split():
        counts[word] = counts.get(word, 0) + 1
    return [w for w, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]]

scout.task(top_words)
```

---

## 9. Type mapping

The Python function signature is converted into Scout workflow inputs and
return types through the metadata produced by `scout.task(...)`:

| Python type | Scout type |
|---|---|
| `str` | `:string` |
| `int` | `:integer` |
| `float` | `:float` |
| `bool` | `:boolean` |
| `list[str]` | `:array` |
| path-like metadata | `:file` or `:file_array` |

For the full mapping rules, see `~/git/scout-rig/doc/PythonWorkflow.md`.

---

## 10. Return values

At execution time the Python task prints its result to stdout and Scout
interprets it as follows:

- Valid JSON → parsed as JSON
- Array / file-array outputs → split on newlines if not JSON
- Anything else → stripped string

In practice:

- Simple strings are easy
- Lists are easy
- Dictionaries and richer results should be JSON-serializable

---

## 11. Standalone CLI behavior

A Python task file can also be run directly:

```bash
# Metadata mode — show task description(s)
python python/hello.py --scout-metadata

# Execution mode — run a task
python python/hello.py --name Alice --excited
```

If a file registers multiple functions, metadata returns multiple task
descriptions, and one function can be selected on the CLI by name.

This means your task file is:

- Inspectable on its own
- Testable on its own
- Usable both from Scout and from the command line

---

## 12. Agent-facing pattern

A very effective Scout-AI pattern is:

1. Package Python tasks in `python/`
2. Keep the role instructions in `start_chat`
3. Let a Ruby workflow orchestrate the larger multi-agent pattern when needed

For example:

- A Python task does extraction or scoring
- A Worker agent calls it as a tool
- A Critic agent checks the result
- A Session-like workflow coordinates the whole run and writes artifacts with
  `Step#file`

This keeps the system clean:

- **Python** does task logic
- **Scout workflows** do orchestration
- **Chat files** do policy and agent behavior

---

## 13. Relationship to workflows and skills

A Python-backed agent task is still a workflow task. That means:

- It participates in the normal Scout workflow / tool machinery
- It can be exposed as a tool through `LLM::Agent`
- It fits naturally into workflow-backed `ask` patterns

---

## 14. Cross-references

- [Agent.md](Agent.md) — the `LLM::Agent` abstraction, agent directory layout
- [AgentWorkflow.md](AgentWorkflow.md) — the `chat_task` DSL, `agent` factory
- [MultiAgentPatterns.md](MultiAgentPatterns.md) — how Python-backed agents
  fit into orchestration patterns
- [../Overview.md](../Overview.md) — getting started, endpoint setup
