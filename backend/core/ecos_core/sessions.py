"""Непрозрачные сессии GhostEcos: токен хранится только хэшем, device_id — метаданные."""
from __future__ import annotations

import hashlib
import os
import secrets
import sqlite3
import threading
import time
from typing import Optional

from fastapi import HTTPException

_SCHEMA_LOCK = threading.Lock()
_SCHEMA_READY: set[str] = set()


def _ttl_seconds() -> int:
    try:
        value = int(os.getenv("GE_AUTH_SESSION_TTL_SECONDS", str(30 * 86400)))
    except (TypeError, ValueError):
        value = 30 * 86400
    return max(300, min(value, 365 * 86400))


def _max_seconds() -> int:
    """Предельный срок жизни сессии от входа, сколько бы она ни продлевалась."""
    try:
        value = int(os.getenv("GE_AUTH_SESSION_MAX_SECONDS", str(365 * 86400)))
    except (TypeError, ValueError):
        value = 365 * 86400
    return max(_ttl_seconds(), min(value, 365 * 86400))


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def ensure_schema(c) -> None:
    """Создаёт схему сессий один раз на путь БД."""
    try:
        rows = c.execute("PRAGMA database_list").fetchall()
        db_path = next((str(row[2]) for row in rows if row[1] == "main"), "")
    except Exception:
        db_path = ""
    key = db_path or f"connection:{id(c)}"
    if key in _SCHEMA_READY:
        return
    with _SCHEMA_LOCK:
        if key in _SCHEMA_READY:
            return
        c.execute("""
            CREATE TABLE IF NOT EXISTS auth_sessions (
                session_id TEXT PRIMARY KEY,
                token_hash TEXT NOT NULL UNIQUE,
                user_id INTEGER NOT NULL,
                device_pk INTEGER,
                auth_method TEXT NOT NULL DEFAULT 'password',
                status TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'expired', 'revoked')),
                created_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                revoked_at INTEGER,
                ended_at INTEGER,
                end_reason TEXT
            )
        """)
        try:
            c.execute("ALTER TABLE auth_sessions ADD COLUMN revoked_at INTEGER")
        except sqlite3.OperationalError:
            pass
        c.execute(
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_created "
            "ON auth_sessions(user_id, created_at DESC)"
        )
        c.execute(
            "CREATE INDEX IF NOT EXISTS idx_auth_sessions_status_expiry "
            "ON auth_sessions(status, expires_at)"
        )
        c.commit()
        _SCHEMA_READY.add(key)


def create_session(c, user_id: int, device_pk: Optional[int] = None,
                   auth_method: str = "password") -> dict:
    ensure_schema(c)
    now = int(time.time())
    expires_at = now + _ttl_seconds()
    if device_pk is not None:
        try:
            device = c.execute(
                "SELECT id, user_id, is_active, is_blocked, expires_at "
                "FROM user_devices WHERE id=?",
                (device_pk,),
            ).fetchone()
        except sqlite3.OperationalError as exc:
            if "no such table: user_devices" in str(exc):
                raise HTTPException(409, "Device enrollment is unavailable")
            raise
        if not device or int(device["user_id"]) != int(user_id):
            raise HTTPException(409, "Device enrollment is unavailable")
        if not device["is_active"] or device["is_blocked"]:
            raise HTTPException(403, "Это устройство заблокировано владельцем аккаунта")
        device_expiry = int(device["expires_at"] or 0)
        if device_expiry > now:
            expires_at = min(expires_at, device_expiry)

    token = secrets.token_urlsafe(48)
    session_id = secrets.token_urlsafe(18)
    c.execute(
        "INSERT INTO auth_sessions "
        "(session_id, token_hash, user_id, device_pk, auth_method, status, "
        "created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?)",
        (session_id, token_hash(token), int(user_id), device_pk,
         str(auth_method)[:32], now, now, expires_at),
    )
    c.commit()
    return {
        "session_id": session_id,
        "session_token": token,
        "token": token,
        "token_type": "Bearer",
        "created_at": now,
        "expires_at": expires_at,
        "expires_in": max(0, expires_at - now),
        "status": "active",
    }


