"""
GhostChat Server — конфигурация.
Все настройки берутся из переменных окружения (см. .env или systemd Environment=).
"""
import os

# ── Сервер ────────────────────────────────────────────────────────────────────
HOST             = os.getenv("GC_HOST",    "127.0.0.1")
PORT             = int(os.getenv("GC_PORT", "8000"))
DEBUG            = os.getenv("GC_DEBUG",   "").lower() in ("1","true","yes")

# Включить /docs /redoc /openapi.json (ТОЛЬКО для разработки!)
ENABLE_DOCS      = os.getenv("GC_ENABLE_DOCS", "").lower() in ("1","true","yes")

# ── База данных ───────────────────────────────────────────────────────────────
DB_PATH          = os.getenv("GC_DB_PATH",      "/opt/ghostchat/ghostchat.db")
UPLOADS_DIR      = os.getenv("GC_UPLOADS_DIR",  "/opt/ghostchat/uploads")

# ── Безопасность ──────────────────────────────────────────────────────────────
# JWT подпись.
JWT_SECRET       = os.getenv("GC_JWT_SECRET", "")
JWT_ALGO         = "HS256"
JWT_EXPIRE_DAYS  = int(os.getenv("GC_JWT_EXPIRE_DAYS", "30"))

# SECURITY (C1): JWT-секрет ОБЯЗАН быть задан отдельной переменной и быть стойким.
# Раньше он молча падал на GHOSTCHAT_SUPPORT_PASSWORD (= GC_INTERNAL_KEY), и это
# значение лежало в репозитории — кто угодно мог подделать токен любого юзера.
# Падаем при старте, если секрет не задан или слабый.
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

# ── Rate limiting ─────────────────────────────────────────────────────────────
RATE_LIMIT_ENABLED = os.getenv("GC_RATE_LIMIT", "1") not in ("0","false","no")

# Pre-auth endpoints (register/login): N запросов за window секунд с одного IP
RL_PREAUTH_COUNT  = int(os.getenv("GC_RL_PREAUTH_COUNT",  "10"))
RL_PREAUTH_WINDOW = int(os.getenv("GC_RL_PREAUTH_WINDOW", "60"))

# Authenticated endpoints: N запросов за window секунд с одного user
RL_AUTH_COUNT     = int(os.getenv("GC_RL_AUTH_COUNT",  "300"))
RL_AUTH_WINDOW    = int(os.getenv("GC_RL_AUTH_WINDOW", "60"))

# WebSocket connections per IP
RL_WS_PER_IP      = int(os.getenv("GC_RL_WS_PER_IP", "5"))

# ── Приложение ────────────────────────────────────────────────────────────────
LATEST_VERSION   = os.getenv("GC_LATEST_VERSION", "1.19.3")

# ── Файлы ────────────────────────────────────────────────────────────────────
FILE_MAX_MB      = int(os.getenv("GC_FILE_MAX_MB",   "100"))
FILE_EXPIRE_SECS = int(os.getenv("GC_FILE_EXPIRE",   "1800"))  # 30 минут

# ── Premium / Shop ────────────────────────────────────────────────────────────
PRICE_FULL_RUB      = int(os.getenv("GC_PRICE_FULL_RUB",    "490"))
PRICE_DISCOUNT_RUB  = int(os.getenv("GC_PRICE_DISC_RUB",    "245"))
PRICE_FULL_USDT     = float(os.getenv("GC_PRICE_FULL_USDT", "5.50"))
PRICE_DISC_USDT     = float(os.getenv("GC_PRICE_DISC_USDT", "2.75"))
DISCOUNT_HOURS      = int(os.getenv("GC_DISCOUNT_HOURS",    "72"))
PREMIUM_MONTHS      = int(os.getenv("GC_PREMIUM_MONTHS",    "12"))
SEND_URL            = os.getenv("GC_SEND_URL",   "")  # Telegram @send deep link (optional)
DONATE_URL          = os.getenv("GC_DONATE_URL", "")  # any tip-link service URL

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
