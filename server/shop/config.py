"""Конфиг — читается из .env в корне shop_bot/."""
from __future__ import annotations

import os
from pathlib import Path


_ROOT = Path(__file__).parent
_ENV_FILE = _ROOT / ".env"


def _load_env() -> None:
    """Примитивный .env парсер — без зависимостей."""
    if not _ENV_FILE.exists():
        return
    for raw in _ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = val


_load_env()


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def _str(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


# --- Telegram ---
BOT_TOKEN: str = _str("BOT_TOKEN", "")
OWNER_TG_ID: int = _int("OWNER_TG_ID", 0)
OWNER_GC_USERNAME: str = _str("OWNER_GC_USERNAME", "").lower()
SEND_WALLET: str = _str("SEND_WALLET", "").lstrip("@")

# --- Web ---
WEB_HOST: str = _str("WEB_HOST", "127.0.0.1")
WEB_PORT: int = _int("WEB_PORT", 8001)
PUBLIC_URL: str = _str("PUBLIC_URL", f"http://{WEB_HOST}:{WEB_PORT}").rstrip("/")
# URL-префикс (если за nginx стоит под /shop/). Локально — пусто.
URL_PREFIX: str = _str("URL_PREFIX", "").rstrip("/")

# --- Security ---
JWT_SECRET: str = _str("JWT_SECRET", "dev_insecure_secret_change_me")
ACCESS_MODE: str = _str("ACCESS_MODE", "owner_only")  # "owner_only" | "all"
OWNER_PASSWORD: str = _str("OWNER_PASSWORD", "")  # если задан — требуется при входе за owner

# --- GhostChat API (для проверки юзернеймов) ---
GC_API_URL: str = _str("GC_API_URL", "")          # http://149.154.70.18
GC_INTERNAL_KEY: str = _str("GC_INTERNAL_KEY", "") # shared secret

# --- Paths (legacy, не используется если задан GC_API_URL) ---
_GC_DB_RAW = _str("GC_DB_PATH", "")
_SHOP_DB_RAW = _str("SHOP_DB_PATH", "./shop.db")
GC_DB_PATH: str = str((_ROOT / _GC_DB_RAW).resolve()) if not os.path.isabs(_GC_DB_RAW) else _GC_DB_RAW
SHOP_DB_PATH: str = str((_ROOT / _SHOP_DB_RAW).resolve()) if not os.path.isabs(_SHOP_DB_RAW) else _SHOP_DB_RAW
STATIC_DIR: Path = _ROOT / "static"

# --- Pricing ---
PRICE_FULL_RUB: int = _int("PRICE_FULL_RUB", 490)
PRICE_DISCOUNT_RUB: int = _int("PRICE_DISCOUNT_RUB", 245)
PRICE_FULL_USDT: float = _float("PRICE_FULL_USDT", 5.50)
PRICE_DISCOUNT_USDT: float = _float("PRICE_DISCOUNT_USDT", 2.75)
DISCOUNT_HOURS: int = _int("DISCOUNT_HOURS", 72)
PREMIUM_MONTHS: int = _int("PREMIUM_MONTHS", 12)

# --- Payment links ---
SEND_URL: str = _str("SEND_URL", "https://t.me/send?start=IV4qJ3pfGkgA")
DONATE_URL: str = _str("DONATE_URL", "https://dalink.to/waki_ss")

# --- Rate limits ---
RATE_LIMIT_ENABLED: bool = _str("RATE_LIMIT_ENABLED", "true").lower() == "true"
RATE_LIMIT_WINDOW_SEC: int = 60
RATE_LIMIT_MAX: int = 60
LOGIN_RATE_LIMIT_MAX: int = 20
_wl_raw = _str("RATE_LIMIT_WHITELIST", "127.0.0.1,::1")
RATE_LIMIT_WHITELIST: set = {ip.strip() for ip in _wl_raw.split(",") if ip.strip()}


def missing() -> list[str]:
    """Список незаполненных обязательных полей."""
    missing_: list[str] = []
    if not BOT_TOKEN or BOT_TOKEN == "PUT_YOUR_TOKEN_HERE":
        missing_.append("BOT_TOKEN")
    if OWNER_TG_ID == 0:
        missing_.append("OWNER_TG_ID")
    if not SEND_WALLET or SEND_WALLET == "your_username":
        missing_.append("SEND_WALLET")
    if JWT_SECRET in ("", "dev_insecure_secret_change_me", "CHANGE_ME_TO_RANDOM_64_HEX_CHARS"):
        missing_.append("JWT_SECRET")
    return missing_
