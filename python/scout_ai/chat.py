from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence

from .message import Message
from .runner import ScoutRunner

_RESERVED_MESSAGE_ROLES = {"previous_response_id"}


class Chat:
    """Python representation of a Scout chat.

    The chat is kept as a list of messages. Whenever Scout needs to parse,
    print, or execute the conversation, the package delegates that work to the
    Ruby CLI through :class:`ScoutRunner`.
    """

    def __init__(self, messages: Optional[Iterable[dict | Message]] = None, runner: Optional[ScoutRunner] = None):
        self.runner = runner or ScoutRunner()
        self.messages: List[Message] = [Message.from_data(message) for message in (messages or [])]

    @classmethod
    def load(cls, path: str | Path, input_format: str = "chat", runner: Optional[ScoutRunner] = None) -> "Chat":
        runner = runner or ScoutRunner()
        messages = runner.load_messages(path, input_format=input_format)
        return cls(messages, runner=runner)

    @classmethod
    def from_text(cls, text: str, runner: Optional[ScoutRunner] = None) -> "Chat":
        runner = runner or ScoutRunner()
        messages = runner.parse_chat_text(text)
        return cls(messages, runner=runner)

    def branch(self) -> "Chat":
        return Chat([message.to_dict() for message in self.messages], runner=self.runner)

    copy = branch

    def to_dicts(self) -> List[Dict[str, Any]]:
        return [message.to_dict() for message in self.messages]

    def to_json(self) -> List[Dict[str, Any]]:
        return self.to_dicts()

    def render(self) -> str:
        return self.runner.render_chat(self.to_dicts())

    def save(self, path: str | Path, output_format: str = "chat") -> Path:
        return self.runner.save_messages(path, self.to_dicts(), output_format=output_format)

    def save_json(self, path: str | Path) -> Path:
        return self.save(path, output_format="json")

    def save_chat(self, path: str | Path) -> Path:
        return self.save(path, output_format="chat")

    def message(self, role: str, content: Any = "", **extra: Any) -> "Chat":
        self.messages.append(Message(str(role), content, dict(extra)))
        return self

    def extend(self, messages: Iterable[dict | Message | "Chat"] | dict | Message | "Chat") -> "Chat":
        if isinstance(messages, Chat):
            iterable = messages.messages
        elif isinstance(messages, (dict, Message)):
            iterable = [messages]
        else:
            iterable = messages
        for message in iterable:
            self.messages.append(Message.from_data(message))
        return self

    append = extend

    def user(self, content: Any) -> "Chat":
        return self.message("user", content)

    def system(self, content: Any) -> "Chat":
        return self.message("system", content)

    def assistant(self, content: Any) -> "Chat":
        return self.message("assistant", content)

    def import_(self, file: str | Path) -> "Chat":
        return self.message("import", str(file))

    def import_last(self, file: str | Path) -> "Chat":
        return self.message("last", str(file))

    def last(self, file: str | Path) -> "Chat":
        return self.import_last(file)

    def continue_(self, file: str | Path) -> "Chat":
        return self.message("continue", str(file))

    def file(self, file: str | Path) -> "Chat":
        return self.message("file", str(file))

    def directory(self, directory: str | Path) -> "Chat":
        return self.message("directory", str(directory))

    def image(self, file: str | Path) -> "Chat":
        return self.message("image", str(file))

    def pdf(self, file: str | Path) -> "Chat":
        return self.message("pdf", str(file))

    def introduce(self, workflow: str) -> "Chat":
        return self.message("introduce", str(workflow))

    def tool(self, *parts: Any) -> "Chat":
        parts = [str(part) for part in parts if part is not None]
        return self.message("tool", "\n".join(parts))

    def use(self, *parts: Any) -> "Chat":
        return self.tool(*parts)

    def mcp(self, content: Any) -> "Chat":
        return self.message("mcp", content)

    def task(self, workflow: str, task_name: str, **inputs: Any) -> "Chat":
        content = " ".join([str(workflow), str(task_name)] + [f"{key}={value}" for key, value in inputs.items()])
        return self.message("task", content.strip())

    def inline_task(self, workflow: str, task_name: str, **inputs: Any) -> "Chat":
        content = " ".join([str(workflow), str(task_name)] + [f"{key}={value}" for key, value in inputs.items()])
        return self.message("inline_task", content.strip())

    def exec_task(self, workflow: str, task_name: str, **inputs: Any) -> "Chat":
        content = " ".join([str(workflow), str(task_name)] + [f"{key}={value}" for key, value in inputs.items()])
        return self.message("exec_task", content.strip())

    def job(self, step: Any) -> "Chat":
        value = getattr(step, "path", step)
        return self.message("job", str(value))

    def inline_job(self, step: Any) -> "Chat":
        value = getattr(step, "path", step)
        return self.message("inline_job", str(value))

    def association(self, name: str, path: str | Path, **options: Any) -> "Chat":
        parts = [str(name), str(path)] + [f"{key}={value}" for key, value in options.items()]
        return self.message("association", " ".join(parts))

    def option(self, name: str, value: Any) -> "Chat":
        return self.message("option", f"{name} {value}")

    def sticky_option(self, name: str, value: Any) -> "Chat":
        return self.message("sticky_option", f"{name} {value}")

    def endpoint(self, value: Any) -> "Chat":
        return self.message("endpoint", value)

    def model(self, value: Any) -> "Chat":
        return self.message("model", value)

    def backend(self, value: Any) -> "Chat":
        return self.message("backend", value)

    def format(self, value: Any) -> "Chat":
        return self.message("format", value)

    def persist(self, value: Any = True) -> "Chat":
        return self.message("persist", value)

    def previous_response_id(self, value: Any) -> "Chat":
        return self.message("previous_response_id", value)

    def clear(self, content: Any = "") -> "Chat":
        return self.message("clear", content)

    def skip(self, content: Any = "") -> "Chat":
        return self.message("skip", content)

    def answer(self) -> Optional[str]:
        message = self.last_message()
        if message is None:
            return None
        return message.content

    def last_message(self, ignore_roles: Sequence[str] = tuple(_RESERVED_MESSAGE_ROLES)) -> Optional[Message]:
        ignored = {str(role) for role in ignore_roles}
        for message in reversed(self.messages):
            if message.role not in ignored:
                return message
        return None

    def _delta_from_updated_messages(self, updated_messages: Iterable[dict | Message]) -> "Chat":
        old = self.to_dicts()
        updated = [Message.from_data(message).to_dict() for message in updated_messages]

        prefix_len = 0
        for current, new in zip(old, updated):
            if current == new:
                prefix_len += 1
            else:
                break

        return Chat(updated[prefix_len:], runner=self.runner)

    def ask(self, agent_name: Optional[str] = None) -> "Chat":
        updated_messages = self.runner.ask_messages(self.to_dicts(), agent_name=agent_name)
        return self._delta_from_updated_messages(updated_messages)

    def chat(self, agent_name: Optional[str] = None) -> Optional[Message]:
        delta = self.ask(agent_name=agent_name)
        self.extend(delta)
        return delta.last_message()

    def __len__(self) -> int:
        return len(self.messages)

    def __iter__(self) -> Iterator[Message]:
        return iter(self.messages)

    def __getitem__(self, item: int) -> Message:
        return self.messages[item]

    def __repr__(self) -> str:
        return f"Chat(messages={self.messages!r})"
