"""GhostChat Server — конфигурация из переменных окружения (.env / systemd)."""
import ipaddress
import os

# ── Сервер ────────────────────────────────────────────────────────────────────
HOST             = os.getenv("GC_HOST",    "127.0.0.1")
PORT             = int(os.getenv("GC_PORT", "8000"))
DEBUG            = os.getenv("GC_DEBUG",   "").lower() in ("1","true","yes")

# /docs /redoc /openapi.json — только для разработки!
ENABLE_DOCS      = os.getenv("GC_ENABLE_DOCS", "").lower() in ("1","true","yes")

# ── База данных ───────────────────────────────────────────────────────────────
DB_PATH          = os.getenv("GC_DB_PATH",      "/opt/ghostchat/ghostchat.db")
UPLOADS_DIR      = os.getenv("GC_UPLOADS_DIR",  "/opt/ghostchat/uploads")

# ── Безопасность ──────────────────────────────────────────────────────────────
# JWT подпись.
JWT_SECRET       = os.getenv("GC_JWT_SECRET", "")
JWT_ALGO         = "HS256"
JWT_EXPIRE_DAYS  = int(os.getenv("GC_JWT_EXPIRE_DAYS", "30"))

# SECURITY: JWT-секрет обязан быть отдельной стойкой переменной; раньше он молча
# подменялся на GHOSTCHAT_SUPPORT_PASSWORD, лежавший в репозитории.
if not JWT_SECRET or len(JWT_SECRET) < 32:
    raise RuntimeError(
        "GC_JWT_SECRET must be set to a strong secret (>=32 chars), separate from "
        "any other credential. Refusing to start with an insecure/missing JWT secret."
    )

# Токен для обхода rate-limit (только для разработчика/сервера)
BYPASS_TOKEN     = os.getenv("GC_BYPASS_TOKEN", "")

# Внутренний ключ shop_bot → main API
INTERNAL_KEY     = os.getenv("GC_INTERNAL_KEY", "")

# Токен для /api/admin/* эндпоинтов
ADMIN_TOKEN      = os.getenv("GC_ADMIN_TOKEN",  os.getenv("GHOSTCHAT_ADMIN_KEY", ""))

# Пароль поддержки
SUPPORT_PASSWORD = os.getenv("GC_SUPPORT_PASSWORD", os.getenv("GHOSTCHAT_SUPPORT_PASSWORD", ""))

# ── Ограничение частоты ─────────────────────────────────────────────────────────
RATE_LIMIT_ENABLED = os.getenv("GC_RATE_LIMIT", "1") not in ("0","false","no")

def _parse_rate_limit_exempt_ips(value: str) -> frozenset[str]:
    """Разбирает только канонические IP; кривые записи allowlist игнорируются."""
    out: set[str] = set()
    for raw in value.split(","):
        candidate = raw.strip()
        if not candidate:
            continue
        try:
            out.add(str(ipaddress.ip_address(candidate)))
        except ValueError:
            continue
    return frozenset(out)


# Точные egress-IP оператора: снимают только rate-лимиты, аутентификация остаётся.
RATE_LIMIT_EXEMPT_IPS = _parse_rate_limit_exempt_ips(
    os.getenv("GC_RATE_LIMIT_EXEMPT_IPS", "")
)

# Pre-auth (register/login): N запросов за window секунд с одного IP
RL_PREAUTH_COUNT  = int(os.getenv("GC_RL_PREAUTH_COUNT",  "10"))
RL_PREAUTH_WINDOW = int(os.getenv("GC_RL_PREAUTH_WINDOW", "60"))

# Authenticated: N запросов за window секунд с одного юзера
RL_AUTH_COUNT     = int(os.getenv("GC_RL_AUTH_COUNT",  "300"))
RL_AUTH_WINDOW    = int(os.getenv("GC_RL_AUTH_WINDOW", "60"))

# WS-соединений с одного IP
RL_WS_PER_IP      = int(os.getenv("GC_RL_WS_PER_IP", "5"))

# ── Приложение ────────────────────────────────────────────────────────────────
LATEST_VERSION   = os.getenv("GC_LATEST_VERSION", "1.1.27")
BETA_RELEASE_AT  = os.getenv("GC_BETA_RELEASE_AT", "2026-09-06T17:39:20+03:00")
LATEST_CRITICAL  = os.getenv("GC_LATEST_CRITICAL", "0").lower() in ("1", "true", "yes")

# ── Файлы ────────────────────────────────────────────────────────────────────
FILE_MAX_MB      = int(os.getenv("GC_FILE_MAX_MB",   "100"))
FILE_EXPIRE_SECS = int(os.getenv("GC_FILE_EXPIRE",   "1800"))  # 30 минут

# ── Премиум / Магазин ──
PRICE_FULL_RUB      = int(os.getenv("GC_PRICE_FULL_RUB",    "490"))
PRICE_DISCOUNT_RUB  = int(os.getenv("GC_PRICE_DISC_RUB",    "245"))
PRICE_FULL_USDT     = float(os.getenv("GC_PRICE_FULL_USDT", "5.50"))
PRICE_DISC_USDT     = float(os.getenv("GC_PRICE_DISC_USDT", "2.75"))
DISCOUNT_HOURS      = int(os.getenv("GC_DISCOUNT_HOURS",    "72"))
PREMIUM_MONTHS      = int(os.getenv("GC_PREMIUM_MONTHS",    "12"))
SEND_URL            = os.getenv("GC_SEND_URL",   "https://t.me/send?start=IV4qJ3pfGkgA")
DONATE_URL          = os.getenv("GC_DONATE_URL", "https://dalink.to/waki_ss")

# ── Пути к статике ────────────────────────────────────────────────────────────
import os as _os
_HERE = _os.path.dirname(_os.path.abspath(__file__))
SITE_DIR = _os.path.join(_HERE, "site")

# ── Фоновые задачи ────────────────────────────────────────────────────────────
HEARTBEAT_TIMEOUT   = 25   # секунд тишины → офлайн
FILE_LOOP_INTERVAL  = 30   # секунд между проверками файлов
CLEANUP_INTERVAL    = 86400  # раз в сутки

# Сколько хранить офлайн-сообщения (7 дней)
MSG_RETAIN_DAYS     = int(os.getenv("GC_MSG_RETAIN_DAYS", "7"))
# Сколько хранить сообщения каналов (30 дней)
CH_MSG_RETAIN_DAYS  = int(os.getenv("GC_CH_MSG_RETAIN_DAYS", "30"))
