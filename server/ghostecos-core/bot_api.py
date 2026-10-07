"""GhostChat bot management and JSON WebSocket protocol."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional
from urllib.parse import urlsplit

from fastapi import APIRouter, File, Header, HTTPException, Query, Request, UploadFile, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from chat_router import (
    _deliver_message,
    _get_user_by_username,
    _is_blocked,
)
from ecos_core.identity import db
from ecos_core.client import auth_member
from ecos_core.shared import _decode_banner_config, _get_privacy_flags, _normalize_banner_config, _rate_limit, _val_name, _val_username, hash_argon2, verify_argon2
from ecos_core.realtime import ws_hub
from bot_runner_crypto import (
    BotRunnerKeyUnavailable,
    decrypt_runner_token,
    encrypt_runner_token,
    verify_runner_control_token,
)
from bot_program_runtime import validate_bot_program

router = APIRouter(prefix="/api/bots", tags=["GhostChat Bots"])
log = logging.getLogger("gc.bots")

CLIENT_PING_TIMEOUT_SECONDS = 45
SERVER_PING_INTERVAL_SECONDS = 20
SERVER_PONG_TIMEOUT_SECONDS = 40
MAX_FRAME_CHARS = 64_000
MAX_BOT_MESSAGE_CHARS = 4_000
MAX_BOT_STORAGE_KEY_CHARS = 128
MAX_BOT_STORAGE_VALUE_BYTES = 65_536
MAX_BOT_STORAGE_REQUEST_BYTES = 262_144
MAX_BOT_STORAGE_TOTAL_BYTES = 1_048_576
MAX_BOT_STORAGE_KEYS = 1_000
BOT_AVATARS_DIR = "/opt/ghostchat/media/avatars"
BOT_RUNNER_HEARTBEAT_FILE = os.environ.get(
    "GHOSTBOT_RUNNER_HEARTBEAT_FILE", "/run/ghostchat-bot-runner/heartbeat"
)
MAX_BOT_PROGRAM_BYTES = 262_144
MAX_BOTS_PER_OWNER = 10
MAX_MANAGED_BOTS_PER_OWNER = 3
MAX_MANAGED_BOTS_GLOBAL = 64
SEND_IDEMPOTENCY_TTL_SECONDS = 365 * 24 * 60 * 60


def _idempotency_lookup(c, sender_id: int, scope: str, client_message_id: Optional[str]):
    """Keep bot sends compatible with older deployed chat_router modules."""
    if not client_message_id:
        return None
    c.execute(
        """CREATE TABLE IF NOT EXISTS gc_send_idempotency (
            sender_id INTEGER NOT NULL,
            scope TEXT NOT NULL,
            client_message_id TEXT NOT NULL,
            response_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(sender_id, scope, client_message_id)
        )"""
    )
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_gc_send_idempotency_created "
        "ON gc_send_idempotency(created_at)"
    )
    row = c.execute(
        "SELECT response_json FROM gc_send_idempotency "
        "WHERE sender_id=? AND scope=? AND client_message_id=?",
        (sender_id, scope, client_message_id),
    ).fetchone()
    if not row:
        return None
    try:
        return json.loads(row["response_json"])
    except Exception:
        return None


def _idempotency_store(c, sender_id: int, scope: str, client_message_id: Optional[str], response: dict):
    if not client_message_id:
        return
    c.execute(
        """CREATE TABLE IF NOT EXISTS gc_send_idempotency (
            sender_id INTEGER NOT NULL,
            scope TEXT NOT NULL,
            client_message_id TEXT NOT NULL,
            response_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY(sender_id, scope, client_message_id)
        )"""
    )
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_gc_send_idempotency_created "
        "ON gc_send_idempotency(created_at)"
    )
    now = int(time.time())
    c.execute(
        "DELETE FROM gc_send_idempotency WHERE created_at < ?",
        (now - SEND_IDEMPOTENCY_TTL_SECONDS,),
    )
    c.execute(
        "INSERT INTO gc_send_idempotency "
        "(sender_id, scope, client_message_id, response_json, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (sender_id, scope, client_message_id, json.dumps(response), now),
    )

_BOT_RESERVED = {
    "giveaway", "airdrop", "gift", "bonus", "prize", "reward", "claim",
    "verify", "verification", "security", "wallet", "support", "help",
    "admin", "official", "ghost", "ghostchat", "ghostecos", "ghostbot",
}


class CreateBotBody(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    display_name: str = Field(min_length=1, max_length=100)


class UpdateBotBody(BaseModel):
    display_name: str = Field(min_length=1, max_length=100)
    banner: Optional[dict[str, Any]] = None
    banner_clear: bool = False


class HumanBotMessageBody(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_BOT_MESSAGE_CHARS)


class BotButtonCallbackBody(BaseModel):
    message_id: int = Field(gt=0)
    callback_data: str = Field(min_length=1, max_length=64)


class BotTestSessionBody(BaseModel):
    client_public_key: str = Field(min_length=40, max_length=48)
    # Account-authenticated clients identify the bot they own. Optional only
    # for compatibility with older clients that authenticate as the bot.
    bot_id: Optional[int] = Field(default=None, gt=0)


class BotTestEncryptedText(BaseModel):
    v: int = Field(ge=1, le=1)
    nonce: str = Field(min_length=16, max_length=16)
    ciphertext: str = Field(min_length=1, max_length=8_000)
    tag: str = Field(min_length=22, max_length=24)


class BotTestMessageBody(BaseModel):
    encrypted_text: BotTestEncryptedText


class BotProgramBody(BaseModel):
    program: dict[str, Any]


@dataclass
class _BotSession:
    bot_id: int
    websocket: WebSocket
    loop: asyncio.AbstractEventLoop
    crypto_public_key: Optional[str] = None


@dataclass
class _BotTestSession:
    session_id: str
    bot_id: int
    client_public_key: str
    created_at: float
    last_activity: float
    next_message_id: int = 1
    messages: list[dict[str, Any]] = field(default_factory=list)


_sessions: dict[int, _BotSession] = {}
_sessions_lock = threading.RLock()
_test_sessions: dict[str, _BotTestSession] = {}
_test_sessions_lock = threading.RLock()
BOT_TEST_SESSION_TTL_SECONDS = 30 * 60
BOT_TEST_SESSION_MAX_MESSAGES = 300


def _ensure_schema() -> None:
    """Create the bot table and extend the legacy long-polling schema safely."""
    c = db()
    try:
        c.execute(
            """CREATE TABLE IF NOT EXISTS bots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL UNIQUE,
                owner_id INTEGER NOT NULL,
                token_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                last_seen_at INTEGER,
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (owner_id) REFERENCES users(id)
            )"""
        )
        columns = {row[1] for row in c.execute("PRAGMA table_info(bots)").fetchall()}
        for name, definition in (
            ("token_digest", "TEXT"),
            ("status", "TEXT NOT NULL DEFAULT 'offline'"),
            ("is_active", "INTEGER NOT NULL DEFAULT 1"),
            ("managed_token_enc", "TEXT"),
            ("managed_enabled", "INTEGER NOT NULL DEFAULT 0"),
            (
                "program_json",
                "TEXT NOT NULL DEFAULT '{\"version\":1,\"commands\":[],\"fallback\":\"\"}'",
            ),
        ):
            if name not in columns:
                c.execute(f"ALTER TABLE bots ADD COLUMN {name} {definition}")
        c.execute(
            "CREATE INDEX IF NOT EXISTS idx_bots_token_digest "
            "ON bots(token_digest) WHERE token_digest IS NOT NULL"
        )
        c.execute(
            """CREATE TABLE IF NOT EXISTS bot_storage (
                bot_id INTEGER NOT NULL,
                key TEXT NOT NULL,
                value_json TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (bot_id, key),
                FOREIGN KEY (bot_id) REFERENCES bots(id) ON DELETE CASCADE
            )"""
        )
        user_columns = {
            row[1] for row in c.execute("PRAGMA table_info(users)").fetchall()
        }
        if "is_bot" not in user_columns:
            c.execute(
                "ALTER TABLE users ADD COLUMN is_bot INTEGER NOT NULL DEFAULT 0"
            )
        # Migrate bot identities created before users.is_bot existed.
        c.execute(
            "UPDATE users SET is_bot=1 WHERE id IN (SELECT user_id FROM bots)"
        )
        chat_columns = {
            row[1] for row in c.execute("PRAGMA table_info(chat_dm)").fetchall()
        }
        if chat_columns and "bot_reply_markup" not in chat_columns:
            c.execute("ALTER TABLE chat_dm ADD COLUMN bot_reply_markup TEXT")
        if chat_columns and "bot_notified_at" not in chat_columns:
            c.execute("ALTER TABLE chat_dm ADD COLUMN bot_notified_at INTEGER NULL")
        # Presence is process-local. No connection survives a service restart.
        c.execute("UPDATE bots SET status='offline' WHERE status<>'offline'")
        c.commit()
    finally:
        c.close()


_ensure_schema()


def _require_app_device(user: dict) -> None:
    """Require the device-scoped token used by the installed GhostChat app.

    This is an API boundary, not cryptographic app attestation: a stolen device
    token remains a bearer credential and the server cannot prove the caller is
    a genuine native binary without a platform-attestation integration.
    """
    if not user.get("is_app_device"):
        raise HTTPException(
            403,
            "Создание и перевыпуск токена доступны только из авторизованного приложения GhostChat",
        )


def _normalise_bot_username(raw: str) -> str:
    username = _val_username(raw.strip().lower())
    if not username.endswith("bot"):
        raise HTTPException(
            422,
            'Имя бота должно оканчиваться на "bot", например weather_bot',
        )
    if username[:-3].rstrip("_") in _BOT_RESERVED:
        raise HTTPException(422, "Это имя бота зарезервировано")
    return username


def _insert_bot_user(c, username: str, display_name: str, now: int) -> int:
    """Insert a non-login user row while adapting to old shared-DB schemas."""
    columns = c.execute("PRAGMA table_info(users)").fetchall()
    info = {row[1]: row for row in columns}
    values: dict[str, Any] = {"username": username, "display_name": display_name}
    if "account_type" in info:
        values["account_type"] = "bot"
    if "is_bot" in info:
        values["is_bot"] = 1
    if "in_ghostchat" in info:
        values["in_ghostchat"] = 0
    if "created_at" in info and info["created_at"][4] is None:
        values["created_at"] = now

    # If this users table requires password columns, give the non-interactive
    # bot account an unguessable random credential, never the bot API token.
    unusable_password_hash = hash_argon2(secrets.token_urlsafe(48))
    for name in ("argon2_hash", "password_hash"):
        if name in info:
            values[name] = unusable_password_hash

    # A few historical schemas added required columns without defaults. Fill
    # only those with neutral values; nullable and defaulted fields stay alone.
    for name, row in info.items():
        if name in values or not row[3] or row[4] is not None or row[5]:
            continue
        field_type = (row[2] or "").upper()
        if any(part in field_type for part in ("CHAR", "TEXT", "CLOB")):
            values[name] = ""
        elif any(part in field_type for part in ("INT", "REAL", "NUM", "BOOL")):
            values[name] = 0
        elif "BLOB" in field_type:
            values[name] = b""

    names = list(values)
    placeholders = ", ".join("?" for _ in names)
    quoted_names = ", ".join(f'"{name}"' for name in names)
    c.execute(
        f"INSERT INTO users ({quoted_names}) VALUES ({placeholders})",
        [values[name] for name in names],
    )
    return int(c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"])


def _token_digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _create_bot(owner_id: int, username: str, display_name: str) -> tuple[int, str]:
    token = secrets.token_urlsafe(32)
    token_hash = hash_argon2(token)
    digest = _token_digest(token)
    now = int(time.time())
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        owned_count = c.execute(
            "SELECT COUNT(*) FROM bots WHERE owner_id=? AND is_active=1",
            (owner_id,),
        ).fetchone()[0]
        if int(owned_count) >= MAX_BOTS_PER_OWNER:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "bot_limit_reached",
                    "limit": MAX_BOTS_PER_OWNER,
                    "message": "????? ??????? ?? ????? 10 ?????",
                },
            )
        taken = c.execute(
            "SELECT 1 FROM gc_public_handles WHERE handle=? LIMIT 1", (username,)
        ).fetchone()
        if not taken:
            taken = c.execute(
                "SELECT 1 FROM users WHERE lower(username)=? LIMIT 1", (username,)
            ).fetchone()
        if taken:
            raise HTTPException(409, "Это имя уже занято")

        user_id = _insert_bot_user(c, username, display_name, now)
        # Bots share the public username namespace with users and channels.
        # The existing registry supports owner_type='user' without a migration.
        c.execute(
            "INSERT INTO gc_public_handles(handle, owner_type, owner_id) "
            "VALUES (?, 'user', ?)",
            (username, user_id),
        )
        c.execute(
            "INSERT INTO bots(user_id, owner_id, token_hash, token_digest, "
            "created_at, status, is_active, managed_token_enc, managed_enabled, "
            "program_json) VALUES (?, ?, ?, ?, ?, 'offline', 1, ?, 0, ?)",
            (
                user_id,
                owner_id,
                token_hash,
                digest,
                now,
                None,
                json.dumps(
                    {"version": 1, "commands": [], "fallback": ""},
                    separators=(",", ":"),
                ),
            ),
        )
        bot_id = int(c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"])
        # Managed runtime credentials are encrypted before they ever reach disk.
        # If the deployment has not provisioned its runner key yet, ordinary
        # externally-run bots still work and the managed start API stays closed.
        try:
            managed_token = encrypt_runner_token(token, bot_id)
        except BotRunnerKeyUnavailable:
            managed_token = None
        c.execute(
            "UPDATE bots SET managed_token_enc=?, program_json=? WHERE id=?",
            (
                managed_token,
                json.dumps(
                    {"version": 1, "commands": [], "fallback": ""},
                    separators=(",", ":"),
                ),
                bot_id,
            ),
        )
        c.commit()
        return bot_id, token
    except sqlite3.IntegrityError as exc:
        c.rollback()
        raise HTTPException(409, "Это имя уже занято") from exc
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()


def _get_owned_bot(c, bot_id: int, owner_id: int) -> dict:
    row = c.execute(
        "SELECT b.id AS bot_id, b.user_id, b.owner_id, b.status, "
        "u.username, u.display_name FROM bots b "
        "JOIN users u ON u.id=b.user_id "
        "WHERE b.id=? AND b.owner_id=? AND b.is_active=1",
        (bot_id, owner_id),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Бот не найден или не принадлежит аккаунту")
    return dict(row)


def _authenticate_bot_token(token: str) -> Optional[dict]:
    if not token or len(token) > 512:
        return None
    c = db()
    try:
        digest = _token_digest(token)
        row = c.execute(
            "SELECT b.id AS bot_id, b.user_id, b.owner_id, b.token_hash, "
            "b.token_digest, u.username, u.display_name "
            "FROM bots b JOIN users u ON u.id=b.user_id "
            "WHERE b.token_digest=? AND b.is_active=1 LIMIT 1",
            (digest,),
        ).fetchone()
        if row:
            return dict(row)

        # Compatibility for tokens issued by the retired long-poll API.
        legacy_rows = c.execute(
            "SELECT b.id AS bot_id, b.user_id, b.owner_id, b.token_hash, "
            "b.token_digest, u.username, u.display_name "
            "FROM bots b JOIN users u ON u.id=b.user_id "
            "WHERE b.token_digest IS NULL AND b.is_active=1"
        ).fetchall()
        for candidate in legacy_rows:
            if verify_argon2(token, candidate["token_hash"] or ""):
                c.execute(
                    "UPDATE bots SET token_digest=? WHERE id=? AND token_digest IS NULL",
                    (digest, candidate["bot_id"]),
                )
                c.commit()
                return dict(candidate)
        return None
    finally:
        c.close()


def _bot_from_authorization(authorization: Optional[str]) -> Optional[dict]:
    if not authorization:
        return None
    scheme, separator, token = authorization.partition(" ")
    if not separator or scheme.lower() != "bot":
        return None
    return _authenticate_bot_token(token.strip())


def _decode_b64url(value: Any, *, max_chars: int = 12_000) -> bytes:
    if not isinstance(value, str) or not value or len(value) > max_chars:
        raise ValueError("invalid base64url value")
    try:
        padded = value + "=" * (-len(value) % 4)
        return base64.b64decode(padded, altchars=b"-_", validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise ValueError("invalid base64url value") from exc


def _validated_public_key(value: Any) -> str:
    try:
        decoded = _decode_b64url(value, max_chars=48)
    except ValueError as exc:
        raise HTTPException(422, "Invalid X25519 public key") from exc
    if len(decoded) != 32:
        raise HTTPException(422, "X25519 public key must be 32 bytes")
    return str(value)


def _validated_encrypted_text(value: Any) -> dict[str, Any]:
    if hasattr(value, "dict"):
        value = value.dict()
    if not isinstance(value, dict) or value.get("v") != 1:
        raise HTTPException(422, "Invalid encrypted message envelope")
    try:
        nonce = _decode_b64url(value.get("nonce"), max_chars=16)
        ciphertext = _decode_b64url(value.get("ciphertext"), max_chars=8_000)
        tag = _decode_b64url(value.get("tag"), max_chars=24)
    except ValueError as exc:
        raise HTTPException(422, "Invalid encrypted message envelope") from exc
    if len(nonce) != 12 or not ciphertext or len(tag) != 16:
        raise HTTPException(422, "Invalid encrypted message envelope")
    return {
        "v": 1,
        "nonce": value["nonce"],
        "ciphertext": value["ciphertext"],
        "tag": value["tag"],
    }


def _require_bot_test_token(authorization: Optional[str]) -> dict:
    bot = _bot_from_authorization(authorization)
    if not bot:
        raise HTTPException(401, "Invalid bot token")
    return bot


def _require_bot_api_token(authorization: Optional[str]) -> dict:
    bot = _bot_from_authorization(authorization)
    if not bot:
        raise HTTPException(401, "Invalid bot token")
    return bot


def _prune_bot_test_sessions(now: Optional[float] = None) -> None:
    cutoff = (time.monotonic() if now is None else now) - BOT_TEST_SESSION_TTL_SECONDS
    with _test_sessions_lock:
        expired = [
            session_id
            for session_id, session in _test_sessions.items()
            if session.last_activity < cutoff
        ]
        for session_id in expired:
            _test_sessions.pop(session_id, None)


def _clear_bot_test_sessions(bot_id: int) -> None:
    with _test_sessions_lock:
        expired = [
            session_id
            for session_id, session in _test_sessions.items()
            if session.bot_id == bot_id
        ]
        for session_id in expired:
            _test_sessions.pop(session_id, None)


def _get_bot_test_session(bot_id: int, session_id: Any) -> _BotTestSession:
    if not isinstance(session_id, str) or not session_id or len(session_id) > 128:
        raise HTTPException(404, "Test chat session not found")
    _prune_bot_test_sessions()
    with _test_sessions_lock:
        session = _test_sessions.get(session_id)
        if not session or session.bot_id != bot_id:
            raise HTTPException(404, "Test chat session not found")
        session.last_activity = time.monotonic()
        return session


def _get_owned_bot_test_session(
    session_id: Any, owner_id: int
) -> tuple[dict, _BotTestSession]:
    if not isinstance(session_id, str) or not session_id or len(session_id) > 128:
        raise HTTPException(404, "Test chat session not found")
    _prune_bot_test_sessions()
    with _test_sessions_lock:
        session = _test_sessions.get(session_id)
        if not session:
            raise HTTPException(404, "Test chat session not found")
        session.last_activity = time.monotonic()

    c = db()
    try:
        bot = _get_owned_bot(c, session.bot_id, owner_id)
    finally:
        c.close()
    return bot, session


def _authorize_bot_test_session(
    session_id: str, authorization: Optional[str]
) -> tuple[dict, _BotTestSession]:
    # Keep the old Bot-token flow working for older GhostBots builds, while
    # the current UI uses the signed-in account and server-checked ownership.
    bot = _bot_from_authorization(authorization)
    if bot:
        return bot, _get_bot_test_session(int(bot["bot_id"]), session_id)
    owner = auth_member(authorization)
    return _get_owned_bot_test_session(session_id, int(owner["id"]))


def _append_bot_test_message(
    session: _BotTestSession, sender: str, encrypted_text: dict[str, Any]
) -> dict[str, Any]:
    now_mono = time.monotonic()
    with _test_sessions_lock:
        current = _test_sessions.get(session.session_id)
        if current is not session:
            raise HTTPException(410, "Test chat session expired")
        message = {
            "id": session.next_message_id,
            "sender": sender,
            "encrypted_text": encrypted_text,
            "created_at": int(time.time()),
        }
        session.next_message_id += 1
        session.last_activity = now_mono
        session.messages.append(message)
        if len(session.messages) > BOT_TEST_SESSION_MAX_MESSAGES:
            del session.messages[: len(session.messages) - BOT_TEST_SESSION_MAX_MESSAGES]
        return message


def _set_bot_status(bot_id: int, status: str) -> tuple[bool, Optional[dict]]:
    now = int(time.time())
    c = db()
    try:
        row = c.execute(
            "SELECT b.owner_id, b.status, b.last_seen_at, u.username FROM bots b "
            "JOIN users u ON u.id=b.user_id WHERE b.id=?",
            (bot_id,),
        ).fetchone()
        if not row:
            return False, None
        changed = row["status"] != status
        if status == "online":
            c.execute(
                "UPDATE bots SET status=?, last_seen_at=? WHERE id=?",
                (status, now, bot_id),
            )
        else:
            c.execute("UPDATE bots SET status=? WHERE id=?", (status, bot_id))
        c.commit()
        payload = {
            "bot_id": bot_id,
            "username": row["username"],
            "status": status,
            "last_seen_at": now if status == "online" else row["last_seen_at"],
        }
        if changed:
            ws_hub.send_to(int(row["owner_id"]), "bot.status", payload)
        return changed, payload
    finally:
        c.close()


def _register_session(session: _BotSession) -> Optional[_BotSession]:
    with _sessions_lock:
        old = _sessions.get(session.bot_id)
        if old:
            # Make replacement transitions atomic with respect to heartbeat
            # writes from the old and new socket handlers.
            _set_bot_status(session.bot_id, "offline")
            _clear_bot_test_sessions(session.bot_id)
        _sessions[session.bot_id] = session
        return old


def _current_session(bot_id: int) -> Optional[_BotSession]:
    with _sessions_lock:
        return _sessions.get(bot_id)


def _set_session_status(
    session: _BotSession, status: str, *, remove: bool = False
) -> tuple[bool, Optional[dict]]:
    with _sessions_lock:
        if _sessions.get(session.bot_id) is not session:
            return False, None
        if remove:
            del _sessions[session.bot_id]
        return _set_bot_status(session.bot_id, status)


async def _run_on_session_loop(session: _BotSession, operation, *args, **kwargs):
    if asyncio.get_running_loop() is session.loop:
        return await operation(*args, **kwargs)
    coro = operation(*args, **kwargs)
    try:
        future = asyncio.run_coroutine_threadsafe(coro, session.loop)
    except Exception:
        coro.close()
        raise
    return await asyncio.wrap_future(future)


async def _send_session_frame(session: _BotSession, frame: dict) -> None:
    await _run_on_session_loop(session, session.websocket.send_json, frame)


async def _close_session(
    session: _BotSession, *, code: int = 4001, reason: str = "Session replaced"
) -> None:
    try:
        await _run_on_session_loop(
            session, session.websocket.close, code=code, reason=reason
        )
    except Exception:
        pass


def _event_frame(name: str, data: dict, event_id: Optional[str] = None) -> dict:
    return {
        "type": "event",
        "event_id": event_id or uuid.uuid4().hex,
        "event": name,
        "data": data,
    }


async def _action_result(
    websocket: WebSocket,
    action_id: Any,
    *,
    result: Optional[dict] = None,
    error_code: Optional[str] = None,
    error_message: Optional[str] = None,
) -> None:
    data: dict[str, Any] = {"action_id": action_id}
    if error_code:
        data["error"] = {"code": error_code, "message": error_message or "Action failed"}
        await websocket.send_json(_event_frame("action.failed", data))
    else:
        data["result"] = result or {}
        await websocket.send_json(_event_frame("action.completed", data))


def _validate_reply_markup(value: Any) -> Optional[dict[str, Any]]:
    """Validate and normalize Telegram-style inline/reply keyboard markup."""
    if value is None:
        return None
    if not isinstance(value, dict):
        raise HTTPException(422, "reply_markup должен быть объектом")

    is_inline = "inline_keyboard" in value
    if is_inline:
        if set(value) != {"inline_keyboard"}:
            raise HTTPException(422, "inline reply_markup содержит неизвестные поля")
        rows_value = value.get("inline_keyboard")
        keyboard_name = "inline_keyboard"
    else:
        allowed = {"keyboard", "resize_keyboard", "one_time_keyboard"}
        if "keyboard" not in value or not set(value).issubset(allowed):
            raise HTTPException(422, "reply_markup должен содержать keyboard или inline_keyboard")
        rows_value = value.get("keyboard")
        keyboard_name = "keyboard"

    if not isinstance(rows_value, list) or not 1 <= len(rows_value) <= 10:
        raise HTTPException(422, f"{keyboard_name} должна содержать от 1 до 10 рядов")

    normalized_rows: list[list[dict[str, str]]] = []
    button_count = 0
    for row in rows_value:
        if not isinstance(row, list) or not 1 <= len(row) <= 10:
            raise HTTPException(422, "В каждом ряду клавиатуры должно быть от 1 до 10 кнопок")
        button_count += len(row)
        if button_count > 100:
            raise HTTPException(422, "Клавиатура не может содержать более 100 кнопок")
        normalized_row: list[dict[str, str]] = []
        for button in row:
            if not isinstance(button, dict):
                raise HTTPException(422, "Кнопка должна быть объектом")
            text = button.get("text")
            if not isinstance(text, str) or not text.strip() or len(text) > 64:
                raise HTTPException(422, "Текст кнопки должен содержать от 1 до 64 символов")

            if is_inline:
                if set(button) == {"text", "callback_data"}:
                    callback_data = button.get("callback_data")
                    if not isinstance(callback_data, str) or not callback_data:
                        raise HTTPException(422, "callback_data не должен быть пустым")
                    if len(callback_data.encode("utf-8")) > 64:
                        raise HTTPException(422, "callback_data не должен превышать 64 байта UTF-8")
                    normalized_row.append({"text": text, "callback_data": callback_data})
                    continue
                if set(button) == {"text", "url"}:
                    url = button.get("url")
                    if not isinstance(url, str) or len(url) > 2_048:
                        raise HTTPException(422, "URL кнопки должен быть строкой до 2048 символов")
                    try:
                        if any(
                            character.isspace()
                            or ord(character) < 32
                            or ord(character) == 127
                            or character == "\\"
                            for character in url
                        ):
                            raise ValueError("URL contains unsafe characters")
                        parsed = urlsplit(url)
                        valid_url = (
                            parsed.scheme in {"http", "https"}
                            and bool(parsed.hostname)
                            and parsed.username is None
                            and parsed.password is None
                        )
                        _ = parsed.port
                    except ValueError:
                        valid_url = False
                    if not valid_url:
                        raise HTTPException(422, "Кнопка может открывать только корректный http(s) URL")
                    normalized_row.append({"text": text, "url": url})
                    continue
                raise HTTPException(422, "Inline-кнопка должна содержать callback_data или url")

            if not set(button).issubset({"text", "send_text"}) or "text" not in button:
                raise HTTPException(422, "Кнопка клавиатуры может содержать только text и send_text")
            send_text = button.get("send_text", text)
            if not isinstance(send_text, str) or not send_text.strip() or len(send_text) > MAX_BOT_MESSAGE_CHARS:
                raise HTTPException(422, "send_text должен содержать от 1 до 4000 символов")
            normalized_row.append({"text": text, "send_text": send_text})
        normalized_rows.append(normalized_row)

    if is_inline:
        normalized: dict[str, Any] = {"inline_keyboard": normalized_rows}
    else:
        resize = value.get("resize_keyboard", True)
        one_time = value.get("one_time_keyboard", False)
        if not isinstance(resize, bool) or not isinstance(one_time, bool):
            raise HTTPException(422, "Настройки клавиатуры должны быть boolean")
        normalized = {
            "keyboard": normalized_rows,
            "resize_keyboard": resize,
            "one_time_keyboard": one_time,
        }
    if len(json.dumps(normalized, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) > 16_384:
        raise HTTPException(422, "reply_markup не должен превышать 16384 байта UTF-8")
    return normalized


def _send_message_as_bot(
    bot: dict,
    to_username: Any,
    to_user_id: Any,
    text: Any,
    reply_markup: Any = None,
) -> dict:
    if not isinstance(text, str):
        raise HTTPException(422, "text обязателен")
    if (to_username is None) == (to_user_id is None):
        raise HTTPException(422, "Укажите ровно один адресат: to_username или to_user_id")
    if to_username is not None and (
        not isinstance(to_username, str) or not to_username.strip()
    ):
        raise HTTPException(422, "Некорректный to_username")
    if to_user_id is not None and (
        type(to_user_id) is not int or to_user_id <= 0
    ):
        raise HTTPException(422, "to_user_id должен быть положительным целым числом")
    clean_text = text.strip()
    if not clean_text or len(clean_text) > MAX_BOT_MESSAGE_CHARS:
        raise HTTPException(400, "text обязателен и не должен превышать 4000 символов")
    normalized_markup = _validate_reply_markup(reply_markup)
    _rate_limit(f"botsend:{bot['user_id']}", limit=120, window=60)

    c = db()
    try:
        if to_user_id is not None:
            to_user = c.execute(
                "SELECT id, username, display_name FROM users WHERE id=?",
                (to_user_id,),
            ).fetchone()
        else:
            to_user = _get_user_by_username(c, to_username.strip().lstrip("@"))
        if not to_user:
            raise HTTPException(404, "Получатель не найден")
        if int(to_user["id"]) == int(bot["user_id"]):
            raise HTTPException(400, "Бот не может написать самому себе")
        if _is_blocked(c, int(bot["user_id"]), int(to_user["id"])):
            raise HTTPException(403, "Пользователь заблокировал бота")
        privacy = _get_privacy_flags(c, int(to_user["id"]))
        if privacy.get("message_privacy") == "nobody":
            raise HTTPException(403, "Пользователь запретил ему писать")
        if privacy.get("message_privacy") == "contacts":
            contact = c.execute(
                "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
                (to_user["id"], bot["user_id"]),
            ).fetchone()
            if not contact:
                raise HTTPException(403, "Бот не входит в контакты пользователя")

        sender = {
            "id": bot["user_id"],
            "username": bot["username"],
            "display_name": bot["display_name"],
        }
        return _deliver_message(
            c,
            sender,
            to_user,
            ciphertext=None,
            plain_text=clean_text,
            reply_markup=normalized_markup,
        )
    finally:
        c.close()


def _mark_bot_messages_read(bot: dict, raw_ids: Any) -> dict[str, Any]:
    if not isinstance(raw_ids, list) or not raw_ids or len(raw_ids) > 500:
        raise HTTPException(422, "ids должен содержать от 1 до 500 message ID")
    if any(type(message_id) is not int or message_id <= 0 for message_id in raw_ids):
        raise HTTPException(422, "Каждый message ID должен быть положительным целым числом")
    ids = list(dict.fromkeys(raw_ids))
    _rate_limit(f"botread:{bot['bot_id']}", limit=120, window=60)

    c = db()
    try:
        if not _get_privacy_flags(c, int(bot["user_id"]))["send_read_receipts"]:
            return {"status": "suppressed", "updated": 0}
        placeholders = ",".join("?" for _ in ids)
        rows = c.execute(
            f"SELECT id, sender_id FROM chat_dm "
            f"WHERE receiver_id=? AND id IN ({placeholders})",
            [int(bot["user_id"]), *ids],
        ).fetchall()
        for row in rows:
            c.execute(
                "INSERT OR IGNORE INTO chat_dm_read_marks "
                "(sender_id, msg_id, recipient_id) VALUES (?, ?, ?)",
                (int(row["sender_id"]), int(row["id"]), int(bot["user_id"])),
            )
        c.commit()
    finally:
        c.close()

    ids_by_sender: dict[int, list[int]] = {}
    for row in rows:
        ids_by_sender.setdefault(int(row["sender_id"]), []).append(int(row["id"]))
    for sender_id, sender_ids in ids_by_sender.items():
        ws_hub.send_to(
            sender_id,
            "chat.read",
            {"ids": sender_ids, "by_username": bot["username"]},
        )
    return {"status": "read", "updated": len(rows)}


async def _dispatch_action(
    websocket: WebSocket, session: _BotSession, bot: dict, frame: dict
) -> bool:
    action_id = frame.get("action_id")
    if action_id is not None and (
        not isinstance(action_id, (str, int)) or len(str(action_id)) > 128
    ):
        await _action_result(
            websocket, None, error_code="invalid_action_id", error_message="Invalid action_id"
        )
        return False
    action = frame.get("action")
    data = frame.get("data", {})
    if not isinstance(action, str) or not isinstance(data, dict):
        await _action_result(
            websocket, action_id, error_code="invalid_action", error_message="Invalid action frame"
        )
        return False

    if action == "message.send":
        test_session_id = data.get("test_session_id")
        if test_session_id is not None:
            try:
                encrypted_text = _validated_encrypted_text(
                    data.get("encrypted_text")
                )
                test_session = _get_bot_test_session(
                    int(bot["bot_id"]), test_session_id
                )
                result = _append_bot_test_message(
                    test_session, "bot", encrypted_text
                )
            except HTTPException as exc:
                await _action_result(
                    websocket,
                    action_id,
                    error_code=f"http_{exc.status_code}",
                    error_message=str(exc.detail),
                )
            except Exception:
                log.exception("Bot test-chat reply failed for bot_id=%s", bot["bot_id"])
                await _action_result(
                    websocket,
                    action_id,
                    error_code="internal_error",
                    error_message="Test reply could not be delivered",
                )
            else:
                await _action_result(
                    websocket,
                    action_id,
                    result={"id": result["id"]},
                )
            return False
        try:
            result = await asyncio.to_thread(
                _send_message_as_bot,
                bot,
                data.get("to_username"),
                data.get("to_user_id"),
                data.get("text"),
                data.get("reply_markup"),
            )
        except HTTPException as exc:
            await _action_result(
                websocket,
                action_id,
                error_code=f"http_{exc.status_code}",
                error_message=str(exc.detail),
            )
        except Exception:
            log.exception("Bot message action failed for bot_id=%s", bot["bot_id"])
            await _action_result(
                websocket,
                action_id,
                error_code="internal_error",
                error_message="Message could not be sent",
            )
        else:
            await _action_result(websocket, action_id, result=result)
        return False

    if action == "message.read":
        if "test_session_id" in data:
            await _action_result(
                websocket,
                action_id,
                error_code="unsupported_context",
                error_message="Read receipts are not supported in encrypted owner test chats",
            )
            return False
        try:
            result = await asyncio.to_thread(
                _mark_bot_messages_read, bot, data.get("ids")
            )
        except HTTPException as exc:
            await _action_result(
                websocket,
                action_id,
                error_code=f"http_{exc.status_code}",
                error_message=str(exc.detail),
            )
        except Exception:
            log.exception("Bot read receipt failed for bot_id=%s", bot["bot_id"])
            await _action_result(
                websocket,
                action_id,
                error_code="internal_error",
                error_message="Read receipt could not be sent",
            )
        else:
            await _action_result(websocket, action_id, result=result)
        return False

    if action == "bot.status.set":
        if data.get("status") != "offline":
            await _action_result(
                websocket,
                action_id,
                error_code="invalid_status",
                error_message="A bot can only request offline status",
            )
            return False
        _, status_payload = await asyncio.to_thread(
            _set_session_status, session, "offline", remove=True
        )
        await _action_result(websocket, action_id, result={"status": "offline"})
        if status_payload:
            await websocket.send_json(_event_frame("bot.status", status_payload))
            _clear_bot_test_sessions(session.bot_id)
        await websocket.close(code=1000, reason="Bot requested offline status")
        return True

    await _action_result(
        websocket,
        action_id,
        error_code="unknown_action",
        error_message=f"Unsupported action: {action[:80]}",
    )
    return False


@router.post("/create")
def create_bot(body: CreateBotBody, authorization: Optional[str] = Header(None)):
    owner = auth_member(authorization)
    _require_app_device(owner)
    _rate_limit(f"botcreate:{owner['id']}", limit=10, window=3600)
    username = _normalise_bot_username(body.username)
    display_name = _val_name(body.display_name)
    bot_id, token = _create_bot(int(owner["id"]), username, display_name)
    return {
        "status": "ok",
        "id": bot_id,
        "username": username,
        "display_name": display_name,
        "token": token,
    }


@router.get("/mine")
def list_my_bots(authorization: Optional[str] = Header(None)):
    owner = auth_member(authorization)
    c = db()
    try:
        rows = c.execute(
            "SELECT b.id, u.username, u.display_name, u.avatar_url, "
            "u.banner_config, b.status, "
            "b.created_at, b.last_seen_at, b.managed_enabled, "
            "(b.managed_token_enc IS NOT NULL) AS managed_ready FROM bots b "
            "JOIN users u ON u.id=b.user_id "
            "WHERE b.owner_id=? AND b.is_active=1 ORDER BY b.created_at DESC",
            (owner["id"],),
        ).fetchall()
        bots = []
        for row in rows:
            item = dict(row)
            item["banner"] = _decode_banner_config(item.pop("banner_config", None))
            item["managed_enabled"] = bool(item["managed_enabled"])
            item["managed_ready"] = bool(item["managed_ready"])
            bots.append(item)
        return {"bots": bots, "runner_available": _runner_service_available()}
    finally:
        c.close()


def _runner_service_available() -> bool:
    try:
        return time.time() - os.stat(BOT_RUNNER_HEARTBEAT_FILE).st_mtime <= 30
    except OSError:
        return False


@router.get("/internal/managed")
def list_managed_runner_bots(
    x_ghost_bot_runner: Optional[str] = Header(None),
):
    """Private control-plane feed consumed only by the local runner service."""
    if not verify_runner_control_token(x_ghost_bot_runner):
        raise HTTPException(403, "Invalid runner credential")
    c = db()
    try:
        rows = c.execute(
            "SELECT id, managed_token_enc, program_json FROM bots "
            "WHERE managed_enabled=1 AND is_active=1 ORDER BY id LIMIT ?",
            (MAX_MANAGED_BOTS_GLOBAL,),
        ).fetchall()
        return {
            "bots": [
                {
                    "id": int(row["id"]),
                    "token_enc": str(row["managed_token_enc"] or ""),
                    "program_json": str(row["program_json"] or "{}"),
                }
                for row in rows
            ]
        }
    finally:
        c.close()


def _owned_program(bot_id: int, owner_id: int) -> dict[str, Any]:
    c = db()
    try:
        bot = _get_owned_bot(c, bot_id, owner_id)
        row = c.execute(
            "SELECT program_json, managed_enabled, managed_token_enc "
            "FROM bots WHERE id=?",
            (bot_id,),
        ).fetchone()
        try:
            program = json.loads(row["program_json"] or "{}")
        except (TypeError, json.JSONDecodeError) as exc:
            log.exception("Invalid managed program stored for bot_id=%s", bot_id)
            raise HTTPException(500, "Stored bot program is invalid") from exc
        try:
            canonical = validate_bot_program(program)
        except (TypeError, ValueError) as exc:
            log.warning("Invalid managed program stored for bot_id=%s", bot_id)
            raise HTTPException(500, "Stored bot program is invalid") from exc
        return {
            "bot": bot,
            "program": canonical,
            "managed_enabled": bool(row["managed_enabled"]),
            "managed_ready": bool(row["managed_token_enc"]),
        }
    finally:
        c.close()


@router.get("/{bot_id}/program")
def get_bot_program(bot_id: int, authorization: Optional[str] = Header(None)):
    owner = auth_member(authorization)
    state = _owned_program(bot_id, int(owner["id"]))
    return {
        "program": state["program"],
        "managed_enabled": state["managed_enabled"],
        "managed_ready": state["managed_ready"],
        "runner_available": _runner_service_available(),
        "bot_status": state["bot"]["status"],
    }


@router.put("/{bot_id}/program")
def save_bot_program(
    bot_id: int,
    body: BotProgramBody,
    authorization: Optional[str] = Header(None),
):
    owner = auth_member(authorization)
    _rate_limit(f"botprogram:{owner['id']}", limit=60, window=3600)
    try:
        program = validate_bot_program(body.program)
    except (TypeError, ValueError) as exc:
        raise HTTPException(422, str(exc)) from exc
    encoded = json.dumps(program, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > MAX_BOT_PROGRAM_BYTES:
        raise HTTPException(413, "Bot program exceeds 256 KiB")
    c = db()
    try:
        _get_owned_bot(c, bot_id, int(owner["id"]))
        c.execute("UPDATE bots SET program_json=? WHERE id=?", (encoded, bot_id))
        c.commit()
    finally:
        c.close()
    return {"status": "ok", "program": program}


@router.post("/{bot_id}/runner/start")
def start_managed_bot(bot_id: int, authorization: Optional[str] = Header(None)):
    owner = auth_member(authorization)
    _require_app_device(owner)
    _rate_limit(f"botrunner:{owner['id']}", limit=20, window=3600)
    if not _runner_service_available():
        raise HTTPException(503, "The managed bot runner service is offline")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        bot = _get_owned_bot(c, bot_id, int(owner["id"]))
        row = c.execute(
            "SELECT managed_enabled, managed_token_enc, program_json "
            "FROM bots WHERE id=?",
            (bot_id,),
        ).fetchone()
        if not row["managed_token_enc"]:
            raise HTTPException(
                409,
                "This bot has no managed credential yet. Regenerate its token once, then try again.",
            )
        try:
            decrypt_runner_token(str(row["managed_token_enc"]), bot_id)
        except (BotRunnerKeyUnavailable, ValueError) as exc:
            raise HTTPException(
                409,
                "Managed bot credentials are unavailable. Check the runner key or regenerate the token.",
            ) from exc
        try:
            program = validate_bot_program(json.loads(row["program_json"] or "{}"))
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            raise HTTPException(422, "Save a valid bot program before starting it") from exc
        if not program["commands"] and not program["fallback"]:
            raise HTTPException(422, "Add at least one command or a fallback reply first")
        if not bool(row["managed_enabled"]):
            running = c.execute(
                "SELECT COUNT(*) AS total FROM bots "
                "WHERE owner_id=? AND is_active=1 AND managed_enabled=1",
                (owner["id"],),
            ).fetchone()
            if int(running["total"]) >= MAX_MANAGED_BOTS_PER_OWNER:
                raise HTTPException(
                    429,
                    f"At most {MAX_MANAGED_BOTS_PER_OWNER} managed bots can run per account",
                )
            total = c.execute(
                "SELECT COUNT(*) AS total FROM bots "
                "WHERE is_active=1 AND managed_enabled=1"
            ).fetchone()
            if int(total["total"]) >= MAX_MANAGED_BOTS_GLOBAL:
                raise HTTPException(429, "The managed bot runner is at capacity")
        c.execute("UPDATE bots SET managed_enabled=1 WHERE id=?", (bot_id,))
        c.commit()
        return {
            "status": "starting",
            "id": bot_id,
            "username": bot["username"],
            "bot_status": bot["status"],
        }
    finally:
        c.close()


@router.post("/{bot_id}/runner/stop")
def stop_managed_bot(bot_id: int, authorization: Optional[str] = Header(None)):
    owner = auth_member(authorization)
    _require_app_device(owner)
    _rate_limit(f"botrunner:{owner['id']}", limit=40, window=3600)
    c = db()
    try:
        _get_owned_bot(c, bot_id, int(owner["id"]))
        c.execute("UPDATE bots SET managed_enabled=0 WHERE id=?", (bot_id,))
        c.commit()
    finally:
        c.close()
    return {"status": "stopping", "id": bot_id}


def _validate_bot_storage_key(key: str) -> str:
    if (
        not isinstance(key, str)
        or len(key) > MAX_BOT_STORAGE_KEY_CHARS
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", key) is None
    ):
        raise HTTPException(
            422,
            "Ключ хранилища: 1-128 ASCII букв, цифр, точек, дефисов, подчёркиваний или двоеточий",
        )
    return key


@router.get("/storage/{key}")
def get_bot_storage_value(key: str, authorization: Optional[str] = Header(None)):
    bot = _require_bot_api_token(authorization)
    key = _validate_bot_storage_key(key)
    _rate_limit(f"botstorage:{bot['bot_id']}", limit=300, window=60)
    c = db()
    try:
        row = c.execute(
            "SELECT value_json FROM bot_storage WHERE bot_id=? AND key=?",
            (bot["bot_id"], key),
        ).fetchone()
        if row is None:
            return {"exists": False}
        try:
            value = json.loads(row["value_json"])
        except (TypeError, json.JSONDecodeError) as exc:
            log.exception("Invalid JSON in bot storage for bot_id=%s", bot["bot_id"])
            raise HTTPException(500, "Stored bot data is invalid") from exc
        return {"exists": True, "value": value}
    finally:
        c.close()


@router.put("/storage/{key}")
async def set_bot_storage_value(
    key: str,
    request: Request,
    authorization: Optional[str] = Header(None),
):
    bot = _require_bot_api_token(authorization)
    key = _validate_bot_storage_key(key)
    _rate_limit(f"botstorage:{bot['bot_id']}", limit=300, window=60)
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            declared_length = int(content_length)
        except ValueError as exc:
            raise HTTPException(400, "Invalid Content-Length") from exc
        if declared_length < 0 or declared_length > MAX_BOT_STORAGE_REQUEST_BYTES:
            raise HTTPException(413, "Storage request body is too large")
    raw_body = bytearray()
    async for chunk in request.stream():
        if len(raw_body) + len(chunk) > MAX_BOT_STORAGE_REQUEST_BYTES:
            raise HTTPException(413, "Storage request body is too large")
        raw_body.extend(chunk)
    try:
        value = json.loads(raw_body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HTTPException(422, "Request body must contain one JSON value") from exc
    try:
        serialized = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        )
    except (TypeError, ValueError, RecursionError) as exc:
        raise HTTPException(422, "Value must be a valid JSON value") from exc
    size_bytes = len(serialized.encode("utf-8"))
    if size_bytes > MAX_BOT_STORAGE_VALUE_BYTES:
        raise HTTPException(413, "Storage value exceeds 65536 UTF-8 bytes")

    now = int(time.time())
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        current = c.execute(
            "SELECT size_bytes FROM bot_storage WHERE bot_id=? AND key=?",
            (bot["bot_id"], key),
        ).fetchone()
        totals = c.execute(
            "SELECT COALESCE(SUM(size_bytes), 0) AS bytes, COUNT(*) AS keys "
            "FROM bot_storage WHERE bot_id=?",
            (bot["bot_id"],),
        ).fetchone()
        current_size = int(current["size_bytes"]) if current else 0
        if current is None and int(totals["keys"]) >= MAX_BOT_STORAGE_KEYS:
            raise HTTPException(413, "Bot storage is limited to 1000 keys")
        if int(totals["bytes"]) - current_size + size_bytes > MAX_BOT_STORAGE_TOTAL_BYTES:
            raise HTTPException(413, "Bot storage is limited to 1 MiB total")
        c.execute(
            "INSERT INTO bot_storage(bot_id, key, value_json, size_bytes, updated_at) "
            "VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(bot_id, key) DO UPDATE SET "
            "value_json=excluded.value_json, size_bytes=excluded.size_bytes, "
            "updated_at=excluded.updated_at",
            (bot["bot_id"], key, serialized, size_bytes, now),
        )
        c.commit()
        return {"status": "ok", "size_bytes": size_bytes, "updated_at": now}
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()


@router.delete("/storage/{key}")
def delete_bot_storage_value(key: str, authorization: Optional[str] = Header(None)):
    bot = _require_bot_api_token(authorization)
    key = _validate_bot_storage_key(key)
    _rate_limit(f"botstorage:{bot['bot_id']}", limit=300, window=60)
    c = db()
    try:
        cursor = c.execute(
            "DELETE FROM bot_storage WHERE bot_id=? AND key=?",
            (bot["bot_id"], key),
        )
        c.commit()
        return {"deleted": cursor.rowcount > 0}
    finally:
        c.close()


@router.post("/{bot_id}/update")
def update_bot(
    bot_id: int,
    body: UpdateBotBody,
    authorization: Optional[str] = Header(None),
):
    owner = auth_member(authorization)
    display_name = _val_name(body.display_name)
    if body.banner is not None and body.banner_clear:
        raise HTTPException(422, "Нельзя одновременно сохранить и убрать баннер")
    banner = (
        _normalize_banner_config(body.banner) if body.banner is not None else None
    )
    c = db()
    try:
        bot = _get_owned_bot(c, bot_id, int(owner["id"]))
        updates = {"display_name": display_name}
        if body.banner is not None:
            updates["banner_config"] = json.dumps(
                banner, ensure_ascii=False, separators=(",", ":")
            )
        elif body.banner_clear:
            updates["banner_config"] = None
        set_clause = ", ".join(f"{column}=?" for column in updates)
        c.execute(
            f"UPDATE users SET {set_clause} WHERE id=?",
            [*updates.values(), bot["user_id"]],
        )
        c.commit()
        return {
            "status": "ok",
            "display_name": display_name,
            "banner": banner if body.banner is not None else None,
            "banner_cleared": body.banner_clear,
        }
    finally:
        c.close()


async def _store_bot_avatar_for_user(user_id: int, file: UploadFile) -> str:
    """Store a bot profile image without changing the shared auth router."""
    if file.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(400, "Только JPEG / PNG / WebP")
    raw = await file.read()
    if len(raw) > 5 * 1024 * 1024:
        raise HTTPException(413, "Файл больше 5 МБ")
    if len(raw) < 100:
        raise HTTPException(400, "Файл слишком маленький")
    try:
        from PIL import Image
        import io

        image = Image.open(io.BytesIO(raw))
        image.load()
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGB")
        elif image.mode == "RGBA":
            background = Image.new("RGB", image.size, (255, 255, 255))
            background.paste(image, mask=image.split()[3])
            image = background
        width, height = image.size
        side = min(width, height)
        left = (width - side) // 2
        top = (height - side) // 2
        image = image.crop((left, top, left + side, top + side))
        image = image.resize((512, 512), Image.LANCZOS)
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=85, optimize=True)
        image_bytes = output.getvalue()
    except Exception as error:
        raise HTTPException(400, f"Не удалось обработать изображение: {error}")

    os.makedirs(BOT_AVATARS_DIR, exist_ok=True)
    filename = f"{user_id}_{time.time_ns()}.jpg"
    path = os.path.join(BOT_AVATARS_DIR, filename)
    with open(path, "wb") as avatar_file:
        avatar_file.write(image_bytes)
    avatar_url = f"/media/avatars/{filename}"
    c = db()
    try:
        old = c.execute(
            "SELECT avatar_url FROM users WHERE id=?", (user_id,)
        ).fetchone()
        if old is None:
            raise HTTPException(404, "Профиль бота не найден")
        c.execute("UPDATE users SET avatar_url=? WHERE id=?", (avatar_url, user_id))
        c.commit()
    except Exception:
        try:
            os.remove(path)
        except OSError:
            pass
        raise
    finally:
        c.close()
    old_url = old["avatar_url"]
    if old_url and old_url.startswith("/media/avatars/"):
        try:
            os.remove(os.path.join(BOT_AVATARS_DIR, os.path.basename(old_url)))
        except OSError:
            pass
    return avatar_url


def _delete_bot_avatar_for_user(user_id: int) -> None:
    c = db()
    try:
        old = c.execute(
            "SELECT avatar_url FROM users WHERE id=?", (user_id,)
        ).fetchone()
        if old is None:
            raise HTTPException(404, "Профиль бота не найден")
        c.execute("UPDATE users SET avatar_url=NULL WHERE id=?", (user_id,))
        c.commit()
    finally:
        c.close()
    old_url = old["avatar_url"]
    if old_url and old_url.startswith("/media/avatars/"):
        try:
            os.remove(os.path.join(BOT_AVATARS_DIR, os.path.basename(old_url)))
        except OSError:
            pass


@router.post("/{bot_id}/avatar")
async def upload_bot_avatar(
    bot_id: int,
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
):
    owner = auth_member(authorization)
    _rate_limit(f"botavatar:{owner['id']}", limit=10, window=3600)
    c = db()
    try:
        bot = _get_owned_bot(c, bot_id, int(owner["id"]))
        user_id = int(bot["user_id"])
    finally:
        c.close()
    avatar_url = await _store_bot_avatar_for_user(user_id, file)
    return {"status": "ok", "avatar_url": avatar_url}


@router.delete("/{bot_id}/avatar")
def delete_bot_avatar(
    bot_id: int, authorization: Optional[str] = Header(None)
):
    owner = auth_member(authorization)
    _rate_limit(f"botavatar:{owner['id']}", limit=10, window=3600)
    c = db()
    try:
        bot = _get_owned_bot(c, bot_id, int(owner["id"]))
        user_id = int(bot["user_id"])
    finally:
        c.close()
    _delete_bot_avatar_for_user(user_id)
    return {"status": "ok", "avatar_url": None}


@router.post("/{bot_id}/regenerate")
async def regenerate_bot_token(
    bot_id: int, authorization: Optional[str] = Header(None)
):
    owner = auth_member(authorization)
    _require_app_device(owner)
    _rate_limit(f"botregen:{owner['id']}", limit=10, window=3600)
    new_token = secrets.token_urlsafe(32)
    new_hash = hash_argon2(new_token)
    digest = _token_digest(new_token)
    try:
        runner_token = encrypt_runner_token(new_token, bot_id)
    except BotRunnerKeyUnavailable:
        runner_token = None
    c = db()
    try:
        _get_owned_bot(c, bot_id, int(owner["id"]))
        c.execute(
            "UPDATE bots SET token_hash=?, token_digest=?, managed_token_enc=?, "
            "managed_enabled=0, status='offline' WHERE id=?",
            (new_hash, digest, runner_token, bot_id),
        )
        c.commit()
    finally:
        c.close()
    await asyncio.to_thread(_set_bot_status, bot_id, "offline")
    session = _current_session(bot_id)
    if session:
        await _close_session(session, code=4401, reason="Bot token was rotated")
    return {"status": "ok", "token": new_token}


def _claim_bot_inbox_message(message_id: int) -> bool:
    c = db()
    try:
        updated = c.execute(
            "UPDATE chat_dm SET bot_notified_at=? "
            "WHERE id=? AND bot_notified_at IS NULL",
            (int(time.time()), message_id),
        )
        c.commit()
        return updated.rowcount == 1
    finally:
        c.close()


def _release_bot_inbox_message(message_id: int) -> None:
    c = db()
    try:
        c.execute("UPDATE chat_dm SET bot_notified_at=NULL WHERE id=?", (message_id,))
        c.commit()
    finally:
        c.close()


async def _notify_bot_inbox_message(
    session: _BotSession,
    *,
    message_id: int,
    from_user_id: int,
    from_username: str,
    text: str,
    created_at: Any,
) -> bool:
    if _current_session(session.bot_id) is not session:
        return False
    claimed = await asyncio.to_thread(_claim_bot_inbox_message, message_id)
    if not claimed:
        return False
    try:
        await _send_session_frame(
            session,
            _event_frame(
                "message.received",
                {
                    "message_id": message_id,
                    "from_user_id": from_user_id,
                    "from_username": from_username,
                    "text": text,
                    "created_at": created_at,
                },
                event_id=f"dm:{message_id}",
            ),
        )
        return True
    except Exception:
        await asyncio.to_thread(_release_bot_inbox_message, message_id)
        log.info(
            "Could not notify bot_id=%s about queued message_id=%s; it remains queued",
            session.bot_id,
            message_id,
            exc_info=True,
        )
        return False


async def _deliver_pending_bot_messages(session: _BotSession) -> None:
    c = db()
    try:
        rows = c.execute(
            "SELECT m.id, m.text, m.created_at, u.id AS from_user_id, "
            "u.username AS from_username FROM chat_dm m "
            "JOIN users u ON u.id=m.sender_id "
            "JOIN bots b ON b.user_id=m.receiver_id "
            "WHERE b.id=? AND b.is_active=1 AND m.bot_notified_at IS NULL "
            "ORDER BY m.id ASC LIMIT 500",
            (session.bot_id,),
        ).fetchall()
    finally:
        c.close()
    for row in rows:
        if _current_session(session.bot_id) is not session:
            return
        delivered = await _notify_bot_inbox_message(
            session,
            message_id=int(row["id"]),
            from_user_id=int(row["from_user_id"]),
            from_username=row["from_username"],
            text=row["text"],
            created_at=row["created_at"],
        )
        if not delivered:
            return


async def send_human_message_to_bot(
    sender: dict, *, to_username: str, text: str,
    client_message_id: Optional[str] = None,
) -> dict:
    """Persist a human-to-bot DM; notify now or replay it after reconnection."""
    _rate_limit(f"botinbox:{sender['id']}", limit=60, window=60)
    if not isinstance(text, str):
        raise HTTPException(422, "plain_text обязателен")
    clean_text = text.strip()
    if not clean_text or len(clean_text) > MAX_BOT_MESSAGE_CHARS:
        raise HTTPException(400, "Сообщение боту должно содержать от 1 до 4000 символов")
    if not isinstance(to_username, str) or not to_username.strip():
        raise HTTPException(422, "to_username обязателен")

    c = db()
    try:
        if client_message_id:
            c.execute("BEGIN IMMEDIATE")
            cached = _idempotency_lookup(
                c, int(sender["id"]), "dm_bot", client_message_id
            )
            if cached is not None:
                c.commit()
                return cached
        bot_row = c.execute(
            "SELECT b.id AS bot_id, b.user_id, b.status, u.username "
            "FROM bots b JOIN users u ON u.id=b.user_id "
            "WHERE lower(u.username)=? AND b.is_active=1 LIMIT 1",
            (to_username.strip().lstrip("@").lower(),),
        ).fetchone()
        if not bot_row:
            raise HTTPException(422, "plain_text разрешён только для активного бота")
        if int(bot_row["user_id"]) == int(sender["id"]):
            raise HTTPException(400, "Нельзя написать боту от его имени")
        if _is_blocked(c, int(sender["id"]), int(bot_row["user_id"])):
            raise HTTPException(403, "Переписка заблокирована")
        privacy = _get_privacy_flags(c, int(bot_row["user_id"]))
        if privacy.get("message_privacy") == "nobody":
            raise HTTPException(403, "Бот запретил входящие сообщения")
        if privacy.get("message_privacy") == "contacts":
            contact = c.execute(
                "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
                (bot_row["user_id"], sender["id"]),
            ).fetchone()
            if not contact:
                raise HTTPException(403, "Писать боту могут только его контакты")

        c.execute(
            "INSERT INTO chat_dm(sender_id, receiver_id, text, bot_notified_at) "
            "VALUES (?, ?, ?, NULL)",
            (sender["id"], bot_row["user_id"], clean_text),
        )
        message_id = int(c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"])
        created = c.execute(
            "SELECT created_at FROM chat_dm WHERE id=?", (message_id,)
        ).fetchone()["created_at"]
        queued_response = {
            "status": "ok",
            "id": message_id,
            "created_at": created,
            "recipient_online": False,
        }
        _idempotency_store(
            c, int(sender["id"]), "dm_bot", client_message_id, queued_response
        )
        c.commit()
        bot_id = int(bot_row["bot_id"])
        bot_status = bot_row["status"]
        bot_username = bot_row["username"]
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

    session = _current_session(bot_id)
    recipient_online = False
    if session is not None and bot_status == "online":
        recipient_online = await _notify_bot_inbox_message(
            session,
            message_id=message_id,
            from_user_id=int(sender["id"]),
            from_username=sender["username"],
            text=clean_text,
            created_at=created,
        )

    ws_hub.send_to(
        int(sender["id"]),
        "chat.echo",
        {
            "id": message_id,
            "from_username": sender["username"],
            "from_display_name": sender.get("display_name"),
            "from_avatar_url": sender.get("avatar_url"),
            "to_username": bot_username,
            "plain_text": clean_text,
            "created_at": created,
        },
    )
    return {
        "status": "ok",
        "id": message_id,
        "created_at": created,
        "recipient_online": recipient_online,
    }


@router.post("/{bot_id}/message")
async def send_message_to_bot(
    bot_id: int,
    body: HumanBotMessageBody,
    authorization: Optional[str] = Header(None),
):
    """Compatibility route using the same durable queue as /api/chat/send."""
    sender = auth_member(authorization)
    c = db()
    try:
        bot_row = c.execute(
            "SELECT u.username FROM bots b JOIN users u ON u.id=b.user_id "
            "WHERE b.id=? AND b.is_active=1",
            (bot_id,),
        ).fetchone()
        if not bot_row:
            raise HTTPException(404, "Бот не найден")
        username = bot_row["username"]
    finally:
        c.close()
    return await send_human_message_to_bot(
        sender, to_username=username, text=body.text
    )


@router.post("/{bot_id}/callback")
async def send_button_callback_to_bot(
    bot_id: int,
    body: BotButtonCallbackBody,
    authorization: Optional[str] = Header(None),
):
    """Deliver a tap on a bot message's inline button as a callback event."""
    sender = auth_member(authorization)
    _rate_limit(f"botcallback:{sender['id']}", limit=60, window=60)
    session = _current_session(bot_id)
    c = db()
    try:
        bot_row = c.execute(
            "SELECT b.user_id, b.status FROM bots b "
            "WHERE b.id=? AND b.is_active=1",
            (bot_id,),
        ).fetchone()
        if not bot_row:
            raise HTTPException(404, "Бот не найден")
        _rate_limit(f"botcallback-target:{bot_id}", limit=600, window=60)
        if not session or bot_row["status"] != "online":
            raise HTTPException(409, "Бот сейчас офлайн")
        if _is_blocked(c, int(sender["id"]), int(bot_row["user_id"])):
            raise HTTPException(403, "Переписка заблокирована")

        row = c.execute(
            "SELECT bot_reply_markup FROM chat_dm "
            "WHERE id=? AND sender_id=? AND receiver_id=?",
            (body.message_id, bot_row["user_id"], sender["id"]),
        ).fetchone()
        if not row or not row["bot_reply_markup"]:
            raise HTTPException(404, "Кнопка сообщения не найдена")
        try:
            markup = json.loads(row["bot_reply_markup"])
        except (TypeError, json.JSONDecodeError) as exc:
            log.warning("Invalid stored reply markup for message_id=%s", body.message_id)
            raise HTTPException(409, "Кнопки сообщения больше недоступны") from exc
        if not isinstance(markup, dict) or not isinstance(
            markup.get("inline_keyboard"), list
        ):
            raise HTTPException(409, "В сообщении нет доступных inline-кнопок")

        callback_exists = any(
            button.get("callback_data") == body.callback_data
            for row_buttons in markup["inline_keyboard"]
            if isinstance(row_buttons, list)
            for button in row_buttons
            if isinstance(button, dict)
        )
        if not callback_exists:
            raise HTTPException(404, "Inline-кнопка не найдена в сообщении")
    finally:
        c.close()

    callback_id = uuid.uuid4().hex
    try:
        await _send_session_frame(
            session,
            _event_frame(
                "button.callback",
                {
                    "callback_id": callback_id,
                    "message_id": body.message_id,
                    "from_user_id": int(sender["id"]),
                    "from_username": sender["username"],
                    "callback_data": body.callback_data,
                },
                event_id=f"button:{body.message_id}:{callback_id}",
            ),
        )
    except Exception as exc:
        raise HTTPException(503, "Не удалось доставить нажатие подключённому боту") from exc
    return {"status": "ok", "callback_id": callback_id}