def adopt_legacy_session(c, token: str, user_id: int,
                         device_pk: Optional[int] = None,
                         expires_at: Optional[int] = None) -> Optional[dict]:
    """Привязывает к старому токену метаданные сессии, чтобы его можно было отозвать."""
    ensure_schema(c)
    now = int(time.time())
    digest = token_hash(token)
    found = c.execute(
        "SELECT session_id FROM auth_sessions WHERE token_hash=?", (digest,)
    ).fetchone()
    if found:
        return resolve_session(c, token)
    expiry = int(expires_at or 0)
    if expiry <= now:
        expiry = now + _ttl_seconds()
    session_id = "legacy_" + digest[:32]
    c.execute(
        "INSERT OR IGNORE INTO auth_sessions "
        "(session_id, token_hash, user_id, device_pk, auth_method, status, "
        "created_at, last_seen_at, expires_at) "
        "VALUES (?, ?, ?, ?, 'legacy', 'active', ?, ?, ?)",
        (session_id, digest, int(user_id), device_pk, now, now, expiry),
    )
    c.commit()
    return resolve_session(c, token)


def resolve_session(c, token: str) -> Optional[dict]:
    """Возвращает юзера активной сессии; истёкшая даёт 401 и не оживает через старые таблицы."""
    ensure_schema(c)
    digest = token_hash(token)
    session = c.execute(
        "SELECT * FROM auth_sessions WHERE token_hash=? LIMIT 1", (digest,)
    ).fetchone()
    if not session:
        return None
    now = int(time.time())
    if session["status"] == "revoked":
        raise HTTPException(401, "Session revoked")
    if session["status"] != "active":
        raise HTTPException(401, "Session expired")
    if int(session["expires_at"]) <= now:
        c.execute(
            "UPDATE auth_sessions SET status='expired', ended_at=?, end_reason='expired' "
            "WHERE session_id=? AND status='active'",
            (now, session["session_id"]),
        )
        c.commit()
        raise HTTPException(401, "Session expired")

    if session["auth_method"] == "legacy":
        legacy_active = False
        try:
            legacy_rows = c.execute(
                "SELECT token FROM soc_tokens WHERE user_id=?",
                (session["user_id"],),
            ).fetchall()
            legacy_active = any(
                row["token"] and secrets.compare_digest(token_hash(row["token"]), digest)
                for row in legacy_rows
            )
        except sqlite3.OperationalError:
            pass
        if not legacy_active and session["device_pk"] is not None:
            try:
                legacy_device = c.execute(
                    "SELECT token, is_active, is_blocked, expires_at FROM user_devices "
                    "WHERE id=? AND user_id=?",
                    (session["device_pk"], session["user_id"]),
                ).fetchone()
                legacy_active = bool(
                    legacy_device and legacy_device["token"]
                    and secrets.compare_digest(token_hash(legacy_device["token"]), digest)
                    and legacy_device["is_active"] and not legacy_device["is_blocked"]
                    and (int(legacy_device["expires_at"] or 0) == 0
                         or int(legacy_device["expires_at"]) > now)
                )
            except sqlite3.OperationalError:
                pass
        if not legacy_active:
            c.execute(
                "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, "
                "end_reason='legacy_token_removed' WHERE session_id=? AND status='active'",
                (now, now, session["session_id"]),
            )
            c.commit()
            raise HTTPException(401, "Session revoked")

    device = None
    device_pk = session["device_pk"]
    if device_pk is not None:
        try:
            device = c.execute(
                "SELECT * FROM user_devices WHERE id=? AND user_id=? LIMIT 1",
                (device_pk, session["user_id"]),
            ).fetchone()
        except sqlite3.OperationalError as exc:
            if "no such table: user_devices" not in str(exc):
                raise
        device_expiry = int(device["expires_at"] or 0) if device else 0
        if (not device or not device["is_active"] or device["is_blocked"]
                or (device_expiry > 0 and device_expiry <= now)):
            c.execute(
                "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, "
                "end_reason='device_revoked' WHERE session_id=? AND status='active'",
                (now, now, session["session_id"]),
            )
            c.commit()
            raise HTTPException(401, "Device revoked")

    user = c.execute(
        "SELECT * FROM users WHERE id=? LIMIT 1", (session["user_id"],)
    ).fetchone()
    if not user:
        c.execute(
            "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, "
            "end_reason='account_missing' WHERE session_id=? AND status='active'",
            (now, now, session["session_id"]),
        )
        c.commit()
        raise HTTPException(401, "Account unavailable")

    # Скользящий срок: активность продлевает сессию, но не дальше предела от входа.
    # UPDATE не чаще раза в час, иначе каждая вкладка писала бы в БД на каждый запрос.
    current_expiry = int(session["expires_at"])
    target_expiry = min(now + _ttl_seconds(), int(session["created_at"]) + _max_seconds())
    renew = target_expiry - current_expiry >= 3600
    if renew or now - int(session["last_seen_at"] or 0) >= 300:
        c.execute(
            "UPDATE auth_sessions SET last_seen_at=?, expires_at=? "
            "WHERE session_id=? AND status='active'",
            (now, target_expiry if renew else current_expiry, session["session_id"]),
        )
        if device is not None:
            c.execute("UPDATE user_devices SET last_seen=? WHERE id=?", (now, device_pk))
            if renew and int(device["expires_at"] or 0) > 0:
                c.execute(
                    "UPDATE user_devices SET expires_at=? WHERE id=? AND expires_at<?",
                    (target_expiry, device_pk, target_expiry),
                )
        c.commit()
        if renew:
            session = dict(session, expires_at=target_expiry)

    result = dict(user)
    result.update({
        "_session_id": session["session_id"],
        "_session_status": "active",
        "_session_created_at": int(session["created_at"]),
        "_session_expires_at": int(session["expires_at"]),
        "_device_pk": int(device["id"]) if device is not None else None,
        "_did": device["device_id"] if device is not None else None,
        "is_guest": False,
        "token": token,
    })
    return result


