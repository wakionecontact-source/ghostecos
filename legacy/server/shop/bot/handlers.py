"""Telegram-бот: /start, регистрация, меню, настройки, чат с тикетами."""
from __future__ import annotations

import html
import logging
import re
from typing import Optional

from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, InlineKeyboardMarkup, Message

import config
import db
import gc_db

from . import keyboards as kb

log = logging.getLogger("shop_bot.handlers")
router = Router(name="shop_bot")


_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,32}$")


class Reg(StatesGroup):
    wait_username = State()


class Rename(StatesGroup):
    wait_new = State()


class OwnerReply(StatesGroup):
    wait_text = State()


def _access_allowed(tg_id: int) -> bool:
    if config.ACCESS_MODE == "all":
        return True
    return tg_id == config.OWNER_TG_ID


def _is_owner(tg_id: int) -> bool:
    return tg_id == config.OWNER_TG_ID


def _esc(s: str) -> str:
    return html.escape(s or "", quote=False)


# ---------- /start ----------


@router.message(CommandStart())
async def cmd_start(msg: Message, state: FSMContext) -> None:
    assert msg.from_user
    tg_id = msg.from_user.id

    if not _access_allowed(tg_id):
        await msg.answer(
            "🔒 Сейчас бот доступен только для владельца.\n"
            "Открытая регистрация появится позже."
        )
        return

    # Обновляем @username если изменился
    existing = db.get_user(tg_id)
    if existing:
        tg_un = msg.from_user.username or ""
        if tg_un != (existing["tg_username"] or ""):
            db.update_tg_username(tg_id, tg_un)
        await msg.answer(
            f"С возвращением, <b>{_esc(existing['gc_username'])}</b> 👋",
            reply_markup=kb.main_menu(bool(existing["has_premium"])),
        )
        await state.clear()
        return

    await state.set_state(Reg.wait_username)
    await msg.answer(
        "👻 <b>GhostChat Premium Shop</b>\n\n"
        "Для начала введи свой <b>юзернейм GhostChat</b> "
        "(тот, под которым ты зарегистрирован в приложении).",
        reply_markup=kb.cancel_kb(),
    )


@router.callback_query(F.data == "cancel")
async def cb_cancel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    if cb.message:
        await cb.message.answer("Отменено.")
    await cb.answer()


@router.message(Reg.wait_username)
async def reg_username(msg: Message, state: FSMContext) -> None:
    assert msg.from_user and msg.text is not None
    tg_id = msg.from_user.id
    username = msg.text.strip().lstrip("@")

    if not _USERNAME_RE.match(username):
        await msg.answer(
            "❌ Неверный формат. Юзернейм: 3–32 символа, только латиница/цифры/_"
        )
        return

    if not gc_db.username_exists(username):
        await msg.answer(
            f"❌ Аккаунт <b>{_esc(username)}</b> не найден в GhostChat.\n"
            "Проверь юзернейм и попробуй ещё раз."
        )
        return

    if db.get_user_by_gc(username):
        await msg.answer(
            "❌ Этот юзернейм уже привязан к другому Telegram-аккаунту."
        )
        return

    db.create_user(tg_id, msg.from_user.username or "", username)
    await state.clear()
    await msg.answer(
        f"✅ Готово! Привязан аккаунт <b>{_esc(username)}</b>.\n\n"
        "Теперь можешь оформить предзаказ Premium.",
        reply_markup=kb.main_menu(False),
    )


# ---------- меню ----------


