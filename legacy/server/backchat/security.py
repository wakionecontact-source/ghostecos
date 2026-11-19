"""
GhostChat — безопасность: JWT, пароли, rate-limiting, DDoS-защита.

Метаданные (IP, токены) обрабатываются ТОЛЬКО в памяти процесса —
никогда не пишутся в БД или логи.
"""
from __future__ import annotations

import time
import hashlib
import hmac
import collections
import threading
from typing import Optional

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, VerificationError, InvalidHashError
from fastapi import HTTPException, Request, status

import config

# ── Хэширование паролей ────────────────────────────────────────────────────────
_ph = PasswordHasher(
    time_cost=2,
    memory_cost=65536,
    parallelism=2,
    hash_len=32,
    salt_len=16,
)

def hash_password(plain: str) -> str:
    return _ph.hash(plain)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _ph.verify(hashed, plain)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False

def needs_rehash(hashed: str) -> bool:
    return _ph.check_needs_rehash(hashed)

# ── JWT ────────────────────────────────────────────────────────────────────────
def create_token(username: str, device_id: str = "") -> str:
    """Создаёт JWT токен с JTI (уникальным ID для отзыва)."""
    import uuid as _uuid
    ts = int(time.time())
    payload = {
        "sub": username,
        "iat": ts,
        "exp": ts + config.JWT_EXPIRE_DAYS * 86400,
        "jti": str(_uuid.uuid4()),   # уникальный ID — нужен для logout/revocation
    }
    if device_id:
        payload["did"] = device_id
    return jwt.encode(payload, config.JWT_SECRET, algorithm=config.JWT_ALGO)

def decode_token(token: str) -> dict:
    """Декодирует JWT. Бросает HTTPException при невалидном токене."""
    try:
        return jwt.decode(token, config.JWT_SECRET, algorithms=[config.JWT_ALGO])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")

def decode_token_soft(token: str) -> Optional[dict]:
    """Декодирует JWT без исключений. Возвращает None при ошибке."""
    try:
        return jwt.decode(token, config.JWT_SECRET, algorithms=[config.JWT_ALGO])
    except Exception:
        return None

def get_username_from_token(token: str) -> Optional[str]:
    payload = decode_token_soft(token)
    return payload.get("sub") if payload else None

# ── Константный time-safe compare ──────────────────────────────────────────────
def safe_equal(a: str, b: str) -> bool:
    """Сравнение строк без timing-атак."""
    return hmac.compare_digest(
        a.encode() if isinstance(a, str) else a,
        b.encode() if isinstance(b, str) else b,
    )

# ── Rate Limiter (sliding window, in-memory) ───────────────────────────────────
# ВАЖНО: все данные — только в RAM, при перезапуске сбрасываются.
# Метаданные запросов (IP/user/время) НЕ пишутся в БД/логи.

class _SlidingWindow:
    """Thread-safe sliding window counter."""
    def __init__(self, limit: int, window: int):
        self.limit  = limit
        self.window = window
        self._data: dict[str, collections.deque] = {}
        self._lock  = threading.Lock()

    def is_allowed(self, key: str) -> bool:
        if not config.RATE_LIMIT_ENABLED:
            return True
        now = time.time()
        with self._lock:
            if key not in self._data:
                self._data[key] = collections.deque()
            dq = self._data[key]
            # Удаляем старые записи
            cutoff = now - self.window
            while dq and dq[0] < cutoff:
                dq.popleft()
            if len(dq) >= self.limit:
                return False
            dq.append(now)
            return True

    def cleanup(self):
        """Периодическая очистка старых ключей."""
        now = time.time()
        with self._lock:
            cutoff = now - self.window
            dead = [k for k, dq in self._data.items()
                    if not dq or dq[-1] < cutoff]
            for k in dead:
                del self._data[k]


# Лимиты: pre-auth (по IP), auth (по username), global (DDoS)
_rl_preauth = _SlidingWindow(config.RL_PREAUTH_COUNT,  config.RL_PREAUTH_WINDOW)
_rl_auth    = _SlidingWindow(config.RL_AUTH_COUNT,     config.RL_AUTH_WINDOW)
_rl_ws_ip   = _SlidingWindow(config.RL_WS_PER_IP * 2, 10)  # буфер WS по IP
_rl_global  = _SlidingWindow(500, 60)  # 500 запросов/мин с одного IP (anti-flood)


def _get_ip(request: Request) -> str:
    """Получить IP клиента. IP используется ТОЛЬКО для rate-limit, не хранится."""
    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"

def _has_bypass(request: Request) -> bool:
    """Проверить bypass-токен (разработчик/сервер)."""
    if not config.BYPASS_TOKEN:
        return False
    hdr = request.headers.get("X-Ghost-Bypass", "")
    return safe_equal(hdr, config.BYPASS_TOKEN)

def check_preauth_rate(request: Request):
    """Rate-limit для pre-auth эндпоинтов (register, login) — по IP."""
    if _has_bypass(request):
        return
    ip = _get_ip(request)
    if not _rl_preauth.is_allowed(ip):
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many requests. Try again later.",
            headers={"Retry-After": str(config.RL_PREAUTH_WINDOW)},
        )

def check_auth_rate(username: str):
    """Rate-limit для auth эндпоинтов — по username."""
    if not _rl_auth.is_allowed(username):
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many requests. Try again later.",
            headers={"Retry-After": str(config.RL_AUTH_WINDOW)},
        )

def check_ws_rate(request: Request) -> bool:
    """Проверить лимит WS-подключений по IP. False → отклонить."""
    if _has_bypass(request):
        return True
    ip = _get_ip(request)
    return _rl_ws_ip.is_allowed(ip)

def check_global_rate(ip: str):
    """Глобальный IP rate limit для DDoS middleware. Бросает HTTPException при превышении."""
    if not config.RATE_LIMIT_ENABLED:
        return
    if not _rl_global.is_allowed(ip):
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many requests",
            headers={"Retry-After": "60"},
        )

def cleanup_rate_limiters():
    """Вызывать периодически для освобождения памяти."""
    _rl_preauth.cleanup()
    _rl_auth.cleanup()
    _rl_ws_ip.cleanup()
    _rl_global.cleanup()

# ── Хэш для анонимизации метаданных ───────────────────────────────────────────
def _meta_hash(value: str) -> str:
    """
    Одностороннее хэширование значения метаданных (например, from/to в БД).
    Сервер может проверить совпадение, но не восстановить исходное значение без ключа.

    НЕ используется для маршрутизации (там нужен оригинал), но может применяться
    в аналитических/статистических таблицах.
    """
    return hashlib.sha256(
        f"{config.JWT_SECRET}:{value}".encode()
    ).hexdigest()[:32]

# ── Хэш кода подтверждения устройства ──────────────────────────────────────────
def hash_code(code: str) -> str:
    """Keyed-хэш 6-значного кода подтверждения нового устройства.
    Сервер хранит ТОЛЬКО хэш и сам сверяет введённый код (constant-time),
    а не доверяет клиентскому boolean «совпало» (дыры C2/C3)."""
    return hashlib.sha256(
        f"{config.JWT_SECRET}:devcode:{code}".encode()
    ).hexdigest()
