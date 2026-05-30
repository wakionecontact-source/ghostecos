"""
Анкета (Фаза 1): FSM-wizard для заполнения и редактирования профиля.

Шаги: имя → возраст → пол → кого ищу → город → био → фото → готово.
Любой шаг можно прервать командой /cancel.
"""
from __future__ import annotations

import logging
from aiogram import Router, F
from aiogram.filters import Command, StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton, ReplyKeyboardRemove

import db

log = logging.getLogger("okey.profile")
router = Router(name="profile")


class ProfileForm(StatesGroup):
    name = State()
    age = State()
    gender = State()
    looking_for = State()
    city = State()
    bio = State()
    photo = State()


# ── Helpers ──────────────────────────────────────────────────────────────────
GENDER_LABELS = {"m": "Парень", "f": "Девушка"}
LOOKING_LABELS = {"m": "Парня", "f": "Девушку", "any": "Не важно"}


def gender_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="Парень", callback_data="gender:m"),
        InlineKeyboardButton(text="Девушка", callback_data="gender:f"),
    ]])


def looking_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Парня", callback_data="looking:m"),
         InlineKeyboardButton(text="Девушку", callback_data="looking:f")],
        [InlineKeyboardButton(text="Не важно", callback_data="looking:any")],
    ])


def skip_keyboard(payload: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="⏭ Пропустить", callback_data=f"skip:{payload}"),
    ]])


def format_profile(p: dict) -> str:
    """Красивый текст анкеты для показа."""
    lines = [f"<b>{p['name']}, {p['age']}</b>"]
    g = GENDER_LABELS.get(p["gender"], "?")
    lf = LOOKING_LABELS.get(p["looking_for"], "?")
    lines.append(f"{g} · ищет: {lf}")
    if p.get("city"):
        lines.append(f"📍 {p['city']}")
    if p.get("bio"):
        lines.append(f"\n{p['bio']}")
    return "\n".join(lines)


# ── Команды ──────────────────────────────────────────────────────────────────
@router.message(Command("profile"))
async def cmd_profile(m: Message, state: FSMContext):
    db.touch_user(m.from_user.id, m.from_user.username)
    await state.clear()
    p = db.get_profile(m.from_user.id)
    if not p:
        await m.answer(
            "У тебя пока нет анкеты. Заполним?\n\n"
            "Жми /fill чтобы начать."
        )
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✏️ Изменить", callback_data="profile:edit")],
        [InlineKeyboardButton(text="🗑 Удалить", callback_data="profile:delete")],
    ])
    if p.get("photo_file_id"):
        await m.answer_photo(p["photo_file_id"], caption=format_profile(p),
                             parse_mode="HTML", reply_markup=kb)
    else:
        await m.answer(format_profile(p), parse_mode="HTML", reply_markup=kb)


@router.message(Command("fill", "edit", "reset"))
async def cmd_fill(m: Message, state: FSMContext):
    db.touch_user(m.from_user.id, m.from_user.username)
    await state.clear()
    await state.set_state(ProfileForm.name)
    await m.answer(
        "Заполняем анкету. На любом шаге пиши /cancel чтобы отменить.\n\n"
        "<b>Как тебя зовут?</b>\n(только имя, 2-30 символов)",
        parse_mode="HTML",
    )


@router.message(Command("cancel"), StateFilter("*"))
async def cmd_cancel(m: Message, state: FSMContext):
    cur = await state.get_state()
    await state.clear()
    if cur:
        await m.answer("Отменено. Жми /profile чтобы посмотреть текущую анкету.")
    else:
        await m.answer("Нечего отменять.")


@router.callback_query(F.data == "profile:edit")
async def cb_profile_edit(cq: CallbackQuery, state: FSMContext):
    await cq.answer()
    await state.clear()
    await state.set_state(ProfileForm.name)
    await cq.message.answer(
        "Заполняем заново. /cancel — отмена.\n\n<b>Как тебя зовут?</b>",
        parse_mode="HTML",
    )


@router.callback_query(F.data == "profile:delete")
async def cb_profile_delete(cq: CallbackQuery, state: FSMContext):
    await cq.answer()
    db.delete_profile(cq.from_user.id)
    await cq.message.answer("Анкета удалена. Жми /fill чтобы создать новую.")


# ── Wizard steps ─────────────────────────────────────────────────────────────
@router.message(ProfileForm.name, F.text)
async def step_name(m: Message, state: FSMContext):
    name = m.text.strip()
    if not (2 <= len(name) <= 30):
        await m.answer("Имя должно быть 2-30 символов. Попробуй ещё:")
        return
    await state.update_data(name=name)
    await state.set_state(ProfileForm.age)
    await m.answer("Сколько тебе лет?\n(число от 14 до 99)")


@router.message(ProfileForm.age, F.text)
async def step_age(m: Message, state: FSMContext):
    text = m.text.strip()
    if not text.isdigit():
        await m.answer("Введи число. Например: 22")
        return
    age = int(text)
    if not (14 <= age <= 99):
        await m.answer("Возраст должен быть от 14 до 99. Попробуй ещё:")
        return
    await state.update_data(age=age)
    await state.set_state(ProfileForm.gender)
    await m.answer("Твой пол?", reply_markup=gender_keyboard())


