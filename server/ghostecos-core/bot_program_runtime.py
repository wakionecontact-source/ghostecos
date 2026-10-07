"""Validation and execution bridge for GhostChat's visual bot builder.

Programs are deliberately JSON-only. This module is mirrored by the public
``ghostapi.ghostbot.BotProgram`` model, while execution still uses the SDK's
normal Bot WebSocket and ``message.send`` action.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

MAX_COMMANDS = 50
MAX_REPLY_LENGTH = 4_000
MAX_DESCRIPTION_LENGTH = 64
_COMMAND_RE = re.compile(r"^/[a-z][a-z0-9_]{0,31}$")


def validate_bot_program(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise TypeError("program must be a JSON object")
    if set(value) - {"version", "commands", "fallback"}:
        raise ValueError("program contains unsupported fields")
    if type(value.get("version")) is not int or value.get("version") != 1:
        raise ValueError("unsupported bot program version")
    raw_commands = value.get("commands", [])
    if not isinstance(raw_commands, list) or len(raw_commands) > MAX_COMMANDS:
        raise ValueError(f"commands must contain no more than {MAX_COMMANDS} entries")
    fallback = value.get("fallback", "")
    if not isinstance(fallback, str) or len(fallback) > MAX_REPLY_LENGTH:
        raise ValueError("fallback must be a string of at most 4000 characters")

    commands: list[dict[str, str]] = []
    seen: set[str] = set()
    for raw in raw_commands:
        if not isinstance(raw, Mapping):
            raise ValueError("each command must be an object")
        if set(raw) - {"command", "description", "response"}:
            raise ValueError("command contains unsupported fields")
        command = raw.get("command")
        description = raw.get("description")
        response = raw.get("response")
        if not all(isinstance(item, str) for item in (command, description, response)):
            raise ValueError("command, description, and response must be strings")
        command = command.strip().lower()
        description = description.strip()
        response = response.strip()
        if not _COMMAND_RE.fullmatch(command):
            raise ValueError("commands must look like /start and use ASCII letters, digits, or _")
        if command in seen:
            raise ValueError(f"duplicate command: {command}")
        if not description or len(description) > MAX_DESCRIPTION_LENGTH:
            raise ValueError("description must contain 1 to 64 characters")
        if not response or len(response) > MAX_REPLY_LENGTH:
            raise ValueError("response must contain 1 to 4000 characters")
        seen.add(command)
        commands.append(
            {"command": command, "description": description, "response": response}
        )
    return {"version": 1, "commands": commands, "fallback": fallback.strip()}


def attach_bot_program(bot: Any, value: Any) -> None:
    """Attach one validated command/fallback program to a ``ghostapi.Bot``."""
    program = validate_bot_program(value)
    by_name = {item["command"]: item for item in program["commands"]}

    def on_message(event: Any) -> None:
        data = event.data
        raw_text = data.get("text")
        if not isinstance(raw_text, str) or not raw_text.strip():
            return
        first_word = raw_text.strip().split(maxsplit=1)[0].split("@", 1)[0].lower()
        matched = by_name.get(first_word)
        if matched is not None:
            reply = matched["response"]
        elif first_word == "/help":
            lines = ["Доступные команды:"]
            lines.extend(
                f"{item['command']} — {item['description']}"
                for item in program["commands"]
            )
            reply = "\n".join(lines)[:MAX_REPLY_LENGTH]
        else:
            reply = program["fallback"]
        if not reply:
            return

        user_id = data.get("from_user_id")
        username = data.get("from_username")
        if type(user_id) is int and user_id > 0:
            bot.send_message(user_id=user_id, text=reply)
        elif isinstance(username, str) and username.strip():
            bot.send_message(username, reply)

    bot.on("message.received", on_message)
