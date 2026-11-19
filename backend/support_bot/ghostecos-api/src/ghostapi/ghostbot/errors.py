"""Публичные исключения bot-SDK GhostChat."""

from __future__ import annotations


class GhostBotError(RuntimeError):
    """Базовая ошибка клиента ботов GhostChat."""


class BotNetworkError(GhostBotError):
    """Клиент не смог подключиться или записать в Bot API."""


class BotProtocolError(GhostBotError):
    """Кадр или ответ сервера не соответствуют протоколу."""


class BotAPIError(GhostBotError):
    """Сервер GhostChat отклонил операцию API."""

    def __init__(self, status: int | None, message: str) -> None:
        self.status = status
        label = f" {status}" if status is not None else ""
        super().__init__(f"GhostChat Bot API error{label}: {message}")