def device_for_token(c, token: str, user_id: int):
    """Находит текущее устройство по старому токену или токену сессии."""
    ensure_schema(c)
    now = int(time.time())
    try:
        device = c.execute(
            "SELECT * FROM user_devices WHERE token=? AND user_id=? "
            "AND is_active=1 AND is_blocked=0 AND (expires_at=0 OR expires_at>?) LIMIT 1",
            (token, int(user_id), now),
        ).fetchone()
    except sqlite3.OperationalError as exc:
        if "no such table: user_devices" in str(exc):
            return None
        raise
    if device:
        return device
    return c.execute(
        "SELECT d.* FROM auth_sessions s JOIN user_devices d ON d.id=s.device_pk "
        "WHERE s.token_hash=? AND s.user_id=? AND s.status='active' AND s.expires_at>? "
        "AND d.is_active=1 AND d.is_blocked=0 AND (d.expires_at=0 OR d.expires_at>?) LIMIT 1",
        (token_hash(token), int(user_id), now, now),
    ).fetchone()


def session_is_active_hash(c, digest: str, user_id: int) -> Optional[bool]:
    """Три состояния: None означает, что хэш не принадлежит сессии."""
    ensure_schema(c)
    now = int(time.time())
    row = c.execute(
        "SELECT s.device_pk, s.auth_method, s.status, s.expires_at FROM auth_sessions s "
        "WHERE s.token_hash=? AND s.user_id=? LIMIT 1",
        (digest, int(user_id)),
    ).fetchone()
    if not row:
        return None
    if row["status"] != "active" or int(row["expires_at"]) <= now:
        return False

    if row["auth_method"] == "legacy":
        # Ротация или удаление старых токенов должна отзывать усыновлённые сессии.
        legacy_tokens = []
        try:
            legacy_tokens.extend(
                item["token"] for item in c.execute(
                    "SELECT token FROM soc_tokens WHERE user_id=?", (int(user_id),)
                ).fetchall() if item["token"]
            )
        except sqlite3.OperationalError:
            pass
        try:
            legacy_tokens.extend(
                item["token"] for item in c.execute(
                    "SELECT token FROM user_devices WHERE user_id=? AND is_active=1 "
                    "AND is_blocked=0 AND (expires_at=0 OR expires_at>?)",
                    (int(user_id), now),
                ).fetchall() if item["token"]
            )
        except sqlite3.OperationalError:
            pass
        return any(secrets.compare_digest(token_hash(value), digest) for value in legacy_tokens)

    if row["device_pk"] is None:
        return True
    device = c.execute(
        "SELECT 1 FROM user_devices WHERE id=? AND user_id=? AND is_active=1 "
        "AND is_blocked=0 AND (expires_at=0 OR expires_at>?) LIMIT 1",
        (row["device_pk"], int(user_id), now),
    ).fetchone()
    return bool(device)


