from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Mapping


@dataclass
class Message:
    """Small wrapper around a Scout chat message.

    Messages are still serialized as plain ``{"role": ..., "content": ...}``
    dictionaries, but this wrapper makes the Python API easier to work with and
    gives ``chat()`` a useful return value whose string representation is the
    message content.
    """

    role: str
    content: Any = ""
    extra: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_data(cls, data: Any) -> "Message":
        if isinstance(data, cls):
            return cls(data.role, data.content, dict(data.extra))

        if isinstance(data, Mapping):
            role = str(data.get("role", ""))
            content = data.get("content", "")
            extra = {k: v for k, v in data.items() if k not in ("role", "content")}
            return cls(role=role, content=content, extra=extra)

        raise TypeError(f"Unsupported message type: {type(data)!r}")

    def to_dict(self) -> Dict[str, Any]:
        data = {"role": self.role, "content": self.content}
        data.update(self.extra)
        return data

    def get(self, key: str, default: Any = None) -> Any:
        if key == "role":
            return self.role
        if key == "content":
            return self.content
        return self.extra.get(key, default)

    def __getitem__(self, key: str) -> Any:
        if key == "role":
            return self.role
        if key == "content":
            return self.content
        return self.extra[key]

    def __str__(self) -> str:
        return "" if self.content is None else str(self.content)

    def __repr__(self) -> str:
        return f"Message(role={self.role!r}, content={self.content!r})"