@router.callback_query(ProfileForm.gender, F.data.startswith("gender:"))
async def step_gender(cq: CallbackQuery, state: FSMContext):
    g = cq.data.split(":")[1]
    if g not in ("m", "f"):
        await cq.answer("Ошибка")
        return
    await state.update_data(gender=g)
    await cq.answer(GENDER_LABELS[g])
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except Exception: pass
    await state.set_state(ProfileForm.looking_for)
    await cq.message.answer("Кого ищешь?", reply_markup=looking_keyboard())


@router.callback_query(ProfileForm.looking_for, F.data.startswith("looking:"))
async def step_looking(cq: CallbackQuery, state: FSMContext):
    lf = cq.data.split(":")[1]
    if lf not in ("m", "f", "any"):
        await cq.answer("Ошибка")
        return
    await state.update_data(looking_for=lf)
    await cq.answer(LOOKING_LABELS[lf])
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except Exception: pass
    await state.set_state(ProfileForm.city)
    await cq.message.answer(
        "Из какого ты города?\n(можно пропустить)",
        reply_markup=skip_keyboard("city"),
    )


@router.message(ProfileForm.city, F.text)
async def step_city(m: Message, state: FSMContext):
    city = m.text.strip()[:50]
    await state.update_data(city=city)
    await state.set_state(ProfileForm.bio)
    await m.answer(
        "Расскажи о себе пару слов\n(до 300 символов, можно пропустить)",
        reply_markup=skip_keyboard("bio"),
    )


@router.callback_query(ProfileForm.city, F.data == "skip:city")
async def step_city_skip(cq: CallbackQuery, state: FSMContext):
    await cq.answer("Пропущено")
    await state.update_data(city=None)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except Exception: pass
    await state.set_state(ProfileForm.bio)
    await cq.message.answer(
        "Расскажи о себе пару слов\n(до 300 символов, можно пропустить)",
        reply_markup=skip_keyboard("bio"),
    )


@router.message(ProfileForm.bio, F.text)
async def step_bio(m: Message, state: FSMContext):
    bio = m.text.strip()[:300]
    await state.update_data(bio=bio)
    await state.set_state(ProfileForm.photo)
    await m.answer(
        "Отправь своё фото\n(одно, любое — потом можно сменить. Или пропусти.)",
        reply_markup=skip_keyboard("photo"),
    )


@router.callback_query(ProfileForm.bio, F.data == "skip:bio")
async def step_bio_skip(cq: CallbackQuery, state: FSMContext):
    await cq.answer("Пропущено")
    await state.update_data(bio=None)
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except Exception: pass
    await state.set_state(ProfileForm.photo)
    await cq.message.answer(
        "Отправь своё фото\n(одно, любое — потом можно сменить. Или пропусти.)",
        reply_markup=skip_keyboard("photo"),
    )


@router.message(ProfileForm.photo, F.photo)
async def step_photo(m: Message, state: FSMContext):
    # Берём фото максимального размера
    photo_id = m.photo[-1].file_id
    await state.update_data(photo_file_id=photo_id)
    await finalize(m, state)


@router.callback_query(ProfileForm.photo, F.data == "skip:photo")
async def step_photo_skip(cq: CallbackQuery, state: FSMContext):
    await cq.answer("Без фото — можно добавить позже через /edit")
    try: await cq.message.edit_reply_markup(reply_markup=None)
    except Exception: pass
    await state.update_data(photo_file_id=None)
    await finalize(cq.message, state, user_id=cq.from_user.id)


@router.message(ProfileForm.photo, ~F.photo)
async def step_photo_wrong(m: Message):
    await m.answer("Жду фото (или нажми «Пропустить»). Не текст, не файл — именно фото.")


async def finalize(m: Message, state: FSMContext, user_id: int | None = None):
    """Сохранить собранные данные и показать готовую анкету."""
    data = await state.get_data()
    await state.clear()
    uid = user_id if user_id is not None else m.from_user.id

    db.save_profile(
        tg_id=uid,
        name=data["name"],
        age=data["age"],
        gender=data["gender"],
        looking_for=data["looking_for"],
        city=data.get("city"),
        bio=data.get("bio"),
        photo_file_id=data.get("photo_file_id"),
    )

    p = db.get_profile(uid)
    text = "✅ Анкета сохранена!\n\n" + format_profile(p)

    if p.get("photo_file_id"):
        await m.answer_photo(p["photo_file_id"], caption=text, parse_mode="HTML")
    else:
        await m.answer(text, parse_mode="HTML")

    await m.answer(
        "Дальше:\n"
        "/profile — посмотреть анкету\n"
        "/edit — заполнить заново\n"
        "(скоро) /search — смотреть анкеты других\n"
        "(скоро) /roulette — случайное общение"
    )
    log.info("Анкета сохранена для tg_id=%s (имя=%s, %s/%s)",
             uid, data["name"], data["gender"], data["age"])
