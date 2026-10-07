"""Issue signed SSO tokens from the identity-owning Core process."""
import os
import time
from typing import Optional
from fastapi import HTTPException
from ecos_core.identity import auth_member


def sso_issue_jwt(authorization: Optional[str]):
    """Принимает обычный gs_token, возвращает JWT (HS256, GC_JWT_SECRET).
    Используется микросервисами на отдельных портах (GhostNation /api/nation/
    и т.п.) — там JWT-валидация быстрее чем походы в БД за токеном.

    sub  = username
    iat  = время выпуска
    exp  = +24ч
    """
    user = auth_member(authorization)
    try:
        import jwt as _jwt
    except ImportError:
        raise HTTPException(500, "PyJWT не установлен")
    secret = os.getenv("GC_JWT_SECRET", "").strip()
    if not secret:
        raise HTTPException(500, "GC_JWT_SECRET не задан в окружении")
    now = int(time.time())
    payload = {
        "sub": user["username"],
        "uid": user["id"],
        "display_name": user.get("display_name") or user["username"],
        "iat": now,
        "exp": now + 86400,
    }
    token_jwt = _jwt.encode(payload, secret, algorithm="HS256")
    if isinstance(token_jwt, bytes):
        token_jwt = token_jwt.decode("utf-8")
    return {
        "jwt": token_jwt,
        "username": user["username"],
        "display_name": user.get("display_name") or user["username"],
        "expires_at": now + 86400,
    }
