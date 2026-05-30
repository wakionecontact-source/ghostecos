"""
OKey bot — минимальный рабочий каркас на aiogram 3.

Цель этого файла: чтобы /start точно отвечал. Без админ-панелей,
без FastAPI рядом, без сложных middleware. Только бот + БД + handlers.

Когда заработает — будем расширять (поиск анкет, рулетка, линковка с GhostEcos).
"""
import asyncio
import logging
import os
import sqlite3
import time
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

load_dotenv()

BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
PROXY_URL = os.getenv("PROXY_URL", "").strip() or None

if not BOT_TOKEN:
    print("[ERROR] BOT_TOKEN не задан в .env. Получи у @BotFather и впиши.")
    raise SystemExit(1)

# ── Логирование ──────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("okey")
logging.getLogger("aiogram.event").setLevel(logging.WARNING)

# ── БД ───────────────────────────────────────────────────────────────────────
DB_PATH = Path(__file__).parent / "okey.db"


def db_init():
    with sqlite3.connect(DB_PATH) as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            tg_id      INTEGER PRIMARY KEY,
            username   TEXT,
            name       TEXT,
            age        INTEGER,
            gender     TEXT,
            looking    TEXT,
            bio        TEXT,
            photo_id   TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """)


def db_get_user(tg_id: int) -> Optional[dict]:
    with sqlite3.connect(DB_PATH) as c:
        c.row_factory = sqlite3.Row
        r = c.execute("SELECT * FROM users WHERE tg_id=?", (tg_id,)).fetchone()
        return dict(r) if r else None


def db_save_user(tg_id: int, **fields) -> None:
    now = int(time.time())
    with sqlite3.connect(DB_PATH) as c:
        existing = c.execute("SELECT tg_id FROM users WHERE tg_id=?", (tg_id,)).fetchone()
        if existing:
            sets = ", ".join(f"{k}=?" for k in fields)
            params = list(fields.values()) + [now, tg_id]
            c.execute(f"UPDATE users SET {sets}, updated_at=? WHERE tg_id=?", params)
        else:
            cols = "tg_id, " + ", ".join(fields.keys()) + ", created_at, updated_at"
            qs = ", ".join("?" * (len(fields) + 3))
            params = [tg_id] + list(fields.values()) + [now, now]
            c.execute(f"INSERT INTO users ({cols}) VALUES ({qs})", params)


# ── aiogram setup ────────────────────────────────────────────────────────────
from aiogram import Bot, Dispatcher, F
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.filters import CommandStart, Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton,
    ReplyKeyboardMarkup, KeyboardButton,
)

if PROXY_URL:
    log.info("Прокси к Telegram: %s", PROXY_URL)
    session = AiohttpSession(proxy=PROXY_URL)
else:
    log.info("Без прокси (через систему/TUN VPN)")
    session = AiohttpSession()

bot = Bot(token=BOT_TOKEN, session=session)
dp = Dispatcher(storage=MemoryStorage())


# ── Клавиатуры ───────────────────────────────────────────────────────────────
def main_menu() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="👤 Моя анкета"), KeyboardButton(text="🔍 Поиск")],
            [KeyboardButton(text="🎲 Рулетка"), KeyboardButton(text="❓ Помощь")],
        ],
        resize_keyboard=True,
    )


def start_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📝 Заполнить анкету", callback_data="fill")],
        [InlineKeyboardButton(text="ℹ️ Что это", callback_data="about")],
    ])


def gender_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="👨 Парень", callback_data="g:m"),
        InlineKeyboardButton(text="👩 Девушка", callback_data="g:f"),
    ]])


def looking_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="👨 Парня", callback_data="l:m"),
         InlineKeyboardButton(text="👩 Девушку", callback_data="l:f")],
        [InlineKeyboardButton(text="🌈 Не важно", callback_data="l:any")],
    ])


def skip_kb(tag: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="⏭ Пропустить", callback_data=f"skip:{tag}"),
    ]])


def profile_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✏️ Изменить", callback_data="fill")],
    ])


# ── FSM анкеты ───────────────────────────────────────────────────────────────
class Form(StatesGroup):
    name = State()
    age = State()
    gender = State()
    looking = State()
    bio = State()
    photo = State()


def format_profile(u: dict) -> str:
    gender_map = {"m": "Парень", "f": "Девушка"}
    looking_map = {"m": "парня", "f": "девушку", "any": "не важно"}
    lines = [f"<b>{u.get('name') or '—'}, {u.get('age') or '?'}</b>"]
    g = gender_map.get(u.get("gender"), "?")
    l = looking_map.get(u.get("looking"), "?")
    lines.append(f"{g} · ищет: {l}")
    if u.get("bio"):
        lines.append(f"\n{u['bio']}")
    return "\n".join(lines)


# ── Handlers ─────────────────────────────────────────────────────────────────
@dp.message(CommandStart())
async def on_start(m: Message, state: FSMContext):
    await state.clear()
    log.info("/start от @%s (%s)", m.from_user.username, m.from_user.id)
    u = db_get_user(m.from_user.id)
    if u and u.get("name"):
        await m.answer(
            f"С возвращением, <b>{u['name']}</b>!\nЖми кнопку внизу или /help.",
            parse_mode="HTML",
            reply_markup=main_menu(),
        )
    else:
        await m.answer(
            "Привет! Это <b>OKey</b> — знакомства в Telegram.\n\n"
            "Заполни анкету и смотри других, лайкай, болтай в рулетке.\n\n"
            "Жми кнопку чтобы начать ↓",
            parse_mode="HTML",
            reply_markup=start_kb(),
        )
        await m.answer("Главное меню всегда внизу:", reply_markup=main_menu())


@dp.message(Command("help"))
@dp.message(F.text == "❓ Помощь")
async def on_help(m: Message):
    await m.answer(
        "<b>OKey</b> — бот знакомств.\n\n"
        "Кнопки внизу:\n"
        "👤 <b>Моя анкета</b> — посмотреть/изменить\n"
        "🔍 <b>Поиск</b> — смотреть анкеты других (скоро)\n"
        "🎲 <b>Рулетка</b> — случайный собеседник (скоро)\n"
        "❓ <b>Помощь</b> — это сообщение\n\n"
        "Команды: /start /cancel",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


@dp.message(Command("cancel"))
async def on_cancel(m: Message, state: FSMContext):
    cur = await state.get_state()
    await state.clear()
    await m.answer("Отменено." if cur else "Нечего отменять.", reply_markup=main_menu())


@dp.callback_query(F.data == "about")
async def cb_about(cq: CallbackQuery):
    await cq.answer()
    await cq.message.answer(
        "<b>OKey</b> — простой бот знакомств в Telegram.\n\n"
        "Заполнил анкету → смотришь других → лайкаешь → match → переписка.\n"
        "Плюс чат-рулетка для случайных диалогов.\n\n"
        "Никаких подписок, никакой рекламы. Просто работает.",
        parse_mode="HTML",
        reply_markup=start_kb(),
    )


# ── Wizard: запуск ───────────────────────────────────────────────────────────
@dp.callback_query(F.data == "fill")
@dp.message(F.text == "👤 Моя анкета")
async def start_wizard(event, state: FSMContext):
    """Вход в wizard — и с кнопки, и с reply-меню."""
    if isinstance(event, CallbackQuery):
        await event.answer()
        send = event.message.answer
        uid = event.from_user.id
    else:
        send = event.answer
        uid = event.from_user.id

    u = db_get_user(uid)
    # Если у юзера уже есть анкета И это reply-кнопка — показать профиль вместо wizard
    if isinstance(event, Message) and u and u.get("name"):
        text = format_profile(u)
        if u.get("photo_id"):
            await event.answer_photo(u["photo_id"], caption=text,
                                     parse_mode="HTML", reply_markup=profile_kb())
        else:
            await send(text, parse_mode="HTML", reply_markup=profile_kb())
        return

    await state.clear()
    await state.set_state(Form.name)
    await send(
        "Заполняем анкету. Жми /cancel чтобы прервать.\n\n"
        "<b>Как тебя зовут?</b>\n(только имя, 2-30 символов)",
        parse_mode="HTML",
    )


@dp.message(Form.name, F.text)
async def step_name(m: Message, state: FSMContext):
    name = m.text.strip()
    if not (2 <= len(name) <= 30):
        await m.answer("Имя 2-30 символов. Попробуй ещё:")
        return
    await state.update_data(name=name)
    await state.set_state(Form.age)
    await m.answer("Сколько тебе лет? (14-99)")


@dp.message(Form.age, F.text)
async def step_age(m: Message, state: FSMContext):
    t = m.text.strip()
    if not t.isdigit() or not (14 <= int(t) <= 99):
        await m.answer("Введи число 14-99:")
        return
    await state.update_data(age=int(t))
    await state.set_state(Form.gender)
    await m.answer("Твой пол?", reply_markup=gender_kb())


@dp.callback_query(Form.gender, F.data.startswith("g:"))
async def step_gender(cq: CallbackQuery, state: FSMContext):
    g = cq.data.split(":", 1)[1]
    if g not in ("m", "f"):
        await cq.answer("?"); return
    await state.update_data(gender=g)
    await cq.answer()
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.looking)
    await cq.message.answer("Кого ищешь?", reply_markup=looking_kb())


@dp.callback_query(Form.looking, F.data.startswith("l:"))
async def step_looking(cq: CallbackQuery, state: FSMContext):
    lf = cq.data.split(":", 1)[1]
    if lf not in ("m", "f", "any"):
        await cq.answer("?"); return
    await state.update_data(looking=lf)
    await cq.answer()
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.bio)
    await cq.message.answer(
        "Расскажи о себе (до 300 символов) или пропусти:",
        reply_markup=skip_kb("bio"),
    )


@dp.message(Form.bio, F.text)
async def step_bio(m: Message, state: FSMContext):
    await state.update_data(bio=m.text.strip()[:300])
    await state.set_state(Form.photo)
    await m.answer("Отправь своё фото или пропусти:", reply_markup=skip_kb("photo"))


@dp.callback_query(Form.bio, F.data == "skip:bio")
async def skip_bio(cq: CallbackQuery, state: FSMContext):
    await cq.answer()
    await state.update_data(bio=None)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.photo)
    await cq.message.answer("Отправь своё фото или пропусти:", reply_markup=skip_kb("photo"))


@dp.message(Form.photo, F.photo)
async def step_photo(m: Message, state: FSMContext):
    await state.update_data(photo_id=m.photo[-1].file_id)
    await finalize(m, state)


@dp.message(Form.photo, ~F.photo)
async def step_photo_wrong(m: Message):
    await m.answer("Жду именно фото (или нажми «Пропустить»):")


@dp.callback_query(Form.photo, F.data == "skip:photo")
async def skip_photo(cq: CallbackQuery, state: FSMContext):
    await cq.answer()
    await state.update_data(photo_id=None)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await finalize(cq.message, state, uid=cq.from_user.id, username=cq.from_user.username)


async def finalize(m: Message, state: FSMContext, uid: Optional[int] = None, username: Optional[str] = None):
    data = await state.get_data()
    await state.clear()
    user_id = uid if uid is not None else m.from_user.id
    uname = username if username is not None else m.from_user.username

    db_save_user(
        user_id,
        username=uname,
        name=data.get("name"),
        age=data.get("age"),
        gender=data.get("gender"),
        looking=data.get("looking"),
        bio=data.get("bio"),
        photo_id=data.get("photo_id"),
    )
    u = db_get_user(user_id)
    text = "✅ Анкета сохранена!\n\n" + format_profile(u)
    if u.get("photo_id"):
        await m.answer_photo(u["photo_id"], caption=text, parse_mode="HTML")
    else:
        await m.answer(text, parse_mode="HTML")
    await m.answer("Дальше — поиск и рулетка появятся скоро.", reply_markup=main_menu())
    log.info("Анкета сохранена tg=%s name=%s", user_id, data.get("name"))


# ── Reply-кнопки stub'ы ──────────────────────────────────────────────────────
@dp.message(F.text == "🔍 Поиск")
async def stub_search(m: Message):
    await m.answer("🔍 Поиск анкет — скоро.", reply_markup=main_menu())


@dp.message(F.text == "🎲 Рулетка")
async def stub_roulette(m: Message):
    await m.answer("🎲 Чат-рулетка — скоро.", reply_markup=main_menu())


# ── Fallback ─────────────────────────────────────────────────────────────────
@dp.message()
async def fallback(m: Message, state: FSMContext):
    cur = await state.get_state()
    if cur:
        # Внутри FSM — игнорим (выше уже отработали либо ничего не подошло)
        return
    await m.answer("Не понял. Жми кнопки внизу или /help.", reply_markup=main_menu())


# ── main ─────────────────────────────────────────────────────────────────────
async def main():
    db_init()
    log.info("БД: %s", DB_PATH)

    # Проверка коннекта + сброс webhook (если когда-то был установлен)
    try:
        me = await bot.get_me()
        log.info("Бот @%s (id=%s)", me.username, me.id)
    except Exception as e:
        log.error("Не могу подключиться к Telegram: %s", e)
        log.error("Проверь BOT_TOKEN и что VPN/прокси работает.")
        return

    wh = await bot.get_webhook_info()
    if wh.url:
        log.warning("Webhook был установлен: %s — сбрасываю", wh.url)
        await bot.delete_webhook(drop_pending_updates=False)
    elif wh.pending_update_count:
        log.info("Pending updates: %s — заберём через polling", wh.pending_update_count)

    log.info("Polling запущен. Жди /start от себя в боте...")
    await dp.start_polling(bot, allowed_updates=["message", "callback_query"])


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nЗакрыто.")
    finally:
        # Закрываем aiohttp-session чтобы не было ResourceWarning
        try: asyncio.run(bot.session.close())
        except: pass
