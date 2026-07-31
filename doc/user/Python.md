# Python Tasks for Agents

This page explains how to write agent tools in Python. It is intended for
workflow authors who want to use Python libraries for specific tasks while
keeping agent orchestration in Scout-AI.

**You should read this if:** you have Python code or libraries you want to
expose as agent tools.

---

## The idea

A Scout-AI agent is a directory. If that directory contains a `python/`
subdirectory with `.py` files, Scout-AI automatically loads those files as
workflow tasks — exactly like Ruby workflow tasks.

This lets you:
- Keep **agent orchestration** in Scout-AI and Ruby.
- Write **task logic** in Python with full access to Python libraries.

---

## Agent directory layout

```text
MyAgent/
├── start_chat            # system prompt
└── python/
    ├── search.py         # Python tasks
    └── summarize.py
```

No `workflow.rb` file is needed if Python tasks are sufficient.

---

## Writing a Python task

Create a Python function with type hints and register it with `scout.task()`:

```python
# python/greet.py
import scout

def greet(name: str, excited: bool = False) -> str:
    """
    Generate a greeting.

    Args:
        name: Name of the person to greet.
        excited: Whether to add an exclamation mark.

    Returns:
        Greeting text.
    """
    return f"Hello, {name}{'!' if excited else ''}"

scout.task(greet)
```

Each `.py` file directly under `python/` is auto-loaded. A single file can
register multiple functions.

---

## Using the agent

Once the directory is set up, load the agent normally:

```ruby
require 'scout-ai'

agent = LLM::Agent.load_agent('MyAgent', endpoint: :openai)
agent.start
agent.user 'Greet Alice using your tool'
puts agent.chat
```

The Python tasks are available as tools through the workflow auto-export
mechanism. The model can call them just like any other tool.

From the CLI:

```bash
scout-ai agent ask MyAgent "Greet Alice"
```

---

## Guidelines for good Python tasks

A good Python task is a clean, standalone function:

- Use **explicit type hints** — they become the tool's parameter schema.
- Use **sensible defaults** for optional parameters.
- Write a **docstring** with an `Args:` section — it becomes the tool
  description.
- Return **plain strings, lists, or JSON-serializable objects**.
- Keep **side effects explicit and minimal**.

Example:

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

## When to use Python tasks

Use Python when:
- The logic is **easier in Python** (data processing, ML, scientific computing).
- You need **specific Python libraries** (pandas, numpy, scikit-learn, etc.).
- The task is a **standalone function** with typed inputs and a structured
  return.

Keep the **orchestration** (agent loops, delegation, conversation management)
in Ruby/Scout-AI. Use Python for the **leaf tasks** that benefit from Python
libraries.

---

## Common mistakes

- **Putting files in subdirectories**: Only `.py` files directly under
  `python/` are auto-loaded. Don't nest them further.
- **Forgetting `scout.task()`**: Without registration, the function is not
  exposed as a tool.
- **Missing type hints**: The model needs type information to know how to call
  the tool. Without hints, parameters may not be properly described.
- **Not using docstrings**: The docstring becomes the tool description shown to
  the model. Without it, the model doesn't know what the tool does.

---

## Next steps

- [BuildingAgents.md](BuildingAgents.md) — agent lifecycle and Ruby tools.
- [ToolCalling.md](ToolCalling.md) — how tools are declared and called.
- [WritingChats.md](WritingChats.md) — the chat file format.
