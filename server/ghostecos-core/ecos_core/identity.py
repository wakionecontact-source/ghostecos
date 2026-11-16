"""GhostEcos identity and session validation, shared by product routers.

The API contract and existing SQLite schema are kept unchanged during the migration.
"""
import os
import sqlite3
import time
from typing import Optional
from fastapi import HTTPException

from ecos_core.sessions import adopt_legacy_session, ensure_schema, resolve_session

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

def _sso_session_user(token: str) -> Optional[dict]:
    """Токен GhostID, выданный браузеру: в базе соцсети его нет, но сессия живая."""
    try:
        from ecos_core import service_sso as sso
    except Exception:
        return None
    try:
        with sso._db() as c:
            row = c.execute(
                "SELECT user_id, scopes FROM access_tokens WHERE token_hash=? AND expires_at>?",
                (sso._hash(token), int(time.time())),
            ).fetchone()
    except Exception:
        return None
    if not row:
        return None
    scopes = {item for item in str(row["scopes"] or "").split() if item}
    if not scopes & {"identity", "profile", "chat"}:
        return None
    user_id = int(row["user_id"] or 0)
    if user_id <= 0:
        return None
    c = db()
    try:
        user = c.execute(
            "SELECT id, username, display_name FROM users WHERE id=?", (user_id,)
        ).fetchone()
    finally:
        c.close()
    if not user:
        return None
    return {
        "id": int(user["id"]),
        "username": user["username"],
        "display_name": user["display_name"],
        "token": token,
        "is_guest": False,
    }


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
    try:
        ensure_schema(c)
        # New tokens are hash-only records. A found but expired/revoked session
        # raises 401 here and cannot fall through to legacy token tables.
        session_user = resolve_session(c, token)
        if session_user:
            return session_user

        row = c.execute(
            "SELECT u.* FROM users u JOIN soc_tokens t ON t.user_id=u.id WHERE t.token=?",
            (token,),
        ).fetchone()
        if row:
            adopted = adopt_legacy_session(c, token, int(row["id"]))
            if adopted:
                return adopted

        now = int(time.time())
        try:
            revoked = c.execute(
                "SELECT 1 FROM user_devices WHERE token=? AND "
                "(is_active=0 OR is_blocked=1 OR (expires_at>0 AND expires_at<=?)) LIMIT 1",
                (token, now),
            ).fetchone()
            device_user = c.execute(
                "SELECT u.id AS _uid, d.id AS _device_pk, d.device_id AS _did, "
                "d.expires_at AS _device_expires_at FROM users u "
                "JOIN user_devices d ON d.user_id=u.id "
                "WHERE d.token=? AND d.is_active=1 AND d.is_blocked=0 "
                "AND (d.expires_at=0 OR d.expires_at>?) LIMIT 1",
                (token, now),
            ).fetchone()
        except sqlite3.OperationalError as exc:
            if "no such table: user_devices" not in str(exc):
                raise
            revoked = None
            device_user = None

        if device_user:
            adopted = adopt_legacy_session(
                c, token, int(device_user["_uid"]),
                int(device_user["_device_pk"]), int(device_user["_device_expires_at"]),
            )
            if adopted:
                return adopted
        if revoked:
            raise HTTPException(401, "Token revoked or expired")
        sso_user = _sso_session_user(token)
        if sso_user:
            return sso_user
        raise HTTPException(401, "Invalid token")
    finally:
        c.close()

def require_member(user: dict):
    """Эндпоинт требует полноценного аккаунта (не гостя)."""
    if user.get("is_guest"):
        raise HTTPException(403, "Войдите или зарегистрируйтесь, чтобы продолжить")

def auth_member(authorization: Optional[str]) -> dict:
    user = auth(authorization)
    require_member(user)
    return user