@router.post("/test/sessions")
async def open_bot_test_session(
    body: BotTestSessionBody,
    authorization: Optional[str] = Header(None),
):
    """Open an ephemeral encrypted test chat for the bot's owner."""
    bot = _bot_from_authorization(authorization)
    if bot is None:
        owner = auth_member(authorization)
        if body.bot_id is None:
            raise HTTPException(400, "bot_id is required")
        c = db()
        try:
            bot = _get_owned_bot(c, body.bot_id, int(owner["id"]))
        finally:
            c.close()
    elif body.bot_id is not None and int(bot["bot_id"]) != body.bot_id:
        raise HTTPException(403, "Bot token does not match bot_id")
    _rate_limit(f"bottestopen:{bot['bot_id']}", limit=12, window=60)
    client_public_key = _validated_public_key(body.client_public_key)
    live = _current_session(int(bot["bot_id"]))
    if not live or not live.crypto_public_key:
        raise HTTPException(
            409,
            "Bot is offline or its SDK does not support encrypted test chats",
        )

    _prune_bot_test_sessions()
    session_id = secrets.token_urlsafe(24)
    now = time.monotonic()
    test_session = _BotTestSession(
        session_id=session_id,
        bot_id=int(bot["bot_id"]),
        client_public_key=client_public_key,
        created_at=now,
        last_activity=now,
    )
    with _test_sessions_lock:
        active_for_bot = sum(
            1 for item in _test_sessions.values() if item.bot_id == test_session.bot_id
        )
        if active_for_bot >= 8:
            raise HTTPException(429, "Too many active bot test chats")
        _test_sessions[session_id] = test_session

    try:
        await _send_session_frame(
            live,
            _event_frame(
                "test.session.open",
                {
                    "test_session_id": session_id,
                    "client_public_key": client_public_key,
                },
                event_id=f"test-open:{session_id}",
            ),
        )
    except Exception as exc:
        with _test_sessions_lock:
            _test_sessions.pop(session_id, None)
        raise HTTPException(503, "Could not reach the connected bot") from exc

    return {
        "status": "ok",
        "session_id": session_id,
        "bot_id": int(bot["bot_id"]),
        "username": bot["username"],
        "display_name": bot["display_name"],
        "bot_public_key": live.crypto_public_key,
    }


