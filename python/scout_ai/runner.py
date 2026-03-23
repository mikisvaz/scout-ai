from __future__ import annotations

import json
import os
import shlex
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterable, List, Optional, Sequence


class CommandError(RuntimeError):
    def __init__(self, cmd: Sequence[str], stdout: str, stderr: str, exit_status: int):
        self.cmd = list(cmd)
        self.stdout = stdout
        self.stderr = stderr
        self.exit_status = exit_status
        message = stderr.strip() or stdout.strip() or f"Command failed with exit status {exit_status}"
        super().__init__(message)


class ScoutRunner:
    """Run Scout-AI CLI commands.

    The Python package deliberately keeps Ruby as the source of truth for chat
    parsing/printing and LLM execution. This runner is the bridge to those CLI
    commands.
    """

    def __init__(self, command: Optional[Sequence[str] | str] = None):
        if command is None:
            command = os.environ.get("SCOUT_AI_COMMAND", "scout-ai")

        if isinstance(command, str):
            self.command = shlex.split(command)
        else:
            self.command = list(command)

        if not self.command:
            raise ValueError("command can not be empty")

    def _run(self, *args: str) -> str:
        cmd = self.command + [str(arg) for arg in args]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise CommandError(cmd, proc.stdout, proc.stderr, proc.returncode)
        return proc.stdout

    def _write_json(self, path: Path, messages: Iterable[dict]) -> None:
        path.write_text(json.dumps(list(messages), ensure_ascii=False, indent=2), encoding="utf-8")

    def json_to_chat_file(self, messages: Iterable[dict], chat_file: Path) -> Path:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8") as handle:
            json.dump(list(messages), handle, ensure_ascii=False, indent=2)
            json_file = Path(handle.name)
        try:
            self._run("llm", "json", "--json", str(json_file), "--output", str(chat_file))
        finally:
            json_file.unlink(missing_ok=True)
        return chat_file

    def chat_file_to_messages(self, chat_file: Path) -> List[dict]:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8") as handle:
            json_file = Path(handle.name)
        try:
            self._run("llm", "json", "--chat", str(chat_file), "--output", str(json_file))
            text = json_file.read_text(encoding="utf-8")
            if text.strip() == "":
                return []
            return json.loads(text)
        finally:
            json_file.unlink(missing_ok=True)

    def render_chat(self, messages: Iterable[dict]) -> str:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".chat", delete=False, encoding="utf-8") as handle:
            chat_file = Path(handle.name)
        try:
            self.json_to_chat_file(messages, chat_file)
            return chat_file.read_text(encoding="utf-8")
        finally:
            chat_file.unlink(missing_ok=True)

    def parse_chat_text(self, text: str) -> List[dict]:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".chat", delete=False, encoding="utf-8") as handle:
            handle.write(text)
            chat_file = Path(handle.name)
        try:
            return self.chat_file_to_messages(chat_file)
        finally:
            chat_file.unlink(missing_ok=True)

    def load_messages(self, path: str | Path, input_format: str = "chat") -> List[dict]:
        path = Path(path)
        if input_format == "json":
            text = path.read_text(encoding="utf-8")
            return [] if text.strip() == "" else json.loads(text)
        if input_format != "chat":
            raise ValueError(f"Unsupported input format: {input_format!r}")
        return self.chat_file_to_messages(path)

    def save_messages(self, path: str | Path, messages: Iterable[dict], output_format: str = "chat") -> Path:
        path = Path(path)
        if output_format == "json":
            path.write_text(json.dumps(list(messages), ensure_ascii=False, indent=2), encoding="utf-8")
            return path
        if output_format != "chat":
            raise ValueError(f"Unsupported output format: {output_format!r}")
        self.json_to_chat_file(messages, path)
        return path

    def ask_messages(self, messages: Iterable[dict], agent_name: Optional[str] = None) -> List[dict]:
        messages = list(messages)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".chat", delete=False, encoding="utf-8") as handle:
            chat_file = Path(handle.name)
        try:
            self.json_to_chat_file(messages, chat_file)
            if agent_name:
                self._run("agent", "ask", str(agent_name), "--chat", str(chat_file))
            else:
                self._run("llm", "ask", "--chat", str(chat_file))
            return self.chat_file_to_messages(chat_file)
        finally:
            chat_file.unlink(missing_ok=True)

    def find_agent_path(self, agent_name: str) -> Optional[Path]:
        try:
            output = self._run("agent", "find", str(agent_name)).strip()
        except CommandError:
            return None
        if not output:
            return None
        return Path(output)

    def load_agent_start_chat(self, agent_name: str) -> List[dict]:
        path = self.find_agent_path(agent_name)
        if path is None:
            return []

        if path.is_file():
            try:
                return self.load_messages(path, input_format="chat")
            except Exception:
                return []

        candidates = [
            path / "start_chat",
            path / "start_chat.chat",
            path / "start_chat.txt",
        ]
        candidates.extend(sorted(path.glob("start_chat.*")))

        for candidate in candidates:
            if candidate.exists() and candidate.is_file():
                try:
                    return self.load_messages(candidate, input_format="chat")
                except Exception:
                    continue

        return []
