from __future__ import annotations

from typing import Any, Optional

from .chat import Chat
from .runner import ScoutRunner


class Agent:
    """Thin Python wrapper over Scout-AI agents.

    The object mirrors Scout-AI's ``start_chat`` / ``current_chat`` split while
    delegating actual execution to the Ruby CLI.
    """

    def __init__(
        self,
        name: str,
        runner: Optional[ScoutRunner] = None,
        start_chat: Optional[Chat] = None,
        endpoint: Any = None,
        model: Any = None,
        backend: Any = None,
        **options: Any,
    ):
        self.name = name
        self.runner = runner or ScoutRunner()

        if start_chat is None:
            start_chat = Chat(self.runner.load_agent_start_chat(name), runner=self.runner)
        elif not isinstance(start_chat, Chat):
            start_chat = Chat(start_chat, runner=self.runner)
        else:
            start_chat.runner = self.runner

        if endpoint is not None:
            start_chat.endpoint(endpoint)
        if model is not None:
            start_chat.model(model)
        if backend is not None:
            start_chat.backend(backend)
        for key, value in options.items():
            if value is not None:
                start_chat.option(key, value)

        self.start_chat = start_chat
        self.current_chat = self.start_chat.branch()

    def start(self, chat: Optional[Chat] = None) -> Chat:
        if chat is None:
            self.current_chat = self.start_chat.branch()
        elif isinstance(chat, Chat):
            self.current_chat = chat.branch()
            self.current_chat.runner = self.runner
        else:
            self.current_chat = Chat(chat, runner=self.runner)
        return self.current_chat

    reset = start

    def ask(self) -> Chat:
        return self.current_chat.ask(agent_name=self.name)

    def chat(self):
        delta = self.ask()
        self.current_chat.extend(delta)
        return delta.last_message()

    def save(self, path, output_format: str = "chat"):
        return self.current_chat.save(path, output_format=output_format)

    def __getattr__(self, name: str):
        attribute = getattr(self.current_chat, name)
        if callable(attribute):
            def delegated(*args, **kwargs):
                result = attribute(*args, **kwargs)
                if result is self.current_chat:
                    return self
                return result
            return delegated
        return attribute

    def __repr__(self) -> str:
        return f"Agent(name={self.name!r}, current_chat={self.current_chat!r})"


def load_agent(name: str, runner: Optional[ScoutRunner] = None, **kwargs: Any) -> Agent:
    return Agent(name=name, runner=runner, **kwargs)