@router.post("/test/sessions/{session_id}/messages")
async def send_bot_test_message(
    session_id: str,
    body: BotTestMessageBody,
    authorization: Optional[str] = Header(None),
):
    """Relay only an opaque encrypted test message to the bot process."""
    bot, test_session = _authorize_bot_test_session(session_id, authorization)
    _rate_limit(f"bottestmsg:{bot['bot_id']}", limit=60, window=60)
    live = _current_session(int(bot["bot_id"]))
    if not live or not live.crypto_public_key:
        raise HTTPException(409, "Bot disconnected; open a new test chat")
    encrypted_text = _validated_encrypted_text(body.encrypted_text)
    message = _append_bot_test_message(test_session, "tester", encrypted_text)
    try:
        await _send_session_frame(
            live,
            _event_frame(
                "message.received",
                {
                    "message_id": message["id"],
                    "test_session_id": session_id,
                    "from_username": "tester",
                    "encrypted_text": encrypted_text,
                    "created_at": message["created_at"],
                },
                event_id=f"test:{session_id}:{message['id']}",
            ),
        )
    except Exception as exc:
        raise HTTPException(503, "Could not deliver the encrypted test message") from exc
    return {"status": "ok", "id": message["id"], "created_at": message["created_at"]}


@router.get("/test/sessions/{session_id}/messages")
def list_bot_test_messages(
    session_id: str,
    after_id: int = Query(0, ge=0),
    authorization: Optional[str] = Header(None),
):
    """Poll encrypted messages for the owner or legacy Bot-token session."""
    bot, test_session = _authorize_bot_test_session(session_id, authorization)
    _rate_limit(f"bottestpoll:{bot['bot_id']}", limit=120, window=60)
    with _test_sessions_lock:
        messages = [
            dict(message)
            for message in test_session.messages
            if message["id"] > after_id
        ]
    return {
        "messages": messages,
        "next_after_id": messages[-1]["id"] if messages else after_id,
    }


