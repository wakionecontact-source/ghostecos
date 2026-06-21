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


def db_delete_user(tg_id: int) -> None:
    with sqlite3.connect(DB_PATH) as c:
        c.execute("DELETE FROM users WHERE tg_id=?", (tg_id,))


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
            [KeyboardButton(text="🎲 Рулетка"), KeyboardButton(text="⚙️ Настройки")],
        ],
        resize_keyboard=True,
    )


def settings_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✏️ Изменить анкету", callback_data="fill")],
        [InlineKeyboardButton(text="❓ Помощь", callback_data="help")],
        [InlineKeyboardButton(text="🗑 Удалить аккаунт", callback_data="acc:del_ask")],
    ])


def confirm_delete_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, удалить", callback_data="acc:del_yes"),
        InlineKeyboardButton(text="❌ Нет", callback_data="acc:del_no"),
    ]])


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
    gender_map = {"m": "👨 Парень", "f": "👩 Девушка"}
    looking_map = {"m": "👨 парня", "f": "👩 девушку", "any": "🌈 не важно"}
    lines = [f"<b>{u.get('name') or '—'}, {u.get('age') or '?'}</b>"]
    g = gender_map.get(u.get("gender"), "❓")
    l = looking_map.get(u.get("looking"), "❓")
    lines.append(f"{g} · ищет: {l}")
    if u.get("bio"):
        lines.append(f"\n💭 {u['bio']}")
    return "\n".join(lines)


# ── Handlers ─────────────────────────────────────────────────────────────────
@dp.message(CommandStart())
async def on_start(m: Message, state: FSMContext):
    await state.clear()
    log.info("/start от @%s (%s)", m.from_user.username, m.from_user.id)
    u = db_get_user(m.from_user.id)
    if u and u.get("name"):
        await m.answer(
            f"👋 С возвращением, <b>{u['name']}</b>!\n\n"
            f"Что хочешь сделать? Кнопки внизу 👇",
            parse_mode="HTML",
            reply_markup=main_menu(),
        )
    else:
        await m.answer(
            "💜 Привет! Это <b>OKey</b> — знакомства в Telegram.\n\n"
            "Что умеет:\n"
            "📝 Заполнить анкету и смотреть других\n"
            "❤️ Лайкать, получать match-уведомления\n"
            "🎲 Болтать в чат-рулетке со случайными людьми\n\n"
            "<i>Никакой рекламы и подписок. Open source.</i>\n\n"
            "Поехали? 👇",
            parse_mode="HTML",
            reply_markup=start_kb(),
        )
        await m.answer("👇 А внизу — главное меню (всегда там):", reply_markup=main_menu())


@dp.message(Command("help"))
async def on_help(m: Message):
    await m.answer(
        "<b>OKey</b> — бот знакомств.\n\n"
        "Кнопки внизу:\n"
        "👤 <b>Моя анкета</b> — посмотреть/изменить\n"
        "🔍 <b>Поиск</b> — смотреть анкеты других (скоро)\n"
        "🎲 <b>Рулетка</b> — случайный собеседник (скоро)\n"
        "⚙️ <b>Настройки</b> — изменить анкету, удалить аккаунт\n\n"
        "Команды: /start /cancel /help",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


@dp.message(Command("cancel"))
async def on_cancel(m: Message, state: FSMContext):
    cur = await state.get_state()
    await state.clear()
    if cur:
        await m.answer("✋ <b>Заполнение отменено</b>\nВсе введённые данные сброшены.",
                       parse_mode="HTML", reply_markup=main_menu())
    else:
        await m.answer("🤷 Нечего отменять — ты не в процессе заполнения.",
                       reply_markup=main_menu())


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
    # Готовим кнопку "взять из Telegram" с display_name
    tg_name_full = " ".join(
        x for x in [event.from_user.first_name, event.from_user.last_name] if x
    ).strip()
    # Обрезаем до лимита 30
    tg_name = (tg_name_full or event.from_user.username or "")[:30]
    name_kb = None
    if tg_name and len(tg_name) >= 2:
        name_kb = InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text=f"📋 Взять из Telegram: {tg_name}", callback_data="name:tg"),
        ]])
    await send(
        "📝 <b>Заполняем анкету</b>\n"
        "<i>Можно прервать в любой момент: /cancel</i>\n\n"
        "👋 <b>Как тебя зовут?</b>\n"
        "Только имя, 2-30 символов.",
        parse_mode="HTML",
        reply_markup=name_kb,
    )


