"""
GhostChat — FastAPI Depends() зависимости.
"""
from __future__ import annotations

from typing import Optional
from fastapi import Depends, Header, HTTPException, Request, status

import config
import security
import database as db

# ── Авторизация ────────────────────────────────────────────────────────────────

async def get_current_user(
    authorization: Optional[str] = Header(default=None),
    request: Request = None,
) -> str:
    """
    Возвращает username из JWT-токена.
    Поддерживает: Authorization: Bearer <token>
    """
    token = None
    if authorization and authorization.startswith("Bearer "):
        token = authorization[7:]
    if not token:
        # Попробовать из query-параметра (для WS)
        if request:
            token = request.query_params.get("token")
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Authorization required")

    payload = security.decode_token(token)
    username = payload.get("sub")
    if not username:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token payload")

    # ── Revocation check ──────────────────────────────────────────────────────
    jti = payload.get("jti", "")
    iat = payload.get("iat", 0)

    # 1. Проверить конкретный JTI (logout)
    if jti and await db.is_jti_revoked(jti):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token revoked")

    # 2. Проверить token_min_iat (массовый отзыв всех токенов пользователя)
    if iat:
        row = await db.fetchone(
            "SELECT token_min_iat FROM users WHERE username = ?", (username,)
        )
        if row and iat < row.get("token_min_iat", 0):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token invalidated")

    return username

async def get_current_user_optional(
    authorization: Optional[str] = Header(default=None),
) -> Optional[str]:
    """Возвращает username или None (для публичных эндпоинтов)."""
    if not authorization or not authorization.startswith("Bearer "):
        return None
    try:
        payload = security.decode_token(authorization[7:])
        return payload.get("sub")
    except Exception:
        return None

async def require_premium(username: str = Depends(get_current_user)) -> str:
    """Требует premium-статус."""
    user = await db.fetchone("SELECT is_premium FROM users WHERE username = ?", (username,))
    if not user or not user["is_premium"]:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Premium required")
    return username

async def require_admin(x_admin_token: Optional[str] = Header(default=None)) -> bool:
    """Проверить admin-токен для /api/admin/* эндпоинтов."""
    if not config.ADMIN_TOKEN:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Admin not configured")
    if not x_admin_token or not security.safe_equal(x_admin_token, config.ADMIN_TOKEN):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Invalid admin token")
    return True

async def require_internal(x_internal_key: Optional[str] = Header(default=None)) -> bool:
    """Проверить внутренний ключ для shop_bot → server вызовов."""
    if not config.INTERNAL_KEY:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Internal API not configured")
    if not x_internal_key or not security.safe_equal(x_internal_key, config.INTERNAL_KEY):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Invalid internal key")
    return True

# ── Rate limiting (используется как Depends) ───────────────────────────────────

async def rate_limit_preauth(request: Request) -> None:
    """Применить IP-based rate limit для pre-auth эндпоинтов."""
    security.check_preauth_rate(request)

async def rate_limit_auth(
    request: Request,
    username: str = Depends(get_current_user),
) -> str:
    """Применить user-based rate limit для auth эндпоинтов."""
    security.check_auth_rate(username)
    return username