def list_sessions(c, user_id: int, current_session_id: Optional[str]) -> list[dict]:
    ensure_schema(c)
    now = int(time.time())
    c.execute(
        "UPDATE auth_sessions SET status='expired', ended_at=?, end_reason='expired' "
        "WHERE user_id=? AND status='active' AND expires_at<=?",
        (now, int(user_id), now),
    )
    c.commit()
    try:
        rows = c.execute(
            "SELECT s.session_id, s.device_pk, s.auth_method, s.status, s.created_at, "
            "s.last_seen_at, s.expires_at, s.ended_at, s.end_reason, "
            "d.device_id, d.device_name, d.platform "
            "FROM auth_sessions s LEFT JOIN user_devices d ON d.id=s.device_pk "
            "WHERE s.user_id=? ORDER BY s.created_at DESC LIMIT 100",
            (int(user_id),),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        if "no such table: user_devices" not in str(exc):
            raise
        rows = c.execute(
            "SELECT session_id, device_pk, auth_method, status, created_at, "
            "last_seen_at, expires_at, ended_at, end_reason, "
            "NULL AS device_id, NULL AS device_name, NULL AS platform "
            "FROM auth_sessions WHERE user_id=? ORDER BY created_at DESC LIMIT 100",
            (int(user_id),),
        ).fetchall()
    return [
        {
            "session_id": row["session_id"],
            "status": row["status"],
            "auth_method": row["auth_method"],
            "created_at": int(row["created_at"]),
            "last_seen_at": int(row["last_seen_at"]),
            "expires_at": int(row["expires_at"]),
            "ended_at": row["ended_at"],
            "end_reason": row["end_reason"],
            "device": ({
                "device_id": row["device_id"],
                "name": row["device_name"],
                "platform": row["platform"],
            } if row["device_pk"] is not None else None),
            "is_current": row["session_id"] == current_session_id,
        }
        for row in rows
    ]


def revoke_session(c, user_id: int, session_id: str,
                   reason: str = "user_revoked") -> bool:
    ensure_schema(c)
    if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128:
        raise HTTPException(422, "Invalid session_id")
    now = int(time.time())
    cur = c.execute(
        "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, end_reason=? "
        "WHERE session_id=? AND user_id=? AND status='active'",
        (now, now, str(reason)[:64], session_id, int(user_id)),
    )
    c.commit()
    return cur.rowcount == 1


def revoke_all_sessions(c, user_id: int, reason: str = "security_event",
                        except_session_id: Optional[str] = None) -> int:
    ensure_schema(c)
    now = int(time.time())
    if except_session_id:
        cur = c.execute(
            "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, end_reason=? "
            "WHERE user_id=? AND status='active' AND session_id<>?",
            (now, now, str(reason)[:64], int(user_id), except_session_id),
        )
    else:
        cur = c.execute(
            "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, end_reason=? "
            "WHERE user_id=? AND status='active'",
            (now, now, str(reason)[:64], int(user_id)),
        )
    c.commit()
    return cur.rowcount


def logout(c, user: dict) -> dict:
    session_id = user.get("_session_id")
    if session_id:
        revoke_session(c, int(user["id"]), session_id, "logout")
    return {"ok": True, "session_id": session_id}


def revoke_device_sessions(c, device_pk: int,
                           reason: str = "device_revoked") -> int:
    ensure_schema(c)
    now = int(time.time())
    cur = c.execute(
        "UPDATE auth_sessions SET status='revoked', revoked_at=?, ended_at=?, end_reason=? "
        "WHERE device_pk=? AND status='active'",
        (now, now, str(reason)[:64], int(device_pk)),
    )
    c.commit()
    return cur.rowcount


def list_for_token(authorization: Optional[str]) -> dict:
    from ecos_core.identity import auth, db, require_member
    user = auth(authorization)
    require_member(user)
    c = db()
    try:
        adopt_legacy_sessions_for_user(c, int(user["id"]))
        return {
            "current_session_id": user.get("_session_id"),
            "sessions": list_sessions(c, int(user["id"]), user.get("_session_id")),
        }
    finally:
        c.close()


def logout_for_token(authorization: Optional[str]) -> dict:
    from ecos_core.identity import auth, db, require_member
    user = auth(authorization)
    require_member(user)
    c = db()
    try:
        return logout(c, user)
    finally:
        c.close()


def revoke_for_token(authorization: Optional[str], session_id: str) -> dict:
    from ecos_core.identity import auth, db, require_member
    user = auth(authorization)
    require_member(user)
    c = db()
    try:
        return {"ok": revoke_session(c, int(user["id"]), session_id)}
    finally:
        c.close()


def adopt_legacy_sessions_for_user(c, user_id: int) -> None:
    """Показывает активные старые токены в списке сессий."""
    ensure_schema(c)
    now = int(time.time())
    legacy = []
    try:
        for row in c.execute(
            "SELECT * FROM soc_tokens WHERE user_id=?", (int(user_id),)
        ).fetchall():
            token = row["token"]
            expiry = int(row["expires_at"] or 0) if "expires_at" in row.keys() else 0
            if token and (expiry == 0 or expiry > now):
                legacy.append((token, None, expiry))
    except sqlite3.OperationalError:
        pass
    try:
        for row in c.execute(
            "SELECT id, token, is_active, is_blocked, expires_at FROM user_devices "
            "WHERE user_id=? AND token IS NOT NULL AND is_active=1 AND is_blocked=0",
            (int(user_id),),
        ).fetchall():
            expiry = int(row["expires_at"] or 0)
            if expiry == 0 or expiry > now:
                legacy.append((row["token"], int(row["id"]), expiry))
    except sqlite3.OperationalError:
        pass

    for token, device_pk, expiry in legacy:
        digest = token_hash(token)
        if c.execute(
            "SELECT 1 FROM auth_sessions WHERE token_hash=? LIMIT 1", (digest,)
        ).fetchone():
            continue
        session_id = "legacy_" + digest[:32]
        c.execute(
            "INSERT OR IGNORE INTO auth_sessions "
            "(session_id, token_hash, user_id, device_pk, auth_method, status, "
            "created_at, last_seen_at, expires_at) "
            "VALUES (?, ?, ?, ?, 'legacy', 'active', ?, ?, ?)",
            (session_id, digest, int(user_id), device_pk, now, now,
             expiry if expiry > now else now + _ttl_seconds()),
        )
    c.commit()