@router.callback_query(F.data == "menu:main")
async def cb_main(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    user = db.get_user(cb.from_user.id)
    if not user:
        await cb.answer("Сначала зарегистрируйся через /start", show_alert=True)
        return
    if cb.message:
        await cb.message.edit_text(
            "Главное меню:",
            reply_markup=kb.main_menu(bool(user["has_premium"])),
        )
    await cb.answer()


@router.callback_query(F.data == "menu:account")
async def cb_account(cb: CallbackQuery) -> None:
    user = db.get_user(cb.from_user.id)
    if not user:
        await cb.answer("Сначала зарегистрируйся через /start", show_alert=True)
        return
    premium = "✅ Предзаказ оформлен" if user["has_premium"] else "— не оформлен"
    text = (
        "👤 <b>Мой аккаунт</b>\n\n"
        f"GhostChat: <b>{_esc(user['gc_username'])}</b>\n"
        f"Telegram: @{_esc(user['tg_username']) or '—'}\n"
        f"TG ID: <code>{user['tg_id']}</code>\n"
        f"Premium: {premium}"
    )
    if cb.message:
        await cb.message.edit_text(text, reply_markup=kb.back_to_main())
    await cb.answer()


@router.callback_query(F.data == "menu:settings")
async def cb_settings(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    user = db.get_user(cb.from_user.id)
    if not user:
        await cb.answer("Сначала зарегистрируйся через /start", show_alert=True)
        return
    if cb.message:
        await cb.message.edit_text("⚙️ <b>Настройки</b>", reply_markup=kb.settings_menu())
    await cb.answer()


# ---------- смена юзернейма ----------


@router.callback_query(F.data == "settings:rename")
async def cb_rename(cb: CallbackQuery, state: FSMContext) -> None:
    user = db.get_user(cb.from_user.id)
    if not user:
        await cb.answer("Сначала зарегистрируйся", show_alert=True)
        return
    await state.set_state(Rename.wait_new)
    if cb.message:
        await cb.message.edit_text(
            "Введи новый юзернейм GhostChat:", reply_markup=kb.cancel_kb()
        )
    await cb.answer()


@router.message(Rename.wait_new)
async def rename_apply(msg: Message, state: FSMContext) -> None:
    assert msg.from_user and msg.text is not None
    username = msg.text.strip().lstrip("@")

    if not _USERNAME_RE.match(username):
        await msg.answer("❌ Неверный формат. 3–32 символа, латиница/цифры/_")
        return
    if not gc_db.username_exists(username):
        await msg.answer(f"❌ Аккаунт <b>{_esc(username)}</b> не найден в GhostChat.")
        return
    other = db.get_user_by_gc(username)
    if other and other["tg_id"] != msg.from_user.id:
        await msg.answer("❌ Юзернейм уже привязан к другому TG-аккаунту.")
        return

    db.update_username(msg.from_user.id, username)
    await state.clear()
    user = db.get_user(msg.from_user.id)
    await msg.answer(
        f"✅ Юзернейм обновлён: <b>{_esc(username)}</b>",
        reply_markup=kb.main_menu(bool(user and user["has_premium"])),
    )


# ---------- удаление ----------


@router.callback_query(F.data == "settings:delete")
async def cb_delete_prompt(cb: CallbackQuery) -> None:
    if cb.message:
        await cb.message.edit_text(
            "⚠️ <b>Точно удалить аккаунт?</b>\n\n"
            "Все тикеты и данные будут удалены.\n"
            "Если есть активный Premium — он тоже аннулируется.",
            reply_markup=kb.confirm_delete(),
        )
    await cb.answer()


@router.callback_query(F.data == "settings:delete_yes")
async def cb_delete_yes(cb: CallbackQuery) -> None:
    db.delete_user(cb.from_user.id)
    if cb.message:
        await cb.message.edit_text(
            "🗑 Аккаунт удалён. Напиши /start чтобы зарегистрироваться заново."
        )
    await cb.answer()


# ---------- ответы владельца на тикеты ----------


@router.callback_query(F.data.startswith("owner:reply:"))
async def cb_owner_reply(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_owner(cb.from_user.id):
        await cb.answer("Только для владельца", show_alert=True)
        return
    ticket_id = (cb.data or "").split(":", 2)[2]
    t = db.get_ticket(ticket_id)
    if not t:
        await cb.answer("Тикет не найден", show_alert=True)
        return
    await state.set_state(OwnerReply.wait_text)
    await state.update_data(ticket_id=ticket_id)
    if cb.message:
        await cb.message.answer(
            f"Ответ на <b>{ticket_id}</b>. Отправь текст сообщения:",
            reply_markup=kb.cancel_kb(),
        )
    await cb.answer()


@router.message(OwnerReply.wait_text)
async def owner_reply_send(msg: Message, state: FSMContext) -> None:
    if not msg.from_user or not _is_owner(msg.from_user.id):
        return
    data = await state.get_data()
    ticket_id = data.get("ticket_id")
    if not ticket_id or not msg.text:
        await state.clear()
        return
    db.add_message(ticket_id, "admin", msg.text)
    await state.clear()
    await msg.answer(f"✅ Ответ отправлен в тикет <b>{ticket_id}</b>")


@router.callback_query(F.data.startswith("owner:confirm:"))
async def cb_owner_confirm(cb: CallbackQuery, bot: Bot) -> None:
    if not _is_owner(cb.from_user.id):
        await cb.answer("Только для владельца", show_alert=True)
        return
    ticket_id = (cb.data or "").split(":", 2)[2]
    t = db.get_ticket(ticket_id)
    if not t:
        await cb.answer("Тикет не найден", show_alert=True)
        return
    if t["status"] == "confirmed":
        await cb.answer("Уже подтверждён")
        return
    # Проверяем что у юзера ещё нет премки
    user = db.get_user(int(t["tg_id"]))
    if not user:
        await cb.answer("Юзер удалён", show_alert=True)
        return
    if user["has_premium"] and user["premium_ticket_id"] != ticket_id:
        await cb.answer("У юзера уже есть Premium (другой тикет)", show_alert=True)
        return

    db.update_ticket_status(ticket_id, "confirmed")
    db.mark_premium(int(t["tg_id"]), ticket_id)
    db.add_message(
        ticket_id, "system", "💎 Оплата подтверждена. Premium закреплён за аккаунтом."
    )

    try:
        await bot.send_message(
            int(t["tg_id"]),
            f"✅ Оплата по тикету <b>{ticket_id}</b> подтверждена!\n"
            f"Premium закреплён за твоим аккаунтом.\n"
            f"Доступ активируется когда Premium выйдет в GhostChat.",
        )
    except Exception as e:
        log.warning("notify user failed: %s", e)

    if cb.message:
        await cb.message.edit_text(
            (cb.message.html_text or cb.message.text or "") + "\n\n<b>✅ ПОДТВЕРЖДЕНО</b>"
        )
    await cb.answer("Подтверждено")


@router.callback_query(F.data.startswith("owner:reject:"))
async def cb_owner_reject(cb: CallbackQuery, bot: Bot) -> None:
    if not _is_owner(cb.from_user.id):
        await cb.answer("Только для владельца", show_alert=True)
        return
    ticket_id = (cb.data or "").split(":", 2)[2]
    t = db.get_ticket(ticket_id)
    if not t:
        await cb.answer("Тикет не найден", show_alert=True)
        return

    db.update_ticket_status(ticket_id, "open")
    db.add_message(
        ticket_id, "system", "❌ Оплата не подтверждена. Свяжись с поддержкой в чате."
    )

    try:
        await bot.send_message(
            int(t["tg_id"]),
            f"❌ Оплата по тикету <b>{ticket_id}</b> не подтверждена.\n"
            f"Напиши в чат тикета — разберёмся.",
        )
    except Exception as e:
        log.warning("notify user failed: %s", e)

    if cb.message:
        await cb.message.edit_text(
            (cb.message.html_text or cb.message.text or "") + "\n\n<b>❌ ОТКЛОНЕНО</b>"
        )
    await cb.answer("Отклонено")


# ---------- /login — код для веба ----------


@router.message(Command("login"))
async def cmd_login(msg: Message) -> None:
    assert msg.from_user
    user = db.get_user(msg.from_user.id)
    if not user:
        await msg.answer("Сначала /start чтобы зарегистрироваться.")
        return
    code = db.issue_login_code(msg.from_user.id)
    await msg.answer(
        f"🔑 Код для входа на сайт:\n\n<code>{code}</code>\n\n"
        f"Действителен 10 минут. Введи его на странице входа."
    )


# ---------- сервисное ----------


@router.message(Command("id"))
async def cmd_id(msg: Message) -> None:
    assert msg.from_user
    await msg.answer(
        f"Твой TG ID: <code>{msg.from_user.id}</code>\n"
        f"@username: @{msg.from_user.username or '—'}"
    )


# ---------- /tickets — список для владельца, старые сверху ----------


_TICKETS_PER_PAGE = 10


def _status_emoji(status: str) -> str:
    return {
        "open": "🆕",
        "payment_sent": "⏳",
        "confirmed": "✅",
        "cancelled": "❌",
    }.get(status, "•")


def _tickets_kb(page: int, total: int) -> Optional[InlineKeyboardMarkup]:
    from aiogram.types import InlineKeyboardButton

    pages = max(1, (total + _TICKETS_PER_PAGE - 1) // _TICKETS_PER_PAGE)
    if pages <= 1:
        return None
    row = []
    if page > 0:
        row.append(InlineKeyboardButton(text="← Назад", callback_data=f"tickets:{page-1}"))
    row.append(InlineKeyboardButton(text=f"{page+1}/{pages}", callback_data="noop"))
    if page < pages - 1:
        row.append(InlineKeyboardButton(text="Далее →", callback_data=f"tickets:{page+1}"))
    return InlineKeyboardMarkup(inline_keyboard=[row])


async def _render_tickets(page: int) -> tuple[str, Optional[InlineKeyboardMarkup]]:
    total = db.count_tickets()
    if total == 0:
        return ("Тикетов пока нет.", None)
    rows = db.list_all_tickets(limit=_TICKETS_PER_PAGE, offset=page * _TICKETS_PER_PAGE)
    lines = [f"📋 <b>Все тикеты</b> ({total})\n"]
    for r in rows:
        u = db.get_user(int(r["tg_id"]))
        gc = _esc(u["gc_username"]) if u else "—"
        tg_un = f"@{_esc(u['tg_username'])}" if u and u["tg_username"] else f"id:{r['tg_id']}"
        emoji = _status_emoji(r["status"])
        method = r["payment_method"] or "—"
        lines.append(
            f"{emoji} <code>{r['ticket_id']}</code> · {tg_un} (gc: <b>{gc}</b>)\n"
            f"   {r['amount_rub']}₽ · {method} · /t_{r['ticket_id'].replace('GP-','')}"
        )
    return ("\n".join(lines), _tickets_kb(page, total))


@router.message(Command("tickets"))
async def cmd_tickets(msg: Message) -> None:
    if not msg.from_user or not _is_owner(msg.from_user.id):
        return
    text, kb_ = await _render_tickets(0)
    await msg.answer(text, reply_markup=kb_)


@router.callback_query(F.data.startswith("tickets:"))
async def cb_tickets_page(cb: CallbackQuery) -> None:
    if not _is_owner(cb.from_user.id):
        await cb.answer()
        return
    try:
        page = int((cb.data or "").split(":")[1])
    except (ValueError, IndexError):
        page = 0
    text, kb_ = await _render_tickets(page)
    if cb.message:
        try:
            await cb.message.edit_text(text, reply_markup=kb_)
        except Exception:
            await cb.message.answer(text, reply_markup=kb_)
    await cb.answer()


@router.callback_query(F.data == "noop")
async def cb_noop(cb: CallbackQuery) -> None:
    await cb.answer()


# Открыть тикет по короткой команде /t_12345678
@router.message(F.text.regexp(r"^/t_(\d{8})(?:@\w+)?$"))
async def cmd_open_ticket(msg: Message) -> None:
    if not msg.from_user or not _is_owner(msg.from_user.id) or not msg.text:
        return
    m = re.match(r"^/t_(\d{8})", msg.text)
    if not m:
        return
    ticket_id = f"GP-{m.group(1)}"
    await _show_ticket_details(msg, ticket_id)


async def _show_ticket_details(msg: Message, ticket_id: str) -> None:
    t = db.get_ticket(ticket_id)
    if not t:
        await msg.answer(f"Тикет {ticket_id} не найден.")
        return
    u = db.get_user(int(t["tg_id"]))
    gc = _esc(u["gc_username"]) if u else "—"
    tg_un = f"@{_esc(u['tg_username'])}" if u and u["tg_username"] else "—"
    tg_id_s = u["tg_id"] if u else "—"

    msgs = db.list_messages(ticket_id)
    chat_lines = []
    for m in msgs[-15:]:
        prefix = {"user": "👤", "admin": "🛠", "system": "⚙️"}.get(m["sender"], "•")
        chat_lines.append(f"{prefix} {_esc(m['body'])}")
    chat_text = "\n".join(chat_lines) if chat_lines else "— пусто —"

    text = (
        f"📋 <b>{ticket_id}</b> {_status_emoji(t['status'])} {t['status']}\n\n"
        f"Юзер: {tg_un} (<code>{tg_id_s}</code>)\n"
        f"GC: <b>{gc}</b>\n"
        f"Сумма: {t['amount_rub']} ₽ / {t['amount_stars']} ⭐\n"
        f"Метод: {t['payment_method'] or '—'}\n\n"
        f"<b>Чат (последние 15):</b>\n{chat_text}\n\n"
        f"<i>Ответь на это сообщение — текст уйдёт юзеру в чат тикета.</i>"
    )
    await msg.answer(text, reply_markup=kb.owner_ticket_actions(ticket_id))


# ---------- ответ владельца реплаем (любой reply в ЛС боту) ----------


async def try_owner_reply_by_reply(msg: Message, bot: Bot) -> bool:
    """Если владелец сделал reply на сообщение бота где есть GP-XXXXXXXX — считаем это ответом в тикет."""
    if not msg.from_user or not _is_owner(msg.from_user.id):
        return False
    if not msg.reply_to_message or not msg.text:
        return False
    src = msg.reply_to_message.text or msg.reply_to_message.caption or ""
    m = re.search(r"GP-\d{8}", src)
    if not m:
        return False
    ticket_id = m.group(0)
    t = db.get_ticket(ticket_id)
    if not t:
        return False
    db.add_message(ticket_id, "admin", msg.text)
    try:
        await bot.send_message(
            int(t["tg_id"]),
            f"💬 Сообщение от поддержки по тикету <b>{ticket_id}</b>:\n\n{_esc(msg.text)}",
        )
    except Exception as e:
        log.warning("forward to user failed: %s", e)
    await msg.answer(f"✅ Отправлено в {ticket_id}")
    return True


@router.message(F.reply_to_message)
async def on_reply_msg(msg: Message, bot: Bot) -> None:
    await try_owner_reply_by_reply(msg, bot)
