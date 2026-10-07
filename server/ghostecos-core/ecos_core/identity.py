"""GhostEcos identity and session validation, shared by product routers.

The API contract and existing SQLite schema are kept unchanged during the migration.
"""
import os
import sqlite3
from typing import Optional
from fastapi import HTTPException

DB = os.getenv("SOCIAL_DB_PATH", "/opt/ghostchat/ghostchat.db")

def _ci_contains(haystack, needle):
    if haystack is None or needle is None:
        return 0
    return 1 if needle.lower() in haystack.lower() else 0

def db():
    # timeout=5: вместо мгновенного 'database is locked' ждём до 5 сек на освобождение
    c = sqlite3.connect(os.environ.get("SOCIAL_DB_PATH", DB), timeout=5.0)
    c.row_factory = sqlite3.Row
    c.create_function("ci_contains", 2, _ci_contains, deterministic=True)
    try:
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.execute("PRAGMA busy_timeout=5000")
    except Exception:
        pass
    return c

def auth(authorization: Optional[str]) -> dict:
    if not authorization or not authorization.strip():
        raise HTTPException(401, "Missing token")
    scheme, separator, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not separator:
        raise HTTPException(401, "Invalid authorization header")
    token = token.strip()
    if not token:
        raise HTTPException(401, "Missing token")
    if token.startswith("guest_") and len(token) > 16:
        return {"id": 0, "username": "__guest__", "display_name": "Гость", "token": token, "is_guest": True}
    c = db()
    row = c.execute(
        "SELECT u.* FROM users u JOIN soc_tokens t ON t.user_id = u.id WHERE t.token = ?",
        (token,),
    ).fetchone()
    if not row:
        # Токен мог существовать, но устройство уже отозвано/заблокировано.
        # Это отдельная причина для клиента: сессию нельзя продолжать.
        try:
            revoked = c.execute(
                "SELECT 1 FROM user_devices WHERE token=? AND (is_active=0 OR is_blocked=1) LIMIT 1",
                (token,),
            ).fetchone()
            row = c.execute(
                "SELECT u.*, d.id AS _device_pk, d.device_id AS _did FROM users u "
                "JOIN user_devices d ON d.user_id = u.id "
                "WHERE d.token=? AND d.is_active=1 AND d.is_blocked=0 LIMIT 1",
                (token,),
            ).fetchone()
        except sqlite3.OperationalError as exc:
            if "no such table: user_devices" not in str(exc):
                c.close()
                raise
            revoked = None
            row = None
    else:
        revoked = None
    c.close()
    if not row:
        if revoked:
            raise HTTPException(401, "Token revoked")
        raise HTTPException(401, "Invalid token")
    u = dict(row)
    u["is_guest"] = False
    u["token"] = token
    return u

def require_member(user: dict):
    """Эндпоинт требует полноценного аккаунта (не гостя)."""
    if user.get("is_guest"):
        raise HTTPException(403, "Войдите или зарегистрируйтесь, чтобы продолжить")

def auth_member(authorization: Optional[str]) -> dict:
    user = auth(authorization)
    require_member(user)
    return user
