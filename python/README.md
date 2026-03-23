# scout-ai Python package

This directory contains the Python package for Scout-AI.

The package provides a lightweight Python interface to Scout-AI chats and agents while keeping Ruby as the source of truth for:

- chat parsing and printing
- LLM execution
- agent execution
- workflow and tool execution

In practice, the Python layer builds chat objects, serializes them through the Scout-AI CLI, and delegates execution back to Scout.

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

## Quick example

    from scout_ai import load_agent

    agent = load_agent("Planner", endpoint="nano")
    agent.file("README.md")
    agent.user("Summarize this repository")

    message = agent.chat()
    print(message.content)

## Chat example

    from scout_ai import Chat

    chat = Chat()
    chat.system("You are concise")
    chat.user("Say hello")

    delta = chat.ask()
    print(delta.to_json())

## What pip installs

The pip package installs only the Python interface contained in this directory.
It does not install the Ruby Scout-AI gem or the rest of the Scout stack.

That separation is intentional:

- Ruby remains responsible for the actual Scout-AI runtime
- Python provides an ergonomic interface to that runtime

## Package layout

- `scout_ai.chat.Chat` — chat builder and execution wrapper
- `scout_ai.agent.Agent` — thin wrapper over Scout agents with eager `current_chat`
- `scout_ai.runner.ScoutRunner` — CLI bridge used internally
- `scout_ai.message.Message` — message wrapper returned by `chat()`

## Running tests

From the repository root:

    PYTHONPATH=python python -m unittest discover python/tests
