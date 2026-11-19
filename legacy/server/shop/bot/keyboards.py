"""Inline и reply клавиатуры."""
from __future__ import annotations

from aiogram.types import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    KeyboardButton,
    ReplyKeyboardMarkup,
    WebAppInfo,
)

import config


def main_menu(user_has_premium: bool = False) -> InlineKeyboardMarkup:
    shop_btn = InlineKeyboardButton(
        text="🛒 Магазин" if not user_has_premium else "🛒 Мои покупки",
        web_app=WebAppInfo(url=f"{config.PUBLIC_URL}/premium"),
    )
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [shop_btn],
            [InlineKeyboardButton(text="👤 Мой аккаунт", callback_data="menu:account")],
            [InlineKeyboardButton(text="⚙️ Настройки", callback_data="menu:settings")],
        ]
    )


def settings_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="✏️ Сменить юзернейм", callback_data="settings:rename")],
            [InlineKeyboardButton(text="🗑 Удалить аккаунт", callback_data="settings:delete")],
            [InlineKeyboardButton(text="← Назад", callback_data="menu:main")],
        ]
    )


def back_to_main() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="← Главное меню", callback_data="menu:main")],
        ]
    )


def confirm_delete() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="✅ Да, удалить", callback_data="settings:delete_yes"),
                InlineKeyboardButton(text="← Отмена", callback_data="menu:settings"),
            ],
        ]
    )


def owner_ticket_actions(ticket_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="✅ Подтвердить", callback_data=f"owner:confirm:{ticket_id}"
                ),
                InlineKeyboardButton(
                    text="❌ Отклонить", callback_data=f"owner:reject:{ticket_id}"
                ),
            ],
            [
                InlineKeyboardButton(
                    text="💬 Ответить в чат", callback_data=f"owner:reply:{ticket_id}"
                ),
            ],
        ]
    )


def owner_reply_actions(ticket_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="💬 Ответить", callback_data=f"owner:reply:{ticket_id}")],
        ]
    )


def cancel_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text="✖ Отмена", callback_data="cancel")]]
    )
