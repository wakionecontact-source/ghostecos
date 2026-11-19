"""Типизированные Telegram-совместимые клавиатуры сообщений для ботов GhostChat."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence
from urllib.parse import urlsplit


_MAX_ROWS = 10
_MAX_BUTTONS = 100
_MAX_BUTTONS_PER_ROW = 10
_MAX_BUTTON_LABEL_CHARS = 64
_MAX_CALLBACK_DATA_BYTES = 64
_MAX_MESSAGE_TEXT_CHARS = 4_000


def _validate_text(value: str, label: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{label} must be a string")
    if not value.strip() or len(value) > maximum:
        raise ValueError(f"{label} must contain between 1 and {maximum} characters")
    return value


def _normalise_rows(rows: Sequence[Sequence[object]], label: str) -> tuple[tuple[object, ...], ...]:
    if not isinstance(rows, Sequence) or isinstance(rows, (str, bytes)):
        raise TypeError(f"{label} rows must be a sequence of rows")
    if not rows or len(rows) > _MAX_ROWS:
        raise ValueError(f"{label} must contain between 1 and {_MAX_ROWS} rows")

    normalised: list[tuple[object, ...]] = []
    button_count = 0
    for row in rows:
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes)):
            raise TypeError(f"each {label} row must be a sequence")
        if not row or len(row) > _MAX_BUTTONS_PER_ROW:
            raise ValueError(
                f"each {label} row must contain between 1 and "
                f"{_MAX_BUTTONS_PER_ROW} buttons"
            )
        button_count += len(row)
        if button_count > _MAX_BUTTONS:
            raise ValueError(f"{label} cannot contain more than {_MAX_BUTTONS} buttons")
        normalised.append(tuple(row))
    return tuple(normalised)


@dataclass(frozen=True, slots=True)
class InlineKeyboardButton:
    """Кнопка под сообщением: тап шлёт callback или открывает URL."""

    text: str
    callback_data: str | None = None
    url: str | None = None

    def __post_init__(self) -> None:
        _validate_text(self.text, "button text", _MAX_BUTTON_LABEL_CHARS)
        if (self.callback_data is None) == (self.url is None):
            raise ValueError("provide exactly one of callback_data or url")
        if self.callback_data is not None:
            if not isinstance(self.callback_data, str) or not self.callback_data:
                raise ValueError("callback_data must not be empty")
            if len(self.callback_data.encode("utf-8")) > _MAX_CALLBACK_DATA_BYTES:
                raise ValueError(
                    f"callback_data must be at most {_MAX_CALLBACK_DATA_BYTES} UTF-8 bytes"
                )
        if self.url is not None:
            if not isinstance(self.url, str) or len(self.url) > 2_048:
                raise ValueError("url must be a string of at most 2048 characters")
            if any(
                character.isspace()
                or ord(character) < 32
                or ord(character) == 127
                or character == "\\"
                for character in self.url
            ):
                raise ValueError("url must not contain whitespace or control characters")
            try:
                parsed = urlsplit(self.url)
                _ = parsed.port
            except ValueError as exc:
                raise ValueError("url must be a valid absolute http(s) URL") from exc
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.username is not None
                or parsed.password is not None
            ):
                raise ValueError("url must be an absolute http(s) URL without credentials")

    def to_dict(self) -> dict[str, str]:
        result = {"text": self.text}
        if self.callback_data is not None:
            result["callback_data"] = self.callback_data
        else:
            result["url"] = str(self.url)
        return result


@dataclass(frozen=True, slots=True)
class KeyboardButton:
    """Кнопка reply-клавиатуры: тап отправляет ``send_text`` как обычное сообщение."""

    text: str
    send_text: str | None = None

    def __post_init__(self) -> None:
        _validate_text(self.text, "button text", _MAX_BUTTON_LABEL_CHARS)
        send_text = self.text if self.send_text is None else self.send_text
        _validate_text(send_text, "send_text", _MAX_MESSAGE_TEXT_CHARS)
        object.__setattr__(self, "send_text", send_text)

    def to_dict(self) -> dict[str, str]:
        return {"text": self.text, "send_text": str(self.send_text)}


@dataclass(frozen=True, slots=True)
class InlineKeyboard:
    """Ряды кнопок прямо под сообщением бота."""

    rows: Sequence[Sequence[InlineKeyboardButton]]

    def __post_init__(self) -> None:
        rows = _normalise_rows(self.rows, "inline keyboard")
        if any(not isinstance(button, InlineKeyboardButton) for row in rows for button in row):
            raise TypeError("inline keyboard rows must contain InlineKeyboardButton values")
        object.__setattr__(self, "rows", rows)

    def to_dict(self) -> dict[str, object]:
        return {
            "inline_keyboard": [
                [button.to_dict() for button in row] for row in self.rows
            ]
        }


@dataclass(frozen=True, slots=True)
class ReplyKeyboard:
    """Постоянная клавиатура чата: тап кнопки шлёт простой текст."""

    rows: Sequence[Sequence[KeyboardButton | str]]
    resize_keyboard: bool = True
    one_time_keyboard: bool = False

    def __post_init__(self) -> None:
        rows = _normalise_rows(self.rows, "reply keyboard")
        converted: list[tuple[KeyboardButton, ...]] = []
        for row in rows:
            converted_row: list[KeyboardButton] = []
            for button in row:
                if isinstance(button, str):
                    button = KeyboardButton(button)
                if not isinstance(button, KeyboardButton):
                    raise TypeError("reply keyboard rows must contain KeyboardButton values or strings")
                converted_row.append(button)
            converted.append(tuple(converted_row))
        if not isinstance(self.resize_keyboard, bool) or not isinstance(
            self.one_time_keyboard, bool
        ):
            raise TypeError("reply keyboard options must be booleans")
        object.__setattr__(self, "rows", tuple(converted))

    def to_dict(self) -> dict[str, object]:
        return {
            "keyboard": [[button.to_dict() for button in row] for row in self.rows],
            "resize_keyboard": self.resize_keyboard,
            "one_time_keyboard": self.one_time_keyboard,
        }


__all__ = [
    "InlineKeyboard",
    "InlineKeyboardButton",
    "KeyboardButton",
    "ReplyKeyboard",
]
