"""Telegram Stars — инвойсы, pre_checkout, successful_payment."""
from __future__ import annotations

import logging

from aiogram import Bot, F, Router
from aiogram.types import (
    LabeledPrice,
    Message,
    PreCheckoutQuery,
)

import db

from . import notify

log = logging.getLogger("shop_bot.payments")
router = Router(name="shop_payments")


async def create_stars_invoice_link(bot: Bot, ticket_id: str) -> str:
    """Создаёт ссылку-инвойс для оплаты Stars. Возвращает https://t.me/$..."""
    t = db.get_ticket(ticket_id)
    if not t:
        raise ValueError("ticket not found")

    amount = int(t["amount_stars"])
    if amount <= 0:
        raise ValueError("invalid stars amount")

    return await bot.create_invoice_link(
        title=f"GhostChat Premium — {ticket_id}",
        description=(
            "Предзаказ Premium. 12 месяцев действия с момента релиза Premium в GhostChat."
        ),
        payload=f"ticket:{ticket_id}",
        currency="XTR",  # Telegram Stars
        prices=[LabeledPrice(label="Premium (предзаказ)", amount=amount)],
    )


@router.pre_checkout_query()
async def pre_checkout(q: PreCheckoutQuery, bot: Bot) -> None:
    payload = q.invoice_payload or ""
    if not payload.startswith("ticket:"):
        await bot.answer_pre_checkout_query(q.id, ok=False, error_message="Invalid payload")
        return
    ticket_id = payload.split(":", 1)[1]
    t = db.get_ticket(ticket_id)
    if not t:
        await bot.answer_pre_checkout_query(q.id, ok=False, error_message="Ticket not found")
        return
    if t["status"] == "confirmed":
        await bot.answer_pre_checkout_query(q.id, ok=False, error_message="Already paid")
        return
    user = db.get_user(int(t["tg_id"]))
    if user and user["has_premium"] and user["premium_ticket_id"] != ticket_id:
        await bot.answer_pre_checkout_query(
            q.id, ok=False, error_message="У аккаунта уже есть Premium"
        )
        return
    if q.total_amount != int(t["amount_stars"]):
        await bot.answer_pre_checkout_query(q.id, ok=False, error_message="Сумма не совпадает")
        return
    await bot.answer_pre_checkout_query(q.id, ok=True)


@router.message(F.successful_payment)
async def on_successful_payment(msg: Message, bot: Bot) -> None:
    sp = msg.successful_payment
    if not sp or not msg.from_user:
        return
    payload = sp.invoice_payload or ""
    if not payload.startswith("ticket:"):
        return
    ticket_id = payload.split(":", 1)[1]
    t = db.get_ticket(ticket_id)
    if not t:
        return
    if t["status"] == "confirmed":
        return

    db.set_payment_method(ticket_id, "stars")
    db.set_stars_charge(ticket_id, sp.telegram_payment_charge_id or "")
    db.update_ticket_status(ticket_id, "confirmed")
    db.mark_premium(int(t["tg_id"]), ticket_id)
    db.add_message(
        ticket_id,
        "system",
        f"⭐ Оплата Stars принята ({sp.total_amount} ⭐). Premium закреплён за аккаунтом.",
    )

    await msg.answer(
        f"✅ Оплата прошла! Premium закреплён за твоим аккаунтом.\n"
        f"Тикет: <b>{ticket_id}</b>"
    )
    await notify.payment_sent(bot, ticket_id, "stars")
