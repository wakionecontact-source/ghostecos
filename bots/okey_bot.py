"""OKey bot — минимальный single-file aiogram-бот для проверки статуса
экосистемы Ghost. Отвечает на /start, /status, /apk.

Запуск:
    BOT_TOKEN=123:xxx python okey_bot.py

Зависимости:
    pip install aiogram aiohttp

Назначение:
    - /start — приветствие, ссылки на /chat, /social, APK
    - /status — пинг API: chat.service, social.service, доступность APK
    - /apk — прямая ссылка на свежий APK
    - /ping — pong
"""

import asyncio
import os
import sys
from datetime import datetime, timezone

try:
    from aiogram import Bot, Dispatcher, F
    from aiogram.filters import CommandStart, Command
    from aiogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton
    from aiogram.enums import ParseMode
    from aiogram.client.default import DefaultBotProperties
    import aiohttp
except ImportError:
    sys.stderr.write("Установи: pip install aiogram aiohttp\n")
    sys.exit(1)

# ─── Конфиг ──────────────────────────────────────────────────────────────
BOT_TOKEN = os.environ.get("BOT_TOKEN", "").strip()
BASE_URL = os.environ.get("GHOST_BASE", "https://ghostecos.duckdns.org")
APK_URL = f"{BASE_URL}/apkextrawaki"
CHAT_URL = f"{BASE_URL}/chat/"
SOCIAL_URL = f"{BASE_URL}/social/"

if not BOT_TOKEN:
    sys.stderr.write("Нужен BOT_TOKEN в окружении\n")
    sys.exit(1)

bot = Bot(
    token=BOT_TOKEN,
    default=DefaultBotProperties(parse_mode=ParseMode.HTML),
)
dp = Dispatcher()


def _main_keyboard() -> InlineKeyboardMarkup:
    """Главная клавиатура с кнопками экосистемы."""
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="Чат (web)", url=CHAT_URL),
            InlineKeyboardButton(text="Лента", url=SOCIAL_URL),
        ],
        [InlineKeyboardButton(text="Скачать APK", url=APK_URL)],
        [InlineKeyboardButton(text="Статус сервисов", callback_data="status")],
    ])


@dp.message(CommandStart())
async def cmd_start(msg: Message) -> None:
    text = (
        "<b>Ghost — приватная экосистема</b>\n\n"
        "Один аккаунт — мессенджер с E2E (sealed sender), своя лента "
        "и банк (Gost/Soul/Prem). Никакой рекламы, никаких алгоритмов.\n\n"
        "Выбирай куда зайти ↓"
    )
    await msg.answer(text, reply_markup=_main_keyboard())


@dp.message(Command("apk"))
async def cmd_apk(msg: Message) -> None:
    await msg.answer(
        f"<b>Свежий Android-APK:</b>\n{APK_URL}\n\n"
        "Поставь \"Установка из неизвестных источников\" и запускай.",
    )


@dp.message(Command("ping"))
async def cmd_ping(msg: Message) -> None:
    await msg.answer("pong")


@dp.message(Command("status"))
async def cmd_status(msg: Message) -> None:
    await msg.answer(await _build_status(), disable_web_page_preview=True)


@dp.callback_query(F.data == "status")
async def cb_status(call) -> None:
    await call.answer()
    await call.message.answer(await _build_status(), disable_web_page_preview=True)


async def _check(url: str, session: aiohttp.ClientSession) -> str:
    """Простая ping-проверка: 200/2xx → OK, иначе FAIL."""
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as r:
            return "✅" if 200 <= r.status < 400 else f"⚠ HTTP {r.status}"
    except Exception as e:
        return f"❌ {type(e).__name__}"


async def _build_status() -> str:
    """Опрашиваем 4 основных endpoint'а параллельно."""
    targets = [
        ("Лендинг", f"{BASE_URL}/"),
        ("Чат web", f"{BASE_URL}/chat/"),
        ("Соц лента", f"{BASE_URL}/social/"),
        ("APK", APK_URL),
    ]
    async with aiohttp.ClientSession() as session:
        results = await asyncio.gather(
            *[_check(u, session) for _, u in targets],
            return_exceptions=False,
        )
    lines = [f"<b>Статус Ghost · {datetime.now(timezone.utc).strftime('%H:%M UTC')}</b>"]
    for (name, _), status in zip(targets, results):
        lines.append(f"{status} {name}")
    return "\n".join(lines)


async def main() -> None:
    sys.stderr.write(f"[okey_bot] starting, base={BASE_URL}\n")
    await dp.start_polling(bot)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.stderr.write("[okey_bot] stopped by user\n")
