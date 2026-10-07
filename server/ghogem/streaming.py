"""
GhoGem Streaming Engine v2

Поддержка:
- Telegram Rich Draft (если доступен)
- fallback edit_message
- плавный вывод текста
- thinking блоки
- буферизация обновлений

stream_response редактирует уже существующее status_message,
а не создаёт новые сообщения.
"""

import logging
import time
import re

from aiogram import Bot
from aiogram.types import Message
from formatting import markdown_to_telegram_html

log = logging.getLogger("ai_bot.streaming")

# Пытаемся импортировать Rich-типы. Если их нет — работаем только через edit.
try:
    from aiogram.types import (
        InputRichMessage,
        InputRichBlockThinking,
        InputRichBlockParagraph,
    )
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False
    InputRichMessage = None
    InputRichBlockThinking = None
    InputRichBlockParagraph = None


# кеш поддержки Rich Draft (один раз на чат)
_rich_cache: dict[int, bool] = {}
_rich_probed = False  # глобальный флаг, чтобы не слать "test" каждый раз


async def supports_rich(bot: Bot, chat_id: int) -> bool:
    """
    Проверяет Telegram Rich Draft.
    Пробуем только один раз за жизнь процесса, без видимого "test".
    """
    global _rich_probed

    if not RICH_AVAILABLE:
        return False

    if chat_id in _rich_cache:
        return _rich_cache[chat_id]

    # Если уже пробовали глобально и зафейлили — не трогаем больше
    if _rich_probed and not any(_rich_cache.values()):
        _rich_cache[chat_id] = False
        return False

    try:
        draft_id = int(time.time() * 1000)

        # Пустой draft — ничего не показывает пользователю
        await bot.send_rich_message_draft(
            chat_id=chat_id,
            draft_id=draft_id,
            rich_message=InputRichMessage(blocks=[])
        )

        _rich_cache[chat_id] = True
        _rich_probed = True
        return True

    except Exception:
        _rich_cache[chat_id] = False
        _rich_probed = True
        return False


async def clear_draft(bot: Bot, chat_id: int, draft_id: int):
    if not RICH_AVAILABLE:
        return
    try:
        await bot.send_rich_message_draft(
            chat_id=chat_id,
            draft_id=draft_id,
            rich_message=InputRichMessage(blocks=[])
        )
    except Exception:
        pass


def split_thinking(text: str):
    patterns = [
        "think",
        "thinking",
        "thought",
        "reasoning"
    ]

    for tag in patterns:
        full = re.search(
            rf"<{tag}>(.*?)</{tag}>",
            text,
            re.DOTALL | re.IGNORECASE
        )

        if full:
            return (
                full.group(1).strip(),
                re.sub(
                    rf"<{tag}>.*?</{tag}>",
                    "",
                    text,
                    flags=re.DOTALL | re.IGNORECASE
                ).strip()
            )

    return "", text


async def send_rich(bot, chat_id, draft_id, thinking, answer):
    if not RICH_AVAILABLE:
        return

    blocks = []

    if thinking:
        blocks.append(InputRichBlockThinking(text=thinking))

    if answer:
        blocks.append(InputRichBlockParagraph(text=answer))

    if not blocks:
        return

    await bot.send_rich_message_draft(
        chat_id=chat_id,
        draft_id=draft_id,
        rich_message=InputRichMessage(blocks=blocks)
    )


async def stream_response(
    bot: Bot,
    chat_id: int,
    stream_generator,
    model_header: str = "",
    status_message: Message | None = None,
    update_delay: float = 0.65,
):
    """
    Главная функция стриминга.

    stream_generator должен отдавать:
    {
       "thinking": "...",
       "answer": "..."
    }

    status_message — уже существующее сообщение "думает...", которое мы редактируем.
    В конце оно НЕ удаляется здесь — bot.py сам решит (удалит и пошлёт финал с кнопками).
    """

    draft_id = int(time.time() * 1000)
    use_rich = await supports_rich(bot, chat_id)

    last_update = 0.0
    thinking = ""
    answer = ""

    async for chunk in stream_generator:
        thinking = chunk.get("thinking", thinking)
        answer = chunk.get("answer", answer)

        now = time.time()
        if now - last_update < update_delay:
            continue
        last_update = now
        visible_answer = re.sub(
            r"\[TOOL_CALL\].*?(?:\[/TOOL_CALL\]|$)",
            "",
            answer,
            flags=re.I | re.S,
        )
        visible_answer = re.sub(r"\[/?TOOL_CALL\]", "", visible_answer, flags=re.I)

        if use_rich:
            try:
                await send_rich(
                    bot,
                    chat_id,
                    draft_id,
                    thinking,
                    (visible_answer + " ▌") if visible_answer else "▌"
                )
            except Exception:
                use_rich = False
        elif status_message:
            try:
                text = model_header + markdown_to_telegram_html(visible_answer) + " ▌"
                await bot.edit_message_text(
                    chat_id=chat_id,
                    message_id=status_message.message_id,
                    text=text,
                    parse_mode="HTML"
                )
            except Exception:
                pass

    # Чистим draft, если использовали
    if use_rich:
        await clear_draft(bot, chat_id, draft_id)

    return answer