async def _accept_name(name: str, send_fn, state: FSMContext):
    """Сохранить имя и перейти к возрасту. Используется и из текста, и из кнопки."""
    # Защита от пустоты
    if not name:
        await send_fn("🤔 Пустое сообщение. Напиши, как тебя зовут:")
        return False
    if len(name) < 2:
        await send_fn(
            f"📏 «{name}» — слишком коротко (нужно <b>2-30 символов</b>).\n"
            f"Это правда твоё имя? Попробуй ещё раз:",
            parse_mode="HTML",
        )
        return False
    if len(name) > 30:
        await send_fn(
            f"📏 Длинновато ({len(name)} символов). Максимум <b>30</b>.\n"
            f"Сократи (или только имя без фамилии):",
            parse_mode="HTML",
        )
        return False
    # Запрет на ссылки и @-упоминания в имени
    low = name.lower()
    if "@" in low or "http" in low or "t.me" in low or ".com" in low:
        await send_fn(
            "🚫 В имени не должно быть ссылок или @-упоминаний.\n"
            "Введи нормальное имя:",
        )
        return False
    await state.update_data(name=name)
    await state.set_state(Form.age)
    await send_fn(
        f"👌 Привет, <b>{name}</b>!\n\n"
        f"🎂 <b>Сколько тебе лет?</b>\n"
        f"Принимаю числа от <b>10</b> до <b>60</b>.",
        parse_mode="HTML",
    )
    return True


@dp.message(Form.name, F.text)
async def step_name(m: Message, state: FSMContext):
    await _accept_name(m.text.strip(), m.answer, state)


@dp.message(Form.name)
async def step_name_not_text(m: Message):
    """Юзер прислал фото/стикер/что угодно вместо имени."""
    await m.answer(
        "🤨 Жду <b>текст</b> с твоим именем, не картинку/стикер/файл.\n"
        "Просто напиши, как тебя зовут:",
        parse_mode="HTML",
    )


@dp.callback_query(Form.name, F.data == "name:tg")
async def step_name_from_tg(cq: CallbackQuery, state: FSMContext):
    tg_name = " ".join(
        x for x in [cq.from_user.first_name, cq.from_user.last_name] if x
    ).strip()
    if not tg_name:
        tg_name = cq.from_user.username or ""
    tg_name = tg_name[:30]
    if len(tg_name) < 2:
        await cq.answer("⚠️ В Telegram нет нормального имени — введи вручную", show_alert=True)
        return
    await cq.answer(f"✅ Взял: {tg_name}")
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await _accept_name(tg_name, cq.message.answer, state)


@dp.message(Form.age, F.text)
async def step_age(m: Message, state: FSMContext):
    t = m.text.strip()
    # Удалим всё кроме цифр на случай "22 года" / "22!"
    digits = "".join(c for c in t if c.isdigit())
    if not digits:
        await m.answer(
            "🔢 Это не похоже на число. Просто <b>число</b>, например: <code>22</code>",
            parse_mode="HTML",
        )
        return
    try:
        age = int(digits)
    except ValueError:
        await m.answer("🔢 Не понял число. Напиши просто цифрами:")
        return
    # Слишком маленький
    if age < 10:
        await m.answer(
            f"🚸 <b>{age}</b> — меньше разрешённого (минимум <b>10</b>).\n\n"
            f"Если это правда твой возраст — извини, бот тебе пока не подходит 😔\n"
            f"Если опечатка — напиши настоящий возраст:",
            parse_mode="HTML",
        )
        return
    # Слишком большой (или явно не возраст)
    if age > 60 and age <= 120:
        await m.answer(
            f"👴 <b>{age}</b> — больше разрешённого (максимум <b>60</b>).\n\n"
            f"Если это правда — увы, бот тебе не подходит 😔\n"
            f"Если ошибся — напиши свой возраст заново:",
            parse_mode="HTML",
        )
        return
    if age > 120:
        await m.answer(
            f"🤖 <b>{age}</b> — ну либо ты бессмертный, либо опечатался.\n"
            f"Напиши нормальный возраст (10-60):",
            parse_mode="HTML",
        )
        return
    await state.update_data(age=age)
    await state.set_state(Form.gender)
    await m.answer(
        f"📅 <b>{age}</b> — записал!\n\n"
        f"⚧ <b>Твой пол?</b>",
        parse_mode="HTML",
        reply_markup=gender_kb(),
    )


@dp.message(Form.age)
async def step_age_not_text(m: Message):
    await m.answer("🔢 Жду число, не картинку/стикер. Сколько тебе лет?")


