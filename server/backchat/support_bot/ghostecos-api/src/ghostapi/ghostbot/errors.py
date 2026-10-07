"""Public exceptions raised by the GhostChat bot SDK."""

from __future__ import annotations


class GhostBotError(RuntimeError):
    """Base error raised by the GhostChat bot client."""


class BotNetworkError(GhostBotError):
    """The client couldn't connect to or write to the Bot API."""


class BotProtocolError(GhostBotError):
    """The server sent a frame or response that doesn't match the protocol."""


class BotAPIError(GhostBotError):
    """The GhostChat server rejected an API operation."""

    def __init__(self, status: int | None, message: str) -> None:
        self.status = status
        label = f" {status}" if status is not None else ""
        super().__init__(f"GhostChat Bot API error{label}: {message}")
