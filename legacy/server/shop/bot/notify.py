"""Уведомления владельцу о событиях."""
from __future__ import annotations

import html
import logging

from aiogram import Bot

import config
import db

from . import keyboards as kb

log = logging.getLogger("shop_bot.notify")


def _esc(s: str) -> str:
    return html.escape(s or "", quote=False)


async def new_ticket(bot: Bot, ticket_id: str) -> None:
    if config.OWNER_TG_ID == 0:
        return
    t = db.get_ticket(ticket_id)
    if not t:
        return
    u = db.get_user(int(t["tg_id"]))
    if not u:
        return
    text = (
        f"🆕 <b>Новый тикет</b> <code>{ticket_id}</code>\n\n"
        f"Юзер: @{_esc(u['tg_username']) or '—'} (<code>{u['tg_id']}</code>)\n"
        f"GC: <b>{_esc(u['gc_username'])}</b>\n"
        f"Сумма: {t['amount_rub']} ₽ / {t['amount_stars']} ⭐"
    )
    try:
        await bot.send_message(
            config.OWNER_TG_ID, text, reply_markup=kb.owner_reply_actions(ticket_id)
        )
    except Exception as e:
        log.warning("owner notify failed: %s", e)


async def payment_sent(bot: Bot, ticket_id: str, method: str) -> None:
    """Юзер нажал 'я оплатил' по @send или прошла Stars."""
    if config.OWNER_TG_ID == 0:
        return
    t = db.get_ticket(ticket_id)
    if not t:
        return
    u = db.get_user(int(t["tg_id"]))
    if not u:
        return

    if method == "stars":
        text = (
            f"⭐ <b>Оплата Stars</b> <code>{ticket_id}</code>\n\n"
            f"Юзер: @{_esc(u['tg_username']) or '—'} (<code>{u['tg_id']}</code>)\n"
            f"GC: <b>{_esc(u['gc_username'])}</b>\n"
            f"Сумма: {t['amount_stars']} ⭐\n\n"
            f"Оплата прошла автоматически, премка уже выдана."
        )
        try:
            await bot.send_message(config.OWNER_TG_ID, text)
        except Exception as e:
            log.warning("owner notify failed: %s", e)
        return

    # @send — требует ручной проверки
    text = (
        f"💎 <b>Оплата @send (ожидает проверки)</b>\n"
        f"Тикет: <code>{ticket_id}</code>\n\n"
        f"Юзер: @{_esc(u['tg_username']) or '—'} (<code>{u['tg_id']}</code>)\n"
        f"GC: <b>{_esc(u['gc_username'])}</b>\n"
        f"Сумма: {t['amount_rub']} ₽\n\n"
        f"Проверь @send и подтверди или отклони."
    )
    try:
        await bot.send_message(
            config.OWNER_TG_ID, text, reply_markup=kb.owner_ticket_actions(ticket_id)
        )
    except Exception as e:
        log.warning("owner notify failed: %s", e)


async def user_message(bot: Bot, ticket_id: str, body: str) -> None:
    """Юзер написал сообщение в чат тикета."""
    if config.OWNER_TG_ID == 0:
        return
    t = db.get_ticket(ticket_id)
    if not t:
        return
    u = db.get_user(int(t["tg_id"]))
    if not u:
        return
    snippet = body if len(body) < 500 else body[:500] + "…"
    text = (
        f"💬 <code>{ticket_id}</code> · @{_esc(u['tg_username']) or '—'} "
        f"(gc: <b>{_esc(u['gc_username'])}</b>)\n\n"
        f"{_esc(snippet)}"
    )
    try:
        await bot.send_message(
            config.OWNER_TG_ID, text, reply_markup=kb.owner_reply_actions(ticket_id)
        )
    except Exception as e:
        log.warning("owner notify failed: %s", e)


async def send_user_notification(bot: Bot, tg_id: int, text: str) -> None:
    try:
        await bot.send_message(tg_id, text)
    except Exception as e:
        log.warning("user notify %s failed: %s", tg_id, e)