@dp.callback_query(Form.gender, F.data.startswith("g:"))
async def step_gender(cq: CallbackQuery, state: FSMContext):
    g = cq.data.split(":", 1)[1]
    if g not in ("m", "f"):
        await cq.answer("⚠️"); return
    await state.update_data(gender=g)
    label = "👨 Парень" if g == "m" else "👩 Девушка"
    await cq.answer(f"✅ {label}")
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.looking)
    await cq.message.answer(
        f"{label} — записал.\n\n"
        f"❤️ <b>Кого ищешь?</b>",
        parse_mode="HTML",
        reply_markup=looking_kb(),
    )


@dp.message(Form.gender)
async def step_gender_text(m: Message):
    await m.answer("👆 Нажми одну из кнопок выше — Парень / Девушка.")


@dp.callback_query(Form.looking, F.data.startswith("l:"))
async def step_looking(cq: CallbackQuery, state: FSMContext):
    lf = cq.data.split(":", 1)[1]
    if lf not in ("m", "f", "any"):
        await cq.answer("⚠️"); return
    labels = {"m": "👨 Парней", "f": "👩 Девушек", "any": "🌈 Не важно кого"}
    await state.update_data(looking=lf)
    await cq.answer(f"✅ {labels[lf]}")
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.bio)
    await cq.message.answer(
        f"Ищешь: <b>{labels[lf]}</b>\n\n"
        f"📝 <b>Расскажи о себе</b>\n"
        f"<i>До 300 символов. Хобби, интересы, чё кайфуешь.</i>\n"
        f"<i>Можно пропустить.</i>",
        parse_mode="HTML",
        reply_markup=skip_kb("bio"),
    )


@dp.message(Form.looking)
async def step_looking_text(m: Message):
    await m.answer("👆 Нажми одну из кнопок выше.")


@dp.message(Form.bio, F.text)
async def step_bio(m: Message, state: FSMContext):
    bio = m.text.strip()
    if len(bio) > 300:
        await m.answer(
            f"📏 Длинновато ({len(bio)} символов). Максимум <b>300</b>.\n"
            f"Сократи и пришли заново:",
            parse_mode="HTML",
        )
        return
    if len(bio) < 3:
        await m.answer(
            "🤔 Слишком коротко. Хотя бы пару слов о себе.\n"
            "Или жми «Пропустить»:",
            reply_markup=skip_kb("bio"),
        )
        return
    await state.update_data(bio=bio)
    await state.set_state(Form.photo)
    await m.answer(
        f"📸 <b>Теперь отправь своё фото</b>\n"
        f"<i>Одно, любое. Будет видно другим юзерам.</i>\n"
        f"<i>Можно пропустить — добавишь позже.</i>",
        parse_mode="HTML",
        reply_markup=skip_kb("photo"),
    )


@dp.message(Form.bio)
async def step_bio_not_text(m: Message):
    await m.answer(
        "📝 Жду <b>текст</b> с описанием себя. Или нажми «Пропустить»:",
        parse_mode="HTML",
        reply_markup=skip_kb("bio"),
    )


@dp.callback_query(Form.bio, F.data == "skip:bio")
async def skip_bio(cq: CallbackQuery, state: FSMContext):
    await cq.answer("⏭ Без описания")
    await state.update_data(bio=None)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await state.set_state(Form.photo)
    await cq.message.answer(
        f"📸 <b>Теперь отправь своё фото</b>\n"
        f"<i>Одно, любое. Будет видно другим юзерам.</i>\n"
        f"<i>Можно пропустить — добавишь позже.</i>",
        parse_mode="HTML",
        reply_markup=skip_kb("photo"),
    )


@dp.message(Form.photo, F.photo)
async def step_photo(m: Message, state: FSMContext):
    await state.update_data(photo_id=m.photo[-1].file_id)
    await finalize(m, state)


@dp.message(Form.photo, F.document)
async def step_photo_doc(m: Message):
    await m.answer(
        "📎 Это файл, не фото. Пришли <b>именно фото</b> (галерея или камера).\n"
        "<i>Telegram файлы-картинки не подходят — они не сжимаются.</i>",
        parse_mode="HTML",
        reply_markup=skip_kb("photo"),
    )


@dp.message(Form.photo)
async def step_photo_wrong(m: Message):
    await m.answer(
        "📸 Жду <b>фото</b>. Не текст, не стикер, не видео.\n"
        "Открой галерею и пришли картинку. Или жми «Пропустить»:",
        parse_mode="HTML",
        reply_markup=skip_kb("photo"),
    )


