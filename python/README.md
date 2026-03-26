# scout-ai Python package

This directory contains the Python package for Scout-AI.

The package provides a lightweight Python interface to Scout-AI chats and agents while keeping Ruby as the source of truth for:

- chat parsing and printing
- LLM execution
- agent execution
- workflow and tool execution

In practice, the Python layer builds chat objects, serializes them through the Scout-AI CLI, and delegates execution back to Scout.

Two complementary Python stories exist in this repository:

- `python/README.md` — use Scout-AI chats and agents from Python
- `doc/PythonAgentTasks.md` — write Python-backed workflow tasks that Ruby agents can load through `PythonWorkflow`

## Requirements

The Python package expects the `scout-ai` command to be available.

Usually this means you should already have the Ruby Scout-AI package installed and configured, together with the Scout stack it depends on.

If the command is not on your `PATH`, you can point the Python package to it with:

    export SCOUT_AI_COMMAND=/full/path/to/scout-ai

## Install from GitHub with pip

Because this repository is primarily a Ruby project and the Python package lives under `python/`, install it with the `subdirectory` fragment:

    pip install "scout-ai @ git+https://github.com/mikisvaz/scout-ai.git@main#subdirectory=python"

You can also omit the explicit package name:

    pip install "git+https://github.com/mikisvaz/scout-ai.git@main#subdirectory=python"

For editable local development from a clone of the repository:

    pip install -e python

## Optional extras

If you also want the machine-learning helpers, you can install optional extras:

    pip install "scout-ai[ml] @ git+https://github.com/mikisvaz/scout-ai.git@main#subdirectory=python"

For Hugging Face / RLHF helpers:

    pip install "scout-ai[huggingface] @ git+https://github.com/mikisvaz/scout-ai.git@main#subdirectory=python"

## Design in one paragraph

The Python package is intentionally thin.

- `Chat` builds an in-memory list of Scout chat messages.
- `Agent` wraps a Scout-AI agent with eager `start_chat` / `current_chat` semantics.
- `ScoutRunner` calls Ruby CLI commands.
- Serialization is delegated to `scout-ai llm json`.
- Execution is delegated to `scout-ai llm ask` or `scout-ai agent ask`.

That means Python does not reimplement Scout chat parsing or workflow/tool execution.

## Main classes

- `scout_ai.Chat` — message builder and plain LLM chat runner
- `scout_ai.Agent` — thin wrapper over Scout agents with eager `current_chat`
- `scout_ai.Message` — message wrapper returned by `chat()`
- `scout_ai.ScoutRunner` — CLI bridge used internally
- `scout_ai.load_agent(name, ...)` — convenience constructor

## Quick `Chat` example

    from scout_ai import Chat

    chat = Chat()
    chat.endpoint("nano")
    chat.system("You are concise")
    chat.user("Say hello")

    delta = chat.ask()
    print(delta.to_json())

    last = chat.chat()
    print(last.role)
    print(last.content)

## Quick `Agent` example

    from scout_ai import load_agent

    agent = load_agent("Planner", endpoint="nano")
    agent.file("README.md")
    agent.user("Summarize this repository")

    message = agent.chat()
    print(message.content)

A more tool-oriented example:

    from scout_ai import load_agent

    agent = load_agent("Planner", endpoint="deep")
    agent.import_("context.chat")
    agent.file("README.md")
    agent.tool("ComputerUse searxng url")
    agent.user("Summarize the file and search for a few references")

    message = agent.chat()
    print(message.content)

## `ask()` vs `chat()` semantics

This distinction is the most important part of the API.

### `Chat.ask()`

- serializes the current chat to a temporary file
- runs `scout-ai llm ask -c <tmp_file>`
- reloads the resulting chat file
- computes the delta between the original and updated message lists
- returns a new `Chat` object containing only the new messages
- does not mutate the original `Chat`

### `Chat.chat()`

