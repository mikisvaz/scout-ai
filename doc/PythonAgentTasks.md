# Python-backed Agent Tasks

This guide explains how to write Scout-AI agent tasks in Python.

This document is about writing Python-backed workflow tasks for Ruby-side agents. If you want to use Scout-AI chats and agents from Python, see `../python/README.md`.

The key idea is simple:

- a normal Scout agent can be packaged as a directory
- if that directory contains a `python/` subdirectory with `*.py` files, `LLM::Agent.load_agent` can auto-load those files as workflow tasks
- the resulting tasks are exposed to the agent exactly like regular workflow tasks

This gives you a convenient way to keep:

- chat and agent orchestration in Scout-AI and Ruby
- task logic in Python

For the underlying generic mechanism, see `~/git/scout-rig/doc/PythonWorkflow.md`.

## 1. When to use Python-backed tasks

Use Python-backed agent tasks when:

- the logic is easier to write in Python
- you want access to Python libraries directly
- the task is naturally a standalone function with typed inputs and a structured return value
- you still want Scout workflow behavior such as persistence, job directories, provenance, and CLI integration

Do not use this mechanism just to avoid Ruby entirely. The most effective pattern is usually:

- use Ruby and Scout workflows to orchestrate the overall control loop
- use Python for the tasks that benefit from Python libraries or Python-first implementations

## 2. How agent auto-loading works

`LLM::Agent.load_agent` resolves an agent in this order:

- named workflow
- agent directory with `workflow.rb`
- agent directory with `knowledge_base/`
- agent directory with `start_chat`
- agent directory with `python/*.py`

The important part for Python-backed agents is in `lib/scout/llm/agent.rb`:

- if the agent directory has a `python/` subdirectory
- and that directory contains `*.py` files
- Scout requires `scout/workflow/python`
- then calls `PythonWorkflow.load_directory(agent_path.python, 'ScoutAgent')`

This means that for agent directories the convention is slightly different from the generic `PythonWorkflow` case:

- generic workflow usage often uses `python/task/<name>.py`
- agent auto-loading uses all `*.py` files directly under `python/`

So for an agent directory, place task files directly in `python/`.

Two practical notes:

- every `*.py` file directly under `python/` is considered during auto-loading
- each file may register one or more functions with `scout.task(...)`

## 3. Minimal agent directory layout

A minimal Python-backed agent directory can look like this:

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

You do not need a `workflow.rb` file if the Python tasks are enough.

## 4. Minimal Python task example

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

- defines a normal Python function
- uses type hints and defaults
- registers the function with `scout.task(...)`

That registration is what makes the function visible to `PythonWorkflow`.

A single file can register multiple functions if you want a small family of related tasks in one place.

## 5. Minimal `start_chat`

A matching `start_chat` can be very small:

```text
system:

You are a helpful assistant with a few Python-backed tools.
Use them when helpful.
```

If the agent is loaded with `LLM::Agent.load_agent("MyAgent")`, the Python tasks are loaded as workflow tasks, and the agent can expose them automatically just as it would for any other workflow-backed agent.

## 6. Loading the agent

Ruby:

```ruby
require 'scout-ai'

agent = LLM::Agent.load_agent('MyAgent', endpoint: :nano)
agent.start
agent.user 'Greet Alice using your tool'
puts agent.chat
```

If the backend supports function calling, the Python-backed tasks are available as tools through the workflow auto-export mechanism.

## 7. Writing good Python tasks

A Python-backed task should behave like a clean, standalone function.

Recommended rules:

- use explicit type hints
- use defaults where possible
- write a short docstring preamble
- document arguments in Google-style `Args:` sections
- return plain strings, arrays, or JSON-serializable objects
- keep side effects explicit and minimal

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

## 8. Type mapping

The Python function signature is converted into Scout workflow inputs and return types through the metadata produced by `scout.task(...)`.

Important mappings include:

- `str` -> `:string`
- `int` -> `:integer`
- `float` -> `:float`
- `bool` -> `:boolean`
- `list[str]` -> `:array`
- `path`-like metadata -> `:file` or `:file_array`

For the full mapping rules, see `~/git/scout-rig/doc/PythonWorkflow.md`.

## 9. Return values

At execution time the Python task prints its result to stdout and Scout interprets it as follows:

- valid JSON -> parsed as JSON
- array/file-array outputs -> split on newlines if not JSON
- anything else -> stripped string

In practice, this means:

- simple strings are easy
- lists are easy
- dictionaries and richer results should usually be JSON-serializable

If you want structured outputs, return JSON-friendly Python objects.

## 10. Standalone CLI behavior

A Python task file can also be run directly.

Metadata mode:

```bash
python python/hello.py --scout-metadata
```

Execution mode:

```bash
python python/hello.py --name Alice --excited
```

If a file registers multiple functions, metadata returns multiple task descriptions, and one function can be selected on the CLI by name.

This is useful because it means your task file is:

- inspectable on its own
- testable on its own
- usable both from Scout and from the command line

## 11. Agent-facing pattern

A very effective Scout-AI pattern is:

- package Python tasks in `python/`
- keep the role instructions in `start_chat`
- let a Ruby workflow orchestrate the larger multi-agent pattern when needed

For example:

- a Python task does extraction or scoring
- a Worker agent calls it as a tool
- a Critic agent checks the result
- a Session-like workflow coordinates the whole run and writes artifacts with `Step#file`

This keeps the system clean:

- Python does task logic
- Scout workflows do orchestration
- chat files do policy and agent behavior

## 12. Relationship to workflows and skills

A Python-backed agent task is still a workflow task.

That matters because it means:

- it participates in the normal Scout workflow/tool machinery
- it can be exposed as a tool through `LLM::Agent`
- it fits naturally into workflow-backed `ask` patterns

If you come from systems that talk about “skills”, the Scout-AI equivalent here is:

- `python/*.py` gives you executable task logic
- `start_chat` gives you the instructional layer
- the agent directory bundles them together as a reusable toolkit

## 13. A slightly larger example

Directory:

```text
TextAgent/
├── start_chat
└── python/
    ├── top_words.py
    └── count_chars.py
```

`python/count_chars.py`:

```python
import scout

def count_chars(text: str) -> int:
    """
    Count characters in a string.

    Args:
        text: Input text.

    Returns:
        Character count.
    """
    return len(text)

scout.task(count_chars)
```

Then in Ruby:

```ruby
agent = LLM::Agent.load_agent('TextAgent', endpoint: :nano)
agent.start
agent.user 'Use your tools to count characters in hello world and list the top words'
puts agent.chat
```

## 14. What to read next

For a practical introduction to chats and agents, read:

- `doc/USER_GUIDE.md`
- `doc/Agent.md`
- `doc/Chat.md`

For the generic Python workflow mechanism, read:

- `~/git/scout-rig/doc/PythonWorkflow.md`

For the underlying Scout workflow model, read:

- `~/git/scout-gear/doc/Workflow.md`