@router.delete("/test/sessions/{session_id}")
async def close_bot_test_session(
    session_id: str,
    authorization: Optional[str] = Header(None),
):
    bot, test_session = _authorize_bot_test_session(session_id, authorization)
    with _test_sessions_lock:
        _test_sessions.pop(test_session.session_id, None)
    live = _current_session(int(bot["bot_id"]))
    if live:
        try:
            await _send_session_frame(
                live,
                _event_frame(
                    "test.session.close",
                    {"test_session_id": session_id},
                    event_id=f"test-close:{session_id}",
                ),
            )
        except Exception:
            pass
    return {"status": "ok"}


@router.websocket("/ws")
async def bot_websocket(websocket: WebSocket):
    bot = await asyncio.to_thread(
        _bot_from_authorization, websocket.headers.get("authorization")
    )
    if not bot:
        await websocket.close(code=4401, reason="Invalid bot token")
        return

    await websocket.accept()
    session = _BotSession(
        bot_id=int(bot["bot_id"]),
        websocket=websocket,
        loop=asyncio.get_running_loop(),
    )
    old_session = _register_session(session)
    if old_session:
        await _close_session(old_session, code=4001, reason="Replaced by a newer session")

    now = time.monotonic()
    last_client_ping: Optional[float] = None
    next_server_ping = now + SERVER_PING_INTERVAL_SECONDS
    pending_server_ping: Optional[str] = None
    pending_server_ping_at: Optional[float] = None
    inbox_replay_attempted = False

    try:
        while True:
            now = time.monotonic()
            if last_client_ping is not None and now - last_client_ping >= CLIENT_PING_TIMEOUT_SECONDS:
                break
            if (
                pending_server_ping_at is not None
                and now - pending_server_ping_at >= SERVER_PONG_TIMEOUT_SECONDS
            ):
                break

            if pending_server_ping is None and now >= next_server_ping:
                pending_server_ping = uuid.uuid4().hex
                pending_server_ping_at = now
                await websocket.send_json({"type": "ping", "ping_id": pending_server_ping})
                next_server_ping = now + SERVER_PING_INTERVAL_SECONDS

            deadlines = []
            if pending_server_ping is None:
                deadlines.append(next_server_ping)
            if last_client_ping is None:
                deadlines.append(now + CLIENT_PING_TIMEOUT_SECONDS)
            else:
                deadlines.append(last_client_ping + CLIENT_PING_TIMEOUT_SECONDS)
            if pending_server_ping_at is not None:
                deadlines.append(pending_server_ping_at + SERVER_PONG_TIMEOUT_SECONDS)
            wait_seconds = max(0.05, min(deadlines) - time.monotonic())

            try:
                raw = await asyncio.wait_for(websocket.receive_text(), timeout=wait_seconds)
            except asyncio.TimeoutError:
                continue
            if len(raw) > MAX_FRAME_CHARS:
                await websocket.close(code=4400, reason="Frame too large")
                break
            try:
                frame = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                await websocket.close(code=4400, reason="Invalid JSON frame")
                break
            if not isinstance(frame, dict):
                await websocket.close(code=4400, reason="Frame must be a JSON object")
                break

            frame_type = frame.get("type")
            if frame_type == "hello":
                if session.crypto_public_key is not None:
                    await websocket.close(code=4400, reason="Duplicate hello frame")
                    break
                if frame.get("key_exchange") != "x25519" or frame.get("version") != 1:
                    await websocket.close(code=4400, reason="Unsupported bot hello")
                    break
                try:
                    session.crypto_public_key = _validated_public_key(
                        frame.get("public_key")
                    )
                except HTTPException:
                    await websocket.close(code=4400, reason="Invalid bot public key")
                    break
                await websocket.send_json(
                    _event_frame(
                        "bot.crypto.ready",
                        {"key_exchange": "x25519", "version": 1},
                    )
                )
                continue

            if frame_type == "ping":
                ping_id = frame.get("ping_id")
                if not isinstance(ping_id, str) or not ping_id or len(ping_id) > 128:
                    await websocket.close(code=4400, reason="Invalid ping_id")
                    break
                last_client_ping = time.monotonic()
                changed, status_payload = await asyncio.to_thread(
                    _set_session_status, session, "online"
                )
                await websocket.send_json({"type": "pong", "ping_id": ping_id})
                if changed and status_payload:
                    await websocket.send_json(_event_frame("bot.status", status_payload))
                if not inbox_replay_attempted:
                    inbox_replay_attempted = True
                    try:
                        await _deliver_pending_bot_messages(session)
                    except Exception:
                        log.exception(
                            "Could not replay queued inbox for bot_id=%s",
                            session.bot_id,
                        )
                continue

            if frame_type == "pong":
                ping_id = frame.get("ping_id")
                if not isinstance(ping_id, str) or not ping_id:
                    await websocket.close(code=4400, reason="Invalid ping_id")
                    break
                if pending_server_ping and ping_id == pending_server_ping:
                    pending_server_ping = None
                    pending_server_ping_at = None
                continue

            if frame_type == "action":
                should_close = await _dispatch_action(websocket, session, bot, frame)
                if should_close:
                    break
                continue

            await websocket.close(code=4400, reason="Unsupported frame type")
            break
    except WebSocketDisconnect:
        pass
    except Exception:
        log.exception("Bot WebSocket failed for bot_id=%s", bot["bot_id"])
    finally:
        try:
            _, status_payload = await asyncio.to_thread(
                _set_session_status, session, "offline", remove=True
            )
            if status_payload:
                _clear_bot_test_sessions(session.bot_id)
        except Exception:
            log.exception("Could not mark bot offline for bot_id=%s", bot["bot_id"])
