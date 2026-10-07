"""Trusted-device helpers for the standalone GhostSocial service."""
from __future__ import annotations

import time
import uuid
from typing import Optional

from fastapi import HTTPException

DEVICE_TOKEN_TTL = 30 * 86400


def now_ts() -> int:
    return int(time.time())


def gen_token() -> str:
    return uuid.uuid4().hex + uuid.uuid4().hex


def init_devices_table(c) -> None:
    c.execute("""
        CREATE TABLE IF NOT EXISTS user_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            device_name TEXT,
            platform TEXT,
            token TEXT UNIQUE,
            pub_key TEXT,
            is_owner INTEGER NOT NULL DEFAULT 0,
            level INTEGER NOT NULL DEFAULT 1,
            is_active INTEGER NOT NULL DEFAULT 1,
            is_blocked INTEGER NOT NULL DEFAULT 0,
            vpn_detected INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            expires_at INTEGER NOT NULL DEFAULT 0,
            UNIQUE(user_id, device_id)
        )
    """)
    for col in ("pub_key TEXT NULL", "expires_at INTEGER NOT NULL DEFAULT 0"):
        try:
            c.execute(f"ALTER TABLE user_devices ADD COLUMN {col}")
        except Exception:
            pass
    c.execute("CREATE INDEX IF NOT EXISTS idx_user_devices_token ON user_devices(token)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_user_devices_user ON user_devices(user_id)")
    c.commit()


def _validate_device_id(device_id: Optional[str]) -> str:
    if device_id is None or not str(device_id).strip():
        return str(uuid.uuid4())
    did = str(device_id).strip()
    if len(did) > 128 or any(ord(ch) < 0x20 for ch in did):
        raise HTTPException(400, "Некорректный идентификатор устройства")
    return did


def register_device(c, user_id: int, device_id: Optional[str],
                    device_name: Optional[str], platform: Optional[str] = None,
                    is_owner: bool = False) -> dict:
    did = _validate_device_id(device_id)
    name = (device_name or "Неизвестное устройство").strip()[:120]
    plat = (platform or "unknown").strip()[:32]
    now = now_ts()
    existing = c.execute(
        "SELECT id, token, is_active, is_blocked, expires_at FROM user_devices "
        "WHERE user_id=? AND device_id=? LIMIT 1",
        (user_id, did),
    ).fetchone()
    if existing:
        if existing["is_blocked"]:
            raise HTTPException(403, "Это устройство заблокировано владельцем аккаунта")
        token = existing["token"]
        expires_at = int(existing["expires_at"] or 0)
        if not existing["is_active"] or not token or expires_at <= now:
            token = gen_token()
            expires_at = now + DEVICE_TOKEN_TTL
            c.execute(
                "UPDATE user_devices SET token=?, is_active=1, expires_at=?, "
                "last_seen=?, device_name=?, platform=? WHERE id=?",
                (token, expires_at, now, name, plat, existing["id"]),
            )
        else:
            c.execute(
                "UPDATE user_devices SET last_seen=?, device_name=?, platform=? WHERE id=?",
                (now, name, plat, existing["id"]),
            )
        c.commit()
        return {"device_id": did, "token": token, "is_new": False}

    token = gen_token()
    c.execute(
        "INSERT INTO user_devices "
        "(user_id, device_id, device_name, platform, token, is_owner, level, "
        "created_at, last_seen, expires_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (user_id, did, name, plat, token, 1 if is_owner else 0,
         999999 if is_owner else 1, now, now, now + DEVICE_TOKEN_TTL),
    )
    c.commit()
    return {"device_id": did, "token": token, "is_new": True}


def auth_device_token(c, token: str) -> Optional[dict]:
    if not token:
        return None
    row = c.execute(
        "SELECT * FROM user_devices WHERE token=? AND is_active=1 "
        "AND is_blocked=0 AND expires_at>? LIMIT 1",
        (token, now_ts()),
    ).fetchone()
    if not row:
        return None
    c.execute("UPDATE user_devices SET last_seen=? WHERE id=?", (now_ts(), row["id"]))
    c.commit()
    return dict(row)


def list_user_devices(c, user_id: int) -> list:
    rows = c.execute(
        "SELECT id, device_id, device_name, platform, is_owner, level, is_active, "
        "is_blocked, vpn_detected, created_at, last_seen, expires_at "
        "FROM user_devices WHERE user_id=? ORDER BY is_owner DESC, last_seen DESC",
        (user_id,),
    ).fetchall()
    hour = 3600
    out = []
    for row in rows:
        item = dict(row)
        if item.get("last_seen"):
            item["last_seen"] = (int(item["last_seen"]) // hour) * hour
        out.append(item)
    return out


def revoke_device(c, user_id: int, device_pk: int) -> bool:
    row = c.execute(
        "SELECT id, is_owner FROM user_devices WHERE id=? AND user_id=? LIMIT 1",
        (device_pk, user_id),
    ).fetchone()
    if not row:
        return False
    if row["is_owner"]:
        raise HTTPException(400, "Нельзя отозвать owner-устройство")
    # Explicit device revoke is stronger than logout.  Keep the device on the
    # account for audit/UI purposes, but block re-login with the same device_id
    # so register_device() cannot silently reactivate a revoked device.
    c.execute(
        "UPDATE user_devices SET is_active=0, is_blocked=1 WHERE id=?",
        (row["id"],),
    )
    c.commit()
    return True
