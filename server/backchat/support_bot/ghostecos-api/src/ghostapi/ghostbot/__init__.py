"""GhostChat bot API for Python."""

from .client import (
    DEFAULT_BASE_URL,
    Bot,
    BotAPIError,
    BotEvent,
    BotNetworkError,
    BotProtocolError,
    GhostBotError,
)
from .storage import BotStorage
from .markup import InlineKeyboard, InlineKeyboardButton, KeyboardButton, ReplyKeyboard

__version__ = "0.1.0a4"

__all__ = [
    "DEFAULT_BASE_URL",
    "Bot",
    "BotAPIError",
    "BotEvent",
    "BotNetworkError",
    "BotProtocolError",
    "BotStorage",
    "GhostBotError",
    "InlineKeyboard",
    "InlineKeyboardButton",
    "KeyboardButton",
    "ReplyKeyboard",
    "__version__",
]
