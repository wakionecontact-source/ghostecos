"""Account-bound, scoped API credentials for GhostStudio.

Raw API keys are displayed once and only SHA-256 digests are persisted.
Keys authenticate only the explicitly scoped developer API routes.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ecos_core.identity import auth_member, db as identity_db
from ecos_core.shared import _rate_limit

router = APIRouter(prefix="/api/developer", tags=["GhostStudio API keys"])
_KEY_RE = re.compile(r"^ge_live_[A-Za-z0-9_-]{43}$")
_KEY_ID_RE = re.compile(r"^[A-Za-z0-9_-]{16}$")
_ALLOWED_SCOPES = {"identity:read", "profile:read", "projects:read", "projects:write"}
_KEY_TTL_MAX_DAYS = 365


class CreateKeyBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=60)
    scopes: list[str] = Field(min_length=1, max_length=4)
    expires_in_days: int = Field(default=90, ge=1, le=_KEY_TTL_MAX_DAYS)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if not value or any(ord(ch) < 32 or 127 <= ord(ch) <= 159 for ch in value):
            raise ValueError("Укажи короткое название без управляющих символов")
        return value


def _path() -> Path:
    return Path(os.getenv(
        "GE_API_KEYS_DB_PATH",
        "/opt/ghostecos-core/private/api_keys.sqlite3",
    ))


@contextmanager
def _db():
    path = _path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=5)
    connection.row_factory = sqlite3.Row
    os.chmod(path, 0o600)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=5000")
    connection.executescript("""
        CREATE TABLE IF NOT EXISTS api_keys (
            key_id TEXT PRIMARY KEY,
            token_hash TEXT NOT NULL UNIQUE,
            key_hint TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            scopes TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            last_used_at INTEGER,
            revoked_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_api_keys_user_created
            ON api_keys(user_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_api_keys_expiry
            ON api_keys(expires_at);
    """)
    connection.commit()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def _account(request: Request) -> dict:
    authorization = request.headers.get("authorization")
    if not authorization and request.headers.get("x-gs-token"):
        authorization = "Bearer " + request.headers["x-gs-token"]
    return auth_member(authorization)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def _key_status(row, now: int) -> str:
    if row["revoked_at"] is not None:
        return "revoked"
    if int(row["expires_at"]) <= now:
        return "expired"
    return "active"


def _public_key(row, now: int) -> dict:
    return {
        "key_id": row["key_id"],
        "name": row["name"],
        "hint": "ge_live_••••" + row["key_hint"],
        "scopes": json.loads(row["scopes"]),
        "status": _key_status(row, now),
        "created_at": int(row["created_at"]),
        "expires_at": int(row["expires_at"]),
        "last_used_at": int(row["last_used_at"]) if row["last_used_at"] else None,
        "revoked_at": int(row["revoked_at"]) if row["revoked_at"] else None,
    }


@router.get("/keys")
def list_keys(request: Request):
    user = _account(request)
    now = int(time.time())
    with _db() as connection:
        rows = connection.execute(
            "SELECT * FROM api_keys WHERE user_id=? ORDER BY created_at DESC LIMIT 100",
            (int(user["id"]),),
        ).fetchall()
        return {"keys": [_public_key(row, now) for row in rows]}


@router.post("/keys", status_code=201)
def create_key(body: CreateKeyBody, request: Request):
    user = _account(request)
    _rate_limit("ghoststudio-api-key-create:" + str(int(user["id"])), limit=5, window=3600)
    scopes = list(dict.fromkeys(body.scopes))
    if "identity:read" not in scopes or not set(scopes) <= _ALLOWED_SCOPES:
        raise HTTPException(422, "Выбери identity:read и только доступные разрешения")
    if "projects:write" in scopes and "projects:read" not in scopes:
        raise HTTPException(422, "Для изменения проектов нужно также выбрать projects:read")

    now = int(time.time())
    token = "ge_live_" + secrets.token_urlsafe(32)
    key_id = secrets.token_urlsafe(12)
    expires_at = now + int(body.expires_in_days) * 86400
    with _db() as connection:
        active_count = connection.execute(
            "SELECT COUNT(*) AS n FROM api_keys WHERE user_id=? AND revoked_at IS NULL AND expires_at>?",
            (int(user["id"]), now),
        ).fetchone()["n"]
        if int(active_count) >= 20:
            raise HTTPException(409, "Можно иметь не больше 20 активных API-ключей")
        connection.execute(
            "INSERT INTO api_keys "
            "(key_id, token_hash, key_hint, user_id, name, scopes, created_at, expires_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (key_id, _hash(token), token[-4:], int(user["id"]), body.name,
             json.dumps(scopes, separators=(",", ":")), now, expires_at),
        )
        row = connection.execute(
            "SELECT * FROM api_keys WHERE key_id=?", (key_id,)
        ).fetchone()
    return {"api_key": token, **_public_key(row, now)}


@router.post("/keys/{key_id}/revoke")
def revoke_key(key_id: str, request: Request):
    user = _account(request)
    if not _KEY_ID_RE.fullmatch(key_id):
        raise HTTPException(404, "API-ключ не найден")
    now = int(time.time())
    with _db() as connection:
        changed = connection.execute(
            "UPDATE api_keys SET revoked_at=? "
            "WHERE key_id=? AND user_id=? AND revoked_at IS NULL",
            (now, key_id, int(user["id"])),
        ).rowcount
        if changed != 1:
            raise HTTPException(404, "Активный API-ключ не найден")
    return {"ok": True, "key_id": key_id, "status": "revoked", "revoked_at": now}


def _api_key_identity(request: Request) -> tuple[dict, list[str]]:
    header = request.headers.get("authorization", "")
    scheme, separator, token = header.partition(" ")
    if scheme.lower() != "bearer" or not separator or not _KEY_RE.fullmatch(token):
        raise HTTPException(401, "Нужен API-ключ GhostStudio в заголовке Authorization")
    now = int(time.time())
    with _db() as connection:
        row = connection.execute(
            "SELECT key_id, user_id, scopes FROM api_keys "
            "WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?",
            (_hash(token), now),
        ).fetchone()
        if not row:
            raise HTTPException(401, "API-ключ недействителен, истёк или отозван")
        key_id, user_id = row["key_id"], int(row["user_id"])
        scopes = json.loads(row["scopes"])
        connection.execute(
            "UPDATE api_keys SET last_used_at=? WHERE key_id=? AND revoked_at IS NULL",
            (now, key_id),
        )

    account_connection = identity_db()
    try:
        columns = {row["name"] for row in account_connection.execute("PRAGMA table_info(users)")}
        public_columns = [name for name in ("id", "username", "display_name", "avatar_url") if name in columns]
        account = account_connection.execute(
            "SELECT " + ", ".join(public_columns) + " FROM users WHERE id=? LIMIT 1",
            (user_id,),
        ).fetchone()
    finally:
        account_connection.close()
    if not account:
        raise HTTPException(401, "Аккаунт API-ключа больше не существует")
    if "identity:read" not in scopes:
        raise HTTPException(403, "API-ключу не выдано разрешение identity:read")
    return dict(account), scopes


@router.get("/v1/me")
def api_key_me(request: Request):
    account, scopes = _api_key_identity(request)
    result = {
        "sub": str(account["id"]),
        "username": account["username"] or "",
    }
    if "profile:read" in scopes:
        result["name"] = account["display_name"] or account["username"] or ""
        result["picture"] = account["avatar_url"]
    return result


def purge_for_user(user_id: int) -> int:
    """Remove account-bound credentials when the owning GhostID account is deleted."""
    path = _path()
    if not path.is_file():
        return 0
    with _db() as connection:
        result = connection.execute(
            "DELETE FROM api_keys WHERE user_id=?", (int(user_id),)
        )
        return int(result.rowcount)


def install(app):
    app.include_router(router)
    from ecos_core.studio_projects import router as projects_router
    app.include_router(projects_router)
    from ecos_core.studio_auth import install as install_studio_auth
    install_studio_auth(app)
    from ecos_core.studio_console import router as console_router
    app.include_router(console_router)

    @app.middleware("http")
    async def api_key_no_store(request: Request, call_next):
        response = await call_next(request)
        if request.url.path.startswith("/api/developer/"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["Pragma"] = "no-cache"
        return response

