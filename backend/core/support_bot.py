"""Детерминированный ответчик FAQ для аккаунта @support."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ghostapi import ghostbot


LOG = logging.getLogger("ghostchat.support_bot")
TOKEN_FILE = Path(
    os.environ.get("GHOSTBOT_TOKEN_FILE", "/etc/ghostchat-support/token")
)

_WELCOME = (
    "Привет! Я автоматический помощник поддержки GhostChat.\n\n"
    "Важно: сообщения этому боту не защищены E2EE — их получает сервер и "
    "может прочитать оператор поддержки. Не отправляй секреты.\n\n"
    "Быстрые ответы:\n"
    "/privacy — шифрование и приватность\n"
    "/login — проблемы со входом\n"
    "/bug — что приложить к описанию ошибки\n"
    "/human — написать оператору поддержки"
)


def reply_for_message(text: str) -> str:
    """Возвращает фиксированный ответ, не повторяя текст пользователя."""
    value = text.strip()
    command = value.split(maxsplit=1)[0].split("@", 1)[0].lower() if value else ""

    if command in {"/start", "/help"}:
        return _WELCOME
    if command in {"/privacy", "/e2ee", "/шифрование"}:
        return (
            "В личных чатах между людьми используется сквозное шифрование "
            "E2EE. Чат с @support — исключение: бот получает текст на сервере, "
            "и его может прочитать оператор поддержки. Не отправляй сюда "
            "пароли, seed-фразы или приватные ключи."
        )
    if command in {"/login", "/вход"}:
        return (
            "Опиши точный текст ошибки и версию приложения. Не присылай пароль, "
            "seed-фразу или коды восстановления: поддержка не может безопасно "
            "попросить их в чате. Если ошибка связана с потерей ключ-фразы, "
            "не удаляй приложение и локальные данные до проверки резервной копии."
        )
    if command in {"/bug", "/ошибка"}:
        return (
            "Для разбора ошибки укажи версию GhostChat, модель телефона, версию "
            "Android, шаги воспроизведения и точный текст ошибки. Перед отправкой "
            "логов удали из них токены, пароли и личные данные."
        )
    if command in {"/human", "/operator", "/оператор"}:
        return (
            "Сообщение сохранено в обращении поддержки. Оператор сможет прочитать "
            "его в панели и ответить в этом чате, когда подключится."
        )
    if command.startswith("/"):
        return "Не знаю такой команды. Напиши /help, чтобы увидеть доступные варианты."
    return (
        "Я автоматический помощник и пока отвечаю только на команды из /help. "
        "Твоё сообщение сохранено для поддержки; оператор сможет ответить "
        "здесь, когда подключится."
    )


def attach_handlers(bot: "ghostbot.Bot") -> None:
    @bot.on("message.received")
    def on_message(event: "ghostbot.BotEvent") -> None:
        data = event.data
        # Обычный аккаунт поддержки не отвечает на шифрованные тесты SDK
        if "test_session_id" in data:
            return
        username = data.get("from_username")
        text = data.get("text")
        if not isinstance(username, str) or not username.strip():
            return
        if not isinstance(text, str) or not text.strip():
            return
        try:
            bot.send_message(username, reply_for_message(text))
        except Exception as exc:  # SECURITY: сообщение и токен не логируем
            LOG.warning("Could not send support reply (%s)", type(exc).__name__)


def main() -> None:
    from ghostapi import ghostbot

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise SystemExit(f"Could not read the protected support bot credential ({type(exc).__name__})") from None
    if not token:
        raise SystemExit("The protected support bot credential is empty")

    bot = ghostbot.Bot(token)
    attach_handlers(bot)
    bot.on_status(
        lambda event: LOG.info(
            "Presence changed: %s", event.data.get("status", "unknown")
        )
    )
    bot.on(
        "connection.open",
        lambda _: LOG.info("Connected to GhostChat bot gateway"),
    )
    bot.run()


if __name__ == "__main__":
    main()