@dp.callback_query(Form.photo, F.data == "skip:photo")
async def skip_photo(cq: CallbackQuery, state: FSMContext):
    await cq.answer("⏭ Без фото")
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
    text = "🎉 <b>Анкета готова!</b>\n\n" + format_profile(u)
    if u.get("photo_id"):
        await m.answer_photo(u["photo_id"], caption=text, parse_mode="HTML")
    else:
        await m.answer(text, parse_mode="HTML")
    await m.answer(
        "💜 Готово!\n\n"
        "🔜 Скоро: поиск других анкет и чат-рулетка.\n"
        "Пока — изменяй анкету в ⚙️ Настройки.",
        reply_markup=main_menu(),
    )
    log.info("Анкета сохранена tg=%s name=%s", user_id, data.get("name"))


# ── Reply-кнопки stub'ы ──────────────────────────────────────────────────────
@dp.message(F.text == "🔍 Поиск")
async def stub_search(m: Message):
    await m.answer(
        "🔍 <b>Поиск анкет</b>\n\n"
        "🛠 Скоро тут будет:\n"
        "• Смотришь карточки других юзеров\n"
        "• 💚 Лайк / 💔 Пропустить\n"
        "• Взаимный лайк → match → можно общаться\n\n"
        "<i>Жди в следующем апдейте.</i>",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


@dp.message(F.text == "🎲 Рулетка")
async def stub_roulette(m: Message):
    await m.answer(
        "🎲 <b>Чат-рулетка</b>\n\n"
        "🛠 Скоро тут будет:\n"
        "• Встаёшь в очередь поиска\n"
        "• Бот находит случайного собеседника\n"
        "• Болтаешь анонимно, можно остановить в любой момент\n\n"
        "<i>Жди в следующем апдейте.</i>",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


# ── Настройки + удаление аккаунта ────────────────────────────────────────────
@dp.message(F.text == "⚙️ Настройки")
async def on_settings(m: Message):
    u = db_get_user(m.from_user.id)
    has_profile = bool(u and u.get("name"))
    status = "✅ Анкета заполнена" if has_profile else "⚠️ Анкета не заполнена"
    await m.answer(
        f"⚙️ <b>Настройки</b>\n\n{status}",
        parse_mode="HTML",
        reply_markup=settings_kb(),
    )


@dp.callback_query(F.data == "help")
async def cb_help(cq: CallbackQuery):
    await cq.answer()
    await cq.message.answer(
        "<b>OKey</b> — бот знакомств.\n\n"
        "Кнопки внизу:\n"
        "👤 <b>Моя анкета</b> — посмотреть/изменить\n"
        "🔍 <b>Поиск</b> — смотреть анкеты других (скоро)\n"
        "🎲 <b>Рулетка</b> — случайный собеседник (скоро)\n"
        "⚙️ <b>Настройки</b> — изменить анкету, удалить аккаунт\n\n"
        "Команды: /start /cancel",
        parse_mode="HTML",
    )


@dp.callback_query(F.data == "acc:del_ask")
async def cb_del_ask(cq: CallbackQuery):
    await cq.answer()
    await cq.message.answer(
        "⚠️ <b>Удалить аккаунт?</b>\n\n"
        "Что произойдёт:\n"
        "🗑 Твоя анкета будет стёрта\n"
        "❤️ Все лайки и матчи пропадут\n"
        "💬 История переписок (если будет) — тоже\n\n"
        "<b>Действие необратимо.</b>\n"
        "Точно?",
        parse_mode="HTML",
        reply_markup=confirm_delete_kb(),
    )


@dp.callback_query(F.data == "acc:del_yes")
async def cb_del_yes(cq: CallbackQuery, state: FSMContext):
    await cq.answer("🗑 Удаляю...")
    await state.clear()
    db_delete_user(cq.from_user.id)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await cq.message.answer(
        "✅ <b>Аккаунт удалён.</b>\n\n"
        "Все данные стёрты. Если захочешь вернуться — жми /start, "
        "заполнишь анкету заново.\n\n"
        "💜 Будет приятно если вернёшься.",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )
    log.info("Аккаунт удалён: tg=%s @%s", cq.from_user.id, cq.from_user.username)


@dp.callback_query(F.data == "acc:del_no")
async def cb_del_no(cq: CallbackQuery):
    await cq.answer("✋ Отменено")
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except: pass
    await cq.message.answer("👌 Удаление отменено. Аккаунт на месте.",
                            reply_markup=main_menu())


# ── Fallback ─────────────────────────────────────────────────────────────────
@dp.message()
async def fallback(m: Message, state: FSMContext):
    cur = await state.get_state()
    if cur:
        # Внутри FSM — игнорим (выше уже отработали либо ничего не подошло)
        return
    await m.answer(
        "🤔 Не понял команду.\n\nЖми кнопки внизу 👇 или /help",
        reply_markup=main_menu(),
    )


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
