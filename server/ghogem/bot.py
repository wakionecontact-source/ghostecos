"""
Telegram-бот GhoGem v8 — файловое хранилище, кастомный промт, учёт пользователей,
приём файлов/фото, авто-репорт ошибок, кнопка «Сообщить об ошибке».
Стриминг ответов через streaming.py.
"""

import asyncio
import html
import json
import logging
import os
import random
import re
import secrets
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

import ai
import reminders
import interactive_choices
import music
import uuid
import db
import model_ratings
import streaming
try:
    import sso  # привязка Telegram ↔ аккаунт GhostEcos (см. sso.py)
except Exception as _sso_e:  # без него бот работает как раньше, просто без /link
    sso = None
    logging.getLogger("ai_bot").error("sso недоступен: %s", _sso_e)
from aiogram import Bot, Dispatcher, F
from aiogram.methods import SendRichMessage, EditMessageText
from aiogram.types import InputRichMessage
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    Message,
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    CopyTextButton,
    InlineQuery,
    InlineQueryResultArticle,
    InputTextMessageContent,
    ReactionTypeEmoji,
    BotCommand,
    LabeledPrice,
    PreCheckoutQuery,
    LinkPreviewOptions,
    FSInputFile,
    InputMediaPhoto,
    WebAppInfo,
)
from formatting import split_text, markdown_to_telegram_html, strip_all_html, _fix_unmatched_tags

import aiohttp

# ============ КОНФИГ ============

load_dotenv()

ADMIN_USER_ID = int(os.getenv("ADMIN_USER_ID", "0"))

TELEGRAM_TOKEN = os.environ["TELEGRAM_TOKEN"]
CRYPTO_BOT_TOKEN = os.environ.get("CRYPTO_BOT_TOKEN", "")

RPM_LIMIT = int(os.getenv("RPM_LIMIT", "30"))
RPD_LIMIT = int(os.getenv("RPD_LIMIT", "1000"))
WINDOW_SECONDS = int(os.getenv("WINDOW_SECONDS", "60"))
DAY_SECONDS = 24 * 60 * 60

MAX_HISTORY_TURNS = int(os.getenv("MAX_HISTORY_TURNS", "20"))

_SYSTEM_PROMPT_RAW = os.getenv("SYSTEM_PROMPT") or (
    "Ты GhoGem — дружелюбный ИИ-ассистент и приложение GhostEcos. "
    "GhostEcos создал продукт GhoGem, а не базовую модель; провайдер и автор "
    "текущей модели добавляются отдельным системным блоком. Не смешивай эти роли."
)
# systemd EnvironmentFile оставляет \n как два символа; восстановим переносы.
SYSTEM_PROMPT = _SYSTEM_PROMPT_RAW.replace("\\n", "\n")
SYSTEM_PROMPT += (
    "\n\nСВЯЗНОСТЬ ДИАЛОГА: если текущее сообщение пользователя не содержит "
    "явной задачи или вопроса (например: «привет», «ку», «ага», «ясно»), "
    "ответь естественно и обязательно кратко упомяни важные недавние события "
    "из доступного контекста до этого сообщения — например, сработавшее "
    "напоминание, результат задания или важное уведомление. Не выдумывай "
    "события и не повторяй несущественные старые детали. Если пользователь в "
    "своём системном промпте/настройках явно просит не напоминать о прошлых "
    "событиях или не упоминать их без запроса, следуй этой настройке. "
    "Если важные недавние напоминания не видны в текущем контексте, но могут "
    "быть релевантны такому сообщению, получи инструкции для recent_reminders "
    "через get_tool_instructions и вызови recent_reminders перед финальным ответом."
)

MAX_MESSAGE_CHUNK = 3500
GHOGEM_WEBAPP_LOGIN_URL = (
    os.getenv("GHOGEM_WEBAPP_LOGIN_URL")
    or "https://ghostecos.duckdns.org/v2/auth?return=%2Fghogem%2F&tg_link=1&client_id=ghogem_bot"
).strip()

# ============ ПОДПИСКА (Telegram Stars) ============

SUBSCRIPTION_PERIOD_SECONDS = 2592000
SUBSCRIPTION_PRICE_STARS = int(os.getenv("SUBSCRIPTION_PRICE_STARS", "150"))
SUBSCRIPTION_PAYLOAD = "ghogem_premium_monthly"
SUBSCRIPTION_PRICE_USDT = float(os.getenv("SUBSCRIPTION_PRICE_USDT", "0.70"))
PREMIUM_FOREVER_EXPIRY = 253402300799  # 31.12.9999 23:59:59 UTC
GHOSTECOS_NEW_ACCOUNT_WINDOW_SECONDS = int(
    os.getenv("GHOSTECOS_NEW_ACCOUNT_WINDOW_SECONDS", "86400")
)

def format_premium_expiry(expires_at: int) -> str:
    if int(expires_at) >= PREMIUM_FOREVER_EXPIRY:
        return "навсегда"
    date = datetime.fromtimestamp(int(expires_at)).strftime("%d.%m.%Y")
    return f"до {date}"

# ============ ЛОГИ ============

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("ai_bot")

# ============ СОСТОЯНИЕ ============

request_times_minute: "deque[float]" = deque()
request_times_day: "deque[float]" = deque()

user_status: dict[int, str] = {}
# Only one running model-generation task per owner; queue entries are separate.
# Store its chat/message pair to reject presses on old or other users' cards.
active_agent_runs: dict[int, dict] = {}
ACTIVE_AGENT_STALE_SECONDS = 180.0
ACTIVE_AGENT_WATCHDOG_INTERVAL_SECONDS = 15.0


def _active_run_is_stale(run: dict | None, *, now: float | None = None) -> bool:
    if not run or run.get("kind") != "prompt" or run.get("waiting_choice_token"):
        return False
    now = time.monotonic() if now is None else float(now)
    last = float(run.get("last_activity_at") or run.get("started_at") or now)
    task = run.get("task")
    return bool(task is not None and not task.done() and now - last >= ACTIVE_AGENT_STALE_SECONDS)


# Live waiters for ask_user_choice. The same process_request coroutine stays
# alive while the separate Telegram question card waits for a click/text.
# Keyed by the persistent choice token; on process restart callbacks safely
# fall back to starting a continuation turn from SQLite state.
interactive_choice_waiters: dict[str, asyncio.Future] = {}
user_models: dict[int, str] = {}
user_provider_page: dict[int, int] = {}
# "current" = смена модели текущего чата, "default" = модель для новых чатов.
user_model_menu_mode: dict[int, str] = {}
MODEL_CATEGORIES = {
    "all": "📋 Все",
    "code": "💻 Код",
    "vision": "👁 Vision",
    "top": "🔥 Топ",
    "free": "🆓 Free",
}
user_model_category: dict[int, str] = {}
user_model_search: dict[int, str] = {}
awaiting_model_search: set[int] = set()
# Пользователи, от которых ждём новый текст системного промпта через настройки.
awaiting_custom_prompt: set[int] = set()
# Пользователи, от которых ждём IANA-имя/город для часового пояса.
awaiting_timezone: set[int] = set()

last_bot_response: dict[int, str] = {}
# Снимок последнего ответа ИИ (для кнопки «Назад к ответу»)
last_answer_snapshot: dict[int, dict] = {}  # user_id -> {text, copy_payload}

# Режим «отправить файл в files/ текущего чата»
upload_mode: set[int] = set()
buffer_upload_mode: set[int] = set()
# Ожидание ввода для редактирования черновика задания
reminder_edits: dict[int, dict] = {}
# Веб-поиск только на следующий запрос (сбрасывается после ответа)
web_search_once: set[int] = set()
# Язык UI: "ru" | "en"
user_lang: dict[int, str] = {}

cooldown_until = 0.0
cooldown_seconds = 15


def lang_for(user_id: int, tg_code: str | None = None) -> str:
    if user_id in user_lang:
        return user_lang[user_id]
    code = (tg_code or "").lower()
    return "ru" if code.startswith("ru") else "en"


def progress_bar(current: int, total: int, width: int = 10) -> str:
    if total <= 0:
        return "▓" * width
    cur = max(0, min(current, total))
    filled = int(round(width * cur / total))
    return "▓" * filled + "░" * (width - filled)


async def get_user_model(user_id: int) -> str:
    """Модель: RAM → диск → дефолт."""
    if user_id in user_models:
        cached_model = user_models[user_id]
        if cached_model in ai.AVAILABLE_MODELS and not ai.is_model_retired(cached_model):
            return cached_model
        user_models.pop(user_id, None)
    try:
        state = await db.get_user_state(user_id)
        mk = state.get("model_key")
        if mk and mk in ai.AVAILABLE_MODELS and not ai.is_model_retired(mk):
            user_models[user_id] = mk
            return mk
    except Exception:
        pass
    try:
        default_key = await db.get_default_model(user_id)
        if (default_key and default_key in ai.AVAILABLE_MODELS
                and not ai.is_model_retired(default_key)):
            return default_key
    except Exception:
        pass
    return ai.DEFAULT_MODEL_KEY


async def persist_user_model(user_id: int, model_key: str):
    user_models[user_id] = model_key
    try:
        await db.set_user_model(user_id, model_key)
    except Exception:
        pass


async def ensure_chat_persisted(user_id: int):
    try:
        await db.set_user_chat(user_id, ai.get_current_chat(user_id))
    except Exception:
        pass


@dataclass
class QueuedRequest:
    user_id: int
    chat_id: int
    prompt: str
    status_message: Message | None
    queued_at: float = field(default_factory=time.time)
    attachment_name: str = ""  # trusted server-saved media attached to this request
    ai_chat_id: str = ""       # exact GhoGem chat this queued turn belongs to
    attempts: int = 0  # сколько раз этот запрос уже повторялся (защита от бесконечного цикла)


@dataclass
class BufferedFollowup:
    text: str
    attachment_name: str = ""
    queued_at: float = field(default_factory=time.time)


pending_requests: "deque[QueuedRequest]" = deque()
rating_blocked_prompts: dict[int, "deque[QueuedRequest]"] = {}

# Prevent one model stuck in endless empty-response retries from blocking every
# other queued owner or due AI reminder. Both pools have small concurrency caps.
_queue_workers: set[asyncio.Task] = set()
_reminder_workers: set[asyncio.Task] = set()
MAX_BACKGROUND_QUEUE_WORKERS = 3
MAX_BACKGROUND_REMINDER_WORKERS = 3
FOREGROUND_AGENT_TIMEOUT_SECONDS = 300

# Event-driven reminder scheduler. RAM holds only the nearest task id/deadline;
# the full reminder row stays in SQLite until its timer actually fires.
reminder_scheduler_wakeup = asyncio.Event()


def wake_reminder_scheduler() -> None:
    reminder_scheduler_wakeup.set()


def _background_worker_done(pool: set, job: asyncio.Task) -> None:
    pool.discard(job)
    if pool is _reminder_workers:
        wake_reminder_scheduler()
    if job.cancelled():
        return
    try:
        error=job.exception()
    except asyncio.CancelledError:
        return
    if error:
        log.error(
            "Необработанная ошибка фонового ИИ-задания",
            exc_info=(type(error),error,error.__traceback__),
        )


BUSY_REPLIES = [
    "🤚 Ещё думаю над вашим предыдущим запросом — секунду!",
    "🧠 Пока обрабатываю прошлый промт. Дождитесь ответа, потом пишите новый.",
    "⏳ Один запрос за раз! Как только отвечу — сразу берусь за следующий.",
    "🙈 Не так быстро, я ещё не закончил с прошлым сообщением.",
]

bot = Bot(token=TELEGRAM_TOKEN)
dp = Dispatcher()


# ============ КЛАВИАТУРЫ ============


def ghostecos_webapp_keyboard(
    include_profile: bool = False,
    already_linked: bool = False,
) -> InlineKeyboardMarkup:
    if already_linked:
        login_button = InlineKeyboardButton(
            text="✅ Вы уже вошли в GhostEcos",
            callback_data="ghostecos_already_logged_in",
        )
    else:
        login_button = InlineKeyboardButton(
            text="🔐 Войти через GhostEcos",
            web_app=WebAppInfo(url=GHOGEM_WEBAPP_LOGIN_URL),
        )
    rows = [[login_button]]
    if include_profile:
        rows.append([InlineKeyboardButton(text="👤 Профиль", callback_data="profile")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def ghostecos_linked_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔓 Отвязать GhostID", callback_data="profile_unlink")],
        [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
    ])


def main_menu_keyboard(
    show_back: bool = False,
    user_id: int | None = None,
    include_webapp: bool = False,
    ghostecos_linked: bool = False,
) -> InlineKeyboardMarkup:
    search_on = user_id is not None and user_id in web_search_once
    search_btn = (
        "🔍 Веб-поиск: ВКЛ (след. запрос)" if search_on else "🔍 Веб-поиск: выкл"
    )
    # Порядок кнопок главного меню: чаты, ИИ, профиль, подписка, поиск, файлы, помощь.
    rows = [
        [
            InlineKeyboardButton(text="💬 Новый чат", callback_data="new_chat"),
            InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats"),
            InlineKeyboardButton(text="📜 История", callback_data="history_cb"),
        ],
        [
            InlineKeyboardButton(text="🧠 Модель", callback_data="change_model"),
            InlineKeyboardButton(text="🔑 Мои ключи", callback_data="mykeys_menu"),
        ],
        [
            InlineKeyboardButton(text="👤 Профиль", callback_data="profile"),
            InlineKeyboardButton(text="⚙️ Настройки", callback_data="settings_menu"),
        ],
        [
            InlineKeyboardButton(text="👥 Рефералы", callback_data="referrals"),
        ],
        [InlineKeyboardButton(text="👑 Premium", callback_data="subscribe")],
        [InlineKeyboardButton(text=search_btn, callback_data="toggle_web_search")],
        [
            InlineKeyboardButton(text="📂 Файлы", callback_data="files_cb"),
            InlineKeyboardButton(text="📥 Загрузить файлы", callback_data="upload_start"),
        ],
        [
            InlineKeyboardButton(text="📊 Статус", callback_data="status"),
            InlineKeyboardButton(text="💡 Помощь", callback_data="help"),
        ],
    ]
    if include_webapp:
        rows.insert(
            0,
            ghostecos_webapp_keyboard(already_linked=ghostecos_linked).inline_keyboard[0],
        )
    if show_back:
        rows.insert(0, [InlineKeyboardButton(text="◀️ Назад к ответу", callback_data="back_to_answer")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def back_only_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="◀️ Назад к ответу", callback_data="back_to_answer")],
        [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
    ])


def subscribe_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"⭐ Оплатить {SUBSCRIPTION_PRICE_STARS} Stars", callback_data="pay_stars")],
        [InlineKeyboardButton(text=f"💎 Оплатить {SUBSCRIPTION_PRICE_USDT:.2f} USDT", callback_data="crypto_pay")],
        [InlineKeyboardButton(text="🏠 В меню", callback_data="main_menu")],
    ])


def agent_stop_keyboard(followup_count: int = 0) -> InlineKeyboardMarkup:
    rows = []
    if int(followup_count or 0) > 0:
        rows.append([
            InlineKeyboardButton(
                text=f"↪️ Дослать сейчас · {int(followup_count)}",
                callback_data="agent:send-followups",
            ),
            InlineKeyboardButton(
                text="💬 Отправить отдельно",
                callback_data="agent:separate-followups",
            ),
        ])
        rows.append([
            InlineKeyboardButton(text="⏹ Остановить генерацию",
                                 callback_data="agent:stop")
        ])
    else:
        rows.append([
            InlineKeyboardButton(text="⏹ Остановить генерацию",
                                 callback_data="agent:stop")
        ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def queue_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔴 Отменить запрос", callback_data="cancel")]
    ])


CHOICE_NUMBER_EMOJI = ("1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣")


def _resolve_interactive_choice_waiter(token: str, payload: dict) -> bool:
    """Wake the exact live agent-turn waiting for this choice token."""
    future = interactive_choice_waiters.get(str(token))
    if future is None or future.done():
        return False
    future.set_result(dict(payload))
    return True


def _scrub_agent_block_preview(text: str) -> str:
    """Never show [BLOCK: ANSWER]/THOUGHT/ACTION protocol tags in Telegram UI."""
    value = re.sub(
        r"[\[{]\s*BLOCK\s*:\s*(?:ACTION|THOUGHT|ANSWER)\s*[\]}]\s*",
        "",
        str(text or ""),
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\s*\[\[GHOGEM_RATING\s*:\s*(?:request|none)\s*\]\]\s*",
        "",
        value,
        flags=re.IGNORECASE,
    )
    # Never flash a partial internal rating marker during streaming.
    partial_rating = re.search(r"\[\[GHOGEM_RAT(?:ING)?[^\n]*$", value, flags=re.IGNORECASE)
    if partial_rating:
        value = value[:partial_rating.start()]
    # Streaming may split the marker halfway through. Hide a trailing partial
    # marker instead of briefly flashing e.g. `[BLOCK: ANS` to the user.
    upper = value.upper()
    markers = (
        "[BLOCK: ACTION]", "[BLOCK: THOUGHT]", "[BLOCK: ANSWER]",
        "{BLOCK: ACTION}", "{BLOCK: THOUGHT}", "{BLOCK: ANSWER}",
        "[[GHOGEM_RATING:REQUEST]]", "[[GHOGEM_RATING:NONE]]",
    )
    for start in range(max(0, len(value) - 32), len(value)):
        suffix = upper[start:]
        if suffix and any(marker.startswith(suffix) for marker in markers):
            value = value[:start]
            break
    return value


def _looks_like_internal_structured_payload(text: str) -> bool:
    """Hide model-emitted tool arguments from live Telegram streaming."""
    value = str(text or "").lstrip()
    if not value:
        return False
    lower = value.lower()
    # Tool payloads commonly start as fenced JSON. We intentionally delay
    # streaming JSON/code-shaped prefixes; the final answer is still delivered
    # normally if it turns out to be legitimate user-facing content.
    if lower.startswith("```json"):
        return True
    if lower.startswith("<svg"):
        return True
    if lower.startswith("{") or lower.startswith("["):
        sample = lower[:1800]
        if any(key in sample for key in (
            '"scenes"', '"svg"', '"transition_duration"', '"tool_name"',
            '"arguments"', '"width"', '"height"', '"fps"',
        )):
            return True
    if '"scenes"' in lower[:1800] and "<svg" in lower[:4000]:
        return True
    return False


def interactive_choice_text(
    question: str,
    options: list[str],
    *,
    footer: str = "choose",
    selected_index: int | None = None,
    custom_answer: str = "",
) -> str:
    """Stable card: question/options never move; only the bottom state changes."""
    lines = [
        "❓ <b>Вопрос</b>",
        html.escape(str(question or "").strip()),
        "",
    ]
    for index, option in enumerate(options[:8], 1):
        emoji = CHOICE_NUMBER_EMOJI[index - 1]
        lines.extend([
            f"{emoji} <b>Вариант {index}</b>",
            html.escape(str(option or "").strip()),
            "",
        ])
    if footer == "custom":
        lines.append(
            "✍️ <i>Напиши свой ответ следующим сообщением — вопрос и варианты останутся перед тобой.</i>"
        )
    elif footer == "selected" and selected_index is not None:
        lines.append(f"✅ <i>Выбран Вариант {selected_index + 1}. Ответ отправлен ИИ.</i>")
    elif footer == "custom_sent":
        preview = " ".join(str(custom_answer or "").split()).strip()
        if len(preview) > 180:
            preview = preview[:177] + "…"
        lines.append(
            "✅ <i>Свой ответ отправлен ИИ"
            + (f": {html.escape(preview)}" if preview else "")
            + ".</i>"
        )
    elif footer == "expired":
        lines.append("⌛️ <i>Этот вопрос уже закрыт или устарел.</i>")
    else:
        lines.append("👇 <i>Выбери один из вариантов ответа снизу</i>")
    return "\n".join(lines).strip()


def interactive_choice_keyboard(token: str, count: int) -> InlineKeyboardMarkup:
    rows = []
    for index in range(max(0, min(int(count), 8))):
        rows.append([
            InlineKeyboardButton(
                text=f"{CHOICE_NUMBER_EMOJI[index]} Вариант {index + 1}",
                callback_data=f"choice:pick:{token}:{index}",
            )
        ])
    rows.append([
        InlineKeyboardButton(
            text="✍️ Написать свой ответ",
            callback_data=f"choice:custom:{token}",
        )
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def interactive_choice_continue_prompt(
    card: dict,
    answer: str,
    *,
    selected_index: int | None = None,
) -> str:
    question = str(card.get("question") or "").strip()
    if selected_index is None:
        answer_line = f"Пользователь написал свой ответ: {answer}"
    else:
        answer_line = f"Пользователь выбрал Вариант {selected_index + 1}: {answer}"
    return (
        "[Ответ пользователя на твой интерактивный вопрос]\n"
        f"Вопрос: {question}\n"
        f"{answer_line}\n\n"
        "Продолжи исходную задачу с учётом этого реального ответа. "
        "Не спрашивай тот же вопрос повторно без необходимости. "
        "Этот выбор сам по себе не является подтверждением удаления, платежа "
        "или другого защищённого/разрушительного действия."
    )


async def update_interactive_choice_card(
    card: dict,
    *,
    footer: str,
    selected_index: int | None = None,
    custom_answer: str = "",
    keep_buttons: bool = False,
):
    text = interactive_choice_text(
        card.get("question") or "",
        card.get("options") or [],
        footer=footer,
        selected_index=selected_index,
        custom_answer=custom_answer,
    )
    markup = (
        interactive_choice_keyboard(str(card["token"]), len(card.get("options") or []))
        if keep_buttons else None
    )
    await bot.edit_message_text(
        chat_id=int(card["telegram_chat_id"]),
        message_id=int(card["message_id"]),
        text=text,
        parse_mode="HTML",
        reply_markup=markup,
    )


@dp.callback_query(F.data.startswith("choice:custom:"))
async def cb_interactive_choice_custom(query: CallbackQuery):
    token = str(query.data or "").split(":", 2)[-1]
    card = await asyncio.to_thread(interactive_choices.get, token)
    if not card or int(card.get("user_id") or 0) != int(query.from_user.id):
        await query.answer("Этот вопрос уже закрыт или устарел.", show_alert=True)
        return
    if (not query.message
            or int(card.get("telegram_chat_id") or 0) != int(query.message.chat.id)
            or int(card.get("message_id") or 0) != int(query.message.message_id)):
        await query.answer("Эта карточка больше не активна.", show_alert=True)
        return
    card = await asyncio.to_thread(
        interactive_choices.begin_custom, token, query.from_user.id
    )
    if not card:
        await query.answer("Этот вопрос уже закрыт.", show_alert=True)
        return
    try:
        await update_interactive_choice_card(
            card,
            footer="custom",
            keep_buttons=True,
        )
    except Exception as error:
        log.warning("choice custom card update failed: %s", type(error).__name__)
    await query.answer("✍️ Напиши свой ответ следующим сообщением")


@dp.callback_query(F.data.startswith("choice:pick:"))
async def cb_interactive_choice_pick(query: CallbackQuery):
    parts = str(query.data or "").split(":")
    if len(parts) != 4:
        await query.answer("Некорректный вариант.", show_alert=True)
        return
    token = parts[2]
    try:
        index = int(parts[3])
    except ValueError:
        await query.answer("Некорректный вариант.", show_alert=True)
        return
    card = await asyncio.to_thread(interactive_choices.get, token)
    if not card or int(card.get("user_id") or 0) != int(query.from_user.id):
        await query.answer("Этот вопрос уже закрыт или устарел.", show_alert=True)
        return
    options = list(card.get("options") or [])
    if not 0 <= index < len(options):
        await query.answer("Такого варианта нет.", show_alert=True)
        return
    if (not query.message
            or int(card.get("telegram_chat_id") or 0) != int(query.message.chat.id)
            or int(card.get("message_id") or 0) != int(query.message.message_id)):
        await query.answer("Эта карточка больше не активна.", show_alert=True)
        return
    consumed = await asyncio.to_thread(
        interactive_choices.consume, token, query.from_user.id
    )
    if not consumed:
        await query.answer("Ответ уже принят.", show_alert=True)
        return
    option = str(options[index])
    try:
        await update_interactive_choice_card(
            consumed,
            footer="selected",
            selected_index=index,
            keep_buttons=False,
        )
    except Exception as error:
        log.warning("choice selected card update failed: %s", type(error).__name__)
    await query.answer(f"✅ Вариант {index + 1}")
    prompt = interactive_choice_continue_prompt(
        consumed,
        option,
        selected_index=index,
    )
    resumed = _resolve_interactive_choice_waiter(
        token,
        {
            "prompt": prompt,
            "timeline": f"✅ Пользователь выбрал Вариант {index + 1}: {option}",
            "selected_index": index,
            "answer": option,
        },
    )
    if not resumed:
        # Bot restart / expired in-memory coroutine: persistent SQLite card still
        # lets us safely continue the exact AI chat as a fresh turn.
        asyncio.create_task(submit_prompt(
            query.from_user.id,
            int(consumed["telegram_chat_id"]),
            prompt,
            notify_message=None,
            ai_chat_id_override=str(consumed["ai_chat_id"]),
        ))


_RATING_URGENT_RE = re.compile(
    r"(срочн|опасност|угрож|пожар|кровотеч|не дыш|без сознани|"
    r"суицид|самоубий|убить себя|112|911|emergency|urgent|danger)",
    re.IGNORECASE,
)

_RATING_TECHNICAL_FAILURE_RE = re.compile(
    r"(анализ не удался|анализатор временно недоступен|"
    r"не удалось обработать прикрепл[её]нное медиа|"
    r"ответ не завершился вовремя|"
    r"не удалось дождаться интерактивного ответа|"
    r"модель вернула пустой ответ)",
    re.IGNORECASE,
)


def rating_model_context(state: dict, *, is_premium: bool) -> str:
    now = int(time.time())
    last_rated = int(state.get("last_rated_at") or 0)
    if last_rated:
        ago = max(0, now - last_rated)
        last_text = (
            datetime.fromtimestamp(last_rated, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            + f" ({ago // 60} мин назад)"
        )
    else:
        last_text = "никогда"
    last_required = int(state.get("last_required_at") or 0)
    if last_required:
        required_ago = max(0, now - last_required)
        required_text = f"{required_ago // 60} мин назад"
    else:
        required_text = "никогда"
    return (
        f"Последний раз пользователь голосовал: {last_text}. "
        f"Ответов после последней оценки: {int(state.get('responses_since_rating') or 0)}. "
        f"Последний обязательный запрос оценки: {required_text}. "
        f"Всего оценок: {int(state.get('total_ratings') or 0)}. "
        f"Тариф: {'Premium' if is_premium else 'Free'}."
    )


def rating_request_allowed(prompt: str, state: dict, answer: str | None = None) -> bool:
    # Частоту решает сама модель: сервер передаёт ей последнюю оценку,
    # число ответов после неё и время прошлого обязательного запроса.
    # Сервер всё равно жёстко исключает экстренные и чисто технические ответы:
    # оценивать ошибку инструмента вместо качества модели бессмысленно.
    if _RATING_URGENT_RE.search(str(prompt or "")):
        return False
    if answer is not None:
        text = str(answer or "").strip()
        if not text:
            return False
        if text.startswith(("❌", "🤷 Модель вернула пустой ответ")):
            return False
        if _RATING_TECHNICAL_FAILURE_RE.search(text):
            return False
    return True


def rating_score_keyboard(token: str, *, is_premium: bool, required: bool) -> InlineKeyboardMarkup:
    rows = [[
        InlineKeyboardButton(text=str(score), callback_data=f"rating:score:{token}:{score}")
        for score in range(1, 6)
    ]]
    if required and is_premium:
        rows.append([
            InlineKeyboardButton(text="Пропустить", callback_data=f"rating:skip:{token}")
        ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def rating_request_text(*, required: bool, is_premium: bool) -> str:
    if required and not is_premium:
        return (
            "⭐ <b>Оцени этот ответ от 1 до 5</b>\n"
            "Это обязательная оценка перед следующим запросом. "
            "<i>На Free её нельзя пропустить.</i>"
        )
    if required:
        return (
            "⭐ <b>Оцени этот ответ от 1 до 5</b>\n"
            "Это поможет улучшать модели. На Premium оценку можно пропустить."
        )
    return "⭐ <b>Оцени ответ от 1 до 5</b>"


def answer_keyboard(
    copy_payload: str | None,
    user_id: int | None = None,
    *,
    model_key: str | None = None,
    model_is_favorite: bool = False,
    answer_chat_id: str | None = None,
    answer_id: str | None = None,
    rating_token: str | None = None,
) -> InlineKeyboardMarkup:
    # Available to both tiers; server enforces 5/hour Free, 30/hour Premium.
    voice_label = "🎙 Озвучить" if ai.fish_tts_available() else None

    search_on = user_id is not None and user_id in web_search_once
    search_btn = "🔍 Поиск: ВКЛ (след. запрос)" if search_on else "🔍 Веб-поиск"

    buttons = []
    if rating_token:
        buttons.append([
            InlineKeyboardButton(
                text="⭐ Оценить",
                callback_data=f"rating:open:{rating_token}",
            )
        ])
    buttons.extend([
        [InlineKeyboardButton(text="📍 Начать с этого места", callback_data="continue_here")],
        [InlineKeyboardButton(text=search_btn, callback_data="toggle_web_search")],
    ])
    if model_key:
        favorite_label = (
            "★ Убрать модель из избранного"
            if model_is_favorite else
            "⭐ Добавить модель в избранное"
        )
        buttons.append([
            InlineKeyboardButton(
                text=favorite_label,
                callback_data=f"favmodel:{model_key}",
            )
        ])
    if voice_label:
        buttons.append([InlineKeyboardButton(text=voice_label, callback_data="tts_last")])
    if answer_chat_id and answer_id:
        buttons.append([
            InlineKeyboardButton(
                text="🧠 Забыть ответ",
                callback_data=f"forgetans:{answer_chat_id}:{answer_id}",
            )
        ])
    buttons.extend([
        [
            InlineKeyboardButton(text="💬 Новый чат", callback_data="new_chat"),
            InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats"),
            InlineKeyboardButton(text="📜 История чата", callback_data="history_cb"),
        ],
        [
            InlineKeyboardButton(text="📂 Файлы", callback_data="files_cb"),
            InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu"),
        ],
        [
            InlineKeyboardButton(text="🧠 Сменить модель", callback_data="change_model"),
            InlineKeyboardButton(text="⚠️ Сообщить об ошибке", url="https://t.me/Waki_robot"),
        ],
    ])
    if copy_payload:
        buttons.append(
            [InlineKeyboardButton(text="📋 Скопировать текст", copy_text=CopyTextButton(text=copy_payload[:256]))]
        )
    return InlineKeyboardMarkup(inline_keyboard=buttons)


def back_to_menu_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔙 Назад в меню", callback_data="main_menu")]
    ])


# ============ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ============

def _prune(dq, older_than: float):
    now = time.time()
    while dq and dq[0] < now - older_than:
        dq.popleft()


def rpm_used() -> int:
    _prune(request_times_minute, WINDOW_SECONDS)
    return len(request_times_minute)


def rpd_used() -> int:
    _prune(request_times_day, DAY_SECONDS)
    return len(request_times_day)


def can_dispatch_now() -> bool:
    # Очередь отключена по запросу — всегда разрешаем диспатч напрямую
    return True


def register_dispatch():
    now = time.time()
    request_times_minute.append(now)
    request_times_day.append(now)


def seconds_until_rpm_slot() -> float:
    if not request_times_minute:
        return 0.0
    return max(0.0, request_times_minute[0] + WINDOW_SECONDS - time.time())


def format_wait_estimate() -> str:
    if rpd_used() >= RPD_LIMIT:
        return "дневной лимит исчерпан, попробуйте позже"
    if rpm_used() >= RPM_LIMIT:
        return f"~{seconds_until_rpm_slot():.0f} сек"
    return "меньше минуты"


def is_user_busy(user_id: int) -> bool:
    return user_id in user_status


def queue_position(user_id: int) -> int | None:
    for i, req in enumerate(pending_requests):
        if req.user_id == user_id:
            return i + 1
    return None


def _followup_block(items: list[BufferedFollowup]) -> str:
    if not items:
        return ""
    lines = []
    budget = 1250
    used = 0
    for index, item in enumerate(items, 1):
        raw = " ".join(str(item.text or "").split()) or "[вложение]"
        if len(raw) > 220:
            raw = raw[:217] + "…"
        line = f"{index}. {html.escape(raw)}"
        if used + len(line) > budget:
            hidden = len(items) - len(lines)
            if hidden > 0:
                lines.append(f"… ещё {hidden}")
            break
        lines.append(line)
        used += len(line)
    return (
        "\n\n━━━━━━━━━━━━━━━\n"
        f"📨 <b>Сообщения в очереди · {len(items)}</b>\n"
        + "\n".join(lines)
    )


def _followup_prompt(items: list[BufferedFollowup], *, original_prompt: str = "",
                     interrupted: bool = False, separate: bool = False) -> str:
    texts = [str(item.text or "").strip() for item in items if str(item.text or "").strip()]
    if not texts:
        texts = ["Продолжи с учётом отправленных вложений."]
    if len(texts) == 1:
        joined = texts[0]
    else:
        joined = "\n".join(f"{i}. {text}" for i, text in enumerate(texts, 1))
    if separate:
        if len(texts) == 1:
            return texts[0]
        return (
            "Ответь на следующие сообщения как на один отдельный новый вопрос, "
            "не как на уточнение к выполнявшейся задаче:\n" + joined
        )
    if interrupted:
        base = str(original_prompt or "").strip()
        return (
            f"{base}\n\n" if base else ""
        ) + (
            "Пользователь дополнил задачу до завершения. Учти ВСЕ дополнения ниже "
            "как часть исходного запроса. Предыдущий проход был остановлен и некоторые "
            "инструменты могли уже успеть изменить состояние: перед повторным действием "
            "сначала проверь текущее состояние и НЕ дублируй уже выполненные действия.\n"
            + joined
        )
    return (
        "Дополнение к предыдущей задаче. Пользователь отправил эти сообщения, "
        "пока ты выполнял предыдущий запрос. Учти их все и продолжи/скорректируй результат:\n"
        + joined
    )


def _followup_attachment(items: list[BufferedFollowup]) -> str:
    for item in items:
        if item.attachment_name:
            return item.attachment_name
    return ""


async def safe_react(chat_id: int, message_id: int, emoji: str):
    try:
        await bot.set_message_reaction(chat_id=chat_id, message_id=message_id, reaction=[ReactionTypeEmoji(emoji=emoji)])
    except Exception:
        pass


async def keep_typing(chat_id: int):
    try:
        while True:
            await bot.send_chat_action(chat_id=chat_id, action="typing")
            await asyncio.sleep(4)
    except asyncio.CancelledError:
        pass


# ============ БЕЙДЖИКИ И ПАРАМЕТРЫ МОДЕЛЕЙ ============
# Размер и power tier берутся из единого реестра ai.AVAILABLE_MODELS.
# 👑 >= 100B   🟢 >= 30B   🟡 >= 12B   🔴 < 12B

# Пороги бейджа (параметры, млрд)
BADGE_CROWN_MIN = 100.0   # 👑
BADGE_GREEN_MIN = 30.0    # 🟢
BADGE_YELLOW_MIN = 12.0   # 🟡
# иначе 🔴


def _params_b(model_key: str) -> float | None:
    """Число параметров (B) из единого каталога моделей."""
    try:
        metadata = ai.get_model_metadata(model_key)
        if metadata.get("params_b") is not None:
            return float(metadata["params_b"])
    except Exception:
        pass
    return None


def get_model_badge(model_key: str) -> str:
    """Бейдж по размеру: больше параметров → выше ранг."""
    b = _params_b(model_key)
    try:
        tier = (ai.get_model_metadata(model_key).get("power_tier") or "").lower()
        if tier == "crown":
            return "👑"
        if tier == "green":
            return "🟢"
        if tier == "yellow":
            return "🟡"
        if tier == "red":
            return "🔴"
    except Exception:
        pass
    if b is None:
        return "⚪"
    if b >= BADGE_CROWN_MIN:
        return "👑"
    if b >= BADGE_GREEN_MIN:
        return "🟢"
    if b >= BADGE_YELLOW_MIN:
        return "🟡"
    return "🔴"


def get_param_text(model_key: str) -> str:
    """Краткая подпись размера, напр. 70B / 671B."""
    b = _params_b(model_key)
    if b is None:
        try:
            return ai.get_model_metadata(model_key).get("params_label") or "размер не раскрыт"
        except Exception:
            return ""
    try:
        active = ai.get_model_metadata(model_key).get("active_params_b")
        if active is not None:
            active_text = f"{active:g}B active"
            if b >= 100 and abs(b - round(b)) < 0.01:
                return f"{int(round(b))}B total / {active_text}"
            return f"{b:g}B total / {active_text}"
    except Exception:
        pass
    if b >= 100 and abs(b - round(b)) < 0.01:
        return f"{int(round(b))}B"
    if abs(b - round(b)) < 0.01:
        return f"{int(round(b))}B"
    return f"{b:g}B"


def reminder_keyboard(task: dict) -> InlineKeyboardMarkup:
    task_id = task["id"]
    repeat_label = reminders.recurrence_label(
        task.get("recurrence") or "once", task.get("weekdays") or ""
    )
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text=task.get("confirm_button") or "✅ Подтвердить",
            callback_data=f"task:confirm:{task_id}",
        )],
        [
            InlineKeyboardButton(text="✏️ Название", callback_data=f"task:edit-title:{task_id}"),
            InlineKeyboardButton(
                text=("✉️ Сообщение" if task.get("execution_mode") == "text" else "📝 Промпт ИИ"),
                callback_data=f"task:edit-instruction:{task_id}",
            ),
        ],
        [
            InlineKeyboardButton(text="🕒 Срок", callback_data=f"task:edit-time:{task_id}"),
            InlineKeyboardButton(text=f"🔁 {repeat_label}", callback_data=f"task:repeat-menu:{task_id}"),
        ],
        [InlineKeyboardButton(
            text=("💬 Режим: текст" if task.get("execution_mode") == "text"
                  else "🤖 Режим: промпт ИИ"),
            callback_data=f"task:mode-menu:{task_id}"
        )],
        [InlineKeyboardButton(text="📆 N дней", callback_data=f"task:edit-days:{task_id}"),
         InlineKeyboardButton(text="⚙️ Свой график", callback_data=f"task:edit-schedule:{task_id}")],
        [InlineKeyboardButton(text="🤖 Изменить с ИИ", callback_data=f"task:edit-ai:{task_id}")],
        [InlineKeyboardButton(
            text=task.get("cancel_button") or "❌ Отменить",
            callback_data=f"task:cancel:{task_id}",
        )],
    ])


def rich_reminder_keyboard(task: dict) -> InlineKeyboardMarkup:
    """Use regular inline buttons so callback updates stay aiogram-compatible."""
    return reminder_keyboard(task)


def rich_reminder_card(task: dict, status: str | None = None) -> InputRichMessage:
    """Rich text card; action buttons stay in regular reply_markup."""
    return InputRichMessage(html=reminder_card_text(task, status=status))


async def _send_reminder_legacy_notice(chat_id: int, task_id: str) -> None:
    await bot.send_message(
        int(chat_id),
        "Если вместо карточки выше написано «обновите Telegram», "
        "открой обычную версию сообщения.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(
                text="Открыть обычную версию",
                callback_data=f"task:legacy:{task_id}",
            )
        ]]),
    )


async def send_reminder_card(chat_id: int, task: dict,
                             status: str | None = None) -> tuple[Message, bool]:
    if (not bool(task.get("legacy_ui"))
            and os.getenv("GHOGEM_RICH_REMINDERS", "1") != "0"):
        try:
            card = await bot(SendRichMessage(
                chat_id=int(chat_id),
                rich_message=rich_reminder_card(task,status),
                reply_markup=rich_reminder_keyboard(task)
                    if task.get("status") == "pending" else None,
            ))
            return card, True
        except Exception as error:
            # Bot API 10.3 can accept a rich message while an older aiogram
            # cannot deserialize the returned rich payload. In that case the
            # message already exists, so never send a duplicate card.
            details=str(error)
            accepted=(
                "Failed to deserialize object" in details
                and ("'ok': True" in details or '"ok": true' in details.lower())
            )
            if accepted:
                matched=re.search(r"""['"]message_id['"]:\s*(\d+)""",details)
                if matched:
                    log.info("Telegram accepted Rich card; local model cannot parse new blocks.")
                    return SimpleNamespace(message_id=int(matched.group(1))), True
                raise RuntimeError(
                    "Rich message accepted, but message_id was not readable; "
                    "refusing duplicate send"
                ) from error
            log.warning(
                "Rich reminder rejected, trying regular card (error class=%s)",
                type(error).__name__,
            )
    card = await bot.send_message(
        int(chat_id), reminder_card_text(task, status=status),
        reply_markup=reminder_keyboard(task)
            if task.get("status") == "pending" else None,
        parse_mode="HTML",
    )
    return card, False


def reminder_repeat_keyboard(task: dict) -> InlineKeyboardMarkup:
    task_id = task["id"]
    options = [
        ("↩️ Один раз", "once"),
        ("📆 Каждый день", "daily"),
        ("📅 N дней подряд", "ndays"),
        ("🗓 Пн–Пт", "weekdays"),
        ("🔁 Каждую неделю", "weekly"),
        ("📅 Каждый месяц", "monthly"),
        ("🎛 Выбрать дни", "custom"),
    ]
    rows = [
        [InlineKeyboardButton(text=label, callback_data=f"task:repeat-{value}:{task_id}")]
        for label, value in options
    ]
    rows.append([InlineKeyboardButton(text="⬅️ Назад", callback_data=f"task:repeat-back:{task_id}")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


_REMINDER_MONTH_NAMES = (
    "января", "февраля", "марта", "апреля", "мая", "июня",
    "июля", "августа", "сентября", "октября", "ноября", "декабря",
)
_REMINDER_WEEKDAY_NAMES = (
    "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс",
)


def _reminder_calendar_date(value: str) -> str:
    day = datetime.strptime(value, "%Y-%m-%d").date()
    return f"{day.day} {_REMINDER_MONTH_NAMES[day.month-1]} {day.year}"


def _reminder_date_period(start: str, end: str | None) -> str:
    if not end:
        return f"с {_reminder_calendar_date(start)}, без даты окончания"
    first = datetime.strptime(start, "%Y-%m-%d").date()
    last = datetime.strptime(end, "%Y-%m-%d").date()
    if first == last:
        return _reminder_calendar_date(start)
    return f"{_reminder_calendar_date(start)} — {_reminder_calendar_date(end)} (включительно)"


def _remaining_reminder_events(
    policy: dict,
    first: int,
    completed: int,
    *,
    timezone_name: str = reminders.DEFAULT_TIMEZONE,
    ceiling: int = 120,
) -> str:
    # For endless schedules, showing an invented total would be misleading.
    if (policy.get("mode") not in ("dates", "occurrences")
            and not policy.get("end_date") and not policy.get("count")):
        return "без ограничения"
    cursor = int(first) - 1
    for count in range(ceiling + 1):
        stamp = reminders.schedule_v2.next_trigger(
            policy,
            after=cursor,
            completed=completed + count,
            timezone_name=timezone_name,
        )
        if stamp is None:
            return str(count)
        cursor = int(stamp)
    return f"больше {ceiling}"


def reminder_schedule_text(task: dict) -> str:
    """Clear calendar summary, shared by regular and rich Telegram cards."""
    timezone_name = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
    zone = reminders.timezone_obj(timezone_name)
    due = datetime.fromtimestamp(int(task["run_at"]), zone)
    tz_label = reminders.timezone_label(timezone_name, due)
    first = (
        f"{_REMINDER_WEEKDAY_NAMES[due.weekday()]}, {due.day} "
        f"{_REMINDER_MONTH_NAMES[due.month-1]} {due.year}, "
        f"{due.strftime('%H:%M')} {tz_label}"
    )
    skipped=int(task.get("occurrences_skipped") or 0)
    skipped_line=f"\n\n⏭ <b>Пропущено</b>\n{skipped}" if skipped else ""
    if not task.get("schedule_json") and (task.get("recurrence") or "once") == "once":
        return f"📅 <b>Когда</b>\n{first}" + skipped_line

    lines = [f"📅 <b>Ближайшее срабатывание</b>\n{first}"]
    if not task.get("schedule_json"):
        repeat = reminders.recurrence_label(
            task.get("recurrence") or "once", task.get("weekdays") or ""
        )
        lines.append(f"🔁 <b>Повтор</b>\n{html.escape(repeat)} · {due.strftime('%H:%M')} {html.escape(tz_label)}")
        lines.append("📆 <b>Окончание</b>\nНе установлено")
        return "\n\n".join(lines) + skipped_line

    try:
        schedule = reminders.schedule_v2.normalize_schedule(
            json.loads(task["schedule_json"]),
            timezone_name=timezone_name,
        )
        if schedule.get("relative_filter") == "next_days":
            repeat = f"{schedule['days_count']} календарных дней подряд"
        elif schedule["mode"] == "daily":
            repeat = "Каждый день"
        elif schedule["mode"] == "weekdays":
            repeat = "По будням (Пн–Пт)"
        elif schedule["mode"] == "weekly":
            repeat = "Каждую неделю"
        elif schedule["mode"] == "monthly":
            repeat = "Каждый месяц"
        elif schedule["mode"] == "custom":
            repeat = "В выбранные дни недели"
        elif schedule["mode"] == "dates":
            repeat = "По выбранным датам"
        else:
            repeat = "По индивидуальному расписанию"

        if schedule.get("weekdays"):
            days = ", ".join(_REMINDER_WEEKDAY_NAMES[n-1] for n in schedule["weekdays"])
            repeat += f" · {days}"

        end_date = (schedule["end_date"] or (
            schedule["dates"][-1] if schedule["mode"] == "dates" else None
        ))
        lines.append(
            f"🗓 <b>Период</b>\n"
            f"{html.escape(_reminder_date_period(schedule['start_date'], end_date))}"
        )
        if schedule["mode"] == "occurrences":
            events = schedule["occurrences"]
            if len(events) <= 6:
                exact = [
                    datetime.fromisoformat(value).astimezone(zone).strftime("%d.%m %H:%M")
                    for value in events
                ]
                lines.append(f"🕒 <b>Все даты и часы ({html.escape(tz_label)})</b>\n" + ", ".join(exact))
            else:
                lines.append("🕒 <b>Время</b>\nУказано отдельно для каждой даты")
        else:
            if schedule["mode"] == "dates":
                selected = [
                    datetime.strptime(value, "%Y-%m-%d").strftime("%d.%m")
                    for value in schedule["dates"][:8]
                ]
                repeat += ": " + ", ".join(selected)
                if len(schedule["dates"]) > 8:
                    repeat += "…"
            lines.append(f"🕒 <b>Часы</b>\n{', '.join(schedule['times'])} {html.escape(tz_label)}")

        if schedule["mode"] not in ("occurrences",):
            if schedule.get("exclude_dates"):
                repeat += f"; пропуск дат: {len(schedule['exclude_dates'])}"
            lines.append(f"🔁 <b>Повтор</b>\n{html.escape(repeat)}")
        remaining = _remaining_reminder_events(
            schedule,
            int(task["run_at"]),
            int(task.get("occurrences_done") or 0),
            timezone_name=timezone_name,
        )
        lines.append(f"🔢 <b>Осталось срабатываний</b>\n{remaining}")
    except (ValueError, TypeError, KeyError, OverflowError):
        lines.append("🔁 <b>Повтор</b>\nИндивидуальное расписание")
    return "\n\n".join(lines) + skipped_line


def reminder_card_text(task: dict, status: str | None = None) -> str:
    instruction = str(task.get("instruction") or "").strip()
    if len(instruction) > 1200:
        instruction = instruction[:1197] + "…"
    title = html.escape(str(task.get("title") or "Задание"))
    body = html.escape(instruction)
    execution_mode = task.get("execution_mode") or "ai"
    mode_label = ("💬 Обычное сообщение · без ИИ"
                  if execution_mode == "text" else "🤖 Промпт для ИИ · с инструментами")
    content_heading = "Текст сообщения" if execution_mode == "text" else "Что выполнит ИИ"
    prefix = (html.escape(status) + "\n\n") if status else ""
    activation = (
        "⏳ Задание ждёт подтверждения. До него сообщения не отправляются."
        if task.get("status") == "pending"
        else "✅ Задание подтверждено." if task.get("status") == "scheduled"
        else " "
    )
    return (
        f"{prefix}🗓 <b>Напоминание</b>\n\n"
        f"<b>Название</b>\n{title}\n\n"
        f"<b>Режим</b>\n{mode_label}\n\n"
        f"<b>{content_heading}</b>\n{body}\n\n"
        + reminder_schedule_text(task)
        + f"\n\n{activation}"
    )


async def refresh_reminder_card(task: dict, status: str | None = None):
    message_id = task.get("config_message_id")
    if not message_id:
        return
    if (not bool(task.get("legacy_ui"))
            and os.getenv("GHOGEM_RICH_REMINDERS", "1") != "0"):
        try:
            await bot(EditMessageText(
                chat_id=int(task["telegram_chat_id"]),
                message_id=int(message_id),
                rich_message=rich_reminder_card(task, status=status),
                reply_markup=(
                    rich_reminder_keyboard(task)
                    if task.get("status") == "pending"
                    else _reminder_detail_controls(task)
                    if task.get("status") == "scheduled"
                    else None
                ),
            ))
            return
        except Exception as error:
            details=str(error)
            accepted=(
                "Failed to deserialize object" in details
                and ("'ok': True" in details or '"ok": true' in details.lower())
            )
            if accepted:
                log.info("Telegram accepted Rich card edit; ignoring local parse mismatch.")
                return
            log.warning(
                "Rich reminder edit rejected for %s (%s); trying HTML",
                task.get("id"),type(error).__name__,
            )
    try:
        await bot.edit_message_text(
            chat_id=int(task["telegram_chat_id"]),
            message_id=int(message_id),
            text=reminder_card_text(task, status=status),
            reply_markup=(
                reminder_keyboard(task)
                if task.get("status") == "pending"
                else _reminder_detail_controls(task)
                if task.get("status") == "scheduled"
                else None
            ),
            parse_mode="HTML",
        )
    except Exception:
        log.exception("Не удалось обновить карточку задания %s", task.get("id"))


async def propose_reminder(
    user_id: int,
    telegram_chat_id: int,
    ai_chat_id: str,
    model_key: str,
    args: dict,
    created_task_out: dict | None = None,
) -> str:
    title = str(args.get("title") or args.get("instruction") or "").strip()[:120]
    instruction = str(args.get("instruction") or title).strip()[:3000]
    execution_mode = reminders.normalize_execution_mode(args.get("execution_mode") or "ai")
    timezone_name = await db.get_timezone(user_id)
    schedule = args.get("schedule")
    if schedule is not None:
        # Resolve relative dates ("today" / "tomorrow") once, then persist
        # those absolute Moscow dates in the single reminder card.
        schedule = reminders.schedule_v2.normalize_schedule(
            schedule, timezone_name=timezone_name
        )
        run_at = 0  # advanced calendar computes its first event in reminders.py
    else:
        run_at = reminders.parse_run_at(
            args.get("run_at"), timezone_name=timezone_name
        )
    is_premium = await db.is_subscribed(user_id)
    max_active = 30 if is_premium else 10
    try:
        task = await reminders.create_draft(
            user_id=user_id,
            telegram_chat_id=telegram_chat_id,
            ai_chat_id=ai_chat_id,
            model_key=model_key,
            title=title,
            instruction=instruction,
            execution_mode=execution_mode,
            run_at=run_at,
            confirm_button=args.get("confirm_button") or "✅ Подтвердить",
            cancel_button=args.get("cancel_button") or "❌ Отменить",
            recurrence=args.get("repeat") or "once",
            weekdays=args.get("weekdays") or [],
            schedule=schedule,
            max_active=max_active,
            timezone_name=timezone_name,
        )
    except reminders.ReminderLimitError as error:
        tier = "Premium" if is_premium else "Free"
        upgrade = "" if is_premium else " Оформи Premium через /subscribe — там лимит 30."
        raise ValueError(
            f"{error} Тариф {tier}: максимум {max_active} активных заданий.{upgrade}"
        ) from error
    try:
        message, used_rich = await send_reminder_card(telegram_chat_id, task)
        await reminders.set_config_message(task["id"], user_id, message.message_id)
        if used_rich:
            await _send_reminder_legacy_notice(telegram_chat_id, str(task["id"]))
    except Exception:
        await reminders.cancel(task["id"], user_id)
        raise
    if created_task_out is not None:
        created_task_out["id"] = task["id"]
    return "Одна карточка задания отправлена и ждёт подтверждения пользователя."


def _reminder_trigger_iso(
    timestamp: int,
    timezone_name: str = reminders.DEFAULT_TIMEZONE,
) -> str:
    return datetime.fromtimestamp(
        int(timestamp), reminders.timezone_obj(timezone_name)
    ).isoformat(timespec="minutes")


def _collect_finite_reminder_triggers(task: dict, *, max_triggers: int = 512) -> list[str]:
    """Expand only bounded calendars; never materialize an endless schedule."""
    timezone_name = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
    if task.get("schedule_json"):
        policy = reminders.schedule_v2.normalize_schedule(
            json.loads(task["schedule_json"]),
            timezone_name=timezone_name,
        )
        if policy["mode"] not in ("dates", "occurrences") and not policy["end_date"] and not policy["count"]:
            raise ValueError("Для бессрочного графика используй одну полную schedule-инструкцию.")
        current = int(time.time()) + reminders.MIN_LEAD_SECONDS - 1
        triggers = []
        for index in range(max_triggers + 1):
            stamp = reminders.schedule_v2.next_trigger(
                policy,
                after=current,
                completed=index,
                timezone_name=timezone_name,
            )
            if stamp is None:
                return triggers
            triggers.append(_reminder_trigger_iso(stamp, timezone_name))
            current = stamp
        raise ValueError("Слишком много срабатываний для объединения.")
    if (task.get("recurrence") or "once") != "once":
        raise ValueError("Бессрочный простой повтор нельзя автоматически объединить с отдельными датами.")
    return [_reminder_trigger_iso(task["run_at"], timezone_name)]


async def merge_reminder_into_one_card(user_id: int, task_id: str, args: dict) -> str:
    """Weak models sometimes call create_reminder for every hour.

    Merge compatible proposed times into one unconfirmed card rather than
    creating six notifications/cards. Exact timestamp lists prevent accidental
    cartesian products of dates and hours.
    """
    task = await reminders.get_task(task_id)
    if (not task or int(task["user_id"]) != int(user_id)
            or task["status"] != "pending"):
        return "❌ Черновик уже недоступен. Нельзя добавлять время."
    old_instruction = str(task.get("instruction") or "").strip().casefold()
    new_instruction = str(args.get("instruction") or old_instruction).strip().casefold()
    if old_instruction != new_instruction:
        return ("⚠️ Эта карточка уже создана для другого действия. "
                "Для другой задачи попроси отдельным сообщением. "
                "Дополнительная карточка НЕ создана.")
    existing_mode = task.get("execution_mode") or "ai"
    requested_mode = args.get("execution_mode") or existing_mode
    if requested_mode != existing_mode:
        return ("⚠️ Нельзя объединить текстовое сообщение и ИИ-промпт "
                "в одну карточку: выбери один режим выполнения.")
    try:
        events = _collect_finite_reminder_triggers(task)
        timezone_name = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
        if args.get("schedule") is not None:
            additional = {
                "recurrence":"advanced",
                "schedule_json":json.dumps(args["schedule"]),
                "timezone_name":timezone_name,
            }
            events.extend(_collect_finite_reminder_triggers(additional))
        else:
            if (args.get("repeat") or "once") != "once":
                return ("⚠️ В этом проходе уже подготовлена карточка; "
                        "полные повторы передай единым schedule. Новая карточка НЕ создана.")
            stamp = reminders.parse_run_at(
                args.get("run_at"), timezone_name=timezone_name
            )
            events.append(_reminder_trigger_iso(stamp, timezone_name))
        future = sorted(set(events))
        if not future or len(future)>512:
            raise ValueError("Неверное количество срабатываний.")
        updated = await reminders.update_draft(
            task_id,user_id,
            schedule={"mode":"occurrences","occurrences":future},
        )
        if not updated:
            return "❌ Карточка уже подтверждена или отменена."
        await refresh_reminder_card(updated,status="🗓 Время добавлено в ту же карточку")
        return (f"✅ Добавлено в ту же карточку. "
                f"Срабатываний: {len(future)}. "
                "НЕ создавай дополнительных карточек; пользователь подтвердит одну.")
    except (ValueError, TypeError, KeyError) as exc:
        return f"❌ Не удалось объединить сроки: {str(exc)[:180]}. Новая карточка НЕ создана."


# ============ ЕДИНЫЙ СТРИМ ХОДА РАБОТЫ ============

def append_agent_reasoning(events: list[tuple[str,str]], chunk: str):
    """Never store provider trace text in the user-visible timeline."""
    if not isinstance(chunk, str) or not chunk:
        return
    marker = "Модель анализирует запрос…"
    if not events or events[-1] != ("thought", marker):
        events.append(("thought", marker))
    if len(events) > 85:
        del events[:-65]


def format_agent_timeline(events: list[tuple[str,str]]) -> str:
    """Compact chronological work log for one Telegram message."""
    rendered=[]
    for kind,raw in events:
        text=str(raw or "").strip()
        if not text:
            continue
        if len(text)>700:
            text=text[:300]+" … [сокращено] … "+text[-320:]
        escaped=html.escape(text)
        if kind=="reasoning":
            line="💭 Модель анализирует запрос…"
        elif kind=="thought":
            line=f"💭 {escaped}"
        elif kind=="done":
            line=f"• ✓ {escaped}"
        elif kind=="error":
            cleaned=escaped.removeprefix("❌").strip()
            line=f"• ✕ {cleaned}"
        else:
            line=f"• {escaped}"
        if rendered and rendered[-1][0] == line:
            rendered[-1]=(line,rendered[-1][1]+1)
        else:
            rendered.append((line,1))

    lines=[
        line if count==1 else f"{line} <i>×{count}</i>"
        for line,count in rendered
    ]
    dropped=0
    while len(lines)>12:
        lines.pop(0)
        dropped+=1
    while len(lines)>1 and len("\n".join(lines))>1750:
        lines.pop(0)
        dropped+=1
    if dropped:
        lines.insert(0,f"… <i>ещё {dropped} шаг(ов) выше</i>")
    return "\n".join(lines)


# ============ ОБРАБОТКА ОДНОГО ЗАПРОСА ============

async def process_request(user_id: int, chat_id: int, prompt: str, status_message: Message | None, *, attachment_name: str = "", ai_chat_id_override: str = "", attempts: int = 0):
    global cooldown_seconds, cooldown_until

    user_status[user_id] = "processing"
    register_dispatch()
    origin_ai_chat_id = str(ai_chat_id_override or ai.get_current_chat(user_id))

    current_model_key = await get_user_model(user_id)
    await ensure_chat_persisted(user_id)
    working_chat_title = str(
        ai.get_chat_title(user_id, origin_ai_chat_id) or "Новый чат"
    )[:80]

    if ai.is_model_retired(current_model_key):
        old_short = current_model_key.split(":", 1)[1]
        log.info("Модель %s уже отключена, сброс на дефолтную для %s", current_model_key, user_id)
        user_models.pop(user_id, None)
        await persist_user_model(user_id, ai.DEFAULT_MODEL_KEY)
        ai.reset_chat(user_id)
        current_model_key = ai.DEFAULT_MODEL_KEY
        message_text = (
            f"⚠️ Модель <code>{old_short}</code> только что отключена провайдером.\n"
            f"Переключил вас на <code>{ai.DEFAULT_MODEL_KEY.split(':',1)[1]}</code>, повторяю запрос."
        )
        if status_message:
            try:
                await status_message.edit_text(message_text, parse_mode="HTML")
            except Exception:
                await bot.send_message(chat_id, message_text, parse_mode="HTML")
        else:
            await bot.send_message(chat_id, message_text, parse_mode="HTML")

    _perm_info = ai.AVAILABLE_MODELS.get(current_model_key) or {}
    if _perm_info.get("availability_status") in {"provider_issue", "free_removed", "disabled", "hidden"}:
        old_short = current_model_key.split(":", 1)[1]
        detail = str(_perm_info.get("status_detail") or "").strip()
        log.info("Модель %s скрыта провайдером, сброс на дефолтную для %s", current_model_key, user_id)
        user_models.pop(user_id, None)
        await persist_user_model(user_id, ai.DEFAULT_MODEL_KEY)
        ai.reset_chat(user_id)
        current_model_key = ai.DEFAULT_MODEL_KEY
        message_text = (
            f"⚠️ Модель <code>{old_short}</code> больше недоступна у провайдера"
            + (f" ({detail})" if detail else "")
            + f".\nПереключил вас на <code>{ai.DEFAULT_MODEL_KEY.split(':',1)[1]}</code>, повторяю запрос."
        )
        if status_message:
            try:
                await status_message.edit_text(message_text, parse_mode="HTML")
            except Exception:
                await bot.send_message(chat_id, message_text, parse_mode="HTML")
        else:
            await bot.send_message(chat_id, message_text, parse_mode="HTML")

    if current_model_key in ai.PREMIUM_MODEL_KEYS and not await db.is_subscribed(user_id):
        log.info("Подписка истекла у %s, сброс модели %s", user_id, current_model_key)
        user_models.pop(user_id, None)
        await persist_user_model(user_id, ai.DEFAULT_MODEL_KEY)
        ai.reset_chat(user_id)
        message_text = (
            "⚠️ Ваша подписка истекла, премиум-модели больше недоступны.\n"
            f"Модель переключена на <code>{ai.DEFAULT_MODEL_KEY.split(':',1)[1]}</code>.\n"
            "Продлите подписку: /subscribe"
        )
        if status_message:
            try:
                await status_message.edit_text(message_text, parse_mode="HTML")
            except Exception:
                await bot.send_message(chat_id, message_text, parse_mode="HTML")
        else:
            await bot.send_message(chat_id, message_text, parse_mode="HTML")
        return

    log.info("Запрос от %s (rpm=%d/%d, rpd=%d/%d): %.50s", user_id, rpm_used(), RPM_LIMIT, rpd_used(), RPD_LIMIT, prompt)

    custom_prompt = await db.get_custom_prompt(user_id)
    timezone_name = await db.get_timezone(user_id)
    fallback_on_rate_limit = await db.get_fallback_on_rate_limit(user_id)
    rating_is_premium = await db.is_subscribed(user_id)
    rating_state = await asyncio.to_thread(model_ratings.user_rating_state, user_id)
    rating_context = rating_model_context(
        rating_state,
        is_premium=rating_is_premium,
    )

    current_short = current_model_key.split(":", 1)[1] if ":" in current_model_key else current_model_key
    badge = get_model_badge(current_model_key)
    params = get_param_text(current_model_key)
    model_header = f"{badge} <b>Модель:</b> <code>{current_short}</code> ({params})\n━━━━━━━━━━━━━━━\n"

    # Статус "Думает..." — сюда же пишем действия агента и накопленные досылы.
    followups: list[BufferedFollowup] = []
    if status_message:
        thinking_msg = status_message
        try:
            await bot.edit_message_text(
                chat_id=chat_id,
                message_id=thinking_msg.message_id,
                text=(
                    f"🤔 <b>{badge} {current_short}</b> думает...\n"
                    f"💬 <b>Чат:</b> {html.escape(working_chat_title)}"
                ),
                parse_mode="HTML",
                reply_markup=agent_stop_keyboard(0),
            )
        except Exception:
            thinking_msg = await bot.send_message(
                chat_id,
                (
                    f"🤔 <b>{badge} {current_short}</b> думает...\n"
                    f"💬 <b>Чат:</b> {html.escape(working_chat_title)}"
                ),
                parse_mode="HTML",
                reply_markup=agent_stop_keyboard(0),
            )
    else:
        thinking_msg = await bot.send_message(
            chat_id,
            (
                f"🤔 <b>{badge} {current_short}</b> думает...\n"
                f"💬 <b>Чат:</b> {html.escape(working_chat_title)}"
            ),
            parse_mode="HTML",
            reply_markup=agent_stop_keyboard(0),
        )

    typing_task = asyncio.create_task(keep_typing(chat_id))
    actions_log: list[tuple[str,str]] = []
    preview_answer = ""
    stream_preview_mode: bool | None = None
    last_status_update = 0.0
    waiting_for_choice = False
    choice_wait_token = ""
    chat_title_task = None
    chat_title_progress_task = None

    def _format_interleaved_timeline(events: list[tuple[str,str]]) -> str:
        return format_agent_timeline(events)

    async def _render_progress(*,force=False):
        nonlocal last_status_update
        now=time.monotonic()
        if not force and now-last_status_update<0.85:
            return
        last_status_update=now
        body=_format_interleaved_timeline(actions_log[-22:])
        header = (
            f"⏳ <b>{badge} {current_short}</b> ждёт ответа…"
            if waiting_for_choice
            else f"🤖 <b>{badge} {current_short}</b> работает…"
        )
        status=(
            header + "\n"
            f"💬 <b>Чат:</b> {html.escape(working_chat_title)}\n"
            "━━━━━━━━━━━━━━━\n"
            "🛠 <b>Ход работы</b>\n"
            f"{body or ('❓ Жду ответа пользователя…' if waiting_for_choice else '⏳ Ожидаю ответа модели…')}"
        )
        if preview_answer:
            status += (
                "\n━━━━━━━━━━━━━━━\n"
                f"{html.escape(preview_answer[-1200:])} ▌"
            )
        followup_tail = _followup_block(followups)
        if followup_tail:
            room = max(850, 3970 - len(followup_tail))
            if len(status) > room:
                status = _fix_unmatched_tags(status[:max(0, room - 28)]) + "\n…"
            status += followup_tail
        try:
            await bot.edit_message_text(
                chat_id=chat_id,
                message_id=thinking_msg.message_id,
                text=_fix_unmatched_tags(status[:3980]),
                parse_mode="HTML",
                reply_markup=agent_stop_keyboard(len(followups)),
            )
        except Exception:
            # Telegram may reject duplicate edits or rate-limit token updates.
            pass

    async def on_action(status: str, kind: str = "action"):
        nonlocal preview_answer, stream_preview_mode
        kind=kind if kind in ("thought","action","done","error") else "action"
        if kind=="action":
            preview_answer=""
            stream_preview_mode=None
        run = active_agent_runs.get(user_id)
        if run and run.get("message_id") == thinking_msg.message_id:
            run["last_activity_at"] = time.monotonic()
        if kind in ("done","error") and actions_log and actions_log[-1][0]=="action":
            actions_log[-1]=(kind,status)
        else:
            actions_log.append((kind,status))
        if len(actions_log)>85:
            del actions_log[:-65]
        await _render_progress(force=True)

    async def on_provider_reasoning(chunk: str):
        run = active_agent_runs.get(user_id)
        if run and run.get("message_id") == thinking_msg.message_id:
            run["last_activity_at"] = time.monotonic()
        return

    async def on_text_chunk(text: str):
        nonlocal preview_answer, stream_preview_mode
        run = active_agent_runs.get(user_id)
        if run and run.get("message_id") == thinking_msg.message_id:
            run["last_activity_at"] = time.monotonic()

        candidate = _scrub_agent_block_preview(str(text or ""))
        stripped = candidate.lstrip()

        # Never live-stream raw tool arguments (JSON/SVG). Some providers
        # print generate_video arguments as ordinary content instead of a
        # function_call; the agent layer may recover and execute them.
        if _looks_like_internal_structured_payload(candidate):
            had_preview = bool(preview_answer)
            stream_preview_mode = False
            preview_answer = ""
            if had_preview:
                await _render_progress(force=True)
            return

        # Delay ambiguous structured prefixes until there is enough content
        # to tell user-facing text from an internal payload.
        if stream_preview_mode is None:
            if stripped.startswith(("`", "{", "[")) and len(stripped) < 96:
                return
            stream_preview_mode = True

        if stream_preview_mode is False:
            return
        preview_answer = candidate
        await _render_progress()

    def _take_active_followups() -> list[BufferedFollowup]:
        run = active_agent_runs.get(user_id)
        if not run or run.get("message_id") != thinking_msg.message_id:
            return []
        items = list(run.get("followups") or [])
        run.get("followups", []).clear()
        return items

    try:
        # Если есть долговременная память — сразу показываем чтение
        if ai.read_memory(user_id).strip():
            await on_action("🧠 Читаю память...", kind="action")

        # Все сообщения идут через tool-capable agent loop.
        # Решение о вызове инструментов принимает модель на каждом запросе.
        force_search = user_id in web_search_once

        if force_search:
            await on_action("🔍 Веб-поиск включён для запроса", kind="action")

        # Media inspection is enforced by the agent runner; it may not finish
        # with a text-only answer until the supplied attachment is analyzed.
        model_prompt = prompt

        created_reminder_in_turn: dict = {}

        async def on_reminder_proposed(args, proposed_model_key, ai_chat_id):
            # Server-side creation authorization based on the real current
            # message, not on the model's invented tool arguments.
            if not ai.reminder_access.user_explicitly_requests_new_reminder(run_prompt):
                return ("❌ Пользователь не просил новое напоминание. "
                        "Для изменения старой карточки используй update_reminder; "
                        "не придумывай новые названия или сроки.")
            if created_reminder_in_turn.get("id"):
                return await merge_reminder_into_one_card(
                    user_id,created_reminder_in_turn["id"],args
                )
            return await propose_reminder(
                user_id, chat_id, ai_chat_id, proposed_model_key, args,
                created_task_out=created_reminder_in_turn,
            )

        async def on_reminder_updated(task_id):
            wake_reminder_scheduler()
            task=await reminders.get_owned(task_id,user_id)
            if task:
                await refresh_reminder_card(task,status="✏️ Настройки напоминания изменены")

        async def on_storage_cleanup_proposed(args, proposed_model_key, ai_chat_id):
            # Model may recommend deletion, but only the authenticated Telegram
            # owner can approve the actual destructive action.
            return await propose_ai_storage_cleanup(
                user_id,
                chat_id,
                ai_chat_id,
                args,
            )

        async def on_chat_management_proposed(args, proposed_model_key, ai_chat_id):
            # Archive/delete is owner-confirmed in Telegram; the model only
            # selects an already-owned chat and proposes the action.
            return await propose_ai_chat_management(
                user_id,
                chat_id,
                ai_chat_id,
                args,
            )

        async def on_choice_proposed(args, proposed_model_key, ai_chat_id):
            nonlocal choice_wait_token
            question = str(args.get("question") or "").strip()
            options = [str(x).strip() for x in (args.get("options") or []) if str(x).strip()]
            if not question or not 2 <= len(options) <= 8:
                return "❌ Некорректный интерактивный вопрос."
            run = active_agent_runs.get(user_id)
            if (run and run.get("message_id") == thinking_msg.message_id
                    and run.get("followups")):
                return (
                    "⚠️ Пока готовился вопрос, пользователь уже прислал новое сообщение. "
                    "Сначала учти это уточнение; интерактивная карточка не показана."
                )
            card = await asyncio.to_thread(
                interactive_choices.create,
                user_id,
                chat_id,
                str(ai_chat_id),
                question,
                options,
            )
            token = str(card["token"])
            text = interactive_choice_text(question, options)
            markup = interactive_choice_keyboard(token, len(options))
            try:
                # The question is deliberately a SEPARATE message. The main
                # agent card stays visible above it and switches to «ждёт ответа».
                sent = await bot.send_message(
                    chat_id,
                    text,
                    parse_mode="HTML",
                    reply_markup=markup,
                )
                message_id = sent.message_id
            except Exception:
                await asyncio.to_thread(interactive_choices.expire_user, user_id)
                if run and run.get("message_id") == thinking_msg.message_id:
                    run["accept_followups"] = True
                raise
            await asyncio.to_thread(interactive_choices.attach_message, token, message_id)
            future = asyncio.get_running_loop().create_future()
            old_future = interactive_choice_waiters.pop(token, None)
            if old_future is not None and not old_future.done():
                old_future.cancel()
            interactive_choice_waiters[token] = future
            choice_wait_token = token
            if run and run.get("message_id") == thinking_msg.message_id:
                run["accept_followups"] = False
                run["waiting_choice_token"] = token
            return json.dumps({
                "status":"awaiting_user_choice",
                "token":token,
                "message_id":message_id,
                "note":"Отдельная карточка показана. Останови генерацию и жди реального ответа пользователя.",
            },ensure_ascii=False)

        run_prompt = model_prompt
        run_attachment = attachment_name
        reply_text = ""
        # Генерация короткого названия идёт параллельно основному ответу и не
        # должна добавлять задержку к чату. Для уже названного чата функция
        # вернётся сразу без обращения к модели.
        chat_title_task = asyncio.create_task(
            ai.ensure_chat_title(user_id, origin_ai_chat_id, prompt)
        )

        async def _watch_generated_chat_title():
            nonlocal working_chat_title
            try:
                generated_title = str(await chat_title_task or "Новый чат")[:80]
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception(
                    "Chat title generation failed during progress (user=%s chat=%s)",
                    user_id,
                    origin_ai_chat_id,
                )
                return
            if generated_title and generated_title != working_chat_title:
                working_chat_title = generated_title
                try:
                    await _render_progress(force=True)
                except Exception:
                    log.exception(
                        "Could not refresh progress with generated chat title "
                        "(user=%s chat=%s)",
                        user_id,
                        origin_ai_chat_id,
                    )

        chat_title_progress_task = asyncio.create_task(
            _watch_generated_chat_title()
        )

        while True:
            model_holder = [current_model_key]
            persistent_model_holder: list[str] = []
            generation = asyncio.create_task(ai.ask_ai(
                user_id, run_prompt, current_model_key, SYSTEM_PROMPT, MAX_HISTORY_TURNS,
                custom_prompt=custom_prompt, on_action=on_action,
                force_web_search=force_search, model_holder=model_holder,
                on_text_chunk=on_text_chunk,
                on_reminder_proposed=on_reminder_proposed,
                on_reminder_updated=on_reminder_updated,
                on_storage_cleanup_proposed=on_storage_cleanup_proposed,
                on_chat_management_proposed=on_chat_management_proposed,
                on_choice_proposed=on_choice_proposed,
                on_reasoning=on_provider_reasoning,
                required_media_filename=run_attachment or None,
                chat_id_override=origin_ai_chat_id,
                allow_model_fallback=fallback_on_rate_limit,
                allow_rate_limit_fallback=fallback_on_rate_limit,
                timezone_name=timezone_name,
                persistent_model_holder=persistent_model_holder,
            ))

            run = active_agent_runs.get(user_id)
            if not run or run.get("message_id") != thinking_msg.message_id:
                run = {
                    "kind": "prompt",
                    "chat_id": chat_id,
                    "ai_chat_id": origin_ai_chat_id,
                    "message_id": thinking_msg.message_id,
                    "followups": followups,
                    "refresh": _render_progress,
                    "cancel_payload": [],
                    "started_at": time.monotonic(),
                    "last_activity_at": time.monotonic(),
                }
                active_agent_runs[user_id] = run
            run.update({
                "task": generation,
                "original_prompt": run_prompt,
                "attachment_name": run_attachment,
                "cancel_reason": "",
                "accept_followups": True,
                "last_activity_at": time.monotonic(),
            })

            try:
                reply_text = await asyncio.wait_for(
                    generation,
                    timeout=FOREGROUND_AGENT_TIMEOUT_SECONDS,
                )
            except asyncio.TimeoutError:
                log.warning(
                    "Foreground agent timeout after %ss (user=%s chat=%s model=%s)",
                    FOREGROUND_AGENT_TIMEOUT_SECONDS,
                    user_id,
                    origin_ai_chat_id,
                    current_model_key,
                )
                run = active_agent_runs.get(user_id)
                if run and run.get("message_id") == thinking_msg.message_id:
                    run["accept_followups"] = False
                actions_log.append((
                    "done",
                    "⌛️ Генерация остановлена: превышено время ожидания",
                ))
                await _render_progress(force=True)
                reply_text = (
                    "⚠️ Ответ не завершился вовремя. Запуск остановлен, "
                    "можно сразу отправить запрос ещё раз."
                )
                break
            except asyncio.CancelledError:
                run = active_agent_runs.get(user_id)
                reason = run.get("cancel_reason") if run else ""
                if reason != "send-followups":
                    raise
                buffered = list(run.get("cancel_payload") or [])
                buffered.extend(list(run.get("followups") or []))
                run.get("followups", []).clear()
                run["cancel_payload"] = []
                run["cancel_reason"] = ""
                if not buffered:
                    raise
                run_prompt = _followup_prompt(
                    buffered, original_prompt=run_prompt, interrupted=True
                )
                run_attachment = run_attachment or _followup_attachment(buffered)
                preview_answer = ""
                actions_log.append((
                    "thought",
                    f"Получил {len(buffered)} уточнение(й) — продолжаю эту же задачу…",
                ))
                run["accept_followups"] = True
                await _render_progress(force=True)
                log.info(
                    "[ДОСЫЛ-СЕЙЧАС] user=%s count=%d same_message=%s",
                    user_id, len(buffered), thinking_msg.message_id,
                )
                continue

            if persistent_model_holder:
                requested_key = persistent_model_holder[-1]
                if requested_key in ai.AVAILABLE_MODELS and not ai.is_model_retired(requested_key):
                    await persist_user_model(user_id, requested_key)

            if model_holder and model_holder[0] and model_holder[0] != current_model_key:
                new_key = model_holder[0]
                log.info(
                    "Временный fallback модели для запроса %s: %s → %s",
                    user_id, current_model_key, new_key,
                )
                current_model_key = new_key
                current_short = (
                    current_model_key.split(":", 1)[1]
                    if ":" in current_model_key else current_model_key
                )
                badge = get_model_badge(current_model_key)
                params = get_param_text(current_model_key)
                model_header = (
                    f"{badge} <b>Модель:</b> <code>{current_short}</code> ({params})\n"
                    f"━━━━━━━━━━━━━━━\n"
                )

            if reply_text == "__GHOGEM_AWAITING_USER_CHOICE__":
                run = active_agent_runs.get(user_id)
                token = str(choice_wait_token or "")
                future = interactive_choice_waiters.get(token) if token else None
                if not token or future is None:
                    log.error("Interactive choice sentinel without live waiter (user=%s)", user_id)
                    reply_text = "⚠️ Не удалось дождаться интерактивного ответа. Попробуй ещё раз."
                    break

                waiting_for_choice = True
                preview_answer = ""
                if run and run.get("message_id") == thinking_msg.message_id:
                    run["accept_followups"] = False
                    run["waiting_choice_token"] = token
                await _render_progress(force=True)

                # Do not keep sending Telegram 'typing…' for up to an hour while
                # the user is simply deciding which button to press.
                typing_task.cancel()
                wait_task = asyncio.create_task(
                    asyncio.wait_for(
                        asyncio.shield(future),
                        timeout=max(300, int(interactive_choices.DEFAULT_TTL)),
                    )
                )
                if run and run.get("message_id") == thinking_msg.message_id:
                    run["task"] = wait_task
                try:
                    choice_result = await wait_task
                except asyncio.TimeoutError:
                    card = await asyncio.to_thread(
                        interactive_choices.get, token, include_closed=True
                    )
                    await asyncio.to_thread(interactive_choices.expire_user, user_id)
                    if card:
                        try:
                            await update_interactive_choice_card(
                                card, footer="expired", keep_buttons=False
                            )
                        except Exception:
                            pass
                    actions_log.append(("thought", "⌛️ Время ожидания ответа истекло"))
                    waiting_for_choice = False
                    reply_text = "⌛️ Вопрос закрылся без ответа. Если хочешь — задай выбор ещё раз."
                    break
                except asyncio.CancelledError:
                    await asyncio.to_thread(interactive_choices.expire_user, user_id)
                    raise
                finally:
                    interactive_choice_waiters.pop(token, None)
                    if not future.done():
                        future.cancel()

                waiting_for_choice = False
                choice_wait_token = ""
                typing_task = asyncio.create_task(keep_typing(chat_id))
                run_prompt = str((choice_result or {}).get("prompt") or "").strip()
                run_attachment = ""
                timeline = str((choice_result or {}).get("timeline") or "").strip()
                if timeline:
                    actions_log.append(("thought", timeline))
                if not run_prompt:
                    reply_text = "⚠️ Ответ получен, но продолжение задачи не удалось сформировать."
                    break
                if run and run.get("message_id") == thinking_msg.message_id:
                    run["accept_followups"] = True
                    run.pop("waiting_choice_token", None)
                await _render_progress(force=True)
                log.info(
                    "Interactive choice resumed same agent turn (user=%s token=%s)",
                    user_id, token,
                )
                continue

            run = active_agent_runs.get(user_id)
            if run and run.get("message_id") == thinking_msg.message_id:
                run["accept_followups"] = False
                buffered = list(run.get("followups") or [])
                run.get("followups", []).clear()
                if buffered:
                    run_prompt = _followup_prompt(buffered)
                    run_attachment = _followup_attachment(buffered)
                    preview_answer = ""
                    actions_log.append((
                        "thought",
                        f"Пришло {len(buffered)} сообщение(й) — учитываю их в этой же задаче…",
                    ))
                    run["accept_followups"] = True
                    await _render_progress(force=True)
                    log.info(
                        "[АВТО-ДОСЫЛ] user=%s count=%d same_message=%s",
                        user_id, len(buffered), thinking_msg.message_id,
                    )
                    continue
            break

        if reply_text == "__GHOGEM_AWAITING_USER_CHOICE__":
            log.info("Interactive choice shown to user %s; waiting for real input", user_id)
            return

        cooldown_seconds = 15
        clean_reply = reply_text or ""

        # Очистка мусора
        clean_reply = re.sub(r'<\|[^|]+\|>', '', clean_reply)
        clean_reply = re.sub(r'<\w+_\w+>', '', clean_reply)
        clean_reply = _scrub_agent_block_preview(clean_reply)

        thinking_part, clean_reply = ai.split_thinking(clean_reply)
        # Public provider reasoning was already placed between tool events
        # by on_provider_reasoning during token streaming.
        if thinking_part:
            thinking_part = re.sub(r'<\|[^|]+\|>', '', thinking_part)
            thinking_part = re.sub(r'<\w+_\w+>', '', thinking_part)

        # Слабые модели пишут create_speech / writefile / send_file текстом — исполняем
        try:
            is_prem = await db.is_subscribed(user_id)
            chat_folder = origin_ai_chat_id
            clean_reply = await ai.fulfill_fake_speech_calls(
                clean_reply, user_id, chat_folder, is_premium=is_prem
            )
            clean_reply = ai.fulfill_fake_file_calls(clean_reply, user_id, chat_folder)
            clean_reply = ai.rescue_code_dumps_to_files(clean_reply, user_id, chat_folder)
            clean_reply = ai.scrub_tool_simulation(clean_reply)
        except Exception as e:
            log.warning("fulfill_fake_*_calls: %s", e)

        # GHOSOU_AUDIO_TO_SEND — публичная запись GhoSou. Внутренний путь
        # известен только серверу и никогда не попадает в ответ модели.
        if "GHOSOU_AUDIO_TO_SEND:" in clean_reply:
            for match in list(re.finditer(r"GHOSOU_AUDIO_TO_SEND:([A-Za-z0-9,_\-]+)", clean_reply)):
                identifier = match.group(1).strip()
                resolved = await asyncio.to_thread(music.resolve_public_audio_path, identifier)
                if not resolved:
                    clean_reply = clean_reply.replace(
                        match.group(0),
                        "❌ Публичный аудиофайл GhoSou недоступен.",
                        1,
                    )
                    continue
                track, file_path = resolved
                title = str(track.get("Title") or "Без названия").strip()
                artist = str(
                    track.get("Artist") or track.get("AuthorName") or ""
                ).strip()
                kind = str(track.get("Kind") or "audio").strip()
                duration = track.get("Duration")
                caption_lines = ["🎧 <b>GhoSou</b>", f"<b>{html.escape(title)}</b>"]
                if artist:
                    caption_lines[-1] += f" — {html.escape(artist)}"
                meta = []
                if kind:
                    meta.append(html.escape(kind))
                try:
                    secs = int(float(duration or 0))
                except (TypeError, ValueError):
                    secs = 0
                if secs > 0:
                    meta.append(f"{secs // 60}:{secs % 60:02d}")
                if meta:
                    caption_lines.append(" · ".join(meta))
                rows = []
                stream_url = str(track.get("stream_url") or "").strip()
                download_url = str(track.get("download_url") or "").strip()
                if stream_url:
                    rows.append([InlineKeyboardButton(text="▶️ Слушать", url=stream_url)])
                if download_url:
                    rows.append([InlineKeyboardButton(text="⬇️ Скачать", url=download_url)])
                markup = InlineKeyboardMarkup(inline_keyboard=rows) if rows else None
                safe_title = re.sub(r"[^0-9A-Za-zА-Яа-яЁё._ -]+", "_", title).strip() or "ghosou"
                tg_file = FSInputFile(file_path, filename=(safe_title[:80] + ".ogg"))
                caption = "\n".join(caption_lines)
                sent_ok = False
                try:
                    await bot.send_audio(
                        chat_id,
                        tg_file,
                        caption=caption,
                        parse_mode="HTML",
                        title=title[:64],
                        performer=artist[:64] if artist else None,
                        reply_markup=markup,
                    )
                    sent_ok = True
                except Exception as audio_error:
                    log.warning("GhoSou send_audio fallback: %s", type(audio_error).__name__)
                    try:
                        await bot.send_document(
                            chat_id,
                            FSInputFile(file_path, filename=(safe_title[:80] + ".ogg")),
                            caption=caption,
                            parse_mode="HTML",
                            reply_markup=markup,
                        )
                        sent_ok = True
                    except Exception as document_error:
                        log.warning(
                            "GhoSou send_document failed: %s",
                            type(document_error).__name__,
                        )
                clean_reply = clean_reply.replace(
                    match.group(0),
                    "✅ Аудио из GhoSou отправлено." if sent_ok else "❌ Не удалось отправить аудио GhoSou.",
                    1,
                )

        # IMAGE_TO_SEND — HTML/CSS-рендеры отправляем именно как фото.
        if "IMAGE_TO_SEND:" in clean_reply:
            for match in list(re.finditer(r"IMAGE_TO_SEND:(\S+)", clean_reply)):
                filename = match.group(1).strip()
                chat_id_folder = origin_ai_chat_id
                file_path = None
                try:
                    file_path = ai.get_full_path(user_id, chat_id_folder, f"files/{filename}")
                    if not os.path.exists(file_path):
                        file_path = ai.resolve_user_upload(user_id, chat_id_folder, filename)
                except Exception:
                    file_path = None
                if file_path and os.path.isfile(file_path):
                    try:
                        await bot.send_photo(
                            chat_id,
                            FSInputFile(file_path, filename=filename),
                        )
                        sent_text = f"✅ Изображение {filename} отправлено."
                    except Exception as photo_error:
                        log.warning("send_photo render fallback: %s", type(photo_error).__name__)
                        try:
                            await bot.send_document(
                                chat_id,
                                FSInputFile(file_path, filename=filename),
                            )
                            sent_text = f"✅ Изображение {filename} отправлено файлом."
                        except Exception:
                            sent_text = f"❌ Не удалось отправить изображение {filename}."
                    clean_reply = clean_reply.replace(match.group(0), sent_text, 1)
                else:
                    clean_reply = clean_reply.replace(
                        match.group(0),
                        f"❌ Изображение {filename} не найдено.",
                        1,
                    )

        # VIDEO_TO_SEND — сгенерированный MP4 отправляем именно как видео.
        if "VIDEO_TO_SEND:" in clean_reply:
            for match in list(re.finditer(r"VIDEO_TO_SEND:(\S+)", clean_reply)):
                filename = match.group(1).strip()
                chat_id_folder = origin_ai_chat_id
                file_path = None
                try:
                    file_path = ai.get_full_path(
                        user_id, chat_id_folder, f"files/{filename}"
                    )
                    if not os.path.exists(file_path):
                        file_path = ai.resolve_user_upload(
                            user_id, chat_id_folder, filename
                        )
                except Exception:
                    file_path = None
                if file_path and os.path.isfile(file_path):
                    try:
                        await bot.send_video(
                            chat_id,
                            FSInputFile(file_path, filename=filename),
                            supports_streaming=True,
                        )
                        sent_text = f"✅ Видео {filename} отправлено."
                    except Exception as video_error:
                        log.warning(
                            "send_video render fallback: %s",
                            type(video_error).__name__,
                        )
                        try:
                            await bot.send_document(
                                chat_id,
                                FSInputFile(file_path, filename=filename),
                            )
                            sent_text = f"✅ Видео {filename} отправлено файлом."
                        except Exception:
                            sent_text = f"❌ Не удалось отправить видео {filename}."
                    clean_reply = clean_reply.replace(
                        match.group(0), sent_text, 1
                    )
                else:
                    clean_reply = clean_reply.replace(
                        match.group(0),
                        f"❌ Видео {filename} не найдено.",
                        1,
                    )

        # FILE_TO_SEND (файлы чата или user-level memory.md) — все маркеры
        if "FILE_TO_SEND:" in clean_reply:
            for match in list(re.finditer(r"FILE_TO_SEND:(\S+)", clean_reply)):
                filename = match.group(1).strip()
                chat_id_folder = origin_ai_chat_id
                found = False
                file_path = None
                if filename in ("memory.md", "memory"):
                    file_path = ai.get_memory_file_path(user_id)
                    found = file_path is not None
                    filename = "memory.md"
                else:
                    try:
                        file_path = ai.get_full_path(user_id, chat_id_folder, f"files/{filename}")
                        if os.path.exists(file_path):
                            found = True
                        else:
                            file_path = ai.get_full_path(user_id, chat_id_folder, filename)
                            if os.path.exists(file_path):
                                found = True
                            else:
                                for root, dirs, files in os.walk(ai._get_chat_dir(user_id, chat_id_folder)):
                                    if filename in files:
                                        file_path = os.path.join(root, filename)
                                        found = True
                                        break
                    except ValueError:
                        found = False
                    if not found:
                        try:
                            file_path = ai.resolve_user_upload(user_id, chat_id_folder, filename)
                            found = os.path.isfile(file_path)
                        except (ValueError, OSError):
                            found = False
                if found and file_path:
                    await bot.send_document(chat_id, FSInputFile(file_path, filename=filename))
                    clean_reply = clean_reply.replace(match.group(0), f"✅ Файл {filename} отправлен.", 1)
                else:
                    clean_reply = clean_reply.replace(match.group(0), f"❌ Файл {filename} не найден.", 1)

        # AUDIO_TO_SEND — озвучка / аудио из files/ (send_voice)
        if "AUDIO_TO_SEND:" in clean_reply:
            for match in re.finditer(r"AUDIO_TO_SEND:(\S+)", clean_reply):
                filename = match.group(1).strip()
                chat_id_folder = origin_ai_chat_id
                file_path = None
                try:
                    file_path = ai.get_full_path(user_id, chat_id_folder, f"files/{filename}")
                    if not os.path.exists(file_path):
                        file_path = ai.resolve_user_upload(user_id, chat_id_folder, filename)
                except Exception:
                    file_path = None
                if file_path and os.path.exists(file_path):
                    try:
                        await bot.send_voice(
                            chat_id,
                            FSInputFile(file_path, filename=filename),
                            caption=f"🎙 {filename}",
                        )
                    except Exception:
                        await bot.send_audio(
                            chat_id,
                            FSInputFile(file_path, filename=filename),
                            caption=f"🎙 {filename}",
                        )
                    clean_reply = clean_reply.replace(match.group(0), f"✅ Аудио {filename} отправлено.")
                else:
                    clean_reply = clean_reply.replace(match.group(0), f"❌ Аудио {filename} не найдено.")

        # Дожидаемся watcher: если название появилось во время генерации,
        # оно уже успело попасть в карточку «Ход работы». Если название модели
        # пришло позже основного ответа — применяем его перед финальной отправкой.
        await chat_title_progress_task
        chat_title = working_chat_title

        last_bot_response[user_id] = clean_reply
        copy_payload = clean_reply if len(clean_reply) <= 256 else None
        response_model_key = current_model_key
        response_model_is_favorite = await db.is_model_favorite(
            user_id, response_model_key
        )
        answer_id = await asyncio.to_thread(
            ai.tag_latest_assistant_answer,
            user_id,
            origin_ai_chat_id,
        )
        rating_allowed = rating_request_allowed(run_prompt, rating_state, clean_reply)
        rating_requested = False
        if rating_allowed:
            rating_requested = await ai.decide_rating_request(
                run_prompt,
                clean_reply,
                response_model_key,
                rating_context,
            )
        rating_required = bool(rating_requested and rating_allowed)
        log.info(
            "Rating decision(hidden): model=%s requested=%s allowed=%s required=%s premium=%s",
            response_model_key,
            rating_requested,
            rating_allowed,
            rating_required,
            rating_is_premium,
        )
        rating_token = None
        if rating_allowed:
            try:
                rating_token = await asyncio.to_thread(
                    model_ratings.create_response,
                    user_id,
                    chat_id,
                    origin_ai_chat_id,
                    answer_id,
                    response_model_key,
                    rating_required,
                )
            except Exception:
                rating_required = False
                log.exception("Could not create model rating record")
        kb = answer_keyboard(
            copy_payload,
            user_id=user_id,
            model_key=response_model_key,
            model_is_favorite=response_model_is_favorite,
            answer_chat_id=origin_ai_chat_id,
            answer_id=answer_id,
            rating_token=rating_token,
        )

        clean_html = markdown_to_telegram_html(clean_reply)

        # Все промежуточные действия и мысли показываем цитатой,
        # финальный ответ остаётся обычным текстом ниже.
        timeline_block = ""
        if actions_log:
            body = _format_interleaved_timeline(actions_log)
            timeline_block = (
                f"<blockquote expandable>🛠 <b>Ход работы</b>\n"
                f"{body}</blockquote>\n\n"
            )

        # Fallback for models putting visible thinking in <think> tags:
        # keep it in the SAME timeline rather than a separate column.
        if False and thinking_part and not any(
            kind=="reasoning" and thinking_part.strip() in value
            for kind,value in actions_log
        ):
            append_agent_reasoning(actions_log,thinking_part[:3500])
            body=_format_interleaved_timeline(actions_log)
            timeline_block=(
                f"<blockquote expandable>🛠 <b>Ход работы</b>\n"
                f"{body}</blockquote>\n\n"
            )

        current_short = (
            current_model_key.split(":", 1)[1]
            if ":" in current_model_key else current_model_key
        )
        badge = get_model_badge(current_model_key)
        params = get_param_text(current_model_key)
        model_header = (
            f"{badge} <b>Модель:</b> <code>{html.escape(current_short)}</code>"
            + (f" ({html.escape(params)})" if params else "")
            + "\n"
            f"💬 <b>Чат:</b> {html.escape(chat_title)}\n"
            f"━━━━━━━━━━━━━━━\n"
        )
        full_msg = model_header + timeline_block + clean_html

        # Превращаем статус в финальный ответ: не оставляем промежуточный текст
        # отдельным сообщением, если Telegram не дал удалить/обновить статус.
        full_msg = _fix_unmatched_tags(full_msg)
        last_answer_snapshot[user_id] = {
            "text": full_msg[:4000],
            "copy_payload": copy_payload,
            "model_key": response_model_key,
            "answer_chat_id": origin_ai_chat_id,
            "answer_id": answer_id,
            "rating_token": rating_token,
            "rating_required": rating_required,
        }
        chunks = split_text(full_msg, MAX_MESSAGE_CHUNK)
        for i, chunk in enumerate(chunks):
            is_last = i == len(chunks) - 1
            markup = kb if is_last else None
            if i == 0:
                try:
                    sent = await bot.edit_message_text(
                        chat_id=chat_id,
                        message_id=thinking_msg.message_id,
                        text=chunk,
                        reply_markup=markup,
                        parse_mode="HTML",
                    )
                except Exception as edit_err:
                    if "message is not modified" in str(edit_err).lower():
                        try:
                            await bot.edit_message_reply_markup(
                                chat_id=chat_id,
                                message_id=thinking_msg.message_id,
                                reply_markup=markup,
                            )
                            sent = thinking_msg
                        except Exception:
                            sent = thinking_msg
                    else:
                        try:
                            # Если HTML не подошёл, пробуем заменить тот же статус plain-текстом.
                            sent = await bot.edit_message_text(
                                chat_id=chat_id,
                                message_id=thinking_msg.message_id,
                                text=strip_all_html(chunk)[:4090],
                                reply_markup=markup,
                            )
                        except Exception:
                            try:
                                await thinking_msg.delete()
                            except Exception:
                                pass
                            try:
                                sent = await bot.send_message(
                                    chat_id=chat_id, text=chunk,
                                    reply_markup=markup, parse_mode="HTML",
                                )
                            except Exception as send_err:
                                log.warning("HTML parse fail, fallback plain: %s", send_err)
                                sent = await bot.send_message(
                                    chat_id=chat_id, text=strip_all_html(chunk)[:4090],
                                    reply_markup=markup,
                                )
            else:
                try:
                    sent = await bot.send_message(
                        chat_id=chat_id, text=chunk,
                        reply_markup=markup, parse_mode="HTML",
                    )
                except Exception as send_err:
                    log.warning("HTML parse fail, fallback plain: %s", send_err)
                    sent = await bot.send_message(
                        chat_id=chat_id, text=strip_all_html(chunk)[:4090],
                        reply_markup=markup,
                    )
            if is_last:
                await safe_react(chat_id, sent.message_id, "👍")
                if rating_token:
                    try:
                        await asyncio.to_thread(
                            model_ratings.attach_message,
                            rating_token,
                            user_id,
                            sent.message_id,
                        )
                    except Exception:
                        log.exception("Could not attach Telegram message to rating")
                if rating_required and rating_token:
                    try:
                        await bot.send_message(
                            chat_id,
                            rating_request_text(
                                required=True,
                                is_premium=rating_is_premium,
                            ),
                            parse_mode="HTML",
                            reply_markup=rating_score_keyboard(
                                rating_token,
                                is_premium=rating_is_premium,
                                required=True,
                            ),
                        )
                    except Exception:
                        log.exception("Could not send required rating prompt")

        log.info("✅ Ответ пользователю %s отправлен (actions=%d)", user_id, len(actions_log))

    except asyncio.CancelledError:
        run = active_agent_runs.get(user_id)
        cancel_reason = str(run.get("cancel_reason") or "") if run else ""
        buffered_count = len(run.get("followups") or []) if run else 0
        if run:
            run.get("followups", []).clear()
            run["cancel_payload"] = []
        if cancel_reason == "watchdog-timeout":
            log.warning(
                "Generation cancelled by stale-run watchdog (user=%s message=%s)",
                user_id,
                thinking_msg.message_id,
            )
        else:
            log.info(
                "Generation stopped by user %s, message %s",
                user_id,
                thinking_msg.message_id,
            )
        try:
            # Не затираем уже показанный ход работы при ручной остановке.
            # Пользователь должен видеть, что модель успела сделать до Stop.
            body = _format_interleaved_timeline(actions_log)
            timeline_block = ""
            if body:
                timeline_block = (
                    f"<blockquote expandable>🛠 <b>Ход работы</b>\n"
                    f"{body}</blockquote>\n\n"
                )
            extra = (
                f"\n<i>Буфер досылов очищен: {buffered_count}.</i>"
                if buffered_count else ""
            )
            stopped_text = _fix_unmatched_tags(
                model_header
                + timeline_block
                + (
                    "⚠️ <b>Ответ завис и был остановлен.</b>\nПовтори запрос."
                    if cancel_reason == "watchdog-timeout"
                    else "⏹ <b>Генерация остановлена пользователем.</b>"
                )
                + extra
            )
            await bot.edit_message_text(
                chat_id=chat_id,
                message_id=thinking_msg.message_id,
                text=stopped_text[:4090],
                parse_mode="HTML",
                reply_markup=None,
            )
        except Exception:
            log.warning("Cannot update cancelled generation card for %s",user_id)
        return
    except ai.ProviderRateLimitError as e:
        try:
            await thinking_msg.delete()
        except Exception:
            pass
        # ProviderRateLimitError поднимается и для фатальных ошибок (403/401/404/5xx
        # после исчерпания фолбэков), а не только для 429. Фатальное — отвечаем один
        # раз и НЕ возвращаем в очередь, иначе горячий цикл «ошибка → очередь →
        # мгновенный повтор» (видно как мигание сообщений отправка/удаление).
        cause = e.__cause__
        transient = True
        if cause is not None:
            transient = bool(
                ai.is_rate_limit_error(cause)
                or getattr(cause, "status_code", None) == 429
            )
        if not transient or attempts >= 2:
            if not transient:
                log.warning("Фатальная ошибка провайдера, без повтора: %s", e.user_message)
                final_text = e.user_message
            else:
                log.warning("Повторы 429 исчерпаны, дальше без очереди: %s", e.user_message)
                final_text = (
                    f"{e.user_message}\n\n"
                    "⏳ Лимиты провайдеров не отпускают, попробуй чуть позже."
                )
            if status_message:
                try:
                    await status_message.edit_text(final_text)
                except Exception:
                    try:
                        await bot.send_message(chat_id, final_text)
                    except Exception:
                        pass
            else:
                try:
                    await bot.send_message(chat_id, final_text)
                except Exception:
                    pass
            return
        wait_s = int(cooldown_seconds)
        log.warning("429 / rate limit: %s", e.user_message)
        # вернуть в очередь и дать паузу перед следующей попыткой
        status_msg = status_message
        if status_msg is None:
            try:
                status_msg = await bot.send_message(
                    chat_id,
                    f"{e.user_message}\n\n"
                    f"⏳ Поставлю в очередь (пауза ~{wait_s} сек)…",
                    reply_markup=queue_keyboard(),
                )
            except Exception:
                status_msg = None
        else:
            try:
                await status_msg.edit_text(
                    f"{e.user_message}\n\n"
                    f"⏳ В очереди, повтор через ~{wait_s} сек.",
                    reply_markup=queue_keyboard(),
                )
            except Exception:
                pass
        retry_followups = _take_active_followups()
        retry_prompt = (
            _followup_prompt(retry_followups, original_prompt=run_prompt, interrupted=True)
            if retry_followups else run_prompt
        )
        pending_requests.appendleft(
            QueuedRequest(
                user_id, chat_id, retry_prompt, status_msg, time.time(),
                run_attachment or _followup_attachment(retry_followups),
                origin_ai_chat_id,
                attempts + 1,
            )
        )
        user_status[user_id] = "queued"
        cooldown_until = time.time() + cooldown_seconds
        cooldown_seconds = min(cooldown_seconds * 2, 300)
        return
    except Exception as e:
        try:
            await thinking_msg.delete()
        except Exception:
            pass

        # openai иногда кидает без нашего обёртки
        if ai.is_rate_limit_error(e) or getattr(e, "status_code", None) == 429:
            msg = ai.format_api_error(e, model_key=current_model_key)
            if attempts >= 2:
                log.warning("Повторы raw-429 исчерпаны, дальше без очереди: %s", e)
                final_text = (
                    f"{msg}\n\n⏳ Лимиты провайдеров не отпускают, попробуй чуть позже."
                )
                if status_message:
                    try:
                        await status_message.edit_text(final_text)
                    except Exception:
                        try:
                            await bot.send_message(chat_id, final_text)
                        except Exception:
                            pass
                else:
                    try:
                        await bot.send_message(chat_id, final_text)
                    except Exception:
                        pass
                return
            wait_s = int(cooldown_seconds)
            log.warning("429 (raw): %s", e)
            status_msg = status_message
            if status_msg is None:
                try:
                    status_msg = await bot.send_message(
                        chat_id,
                        f"{msg}\n\n⏳ В очереди, повтор через ~{wait_s} сек.",
                        reply_markup=queue_keyboard(),
                    )
                except Exception:
                    status_msg = None
            else:
                try:
                    await status_msg.edit_text(
                        f"{msg}\n\n⏳ В очереди, повтор через ~{wait_s} сек.",
                        reply_markup=queue_keyboard(),
                    )
                except Exception:
                    pass
            retry_followups = _take_active_followups()
            retry_prompt = (
                _followup_prompt(retry_followups, original_prompt=run_prompt, interrupted=True)
                if retry_followups else run_prompt
            )
            pending_requests.appendleft(
                QueuedRequest(
                    user_id, chat_id, retry_prompt, status_msg, time.time(),
                    run_attachment or _followup_attachment(retry_followups),
                    origin_ai_chat_id,
                    attempts + 1,
                )
            )
            user_status[user_id] = "queued"
            cooldown_until = time.time() + cooldown_seconds
            cooldown_seconds = min(cooldown_seconds * 2, 300)
            return

        log.error("Ошибка API: %s", e)
        friendly = ai.format_api_error(e, model_key=current_model_key)
        try:
            await bot.send_message(chat_id, friendly)
        except Exception:
            await bot.send_message(chat_id, f"❌ Ошибка: {str(e)[:280]}")
        if str(user_id) != str(ADMIN_USER_ID):
            try:
                await bot.send_message(
                    ADMIN_USER_ID,
                    f"🚨 Ошибка у <code>{user_id}</code> "
                    f"(model={current_model_key}):\n<code>{html.escape(str(e)[:500])}</code>",
                    parse_mode="HTML",
                )
            except Exception:
                pass
    finally:
        title_tasks = [
            task for task in (chat_title_progress_task, chat_title_task)
            if task is not None and not task.done()
        ]
        for task in title_tasks:
            task.cancel()
        if title_tasks:
            await asyncio.gather(*title_tasks, return_exceptions=True)
        typing_task.cancel()
        if choice_wait_token:
            pending_waiter = interactive_choice_waiters.pop(choice_wait_token, None)
            if pending_waiter is not None and not pending_waiter.done():
                pending_waiter.cancel()
        run=active_agent_runs.get(user_id)
        if run and run.get("message_id")==thinking_msg.message_id:
            active_agent_runs.pop(user_id,None)
        # Keep the owner reserved while follow-ups are waiting, so a new
        # incoming message cannot slip into a parallel turn between queue items.
        if user_status.get(user_id) != "queued":
            web_search_once.discard(user_id)
            if any(req.user_id == user_id for req in pending_requests):
                user_status[user_id] = "queued"
            else:
                user_status.pop(user_id, None)


async def update_queue_statuses():
    for req in list(pending_requests):
        pos = queue_position(req.user_id)
        if pos is None or not req.status_message:
            continue
        new_text = f"⏳ <b>Очередь</b>\nПозиция: #{pos}\n⏱ Ожидание: {format_wait_estimate()}"
        try:
            if req.status_message.text != new_text:
                await req.status_message.edit_text(new_text, reply_markup=queue_keyboard(), parse_mode="HTML")
        except Exception:
            pass


async def _resume_rating_blocked_prompts(user_id: int) -> None:
    queue = rating_blocked_prompts.pop(int(user_id), None)
    if not queue:
        return
    while queue:
        req = queue.popleft()
        try:
            await submit_prompt(
                req.user_id,
                req.chat_id,
                req.prompt,
                notify_message=None,
                attachment_name=req.attachment_name,
                ai_chat_id_override=req.ai_chat_id,
            )
        except Exception:
            log.exception(
                "Could not resume prompt after rating (user=%s chat=%s)",
                req.user_id,
                req.chat_id,
            )


async def submit_prompt(
    user_id: int,
    chat_id: int,
    prompt: str,
    notify_message: Message | None,
    *,
    attachment_name: str = "",
    ai_chat_id_override: str = "",
):
    run = active_agent_runs.get(user_id)
    if run and run.get("kind") == "prompt":
        task = run.get("task")
        if _active_run_is_stale(run):
            run["cancel_reason"] = "watchdog-timeout"
            run["accept_followups"] = False
            pending_requests.append(
                QueuedRequest(
                    user_id,
                    chat_id,
                    prompt,
                    None,
                    time.time(),
                    attachment_name,
                    str(ai_chat_id_override or ai.get_current_chat(user_id)),
                )
            )
            if task is not None and not task.done():
                task.cancel()
            log.warning(
                "New prompt detected stale run; cancelled old turn and queued "
                "the new one (user=%s)",
                user_id,
            )
            return
        # Accept follow-ups until the whole answer card is finalized, not merely
        # until the provider task flips to done(). This closes the tiny window
        # between provider completion and Telegram final rendering.
        if run.get("accept_followups", True) and not run.get("cancel_reason"):
            item = BufferedFollowup(prompt, attachment_name=attachment_name)
            run.setdefault("followups", []).append(item)
            refresh = run.get("refresh")
            if refresh:
                try:
                    await refresh(force=True)
                except Exception:
                    pass
            log.info(
                "[ДОСЫЛ-БУФЕР] user=%s count=%d: %.80s",
                user_id, len(run.get("followups") or []), prompt,
            )
            return
        # A 'send now' cancellation can be between task.cancel() and the
        # process_request CancelledError handler. Keep very-late messages in
        # that same payload instead of losing/serializing them separately.
        if run.get("cancel_reason") == "send-followups":
            run.setdefault("cancel_payload", []).append(
                BufferedFollowup(prompt, attachment_name=attachment_name)
            )
            return

    pending_rating = await asyncio.to_thread(
        model_ratings.pending_required, user_id
    )
    if pending_rating:
        premium = await db.is_subscribed(user_id)
        blocked_queue = rating_blocked_prompts.setdefault(user_id, deque())
        blocked_queue.append(
            QueuedRequest(
                user_id,
                chat_id,
                prompt,
                None,
                time.time(),
                attachment_name,
                str(ai_chat_id_override or ai.get_current_chat(user_id)),
            )
        )
        try:
            await bot.send_message(
                chat_id,
                rating_request_text(
                    required=True,
                    is_premium=premium,
                )
                + "\n\n💬 <i>Твой новый запрос сохранён и отправится автоматически после оценки.</i>",
                parse_mode="HTML",
                reply_markup=rating_score_keyboard(
                    str(pending_rating["token"]),
                    is_premium=premium,
                    required=True,
                ),
            )
        except Exception:
            log.exception("Could not show pending required rating")
        return

    if is_user_busy(user_id):
        # Очередь отключена — не ставим в очередь, просто просим подождать
        try:
            await bot.send_message(chat_id, "🤚 Уже обрабатываю твой предыдущий запрос — дождись ответа.", parse_mode="HTML")
        except Exception:
            pass
        return

    if can_dispatch_now():
        await process_request(
            user_id, chat_id, prompt, status_message=None,
            attachment_name=attachment_name,
            ai_chat_id_override=str(ai_chat_id_override or ai.get_current_chat(user_id)),
        )
    else:
        # Очередь отключена — диспатчим сразу без ожидания
        await process_request(
            user_id, chat_id, prompt, status_message=None,
            attachment_name=attachment_name,
            ai_chat_id_override=str(ai_chat_id_override or ai.get_current_chat(user_id)),
        )


# ============ ФОНОВЫЕ ЗАДАЧИ ============

async def remember_delivered_reminder(task: dict, delivered_text: str):
    """Persist the reminder event in the exact AI chat it belongs to."""
    user_id = int(task["user_id"])
    ai_chat_id = str(task["ai_chat_id"])
    title = str(task.get("title") or "Напоминание").strip()
    text = str(delivered_text or "").strip()
    if not text:
        return
    event_text = (
        f"📌 Сработало напоминание «{title}».\n"
        f"{text}"
    )
    event_id = f"reminder:{task['id']}:{int(task['run_at'])}"
    await asyncio.to_thread(
        ai.append_history_message,
        user_id,
        ai_chat_id,
        "assistant",
        event_text,
        max_history_turns=MAX_HISTORY_TURNS,
        external_event_id=event_id,
    )


async def execute_plain_text_reminder(task: dict):
    """Deliver literal user-approved text, without any model/API invocation.

    The reminder is marked completed only after Telegram accepts the message.
    Existing retry handling applies if delivery fails.
    """
    chat_id = int(task["telegram_chat_id"])
    body = str(task.get("instruction") or "").strip()
    if not body:
        raise ValueError("У текстового напоминания отсутствует сообщение.")
    # No parse_mode: angle brackets, markup and links stay literal.
    # The database enforces max 3000 characters, below Telegram's 4096 limit.
    await bot.send_message(chat_id, body)
    try:
        await remember_delivered_reminder(task, body)
    except Exception:
        log.exception("Не удалось сохранить текстовое напоминание %s в контекст", task["id"])
    await reminders.complete(task["id"])


def scheduled_side_effect_allowlist(instruction: str) -> set[str]:
    """Server-side allowlist derived only from the user's saved task text."""
    text = " ".join(str(instruction or "").casefold().split())
    allowed: set[str] = set()

    if re.search(
        r"(?:созда|сдела|сохрани|запиши|подготов|сгенерир).{0,50}"
        r"(?:файл|документ|отч[её]т|код|html|json|csv|md|markdown)",
        text,
    ):
        allowed.add("write_file")
    if re.search(
        r"(?:измени|редактир|обнови|доработ).{0,50}"
        r"(?:файл|документ|отч[её]т|код|html|json|csv|md|markdown)",
        text,
    ):
        # Some models rewrite the whole file instead of issuing a surgical edit,
        # so an explicitly confirmed edit may use either edit_file or write_file.
        allowed.update({"edit_file", "write_file"})
    if re.search(r"(?:скопир|копир).{0,45}(?:файл|документ)", text):
        allowed.update({"copy_file", "copy_chat_file", "copy_from_shared"})
    if re.search(r"(?:запомни|сохрани.{0,20}памят|обнови.{0,20}памят)", text):
        allowed.add("write_memory")
    if re.search(
        r"(?:созда|сдела|сгенерир|нарису).{0,45}"
        r"(?:изображ|картин|фото|баннер|обложк|постер|инфограф)",
        text,
    ):
        allowed.add("generate_image")
        allowed.update({"generate_photo", "generate_photo_pro"})
    if re.search(
        r"(?:созда|сдела|сгенерир|собер).{0,45}"
        r"(?:видео|ролик|анимац|mp4|сторис|reels|shorts)",
        text,
    ):
        allowed.add("generate_video")
    if re.search(r"(?:озвуч|сделай.{0,20}(?:аудио|голос))", text):
        allowed.add("create_speech")
    if re.search(r"(?:извлек|достань|вытащи).{0,30}(?:аудио|звук|аудиодорож)", text):
        allowed.add("extract_audio")
    if re.search(r"(?:общее хранилище|shared).{0,50}(?:сохрани|опубликуй|скопир)", text):
        allowed.update({"publish_to_shared", "copy_from_shared"})
    if re.search(r"(?:git|коммит|commit)", text):
        allowed.add("git_commit")
    if re.search(r"(?:восстанови|откати).{0,40}(?:верси|git|файл)", text):
        allowed.add("git_restore")

    return allowed


async def execute_scheduled_reminder(task: dict):
    user_id = int(task["user_id"])
    telegram_chat_id = int(task["telegram_chat_id"])
    user_status[user_id] = "processing"
    typing_task = None
    status_message = None
    actions_log: list[tuple[str,str]] = []
    preview_answer = ""
    last_status_edit = 0.0

    try:
        status_message = await bot.send_message(
            telegram_chat_id,
            f"📌 <b>Задание</b>\n<b>{html.escape(task['title'])}</b>\nЗапускаю…",
            parse_mode="HTML",
            reply_markup=agent_stop_keyboard(),
        )
        typing_task = asyncio.create_task(keep_typing(telegram_chat_id))

        async def _render_scheduled_progress(*,force=False):
            nonlocal last_status_edit
            now=time.monotonic()
            if not force and now-last_status_edit<0.85:
                return
            last_status_edit=now
            timeline=format_agent_timeline(actions_log[-22:])
            progress=(
                f"📌 <b>Задание</b>\n<b>{html.escape(task['title'])}</b>\n"
                "🛠 <b>Ход работы</b>\n"
                f"{timeline or '⏳ Ожидаю модель…'}"
            )
            try:
                await bot.edit_message_text(
                    chat_id=telegram_chat_id,
                    message_id=status_message.message_id,
                    text=_fix_unmatched_tags(progress[:3990]),
                    parse_mode="HTML",
                    reply_markup=agent_stop_keyboard(),
                )
            except Exception:
                pass

        async def on_action(status: str,kind: str="action"):
            nonlocal preview_answer
            kind=kind if kind in ("thought","action","done") else "action"
            if kind=="action":
                preview_answer=""
            if kind=="done" and actions_log and actions_log[-1][0]=="action":
                actions_log[-1]=(kind,status)
            else:
                actions_log.append((kind,status))
            if len(actions_log)>85:
                del actions_log[:-65]
            await _render_scheduled_progress(force=True)

        async def on_reasoning(chunk: str):
            append_agent_reasoning(actions_log,str(chunk or ""))
            await _render_scheduled_progress()

        async def on_answer_chunk(text: str):
            # Do not mirror the future final answer into «Ход работы».
            return

        prompt = (
            "[Подтверждённое пользователем одноразовое задание. Наступил выбранный срок.]\n"
            f"Название: {task['title']}\n"
            f"Инструкция: {task['instruction']}\n\n"
            "Используй историю именно этого чата как контекст. Выполни задачу сейчас; "
            "если для неё нужны инструменты, сам реши и вызови их. В финальном сообщении "
            "не добавляй отдельный заголовок — бот сам поставит «📌 Задание». "
            "Для физического действия честно напомни пользователю и не утверждай, "
            "что ты выполнил его в реальном мире."
        )
        model_holder = [task["model_key"]]
        generation=asyncio.create_task(ai.ask_ai(
            user_id,
            prompt,
            task["model_key"],
            SYSTEM_PROMPT,
            MAX_HISTORY_TURNS,
            custom_prompt=await db.get_custom_prompt(user_id),
            on_action=on_action,
            on_reasoning=on_reasoning,
            on_text_chunk=on_answer_chunk,
            model_holder=model_holder,
            chat_id_override=task["ai_chat_id"],
            scheduled_task=True,
            scheduled_allowed_side_effects=scheduled_side_effect_allowlist(
                task.get("instruction") or ""
            ),
            allow_model_fallback=await db.get_fallback_on_rate_limit(user_id),
            allow_rate_limit_fallback=await db.get_fallback_on_rate_limit(user_id),
            timezone_name=task.get("timezone_name") or reminders.DEFAULT_TIMEZONE,
        ))
        active_agent_runs[user_id]={
            "task":generation,
            "chat_id":telegram_chat_id,
            "message_id":status_message.message_id,
            "reminder_id":task["id"],
        }
        reply = await generation
        if reply.startswith(("⚠️ Модель ", "🔒 Модель ", "❌ Провайдер ")):
            raise RuntimeError(reply)
        if model_holder and model_holder[0] and model_holder[0] != task["model_key"]:
            log.info(
                "Задание %s переключило недоступную модель %s → %s",
                task["id"], task["model_key"], model_holder[0],
            )

        reply = str(reply or "")
        for match in list(re.finditer(r"IMAGE_TO_SEND:(\S+)", reply)):
            filename = match.group(1).strip()
            file_path = None
            try:
                file_path = ai.get_full_path(
                    user_id, task["ai_chat_id"], f"files/{filename}"
                )
                if not os.path.exists(file_path):
                    file_path = ai.resolve_user_upload(
                        user_id, task["ai_chat_id"], filename
                    )
            except Exception:
                file_path = None
            if file_path and os.path.isfile(file_path):
                try:
                    await bot.send_photo(
                        telegram_chat_id,
                        FSInputFile(file_path, filename=filename),
                    )
                except Exception:
                    await bot.send_document(
                        telegram_chat_id,
                        FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                    )
                reply = reply.replace(
                    match.group(0), f"✅ Изображение {filename} отправлено.", 1
                )
            else:
                reply = reply.replace(
                    match.group(0), f"❌ Изображение {filename} не найдено.", 1
                )

        for match in list(re.finditer(r"VIDEO_TO_SEND:(\S+)", reply)):
            filename = match.group(1).strip()
            file_path = None
            try:
                file_path = ai.get_full_path(
                    user_id, task["ai_chat_id"], f"files/{filename}"
                )
                if not os.path.exists(file_path):
                    file_path = ai.resolve_user_upload(
                        user_id, task["ai_chat_id"], filename
                    )
            except Exception:
                file_path = None
            if file_path and os.path.isfile(file_path):
                try:
                    await bot.send_video(
                        telegram_chat_id,
                        FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                        supports_streaming=True,
                    )
                except Exception:
                    await bot.send_document(
                        telegram_chat_id,
                        FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                    )
                reply = reply.replace(
                    match.group(0), f"✅ Видео {filename} отправлено.", 1
                )
            else:
                reply = reply.replace(
                    match.group(0), f"❌ Видео {filename} не найдено.", 1
                )

        for match in list(re.finditer(r"FILE_TO_SEND:(\S+)", reply)):
            filename = match.group(1).strip()
            file_path = None
            try:
                if filename in ("memory.md", "memory"):
                    file_path = ai.get_memory_file_path(user_id)
                    filename = "memory.md"
                else:
                    file_path = ai.get_full_path(user_id, task["ai_chat_id"], f"files/{filename}")
                    if not os.path.exists(file_path):
                        file_path = ai.resolve_user_upload(user_id, task["ai_chat_id"], filename)
                if file_path and os.path.exists(file_path):
                    await bot.send_document(
                        telegram_chat_id, FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                    )
                    reply = reply.replace(match.group(0), f"✅ Файл {filename} отправлен.", 1)
                else:
                    reply = reply.replace(match.group(0), f"❌ Файл {filename} не найден.", 1)
            except Exception:
                log.exception("Не удалось отправить файл задания %s", filename)
                reply = reply.replace(match.group(0), f"❌ Не удалось отправить файл {filename}.", 1)

        for match in list(re.finditer(r"AUDIO_TO_SEND:(\S+)", reply)):
            filename = match.group(1).strip()
            file_path = None
            try:
                file_path = ai.get_full_path(user_id, task["ai_chat_id"], f"files/{filename}")
                if not os.path.exists(file_path):
                    file_path = ai.resolve_user_upload(user_id, task["ai_chat_id"], filename)
            except Exception:
                file_path = None
            if file_path and os.path.exists(file_path):
                try:
                    await bot.send_voice(
                        telegram_chat_id, FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                    )
                except Exception:
                    await bot.send_audio(
                        telegram_chat_id, FSInputFile(file_path, filename=filename),
                        caption=f"📌 Задание · {filename}",
                    )
                reply = reply.replace(match.group(0), f"✅ Аудио {filename} отправлено.", 1)
            else:
                reply = reply.replace(match.group(0), f"❌ Аудио {filename} не найдено.", 1)

        # The same chronological events are shown during streaming and in
        # the final expandable agent block: no separate reasoning section.
        known_reasoning,reply=ai.split_thinking(reply)
        if known_reasoning and not any(
            kind=="reasoning" and known_reasoning.strip() in value
            for kind,value in actions_log
        ):
            append_agent_reasoning(actions_log,known_reasoning[:3500])
        chronology=format_agent_timeline(actions_log[-35:])
        quoted_timeline=(
            "<blockquote expandable>🛠 <b>Ход работы</b>\n"
            f"{chronology}</blockquote>\n\n"
        ) if chronology else ""
        answer_html=markdown_to_telegram_html(reply or "Задание выполнено.")
        final_text=_fix_unmatched_tags(
            f"📌 <b>Задание</b>\n<b>{html.escape(task['title'])}</b>\n\n"
            +quoted_timeline+answer_html
        )
        scheduled_rating_token = None
        try:
            scheduled_model_key = (
                model_holder[0] if model_holder else task["model_key"]
            )
            scheduled_rating_token = await asyncio.to_thread(
                model_ratings.create_response,
                user_id,
                telegram_chat_id,
                task["ai_chat_id"],
                f"reminder:{task['id']}:{int(task['run_at'])}",
                scheduled_model_key,
                False,
            )
        except Exception:
            log.exception("Could not create scheduled model rating record")

        chunks = split_text(final_text, MAX_MESSAGE_CHUNK)
        final_sent_message_id = None
        for index, chunk in enumerate(chunks):
            is_last = index == len(chunks) - 1
            rating_markup = (
                InlineKeyboardMarkup(inline_keyboard=[[
                    InlineKeyboardButton(
                        text="⭐ Оценить",
                        callback_data=f"rating:open:{scheduled_rating_token}",
                    )
                ]])
                if is_last and scheduled_rating_token else None
            )
            if index == 0:
                try:
                    sent = await bot.edit_message_text(
                        chat_id=telegram_chat_id,
                        message_id=status_message.message_id,
                        text=chunk,
                        parse_mode="HTML",
                        reply_markup=rating_markup,
                    )
                    if is_last:
                        final_sent_message_id = sent.message_id
                    continue
                except Exception:
                    pass
            sent = await bot.send_message(
                telegram_chat_id,
                chunk,
                parse_mode="HTML",
                reply_markup=rating_markup,
            )
            if is_last:
                final_sent_message_id = sent.message_id
        if scheduled_rating_token and final_sent_message_id:
            try:
                await asyncio.to_thread(
                    model_ratings.attach_message,
                    scheduled_rating_token,
                    user_id,
                    final_sent_message_id,
                )
            except Exception:
                log.exception("Could not attach scheduled rating message")
        try:
            await remember_delivered_reminder(task, reply or "Задание выполнено.")
        except Exception:
            log.exception("Не удалось сохранить AI-напоминание %s в контекст", task["id"])
        await reminders.complete(task["id"])
    except asyncio.CancelledError:
        # Only the current firing is skipped by the authenticated owner.
        # It must NOT enter the regular retry queue or restart the model.
        log.info("Scheduled AI reminder %s stopped by owner %s",task["id"],user_id)
        updated=await reminders.skip_running(task["id"],user_id)
        suffix=(
            "Будущие повторения сохранены."
            if (updated.get("task") or {}).get("status")=="scheduled"
            else "Это было последнее срабатывание."
        )
        try:
            if status_message:
                await bot.edit_message_text(
                    chat_id=telegram_chat_id,
                    message_id=status_message.message_id,
                    text="⏹ <b>Выполнение напоминания остановлено.</b>\n"+suffix,
                    parse_mode="HTML",
                    reply_markup=None,
                )
        except Exception:
            pass
        return
    except Exception as error:
        log.exception("Ошибка выполнения задания %s", task["id"])
        retry_status = await reminders.retry(task["id"], str(error))
        notice = (
            "❌ Задание не удалось выполнить после нескольких попыток."
            if retry_status == "failed"
            else "⚠️ Не получилось выполнить задание сейчас. Я попробую ещё раз позже."
        )
        try:
            if status_message:
                await status_message.edit_text(notice)
            else:
                await bot.send_message(telegram_chat_id, notice)
        except Exception:
            pass
    finally:
        if typing_task:
            typing_task.cancel()
        run=active_agent_runs.get(user_id)
        if (run and status_message
                and run.get("message_id")==status_message.message_id):
            active_agent_runs.pop(user_id,None)
        if any(req.user_id == user_id for req in pending_requests):
            user_status[user_id] = "queued"
        else:
            user_status.pop(user_id, None)


async def reminders_loop():
    while True:
        try:
            await reminders.expire_pending()
            for candidate in await reminders.due(limit=20):
                user_id = int(candidate["user_id"])
                if candidate.get("execution_mode") == "text":
                    # A simple text reminder must NOT wait for a free LLM slot,
                    # register AI rate consumption or start an agent.
                    task = await reminders.claim(candidate["id"])
                    if not task:
                        continue
                    try:
                        await execute_plain_text_reminder(task)
                    except Exception as exc:
                        log.exception("Не удалось доставить текстовое напоминание %s", task["id"])
                        await reminders.retry(task["id"],str(exc))
                    break
                if is_user_busy(user_id) or not can_dispatch_now():
                    continue
                if len(_reminder_workers)>=MAX_BACKGROUND_REMINDER_WORKERS:
                    continue
                task = await reminders.claim(candidate["id"])
                if not task:
                    continue
                # Re-check the fresh claimed row, not only the due-list snapshot.
                # A card may have been switched to literal text right before firing.
                if task.get("execution_mode") == "text":
                    try:
                        await execute_plain_text_reminder(task)
                    except Exception as exc:
                        log.exception("Не удалось доставить текстовое напоминание %s", task["id"])
                        await reminders.retry(task["id"], str(exc))
                    break
                register_dispatch()
                job=asyncio.create_task(
                    execute_scheduled_reminder(task),
                    name=f"ghogem-reminder-{task['id'][:12]}",
                )
                _reminder_workers.add(job)
                job.add_done_callback(
                    lambda completed: _background_worker_done(
                        _reminder_workers,completed
                    )
                )
                break
        except Exception:
            log.exception("Ошибка фонового цикла заданий")
        await asyncio.sleep(5)


async def reminders_loop_v2():
    """Event-driven scheduler; full task rows stay in SQLite until due."""
    while True:
        try:
            reminder_scheduler_wakeup.clear()
            await reminders.expire_pending()
            nearest = await reminders.next_due()

            if not nearest:
                try:
                    await asyncio.wait_for(
                        reminder_scheduler_wakeup.wait(), timeout=60
                    )
                except asyncio.TimeoutError:
                    pass
                continue

            task_id = str(nearest["task_id"])
            delay = max(0.0, int(nearest["due_at"]) - time.time())
            if delay > 0:
                try:
                    await asyncio.wait_for(
                        reminder_scheduler_wakeup.wait(), timeout=delay
                    )
                    continue
                except asyncio.TimeoutError:
                    pass

            candidate = await reminders.get_task(task_id)
            if not candidate or candidate.get("status") != "scheduled":
                continue
            effective_due = int(candidate.get("retry_at") or candidate["run_at"])
            if effective_due > int(time.time()):
                continue

            user_id = int(candidate["user_id"])
            if candidate.get("execution_mode") == "text":
                task = await reminders.claim(task_id)
                if not task:
                    continue
                try:
                    await execute_plain_text_reminder(task)
                except Exception as exc:
                    log.exception(
                        "Не удалось доставить текстовое напоминание %s",
                        task["id"],
                    )
                    await reminders.retry(task["id"], str(exc))
                continue

            if (
                is_user_busy(user_id)
                or not can_dispatch_now()
                or len(_reminder_workers) >= MAX_BACKGROUND_REMINDER_WORKERS
            ):
                try:
                    await asyncio.wait_for(
                        reminder_scheduler_wakeup.wait(), timeout=1.0
                    )
                except asyncio.TimeoutError:
                    pass
                continue

            task = await reminders.claim(task_id)
            if not task:
                continue
            if task.get("execution_mode") == "text":
                try:
                    await execute_plain_text_reminder(task)
                except Exception as exc:
                    log.exception(
                        "Не удалось доставить текстовое напоминание %s",
                        task["id"],
                    )
                    await reminders.retry(task["id"], str(exc))
                continue

            register_dispatch()
            job = asyncio.create_task(
                execute_scheduled_reminder(task),
                name=f"ghogem-reminder-{task['id'][:12]}",
            )
            _reminder_workers.add(job)
            job.add_done_callback(
                lambda completed: _background_worker_done(
                    _reminder_workers, completed
                )
            )
        except Exception:
            log.exception("Ошибка event-driven планировщика заданий")
            await asyncio.sleep(1)


async def _run_queued_request(req: QueuedRequest):
    try:
        await process_request(
            req.user_id,req.chat_id,req.prompt,req.status_message,
            attachment_name=req.attachment_name,
            ai_chat_id_override=req.ai_chat_id,
            attempts=req.attempts,
        )
    except asyncio.CancelledError:
        raise
    except Exception:
        log.exception(
            "Ошибка очередного запроса пользователя %s",req.user_id
        )
        if user_status.get(req.user_id)=="processing":
            if any(item.user_id == req.user_id for item in pending_requests):
                user_status[req.user_id] = "queued"
            else:
                user_status.pop(req.user_id,None)
    finally:
        await update_queue_statuses()


async def active_agent_watchdog_loop():
    while True:
        now = time.monotonic()
        for uid, run in list(active_agent_runs.items()):
            if not _active_run_is_stale(run, now=now):
                continue
            task = run.get("task")
            if task is None or task.done():
                continue
            idle_for = int(now - float(
                run.get("last_activity_at")
                or run.get("started_at")
                or now
            ))
            run["cancel_reason"] = "watchdog-timeout"
            run["accept_followups"] = False
            log.warning(
                "Stale foreground agent cancelled after %ss without activity "
                "(user=%s chat=%s)",
                idle_for,
                uid,
                run.get("ai_chat_id"),
            )
            task.cancel()
        await asyncio.sleep(ACTIVE_AGENT_WATCHDOG_INTERVAL_SECONDS)


async def process_pending_loop():
    while True:
        if (pending_requests and can_dispatch_now()
                and len(_queue_workers)<MAX_BACKGROUND_QUEUE_WORKERS):
            req = None
            # Keep per-user turns strictly sequential while still allowing
            # other users to use free workers.
            for _ in range(len(pending_requests)):
                candidate = pending_requests.popleft()
                if user_status.get(candidate.user_id) == "processing":
                    pending_requests.append(candidate)
                    continue
                req = candidate
                break
            if req is None:
                await asyncio.sleep(0.35)
                continue
            job=asyncio.create_task(
                _run_queued_request(req),
                name=f"ghogem-queue-{req.user_id}",
            )
            _queue_workers.add(job)
            job.add_done_callback(
                lambda completed: _background_worker_done(
                    _queue_workers,completed
                )
            )
            # Let process_request mark this owner as processing before another
            # queued message for the same owner is considered.
            await asyncio.sleep(0)
        elif pending_requests:
            await asyncio.sleep(1)
        else:
            await asyncio.sleep(0.5)


async def cleanup_loop():
    next_media_cleanup = 0.0
    next_chat_archive_cleanup = 0.0
    while True:
        await asyncio.sleep(5)
        _prune(request_times_minute, WINDOW_SECONDS)
        _prune(request_times_day, DAY_SECONDS)
        now_mono = time.monotonic()
        if now_mono >= next_media_cleanup:
            next_media_cleanup = now_mono + 1800
            try:
                stats = await asyncio.to_thread(ai.cleanup_all_temporary_storage)
                log.info("Temporary media/buffer cleanup: %s", stats)
            except Exception:
                log.exception("Temporary storage cleanup failed")
        if now_mono >= next_chat_archive_cleanup:
            next_chat_archive_cleanup = now_mono + 6 * 3600
            try:
                stats = await asyncio.to_thread(ai.cleanup_all_archived_chats)
                if stats.get("deleted"):
                    log.info("Expired chat archive cleanup: %s", stats)
            except Exception:
                log.exception("Archived chat cleanup failed")


_already_logged_retired: set[str] = set()

async def check_retired_models_loop():
    """Логирует уход модели только один раз, когда она только что стала retired."""
    while True:
        await asyncio.sleep(3600)
        for key in ai.all_retiring_models():
            if ai.is_model_retired(key) and key not in _already_logged_retired:
                log.info("Модель %s официально ушла в отставку", key)
                _already_logged_retired.add(key)


# ============ СТАРТ / ПРИВЕТСТВИЕ ============

def is_greeting(text: str) -> bool:
    t = text.lower().strip()
    return t in {"привет", "здарова", "хай", "hello", "hi", "ку", "здаров", "прив", "здравствуй", "здравствуйте"}


def generate_greeting(user_id: int) -> str:
    return (
        "Здарова! 👋 Я <b>GhoGem</b> — дерзкий ИИ из экосистемы GhostEcos.\n\n"
        "Пиши что угодно, выбирай модель через /model, оформляй Premium если нужно.\n"
        "Готов рвать задачи 🚀"
    )


# ============ ПРИВЯЗКА АККАУНТА GHOSTECOS (сайт ghogem) ============

async def _award_ghostecos_link_bonus(user_id: int, gs_user_id: int) -> str:
    """Выдать одноразовый Premium-бонус за первую GhostID-привязку."""
    try:
        created_at = await asyncio.to_thread(
            sso.get_gs_account_created_at, int(gs_user_id)
        )
        result = await db.claim_ghostecos_link_bonus(
            user_id,
            int(gs_user_id),
            created_at,
            GHOSTECOS_NEW_ACCOUNT_WINDOW_SECONDS,
        )
    except Exception:
        log.exception(
            "Не удалось начислить GhostEcos link bonus (tg=%s gs=%s)",
            user_id, gs_user_id,
        )
        return ""

    if result.get("permanent"):
        return "\n👑 Premium уже активен навсегда — срок не изменён."
    days = int(result.get("days") or 0)
    if days <= 0:
        return ""
    if result.get("is_new_account"):
        return (
            f"\n🎁 <b>+{days} дней Premium</b>: 2 дня за привязку GhostID "
            "+ 3 дня за новый аккаунт GhostEcos."
        )
    return f"\n🎁 <b>+{days} дня Premium</b> за первую привязку GhostID."


# Юзер вошёл в аккаунт GhostEcos на сайте, там же нажал «Привязать Telegram» и
# получил 6-значный код. Погашаем код здесь — после этого чаты/файлы/память
# бота и сайта общие (namespace = telegram id, см. sso.py).

async def _do_link(message: Message, code: str):
    if sso is None:
        await message.answer("Привязка аккаунтов сейчас недоступна.")
        return
    code = (code or "").strip()
    if not code:
        await message.answer(
            "🔗 <b>Привязка аккаунта GhostEcos</b>\n\n"
            "1. Открой сайт GhoGem и войди в аккаунт\n"
            "2. Нажми на себя внизу слева → «Привязать Telegram»\n"
            "3. Пришли мне: <code>/link 123456</code>\n\n"
            "После привязки чаты на сайте и в боте станут общими.",
            parse_mode="HTML",
        )
        return
    try:
        ok, msg, moved = await asyncio.to_thread(sso.link_code_redeem, code, message.from_user.id)
    except Exception:
        log.exception("link_code_redeem failed")
        await message.answer("Не получилось привязать — ошибка на сервере. Попробуй позже.")
        return
    if not ok:
        await message.answer("⚠️ " + html.escape(msg))
        return
    link = await asyncio.to_thread(sso.link_by_tg, message.from_user.id)
    bonus_text = ""
    if link and link.get("gs_user_id"):
        bonus_text = await _award_ghostecos_link_bonus(
            message.from_user.id, int(link["gs_user_id"])
        )
    tail = f"\n📂 Перенесено чатов с сайта: <b>{moved}</b>" if moved else ""
    await message.answer(
        "✅ " + html.escape(msg) + tail + bonus_text +
        "\n\nТеперь чаты, файлы и память у бота и на сайте общие.",
        parse_mode="HTML",
        reply_markup=ghostecos_linked_keyboard(),
    )


@dp.message(Command("ecos"))
async def cmd_ghogem_app(message: Message):
    if message.chat.type != "private":
        await message.answer("Открой GhostEcos из личного чата с ботом.")
        return
    already_linked = False
    if sso is not None:
        try:
            already_linked = bool(await asyncio.to_thread(sso.link_by_tg, message.from_user.id))
        except Exception:
            log.exception("Не удалось проверить GhostEcos-привязку для /ecos")
    text = (
        "Ты уже вошёл в GhostEcos — аккаунт связан с этим Telegram."
        if already_linked
        else "Открою GhoGem. После входа аккаунт свяжется с Telegram, и ты вернёшься в бот."
    )
    await message.answer(
        text,
        reply_markup=ghostecos_webapp_keyboard(
            include_profile=True,
            already_linked=already_linked,
        ),
    )


@dp.message(Command("link"))
async def cmd_link(message: Message):
    parts = (message.text or "").split(maxsplit=1)
    await _do_link(message, parts[1] if len(parts) > 1 else "")


@dp.message(Command("unlink"))
async def cmd_unlink(message: Message):
    if sso is None:
        await message.answer("Привязка аккаунтов сейчас недоступна.")
        return
    link = await asyncio.to_thread(sso.link_by_tg, message.from_user.id)
    if not link:
        await message.answer("К этому Telegram аккаунт GhostEcos не привязан.")
        return
    await asyncio.to_thread(sso.link_delete_by_gs, link["gs_user_id"])
    await message.answer(
        "🔓 Аккаунт @%s отвязан.\n\nЧаты остались здесь, в Telegram — на сайте "
        "после входа начнётся новый список." % html.escape(str(link["gs_username"] or link["gs_user_id"])),
        parse_mode="HTML",
    )


@dp.message(CommandStart())
async def cmd_start(message: Message):
    user_id = message.from_user.id
    await db.touch_user(user_id)

    args = (message.text or "").split(maxsplit=1)

    # Вход из GhostEcos Mini App: /start ghlogin_<одноразовый код>.
    if len(args) > 1 and args[1].startswith("ghlogin_"):
        if sso is None:
            await message.answer("⚠️ Вход через GhostEcos сейчас недоступен. Попробуй позже.")
            return
        code = args[1][len("ghlogin_"):]
        try:
            ok, msg, moved, account = await asyncio.to_thread(
                sso.webapp_login_code_redeem, code, user_id
            )
        except Exception:
            log.exception("Ошибка погашения одноразового GhostEcos-кода")
            await message.answer("⚠️ Не удалось завершить вход. Открой /ecos и попробуй ещё раз.")
            return
        if not ok or not account:
            await message.answer("⚠️ " + html.escape(msg))
            return
        username = html.escape(str(account.get("gs_username") or account["gs_user_id"]))
        moved_text = f"\n📂 Перенесено чатов: <b>{moved}</b>" if moved else ""
        bonus_text = await _award_ghostecos_link_bonus(
            user_id, int(account["gs_user_id"])
        )
        await message.answer(
            "✅ Вход в аккаунт GhostEcos выполнен успешно.\n"
            f"👤 Аккаунт: <b>@{username.lstrip('@')}</b>"
            + moved_text
            + bonus_text
            + "\n\nПрофиль GhoGem обновлён.",
            parse_mode="HTML",
            reply_markup=ghostecos_linked_keyboard(),
        )
        return

    # привязка аккаунта с сайта: /start link<код>
    if len(args) > 1 and args[1].startswith("link"):
        await _do_link(message, args[1][4:])
        return

    # реферал: /start ref<inviter_id>
    if len(args) > 1 and args[1].startswith("ref"):
        try:
            inviter_id = int(args[1][3:])
            if inviter_id != user_id and inviter_id > 0:
                added = await db.add_referral(inviter_id, user_id)
                if added:
                    # друг: +1 день Premium (продление, не перезапись)
                    await db.extend_subscription_days(user_id, 1)
                    await message.answer(
                        "🎁 Тебе начислен +1 день Premium за переход по реферальной ссылке!"
                    )

                    # инвайтер: бонус по номеру этого реферала (тир)
                    count = await db.count_referrals(inviter_id)
                    bonus_sec = db.bonus_seconds_for_nth(count)
                    if bonus_sec > 0:
                        exp = await db.get_expiry(inviter_id)
                        base = max(exp, int(time.time()))
                        await db.set_subscription(inviter_id, base + bonus_sec)
                        await db.mark_referral_bonus_applied(inviter_id, user_id)

                    # уведомление пригласившему
                    friend = message.from_user
                    friend_name = (
                        (friend.full_name if friend else None)
                        or (f"@{friend.username}" if friend and friend.username else None)
                        or f"id {user_id}"
                    )
                    try:
                        tier_name, per_person, cur, mx, next_hint = _referral_tier_info(count)
                        await bot.send_message(
                            inviter_id,
                            (
                                f"🎉 По твоей реферальной ссылке зашёл новый пользователь!\n\n"
                                f"👤 {html.escape(str(friend_name))}\n"
                                f"📊 Всего приглашено: <b>{count}</b>\n"
                                f"🏅 Уровень: <b>{tier_name}</b>\n"
                                f"📈 {html.escape(next_hint)}\n"
                                f"👑 Тебе начислено Premium: <b>+{_format_seconds(bonus_sec)}</b>\n"
                                f"➡️ За следующего: <b>{per_person}</b>\n\n"
                                f"Смотреть прогресс: /referrals"
                            ),
                            parse_mode="HTML",
                        )
                    except Exception:
                        log.info(
                            "Не удалось уведомить inviter %s о реферале %s",
                            inviter_id,
                            user_id,
                        )
        except Exception:
            log.exception("Ошибка обработки реферала в /start")

    ghostecos_linked = False
    # Используем ник Telegram, пока нет привязки к GhostEcos.
    telegram_nick = (
        f"@{message.from_user.username}"
        if message.from_user.username else message.from_user.full_name
    )
    welcome_nick = telegram_nick or "друг"
    if message.chat.type == "private" and sso is not None:
        try:
            link = await asyncio.to_thread(sso.link_by_tg, user_id)
            ghostecos_linked = bool(link)
            if link:
                profile = await asyncio.to_thread(
                    sso.get_gs_profile_by_id, int(link["gs_user_id"])
                )
                welcome_nick = (
                    (profile or {}).get("display_name")
                    or (profile or {}).get("username")
                    or link.get("gs_username")
                    or telegram_nick
                )
        except Exception:
            log.exception("Не удалось проверить GhostEcos-привязку для /start")

    await message.answer(
        f"👋 <b>С возвращением, {html.escape(str(welcome_nick))}!</b>\n\n"
        + await format_main_menu_text(user_id),
        parse_mode="HTML",
        reply_markup=main_menu_keyboard(
            user_id=user_id,
            include_webapp=message.chat.type == "private",
            ghostecos_linked=ghostecos_linked,
        )
    )


# ============ КОМАНДЫ ============

@dp.message(Command("reset"))
async def cmd_reset(message: Message):
    user_id = message.from_user.id
    ai.reset_chat(user_id)
    await message.answer("🔄 Диалог сброшен. Начинаем с чистого листа.")


def format_help_text() -> str:
    return (
        "💡 <b>GhoGem · Справка</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "<b>🧠 Модели</b>\n"
        "/model — каталог: Groq, Mistral, OpenRouter, SambaNova, Cloudflare…\n"
        "Бейдж 👑/🟢/🟡/🔴 — по размеру модели\n\n"
        "<b>👑 Premium</b>\n"
        f"/subscribe — {SUBSCRIPTION_PRICE_STARS} Stars или {SUBSCRIPTION_PRICE_USDT:.2f} USDT / 30 дней\n"
        "Открывает крупные модели (Mistral Large, 120B, Nemotron Ultra…)\n\n"
        "<b>🔍 Веб-поиск</b>\n"
        "В главном меню: «🔍 Веб-поиск» — на <b>один</b> следующий запрос\n"
        "Модель ищет в сети и даёт ответ со ссылками\n\n"
        "<b>🐍 Точные расчёты</b>\n"
        "Попроси посчитать / решить уравнение — модель вызовет Python-песочницу\n\n"
        "<b>📁 Файлы и чаты</b>\n"
        "/files — файлы текущего чата · /history — история\n"
        "Кнопки «Мои чаты» / «Новый чат» · пришли документ/фото — сохранится в files/\n\n"
        "<b>🎙 Озвучка</b>\n"
        f"{ai.fish_promo_ui_text()}\n\n"
        "<b>👥 Рефералы</b>\n"
        "/referrals — ссылка, тиры и прогресс\n\n"
        "<b>⚙️ Прочее</b>\n"
        "/ecos — войти через GhostEcos и открыть веб-приложение\n"
        "/status · /myprompt · /clearprompt · /reset · /cancel · /queue\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "<i>Просто пиши в чат — остальное сделают tools</i>"
    )


@dp.message(Command("help"))
async def cmd_help(message: Message):
    await message.answer(
        format_help_text(), parse_mode="HTML", reply_markup=back_to_menu_keyboard()
    )


async def format_status_text(user_id: int) -> str:
    subscribed = await db.is_subscribed(user_id)
    model = await get_user_model(user_id)
    short = model.split(":", 1)[1] if ":" in model else model
    text = (
        f"📊 <b>Статус</b>\n\n"
        f"Модель: <code>{short}</code>\n"
        f"Premium: {'✅ активен' if subscribed else '❌ нет'}\n"
        f"RPM: {rpm_used()}/{RPM_LIMIT}\n"
        f"RPD: {rpd_used()}/{RPD_LIMIT}\n"
        f"В очереди: {len(pending_requests)}\n"
    )
    return text


@dp.message(Command("status"))
async def cmd_status(message: Message):
    text = await format_status_text(message.from_user.id)
    await message.answer(text, parse_mode="HTML", reply_markup=back_to_menu_keyboard())


@dp.message(Command("queue"))
async def cmd_queue(message: Message):
    pos = queue_position(message.from_user.id)
    if pos:
        await message.answer(f"📍 Ты в очереди на позиции #{pos}")
    else:
        await message.answer("Ты не в очереди.")


@dp.message(Command("cancel"))
async def cmd_cancel(message: Message):
    cancelled = await cancel_user_request(message.from_user.id, notify=message)
    await message.answer("Останавливаю запрос…" if cancelled
                         else "Активного запроса или очереди нет.")


def format_files_text(user_id: int) -> str:
    chat_id = ai.get_current_chat(user_id)
    stats = ai.chat_stats(user_id, chat_id)
    files = stats["file_list"]
    short_id = chat_id[-8:] if len(chat_id) > 8 else chat_id
    mode = "🟢 режим загрузки ВКЛ" if user_id in upload_mode else "⚪ режим загрузки выкл"
    header = (
        f"📂 <b>Проводник</b> <code>chats/…{short_id}/files/</code>\n"
        f"Сообщений: {stats['messages']} · Файлов: {stats['files']}\n"
        f"{mode}\n"
        f"📦 Git: локальные версии · Status / Log / Commit\n"
        f"🖼 /media — общее медиа · 🚨 /buffer — срочный буфер\n"
        f"━━━━━━━━━━━━━━━\n"
    )
    if not files:
        return header + "Папка пуста.\nНажми «📥 Отправить сюда» и пришли файл."
    body = "\n".join(f"• <code>{f}</code>" for f in files[:40])
    if len(files) > 40:
        body += f"\n… и ещё {len(files) - 40}"
    return header + body


def _html_esc_code(text: str) -> str:
    return (
        str(text or "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def format_git_panel(title: str, body: str) -> str:
    """Карточка git для Telegram — не сырой dump."""
    body = (body or "").strip()
    return (
        f"📦 <b>{_html_esc_code(title)}</b>\n"
        f"━━━━━━━━━━━━━━━\n"
        f"<code>{_html_esc_code(body)[:3500]}</code>"
    )


def _resolve_files_name(user_id: int, short: str) -> str | None:
    """callback_data обрезает имя — ищем полное в files/."""
    chat_id = ai.get_current_chat(user_id)
    files = ai.list_files(user_id, chat_id)
    if short in files:
        return short
    for f in files:
        if f.startswith(short) or short in f:
            return f
    return None


def files_explorer_keyboard(user_id: int) -> InlineKeyboardMarkup:
    chat_id = ai.get_current_chat(user_id)
    files = ai.list_files(user_id, chat_id)
    rows = []
    # до 12 файлов — открыть карточку (скачать / git)
    for name in files[:12]:
        label = name if len(name) <= 28 else name[:25] + "…"
        rows.append([InlineKeyboardButton(
            text=f"📄 {label}",
            callback_data=f"file_menu:{name[:40]}",
        )])
    if user_id in upload_mode:
        rows.append([InlineKeyboardButton(text="❌ Отменить загрузку", callback_data="upload_cancel")])
    else:
        rows.append([InlineKeyboardButton(text="📥 Отправить сюда", callback_data="upload_start")])
    # локальный git (без push)
    rows.append([
        InlineKeyboardButton(text="📦 Status", callback_data="git_status"),
        InlineKeyboardButton(text="📦 Log", callback_data="git_log"),
        InlineKeyboardButton(text="📦 Commit", callback_data="git_commit"),
    ])
    rows.append([
        InlineKeyboardButton(text="🧹 Очистка", callback_data="storage:home"),
        InlineKeyboardButton(text="🔄 Обновить", callback_data="files_cb"),
        InlineKeyboardButton(text="🏠 Меню", callback_data="main_menu"),
    ])
    if user_id in last_answer_snapshot:
        rows.insert(0, [InlineKeyboardButton(text="◀️ Назад к ответу", callback_data="back_to_answer")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def file_card_keyboard(user_id: int, name: str) -> InlineKeyboardMarkup:
    short = name[:40]
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📤 Скачать", callback_data=f"file_send:{short}")],
        [
            InlineKeyboardButton(text="📦 Diff", callback_data=f"git_diff:{short}"),
            InlineKeyboardButton(text="📦 История", callback_data=f"git_flog:{short}"),
        ],
        [InlineKeyboardButton(text="⏪ На версию…", callback_data=f"git_rlist:{short}")],
        [InlineKeyboardButton(text="◀️ К файлам", callback_data="files_cb")],
    ])


def git_restore_keyboard(user_id: int, name: str) -> InlineKeyboardMarkup:
    chat_id = ai.get_current_chat(user_id)
    entries = ai.git_log_entries(user_id, chat_id, limit=8, filename=name)
    rows = []
    short = name[:28]
    for e in entries:
        h = e["hash"][:7]
        subj = (e["subject"] or "")[:22]
        label = f"→ {h} {subj}".strip() or f"→ {h}"
        # git_rst:hash:name  — укладываемся в 64 байта callback
        rows.append([InlineKeyboardButton(
            text=label[:64],
            callback_data=f"git_rst:{h}:{short}",
        )])
    if not rows:
        rows.append([InlineKeyboardButton(text="(нет коммитов — сначала Commit)", callback_data="files_cb")])
    rows.append([InlineKeyboardButton(text="◀️ Назад", callback_data=f"file_menu:{name[:40]}")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def format_history_text(user_id: int) -> str:
    chat_id = ai.get_current_chat(user_id)
    stats = ai.chat_stats(user_id, chat_id)
    short_id = chat_id[-8:] if len(chat_id) > 8 else chat_id
    chat_title = ai.get_chat_title(user_id, chat_id)
    raw = ai.get_history_text(user_id, chat_id)
    header = (
        f"📜 <b>История · {html.escape(chat_title)}</b> <code>…{short_id}</code>\n"
        f"Сообщений: {stats['messages']}\n"
        f"━━━━━━━━━━━━━━━\n"
    )
    return header + (raw if raw else "История пуста.")


@dp.message(Command("files"))
async def cmd_files(message: Message):
    uid = message.from_user.id
    await message.answer(
        format_files_text(uid),
        parse_mode="HTML",
        reply_markup=files_explorer_keyboard(uid),
    )


def _time_left(seconds: int) -> str:
    days, rest = divmod(max(0, int(seconds)), 86400)
    hours, _ = divmod(rest, 3600)
    return f"{days} д. {hours} ч." if days else f"{hours} ч."


def _temporary_panel(uid: int, area: str) -> str:
    try:
        premium = ai.storage_limits_for_user(uid)["chat_limit"] == ai.PREMIUM_CHAT_STORAGE_BYTES
        status = ai.storage_v2.list_temporary(
            ai.USERS_DIR, uid, area=area, premium=premium)
    except Exception as exc:
        return "❌ Хранилище недоступно: " + html.escape(str(exc)[:180])
    title = "🖼 Общие медиа" if area == "media" else "🚨 Аварийный буфер"
    lines = [
        f"<b>{title}</b>",
        f"Использовано {status['used']/1048576:.2f} из {status['limit']/1048576:.0f} МБ",
        f"Файлов: {len(status['files'])}",
        "",
    ]
    for entry in status["files"][:25]:
        title = html.escape(str(entry.get("original_name") or entry["name"])[:60])
        lines.append(
            f"• {title}\n"
            f"  <code>{html.escape(entry['name'])}</code> "
            f"({entry['size']/1048576:.2f} МБ; осталось {_time_left(entry['remaining_seconds'])})"
        )
    if not status["files"]:
        lines.append("Пока пусто.")
    return "\n".join(lines)


def temporary_files_keyboard(uid: int, area: str) -> InlineKeyboardMarkup:
    premium = ai.storage_limits_for_user(uid)["chat_limit"] == ai.PREMIUM_CHAT_STORAGE_BYTES
    records = ai.storage_v2.list_temporary(
        ai.USERS_DIR, uid, area=area, premium=premium
    )["files"]
    buttons = []
    for item in records[:8]:
        label = str(item.get("original_name") or item["name"])
        label = label[:28] + ("…" if len(label) > 28 else "")
        buttons.append([InlineKeyboardButton(
            text=f"📤 {label}",
            callback_data=f"temporary_send:{area}:{item['name']}",
        )])
    if area == "buffer" and uid in buffer_upload_mode:
        buttons.append([InlineKeyboardButton(
            text="❌ Отменить срочную загрузку", callback_data="buffer_upload_cancel",
        )])
    buttons.append([InlineKeyboardButton(text="🏠 Меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


@dp.callback_query(F.data.startswith("temporary_send:"))
async def cb_temporary_send(query: CallbackQuery):
    uid = query.from_user.id
    try:
        prefix, area, name = query.data.split(":", 2)
        if prefix != "temporary_send" or area not in ("media", "buffer"):
            raise ValueError("Неизвестное хранилище")
        path = ai.storage_v2.temp_path(ai.USERS_DIR, uid, name, area)
        await bot.send_document(
            query.message.chat.id, FSInputFile(path, filename=name)
        )
        await query.answer("Файл отправлен")
    except Exception:
        await query.answer("Файл не найден или срок хранения истёк", show_alert=True)


@dp.callback_query(F.data == "buffer_upload_cancel")
async def cb_buffer_upload_cancel(query: CallbackQuery):
    buffer_upload_mode.discard(query.from_user.id)
    await query.answer("Срочная загрузка отменена")
    await edit_or_answer(query, _temporary_panel(query.from_user.id, "buffer"),
                         temporary_files_keyboard(query.from_user.id, "buffer"))


@dp.message(Command("media"))
async def cmd_media(message: Message):
    uid = message.from_user.id
    await message.answer(_temporary_panel(uid, "media"), parse_mode="HTML",
                         reply_markup=temporary_files_keyboard(uid, "media"))


@dp.message(Command("buffer"))
async def cmd_buffer(message: Message):
    uid = message.from_user.id
    buffer_upload_mode.add(uid)
    upload_mode.discard(uid)
    await message.answer(
        _temporary_panel(uid, "buffer")
        + "\n\n<b>Срочный режим включён.</b> Следующий документ или фото "
          "будет сохранён в общем буфере на 24 часа.",
        parse_mode="HTML",
        reply_markup=temporary_files_keyboard(uid, "buffer"),
    )


# AI chat-management approvals. The model can only PROPOSE an action;
# a real Telegram callback from the authenticated owner performs it.
chat_management_tokens: dict[str, dict] = {}
CHAT_MANAGEMENT_TTL = 5 * 60


def _prune_chat_management_tokens() -> None:
    now = int(time.time())
    for token, record in list(chat_management_tokens.items()):
        if int(record.get("expires_at") or 0) < now:
            chat_management_tokens.pop(token, None)
    if len(chat_management_tokens) > 1000:
        for token in list(chat_management_tokens)[:400]:
            chat_management_tokens.pop(token, None)


async def propose_ai_chat_management(
    uid: int,
    telegram_chat_id: int,
    ai_chat_id: str,
    args: dict,
) -> str:
    action = str((args or {}).get("action") or "").strip().lower()
    location = str((args or {}).get("location") or "active").strip().lower()
    target_id = str((args or {}).get("chat_id") or "").strip()
    reason = " ".join(str((args or {}).get("reason") or "").split())[:240]

    if action not in {"archive", "delete"}:
        return "❌ action должен быть archive или delete."
    if location not in {"active", "archive"}:
        return "❌ location должен быть active или archive."
    if action == "archive" and location != "active":
        return "❌ Архивировать можно только активный чат."
    if not re.fullmatch(r"\d{10,20}", target_id):
        return "❌ Нужен точный chat_id из list_chats/list_archived_chats."

    if location == "active":
        items = {str(x["id"]): x for x in ai.list_user_chats(uid)}
        target = items.get(target_id)
        if not target:
            return "❌ Активный чат не найден среди чатов пользователя."
        if target.get("current"):
            return "❌ Текущий чат архивировать или удалять нельзя."
    else:
        items = {str(x["id"]): x for x in ai.list_archived_chats(uid)}
        target = items.get(target_id)
        if not target:
            return "❌ Архивный чат не найден среди чатов пользователя."

    _prune_chat_management_tokens()
    token = secrets.token_urlsafe(9)
    chat_management_tokens[token] = {
        "user_id": int(uid),
        "telegram_chat_id": int(telegram_chat_id),
        "ai_chat_id": str(ai_chat_id),
        "action": action,
        "location": location,
        "chat_id": target_id,
        "expires_at": int(time.time()) + CHAT_MANAGEMENT_TTL,
    }

    title = str(target.get("title") or "Новый чат")[:100]
    messages_count = int(target.get("messages") or 0)
    files_count = int(target.get("files") or 0)
    verb = "переместить в архив" if action == "archive" else "удалить"
    effect = (
        "Чат будет храниться в архиве 7 дней, затем удалится автоматически."
        if action == "archive"
        else "История и файлы этого чата будут удалены."
    )
    await bot.send_message(
        int(telegram_chat_id),
        "🤖 <b>GhoGemo предлагает действие с чатом</b>\n\n"
        f"💬 <b>{html.escape(title)}</b>\n"
        f"Сообщений: {messages_count} · файлов: {files_count}\n"
        f"Действие: <b>{html.escape(verb)}</b>\n"
        + (f"Причина: {html.escape(reason)}\n" if reason else "")
        + f"\n{html.escape(effect)}\n\n"
        "<i>Ничего ещё не изменено.</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(
                text="✅ Подтвердить",
                callback_data=f"ai_chat_manage:confirm:{token}",
            ),
            InlineKeyboardButton(
                text="❌ Отмена",
                callback_data=f"ai_chat_manage:cancel:{token}",
            ),
        ]]),
    )
    return json.dumps({
        "status": "awaiting_user_confirmation",
        "action": action,
        "location": location,
        "chat_id": target_id,
        "title": title,
        "note": "Действие НЕ выполнено. Ждём реального нажатия пользователя в Telegram.",
    }, ensure_ascii=False)


# Explicit, one-time owner-bound deletion approvals. This map is intentionally
# process-local: a restart invalidates stale "confirm delete" buttons.
storage_deletion_tokens: dict[str, tuple[int, int, str, str, str, int]] = {}
storage_deletion_versions: dict[str, tuple[int,int,int]] = {}
# Bulk clear confirmations are also process-local and store an exact snapshot,
# so files uploaded after the confirmation screen opens are never deleted.
storage_bulk_tokens: dict[str, dict] = {}
STORAGE_DELETE_TTL = 5 * 60


def _storage_cleanup_token(uid: int, telegram_chat_id: int, area: str,
                           ai_chat_id: str, filename: str) -> str:
    now=int(time.time())
    for old, entry in list(storage_deletion_tokens.items()):
        if entry[-1] < now:
            storage_deletion_tokens.pop(old, None)
            storage_deletion_versions.pop(old, None)
    if len(storage_deletion_tokens) >= 1200:
        # Resource bound for maliciously repeated list requests.
        for old in list(storage_deletion_tokens)[:500]:
            storage_deletion_tokens.pop(old,None)
            storage_deletion_versions.pop(old,None)
    token=secrets.token_urlsafe(9)
    storage_deletion_tokens[token]=(
        int(uid), int(telegram_chat_id), area, str(ai_chat_id), filename, now+STORAGE_DELETE_TTL)
    # Avoid deleting a different version if the user edits/replaces a
    # permanent file between opening the panel and confirming removal.
    if area in ("main","shared"):
        path=(ai._safe_path(uid,ai_chat_id,filename) if area=="main"
              else ai._safe_shared_path(uid,filename))
        stat=os.stat(path)
        storage_deletion_versions[token]=(stat.st_ino,stat.st_mtime_ns,stat.st_size)
    return token


def _resolve_ai_storage_target(
    uid: int,
    ai_chat_id: str,
    area: str,
    filename: str,
    requested_chat_id: str | None = None,
) -> tuple[str, str, str, int, str]:
    """Resolve one owner file for AI cleanup confirmation.

    Returns (normalized_area, path, display_name, size_bytes, target_chat_id).
    """
    raw_area = (area or "").strip().lower()
    normalized = {
        "current_chat": "main",
        "main": "main",
        "chat": "main",
        "shared": "shared",
        "media": "media",
        "buffer": "buffer",
    }.get(raw_area)
    if not normalized:
        raise ValueError("Неизвестное хранилище")
    filename = str(filename or "").strip()
    if not filename:
        raise ValueError("Не указано имя файла")

    target_chat_id = str(ai_chat_id)
    if raw_area == "chat":
        target_chat_id = str(requested_chat_id or "").strip()
        if not target_chat_id:
            raise ValueError("Для area=chat нужен chat_id")
        owned = {str(c.get("id")) for c in ai.list_user_chats(uid)}
        owned.add(str(ai.get_current_chat(uid)))
        if target_chat_id not in owned:
            raise ValueError("Этот чат не принадлежит пользователю или не существует")

    if normalized == "main":
        path = ai._safe_path(uid, target_chat_id, filename)
        display_name = filename
    elif normalized == "shared":
        path = ai._safe_shared_path(uid, filename)
        display_name = filename
    else:
        premium = (
            ai.storage_limits_for_user(uid)["chat_limit"]
            == ai.PREMIUM_CHAT_STORAGE_BYTES
        )
        payload = ai.storage_v2.list_temporary(
            ai.USERS_DIR, uid, area=normalized, premium=premium
        )
        record = next(
            (item for item in payload["files"] if str(item.get("name")) == filename),
            None,
        )
        if not record:
            raise ValueError("Файл не найден в этом хранилище")
        path = ai.storage_v2.temp_path(
            ai.USERS_DIR, uid, filename, normalized
        )
        original = str(record.get("original_name") or "").strip()
        display_name = original or filename

    if not os.path.isfile(path):
        raise ValueError("Файл уже отсутствует")
    return (
        normalized,
        path,
        display_name,
        int(os.path.getsize(path)),
        target_chat_id,
    )


def _human_usage_age(timestamp: int | None) -> str:
    if not timestamp:
        return "нет данных"
    seconds = max(0, int(time.time()) - int(timestamp))
    if seconds < 60:
        return "только что"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes} мин. назад"
    hours = minutes // 60
    if hours < 24:
        return f"{hours} ч. назад"
    days = hours // 24
    if days < 30:
        return f"{days} дн. назад"
    if days < 365:
        months = max(1, days // 30)
        return f"{months} мес. назад"
    years = max(1, days // 365)
    return f"{years} г. назад"


def _storage_chat_label(chat_id: str | None, current_chat_id: str) -> str:
    if not chat_id:
        return "нет данных"
    value = str(chat_id)
    if value == str(current_chat_id):
        return "текущий чат"
    try:
        date = datetime.fromtimestamp(
            int(value) / 1000,
            ZoneInfo("Europe/Moscow"),
        ).strftime("%d.%m.%Y %H:%M")
        return f"чат …{value[-8:]} · {date} МСК"
    except Exception:
        return f"чат …{value[-8:]}"


async def propose_ai_storage_cleanup(
    uid: int,
    telegram_chat_id: int,
    ai_chat_id: str,
    args: dict,
) -> str:
    """Send the actual file with owner-bound delete/keep confirmation."""
    area = str(args.get("area") or "").strip()
    filename = str(args.get("filename") or "").strip()
    reason = re.sub(r"\s+", " ", str(args.get("reason") or "").strip())[:260]

    try:
        normalized, path, display_name, size, target_chat_id = await asyncio.to_thread(
            _resolve_ai_storage_target,
            uid,
            ai_chat_id,
            area,
            filename,
            args.get("chat_id"),
        )
    except Exception as exc:
        return f"❌ Не удалось подготовить удаление: {str(exc)[:220]}"

    token = _storage_cleanup_token(
        uid,
        telegram_chat_id,
        normalized,
        target_chat_id,
        filename,
    )
    if (area or "").strip().lower() == "chat":
        area_label = f"файлы чата …{target_chat_id[-8:]}"
    else:
        area_label = {
            "main": "файлы текущего чата",
            "shared": "общие документы",
            "media": "медиа",
            "buffer": "буфер",
        }[normalized]

    usage = await asyncio.to_thread(
        ai.get_file_usage,
        uid,
        area=normalized,
        filename=filename,
        storage_chat_id=(target_chat_id if normalized == "main" else None),
    )
    last_used_at = int((usage or {}).get("last_used_at") or 0)
    last_used_chat_id = (usage or {}).get("last_used_chat_id")
    usage_age = _human_usage_age(last_used_at or None)
    usage_chat = _storage_chat_label(last_used_chat_id, ai_chat_id)

    caption = (
        "🤖 <b>GhoGemo предлагает удалить файл</b>\n\n"
        f"📄 <code>{html.escape(display_name)}</code>\n"
        f"🗄 {html.escape(area_label)} · {size/1048576:.2f} МБ\n"
        f"🕓 Последнее использование: <b>{html.escape(usage_age)}</b>\n"
        f"💬 Последний чат: <b>{html.escape(usage_chat)}</b>\n"
        + (
            f"💭 {html.escape(reason)}\n"
            if reason else
            ""
        )
        + "\n<i>Файл пока НЕ удалён. Проверь его и выбери действие.</i>"
    )
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(
            text="🗑 Удалить",
            callback_data=f"ai_storage:confirm:{token}",
        ),
        InlineKeyboardButton(
            text="✅ Оставить",
            callback_data=f"ai_storage:keep:{token}",
        ),
    ]])

    upload = FSInputFile(path, filename=os.path.basename(path))
    ext = os.path.splitext(path)[1].lower()
    sent = None
    try:
        if ext in ai.storage_v2.VIDEO_TYPES:
            sent = await bot.send_video(
                telegram_chat_id,
                video=upload,
                caption=caption,
                reply_markup=kb,
                parse_mode="HTML",
                supports_streaming=True,
            )
        elif ext in ai.storage_v2.IMAGE_TYPES:
            sent = await bot.send_photo(
                telegram_chat_id,
                photo=upload,
                caption=caption,
                reply_markup=kb,
                parse_mode="HTML",
            )
        elif ext in ai.storage_v2.AUDIO_TYPES:
            sent = await bot.send_audio(
                telegram_chat_id,
                audio=upload,
                caption=caption,
                reply_markup=kb,
                parse_mode="HTML",
            )
        else:
            sent = await bot.send_document(
                telegram_chat_id,
                document=upload,
                caption=caption,
                reply_markup=kb,
                parse_mode="HTML",
            )
    except Exception:
        log.exception("Could not send AI storage candidate as native media; falling back to document")
        try:
            sent = await bot.send_document(
                telegram_chat_id,
                document=FSInputFile(path, filename=os.path.basename(path)),
                caption=caption,
                reply_markup=kb,
                parse_mode="HTML",
            )
        except Exception as exc:
            storage_deletion_tokens.pop(token, None)
            storage_deletion_versions.pop(token, None)
            log.exception("Could not send AI storage cleanup confirmation")
            return f"❌ Не удалось отправить файл для подтверждения: {str(exc)[:180]}"

    return json.dumps({
        "status": "awaiting_user_confirmation",
        "area": normalized,
        "filename": filename,
        "display_name": display_name,
        "size_bytes": size,
        "chat_id": target_chat_id if normalized == "main" else None,
        "last_used_at": last_used_at or None,
        "seconds_since_last_use": (
            max(0, int(time.time()) - last_used_at) if last_used_at else None
        ),
        "last_used_chat_id": last_used_chat_id,
        "telegram_message_id": getattr(sent, "message_id", None),
        "deleted": False,
        "note": "Файл отправлен пользователю. Ничего не удалено до нажатия кнопки «Удалить».",
    }, ensure_ascii=False)


def storage_overview(uid: int) -> str:
    chat_id=ai.get_current_chat(uid)
    permanent=ai.storage_usage(uid,chat_id)
    temporary={}
    premium=permanent["chat_limit"] == ai.PREMIUM_CHAT_STORAGE_BYTES
    for area in ("media","buffer"):
        temporary[area]=ai.storage_v2.list_temporary(
            ai.USERS_DIR,uid,area=area,premium=premium)

    def size(x: int) -> str:
        return f"{x/1048576:.2f}"

    def meter(used: int, limit: int) -> str:
        if limit <= 0:
            return "░░░░░░░░░░ 0%"
        pct=max(0.0,min(100.0,(used/limit)*100.0))
        filled=max(0,min(10,round(pct/10)))
        return f"{'▓'*filled}{'░'*(10-filled)} {pct:.0f}%"

    return (
        "🗄 <b>Хранилище GhoGemo · Управление памятью</b>\n\n"
        "<b>Постоянные файлы</b>\n"
        f"• Этот чат: {size(permanent['chat'])}/{size(permanent['chat_limit'])} МБ\n"
        f"  {meter(permanent['chat'],permanent['chat_limit'])}\n"
        f"• Общие документы: {size(permanent['shared'])}/{size(permanent['shared_limit'])} МБ\n"
        f"  {meter(permanent['shared'],permanent['shared_limit'])}\n"
        f"• Всего обычных файлов: {size(permanent['total'])}/{size(permanent['user_limit'])} МБ\n"
        f"  {meter(permanent['total'],permanent['user_limit'])}\n\n"
        "<b>Временная память</b>\n"
        f"• Медиа: {size(temporary['media']['used'])}/{size(temporary['media']['limit'])} МБ\n"
        f"  {meter(temporary['media']['used'],temporary['media']['limit'])}\n"
        f"• Буфер: {size(temporary['buffer']['used'])}/{size(temporary['buffer']['limit'])} МБ\n"
        f"  {meter(temporary['buffer']['used'],temporary['buffer']['limit'])}\n\n"
        "<i>Очистка файлов необратима. Массовое удаление всегда требует отдельного подтверждения.</i>"
    )


def storage_overview_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📄 Этот чат",callback_data="storage:view:main:0"),
         InlineKeyboardButton(text="📂 Общие документы",callback_data="storage:view:shared:0")],
        [InlineKeyboardButton(text="🖼 Медиа",callback_data="storage:view:media:0"),
         InlineKeyboardButton(text="🚨 Буфер",callback_data="storage:view:buffer:0")],
        [InlineKeyboardButton(text="🗑 Очистить хранилище",callback_data="storage:bulkmenu")],
        [InlineKeyboardButton(text="🧽 Очистить просроченные",callback_data="storage:prune")],
        [InlineKeyboardButton(text="⚙️ Настройки",callback_data="settings_menu"),
         InlineKeyboardButton(text="🏠 Меню",callback_data="main_menu")],
    ])


def _storage_items(uid: int,area: str) -> list[tuple[str,int]]:
    if area in ("media","buffer"):
        premium=ai.storage_limits_for_user(uid)["chat_limit"] == ai.PREMIUM_CHAT_STORAGE_BYTES
        data=ai.storage_v2.list_temporary(ai.USERS_DIR,uid,area=area,premium=premium)
        return [
            (item["name"],int(item["size"]))
            for item in data["files"]
        ]
    if area=="main":
        chat=ai.get_current_chat(uid)
        names=ai.list_files(uid,chat)
        items=[]
        for name in names:
            try:
                path=ai._safe_path(uid,chat,name)
                if os.path.isfile(path):
                    items.append((name,os.stat(path).st_size))
            except (ValueError,OSError):
                continue
        return items
    if area=="shared":
        items=[]
        for name in ai.list_shared_files(uid):
            try:
                path=ai._safe_shared_path(uid,name)
                if os.path.isfile(path):
                    items.append((name,os.stat(path).st_size))
            except (ValueError,OSError):
                continue
        return items
    raise ValueError("Неизвестное хранилище")


_STORAGE_BULK_TITLES = {
    "main": "файлы текущего чата",
    "shared": "общие документы",
    "media": "временные медиа",
    "buffer": "буфер",
    "temporary": "всю временную память",
    "all": "ВСЕ файлы GhoGemo",
}


def _storage_bulk_snapshot(uid: int, scope: str) -> list[dict]:
    if scope not in _STORAGE_BULK_TITLES:
        raise ValueError("Неизвестная область очистки")

    result: list[dict] = []

    def add_permanent(area: str, chat_id: str, name: str):
        path = (
            ai._safe_path(uid, chat_id, name)
            if area == "main"
            else ai._safe_shared_path(uid, name)
        )
        if not os.path.isfile(path):
            return
        stat = os.stat(path)
        result.append({
            "area": area,
            "chat_id": chat_id,
            "name": name,
            "size": int(stat.st_size),
            "version": (int(stat.st_ino), int(stat.st_mtime_ns), int(stat.st_size)),
        })

    if scope in ("main", "all"):
        if scope == "main":
            chat_ids = [str(ai.get_current_chat(uid))]
        else:
            chat_ids = [str(c["id"]) for c in ai.list_user_chats(uid)]
            current = str(ai.get_current_chat(uid))
            if current not in chat_ids:
                chat_ids.append(current)
        for chat_id in chat_ids:
            for name in ai.list_files(uid, chat_id):
                try:
                    add_permanent("main", chat_id, name)
                except (ValueError, OSError):
                    continue

    if scope in ("shared", "all"):
        for name in ai.list_shared_files(uid):
            try:
                add_permanent("shared", "", name)
            except (ValueError, OSError):
                continue

    temp_scopes = []
    if scope in ("media", "buffer"):
        temp_scopes = [scope]
    elif scope in ("temporary", "all"):
        temp_scopes = ["media", "buffer"]
    if temp_scopes:
        premium = (
            ai.storage_limits_for_user(uid)["chat_limit"]
            == ai.PREMIUM_CHAT_STORAGE_BYTES
        )
        for area in temp_scopes:
            data = ai.storage_v2.list_temporary(
                ai.USERS_DIR, uid, area=area, premium=premium
            )
            for item in data["files"]:
                result.append({
                    "area": area,
                    "chat_id": "",
                    "name": str(item["name"]),
                    "size": int(item["size"]),
                    "version": None,
                })

    return result


def _storage_make_bulk_token(
    uid: int,
    telegram_chat_id: int,
    scope: str,
    items: list[dict],
) -> str:
    now = int(time.time())
    for old, data in list(storage_bulk_tokens.items()):
        if int(data.get("expires", 0)) < now:
            storage_bulk_tokens.pop(old, None)
    if len(storage_bulk_tokens) > 200:
        for old in list(storage_bulk_tokens)[:80]:
            storage_bulk_tokens.pop(old, None)
    token = secrets.token_urlsafe(9)
    storage_bulk_tokens[token] = {
        "user_id": int(uid),
        "telegram_chat_id": int(telegram_chat_id),
        "scope": scope,
        "items": items,
        "expires": now + STORAGE_DELETE_TTL,
    }
    return token


def _storage_delete_bulk_sync(uid: int, items: list[dict]) -> tuple[int,int,int]:
    deleted = 0
    freed = 0
    failed = 0
    for item in items:
        area = str(item.get("area") or "")
        chat_id = str(item.get("chat_id") or "")
        name = str(item.get("name") or "")
        try:
            if area == "main":
                path = ai._safe_path(uid, chat_id, name)
                if not os.path.isfile(path):
                    continue
                stat = os.stat(path)
                current_version = (
                    int(stat.st_ino), int(stat.st_mtime_ns), int(stat.st_size)
                )
                if item.get("version") != current_version:
                    failed += 1
                    continue
                size = int(stat.st_size)
                status = ai._delete_file(uid, chat_id, name)
                if status != "Файл удалён":
                    raise ValueError(status)
            elif area == "shared":
                path = ai._safe_shared_path(uid, name)
                if not os.path.isfile(path):
                    continue
                stat = os.stat(path)
                current_version = (
                    int(stat.st_ino), int(stat.st_mtime_ns), int(stat.st_size)
                )
                if item.get("version") != current_version:
                    failed += 1
                    continue
                size = int(stat.st_size)
                status = ai.delete_shared_file(uid, name)
                if not status.startswith("✅"):
                    raise ValueError(status)
            elif area in ("media", "buffer"):
                size = int(ai.storage_v2.delete_temporary(
                    ai.USERS_DIR, uid, area=area, name=name
                ))
            else:
                failed += 1
                continue
            try:
                ai.forget_file_usage(
                    uid,
                    area=area,
                    filename=name,
                    storage_chat_id=(chat_id if area == "main" else None),
                )
            except Exception:
                log.exception("Failed to remove bulk-deleted file usage metadata")
            deleted += 1
            freed += max(0, size)
        except Exception:
            failed += 1
    return deleted, freed, failed


def _storage_list_panel(uid: int,chat_id: int,area: str,page: int):
    items=_storage_items(uid,area)
    offset=page*8
    excerpt=items[offset:offset+8]
    titles={"main":"обычных файлов этого чата","shared":"общих документов",
            "media":"медиафайлов","buffer":"буфера"}
    text=(
        f"🧹 <b>Очистка {titles[area]}</b>\n"
        f"Всего файлов: {len(items)}. Страница {page+1}.\n"
        "Нажатие на файл откроет подтверждение; сразу ничего не удаляется."
    )
    buttons=[]
    chat_folder=ai.get_current_chat(uid)
    for name,size in excerpt:
        token=_storage_cleanup_token(uid,chat_id,area,chat_folder,name)
        short=name if len(name)<35 else name[:32]+"…"
        buttons.append([InlineKeyboardButton(
            text=f"🗑 {short} ({size/1048576:.2f} МБ)",
            callback_data=f"storage:ask:{token}",
        )])
    nav=[]
    if page>0:
        nav.append(InlineKeyboardButton(
            text="◀️",callback_data=f"storage:view:{area}:{page-1}"))
    if offset+8<len(items):
        nav.append(InlineKeyboardButton(
            text="▶️",callback_data=f"storage:view:{area}:{page+1}"))
    if nav:
        buttons.append(nav)
    buttons.append([InlineKeyboardButton(text="◀️ К памяти",callback_data="storage:home")])
    if not items:
        text+="\n\nПусто."
    return text,InlineKeyboardMarkup(inline_keyboard=buttons)


@dp.message(Command("storage"))
async def cmd_storage(message: Message):
    uid=message.from_user.id
    try:
        await message.answer(storage_overview(uid),parse_mode="HTML",
                             reply_markup=storage_overview_keyboard())
    except Exception as exc:
        log.exception("Cannot open storage panel")
        await message.answer(f"❌ Проводник памяти недоступен: {html.escape(str(exc)[:100])}")


@dp.callback_query(F.data == "storage:home")
async def cb_storage_home(query: CallbackQuery):
    await query.answer()
    try:
        await edit_or_answer(query,storage_overview(query.from_user.id),
                             storage_overview_keyboard())
    except Exception:
        log.exception("Storage home failed")


@dp.callback_query(F.data == "storage:bulkmenu")
async def cb_storage_bulk_menu(query: CallbackQuery):
    await query.answer()
    text = (
        "🗑 <b>Очистить хранилище</b>\n\n"
        "Выбери, что удалить. Перед удалением я ещё раз покажу объём "
        "и попрошу подтверждение.\n\n"
        "<i>История чатов, память ИИ и настройки при очистке файлов не удаляются.</i>"
    )
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="📄 Файлы этого чата",
            callback_data="storage:bulkask:main",
        )],
        [InlineKeyboardButton(
            text="📂 Общие документы",
            callback_data="storage:bulkask:shared",
        )],
        [InlineKeyboardButton(
            text="🖼 Временные медиа",
            callback_data="storage:bulkask:media",
        ),
         InlineKeyboardButton(
            text="🚨 Буфер",
            callback_data="storage:bulkask:buffer",
        )],
        [InlineKeyboardButton(
            text="🧽 Вся временная память",
            callback_data="storage:bulkask:temporary",
        )],
        [InlineKeyboardButton(
            text="⚠️ ВСЕ файлы",
            callback_data="storage:bulkask:all",
        )],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="storage:home")],
    ])
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data.startswith("storage:bulkask:"))
async def cb_storage_bulk_ask(query: CallbackQuery):
    scope = query.data.rsplit(":", 1)[-1]
    if scope not in _STORAGE_BULK_TITLES:
        await query.answer("Неизвестная область", show_alert=True)
        return
    try:
        items = await asyncio.to_thread(
            _storage_bulk_snapshot, query.from_user.id, scope
        )
    except Exception:
        log.exception("Cannot build storage bulk snapshot")
        await query.answer("Не удалось проверить хранилище", show_alert=True)
        return

    if not items:
        await query.answer("Здесь уже пусто")
        await edit_or_answer(
            query,
            storage_overview(query.from_user.id),
            storage_overview_keyboard(),
        )
        return

    total = sum(max(0, int(item.get("size") or 0)) for item in items)
    token = _storage_make_bulk_token(
        query.from_user.id,
        query.message.chat.id,
        scope,
        items,
    )
    title = _STORAGE_BULK_TITLES[scope]
    warning = (
        "\n\n⚠️ Будут удалены файлы из <b>всех чатов</b>, общие документы "
        "и временные файлы."
        if scope == "all" else ""
    )
    text = (
        "⚠️ <b>Подтверждение очистки</b>\n\n"
        f"Что удаляем: <b>{html.escape(title)}</b>\n"
        f"Файлов: <b>{len(items)}</b>\n"
        f"Освободится примерно: <b>{total/1048576:.2f} МБ</b>"
        f"{warning}\n\n"
        "<i>Удаление необратимо. Новые файлы, загруженные после открытия "
        "этого подтверждения, затронуты не будут.</i>"
    )
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="🗑 Да, очистить",
            callback_data=f"storage:bulkconfirm:{token}",
        )],
        [InlineKeyboardButton(
            text="Нет, оставить",
            callback_data="storage:home",
        )],
    ])
    await query.answer()
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data.startswith("storage:bulkconfirm:"))
async def cb_storage_bulk_confirm(query: CallbackQuery):
    token = query.data.rsplit(":", 1)[-1]
    data = storage_bulk_tokens.pop(token, None)
    now = int(time.time())
    if (
        not data
        or int(data.get("user_id", -1)) != query.from_user.id
        or int(data.get("telegram_chat_id", -1)) != query.message.chat.id
        or int(data.get("expires", 0)) < now
    ):
        await query.answer(
            "Подтверждение устарело. Открой очистку заново.",
            show_alert=True,
        )
        return

    items = list(data.get("items") or [])
    deleted, freed, failed = await asyncio.to_thread(
        _storage_delete_bulk_sync,
        query.from_user.id,
        items,
    )
    msg = (
        f"✅ Удалено файлов: {deleted}\n"
        f"Освобождено: <b>{freed/1048576:.2f} МБ</b>"
    )
    if failed:
        msg += (
            f"\n⚠️ Пропущено: {failed} — некоторые файлы изменились "
            "после открытия подтверждения или уже отсутствуют."
        )
    await query.answer("Очистка завершена")
    await edit_or_answer(
        query,
        msg + "\n\n" + storage_overview(query.from_user.id),
        storage_overview_keyboard(),
    )


@dp.callback_query(F.data == "storage:prune")
async def cb_storage_prune(query: CallbackQuery):
    uid=query.from_user.id
    try:
        result=await asyncio.to_thread(ai.storage_v2.cleanup_expired,ai.USERS_DIR,uid)
        await query.answer(f"Просроченные файлы: {sum(result.values())} удалено")
        await edit_or_answer(query,storage_overview(uid),storage_overview_keyboard())
    except Exception:
        log.exception("Failed to prune temporary media")
        await query.answer("Очистка пока недоступна",show_alert=True)


@dp.callback_query(F.data.startswith("storage:view:"))
async def cb_storage_view(query: CallbackQuery):
    try:
        _,_,area,p=query.data.split(":",3)
        if area not in {"main","shared","media","buffer"}:
            raise ValueError("area")
        page=int(p)
        if not 0<=page<=500:
            raise ValueError("page")
        content,kb=_storage_list_panel(query.from_user.id,
                                       query.message.chat.id,area,page)
        await query.answer()
        await edit_or_answer(query,content,kb)
    except Exception:
        await query.answer("Не удалось показать список",show_alert=True)


def _verified_deletion_token(query: CallbackQuery,token: str):
    record=storage_deletion_tokens.get(token)
    if not record:
        return None
    uid,chat_id,area,ai_chat_id,name,expiration=record
    if (uid!=query.from_user.id or chat_id!=query.message.chat.id
            or expiration<int(time.time())):
        return None
    return record


async def _perform_storage_token_delete(
    token: str,
    record: tuple[int, int, str, str, str, int],
) -> tuple[int, str]:
    """Consume one owner-bound deletion token and delete exactly its file."""
    storage_deletion_tokens.pop(token, None)
    version = storage_deletion_versions.pop(token, None)
    uid, _, area, chat_id, filename, _ = record

    if area in ("main", "shared"):
        path = (
            ai._safe_path(uid, chat_id, filename)
            if area == "main"
            else ai._safe_shared_path(uid, filename)
        )
        stats = os.stat(path)
        current_version = (stats.st_ino, stats.st_mtime_ns, stats.st_size)
        if version != current_version:
            raise ValueError(
                "Файл изменился после открытия подтверждения. "
                "Нужно запросить удаление заново."
            )

    if area in ("media", "buffer"):
        freed = await asyncio.to_thread(
            ai.storage_v2.delete_temporary,
            ai.USERS_DIR,
            uid,
            area=area,
            name=filename,
        )
    elif area == "main":
        path = ai._safe_path(uid, chat_id, filename)
        freed = os.stat(path).st_size if os.path.isfile(path) else 0
        status = await asyncio.to_thread(ai._delete_file, uid, chat_id, filename)
        if status != "Файл удалён":
            raise ValueError(status)
    elif area == "shared":
        path = ai._safe_shared_path(uid, filename)
        freed = os.stat(path).st_size if os.path.isfile(path) else 0
        status = await asyncio.to_thread(ai.delete_shared_file, uid, filename)
        if not status.startswith("✅"):
            raise ValueError(status)
    else:
        raise ValueError("Неизвестное хранилище")

    try:
        await asyncio.to_thread(
            ai.forget_file_usage,
            uid,
            area=area,
            filename=filename,
            storage_chat_id=(chat_id if area == "main" else None),
        )
    except Exception:
        log.exception("Failed to remove deleted file usage metadata")

    return int(freed), filename


@dp.callback_query(F.data.startswith("storage:ask:"))
async def cb_storage_ask(query: CallbackQuery):
    token=query.data.rsplit(":",1)[-1]
    record=_verified_deletion_token(query,token)
    if not record:
        await query.answer("Ссылка устарела или недоступна",show_alert=True)
        return
    _,_,area,storage_chat_id,filename,_=record
    usage = await asyncio.to_thread(
        ai.get_file_usage,
        query.from_user.id,
        area=area,
        filename=filename,
        storage_chat_id=(storage_chat_id if area=="main" else None),
    )
    last_used_at=int((usage or {}).get("last_used_at") or 0)
    last_used_chat_id=(usage or {}).get("last_used_chat_id")
    text=(
        "⚠️ <b>Подтвердить удаление?</b>\n\n"
        f"Файл: <code>{html.escape(filename)}</code>\n"
        f"Хранилище: <code>{area}</code>\n"
        f"🕓 Последнее использование: <b>{html.escape(_human_usage_age(last_used_at or None))}</b>\n"
        f"💬 Последний чат: <b>{html.escape(_storage_chat_label(last_used_chat_id, storage_chat_id))}</b>\n\n"
        "Это действие нельзя отменить. Если файл анализируется прямо сейчас, "
        "анализ может прерваться."
    )
    kb=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🗑 Да, удалить файл",
                              callback_data=f"storage:confirm:{token}")],
        [InlineKeyboardButton(text="Нет, оставить",callback_data="storage:home")],
    ])
    await query.answer()
    await edit_or_answer(query,text,kb)


@dp.callback_query(F.data.startswith("storage:confirm:"))
async def cb_storage_confirm(query: CallbackQuery):
    token=query.data.rsplit(":",1)[-1]
    record=_verified_deletion_token(query,token)
    if not record:
        await query.answer("Ссылка устарела или недоступна",show_alert=True)
        return
    filename=record[4]
    try:
        freed,_=await _perform_storage_token_delete(token,record)
        await query.answer("Файл удалён")
        await edit_or_answer(query,
            f"✅ Удалено <code>{html.escape(filename)}</code>\n"
            f"Освобождено: {freed/1048576:.2f} МБ.",
            storage_overview_keyboard())
    except Exception as exc:
        log.warning("Storage deletion failed: %s",exc)
        await query.answer("Удалить не удалось",show_alert=True)
        await edit_or_answer(query,
            "❌ Не удалось удалить файл: "+html.escape(str(exc)[:180]),
            storage_overview_keyboard())


@dp.callback_query(F.data.startswith("ai_storage:confirm:"))
async def cb_ai_storage_confirm(query: CallbackQuery):
    token=query.data.rsplit(":",1)[-1]
    record=_verified_deletion_token(query,token)
    if not record:
        await query.answer("Подтверждение устарело или недоступно",show_alert=True)
        return
    filename=record[4]
    try:
        freed,_=await _perform_storage_token_delete(token,record)
        await query.answer("Удалено")
        kb=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="🗄 Открыть хранилище",callback_data="storage:home")
        ]])
        await edit_or_answer(
            query,
            f"✅ <b>Файл удалён</b>\n\n"
            f"<code>{html.escape(filename)}</code>\n"
            f"Освобождено: <b>{freed/1048576:.2f} МБ</b>.",
            kb,
        )
    except Exception as exc:
        log.warning("AI storage deletion failed: %s",exc)
        await query.answer("Удалить не удалось",show_alert=True)
        await edit_or_answer(
            query,
            "❌ Не удалось удалить файл: "+html.escape(str(exc)[:180]),
            InlineKeyboardMarkup(inline_keyboard=[[
                InlineKeyboardButton(text="🗄 Хранилище",callback_data="storage:home")
            ]]),
        )


@dp.callback_query(F.data.startswith("ai_storage:keep:"))
async def cb_ai_storage_keep(query: CallbackQuery):
    token=query.data.rsplit(":",1)[-1]
    record=_verified_deletion_token(query,token)
    if not record:
        await query.answer("Подтверждение устарело или недоступно",show_alert=True)
        return
    filename=record[4]
    storage_deletion_tokens.pop(token,None)
    storage_deletion_versions.pop(token,None)
    await query.answer("Оставлено")
    kb=InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="🗄 Открыть хранилище",callback_data="storage:home")
    ]])
    await edit_or_answer(
        query,
        f"✅ <b>Файл оставлен</b>\n\n"
        f"<code>{html.escape(filename)}</code>\n"
        "GhoGemo ничего не удалил.",
        kb,
    )


@dp.callback_query(F.data.startswith("ai_chat_manage:"))
async def cb_ai_chat_manage(query: CallbackQuery):
    parts = query.data.split(":", 2)
    if len(parts) != 3:
        await query.answer("Некорректное подтверждение", show_alert=True)
        return
    decision, token = parts[1], parts[2]
    _prune_chat_management_tokens()
    record = chat_management_tokens.get(token)
    if not record:
        await query.answer("Подтверждение устарело или недоступно", show_alert=True)
        return
    if (
        int(record.get("user_id") or 0) != int(query.from_user.id)
        or int(record.get("telegram_chat_id") or 0) != int(query.message.chat.id)
        or int(record.get("expires_at") or 0) < int(time.time())
    ):
        await query.answer("Это подтверждение недоступно", show_alert=True)
        return

    if decision == "cancel":
        chat_management_tokens.pop(token, None)
        await query.answer("Отменено")
        try:
            await query.message.edit_text(
                "✅ <b>Действие с чатом отменено.</b>\nНичего не изменено.",
                parse_mode="HTML",
            )
        except Exception:
            pass
        return
    if decision != "confirm":
        await query.answer("Некорректное действие", show_alert=True)
        return

    uid = int(record["user_id"])
    action = str(record["action"])
    location = str(record["location"])
    target_id = str(record["chat_id"])

    # Revalidate ownership/current status at confirmation time; the state may
    # have changed since the model proposed the operation.
    if location == "active":
        current_items = {str(x["id"]): x for x in ai.list_user_chats(uid)}
        item = current_items.get(target_id)
        if not item:
            chat_management_tokens.pop(token, None)
            await query.answer("Чат уже недоступен", show_alert=True)
            return
        if item.get("current"):
            chat_management_tokens.pop(token, None)
            await query.answer("Текущий чат менять нельзя", show_alert=True)
            return
    else:
        archived_items = {str(x["id"]): x for x in ai.list_archived_chats(uid)}
        item = archived_items.get(target_id)
        if not item:
            chat_management_tokens.pop(token, None)
            await query.answer("Архивный чат уже недоступен", show_alert=True)
            return

    if action == "archive":
        if location != "active":
            outcome = "missing"
        else:
            outcome = await asyncio.to_thread(
                ai.archive_chat, uid, target_id, reason="ai_confirmed"
            )
        success = outcome == "archived"
        done_text = (
            "✅ <b>Чат перемещён в архив.</b>\n"
            "Он будет автоматически удалён через 7 дней."
        )
    else:
        if location == "archive":
            outcome = await asyncio.to_thread(ai.delete_archived_chat, uid, target_id)
        else:
            outcome = await asyncio.to_thread(ai.delete_chat, uid, target_id)
        success = outcome == "deleted"
        done_text = "✅ <b>Чат удалён.</b>\nИстория и файлы удалены."

    chat_management_tokens.pop(token, None)
    if not success:
        await query.answer("Не удалось выполнить действие", show_alert=True)
        try:
            await query.message.edit_text(
                "❌ <b>Действие не выполнено.</b>\n"
                "Состояние чата изменилось — запроси действие заново.",
                parse_mode="HTML",
            )
        except Exception:
            pass
        return

    await query.answer("Готово")
    try:
        await query.message.edit_text(
            done_text,
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
                [InlineKeyboardButton(text="📦 Архив", callback_data="archived_chats:0")],
            ]),
        )
    except Exception:
        pass


@dp.message(Command("history"))
async def cmd_history(message: Message):
    user_id = message.from_user.id
    text = format_history_text(user_id)
    chunks = split_text(text, 3500)
    for chunk in chunks:
        await message.answer(chunk, parse_mode="HTML")


@dp.message(Command("subscribe"))
async def format_premium_text(user_id: int) -> str:
    if await db.is_subscribed(user_id):
        exp = await db.get_expiry(user_id)
        until = format_premium_expiry(exp)
        status = f"✅ <b>Активен</b> {until}"
    else:
        status = "❌ Сейчас не активен"
    # список premium-моделей коротко
    prem_lines = []
    for key in sorted(ai.PREMIUM_MODEL_KEYS):
        if key not in ai.AVAILABLE_MODELS or ai.is_model_retired(key):
            continue
        short = key.split(":", 1)[1]
        badge = get_model_badge(key)
        params = get_param_text(key)
        prem_lines.append(f"  {badge} <code>{short}</code>" + (f" · {params}" if params else ""))
    models_block = "\n".join(prem_lines[:18]) if prem_lines else "  (каталог пуст)"
    if len(prem_lines) > 18:
        models_block += f"\n  … и ещё {len(prem_lines) - 18}"
    return (
        f"👑 <b>GhoGem Premium</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"{status}\n\n"
        f"💎 <b>Что даёт Premium</b>\n"
        f"• Дополнительные ИИ-модели в /model\n"
        f"• До 30 активных заданий и напоминаний (Free — 10)\n"
        f"• Расширенный анализ фотографий с рассуждениями\n"
        f"• Видео: 15 в день, анализ до 60 сек (Free — 3 по 20 сек)\n"
        f"• Аудио: 100 записей в час, длинные — целиком (Free — 15/час, до 60 сек)\n"
        f"• Озвучка: 30 раз в час (Free — 5)\n"
        f"• Файлы: 30 МБ на чат, 20 МБ общее, 150 МБ всего\n"
        f"• Временные медиа: 60 МБ, хранение до 10 дней\n\n"
        f"🏷 <b>Цена</b>\n"
        f"⭐ {SUBSCRIPTION_PRICE_STARS} Stars / 30 дней\n"
        f"💎 {SUBSCRIPTION_PRICE_USDT:.2f} USDT / 30 дней\n\n"
        f"🧠 <b>Premium-модели</b>\n"
        f"{models_block}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"<i>Оплата Stars или CryptoBot — кнопки ниже</i>"
    )


async def cmd_subscribe(message: Message):
    user_id = message.from_user.id
    text = await format_premium_text(user_id)
    if await db.is_subscribed(user_id):
        await message.answer(text, parse_mode="HTML", reply_markup=back_to_menu_keyboard())
        return
    await message.answer(text, parse_mode="HTML", reply_markup=subscribe_keyboard())


@dp.callback_query(F.data == "subscribe")
async def cb_subscribe(query: CallbackQuery):
    await query.answer()
    user_id = query.from_user.id
    text = await format_premium_text(user_id)
    kb = back_to_menu_keyboard() if await db.is_subscribed(user_id) else subscribe_keyboard()
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data == "pay_stars")
async def cb_pay_stars(query: CallbackQuery):
    await query.answer()
    user_id = query.from_user.id
    if await db.is_subscribed(user_id):
        exp = await db.get_expiry(user_id)
        until = format_premium_expiry(exp)
        await query.message.answer(f"✅ Premium уже активен {until}")
        return
    prices = [LabeledPrice(label="GhoGem Premium 30 дней", amount=SUBSCRIPTION_PRICE_STARS)]
    await bot.send_invoice(
        chat_id=query.message.chat.id,
        title="GhoGem Premium",
        description="ИИ-модели, 30 заданий, расширенный анализ фото, видео и аудио. Доступ на 30 дней",
        payload=SUBSCRIPTION_PAYLOAD,
        provider_token="",
        currency="XTR",
        prices=prices,
    )


@dp.pre_checkout_query()
async def pre_checkout(query: PreCheckoutQuery):
    await query.answer(ok=True)


@dp.message(F.successful_payment)
async def successful_payment(message: Message):
    user_id = message.from_user.id
    expires = int(time.time()) + SUBSCRIPTION_PERIOD_SECONDS
    await db.set_subscription(user_id, expires)
    until_str = format_premium_expiry(expires)
    await message.answer(f"✅ Оплата получена! Premium активен {until_str}.\nЖми /model")


# ============ CRYPTO BOT ============

async def create_crypto_invoice(user_id: int) -> dict:
    if not CRYPTO_BOT_TOKEN:
        return {"ok": False, "error": "no token"}
    url = "https://pay.crypt.bot/api/createInvoice"
    headers = {"Crypto-Pay-API-Token": CRYPTO_BOT_TOKEN}
    payload = {
        "asset": "USDT",
        "amount": f"{SUBSCRIPTION_PRICE_USDT:.2f}",
        "description": "GhoGem Premium на 30 дней: модели, до 30 заданий, расширенный анализ медиа",
        "payload": f"premium_{user_id}",
        "expires_in": 3600,
    }
    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=payload, headers=headers) as resp:
            return await resp.json()


async def check_crypto_payment(invoice_id: int) -> dict:
    if not CRYPTO_BOT_TOKEN:
        return {"ok": False}
    url = f"https://pay.crypt.bot/api/getInvoices?invoice_ids={invoice_id}"
    headers = {"Crypto-Pay-API-Token": CRYPTO_BOT_TOKEN}
    async with aiohttp.ClientSession() as session:
        async with session.get(url, headers=headers) as resp:
            return await resp.json()


@dp.callback_query(F.data == "crypto_pay")
async def cb_crypto(query: CallbackQuery):
    await query.answer()
    if not CRYPTO_BOT_TOKEN:
        await query.message.answer("💎 Оплата криптой временно недоступна. Используйте Stars.")
        return
    wait_msg = await query.message.answer("💎 Создаю счёт для оплаты...")
    try:
        invoice = await create_crypto_invoice(query.from_user.id)
    except Exception as e:
        log.warning("Ошибка создания крипто-счёта: %s", e)
        invoice = {"ok": False, "error": str(e)}
    try:
        await wait_msg.delete()
    except Exception:
        pass
    if invoice.get("ok"):
        pay_url = invoice["result"]["bot_invoice_url"]
        invoice_id = invoice["result"]["invoice_id"]
        kb = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="💎 Оплатить через CryptoBot", url=pay_url)],
            [InlineKeyboardButton(text="🔄 Проверить оплату", callback_data=f"check_crypto:{invoice_id}")]
        ])
        await query.message.answer(
            f"💎 <b>GhoGem Premium</b> — {SUBSCRIPTION_PRICE_USDT:.2f} USDT / 30 дней\n\n"
            "Нажмите кнопку для оплаты через CryptoBot.\nПосле оплаты нажмите «Проверить оплату».",
            reply_markup=kb, parse_mode="HTML"
        )
    else:
        await query.message.answer("❌ Ошибка создания счёта. Попробуйте позже или используйте Stars.")


@dp.callback_query(F.data.startswith("check_crypto:"))
async def cb_check_crypto(query: CallbackQuery):
    await query.answer("Проверяю оплату...")
    invoice_id = int(query.data.split(":")[1])
    try:
        result = await check_crypto_payment(invoice_id)
    except Exception as e:
        log.warning("Ошибка проверки крипто-оплаты: %s", e)
        await query.message.answer("❌ Не получилось проверить оплату (сбой сети). Попробуйте ещё раз через минуту.")
        return
    if result.get("ok") and result["result"]["items"]:
        invoice = result["result"]["items"][0]
        if invoice["status"] == "paid":
            payload = invoice.get("payload", "")
            if payload.startswith("premium_"):
                user_id = int(payload.split("_")[1])
                if user_id != query.from_user.id:
                    await query.answer("Этот счёт выписан для другого пользователя", show_alert=True)
                    return
                expires = int(time.time()) + 30 * 24 * 3600
                await db.set_subscription(user_id, expires)
                until_str = format_premium_expiry(expires)
                log.info(f"💳 Крипто-оплата от {user_id}, подписка {until_str}")
                await query.message.edit_text(
                    f"✅ Оплата получена! Premium активен {until_str}.\nПремиум-модели доступны — жмите /model",
                    parse_mode="HTML"
                )
                return
    await query.message.edit_text(
        "💎 <b>Оплата ещё не поступила</b>\n\n"
        "Если вы уже оплатили — подождите минуту и нажмите кнопку ниже.\n"
        "Если нет — создайте новый счёт: /subscribe",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🔄 Проверить ещё раз", callback_data=f"check_crypto:{invoice_id}")],
        ])
    )


# ============ АДМИН ============

def is_admin(user_id: int) -> bool:
    return ADMIN_USER_ID != 0 and user_id == ADMIN_USER_ID


@dp.message(Command("grant"))
async def cmd_grant(message: Message):
    if not is_admin(message.from_user.id):
        return
    parts = message.text.split()
    if len(parts) != 3:
        await message.answer("Использование: <code>/grant &lt;user_id&gt; &lt;дней&gt;</code>", parse_mode="HTML")
        return
    try:
        target_id, days = int(parts[1]), int(parts[2])
    except ValueError:
        await message.answer("user_id и число дней должны быть целыми числами.")
        return
    expires = int(time.time()) + days * 24 * 3600
    await db.set_subscription(target_id, expires)
    until_str = format_premium_expiry(expires)
    await message.answer(f"✅ Пользователю <code>{target_id}</code> выдана подписка {until_str}.", parse_mode="HTML")


@dp.message(Command("revoke"))
async def cmd_revoke_premium(message: Message):
    if not is_admin(message.from_user.id):
        return
    parts = message.text.split()
    if len(parts) != 2:
        await message.answer("Использование: <code>/revoke &lt;user_id&gt;</code>", parse_mode="HTML")
        return
    try:
        target_id = int(parts[1])
    except ValueError:
        await message.answer("user_id должен быть числом.")
        return
    await db.revoke_subscription(target_id)
    await message.answer(f"🔄 Подписка пользователя <code>{target_id}</code> отозвана.", parse_mode="HTML")


@dp.message(Command("subscribers"))
async def cmd_subscribers(message: Message):
    if not is_admin(message.from_user.id):
        return
    rows = await db.list_active_subscriptions()
    if not rows:
        await message.answer("📭 Ни одной активной подписки.")
        return
    text = "📋 <b>Активные подписки:</b>\n\n"
    for uid, exp in rows:
        until = format_premium_expiry(exp)
        text += f"• <code>{uid}</code> — {until}\n"
    await message.answer(text, parse_mode="HTML")


@dp.message(Command("users"))
async def cmd_users(message: Message):
    if not is_admin(message.from_user.id):
        return
    total = await db.count_users()
    await message.answer(f"👥 Всего пользователей: <b>{total}</b>", parse_mode="HTML")


# ============ МОДЕЛИ ============

@dp.message(Command("model"))
async def cmd_model(message: Message):
    user_model_menu_mode[message.from_user.id] = "current"
    user_provider_page[message.from_user.id] = 0
    await show_model_menu(message.from_user.id, message.chat.id)


async def make_provider_page(user_id: int, provider_index: int) -> tuple[str, InlineKeyboardMarkup]:
    subscribed = await db.is_subscribed(user_id)
    by_provider = ai.available_models_by_provider()
    # category/search filtering
    category = user_model_category.get(user_id, "all")
    search_q = user_model_search.get(user_id, "").lower().strip()
    if category != "all" or search_q:
        filtered: dict[str, list[str]] = {}
        for provider, models in by_provider.items():
            keep = []
            for key in models:
                info = ai.AVAILABLE_MODELS.get(key) or {}
                # category
                if category == "code" and not any(x in key.lower() for x in ("coder", "laguna", "nex", "north", "dots", "qwen")):
                    continue
                if category == "vision" and key not in ai.MULTIMODAL_MODELS:
                    continue
                if category == "top" and key not in ("pollinations:gpt-5-mini", "pollinations:gpt-5.2", "pollinations:claude-sonnet-4-6", "zveno:nemotron-ultra", "zveno:nemotron-super", "bazaarlink:deepseek-v4-flash", "groq:llama-4-maverick"):
                    continue
                if category == "free" and ai.is_premium_model(key):
                    continue
                # search
                if search_q and search_q not in key.lower() and search_q not in str(info.get("label", "")).lower():
                    continue
                keep.append(key)
            if keep:
                filtered[provider] = keep
        # also filter favorites
        by_provider = filtered

    favorite_keys = [
        key for key in await db.list_favorite_models(user_id)
        if key in ai.AVAILABLE_MODELS
        and not ai.is_model_retired(key)
    ]
    if category != "all" or search_q:
        fav_keep = []
        for key in favorite_keys:
            info = ai.AVAILABLE_MODELS.get(key) or {}
            if category == "code" and not any(x in key.lower() for x in ("coder", "laguna", "nex", "north", "dots", "qwen")):
                continue
            if category == "vision" and key not in ai.MULTIMODAL_MODELS:
                continue
            if category == "top" and key not in ("pollinations:gpt-5-mini", "pollinations:gpt-5.2", "pollinations:claude-sonnet-4-6", "zveno:nemotron-ultra", "zveno:nemotron-super", "bazaarlink:deepseek-v4-flash", "groq:llama-4-maverick"):
                continue
            if category == "free" and ai.is_premium_model(key):
                continue
            if search_q and search_q not in key.lower() and search_q not in str(info.get("label", "")).lower():
                continue
            fav_keep.append(key)
        favorite_keys = fav_keep
    sections: list[tuple[str, list[str]]] = [("favorites", favorite_keys)]
    sections.extend((provider, list(models)) for provider, models in by_provider.items())

    if len(sections) == 1 and not favorite_keys:
        return "😔 Нет доступных моделей.", InlineKeyboardMarkup(inline_keyboard=[])

    provider_index = provider_index % len(sections)
    user_provider_page[user_id] = provider_index

    section_key, models = sections[provider_index]
    label = (
        "⭐ <b>Избранное</b>"
        if section_key == "favorites"
        else ai.PROVIDER_LABELS.get(section_key, f"🔸 {section_key}")
    )

    mode = user_model_menu_mode.get(user_id, "current")
    if mode == "default":
        current_key = await db.get_default_model(user_id) or ai.DEFAULT_MODEL_KEY
        current_caption = "⚙️ Модель по умолчанию"
    else:
        current_key = await get_user_model(user_id)
        current_caption = "🔄 Текущая модель"
    current_short = current_key.split(":", 1)[1] if ":" in current_key else current_key

    promo_active = any(ai._is_promo_active(info) for info in ai.AVAILABLE_MODELS.values() if info.get("premium"))
    promo_banner = "🎉 <b>Акция до 30.10.26:</b> все новые модели бесплатны!\n\n" if promo_active else ""
    text = (
        f"{promo_banner}"
        f"{current_caption}: <code>{current_short}</code>\n\n"
        f"{label}\n"
        f"├{'─' * 15}\n"
    )

    if not models:
        text += "└ Пока пусто. Добавь модель кнопкой ⭐ под её ответом.\n"

    for key in models:
        short = key.split(":", 1)[1]
        is_premium = key in ai.PREMIUM_MODEL_KEYS
        lock = "🔒 " if (is_premium and not subscribed) else ""
        badge = get_model_badge(key)
        params = get_param_text(key)
        countdown = ai.model_countdown_text(key)
        countdown_str = f" ({countdown} до отключения)" if countdown else ""
        selected = " ✓" if key == current_key else ""
        info = ai.AVAILABLE_MODELS.get(key) or {}
        status_short = str(info.get("status_short") or "").strip()
        if status_short:
            unavailable = f" · {status_short}"
        elif not ai.is_model_available(key):
            unavailable = " · ⏳ временно недоступна"
        else:
            unavailable = ""
        text += (
            f"├ {lock}{badge} {short} ({params}){selected}"
            f"{countdown_str}{unavailable}\n"
        )

    buttons = []
    for key in models:
        short = key.split(":", 1)[1]
        is_premium = key in ai.PREMIUM_MODEL_KEYS
        lock = "🔒 " if (is_premium and not subscribed) else ""
        badge = get_model_badge(key)
        countdown = ai.model_countdown_text(key)
        warn = f" {countdown}" if countdown else ""
        selected = " ✓" if key == current_key else ""
        info = ai.AVAILABLE_MODELS.get(key) or {}
        if info.get("availability_status") == "provider_issue":
            unavailable = " ⚠️"
        else:
            unavailable = " ⏳" if not ai.is_model_available(key) else ""
        buttons.append([InlineKeyboardButton(
            text=f"{lock}{badge} {short}{selected}{warn}{unavailable}",
            callback_data=f"model:{key}",
        )])

    # category/search rows
    cat_row1 = [
        InlineKeyboardButton(text=("✅ " if category == "all" else "") + "📋 Все", callback_data="modelcat:all"),
        InlineKeyboardButton(text=("✅ " if category == "code" else "") + "💻 Код", callback_data="modelcat:code"),
        InlineKeyboardButton(text=("✅ " if category == "vision" else "") + "👁 Vision", callback_data="modelcat:vision"),
    ]
    cat_row2 = [
        InlineKeyboardButton(text=("✅ " if category == "top" else "") + "🔥 Топ", callback_data="modelcat:top"),
        InlineKeyboardButton(text=("✅ " if category == "free" else "") + "🆓 Free", callback_data="modelcat:free"),
        InlineKeyboardButton(text="🔍 Поиск" + (f": {search_q[:10]}" if search_q else ""), callback_data="modelsearch"),
    ]
    if search_q:
        cat_row2.append(InlineKeyboardButton(text="❌ Сброс", callback_data="modelsearch_clear"))
    buttons.append(cat_row1)
    buttons.append(cat_row2)

    nav_row = [
        InlineKeyboardButton(text="◀️", callback_data=f"provider:{provider_index - 1}"),
        InlineKeyboardButton(
            text=f"{'⭐' if section_key == 'favorites' else provider_index}/{len(sections) - 1}",
            callback_data="none",
        ),
        InlineKeyboardButton(text="▶️", callback_data=f"provider:{provider_index + 1}"),
    ]
    buttons.append(nav_row)

    back_callback = "settings_menu" if mode == "default" else "main_menu"
    buttons.append([InlineKeyboardButton(
        text="🔙 Назад в настройки" if mode == "default" else "🔙 Назад в меню",
        callback_data=back_callback,
    )])

    if not subscribed and ai.has_any_premium_available():
        buttons.append([InlineKeyboardButton(
            text=f"⭐ Premium за {SUBSCRIPTION_PRICE_STARS} Stars", callback_data="subscribe"
        )])

    return text, InlineKeyboardMarkup(inline_keyboard=buttons)


async def show_model_menu(user_id: int, chat_id: int, edit_message: Message | None = None):
    provider_index = user_provider_page.get(user_id, 0)
    text, kb = await make_provider_page(user_id, provider_index)
    if edit_message:
        await edit_message.edit_text(text, reply_markup=kb, parse_mode="HTML")
    else:
        await bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


@dp.callback_query(F.data.startswith("provider:"))
async def cb_provider_page(query: CallbackQuery):
    await query.answer()
    new_index = int(query.data.split(":")[1])
    text, kb = await make_provider_page(query.from_user.id, new_index)
    await query.message.edit_text(text, reply_markup=kb, parse_mode="HTML")


@dp.callback_query(F.data.startswith("modelcat:"))
async def cb_model_category(query: CallbackQuery):
    await query.answer()
    cat = query.data.split(":", 1)[1]
    if cat not in MODEL_CATEGORIES:
        cat = "all"
    user_model_category[query.from_user.id] = cat
    user_provider_page[query.from_user.id] = 0
    text, kb = await make_provider_page(query.from_user.id, 0)
    await query.message.edit_text(text, reply_markup=kb, parse_mode="HTML")


@dp.callback_query(F.data == "modelsearch")
async def cb_model_search(query: CallbackQuery):
    await query.answer()
    awaiting_model_search.add(query.from_user.id)
    await query.message.answer("🔍 Введи название модели для поиска (например `gpt`, `claude`, `qwen`, `nemotron`):", parse_mode="HTML")


@dp.callback_query(F.data == "modelsearch_clear")
async def cb_model_search_clear(query: CallbackQuery):
    await query.answer()
    user_model_search.pop(query.from_user.id, None)
    awaiting_model_search.discard(query.from_user.id)
    text, kb = await make_provider_page(query.from_user.id, 0)
    await query.message.edit_text(text, reply_markup=kb, parse_mode="HTML")


@dp.callback_query(F.data.startswith("forgetans:"))
async def cb_forget_answer(query: CallbackQuery):
    user_id = query.from_user.id
    try:
        _, answer_chat_id, answer_id = query.data.split(":", 2)
    except ValueError:
        await query.answer("Некорректная кнопка", show_alert=True)
        return

    forgotten = await asyncio.to_thread(
        ai.forget_assistant_answer,
        user_id,
        answer_chat_id,
        answer_id,
    )

    markup = query.message.reply_markup if query.message else None
    if markup:
        rows = []
        for row in markup.inline_keyboard:
            new_row = []
            for button in row:
                if getattr(button, "callback_data", None) == query.data:
                    new_row.append(InlineKeyboardButton(
                        text="🧠 Ответ забыт",
                        callback_data="none",
                    ))
                else:
                    new_row.append(button)
            rows.append(new_row)
        try:
            await query.message.edit_reply_markup(
                reply_markup=InlineKeyboardMarkup(inline_keyboard=rows)
            )
        except Exception:
            pass

    snap = last_answer_snapshot.get(user_id)
    if (
        snap
        and str(snap.get("answer_chat_id") or "") == answer_chat_id
        and str(snap.get("answer_id") or "") == answer_id
    ):
        snap["answer_id"] = None

    await query.answer(
        "🧠 Ответ удалён из контекста ИИ"
        if forgotten else
        "Этот ответ уже не находится в контексте",
        show_alert=False,
    )


@dp.callback_query(F.data.startswith("rating:open:"))
async def cb_rating_open(query: CallbackQuery):
    user_id = query.from_user.id
    token = query.data.split(":", 2)[2]
    row = await asyncio.to_thread(model_ratings.get, token, user_id)
    if not row:
        await query.answer("Эта оценка уже недоступна", show_alert=True)
        return
    premium = await db.is_subscribed(user_id)
    required = bool(row.get("required")) and row.get("score") is None and not row.get("skipped")
    model_name = str(row.get("model_key") or "").split(":", 1)[-1]
    score = row.get("score")
    current = f"\nТекущая оценка: <b>{int(score)}/5</b>" if score else ""
    await query.answer()
    await bot.send_message(
        query.message.chat.id,
        rating_request_text(required=required, is_premium=premium)
        + f"\nМодель: <code>{html.escape(model_name)}</code>"
        + current,
        parse_mode="HTML",
        reply_markup=rating_score_keyboard(
            token,
            is_premium=premium,
            required=required,
        ),
    )


@dp.callback_query(F.data.startswith("rating:score:"))
async def cb_rating_score(query: CallbackQuery):
    user_id = query.from_user.id
    parts = query.data.split(":")
    if len(parts) != 4:
        await query.answer("Некорректная оценка", show_alert=True)
        return
    token, raw_score = parts[2], parts[3]
    try:
        score = int(raw_score)
    except ValueError:
        await query.answer("Некорректная оценка", show_alert=True)
        return
    if not 1 <= score <= 5:
        await query.answer("Оценка должна быть от 1 до 5", show_alert=True)
        return
    row = await asyncio.to_thread(model_ratings.get, token, user_id)
    if not row:
        await query.answer("Эта оценка уже недоступна", show_alert=True)
        return
    saved = await asyncio.to_thread(model_ratings.submit, token, user_id, score)
    if not saved:
        await query.answer("Не удалось сохранить оценку", show_alert=True)
        return
    model_name = str(row.get("model_key") or "").split(":", 1)[-1]
    stars = "★" * score + "☆" * (5 - score)
    resume_count = (
        len(rating_blocked_prompts.get(user_id) or ())
        if bool(row.get("required")) else 0
    )
    await query.answer(f"Сохранено: {score}/5")
    if query.message:
        try:
            tail = (
                f"Отправляю сохранённые запросы: <b>{resume_count}</b>."
                if resume_count else
                "Можно продолжать общение."
            )
            await query.message.edit_text(
                f"✅ <b>Оценка сохранена: {score}/5</b>\n"
                f"{stars}\n"
                f"Модель: <code>{html.escape(model_name)}</code>\n"
                + tail,
                parse_mode="HTML",
            )
        except Exception:
            pass
    if resume_count:
        asyncio.create_task(_resume_rating_blocked_prompts(user_id))


@dp.callback_query(F.data.startswith("rating:skip:"))
async def cb_rating_skip(query: CallbackQuery):
    user_id = query.from_user.id
    token = query.data.split(":", 2)[2]
    row = await asyncio.to_thread(model_ratings.get, token, user_id)
    if not row:
        await query.answer("Эта оценка уже недоступна", show_alert=True)
        return
    if not await db.is_subscribed(user_id):
        await query.answer(
            "На Free обязательную оценку пропустить нельзя.",
            show_alert=True,
        )
        return
    if not row.get("required") or row.get("score") is not None:
        await query.answer("Пропуск здесь не нужен", show_alert=True)
        return
    skipped = await asyncio.to_thread(model_ratings.skip, token, user_id)
    if not skipped:
        await query.answer("Не удалось пропустить оценку", show_alert=True)
        return
    resume_count = len(rating_blocked_prompts.get(user_id) or ())
    await query.answer("Оценка пропущена")
    if query.message:
        try:
            tail = (
                f"\nОтправляю сохранённые запросы: <b>{resume_count}</b>."
                if resume_count else ""
            )
            await query.message.edit_text(
                "⏭ <b>Оценка пропущена</b>\n"
                "Premium позволяет продолжить без обязательной оценки."
                + tail,
                parse_mode="HTML",
            )
        except Exception:
            pass
    if resume_count:
        asyncio.create_task(_resume_rating_blocked_prompts(user_id))


@dp.callback_query(F.data.startswith("favmodel:"))
async def cb_toggle_favorite_model(query: CallbackQuery):
    user_id = query.from_user.id
    model_key = query.data.split(":", 1)[1]
    if model_key not in ai.AVAILABLE_MODELS:
        await query.answer("Модель больше недоступна", show_alert=True)
        return

    was_favorite = await db.is_model_favorite(user_id, model_key)
    is_favorite = await db.set_model_favorite(user_id, model_key, not was_favorite)
    short_name = model_key.split(":", 1)[1]

    markup = query.message.reply_markup if query.message else None
    if markup:
        rows = []
        for row in markup.inline_keyboard:
            new_row = []
            for button in row:
                if getattr(button, "callback_data", None) == f"favmodel:{model_key}":
                    new_row.append(InlineKeyboardButton(
                        text=(
                            "★ Убрать модель из избранного"
                            if is_favorite else
                            "⭐ Добавить модель в избранное"
                        ),
                        callback_data=f"favmodel:{model_key}",
                    ))
                else:
                    new_row.append(button)
            rows.append(new_row)
        try:
            await query.message.edit_reply_markup(
                reply_markup=InlineKeyboardMarkup(inline_keyboard=rows)
            )
        except Exception:
            pass

    await query.answer(
        f"{'⭐ Добавлено в избранное' if is_favorite else 'Убрано из избранного'}: {short_name}"
    )


@dp.callback_query(F.data.startswith("model:"))
async def cb_model(query: CallbackQuery):
    model_key = query.data.split(":", 1)[1]
    full_key = model_key
    if full_key not in ai.AVAILABLE_MODELS:
        await query.answer("Неизвестная модель")
        return
    if not ai.is_model_available(full_key):
        info = ai.AVAILABLE_MODELS.get(full_key) or {}
        detail = str(info.get("status_detail") or "").strip()
        if detail:
            await query.answer(
                "⚠️ Модель сейчас не работает. " + detail,
                show_alert=True,
            )
        else:
            await query.answer(
                "⚠️ Эта модель сейчас недоступна или больше не бесплатна",
                show_alert=True,
            )
        await show_model_menu(query.from_user.id, query.message.chat.id, edit_message=query.message)
        return
    if ai.is_model_retired(full_key):
        await query.answer("😔 Эта модель уже отключена провайдером", show_alert=True)
        await show_model_menu(query.from_user.id, query.message.chat.id, edit_message=query.message)
        return
    if full_key in ai.PREMIUM_MODEL_KEYS and not await db.is_subscribed(query.from_user.id):
        await query.answer("🔒 Эта модель доступна только по подписке", show_alert=True)
        await query.message.answer(
            f"⭐ Модель <code>{full_key.split(':', 1)[1]}</code> доступна только с активной подпиской.",
            reply_markup=subscribe_keyboard(), parse_mode="HTML",
        )
        return
    user_id = query.from_user.id
    short_name = full_key.split(":", 1)[1]
    badge = get_model_badge(full_key)
    params = get_param_text(full_key)
    mode = user_model_menu_mode.get(user_id, "current")

    if mode == "default":
        await db.set_default_model(user_id, full_key)
        await query.answer(f"По умолчанию: {short_name} 🟢")
        text, kb = await make_provider_page(
            user_id, user_provider_page.get(user_id, 0)
        )
        await query.message.edit_text(
            f"✅ Модель по умолчанию: <code>{short_name}</code>\n"
            "Она будет включаться при создании новых чатов.\n\n"
            f"{text}",
            reply_markup=kb,
            parse_mode="HTML",
        )
        return

    await persist_user_model(user_id, full_key)
    # Не сбрасываем чат при смене модели — файлы и память сохраняются.
    await ensure_chat_persisted(user_id)
    await query.answer(f"Модель изменена на {short_name} 🟢")
    await bot.send_message(
        query.message.chat.id,
        f"{badge} Модель <b>{short_name}</b> ({params}) выбрана! Попробуйте прислать сообщение.",
        parse_mode="HTML", reply_markup=back_to_menu_keyboard()
    )
    text, kb = await make_provider_page(
        user_id, user_provider_page.get(user_id, 0)
    )
    await query.message.edit_text(
        f"✅ Модель изменена: <code>{short_name}</code>\nЧат и файлы сохранены.\n\n{text}",
        reply_markup=kb, parse_mode="HTML",
    )


# ============ НАСТРОЙКИ ============

MAX_CUSTOM_PROMPT_LEN = 1500

TIMEZONE_PRESETS = [
    ("🇷🇺 Москва", "Europe/Moscow"),
    ("🇷🇺 Калининград", "Europe/Kaliningrad"),
    ("🇷🇺 Самара", "Europe/Samara"),
    ("🇷🇺 Екатеринбург", "Asia/Yekaterinburg"),
    ("🇷🇺 Омск", "Asia/Omsk"),
    ("🇷🇺 Красноярск", "Asia/Krasnoyarsk"),
    ("🇷🇺 Иркутск", "Asia/Irkutsk"),
    ("🇷🇺 Якутск", "Asia/Yakutsk"),
    ("🇷🇺 Владивосток", "Asia/Vladivostok"),
    ("🇩🇪 Берлин", "Europe/Berlin"),
    ("🇬🇧 Лондон", "Europe/London"),
    ("🇺🇸 Нью-Йорк", "America/New_York"),
    ("🇺🇸 Лос-Анджелес", "America/Los_Angeles"),
    ("🇯🇵 Токио", "Asia/Tokyo"),
]
TIMEZONE_ALIASES = {
    "москва": "Europe/Moscow",
    "moscow": "Europe/Moscow",
    "мск": "Europe/Moscow",
    "калининград": "Europe/Kaliningrad",
    "самара": "Europe/Samara",
    "екатеринбург": "Asia/Yekaterinburg",
    "екб": "Asia/Yekaterinburg",
    "омск": "Asia/Omsk",
    "красноярск": "Asia/Krasnoyarsk",
    "иркутск": "Asia/Irkutsk",
    "якутск": "Asia/Yakutsk",
    "владивосток": "Asia/Vladivostok",
    "берлин": "Europe/Berlin",
    "berlin": "Europe/Berlin",
    "frankfurt": "Europe/Berlin",
    "франкфурт": "Europe/Berlin",
    "германия": "Europe/Berlin",
    "germany": "Europe/Berlin",
    "лондон": "Europe/London",
    "london": "Europe/London",
    "нью-йорк": "America/New_York",
    "new york": "America/New_York",
    "лос-анджелес": "America/Los_Angeles",
    "los angeles": "America/Los_Angeles",
    "токио": "Asia/Tokyo",
    "tokyo": "Asia/Tokyo",
}


def normalize_timezone_input(value: str) -> str:
    raw = " ".join(str(value or "").strip().split())
    if not raw:
        raise ValueError("Пустой часовой пояс.")
    candidate = TIMEZONE_ALIASES.get(raw.casefold(), raw)
    try:
        ZoneInfo(candidate)
    except Exception as error:
        raise ValueError(
            "Не знаю такой часовой пояс. Пришли IANA-имя, например Europe/Moscow, "
            "Europe/Berlin или Asia/Yekaterinburg."
        ) from error
    return candidate


def timezone_summary(timezone_name: str) -> str:
    try:
        zone = ZoneInfo(timezone_name)
    except Exception:
        timezone_name = reminders.DEFAULT_TIMEZONE
        zone = ZoneInfo(timezone_name)
    now = datetime.now(zone)
    offset = now.strftime("%z")
    if len(offset) == 5:
        offset = f"{offset[:3]}:{offset[3:]}"
    return (
        f"<code>{html.escape(timezone_name)}</code> · "
        f"{now.strftime('%H:%M')} {html.escape(reminders.timezone_label(timezone_name, now))} · UTC{offset}"
    )


def timezone_keyboard(current_timezone: str) -> InlineKeyboardMarkup:
    rows = []
    for index in range(0, len(TIMEZONE_PRESETS), 2):
        row = []
        for label, zone in TIMEZONE_PRESETS[index:index + 2]:
            prefix = "✅ " if zone == current_timezone else ""
            row.append(InlineKeyboardButton(
                text=prefix + label,
                callback_data=f"tz:set:{zone}",
            ))
        rows.append(row)
    rows.extend([
        [InlineKeyboardButton(
            text="✍️ Ввести город / IANA",
            callback_data="tz:custom",
        )],
        [InlineKeyboardButton(
            text="◀️ Настройки",
            callback_data="settings_menu",
        )],
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def settings_text(user_id: int) -> str:
    custom_prompt = await db.get_custom_prompt(user_id)
    default_key = await db.get_default_model(user_id) or ai.DEFAULT_MODEL_KEY
    timezone_name = await db.get_timezone(user_id)
    fallback_on_rate_limit = await db.get_fallback_on_rate_limit(user_id)
    default_short = default_key.split(":", 1)[1] if ":" in default_key else default_key
    prompt_state = (
        f"<code>{html.escape(custom_prompt[:180])}</code>"
        + ("…" if len(custom_prompt) > 180 else "")
        if custom_prompt else
        "<i>не задан</i>"
    )
    return (
        "⚙️ <b>Настройки GhoGem</b>\n\n"
        f"📝 <b>Системный промпт:</b> {prompt_state}\n\n"
        f"🧠 <b>Модель по умолчанию:</b> <code>{html.escape(default_short)}</code>\n"
        "<i>Она автоматически включается в новых чатах.</i>\n\n"
        f"🕒 <b>Часовой пояс:</b> {timezone_summary(timezone_name)}\n"
        "<i>Используется для времени ИИ и новых напоминаний.</i>\n\n"
        f"🔄 <b>Автосмена модели:</b> "
        f"{'включена' if fallback_on_rate_limit else 'выключена'}\n"
        "<i>Если выключить, GhoGem не будет автоматически менять выбранную модель "
        "при лимите, тайм-ауте или ошибке провайдера. Другой API-ключ той же модели "
        "он всё ещё может попробовать.</i>"
    )


def settings_keyboard(
    has_prompt: bool = False,
    fallback_on_rate_limit: bool = True,
) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(
            text="📝 Изменить системный промпт",
            callback_data="settings_prompt_edit",
        )],
        [InlineKeyboardButton(
            text="🧠 Модель по умолчанию",
            callback_data="settings_default_model",
        )],
        [InlineKeyboardButton(
            text="🕒 Часовой пояс",
            callback_data="settings_timezone",
        )],
        [InlineKeyboardButton(
            text=(
                "🔄 Автосмена модели: ВКЛ"
                if fallback_on_rate_limit
                else "⛔ Автосмена модели: ВЫКЛ"
            ),
            callback_data="settings_toggle_rate_fallback",
        )],
        [InlineKeyboardButton(
            text="🗄 Хранилище",
            callback_data="settings_storage",
        )],
    ]
    if has_prompt:
        rows.append([InlineKeyboardButton(
            text="🧹 Удалить системный промпт",
            callback_data="settings_prompt_clear",
        )])
    rows.append([InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def render_settings(
    user_id: int,
    *,
    query: CallbackQuery | None = None,
    chat_id: int | None = None,
):
    text = await settings_text(user_id)
    kb = settings_keyboard(
        bool(await db.get_custom_prompt(user_id)),
        await db.get_fallback_on_rate_limit(user_id),
    )
    if query and query.message:
        await query.message.edit_text(text, reply_markup=kb, parse_mode="HTML")
    elif chat_id is not None:
        await bot.send_message(chat_id, text, reply_markup=kb, parse_mode="HTML")


@dp.callback_query(F.data == "settings_menu")
async def cb_settings_menu(query: CallbackQuery):
    awaiting_custom_prompt.discard(query.from_user.id)
    awaiting_timezone.discard(query.from_user.id)
    user_model_menu_mode.pop(query.from_user.id, None)
    await query.answer()
    await render_settings(query.from_user.id, query=query)


@dp.callback_query(F.data == "settings_toggle_rate_fallback")
async def cb_settings_toggle_rate_fallback(query: CallbackQuery):
    user_id = query.from_user.id
    current = await db.get_fallback_on_rate_limit(user_id)
    new_value = not current
    await db.set_fallback_on_rate_limit(user_id, new_value)
    await query.answer(
        "Автосмена модели включена"
        if new_value else
        "Автосмена модели выключена"
    )
    await render_settings(user_id, query=query)


@dp.callback_query(F.data == "settings_prompt_edit")
async def cb_settings_prompt_edit(query: CallbackQuery):
    awaiting_timezone.discard(query.from_user.id)
    awaiting_custom_prompt.add(query.from_user.id)
    await query.answer()
    await query.message.edit_text(
        "📝 <b>Системный промпт</b>\n\n"
        "Пришли следующим сообщением новый системный промпт. "
        f"Максимум {MAX_CUSTOM_PROMPT_LEN} символов.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(
                text="Отмена",
                callback_data="settings_prompt_cancel",
            )
        ]]),
    )


@dp.callback_query(F.data == "settings_prompt_cancel")
async def cb_settings_prompt_cancel(query: CallbackQuery):
    awaiting_custom_prompt.discard(query.from_user.id)
    await query.answer("Отменено")
    await render_settings(query.from_user.id, query=query)


@dp.callback_query(F.data == "settings_prompt_clear")
async def cb_settings_prompt_clear(query: CallbackQuery):
    await db.delete_custom_prompt(query.from_user.id)
    awaiting_custom_prompt.discard(query.from_user.id)
    await query.answer("Системный промпт удалён")
    await render_settings(query.from_user.id, query=query)


@dp.callback_query(F.data == "settings_default_model")
async def cb_settings_default_model(query: CallbackQuery):
    user_id = query.from_user.id
    user_model_menu_mode[user_id] = "default"
    user_provider_page[user_id] = 0
    await query.answer()
    await show_model_menu(
        user_id,
        query.message.chat.id,
        edit_message=query.message,
    )


@dp.callback_query(F.data == "settings_timezone")
async def cb_settings_timezone(query: CallbackQuery):
    user_id = query.from_user.id
    awaiting_custom_prompt.discard(user_id)
    awaiting_timezone.discard(user_id)
    timezone_name = await db.get_timezone(user_id)
    await query.answer()
    await query.message.edit_text(
        "🕒 <b>Часовой пояс</b>\n\n"
        f"Сейчас: {timezone_summary(timezone_name)}\n\n"
        "Он используется для текущего времени ИИ и для <b>новых</b> "
        "напоминаний. Уже созданные задания сохраняют часовой пояс, "
        "с которым были созданы.",
        parse_mode="HTML",
        reply_markup=timezone_keyboard(timezone_name),
    )


@dp.callback_query(F.data.startswith("tz:set:"))
async def cb_timezone_set(query: CallbackQuery):
    user_id = query.from_user.id
    raw = query.data.split(":", 2)[2]
    try:
        timezone_name = normalize_timezone_input(raw)
    except ValueError as error:
        await query.answer(str(error)[:180], show_alert=True)
        return
    await db.set_timezone(user_id, timezone_name)
    awaiting_timezone.discard(user_id)
    awaiting_custom_prompt.discard(user_id)
    await query.answer("Часовой пояс сохранён")
    await render_settings(user_id, query=query)


@dp.callback_query(F.data == "tz:custom")
async def cb_timezone_custom(query: CallbackQuery):
    user_id = query.from_user.id
    awaiting_custom_prompt.discard(user_id)
    awaiting_timezone.add(user_id)
    await query.answer()
    await query.message.edit_text(
        "🕒 <b>Свой часовой пояс</b>\n\n"
        "Пришли город или IANA-имя следующим сообщением.\n"
        "Например: <code>Москва</code>, <code>Екатеринбург</code>, "
        "<code>Europe/Berlin</code>, <code>America/New_York</code>.\n\n"
        "Лучше использовать IANA-имя: оно автоматически учитывает "
        "переходы на летнее/зимнее время.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(
                text="Отмена",
                callback_data="settings_timezone",
            )
        ]]),
    )


@dp.callback_query(F.data == "settings_storage")
async def cb_settings_storage(query: CallbackQuery):
    await query.answer()
    try:
        await edit_or_answer(
            query,
            storage_overview(query.from_user.id),
            storage_overview_keyboard(),
        )
    except Exception:
        log.exception("Settings storage panel failed")
        await query.answer("Хранилище пока недоступно", show_alert=True)


# ============ КАСТОМНЫЙ ПРОМТ ============



@dp.message(Command("myprompt"))
async def cmd_myprompt(message: Message):
    args = message.text.split(maxsplit=1)
    if len(args) > 1:
        text = args[1].strip()
        if len(text) > MAX_CUSTOM_PROMPT_LEN:
            await message.answer(
                f"❌ Слишком длинно ({len(text)} символов). "
                f"Максимум — {MAX_CUSTOM_PROMPT_LEN}."
            )
            return
        await db.set_custom_prompt(message.from_user.id, text)
        await message.answer("✅ Твой системный промт сохранён! Бот будет учитывать его в диалогах.")
    else:
        prompt = await db.get_custom_prompt(message.from_user.id)
        if prompt:
            await message.answer(f"📝 Твой системный промт:\n<code>{html.escape(prompt)}</code>", parse_mode="HTML")
        else:
            await message.answer("У тебя пока нет своего промта. Установи: /myprompt <текст>")


@dp.message(Command("clearprompt"))
async def cmd_clearprompt(message: Message):
    await db.delete_custom_prompt(message.from_user.id)
    await message.answer("🧹 Твой системный промт удалён.")


# ============ ПОЛЬЗОВАТЕЛЬСКИЕ API-КЛЮЧИ ============

ADDKEY_PROVIDERS = list(getattr(ai, "API_KEY_PROVIDERS", ai.PROVIDER_ORDER))
ADDKEY_REWARD_DAYS = 3

# ссылки, где получить бесплатный API-ключ у каждого провайдера — показываем
# в сообщении с выбором, чтобы не заставлять человека гуглить самому
ADDKEY_SIGNUP_LINKS = {
    "groq": "https://console.groq.com/keys",
    "mistral": "https://console.mistral.ai/api-keys",
    "openrouter": "https://openrouter.ai/keys",
    "sambanova": "https://cloud.sambanova.ai/apis",
}


def _live_addkey_providers() -> list[str]:
    """Только те провайдеры, у которых реально настроен основной ключ
    (иначе получится, что юзер добавляет ключ для провайдера, которого
    у нас вообще нет — NVIDIA/Cloudflare часто выключены за отсутствием
    своего ключа)."""
    live = []
    for p in ADDKEY_PROVIDERS:
        try:
            if ai.get_client(p) is not None:
                live.append(p)
        except Exception:
            pass
    return live

# in-memory: кто сейчас в процессе присылки ключа и для какого провайдера
# (не переживает рестарт бота — это ок, пользователь просто начнёт заново)
_awaiting_key: dict[int, str] = {}

# грубое распознавание провайдера по характерному префиксу ключа —
# нужно чтобы подсказать "это ключ от X, а не от Y" если юзер перепутал
_KEY_PREFIX_HINTS = [
    ("gsk_", "groq"),
    ("sk-or-", "openrouter"),
]


def _guess_provider(api_key: str) -> str | None:
    for prefix, provider in _KEY_PREFIX_HINTS:
        if api_key.startswith(prefix):
            return provider
    return None


def _addkey_provider_keyboard() -> InlineKeyboardMarkup:
    rows = []
    row = []
    for p in _live_addkey_providers():
        label = ai.PROVIDER_LABELS.get(p, p)
        row.append(InlineKeyboardButton(text=label, callback_data=f"addkey_prov:{p}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([InlineKeyboardButton(text="◀️ Вернуться", callback_data="addkey_cancel")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


MYKEYS_PROVIDER_EMOJI_ON = "✅"
MYKEYS_PROVIDER_EMOJI_OFF = "⬜"


async def _mykeys_menu_text_and_kb(user_id: int) -> tuple[str, InlineKeyboardMarkup]:
    live_providers = _live_addkey_providers()
    own_keys = {k["provider"]: k for k in await db.list_user_keys(user_id)}

    rows = []
    row = []
    for p in live_providers:
        label = ai.PROVIDER_LABELS.get(p, p)
        info = own_keys.get(p)
        if not info:
            mark = "⬜"
        elif not info.get("is_active"):
            mark = "🔴"
        elif info.get("use_own_only"):
            mark = "🔒"
        else:
            mark = "✅"
        row.append(InlineKeyboardButton(text=f"{mark} {label}", callback_data=f"mykeys_prov:{p}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([InlineKeyboardButton(text="◀️ Вернуться", callback_data="addkey_cancel")])

    text = (
        "🔑 <b>Мои ключи</b>\n\n"
        "✅ — активный резервный ключ · 🔒 — только твой · 🔴 — отключён · ⬜ — не добавлен\n\n"
        "Ключи хранятся зашифрованно. Резервный ключ пробуется на той же модели "
        "до её автосмены. Жми на провайдера для управления."
    )
    return text, InlineKeyboardMarkup(inline_keyboard=rows)


@dp.callback_query(F.data == "mykeys_menu")
async def cb_mykeys_menu(query: CallbackQuery):
    _awaiting_key.pop(query.from_user.id, None)
    text, kb = await _mykeys_menu_text_and_kb(query.from_user.id)
    await query.message.edit_text(text, parse_mode="HTML", reply_markup=kb)
    await query.answer()


@dp.callback_query(F.data.startswith("mykeys_prov:"))
async def cb_mykeys_provider(query: CallbackQuery):
    provider = query.data.split(":", 1)[1]
    if provider not in ADDKEY_PROVIDERS:
        await query.answer("Неизвестный провайдер", show_alert=True)
        return

    existing = await db.get_user_key_any(query.from_user.id, provider)
    if existing is None:
        # ключа ещё нет — сразу ведём в обычный флоу добавления
        await cb_addkey_provider_chosen(query)
        return

    # ключ уже есть — экран управления им
    await _render_mykeys_manage(query, provider)


async def _render_mykeys_manage(
    query: CallbackQuery,
    provider: str,
    *,
    answer_callback: bool = True,
):
    user_id = query.from_user.id
    keys = {k["provider"]: k for k in await db.list_user_keys(user_id)}
    info = keys.get(provider)
    if not info:
        await query.answer("Ключ не найден", show_alert=True)
        return

    label = ai.PROVIDER_LABELS.get(provider, provider)
    own_only = info.get("use_own_only")
    own_only_label = "✅ Только мой ключ" if own_only else "⬜ Только мой ключ"
    status_line = "🟢 активен" if info.get("is_active") else "🔴 отключён после ошибки"
    fail_count = int(info.get("fail_count") or 0)
    last_used_at = info.get("last_used_at")
    if last_used_at:
        try:
            last_used = datetime.fromtimestamp(
                int(last_used_at), tz=timezone.utc
            ).astimezone(ZoneInfo("Europe/Moscow")).strftime("%d.%m %H:%M МСК")
        except Exception:
            last_used = "недавно"
    else:
        last_used = "ещё не использовался"

    text = (
        f"🔑 <b>{label}</b>\n\n"
        f"Ключ: <code>{info.get('masked_key', '••••')}</code>\n"
        f"Статус: {status_line}\n"
        f"Последнее использование: <b>{html.escape(last_used)}</b>\n"
        f"Ошибок ключа: <b>{fail_count}</b>\n\n"
        f"«Только мой ключ» — запросы к {label} идут через твой ключ, "
        "без серверного или чужого ключа этого провайдера; сам ключ не попадает "
        "в общий резервный пул.\n"
        "Если режим выключен, ключ может участвовать в резервном пуле и для твоего "
        "запроса будет попробован на той же модели до её автосмены."
    )
    key_test_label = (
        "🧪 Проверить ключ"
        if info.get("is_active")
        else "🧪 Проверить и включить"
    )
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=own_only_label, callback_data=f"mykeys_toggle:{provider}")],
        [InlineKeyboardButton(text=key_test_label, callback_data=f"mykeys_test:{provider}")],
        [InlineKeyboardButton(text="✏️ Изменить ключ", callback_data=f"addkey_prov:{provider}")],
        [InlineKeyboardButton(text="🗑 Удалить ключ", callback_data=f"mykeys_delete:{provider}")],
        [InlineKeyboardButton(text="◀️ Вернуться", callback_data="mykeys_menu")],
    ])
    await query.message.edit_text(text, parse_mode="HTML", reply_markup=kb)
    if answer_callback:
        await query.answer()


@dp.callback_query(F.data.startswith("mykeys_toggle:"))
async def cb_mykeys_toggle(query: CallbackQuery):
    provider = query.data.split(":", 1)[1]
    user_id = query.from_user.id
    info = await db.get_user_key_any(user_id, provider)
    if not info:
        await query.answer("Ключ не найден", show_alert=True)
        return
    new_value = not info.get("use_own_only")
    await db.set_use_own_only(user_id, provider, new_value)
    await query.answer("Готово: " + ("только свой ключ включён" if new_value else "только свой ключ выключен"))
    await _render_mykeys_manage(query, provider, answer_callback=False)


@dp.callback_query(F.data.startswith("mykeys_test:"))
async def cb_mykeys_test(query: CallbackQuery):
    provider = query.data.split(":", 1)[1]
    user_id = query.from_user.id
    info = await db.get_user_key_any(user_id, provider)
    if not info:
        await query.answer("Ключ не найден", show_alert=True)
        return

    await query.answer("Проверяю ключ…")
    probe = await ai.probe_api_key(provider, str(info.get("api_key") or ""))
    status = str(probe.get("status") or "unknown")

    if status in {"ok", "limited", "restricted"}:
        await db.reactivate_user_key(user_id, provider)
        await db.reset_key_fail_count(user_id, provider)
        if status == "ok":
            message = "✅ Ключ работает"
        elif status == "limited":
            message = "🟡 Ключ настоящий, но сейчас упёрся в лимит"
        else:
            message = "🟡 Ключ принят провайдером, но тестовая модель недоступна этому ключу"
    elif status == "invalid":
        await db.mark_key_failed(user_id, provider, deactivate_after=1)
        message = "❌ Провайдер отклонил ключ: авторизация не прошла"
    else:
        message = "⚠️ Не удалось уверенно проверить ключ прямо сейчас"

    try:
        await query.message.answer(message)
    except Exception:
        pass
    await _render_mykeys_manage(query, provider, answer_callback=False)


@dp.callback_query(F.data.startswith("mykeys_delete:"))
async def cb_mykeys_delete(query: CallbackQuery):
    provider = query.data.split(":", 1)[1]
    user_id = query.from_user.id
    await db.remove_user_key(user_id, provider)
    await query.answer("Ключ удалён")
    text, kb = await _mykeys_menu_text_and_kb(user_id)
    await query.message.edit_text(text, parse_mode="HTML", reply_markup=kb)


@dp.callback_query(F.data == "addkey_start")
async def cb_addkey_start(query: CallbackQuery):
    _awaiting_key.pop(query.from_user.id, None)
    await query.message.edit_text(
        "🔑 <b>Свой API-ключ</b>\n\n"
        "Ключ хранится зашифрованно. По умолчанию он работает как резервный: "
        "если ключи GhoGem упёрлись в лимит, бот сначала попробует другой ключ "
        "на той же модели и только потом сменит модель.\n\n"
        "В «Моих ключах» можно включить <b>«Только мой ключ»</b> — тогда ключ "
        "используется только для твоих запросов и исключается из общего пула.\n\n"
        f"За первый ключ от каждого провайдера — <b>+{ADDKEY_REWARD_DAYS} дня Premium</b>.\n\n"
        "Выбери провайдера:",
        parse_mode="HTML",
        reply_markup=_addkey_provider_keyboard(),
        disable_web_page_preview=True,
    )
    await query.answer()


@dp.callback_query(F.data.startswith("addkey_prov:"))
async def cb_addkey_provider_chosen(query: CallbackQuery):
    provider = query.data.split(":", 1)[1]
    if provider not in ADDKEY_PROVIDERS:
        await query.answer("Неизвестный провайдер", show_alert=True)
        return
    _awaiting_key[query.from_user.id] = provider
    label = ai.PROVIDER_LABELS.get(provider, provider)
    link = ADDKEY_SIGNUP_LINKS.get(provider)
    link_line = f"\n\n🔗 Получить ключ: <a href=\"{link}\">{link}</a>" if link else ""
    await query.message.edit_text(
        f"🔑 Пришли ключ для {label} следующим сообщением."
        f"{link_line}\n\n"
        "Перед сохранением я коротко проверю авторизацию. Ключ хранится зашифрованно; "
        "режим «Только мой ключ» можно включить после добавления.",
        parse_mode="HTML",
        disable_web_page_preview=True,
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="◀️ Вернуться", callback_data="addkey_cancel")]
        ]),
    )
    await query.answer()


@dp.callback_query(F.data == "addkey_cancel")
async def cb_addkey_cancel(query: CallbackQuery):
    _awaiting_key.pop(query.from_user.id, None)
    await query.message.edit_text(
        "Главное меню:",
        reply_markup=main_menu_keyboard(),
    )
    await query.answer("Отменено")


@dp.callback_query(F.data.startswith("addkey_reprompt:"))
async def cb_addkey_reprompt(query: CallbackQuery):
    """Пользователь прислал ключ не того провайдера — кнопка «вернуться
    к выбранному провайдеру» (просим прислать ключ ЕЩЁ раз, для него же)."""
    provider = query.data.split(":", 1)[1]
    if provider not in ADDKEY_PROVIDERS:
        await query.answer("Неизвестный провайдер", show_alert=True)
        return
    _awaiting_key[query.from_user.id] = provider
    label = ai.PROVIDER_LABELS.get(provider, provider)
    link = ADDKEY_SIGNUP_LINKS.get(provider)
    link_line = f"\n\n🔗 Получить ключ: <a href=\"{link}\">{link}</a>" if link else ""
    await query.message.edit_text(
        f"🔑 Пришли ключ для {label} следующим сообщением.{link_line}",
        parse_mode="HTML",
        disable_web_page_preview=True,
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="◀️ Вернуться", callback_data="addkey_cancel")]
        ]),
    )
    await query.answer()


@dp.callback_query(F.data.startswith("addkey_useother:"))
async def cb_addkey_use_other(query: CallbackQuery):
    """Пользователь прислал ключ не того провайдера, но согласился
    использовать его для распознанного провайдера вместо выбранного."""
    payload = query.data.split(":", 2)
    if len(payload) != 3:
        await query.answer("Ошибка данных", show_alert=True)
        return
    _, provider, key_token = payload
    api_key = _pending_keys.pop(key_token, None)
    if not api_key or provider not in ADDKEY_PROVIDERS:
        await query.answer("Ключ устарел, пришли ещё раз", show_alert=True)
        return
    await _save_key_and_reply(query.from_user.id, provider, api_key, query.message, is_callback=True)
    await query.answer()


# короткоживущий токен → реальный ключ, чтобы не пихать сырой API-ключ
# в callback_data (там лимит 64 байта и это светилось бы в логах Telegram)
_pending_keys: dict[str, str] = {}


async def _save_key_and_reply(user_id: int, provider: str, api_key: str, message: Message, is_callback: bool = False):
    label = ai.PROVIDER_LABELS.get(provider, provider)
    send = message.edit_text if is_callback else message.answer

    probe = await ai.probe_api_key(provider, api_key)
    probe_status = str(probe.get("status") or "unknown")
    if probe_status == "invalid":
        text = (
            f"❌ Ключ {label} не сохранён: провайдер вернул ошибку авторизации. "
            "Проверь ключ и пришли его ещё раз."
        )
        try:
            await send(text, reply_markup=back_to_menu_keyboard())
        except Exception:
            await message.answer(text, reply_markup=back_to_menu_keyboard())
        return

    result = await db.add_user_key(user_id, provider, api_key)

    if probe_status == "ok":
        verify_line = "🧪 Проверка: ключ работает."
    elif probe_status == "limited":
        verify_line = "🧪 Проверка: ключ настоящий, но сейчас в лимите."
    elif probe_status == "restricted":
        verify_line = "🧪 Проверка: авторизация прошла, но тестовая модель ограничена."
    else:
        verify_line = "🧪 Проверка сейчас не дала однозначного результата; ключ можно перепроверить в «Моих ключах»."

    if result.get("is_first"):
        await db.extend_subscription_days(user_id, ADDKEY_REWARD_DAYS)
        text = (
            f"✅ Ключ {label} сохранён и добавлен в резервный пул.\n"
            f"{verify_line}\n"
            f"🎁 Начислено +{ADDKEY_REWARD_DAYS} дня Premium — спасибо!\n\n"
            "В «Моих ключах» можно включить «Только мой ключ» — тогда он станет приватным "
            "и перестанет участвовать в общем пуле."
        )
    else:
        text = (
            f"✅ Ключ {label} обновлён.\n"
            f"{verify_line}\n"
            "Режим использования можно изменить в «Моих ключах»."
        )

    try:
        await send(text, reply_markup=back_to_menu_keyboard())
    except Exception:
        await message.answer(text, reply_markup=back_to_menu_keyboard())


async def try_handle_pending_api_key(message: Message) -> bool:
    """Вызывается ПЕРВОЙ строкой в handle_message — перехватывает текст,
    если пользователь сейчас в процессе присылки ключа. Возвращает True,
    если сообщение было обработано как ключ (и обычную логику ИИ дальше
    запускать не нужно)."""
    user_id = message.from_user.id
    provider = _awaiting_key.get(user_id)
    if not provider:
        return False

    api_key = (message.text or "").strip()
    _awaiting_key.pop(user_id, None)

    if len(api_key) < 10 or " " in api_key or "\n" in api_key:
        await message.answer(
            "❌ Не удалось распознать ключ — это не похоже на API-ключ.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="◀️ Вернуться", callback_data="addkey_start")]
            ]),
        )
        return True

    guessed = _guess_provider(api_key)

    if guessed and guessed != provider:
        # похоже на ключ ДРУГОГО нашего провайдера — даём выбор
        expected_label = ai.PROVIDER_LABELS.get(provider, provider)
        guessed_label = ai.PROVIDER_LABELS.get(guessed, guessed)
        token = uuid.uuid4().hex[:12]
        _pending_keys[token] = api_key
        await message.answer(
            f"⚠️ Ты выбрал {expected_label}, но этот ключ похож на ключ {guessed_label}.",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text=f"◀️ Прислать ключ {expected_label}", callback_data=f"addkey_reprompt:{provider}")],
                [InlineKeyboardButton(text=f"✅ Использовать как {guessed_label}", callback_data=f"addkey_useother:{guessed}:{token}")],
            ]),
        )
        return True

    # либо совпадает с ожидаемым провайдером, либо формат неизвестен —
    # сохраняем как есть под выбранным пользователем провайдером
    await _save_key_and_reply(user_id, provider, api_key, message)
    return True


@dp.message(Command("addkey"))
async def cmd_addkey(message: Message):
    """Текстовая команда остаётся как быстрый путь для тех, кто предпочитает
    её кнопкам — основной флоу теперь через кнопку в меню."""
    args = message.text.split(maxsplit=2)
    if len(args) < 3:
        await message.answer(
            "Открой 🔑 «Свой API-ключ» в меню — там удобнее (выбор провайдера кнопками).",
            reply_markup=main_menu_keyboard(),
        )
        return
    provider = args[1].strip().lower()
    api_key = args[2].strip()
    if provider not in ADDKEY_PROVIDERS:
        await message.answer(f"❌ Неизвестный провайдер «{provider}». Доступны: {', '.join(ADDKEY_PROVIDERS)}")
        return
    if len(api_key) < 10 or " " in api_key:
        await message.answer("❌ Похоже, это не ключ. Проверь и пришли снова.")
        return
    await _save_key_and_reply(message.from_user.id, provider, api_key, message)


# ============ РЕФЕРАЛЫ ============

def _format_seconds(sec: int) -> str:
    if sec < 3600:
        return f"{sec // 60} мин"
    elif sec < 86400:
        return f"{sec // 3600} ч"
    else:
        return f"{sec // 86400} дн"


def referral_link(user_id: int) -> str:
    return f"https://t.me/ghogembot?start=ref{int(user_id)}"


def referral_invitation_text() -> str:
    """Публичная карточка с описанием бота и бонусом новичку."""
    return (
        "🤖 <b>GhoGem — ИИ-помощник в Telegram</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "Нейросети прямо в Telegram — без лишних приложений.\n\n"
        "🧠 Выбирай ИИ-модель под задачу\n"
        "🔎 Ищи информацию в интернете\n"
        "📁 Работай с файлами и изображениями\n"
        "💬 Сохраняй историю чатов и используй память\n"
        "🗓 Создавай задания и напоминания\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "🎁 <b>Новому пользователю — 1 день Premium</b> по этому приглашению.\n\n"
        "Нажми кнопку и попробуй GhoGem!"
    )


def referral_invitation_keyboard(user_id: int) -> InlineKeyboardMarkup:
    # Только URL-кнопки для пересылаемого сообщения.
    url = referral_link(user_id)
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🚀 Открыть GhoGem", url=url, style="primary")],
        [InlineKeyboardButton(text="🎁 Забрать +1 день Premium", url=url, style="success")],
    ])


def referrals_keyboard(user_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📨 Создать приглашение", callback_data="referral_invitation", style="primary")],
        [InlineKeyboardButton(text="📋 Скопировать ссылку", copy_text=CopyTextButton(text=referral_link(user_id)))],
        [InlineKeyboardButton(text="🔙 Назад в меню", callback_data="main_menu")],
    ])


@dp.message(Command("referrals"))
async def cmd_referrals(message: Message):
    text = await format_referrals_text(message.from_user.id)
    await message.answer(text, parse_mode="HTML", reply_markup=referrals_keyboard(message.from_user.id))


@dp.callback_query(F.data == "referral_invitation")
async def cb_referral_invitation(query: CallbackQuery):
    await query.answer()
    await bot.send_message(
        query.message.chat.id,
        referral_invitation_text(),
        parse_mode="HTML",
        reply_markup=referral_invitation_keyboard(query.from_user.id),
    )


@dp.inline_query()
async def inline_referral_invitation(query: InlineQuery):
    """Работает после включения inline mode через @BotFather."""
    if (query.query or "").strip().lower() not in ("", "invite"):
        await query.answer([], cache_time=1, is_personal=True)
        return
    result = InlineQueryResultArticle(
        id=f"ghogem_referral_{query.from_user.id}",
        title="🤖 Пригласить в GhoGem",
        description="ИИ-помощник + день Premium новому пользователю",
        input_message_content=InputTextMessageContent(
            message_text=referral_invitation_text(), parse_mode="HTML"
        ),
        reply_markup=referral_invitation_keyboard(query.from_user.id),
    )
    await query.answer([result], cache_time=0, is_personal=True)


def _referral_tier_info(count: int) -> tuple[str, str, int, int, str]:
    """(emoji_name, bonus_per_person, progress_cur, progress_max, next_hint)"""
    if count < 10:
        return "🥉 Старт", "+30 мин", count, 10, f"ещё {10 - count} до Бронзы"
    if count < 20:
        return "🥈 Бронза", "+3 ч", count - 10, 10, f"ещё {20 - count} до Серебра"
    if count < 50:
        return "🥇 Серебро", "+3 дня", count - 20, 30, f"ещё {50 - count} до Золота"
    return "💎 Золото", "+5 дней", 1, 1, "максимальный уровень"


async def format_referrals_text(user_id: int) -> str:
    count = await db.count_referrals(user_id)
    bonus_sec = await db.get_referral_bonus_seconds(user_id)
    bonus_str = _format_seconds(bonus_sec)
    tier_name, per_person, cur, mx, next_hint = _referral_tier_info(count)
    bar = progress_bar(cur, mx, 12)
    pct = int(100 * cur / mx) if mx else 100
    return (
        f"👥 <b>Реферальная программа</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📨 <b>Приглашение для друга</b>\n"
        f"Нажми «Создать приглашение» и перешли карточку.\n\n"
        f"📊 <b>Твой прогресс</b>\n"
        f"Приглашено: <b>{count}</b> чел\n"
        f"Уровень: <b>{tier_name}</b>\n"
        f"Бонус за нового: <b>{per_person}</b> Premium тебе\n"
        f"Накоплено бонусов: +{bonus_str}\n\n"
        f"{bar} <b>{pct}%</b>\n"
        f"<i>{next_hint}</i>\n\n"
        f"🏷 <b>Тиры</b>\n"
        f"🥉 <b>Старт</b> 0–9 · +30 мин / чел\n"
        f"🥈 <b>Бронза</b> 10–19 · +3 ч / чел\n"
        f"🥇 <b>Серебро</b> 20–49 · +3 дня / чел\n"
        f"💎 <b>Золото</b> 50+ · +5 дней / чел\n\n"
        f"🎁 Друг по ссылке получает <b>+1 день Premium</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"<i>Бонус за каждого нового приглашённого пользователя.</i>"
    )


@dp.callback_query(F.data == "referrals")
async def cb_referrals(query: CallbackQuery):
    await query.answer()
    text = await format_referrals_text(query.from_user.id)
    await edit_or_answer(query, text, referrals_keyboard(query.from_user.id))


# ============ КНОПКИ МЕНЮ ============

async def format_main_menu_text(user_id: int) -> str:
    chat_id = ai.get_current_chat(user_id)
    stats = ai.chat_stats(user_id, chat_id)
    short_id = chat_id[-8:] if len(chat_id) > 8 else chat_id
    chat_title = ai.get_chat_title(user_id, chat_id)
    model_key = await get_user_model(user_id)
    short = model_key.split(":", 1)[1] if ":" in model_key else model_key
    badge = get_model_badge(model_key)
    params = get_param_text(model_key)
    model_info = ai.AVAILABLE_MODELS.get(model_key) or {}
    model_status_short = str(model_info.get("status_short") or "").strip()
    model_status_line = (
        f"\n{model_status_short}"
        if model_status_short else ""
    )
    try:
        prem = await db.is_subscribed(user_id)
        if prem:
            exp = await db.get_expiry(user_id)
            until = format_premium_expiry(exp)
            prem_line = f"👑 Premium · <b>{until}</b>"
        else:
            prem_line = "🔓 Free · <i>Premium закрыт</i>"
    except Exception:
        prem_line = "🔓 Free"
    search_line = (
        "🔍 Веб-поиск: <b>ВКЛ</b> на следующий запрос"
        if user_id in web_search_once
        else "🔍 Веб-поиск: выкл (кнопка ниже)"
    )
    q = len(pending_requests)
    queue_line = f"⏳ В общей очереди: <b>{q}</b>" if q else "✅ Очередь пуста"
    return (
        f"🏠 <b>GhoGem · Главное меню</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"{badge} Модель: <code>{short}</code>"
        + (f" · {params}" if params else "")
        + model_status_line + "\n"
        f"{prem_line}\n"
        f"{search_line}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 Чат: <b>{html.escape(chat_title)}</b> <code>…{short_id}</code>\n"
        f"📨 Сообщений: <b>{stats['messages']}</b> · 📄 Файлов: <b>{stats['files']}</b>\n"
        f"📜 История: {'есть' if stats['has_history'] else 'пусто'}\n"
        f"{queue_line}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"<i>Выбери действие кнопкой или просто напиши сообщение</i>"
    )


async def edit_or_answer(query: CallbackQuery, text: str, reply_markup=None):
    """Редактирует текст или подпись к медиа; при ошибке — отправляет новое сообщение."""
    has_snap = query.from_user.id in last_answer_snapshot
    kb = reply_markup
    if kb is None:
        kb = back_only_keyboard() if has_snap else main_menu_keyboard(show_back=False)
    try:
        has_caption_media = bool(
            query.message and (
                query.message.photo
                or query.message.video
                or query.message.document
                or query.message.audio
                or query.message.animation
            )
        )
        if has_caption_media:
            await query.message.edit_caption(
                caption=text, reply_markup=kb, parse_mode="HTML"
            )
        else:
            await query.message.edit_text(text, reply_markup=kb, parse_mode="HTML")
    except Exception:
        await query.message.answer(text, reply_markup=kb, parse_mode="HTML")


async def _ghostecos_avatar_path(gs_user_id: int) -> str | None:
    """Возвращает проверенный локальный путь к аватару GhostEcos."""
    if sso is None:
        return None
    try:
        profile = await asyncio.to_thread(sso.get_gs_profile_by_id, int(gs_user_id))
        avatar_url = str((profile or {}).get("avatar_url") or "").strip()
        match = re.fullmatch(
            r"(?:https://ghostecos\.duckdns\.org)?/media/avatars/([A-Za-z0-9_-]+\.(?:jpg|jpeg|png|webp))",
            avatar_url,
            flags=re.IGNORECASE,
        )
        if not match:
            return None

        avatar_path = os.path.join(
            os.getenv("GHOSTECOS_AVATAR_DIR", "/opt/ghostchat/media/avatars"),
            match.group(1),
        )
        return avatar_path if os.path.isfile(avatar_path) else None
    except Exception:
        log.exception("Не удалось получить локальный аватар GhostEcos ID %s", gs_user_id)
        return None


async def _render_profile(
    query: CallbackQuery,
    text: str,
    keyboard: InlineKeyboardMarkup,
    gs_user_id: int | None = None,
):
    message = query.message
    image_path = (
        await _ghostecos_avatar_path(gs_user_id)
        if gs_user_id and message and message.chat.type == "private"
        else None
    )

    if image_path and message:
        photo = FSInputFile(image_path)
        media = InputMediaPhoto(media=photo, caption=text, parse_mode="HTML")
        if message.photo:
            try:
                await message.edit_media(media=media, reply_markup=keyboard)
                return
            except Exception:
                log.debug("Не удалось обновить фото сообщения профиля; отправлю новое")

        try:
            await message.answer_photo(
                photo=photo,
                caption=text,
                reply_markup=keyboard,
                parse_mode="HTML",
            )
        except Exception:
            log.exception("Не удалось отправить аватар профиля; оставляю текстовый профиль")
            await edit_or_answer(query, text, keyboard)
            return

        try:
            await message.delete()
        except Exception:
            pass
        return

    if message and message.photo:
        try:
            await message.edit_caption(
                caption=text, reply_markup=keyboard, parse_mode="HTML"
            )
            return
        except Exception:
            log.debug("Не удалось заменить подпись фото профиля; отправлю текст")

        try:
            await message.answer(text, reply_markup=keyboard, parse_mode="HTML")
        except Exception:
            log.exception("Не удалось отправить текстовый профиль")
            return
        try:
            await message.delete()
        except Exception:
            pass
        return

    await edit_or_answer(query, text, keyboard)


@dp.callback_query(F.data == "main_menu")
async def cb_main_menu(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    text = await format_main_menu_text(uid)
    keyboard = main_menu_keyboard(
        show_back=uid in last_answer_snapshot,
        user_id=uid,
    )
    if query.message and query.message.photo:
        try:
            await query.message.delete()
        except Exception:
            pass
        await query.message.answer(text, reply_markup=keyboard, parse_mode="HTML")
    else:
        await edit_or_answer(query, text, keyboard)


@dp.callback_query(F.data == "profile")
async def cb_profile(query: CallbackQuery):
    await query.answer()
    user = query.from_user
    tg_name = user.full_name or f"id {user.id}"
    tg_identity = f"{tg_name} · @{user.username}" if user.username else f"{tg_name} · id {user.id}"
    ref_link = f"https://t.me/ghogembot?start=ref{user.id}"
    link = None
    link_error = False
    try:
        link = await db.get_user_ghostecos(user.id)
    except Exception:
        link_error = True
        log.exception("Не удалось прочитать GhostEcos-профиль Telegram %s из БД бота", user.id)

    if link:
        gs_username = html.escape(str(link.get("gs_username") or link.get("gs_user_id") or "аккаунт"))
        gs_user_id = html.escape(str(link.get("gs_user_id") or "—"))
        text = (
            "👤 <b>Профиль</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            f"👻 GhostEcos: <b>@{gs_username.lstrip('@')}</b> · ID <code>{gs_user_id}</code>\n"
            f"📱 Telegram: {html.escape(tg_identity)}\n"
            f"🔗 Реферальная ссылка: <code>{html.escape(ref_link)}</code>\n\n"
            "✅ Чаты и файлы бота и сайта общие."
        )
        if query.message and query.message.chat.type == "private" and sso is not None:
            keyboard = ghostecos_linked_keyboard()
        else:
            keyboard = back_to_menu_keyboard()
    else:
        text = (
            "👤 <b>Профиль</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "📱 Аккаунт бота: <b>Telegram</b>\n"
            f"👤 {html.escape(tg_identity)}\n"
            f"🔗 Реферальная ссылка: <code>{html.escape(ref_link)}</code>\n\n"
            + (
                "⚠️ Не удалось проверить привязку GhostEcos. Попробуй позже."
                if link_error or sso is None
                else "GhostEcos не подключён. Нажми кнопку ниже: после входа аккаунт свяжется с Telegram."
            )
        )
        if query.message and query.message.chat.type == "private" and sso is not None:
            keyboard = ghostecos_webapp_keyboard()
            keyboard.inline_keyboard.append([
                InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")
            ])
        else:
            keyboard = back_to_menu_keyboard()
    await _render_profile(
        query,
        text,
        keyboard,
        int(link["gs_user_id"]) if link and link.get("gs_user_id") else None,
    )


@dp.callback_query(F.data == "ghostecos_already_logged_in")
async def cb_ghostecos_already_logged_in(query: CallbackQuery):
    if sso is None:
        await query.answer("Не удалось проверить вход в GhostEcos.", show_alert=True)
        return
    try:
        link = await asyncio.to_thread(sso.link_by_tg, query.from_user.id)
    except Exception:
        log.exception("Не удалось проверить GhostEcos-привязку по кнопке /ecos")
        await query.answer("Не удалось проверить вход. Попробуй позже.", show_alert=True)
        return

    if link:
        await query.answer("Ты уже вошёл в аккаунт GhostEcos.", show_alert=True)
    else:
        await query.answer(
            "GhostEcos уже не привязан. Открой /ecos, чтобы войти.",
            show_alert=True,
        )


@dp.callback_query(F.data == "profile_unlink")
async def cb_profile_unlink(query: CallbackQuery):
    if not query.message or query.message.chat.type != "private":
        await query.answer("Отвязка GhostID доступна в личном чате с ботом.", show_alert=True)
        return
    if sso is None:
        await query.answer("Привязка GhostEcos сейчас недоступна.", show_alert=True)
        return

    await query.answer()
    link = await asyncio.to_thread(sso.link_by_tg, query.from_user.id)
    if not link:
        await edit_or_answer(
            query,
            "GhostEcos уже не привязан к этому Telegram.",
            back_to_menu_keyboard(),
        )
        return

    gs_username = html.escape(str(link.get("gs_username") or link.get("gs_user_id")))
    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Да, отвязать", callback_data="profile_unlink_yes")],
        [InlineKeyboardButton(text="Отмена", callback_data="profile")],
    ])
    await edit_or_answer(
        query,
        f"Отвязать GhostEcos <b>@{gs_username.lstrip('@')}</b> от этого Telegram?\n\n"
        "После этого сможешь войти в нужный GhostEcos-аккаунт через профиль.",
        keyboard,
    )


@dp.callback_query(F.data == "profile_unlink_yes")
async def cb_profile_unlink_yes(query: CallbackQuery):
    if not query.message or query.message.chat.type != "private":
        await query.answer("Отвязка GhostID доступна в личном чате с ботом.", show_alert=True)
        return
    if sso is None:
        await query.answer("Привязка GhostEcos сейчас недоступна.", show_alert=True)
        return

    await query.answer()
    link = await asyncio.to_thread(sso.link_by_tg, query.from_user.id)
    if not link:
        await edit_or_answer(
            query,
            "GhostEcos уже отвязан от этого Telegram.",
            back_to_menu_keyboard(),
        )
        return

    try:
        removed = await asyncio.to_thread(sso.link_delete_by_gs, link["gs_user_id"])
    except Exception:
        log.exception("Не удалось отвязать GhostEcos для Telegram %s", query.from_user.id)
        await edit_or_answer(
            query,
            "Не удалось отвязать GhostEcos из-за ошибки сервера. Попробуй позже.",
            back_to_menu_keyboard(),
        )
        return

    if not removed:
        await edit_or_answer(
            query,
            "Привязка уже снята. Открой профиль, чтобы проверить статус.",
            back_to_menu_keyboard(),
        )
        return

    gs_username = html.escape(str(link.get("gs_username") or link.get("gs_user_id")))
    keyboard = ghostecos_webapp_keyboard()
    keyboard.inline_keyboard.append([
        InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")
    ])
    text = (
        f"🔓 GhostEcos <b>@{gs_username.lstrip('@')}</b> отвязан.\n\n"
        "Теперь Telegram можно связать с нужным аккаунтом через кнопку ниже."
    )
    if query.message and query.message.photo:
        try:
            await query.message.delete()
        except Exception:
            pass
        await query.message.answer(text, reply_markup=keyboard, parse_mode="HTML")
    else:
        await edit_or_answer(query, text, keyboard)


@dp.callback_query(F.data == "toggle_web_search")
async def cb_toggle_web_search(query: CallbackQuery):
    uid = query.from_user.id
    if uid in web_search_once:
        web_search_once.discard(uid)
        await query.answer("Веб-поиск выключен", show_alert=False)
    else:
        web_search_once.add(uid)
        await query.answer(
            "🔍 Поиск ВКЛ на следующий запрос. После ответа сбросится.",
            show_alert=True,
        )
    # Не затираем ответ ИИ: если это меню — обновим текст; иначе только кнопки
    msg_text = (query.message.text or query.message.caption or "") if query.message else ""
    is_menu = "Главное меню" in msg_text or "GhoGem · Главное" in msg_text
    if is_menu:
        text = await format_main_menu_text(uid)
        await edit_or_answer(
            query, text,
            main_menu_keyboard(show_back=uid in last_answer_snapshot, user_id=uid),
        )
        return
    # ответ ИИ / другое — обновить reply_markup
    try:
        snap = last_answer_snapshot.get(uid) or {}
        model_key = snap.get("model_key") or await get_user_model(uid)
        is_favorite = await db.is_model_favorite(uid, model_key)
        await query.message.edit_reply_markup(
            reply_markup=answer_keyboard(
                (last_bot_response.get(uid) or "")[:256] or None,
                user_id=uid,
                model_key=model_key,
                model_is_favorite=is_favorite,
                answer_chat_id=snap.get("answer_chat_id"),
                answer_id=snap.get("answer_id"),
                rating_token=snap.get("rating_token"),
            )
        )
    except Exception:
        pass


@dp.callback_query(F.data == "back_to_answer")
async def cb_back_to_answer(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    snap = last_answer_snapshot.get(uid)
    if not snap:
        await query.answer("Нет сохранённого ответа", show_alert=True)
        return
    model_key = snap.get("model_key") or await get_user_model(uid)
    kb = answer_keyboard(
        snap.get("copy_payload"),
        user_id=uid,
        model_key=model_key,
        model_is_favorite=await db.is_model_favorite(uid, model_key),
        answer_chat_id=snap.get("answer_chat_id"),
        answer_id=snap.get("answer_id"),
        rating_token=snap.get("rating_token"),
    )
    try:
        await query.message.edit_text(
            snap["text"],
            reply_markup=kb,
            parse_mode="HTML",
        )
    except Exception:
        try:
            await query.message.edit_text(
                strip_all_html(snap["text"])[:4090],
                reply_markup=kb,
            )
        except Exception:
            await query.message.answer("Не удалось вернуть ответ. Напиши что-нибудь новое.")


@dp.callback_query(F.data == "new_chat")
async def cb_new_chat(query: CallbackQuery):
    user_id = query.from_user.id
    default_key = await db.get_default_model(user_id) or ai.DEFAULT_MODEL_KEY
    if (default_key not in ai.AVAILABLE_MODELS
            or ai.is_model_retired(default_key)
            or not ai.is_model_available(default_key)):
        default_key = ai.DEFAULT_MODEL_KEY
    try:
        ai.reset_chat(user_id)
    except ValueError as error:
        await query.answer("Не удалось создать новый чат", show_alert=True)
        await edit_or_answer(
            query,
            "⚠️ <b>Не удалось подготовить новый чат.</b>\n\n"
            + html.escape(str(error)[:220]),
            InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
                [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
            ]),
        )
        return

    await query.answer()
    await persist_user_model(user_id, default_key)
    await ensure_chat_persisted(user_id)
    last_answer_snapshot.pop(user_id, None)
    short_name = default_key.split(":", 1)[1] if ":" in default_key else default_key
    await edit_or_answer(
        query,
        "💬 <b>Новый чат создан.</b>\n"
        f"🧠 Модель: <code>{html.escape(short_name)}</code>\n"
        "Папка files/ готова. Пиши!",
        main_menu_keyboard(show_back=False, user_id=user_id),
    )


CHAT_LIST_PAGE_SIZE = 15


async def _show_my_chats(query: CallbackQuery, page: int = 0):
    uid = query.from_user.id
    chats = ai.list_user_chats(uid)
    archived_count = len(ai.list_archived_chats(uid))
    limit = ai.chat_limit_for_user(uid)
    if not chats:
        await edit_or_answer(
            query,
            "📂 У тебя пока нет активных чатов.",
            InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(
                    text=f"📦 Архив · {archived_count}",
                    callback_data="archived_chats:0",
                )],
                [InlineKeyboardButton(text="💬 Новый чат", callback_data="new_chat")],
                [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
            ]),
        )
        return
    pages = max(1, (len(chats) + CHAT_LIST_PAGE_SIZE - 1) // CHAT_LIST_PAGE_SIZE)
    page = max(0, min(int(page), pages - 1))
    start = page * CHAT_LIST_PAGE_SIZE
    visible = chats[start:start + CHAT_LIST_PAGE_SIZE]
    text = (
        f"📂 <b>Твои чаты</b> · {len(chats)}/{limit}\n"
        f"Страница {page + 1}/{pages} · архив хранится 7 дней.\n\n"
    )
    rows = []
    for c in visible:
        mark = "✅ " if c.get("current") else ""
        short = c["id"][-8:]
        title = str(c.get("title") or "Новый чат")[:40]
        label = f"{mark}{title} · {c['messages']} сообщ."
        row = [InlineKeyboardButton(
            text=label[:48],
            callback_data=f"select_chat:{c['id']}",
        )]
        if not c.get("current"):
            row.append(InlineKeyboardButton(
                text="⋯",
                callback_data=f"chat_actions:{c['id']}:{page}",
            ))
        rows.append(row)
        text += (
            f"{'✅ ' if c.get('current') else '• '}<b>{html.escape(title)}</b> "
            f"<code>…{short}</code> — {c['messages']} сообщ., {c['files']} файл.\n"
        )
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton(text="◀️", callback_data=f"my_chats_page:{page-1}"))
    if page + 1 < pages:
        nav.append(InlineKeyboardButton(text="▶️", callback_data=f"my_chats_page:{page+1}"))
    if nav:
        rows.append(nav)
    rows.append([
        InlineKeyboardButton(text="💬 Новый чат", callback_data="new_chat"),
        InlineKeyboardButton(
            text=f"📦 Архив · {archived_count}",
            callback_data="archived_chats:0",
        ),
    ])
    if uid in last_answer_snapshot:
        rows.append([InlineKeyboardButton(text="◀️ Назад к ответу", callback_data="back_to_answer")])
    rows.append([InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")])
    await edit_or_answer(query, text, InlineKeyboardMarkup(inline_keyboard=rows))


@dp.callback_query(F.data == "my_chats")
async def cb_my_chats(query: CallbackQuery):
    await query.answer()
    await _show_my_chats(query, 0)


@dp.callback_query(F.data.startswith("my_chats_page:"))
async def cb_my_chats_page(query: CallbackQuery):
    try:
        page = int(query.data.split(":", 1)[1])
    except Exception:
        page = 0
    await query.answer()
    await _show_my_chats(query, page)


@dp.callback_query(F.data.startswith("chat_actions:"))
async def cb_chat_actions(query: CallbackQuery):
    parts = query.data.split(":")
    if len(parts) < 2:
        await query.answer("Некорректный чат", show_alert=True)
        return
    chat_id = parts[1]
    try:
        page = int(parts[2]) if len(parts) > 2 else 0
    except Exception:
        page = 0
    uid = query.from_user.id
    chats = {str(c["id"]): c for c in ai.list_user_chats(uid)}
    chat = chats.get(chat_id)
    if not chat:
        await query.answer("Чат уже недоступен", show_alert=True)
        return
    if chat.get("current"):
        await query.answer("Это текущий чат", show_alert=True)
        return
    title = str(chat.get("title") or "Новый чат")[:80]
    await query.answer()
    await edit_or_answer(
        query,
        "💬 <b>Действия с чатом</b>\n\n"
        f"<b>{html.escape(title)}</b>\n"
        f"Сообщений: {int(chat.get('messages') or 0)} · "
        f"файлов: {int(chat.get('files') or 0)}",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="📦 Архивировать",
                callback_data=f"archive_chat:{chat_id}",
            )],
            [InlineKeyboardButton(
                text="🗑 Удалить",
                callback_data=f"delete_chat:{chat_id}",
            )],
            [InlineKeyboardButton(
                text="↩️ Назад к чатам",
                callback_data=f"my_chats_page:{page}",
            )],
        ]),
    )


def _archive_ttl_label(seconds: int) -> str:
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours = rem // 3600
    if days:
        return f"{days} д {hours} ч"
    return f"{hours} ч"


@dp.callback_query(F.data.startswith("archive_chat:"))
async def cb_archive_chat(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    chats = {str(c["id"]): c for c in ai.list_user_chats(uid)}
    chat = chats.get(chat_id)
    if not chat:
        await query.answer("Чат не найден", show_alert=True)
        return
    if chat.get("current"):
        await query.answer("Текущий чат архивировать нельзя", show_alert=True)
        return
    title = str(chat.get("title") or "Новый чат")[:80]
    await query.answer()
    await edit_or_answer(
        query,
        f"📦 <b>Переместить чат в архив?</b>\n\n"
        f"<b>{html.escape(title)}</b>\n"
        f"Сообщений: {int(chat.get('messages') or 0)} · файлов: {int(chat.get('files') or 0)}\n\n"
        "Архив хранится 7 дней, затем чат удалится автоматически.",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="📦 Да, в архив",
                callback_data=f"archive_chat_confirm:{chat_id}",
            )],
            [InlineKeyboardButton(text="↩️ Отмена", callback_data="my_chats")],
        ]),
    )


@dp.callback_query(F.data.startswith("archive_chat_confirm:"))
async def cb_archive_chat_confirm(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    result = await asyncio.to_thread(
        ai.archive_chat, uid, chat_id, reason="manual_ui"
    )
    if result == "current":
        await query.answer("Текущий чат архивировать нельзя", show_alert=True)
        return
    if result != "archived":
        await query.answer("Чат уже перемещён или недоступен", show_alert=True)
        return
    await query.answer("Чат перемещён в архив")
    await edit_or_answer(
        query,
        "✅ <b>Чат перемещён в архив.</b>\n"
        "Он будет автоматически удалён через 7 дней.",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📦 Архив", callback_data="archived_chats:0")],
            [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
            [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
        ]),
    )


@dp.callback_query(F.data.startswith("archived_chats:"))
async def cb_archived_chats(query: CallbackQuery):
    uid = query.from_user.id
    try:
        page = int(query.data.split(":", 1)[1])
    except Exception:
        page = 0
    archived = ai.list_archived_chats(uid)
    pages = max(1, (len(archived) + CHAT_LIST_PAGE_SIZE - 1) // CHAT_LIST_PAGE_SIZE)
    page = max(0, min(page, pages - 1))
    start = page * CHAT_LIST_PAGE_SIZE
    visible = archived[start:start + CHAT_LIST_PAGE_SIZE]
    rows = []
    if not archived:
        text = "📦 <b>Архив пуст.</b>\n\nСюда автоматически попадают старые чаты при достижении лимита."
    else:
        text = (
            f"📦 <b>Архив</b> · {len(archived)}\n"
            f"Страница {page + 1}/{pages}. Каждый чат удаляется через 7 дней после архивации.\n\n"
        )
        for item in visible:
            title = str(item.get("title") or "Новый чат")[:42]
            ttl = _archive_ttl_label(item.get("seconds_left") or 0)
            text += (
                f"• <b>{html.escape(title)}</b> · "
                f"{int(item.get('messages') or 0)} сообщ. · осталось {html.escape(ttl)}\n"
            )
            rows.append([
                InlineKeyboardButton(
                    text=f"📦 {title[:32]} · {ttl}",
                    callback_data=f"archived_chat_actions:{item['id']}:{page}",
                ),
                InlineKeyboardButton(
                    text="⋯",
                    callback_data=f"archived_chat_actions:{item['id']}:{page}",
                ),
            ])
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton(text="◀️", callback_data=f"archived_chats:{page-1}"))
    if page + 1 < pages:
        nav.append(InlineKeyboardButton(text="▶️", callback_data=f"archived_chats:{page+1}"))
    if nav:
        rows.append(nav)
    rows.append([InlineKeyboardButton(text="📂 Активные чаты", callback_data="my_chats")])
    rows.append([InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")])
    await query.answer()
    await edit_or_answer(query, text, InlineKeyboardMarkup(inline_keyboard=rows))


@dp.callback_query(F.data.startswith("archived_chat_actions:"))
async def cb_archived_chat_actions(query: CallbackQuery):
    parts = query.data.split(":")
    if len(parts) < 2:
        await query.answer("Некорректный чат", show_alert=True)
        return
    chat_id = parts[1]
    try:
        page = int(parts[2]) if len(parts) > 2 else 0
    except Exception:
        page = 0
    uid = query.from_user.id
    archived = {str(x["id"]): x for x in ai.list_archived_chats(uid)}
    item = archived.get(chat_id)
    if not item:
        await query.answer("Архивный чат уже недоступен", show_alert=True)
        return
    title = str(item.get("title") or "Новый чат")[:80]
    ttl = _archive_ttl_label(item.get("seconds_left") or 0)
    await query.answer()
    await edit_or_answer(
        query,
        "📦 <b>Архивный чат</b>\n\n"
        f"<b>{html.escape(title)}</b>\n"
        f"Сообщений: {int(item.get('messages') or 0)} · "
        f"файлов: {int(item.get('files') or 0)}\n"
        f"До автоудаления: <b>{html.escape(ttl)}</b>",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="↩️ Вернуть в чаты",
                callback_data=f"restore_archived_chat:{chat_id}:{page}",
            )],
            [InlineKeyboardButton(
                text="🗑 Удалить сейчас",
                callback_data=f"delete_archived_chat:{chat_id}",
            )],
            [InlineKeyboardButton(
                text="◀️ Назад в архив",
                callback_data=f"archived_chats:{page}",
            )],
        ]),
    )


@dp.callback_query(F.data.startswith("restore_archived_chat:"))
async def cb_restore_archived_chat(query: CallbackQuery):
    parts = query.data.split(":")
    if len(parts) < 2:
        await query.answer("Некорректный чат", show_alert=True)
        return
    chat_id = parts[1]
    uid = query.from_user.id
    result = await asyncio.to_thread(ai.restore_archived_chat, uid, chat_id)
    if result == "limit":
        await query.answer(
            "Лимит активных чатов заполнен — сначала архивируй один из них.",
            show_alert=True,
        )
        return
    if result != "restored":
        await query.answer("Чат уже восстановлен или недоступен", show_alert=True)
        return
    await query.answer("Чат возвращён")
    await edit_or_answer(
        query,
        "✅ <b>Чат восстановлен из архива.</b>\n"
        "Он снова доступен в «Моих чатах».",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
            [InlineKeyboardButton(text="📦 Архив", callback_data="archived_chats:0")],
        ]),
    )


@dp.callback_query(F.data.startswith("delete_archived_chat:"))
async def cb_delete_archived_chat(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    archived = {str(x["id"]): x for x in ai.list_archived_chats(uid)}
    item = archived.get(chat_id)
    if not item:
        await query.answer("Архивный чат не найден", show_alert=True)
        return
    title = str(item.get("title") or "Новый чат")[:80]
    await query.answer()
    await edit_or_answer(
        query,
        f"🗑 <b>Удалить архивный чат сейчас?</b>\n\n"
        f"<b>{html.escape(title)}</b>\n"
        "История и файлы будут удалены без ожидания 7 дней.",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="🗑 Да, удалить",
                callback_data=f"delete_archived_chat_confirm:{chat_id}",
            )],
            [InlineKeyboardButton(text="↩️ Отмена", callback_data="archived_chats:0")],
        ]),
    )


@dp.callback_query(F.data.startswith("delete_archived_chat_confirm:"))
async def cb_delete_archived_chat_confirm(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    result = await asyncio.to_thread(ai.delete_archived_chat, uid, chat_id)
    if result != "deleted":
        await query.answer("Чат уже удалён или не найден", show_alert=True)
        return
    await query.answer("Архивный чат удалён")
    await edit_or_answer(
        query,
        "✅ <b>Архивный чат удалён.</b>",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📦 Архив", callback_data="archived_chats:0")],
            [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
        ]),
    )


@dp.callback_query(F.data.startswith("delete_chat:"))
async def cb_delete_chat(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    chats = {str(c["id"]): c for c in ai.list_user_chats(uid)}
    chat = chats.get(chat_id)
    if not chat:
        await query.answer("Чат не найден", show_alert=True)
        return
    if chat.get("current"):
        await query.answer("Текущий чат удалить нельзя", show_alert=True)
        return
    title = str(chat.get("title") or "Новый чат")[:80]
    await query.answer()
    await edit_or_answer(
        query,
        f"🗑 <b>Удалить чат?</b>\n\n"
        f"<b>{html.escape(title)}</b>\n"
        f"Сообщений: {int(chat.get('messages') or 0)} · файлов: {int(chat.get('files') or 0)}\n\n"
        "История и файлы этого чата будут удалены.",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="🗑 Да, удалить",
                callback_data=f"delete_chat_confirm:{chat_id}",
            )],
            [InlineKeyboardButton(text="↩️ Отмена", callback_data="my_chats")],
        ]),
    )


@dp.callback_query(F.data.startswith("delete_chat_confirm:"))
async def cb_delete_chat_confirm(query: CallbackQuery):
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    result = await asyncio.to_thread(ai.delete_chat, uid, chat_id)
    if result == "current":
        await query.answer("Текущий чат удалить нельзя", show_alert=True)
        return
    if result != "deleted":
        await query.answer("Чат уже удалён или не найден", show_alert=True)
        return
    await query.answer("Чат удалён")
    remaining = len(ai.list_user_chats(uid))
    await edit_or_answer(
        query,
        f"✅ <b>Чат удалён.</b>\n"
        f"Теперь занято {remaining}/{ai.chat_limit_for_user(uid)}.",
        InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="💬 Новый чат", callback_data="new_chat")],
            [InlineKeyboardButton(text="📂 Мои чаты", callback_data="my_chats")],
            [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main_menu")],
        ]),
    )


@dp.callback_query(F.data.startswith("select_chat:"))
async def cb_select_chat(query: CallbackQuery):
    await query.answer()
    chat_id = query.data.split(":", 1)[1]
    uid = query.from_user.id
    ok = ai.switch_chat(uid, chat_id)
    if not ok:
        await query.answer("Чат не найден", show_alert=True)
        return
    await ensure_chat_persisted(uid)
    stats = ai.chat_stats(uid, chat_id)
    short = chat_id[-8:]
    title = ai.get_chat_title(uid, chat_id)
    text = (
        f"✅ Переключено на чат <b>{html.escape(title)}</b> <code>…{short}</code>\n"
        f"📨 Сообщений: {stats['messages']}\n"
        f"📄 Файлов: {stats['files']}\n"
        f"Можешь писать — история и files/ этого чата активны."
    )
    await edit_or_answer(query, text, main_menu_keyboard(show_back=uid in last_answer_snapshot))


@dp.callback_query(F.data == "change_model")
async def cb_change_model(query: CallbackQuery):
    user_id = query.from_user.id
    user_model_menu_mode[user_id] = "current"
    user_provider_page[user_id] = 0
    await query.answer()
    await show_model_menu(user_id, query.message.chat.id, edit_message=query.message)


@dp.callback_query(F.data == "status")
async def cb_status(query: CallbackQuery):
    await query.answer()
    # query.message.from_user — бот; статус нужен нажавшему пользователю.
    text = await format_status_text(query.from_user.id)
    await edit_or_answer(query, text, back_to_menu_keyboard())


@dp.callback_query(F.data == "files_cb")
async def cb_files(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    text = format_files_text(uid)
    await edit_or_answer(query, text, files_explorer_keyboard(uid))


@dp.callback_query(F.data == "upload_start")
async def cb_upload_start(query: CallbackQuery):
    uid = query.from_user.id
    upload_mode.add(uid)
    await query.answer("Пришли файл / фото / голосовое — сохранится в files/")
    text = format_files_text(uid) + "\n\n📥 <b>Режим загрузки включён.</b>\nПришли файл следующим сообщением или нажми «Отменить»."
    await edit_or_answer(query, text, files_explorer_keyboard(uid))


@dp.callback_query(F.data == "upload_cancel")
async def cb_upload_cancel(query: CallbackQuery):
    uid = query.from_user.id
    upload_mode.discard(uid)
    await query.answer("Загрузка отменена")
    await edit_or_answer(query, format_files_text(uid), files_explorer_keyboard(uid))


@dp.callback_query(F.data.startswith("file_menu:"))
async def cb_file_menu(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    short = query.data.split(":", 1)[1]
    name = _resolve_files_name(uid, short)
    if not name:
        await query.answer("Файл не найден", show_alert=True)
        return
    text = (
        f"📄 <b>{name}</b>\n"
        f"━━━━━━━━━━━━━━━\n"
        f"Скачать, diff, история коммитов или откат к версии.\n"
        f"<i>Git только локальный — без push.</i>"
    )
    await edit_or_answer(query, text, file_card_keyboard(uid, name))


@dp.callback_query(F.data.startswith("file_send:"))
async def cb_file_send(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    name = query.data.split(":", 1)[1]
    name = _resolve_files_name(uid, name) or name
    chat_folder = ai.get_current_chat(uid)
    try:
        path = ai.get_file_path(uid, chat_folder, name)
        if os.path.exists(path):
            await bot.send_document(query.message.chat.id, FSInputFile(path, filename=name))
            await query.answer("Отправлено")
        else:
            await query.answer("Файл не найден", show_alert=True)
    except Exception as e:
        await query.answer(f"Ошибка: {e}", show_alert=True)


@dp.callback_query(F.data == "git_status")
async def cb_git_status(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    chat_id = ai.get_current_chat(uid)
    raw = ai.git_status(uid, chat_id)
    text = format_git_panel("Статус версий", raw)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📦 Commit", callback_data="git_commit")],
        [InlineKeyboardButton(text="◀️ К файлам", callback_data="files_cb")],
    ])
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data == "git_log")
async def cb_git_log(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    chat_id = ai.get_current_chat(uid)
    raw = ai.git_log(uid, chat_id, limit=15)
    text = format_git_panel("История версий", raw)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="◀️ К файлам", callback_data="files_cb")],
    ])
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data == "git_commit")
async def cb_git_commit(query: CallbackQuery):
    uid = query.from_user.id
    chat_id = ai.get_current_chat(uid)
    msg = f"snapshot {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    raw = ai.git_commit(uid, chat_id, msg)
    await query.answer("Сохранено" if raw.startswith("✅") else "Нечего сохранять", show_alert=not raw.startswith("✅"))
    text = format_git_panel("Снимок сохранён" if raw.startswith("✅") else "Коммит", raw)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📦 Log", callback_data="git_log")],
        [InlineKeyboardButton(text="◀️ К файлам", callback_data="files_cb")],
    ])
    await edit_or_answer(query, text, kb)


@dp.callback_query(F.data.startswith("git_diff:"))
async def cb_git_diff(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    short = query.data.split(":", 1)[1]
    name = _resolve_files_name(uid, short)
    if not name:
        await query.answer("Файл не найден", show_alert=True)
        return
    chat_id = ai.get_current_chat(uid)
    raw = ai.git_diff(uid, chat_id, filename=name)
    text = format_git_panel(f"Diff · {name}", raw)
    await edit_or_answer(query, text, file_card_keyboard(uid, name))


@dp.callback_query(F.data.startswith("git_flog:"))
async def cb_git_flog(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    short = query.data.split(":", 1)[1]
    name = _resolve_files_name(uid, short)
    if not name:
        await query.answer("Файл не найден", show_alert=True)
        return
    chat_id = ai.get_current_chat(uid)
    raw = ai.git_log(uid, chat_id, limit=15, filename=name)
    text = format_git_panel(f"Версии · {name}", raw)
    await edit_or_answer(query, text, file_card_keyboard(uid, name))


@dp.callback_query(F.data.startswith("git_rlist:"))
async def cb_git_rlist(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    short = query.data.split(":", 1)[1]
    name = _resolve_files_name(uid, short)
    if not name:
        await query.answer("Файл не найден", show_alert=True)
        return
    text = (
        f"⏪ <b>Переключить версию</b>\n"
        f"<code>{_html_esc_code(name)}</code>\n"
        f"━━━━━━━━━━━━━━━\n"
        f"Выбери коммит — файл станет таким, как в этой версии.\n"
        f"<i>Только этот файл. Чтобы закрепить — потом Commit.</i>"
    )
    await edit_or_answer(query, text, git_restore_keyboard(uid, name))


@dp.callback_query(F.data.startswith("git_rst:"))
async def cb_git_rst(query: CallbackQuery):
    uid = query.from_user.id
    # git_rst:hash:name
    parts = query.data.split(":", 2)
    if len(parts) < 3:
        await query.answer("Некорректные данные", show_alert=True)
        return
    rev, short = parts[1], parts[2]
    name = _resolve_files_name(uid, short)
    if not name:
        await query.answer("Файл не найден", show_alert=True)
        return
    chat_id = ai.get_current_chat(uid)
    raw = ai.git_restore(uid, chat_id, filename=name, commit=rev)
    ok = raw.startswith("✅")
    await query.answer("Переключено" if ok else "Ошибка", show_alert=not ok)
    text = format_git_panel(f"Версия {rev} · {name}", raw)
    await edit_or_answer(query, text, file_card_keyboard(uid, name))


@dp.callback_query(F.data == "history_cb")
async def cb_history(query: CallbackQuery):
    await query.answer()
    uid = query.from_user.id
    text = format_history_text(uid)
    # длинную историю лучше кусками; первое сообщение с кнопкой назад
    chunks = split_text(text, 3500)
    kb = back_only_keyboard() if uid in last_answer_snapshot else main_menu_keyboard()
    try:
        await query.message.edit_text(chunks[0], reply_markup=kb, parse_mode="HTML")
    except Exception:
        await query.message.answer(chunks[0], reply_markup=kb, parse_mode="HTML")
    for chunk in chunks[1:]:
        await query.message.answer(chunk, parse_mode="HTML")


@dp.callback_query(F.data == "help")
async def cb_help(query: CallbackQuery):
    await query.answer()
    await edit_or_answer(query, format_help_text(), back_to_menu_keyboard())


@dp.callback_query(F.data == "continue_here")
async def cb_continue_here(query: CallbackQuery):
    await query.answer("Можешь продолжать писать в этот чат")


@dp.callback_query(F.data == "tts_last")
async def cb_tts_last(query: CallbackQuery):
    """Озвучивает последний ответ активному Premium-пользователю."""
    uid = query.from_user.id
    text = last_bot_response.get(uid) or ""
    # Убрать служебные хвосты
    text = re.sub(r"(FILE_TO_SEND|AUDIO_TO_SEND):\S+", "", text).strip()
    if not text:
        await query.answer("Нет текста для озвучки", show_alert=True)
        return
    is_prem = await db.is_subscribed(uid)
    if not ai.fish_tts_available():
        await query.answer("Озвучка временно не настроена", show_alert=True)
        return

    remaining = ai.media_quotas_v2.usage(ai.USERS_DIR,uid,is_prem)["tts"]
    if remaining["remaining"] <= 0:
        await query.answer(
            f"Лимит: {remaining['limit']} озвучиваний за час. Попробуй позже.",
            show_alert=True,
        )
        return

    await query.answer("Генерирую голос…")
    status = await bot.send_message(
        query.message.chat.id,
        f"🎙 Озвучиваю ответ…\n{ai.fish_promo_ui_text()}",
        parse_mode="HTML",
    )
    saved = await ai.media_services_v2.speech_to_media(
        ai,uid,is_prem,text,chat_id=ai.get_current_chat(uid)
    )
    try:
        await status.delete()
    except Exception:
        pass
    if saved.get("error"):
        await bot.send_message(query.message.chat.id, saved["error"])
        return
    filepath = ai.storage_v2.temp_path(
        ai.USERS_DIR,uid,saved["name"],"media"
    )
    balance = ai.media_quotas_v2.usage(ai.USERS_DIR,uid,is_prem)["tts"]["remaining"]
    caption = f"🎙 Озвучка · GhoGemo\nОсталось в этом часу: {balance}"
    try:
        await bot.send_voice(
            query.message.chat.id,
            FSInputFile(filepath,filename="ghogem.mp3"),
            caption=caption,
        )
    except Exception:
        try:
            await bot.send_audio(
                query.message.chat.id,
                FSInputFile(filepath,filename="ghogem.mp3"),
                caption=caption,
            )
        except Exception as exc:
            await bot.send_message(
                query.message.chat.id,
                f"⚠️ Озвучка создана, но отправка не удалась: {str(exc)[:160]}. "
                f"Файл доступен через /media: {saved['name']}"
            )


@dp.callback_query(F.data == "agent:send-followups")
async def cb_send_inline_followups(query: CallbackQuery):
    run = active_agent_runs.get(query.from_user.id)
    current_msg = query.message
    if (not run or run.get("kind") != "prompt" or not current_msg
            or run.get("chat_id") != current_msg.chat.id
            or run.get("message_id") != current_msg.message_id):
        await query.answer("Этот запуск уже завершён.", show_alert=True)
        return
    buffered = list(run.get("followups") or [])
    if not buffered:
        await query.answer("Нет сообщений для досыла.")
        return
    task = run.get("task")
    run.get("followups", []).clear()
    if task and task.done():
        run["accept_followups"] = False
        pending_requests.appendleft(QueuedRequest(
            query.from_user.id,
            int(run["chat_id"]),
            _followup_prompt(buffered),
            None,
            time.time(),
            _followup_attachment(buffered),
            str(run.get("ai_chat_id") or ai.get_current_chat(query.from_user.id)),
        ))
        await query.answer(f"Ответ уже завершён — отправляю следом · {len(buffered)}")
        return
    run["cancel_payload"] = buffered
    run["cancel_reason"] = "send-followups"
    if task and not task.done():
        task.cancel()
    await query.answer(f"Досылаю сообщений: {len(buffered)}")


@dp.callback_query(F.data == "agent:separate-followups")
async def cb_send_inline_followups_separately(query: CallbackQuery):
    user_id = query.from_user.id
    run = active_agent_runs.get(user_id)
    current_msg = query.message
    if (not run or run.get("kind") != "prompt" or not current_msg
            or run.get("chat_id") != current_msg.chat.id
            or run.get("message_id") != current_msg.message_id):
        await query.answer("Этот запуск уже завершён.", show_alert=True)
        return
    buffered = list(run.get("followups") or [])
    if not buffered:
        await query.answer("Нет сообщений для отправки.")
        return
    run.get("followups", []).clear()
    separate_status = None
    try:
        separate_status = await bot.send_message(
            int(run["chat_id"]),
            "💬 <b>Отдельный вопрос</b>\n"
            f"Сообщений: {len(buffered)}\n"
            "Запущу сразу после текущей задачи.",
            parse_mode="HTML",
            reply_markup=queue_keyboard(),
        )
    except Exception:
        separate_status = None
    pending_requests.appendleft(QueuedRequest(
        user_id,
        int(run["chat_id"]),
        _followup_prompt(buffered, separate=True),
        separate_status,
        time.time(),
        _followup_attachment(buffered),
        str(run.get("ai_chat_id") or ai.get_current_chat(user_id)),
    ))
    refresh = run.get("refresh")
    if refresh:
        try:
            await refresh(force=True)
        except Exception:
            pass
    await query.answer(f"Поставил отдельным вопросом · {len(buffered)}")


@dp.callback_query(F.data == "agent:stop")
async def cb_stop_active_agent(query: CallbackQuery):
    run=active_agent_runs.get(query.from_user.id)
    current_msg=query.message
    if (not run or not current_msg
            or run["chat_id"]!=current_msg.chat.id
            or run["message_id"]!=current_msg.message_id
            or run["task"].done()):
        await query.answer("Этот ответ уже завершён или недоступен.",show_alert=True)
        return
    run["cancel_reason"] = "stop-all"
    run.get("followups", []).clear()
    run["cancel_payload"] = []
    run["task"].cancel()
    await query.answer("Останавливаю всё…")


@dp.callback_query(F.data == "cancel")
async def cb_cancel(query: CallbackQuery):
    cancelled = await cancel_user_request(query.from_user.id, notify=query)
    await query.answer("Отменено" if cancelled else "Запрос уже не в очереди")


@dp.callback_query(F.data == "none")
async def cb_none(query: CallbackQuery):
    await query.answer()


async def cancel_user_request(user_id: int, notify: Message | CallbackQuery | None):
    for req in list(pending_requests):
        if req.user_id == user_id:
            pending_requests.remove(req)
            # If a generation is still running, keep the processing guard;
            # otherwise another queued follow-up could start in parallel.
            if user_status.get(user_id) != "processing" and not any(
                queued.user_id == user_id for queued in pending_requests
            ):
                user_status.pop(user_id, None)
            if req.status_message:
                try:
                    await req.status_message.edit_text("❌ Запрос отменён.")
                except Exception:
                    pass
            return True
    run=active_agent_runs.get(user_id)
    if run and not run["task"].done():
        run["task"].cancel()
        return True
    return False


async def _reminders_list_payload(user_id: int, chat_id: int, page: int = 0):
    """Unified owner-wide list across all GhoGemo chats (not origin chat)."""
    tasks = await reminders.list_owned(user_id, limit=100)
    if not tasks:
        return "🗓 У тебя пока нет активных заданий. Они будут общими для всех твоих чатов.", None
    page=max(0,min(int(page),50))
    page_size=7
    offset=page*page_size
    if offset>=len(tasks):
        page=max(0,(len(tasks)-1)//page_size)
        offset=page*page_size
    shown=tasks[offset:offset+page_size]
    lines=[
        "🗓 <b>Твои напоминания</b>",
        "Одна общая коллекция для всех твоих чатов.",
        f"Заданий: {len(tasks)} · Страница: {page+1}/{(len(tasks)-1)//page_size+1}",
        "",
    ]
    rows=[]
    for task in shown:
        task_timezone = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
        due = datetime.fromtimestamp(
            int(task["run_at"]), reminders.timezone_obj(task_timezone)
        )
        tz_label = reminders.timezone_label(task_timezone, due)
        state={
            "pending":"⏳ ждёт подтверждения",
            "scheduled":"✅ активно",
            "running":"🛠 выполняется",
            "editing":"✏️ редактируется",
        }.get(task["status"],task["status"])
        title=html.escape(str(task.get("title") or "Задание")[:65])
        mode="💬" if task.get("execution_mode")=="text" else "🤖"
        lines.append(
            f"• {mode} <b>{title}</b>\n"
            f"  Следующее: {due.strftime('%d.%m.%Y %H:%M')} "
            f"{html.escape(tz_label)} · {state}"
        )
        rows.append([InlineKeyboardButton(
            text=f"👁 {str(task.get('title') or 'Задание')[:29]}",
            callback_data=f"task:view:{task['id']}",
        )])
        controls=[]
        if task["status"]=="pending":
            controls=[
                InlineKeyboardButton(text="✅ Подтвердить",callback_data=f"task:confirm:{task['id']}"),
                InlineKeyboardButton(text="❌ Отменить",callback_data=f"task:cancel:{task['id']}"),
            ]
        elif task["status"]=="scheduled":
            controls=[
                InlineKeyboardButton(text="⏭ Пропустить одно",callback_data=f"task:skip-next:{task['id']}"),
                InlineKeyboardButton(text="✏️ Изменить",callback_data=f"task:edit:{task['id']}"),
                InlineKeyboardButton(text="❌ Отменить",callback_data=f"task:cancel:{task['id']}"),
            ]
        if controls:
            rows.append(controls)
    navigation=[]
    if page>0:
        navigation.append(InlineKeyboardButton(
            text="◀️",callback_data=f"task:list-page:{page-1}"))
    if offset+page_size<len(tasks):
        navigation.append(InlineKeyboardButton(
            text="▶️",callback_data=f"task:list-page:{page+1}"))
    if navigation:
        rows.append(navigation)
    return "\n".join(lines),InlineKeyboardMarkup(inline_keyboard=rows)


def _reminder_detail_controls(task: dict) -> InlineKeyboardMarkup:
    rows=[]
    task_id=task["id"]
    if task["status"]=="scheduled":
        rows.append([
            InlineKeyboardButton(text="⏭ Пропустить ближайшее",
                                 callback_data=f"task:skip-next:{task_id}"),
            InlineKeyboardButton(text="✏️ Изменить",
                                 callback_data=f"task:edit:{task_id}"),
        ])
    elif task["status"]=="pending":
        rows.append([
            InlineKeyboardButton(text="✅ Подтвердить",
                                 callback_data=f"task:confirm:{task_id}"),
        ])
    if task["status"] in ("pending","scheduled"):
        rows.append([
            InlineKeyboardButton(text="❌ Отменить задание",
                                 callback_data=f"task:cancel:{task_id}"),
        ])
    rows.append([
        InlineKeyboardButton(text="◀️ К общему списку",
                             callback_data="task:list-page:0"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def _refresh_reminders_list_message(message: Message, user_id: int):
    text, keyboard = await _reminders_list_payload(user_id, message.chat.id)
    try:
        await message.edit_text(text, reply_markup=keyboard, parse_mode="HTML")
    except Exception:
        log.debug("reminders list message could not be refreshed", exc_info=True)


async def handle_reminder_callback(query: CallbackQuery):
    parts = (query.data or "").split(":")
    if len(parts) != 3:
        await query.answer("Некорректное задание", show_alert=True)
        return
    _, action, task_id = parts
    expected_skip_at = None
    if action == "skip-confirm" and "-" in task_id:
        task_id, raw_run_at = task_id.rsplit("-",1)
        try:
            expected_skip_at=int(raw_run_at)
        except (ValueError,TypeError):
            await query.answer("Некорректная дата пропуска",show_alert=True)
            return
    message=query.message
    if not message:
        await query.answer("Сообщение недоступно",show_alert=True)
        return
    if action == "list-page":
        try:
            page=int(task_id)
            if not 0<=page<=50:
                raise ValueError("Недопустимая страница")
            content,keyboard=await _reminders_list_payload(
                query.from_user.id,message.chat.id,page=page
            )
            await query.answer()
            await edit_or_answer(query,content,keyboard)
        except Exception:
            await query.answer("Не удалось обновить список",show_alert=True)
        return

    task = await reminders.get_owned(task_id,query.from_user.id)
    if not task:
        await query.answer("Это задание не найдено среди твоих напоминаний.",show_alert=True)
        return
    is_config_card = (
        int(task.get("telegram_chat_id") or 0) == int(message.chat.id)
        and int(task.get("config_message_id") or 0) == int(message.message_id)
    )

    if action == "legacy":
        if task["status"] != "pending":
            await query.answer("Эта карточка уже обработана.", show_alert=True)
            try:
                await message.edit_text("Карточка задания уже обработана.")
            except Exception:
                pass
            return
        old_message_id = int(task.get("config_message_id") or 0)
        try:
            regular = await bot.send_message(
                message.chat.id,
                reminder_card_text(task),
                parse_mode="HTML",
                reply_markup=reminder_keyboard(task),
            )
            await reminders.set_config_message(
                task_id, query.from_user.id, regular.message_id
            )
            await reminders.set_legacy_ui(
                task_id, query.from_user.id, True
            )
            if old_message_id and old_message_id != regular.message_id:
                try:
                    await bot.delete_message(message.chat.id, old_message_id)
                except Exception:
                    log.debug(
                        "Could not delete incompatible rich reminder card",
                        exc_info=True,
                    )
            await query.answer("Обычная версия включена")
            try:
                await message.edit_text(
                    "✅ Обычная версия карточки открыта. "
                    "Кнопки теперь находятся под сообщением."
                )
            except Exception:
                pass
        except Exception:
            log.exception("Could not switch reminder card to legacy mode")
            await query.answer(
                "Не удалось открыть обычную версию. Попробуй ещё раз.",
                show_alert=True,
            )
        return

    if action == "view":
        await query.answer()
        await bot.send_message(
            message.chat.id,
            reminder_card_text(task),
            parse_mode="HTML",
            reply_markup=_reminder_detail_controls(task),
        )
        return

    if action == "skip-next":
        if task["status"]!="scheduled":
            await query.answer("Можно пропустить только ожидающее подтверждённое задание.",show_alert=True)
            return
        when=reminders.format_run_at(
            task["run_at"],
            task.get("timezone_name") or reminders.DEFAULT_TIMEZONE,
        )
        await query.answer()
        await bot.send_message(
            message.chat.id,
            f"⏭ <b>Пропустить ближайшее срабатывание?</b>\n\n"
            f"<b>{html.escape(str(task['title'])[:120])}</b>\n"
            f"Ближайшее: {html.escape(when)}\n\n"
            "Пропускается <b>только один</b> запуск. "
            "Будущие повторы останутся. Для разового задания это завершение.",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="⏭ Да, пропустить один раз",
                                      callback_data=f"task:skip-confirm:{task_id}-{task['run_at']}")],
                [InlineKeyboardButton(text="Нет, оставить",
                                      callback_data="task:list-page:0")],
            ]),
        )
        return

    if action == "skip-confirm":
        if expected_skip_at is None:
            await query.answer("Открой свежее подтверждение пропуска.",show_alert=True)
            return
        outcome=await reminders.skip_next(
            query.from_user.id,task_id,expected_run_at=expected_skip_at
        )
        wake_reminder_scheduler()
        if not outcome["ok"]:
            if outcome["reason"]=="stale":
                await query.answer("Ближайшее срабатывание уже изменилось. Открой карточку заново.",show_alert=True)
                return
            await query.answer("Задание уже выполняется, изменено или недоступно.",show_alert=True)
            return
        updated=outcome["task"]
        task_timezone = updated.get("timezone_name") or reminders.DEFAULT_TIMEZONE
        old=reminders.format_run_at(outcome["skipped_at"], task_timezone)
        next_label=(f"Следующее: {html.escape(reminders.format_run_at(updated['run_at'], task_timezone))}"
                    if updated["status"]=="scheduled"
                    else "Последнее срабатывание пропущено — задание завершено.")
        await query.answer("Пропущено одно срабатывание")
        await edit_or_answer(
            query,
            f"✅ Пропущено одно срабатывание: {html.escape(old)}\n"
            f"{next_label}",
            _reminder_detail_controls(updated),
        )
        if updated.get("config_message_id"):
            await refresh_reminder_card(updated,status="⏭ Ближайшее срабатывание пропущено")
        return

    if action == "confirm":
        result = await reminders.confirm(task_id, query.from_user.id)
        wake_reminder_scheduler()
        if not result["ok"]:
            reason = result["reason"]
            text = {
                "expired": "Черновик истёк. Создай задание заново.",
                "time_passed": "Срок уже близко или прошёл. Измени дату или время.",
                "not_pending": "Это задание уже обработано.",
                "replacement_missing": "Исходное задание изменилось. Открой /reminders и попробуй снова.",
            }.get(reason, "Не удалось подтвердить задание.")
            await query.answer(text, show_alert=True)
            if reason == "expired":
                expired = await reminders.get_task(task_id)
                if expired:
                    await refresh_reminder_card(expired, status="⌛ Черновик истёк")
            return
        reminder_edits.pop(query.from_user.id, None)
        await query.answer("Задание подтверждено")
        confirmed = result["task"]
        confirmation_status = (
            "✅ Изменения подтверждены"
            if confirmed.get("replaces_id") else "✅ Задание подтверждено"
        )
        await refresh_reminder_card(confirmed, status=confirmation_status)
        if not is_config_card:
            await _refresh_reminders_list_message(message, query.from_user.id)
        return

    if action == "cancel":
        ok, updated = await reminders.cancel(task_id, query.from_user.id)
        wake_reminder_scheduler()
        if not ok:
            await query.answer("Задание уже запущено или отменено.", show_alert=True)
            return
        reminder_edits.pop(query.from_user.id, None)
        await query.answer("Задание отменено")
        if updated:
            await refresh_reminder_card(updated, status="❌ Задание отменено")
        if not is_config_card:
            await _refresh_reminders_list_message(message, query.from_user.id)
        return

    if action == "edit":
        if task["status"] != "scheduled":
            await query.answer("Это задание уже нельзя изменить.", show_alert=True)
            return
        is_premium = await db.is_subscribed(query.from_user.id)
        draft = None
        try:
            draft = await reminders.create_edit_draft(
                task_id, query.from_user.id, max_active=30 if is_premium else 10
            )
            card, used_rich = await send_reminder_card(
                message.chat.id, draft, status="✏️ Черновик изменений",
            )
            await reminders.set_config_message(
                draft["id"], query.from_user.id, card.message_id
            )
            if used_rich:
                await _send_reminder_legacy_notice(
                    message.chat.id, str(draft["id"])
                )
        except Exception as error:
            if draft:
                await reminders.cancel(draft["id"], query.from_user.id)
            await query.answer(str(error)[:180], show_alert=True)
            return
        await query.answer("Открыл черновик изменений")
        await _refresh_reminders_list_message(message, query.from_user.id)
        return

    if action == "mode-menu":
        if task["status"] != "pending":
            await query.answer("Изменить режим можно через черновик задания.", show_alert=True)
            return
        await query.answer()
        keyboard = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(
                text="💬 Текст — отправить сообщение без ИИ",
                callback_data=f"task:mode-text:{task_id}",
            )],
            [InlineKeyboardButton(
                text="🤖 Промпт ИИ — выполнить инструкцию",
                callback_data=f"task:mode-ai:{task_id}",
            )],
            [InlineKeyboardButton(text="◀️ Вернуться к карточке",
                                  callback_data=f"task:mode-back:{task_id}")],
        ])
        await bot.send_message(
            message.chat.id,
            "Выбери способ выполнения задания:\n\n"
            "💬 <b>Текст:</b> бот отправит сообщение дословно, без обращения к нейросети.\n"
            "🤖 <b>Промпт ИИ:</b> модель запустится в назначенное время и выполнит инструкцию.",
            parse_mode="HTML", reply_markup=keyboard,
        )
        return

    if action == "mode-back":
        await query.answer()
        return

    if action in ("mode-ai", "mode-text"):
        if task["status"] != "pending":
            await query.answer("Режим можно изменять только в черновике.", show_alert=True)
            return
        selected = "ai" if action == "mode-ai" else "text"
        updated = await reminders.update_draft(
            task_id, query.from_user.id, execution_mode=selected
        )
        if not updated:
            await query.answer("Черновик уже недоступен.", show_alert=True)
            return
        await query.answer("Выбран режим ИИ" if selected == "ai" else "Выбран текстовый режим")
        await refresh_reminder_card(updated)
        return

    if action in ("edit-title", "edit-instruction", "edit-time", "edit-ai", "edit-schedule", "edit-days"):
        if task["status"] != "pending":
            await query.answer("Редактировать можно только черновик.", show_alert=True)
            return
        field = {
            "edit-title": "title",
            "edit-instruction": "instruction",
            "edit-time": "time",
            "edit-ai": "ai",
            "edit-schedule": "schedule",
            "edit-days": "days_count",
        }[action]
        reminder_edits[query.from_user.id] = {
            "task_id": task_id,
            "field": field,
            "chat_id": message.chat.id,
        }
        await query.answer()
        task_timezone = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
        prompts = {
            "title": "Пришли новое короткое название задания.",
            "instruction": (
                "Пришли новое сообщение напоминания одним сообщением."
                if task.get("execution_mode") == "text"
                else "Пришли новую инструкцию для модели одним сообщением."
            ),
            "time": (
                "Пришли новый разовый срок: ДД.ММ.ГГГГ ЧЧ:ММ. "
                f"Часовой пояс этой карточки: <code>{html.escape(task_timezone)}</code>. "
                "Для нескольких времён используй «Свой график»."
            ),
            "days_count": (
                "📆 <b>Повторять N дней</b>\n\n"
                "Сколько календарных дней повторять? Пришли число от 1 до 3660.\n"
                "Например: <code>3</code>\n\n"
                "Можно также сразу прислать все настройки: "
                "<code>3; да; 15:00, 19:00</code> "
                "или <code>3; нет; 15:00, 19:00</code>."
            ),
            "schedule": (
                "Пришли диапазон и все часы, например:\n"
                "<code>30.09.2026–02.10.2026; 15:00, 19:00</code>\n\n"
                "Или полный JSON-календарь с mode, start_date, end_date, times, "
                "weekdays, dates, exclude_dates, count. "
                "Можно выбрать «Изменить с ИИ» и описать расписание словами."
            ),
            "ai": "Опиши, что поменять в задании. ИИ подготовит обновлённую карточку, а задание изменится только после твоего подтверждения.",
        }
        await bot.send_message(message.chat.id, prompts[field], parse_mode="HTML")
        return

    if action in ("days-include", "days-exclude"):
        active = reminder_edits.get(query.from_user.id) or {}
        if (task.get("status") != "pending"
                or active.get("field") != "days_inclusion"
                or active.get("task_id") != task_id
                or active.get("chat_id") != message.chat.id):
            await query.answer("Настройка устарела, открой «N дней» заново.",
                               show_alert=True)
            return
        active["include_today"] = (action == "days-include")
        active["field"] = "days_times"
        await query.answer("Сегодня включено" if active["include_today"] else "Начнётся завтра")
        await bot.send_message(
            message.chat.id,
            f"🕒 Теперь укажи время для {active['days_count']} дней. "
            f"Часовой пояс: <code>{html.escape(str(task.get('timezone_name') or reminders.DEFAULT_TIMEZONE))}</code>.\n"
            "Можно несколько значений через запятую, например: "
            "<code>15:00, 19:00</code>.",
            parse_mode="HTML",
        )
        return

    if action == "repeat-menu":
        if task["status"] != "pending":
            await query.answer("Сначала открой черновик задания.", show_alert=True)
            return
        await query.answer()
        try:
            await message.edit_reply_markup(reply_markup=reminder_repeat_keyboard(task))
        except Exception:
            log.exception("Не удалось показать варианты повтора")
        return

    if action == "repeat-back":
        if task["status"] == "pending":
            await query.answer()
            await refresh_reminder_card(task)
        else:
            await query.answer("Черновик уже обработан.", show_alert=True)
        return

    if action.startswith("repeat-"):
        if task["status"] != "pending":
            await query.answer("Редактировать можно только черновик.", show_alert=True)
            return
        repeat = action.removeprefix("repeat-")
        if repeat == "ndays":
            reminder_edits[query.from_user.id] = {
                "task_id": task_id,
                "field": "days_count",
                "chat_id": message.chat.id,
            }
            await query.answer()
            await bot.send_message(
                message.chat.id,
                "📆 <b>Повторять N дней подряд</b>\n"
                "Сколько дней? Отправь число, например <code>3</code>.\n"
                "Затем выберешь, учитывать ли сегодня, и задашь часы.\n"
                "Быстрый ввод: <code>3; да; 15:00, 19:00</code>.",
                parse_mode="HTML",
            )
            return
        if repeat == "custom":
            reminder_edits[query.from_user.id] = {
                "task_id": task_id,
                "field": "weekdays",
                "chat_id": message.chat.id,
            }
            await query.answer()
            await bot.send_message(
                message.chat.id,
                "Пришли дни недели через запятую, например: Пн, Ср, Пт.",
            )
            return
        try:
            updated = await reminders.update_draft(
                task_id, query.from_user.id, recurrence=repeat, weekdays=[]
            )
        except (ValueError, TypeError) as error:
            await query.answer(str(error)[:180], show_alert=True)
            return
        if not updated:
            await query.answer("Черновик уже обработан.", show_alert=True)
            return
        await query.answer("Повтор обновлён")
        await refresh_reminder_card(updated)
        return

    await query.answer("Неизвестное действие", show_alert=True)


dp.callback_query.register(handle_reminder_callback, F.data.startswith("task:"))


async def handle_reminder_edit_message(message: Message) -> bool:
    user_id = message.from_user.id
    state = reminder_edits.get(user_id)
    if not state or int(state["chat_id"]) != message.chat.id:
        return False
    value = (message.text or "").strip()
    if not value:
        await message.reply("Пришли непустое значение.")
        return True

    try:
        current = await reminders.get_task(state["task_id"])
        if not current or current["status"] != "pending":
            reminder_edits.pop(user_id, None)
            await message.reply("Этот черновик уже обработан. Открой /reminders и создай новый.")
            return True
        field = state["field"]
        task_timezone = str(current.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
        task_zone = reminders.timezone_obj(task_timezone)
        if field == "time":
            try:
                run_at = reminders.parse_run_at(
                    value, timezone_name=task_timezone
                )
            except ValueError:
                parsed = datetime.strptime(value, "%d.%m.%Y %H:%M")
                run_at = int(parsed.replace(tzinfo=task_zone).timestamp())
            task = await reminders.update_draft(
                state["task_id"], user_id, run_at=run_at
            )
        elif field == "weekdays":
            days = reminders.parse_weekdays(value)
            task = await reminders.update_draft(
                state["task_id"], user_id, recurrence="custom", weekdays=days
            )
        elif field == "days_count":
            if ";" in value:
                schedule = reminders.schedule_v2.parse_user_schedule(
                    value, timezone_name=task_timezone
                )
                if schedule.get("relative_filter") != "next_days":
                    raise ValueError("Пример: 3; да; 15:00, 19:00.")
                task = await reminders.update_draft(
                    state["task_id"], user_id, schedule=schedule
                )
            else:
                if not value.isascii() or not value.isdigit():
                    raise ValueError("Укажи число дней, например 3.")
                days = int(value)
                if not 1 <= days <= 3660:
                    raise ValueError("Выбери от 1 до 3660 дней.")
                state["days_count"] = days
                state["field"] = "days_inclusion"
                keyboard = InlineKeyboardMarkup(inline_keyboard=[
                    [InlineKeyboardButton(
                        text="✅ Включить сегодня (если часы ещё впереди)",
                        callback_data=f"task:days-include:{state['task_id']}"
                    )],
                    [InlineKeyboardButton(
                        text="➡️ Начать завтра",
                        callback_data=f"task:days-exclude:{state['task_id']}"
                    )],
                ])
                await message.reply(
                    f"📆 Выбрано <b>{days} дней</b>.\n"
                    "Учитывать сегодняшний день?",
                    parse_mode="HTML", reply_markup=keyboard,
                )
                return True
        elif field == "days_times":
            times = [item.strip() for item in value.split(",") if item.strip()]
            schedule = {
                "mode":"next_days",
                "days_count":state["days_count"],
                "include_today":state["include_today"],
                "times":times,
            }
            task = await reminders.update_draft(
                state["task_id"], user_id, schedule=schedule
            )
        elif field in ("schedule", "days"):
            schedule = reminders.schedule_v2.parse_user_schedule(
                value, timezone_name=task_timezone
            )
            if field == "days" and schedule.get("relative_filter") != "next_days":
                raise ValueError("Напиши: 3; да; 15:00, 19:00 или 3; нет; 15:00, 19:00.")
            task = await reminders.update_draft(
                state["task_id"], user_id, schedule=schedule
            )
        elif field == "ai":
            changes = await ai.revise_reminder_config(
                user_id, current["model_key"], current, value
            )
            run_at = reminders.parse_run_at(
                changes["run_at"], timezone_name=task_timezone
            )
            existing_schedule = (
                json.loads(current["schedule_json"]) if current.get("schedule_json") else None
            )
            chosen_schedule = changes.get("schedule")
            if chosen_schedule is None and changes.get("repeat") == "advanced":
                chosen_schedule = existing_schedule
            if chosen_schedule is not None:
                task = await reminders.update_draft(
                    state["task_id"], user_id,
                    title=changes["title"],
                    instruction=changes["instruction"],
                    execution_mode=changes.get("execution_mode") or current.get("execution_mode") or "ai",
                    schedule=chosen_schedule,
                )
            else:
                recurrence, weekdays = reminders.normalize_recurrence(
                    changes.get("repeat") or current.get("recurrence") or "once",
                    changes.get("weekdays") or [],
                )
                task = await reminders.update_draft(
                    state["task_id"], user_id,
                    title=changes["title"],
                    instruction=changes["instruction"],
                    execution_mode=changes.get("execution_mode") or current.get("execution_mode") or "ai",
                    run_at=run_at,
                    recurrence=recurrence,
                    weekdays=weekdays,
                )
        elif field == "title":
            task = await reminders.update_draft(
                state["task_id"], user_id, title=value
            )
        else:
            task = await reminders.update_draft(
                state["task_id"], user_id, instruction=value
            )
    except (ValueError, TypeError, RuntimeError) as error:
        await message.reply(html.escape(str(error)), parse_mode="HTML")
        return True

    if not task:
        reminder_edits.pop(user_id, None)
        await message.reply("Черновик уже нельзя изменить. Создай задание заново.")
        return True

    reminder_edits.pop(user_id, None)
    await refresh_reminder_card(task)
    if state["field"] == "ai":
        await message.reply("✅ ИИ подготовил изменения. Проверь карточку и подтверди её кнопкой.")
    else:
        await message.reply("✅ Черновик обновлён. Проверь карточку и нажми «Подтвердить».")
    return True


@dp.message(Command("reminders"))
async def cmd_reminders(message: Message):
    text, keyboard = await _reminders_list_payload(message.from_user.id, message.chat.id)
    await message.answer(text, reply_markup=keyboard, parse_mode="HTML")


# ============ ФАЙЛЫ / ФОТО / АУДИО ============

async def _save_bytes_to_chat(user_id: int, filename: str, content: bytes) -> tuple[str | None, str]:
    """Store uploads in owner media, emergency buffer, or regular chat files."""
    chat_id = ai.get_current_chat(user_id)
    emergency = user_id in buffer_upload_mode
    suffix = ai.storage_v2.category(filename)
    heavy_media = (
        suffix in ai.storage_v2.AUDIO_TYPES
        or suffix in ai.storage_v2.VIDEO_TYPES
    )
    queued_media = False
    try:
        if heavy_media:
            await ai.media_services_v2.acquire_media_slot()
            queued_media = True
        entry = await asyncio.to_thread(
            ai.save_user_upload, user_id, chat_id, filename, content,
            target="buffer" if emergency else None, urgent=emergency,
        )
    except Exception as exc:
        log.warning("Upload rejected user=%s name=%s type=%s",
                    user_id, filename[:60], type(exc).__name__)
        return None, f"❌ {html.escape(str(exc)[:350])}"
    finally:
        if queued_media:
            ai.media_services_v2.release_media_slot()
    name = entry["name"]
    area = entry["area"]
    if area == "main":
        text = ai.extract_text_from_bytes(name, content)
        return entry["path"], (
            f"\n\n📄 Текст (фрагмент):\n<code>{html.escape(text[:1500])}</code>"
            if text else "📂 Основное хранилище чата."
        )
    expiration = datetime.fromtimestamp(
        entry["expires_at"], ZoneInfo("Europe/Moscow")
    ).strftime("%d.%m %H:%M МСК")
    caption = "🖼 Общее медиа" if area == "media" else "🚨 Аварийный буфер"
    compression_note = ""
    if entry.get("compressed"):
        original_size = int(entry.get("original_size") or len(content))
        compression_note = (
            f" · сжато {original_size/1048576:.2f} → "
            f"{int(entry['size'])/1048576:.2f} МБ"
        )
    note = (
        f"{caption} · {(entry['size'] / 1048576):.2f} МБ · "
        f"до {expiration}"
        + compression_note
    )
    return entry["path"], note


@dp.message(F.document)
async def handle_document(message: Message):
    """Сохраняет документ в files/ и сразу запускает разбор моделью."""
    user_id = message.from_user.id
    chat_folder = ai.get_current_chat(user_id)
    doc = message.document
    filename = doc.file_name or f"document_{int(time.time())}"
    caption = (message.caption or "").strip()
    only_save = user_id in upload_mode

    file_obj = await bot.get_file(doc.file_id)
    file_bytes = await bot.download_file(file_obj.file_path)
    content = file_bytes.read()
    result, note = await _save_bytes_to_chat(user_id, filename, content)

    if result is None:
        await message.reply(note or "❌ Не удалось сохранить файл.")
        return

    upload_mode.discard(user_id)
    buffer_upload_mode.discard(user_id)

    base = os.path.basename(result)
    await safe_react(message.chat.id, message.message_id, "📎")

    if only_save:
        await message.reply(
            f"✅ Сохранено: <code>{base}</code>\n"
            f"{html.escape(note)}",
            parse_mode="HTML",
            reply_markup=files_explorer_keyboard(user_id),
        )
        return

    # Delegate analysis decisions to the main agent, not an automatic parser.
    prompt = (
        f"Пользователь приложил файл «{base}». "
        f"Место хранения: {'общее временное хранилище' if '/media/' in result or '/buffer/' in result else 'files/ чата'}. "
        f"{note}.\n"
        "Ты главная агентская модель. Выбери задачу анализатору analyze_file, "
        "прочитай его отчёт и при необходимости вызови его снова с другой задачей "
        "или нужной страницей/участком. Лишь затем сформируй ответ пользователю.\n"
        f"Запрос пользователя: {caption or 'Посмотри, что в файле.'}\n"
    )
    await submit_prompt(
        user_id, message.chat.id, prompt, notify_message=message,
        attachment_name=base,
    )


@dp.message(F.photo)
async def handle_photo(message: Message):
    user_id = message.from_user.id
    chat_folder = ai.get_current_chat(user_id)
    photo = message.photo[-1]
    filename = f"photo_{int(time.time() * 1000)}.jpg"
    caption = (message.caption or "").strip()

    file_obj = await bot.get_file(photo.file_id)
    file_bytes = await bot.download_file(file_obj.file_path)
    content = file_bytes.read()

    # Explicit upload mode saves without running the agent.
    if user_id in upload_mode:
        result, note = await _save_bytes_to_chat(user_id, filename, content)
        upload_mode.discard(user_id)
        buffer_upload_mode.discard(user_id)
        if result is None:
            await message.reply(note or "❌ Фото не сохранено.")
        else:
            await message.reply(
                f"✅ Фото: <code>{html.escape(os.path.basename(result))}</code>\n"
                f"{html.escape(note)}", parse_mode="HTML",
                reply_markup=files_explorer_keyboard(user_id),
            )
        return

    result, note = await _save_bytes_to_chat(user_id, filename, content)
    if result is None:
        await message.reply(note or "❌ Фото не сохранено.")
        return
    buffer_upload_mode.discard(user_id)

    await safe_react(message.chat.id, message.message_id, "🖼")
    base = os.path.basename(result)
    original_request = caption or "Посмотри на фотографию и расскажи, что важно."
    prompt = (
        f"Пользователь отправил фотографию «{base}» (файл находится в общем временном хранилище пользователя).\n"
        f"Его запрос: {original_request}\n"
        "Фото является вложением ЭТОГО сообщения. Прежде чем отвечать, "
        "ОБЯЗАТЕЛЬНО вызови анализатор analyze_file для указанного имени, "
        "дождись его результата и используй его для ответа.\n"
    )
    await submit_prompt(
        user_id, message.chat.id, prompt, notify_message=message,
        attachment_name=base,
    )


@dp.message(F.voice | F.audio)
async def handle_audio(message: Message):
    """Голос/аудио: общий медиа-раздел; STT для обоих тарифов с квотами."""
    user_id = message.from_user.id
    chat_folder = ai.get_current_chat(user_id)

    if message.voice:
        file_id = message.voice.file_id
        filename = f"voice_{int(time.time())}.ogg"
    else:
        file_id = message.audio.file_id
        filename = message.audio.file_name or f"audio_{int(time.time())}.mp3"

    file_obj = await bot.get_file(file_id)
    file_bytes = await bot.download_file(file_obj.file_path)
    content = file_bytes.read()

    result, note = await _save_bytes_to_chat(user_id, filename, content)
    if result is None:
        await message.reply(note or "❌ Аудио не сохранено.")
        return
    buffer_upload_mode.discard(user_id)

    if user_id in upload_mode:
        upload_mode.discard(user_id)
        await message.reply(
            f"✅ Аудио: <code>{html.escape(os.path.basename(result))}</code>\n{html.escape(note)}",
            parse_mode="HTML",
            reply_markup=files_explorer_keyboard(user_id),
        )
        return

    base = os.path.basename(result)
    caption = (message.caption or "").strip()
    prompt = (
        f"Пользователь отправил аудиофайл «{base}», файл сохранён в общем медиахранилище.\n"
        f"Запрос пользователя: {caption or 'Изучи аудиозапись.'}\n"
        "Сформулируй задачу analyze_file. Free-анализ ограничен первыми "
        "60 сек с явным уведомлением об обрезке, Premium прослушивает "
        "длинную запись частями по 120 сек. Если лимит исчерпан, "
        "честно сообщи об этом. Отчёт анализатора — промежуточный; "
        "окончательное решение и ответ за тобой."
    )
    await submit_prompt(user_id, message.chat.id, prompt, notify_message=message,
                        attachment_name=base)


@dp.message(F.video | F.video_note | F.animation)
async def handle_video(message: Message):
    """Saved video is evaluated by the main agent using sampled frames."""
    user_id = message.from_user.id
    video = message.video or message.video_note or message.animation
    basename = (
        getattr(video, "file_name", None)
        or f"video_{int(time.time())}.mp4"
    )
    # Default to .mp4; preserve explicit extensions for supported containers.
    if not os.path.splitext(basename)[1]:
        basename += ".mp4"
    if getattr(video, "file_size", 0) and video.file_size > 20 * 1024 * 1024:
        await message.reply("❌ Telegram Bot API не позволяет скачать такой большой ролик (20 МБ). Пришли меньший фрагмент.")
        return
    file_info = await bot.get_file(video.file_id)
    data = (await bot.download_file(file_info.file_path)).read()
    saved, note = await _save_bytes_to_chat(user_id, basename, data)
    if not saved:
        await message.reply(note or "❌ Видео не сохранено.")
        return
    buffer_upload_mode.discard(user_id)
    base = os.path.basename(saved)
    if user_id in upload_mode:
        upload_mode.discard(user_id)
        await message.reply(
            f"✅ Видео сохранено: <code>{html.escape(base)}</code>\n{html.escape(note)}",
            parse_mode="HTML", reply_markup=files_explorer_keyboard(user_id),
        )
        return
    caption = (message.caption or "").strip()
    prompt = (
        f"Пользователь прислал видеоролик «{base}» в общем медиахранилище.\n"
        f"Его запрос: {caption or 'Изучи ролик и расскажи главное.'}\n"
        "Сформулируй задание analyze_file для кадров. Free анализирует только "
        "первые 20 секунд, Premium первые 60 секунд; остальные кадры не проверены. "
        "Повторный анализ того же файла не расходует новую квоту. "
        "Звук из ролика анализатор пока не получает. "
        "После результатов реши, что ответить."
    )
    await submit_prompt(user_id, message.chat.id, prompt, notify_message=message,
                        attachment_name=base)


# ============ ОСНОВНОЙ ХЕНДЛЕР СООБЩЕНИЙ ============

@dp.message(F.text)
async def handle_message(message: Message):
    user_id = message.from_user.id
    await db.touch_user(user_id)

    custom_choice = await asyncio.to_thread(
        interactive_choices.custom_for_user, user_id
    )
    if custom_choice:
        if int(custom_choice.get("telegram_chat_id") or 0) != int(message.chat.id):
            custom_choice = None
        answer = (message.text or "").strip() if custom_choice else ""
        if answer:
            consumed = await asyncio.to_thread(
                interactive_choices.consume,
                str(custom_choice["token"]),
                user_id,
                custom_only=True,
            )
            if consumed:
                try:
                    await update_interactive_choice_card(
                        consumed,
                        footer="custom_sent",
                        custom_answer=answer,
                        keep_buttons=False,
                    )
                except Exception as error:
                    log.warning(
                        "choice custom answer card update failed: %s",
                        type(error).__name__,
                    )
                prompt = interactive_choice_continue_prompt(
                    consumed,
                    answer,
                    selected_index=None,
                )
                resumed = _resolve_interactive_choice_waiter(
                    str(consumed["token"]),
                    {
                        "prompt": prompt,
                        "timeline": "✅ Пользователь написал свой ответ: " + answer,
                        "selected_index": None,
                        "answer": answer,
                    },
                )
                if not resumed:
                    await submit_prompt(
                        user_id,
                        message.chat.id,
                        prompt,
                        notify_message=message,
                        ai_chat_id_override=str(consumed["ai_chat_id"]),
                    )
                return

    if user_id in awaiting_model_search:
        q = (message.text or "").strip()
        awaiting_model_search.discard(user_id)
        if q:
            user_model_search[user_id] = q
        else:
            user_model_search.pop(user_id, None)
        user_provider_page[user_id] = 0
        text, kb = await make_provider_page(user_id, 0)
        await message.answer(text, reply_markup=kb, parse_mode="HTML")
        return

    if user_id in awaiting_timezone:
        text = (message.text or "").strip()
        if not text:
            return
        try:
            timezone_name = normalize_timezone_input(text)
        except ValueError as error:
            await message.answer(
                f"❌ {html.escape(str(error))}",
                parse_mode="HTML",
            )
            return
        await db.set_timezone(user_id, timezone_name)
        awaiting_timezone.discard(user_id)
        await message.answer(
            "✅ Часовой пояс сохранён.\n"
            f"{timezone_summary(timezone_name)}",
            parse_mode="HTML",
            reply_markup=settings_keyboard(
                has_prompt=bool(await db.get_custom_prompt(user_id))
            ),
        )
        return

    if user_id in awaiting_custom_prompt:
        text = (message.text or "").strip()
        if not text:
            return
        if len(text) > MAX_CUSTOM_PROMPT_LEN:
            await message.answer(
                f"❌ Слишком длинно ({len(text)} символов). "
                f"Максимум — {MAX_CUSTOM_PROMPT_LEN}."
            )
            return
        await db.set_custom_prompt(user_id, text)
        awaiting_custom_prompt.discard(user_id)
        await message.answer(
            "✅ Системный промпт сохранён.",
            reply_markup=settings_keyboard(has_prompt=True),
        )
        return

    if await try_handle_pending_api_key(message):
        return
    if await handle_reminder_edit_message(message):
        return
    # A time-bounded pause has priority over the verb «отключи».
    # Handle high-confidence ranges deterministically before the full-disable path.
    pause_timezone = await db.get_timezone(user_id)
    paused = await asyncio.to_thread(
        ai.reminder_access.pause_existing_direct,
        user_id, message.text or "", pause_timezone,
    )
    if paused is not None:
        await message.answer(paused["message"])
        wake_reminder_scheduler()
        for task_id in paused["paused_ids"]:
            task=await reminders.get_owned(task_id,user_id)
            if task:
                await refresh_reminder_card(
                    task,status="⏸ Напоминание временно приостановлено"
                )
        return

    # Explicit full disable is deterministic and must not depend on an LLM.
    # It runs only when there is NO temporary duration in the request.
    disabled = await asyncio.to_thread(
        ai.reminder_access.disable_existing_direct,
        user_id,message.text or "",
    )
    if disabled is not None:
        await message.answer(disabled["message"])
        for task_id in disabled["cancelled_ids"]:
            task=await reminders.get_owned(task_id,user_id)
            if task:
                await refresh_reminder_card(task,status="🛑 Напоминание отключено")
        return
    # Deterministic fallback for explicit conversion of existing reminders to
    # literal text. It works even when the selected LLM is blank or offline.
    # Other reminder edits still use the agent + update_reminder tool.
    direct = await asyncio.to_thread(
        ai.reminder_access.change_existing_to_text_direct,
        user_id,message.text or "",
    )
    if direct is not None:
        await message.answer(direct["message"])
        for task_id in direct["changed_ids"]:
            task=await reminders.get_owned(task_id,user_id)
            if task:
                await refresh_reminder_card(
                    task,status="✅ Переключено на текст без вызова ИИ"
                )
        return
    chat_id = message.chat.id
    prompt = message.text.strip()
    if not prompt:
        return
    await safe_react(chat_id, message.message_id, "👀")
    if not ai.load_history(user_id, ai.get_current_chat(user_id)) and is_greeting(prompt):
        greeting = generate_greeting(user_id)
        ai.seed_history(user_id, SYSTEM_PROMPT, prompt, greeting)
        await bot.send_message(chat_id, greeting, parse_mode="HTML")
        return
    await submit_prompt(user_id, chat_id, prompt, notify_message=message)


@dp.message()
async def handle_non_text(message: Message):
    await message.reply("🙈 Я понимаю только текстовые сообщения — пришлите промт текстом.")


# ============ ЗАПУСК ============

async def main():
    active_providers = [
        ai.PROVIDER_NAMES.get(provider, provider)
        for provider in ai.configured_providers()
    ]
    log.info(
        "🤖 Бот запущен. Провайдеры: %s. Fish TTS: %s. Модель: %s. Лимиты: %d RPM / %d RPD",
        ", ".join(active_providers) or "нет",
        "ON" if ai.fish_tts_available() else "OFF",
        ai.DEFAULT_MODEL_KEY,
        RPM_LIMIT,
        RPD_LIMIT,
    )

    await bot.set_my_commands([
        BotCommand(command="reset", description="Начать диалог заново"),
        BotCommand(command="model", description="Выбрать модель"),
        BotCommand(command="subscribe", description="Оформить Premium"),
        BotCommand(command="referrals", description="Реферальная программа"),
        BotCommand(command="files", description="Файлы в чате"),
        BotCommand(command="media", description="Общие временные медиа"),
        BotCommand(command="buffer", description="Срочный буфер"),
        BotCommand(command="history", description="История чата"),
        BotCommand(command="reminders", description="Мои задания и напоминания"),
        BotCommand(command="link", description="Привязать аккаунт GhostEcos"),
        BotCommand(command="ecos", description="Войти через GhostEcos · веб-приложение"),
        BotCommand(command="status", description="Статистика бота"),
        BotCommand(command="queue", description="Моя позиция в очереди"),
        BotCommand(command="cancel", description="Отменить запрос в очереди"),
        BotCommand(command="help", description="Помощь"),
        BotCommand(command="myprompt", description="Установить свой промт"),
        BotCommand(command="clearprompt", description="Удалить свой промт"),
    ])

    recovered = await reminders.recover_running()
    if recovered:
        log.warning("После перезапуска восстановлено заданий: %d", recovered)
    try:
        pruned_choices = await asyncio.to_thread(interactive_choices.prune)
        if pruned_choices:
            log.info("Удалено старых интерактивных вопросов: %d", pruned_choices)
    except Exception:
        log.exception("Не удалось очистить старые интерактивные вопросы")
    asyncio.create_task(process_pending_loop())
    asyncio.create_task(active_agent_watchdog_loop())
    asyncio.create_task(reminders_loop_v2())
    asyncio.create_task(cleanup_loop())
    asyncio.create_task(check_retired_models_loop())
    asyncio.create_task(ai.openrouter_model_catalog_loop())

    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