- performs the same execution as `ask()`
- appends the new messages to the current `Chat`
- returns the last meaningful new message
- skips a trailing bookkeeping message such as `previous_response_id`

### `Agent.ask()`

- uses the agent-aware command `scout-ai agent ask <agent_name> -c <tmp_file>`
- returns a delta `Chat`
- does not mutate `current_chat`

### `Agent.chat()`

- uses the same agent-aware command
- appends the new messages to `current_chat`
- returns the last meaningful new message

This mirrors how Scout-AI distinguishes between returning a trace/delta and advancing the active conversation.

## Message builder methods

`Chat` exposes a Python-side builder API that mirrors the Ruby chat builder closely.

Common methods include:

- `user(text)`
- `system(text)`
- `assistant(text)`
- `file(path)`
- `directory(path)`
- `image(path)`
- `pdf(path)`
- `import_(path)`
- `import_last(path)`
- `continue_(path)`
- `tool(spec)`
- `use(spec)`
- `introduce(workflow)`
- `task(workflow, task_name, **inputs)`
- `inline_task(...)`
- `exec_task(...)`
- `job(step_or_path)`
- `inline_job(step_or_path)`
- `association(name, path, **options)`
- `endpoint(value)`
- `model(value)`
- `backend(value)`
- `format(value)`
- `option(name, value)`
- `sticky_option(name, value)`
- `persist(value=True)`
- `previous_response_id(value)`

Notes:

- Python uses `import_()` and `continue_()` because `import` and `continue` are reserved keywords.
- `use()` is just an alias for `tool()`.
- endpoint and model settings are represented as messages, just like in Ruby Scout-AI chats.

## Saving and loading chats

You can save or load the Python chat wrapper in either Scout chat format or JSON format.

    from scout_ai import Chat

    chat = Chat().system("You are helpful").user("Summarize this")
    chat.save_chat("example.chat")
    chat.save_json("example.json")

    loaded_chat = Chat.load("example.chat", input_format="chat")
    loaded_json = Chat.load("example.json", input_format="json")

The rendered Scout chat text is also available directly:

    text = chat.render()
    print(text)

## How the conversion works

The Python package deliberately does not implement Scout chat parsing or printing itself.

Instead it always round-trips through:

    scout-ai llm json

That command is used to:

- convert JSON messages to Scout chat text
- convert Scout chat text back to JSON messages

This keeps Ruby as the authority for the chat format.

## Eager agent initialization

`load_agent(name, ...)` initializes `start_chat` and `current_chat` eagerly.

In the current implementation, the Python wrapper tries to resolve the agent path through:

    scout-ai agent find <agent_name>

and then loads the agent's `start_chat` file when it can find one.

That works best for agent directories with an explicit `start_chat` file. If an agent's initial state is synthesized indirectly on the Ruby side rather than stored as a file, the Python wrapper may start from a smaller initial chat.

## Relationship to Python-backed workflow tasks

The Python package described here is for using chats and agents from Python.

It is separate from writing workflow tasks in Python.

If you want to create Python functions that Ruby agents can load and use as workflow tasks, see:

    ../doc/PythonAgentTasks.md

That document explains:

- `scout.task(...)`
- `PythonWorkflow`
- agent directory auto-loading from `python/*.py`

## What pip installs

The pip package installs only the Python interface contained in this directory.
It does not install the Ruby Scout-AI gem or the rest of the Scout stack.

That separation is intentional:

- Ruby remains responsible for the actual Scout-AI runtime
- Python provides an ergonomic interface to that runtime

## Running tests

From the repository root:

    PYTHONPATH=python python -m unittest discover python/tests

A minimal smoke test can also round-trip a chat through the real CLI bridge:

    PYTHONPATH=python python - <<'PY'
    from scout_ai import Chat, ScoutRunner

    runner = ScoutRunner(command=['bin/scout-ai'])
    chat = Chat(runner=runner).system('You are concise').user('Hello world')
    text = chat.render()
    print(text)
    print(Chat.from_text(text, runner=runner).to_json())
    PY
