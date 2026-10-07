"""Room metadata API for GhostChat 1.2.

Channels live in ``gc_channels`` and groups in ``gc_groups``. They share a
small response contract for the client, but remain different entities:
channels and groups both have a globally unique username.
Messages, encrypted attachments, membership, and pin retention share this API.
"""

import base64
from chat_client_idempotency import begin as idem_begin, save as idem_save
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import sqlite3
import tempfile
import time
import uuid
from typing import Optional
from urllib.parse import unquote, urlsplit

from fastapi import APIRouter, File, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from ecos_core.identity import db
from ecos_core.client import auth, auth_member
from ecos_core.login import _consume_password_challenge, _persist_password_verifier
from ecos_core.shared import _decode_banner_config, _normalize_banner_config, _rate_limit, _val_name, _val_username, _get_privacy_flags
from ecos_core.realtime import ws_hub


router = APIRouter(prefix="/api/chat/v2/rooms", tags=["GhostChat rooms v2"])

ROOM_FILE_MAX_BYTES = 50 * 1024 * 1024
ROOM_FILE_TTL_SECONDS = 5 * 24 * 60 * 60
_ROOM_FILE_DIR = os.environ.get(
    "GC_ROOM_FILE_DIR",
    os.path.join(os.environ.get("GC_UPLOADS_DIR", "/opt/ghostchat/uploads"), "room_files"),
)
os.makedirs(_ROOM_FILE_DIR, exist_ok=True)


class GroupCreateBody(BaseModel):
    username: Optional[str] = Field(default=None, min_length=3, max_length=64)
    title: str = Field(min_length=2, max_length=100)
    about: str = Field(default="", max_length=512)
    visibility: str = Field(default="private", max_length=16)
    history_mode: str = Field(default="new_only", max_length=16)


class GroupMemberBody(BaseModel):
    username: str = Field(min_length=3, max_length=64)


class RoomJoinBody(BaseModel):
    password: Optional[str] = Field(default=None, max_length=128)


class RoomPinBody(BaseModel):
    message_id: int = Field(gt=0)
    notify: bool = True
    preview_text: Optional[str] = Field(default=None, max_length=2000)


class RoomInviteLinkBody(BaseModel):
    expires_hours: Optional[int] = Field(default=None, ge=1, le=8760)
    max_uses: Optional[int] = Field(default=None, ge=1, le=100000)
    request_join: bool = False
    usernames: list[str] = Field(default_factory=list, max_length=500)


class RoomJoinDecisionBody(BaseModel):
    action: str = Field(min_length=2, max_length=16)


class GroupPatchBody(BaseModel):
    username: Optional[str] = Field(default=None, min_length=3, max_length=64)
    title: Optional[str] = Field(default=None, min_length=2, max_length=100)
    about: Optional[str] = Field(default=None, max_length=512)
    banner: Optional[dict] = None
    banner_clear: bool = False
    visibility: Optional[str] = Field(default=None, max_length=16)
    history_mode: Optional[str] = Field(default=None, max_length=16)
    rules: Optional[str] = Field(default=None, max_length=2000)
    board_text: Optional[str] = Field(default=None, max_length=2000)
    preview_fields: Optional[list[str]] = None
    show_pinned_preview: Optional[bool] = None
    join_mode: Optional[str] = Field(default=None, max_length=16)
    join_password: Optional[str] = Field(default=None, max_length=128)


class RoomConvertBody(BaseModel):
    room_type: str = Field(min_length=5, max_length=16)


class RoomOwnerTransferBody(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    challenge_id: str = Field(min_length=16, max_length=128)
    proof: str = Field(min_length=32, max_length=256)


class RoomEnvelopeBody(BaseModel):
    target_device_id: int
    envelope: str
    target_device_pub: Optional[str] = None


class RoomSendBody(BaseModel):
    client_message_id: Optional[str] = Field(default=None, min_length=16, max_length=128)
    sender_identity_pub: Optional[str] = Field(default=None, max_length=100)
    payload: Optional[str] = Field(default=None, max_length=20000)
    envelopes: list[RoomEnvelopeBody] = Field(default_factory=list, max_length=64)
    attachment_file_ids: list[str] = Field(default_factory=list, max_length=5)


class RoomReceiptBody(BaseModel):
    message_ids: list[int] = Field(default_factory=list, max_length=200)
    status: str = Field(min_length=1, max_length=16)


_VISIBILITIES = {"public", "private"}
_HISTORY_MODES = {"new_only", "all"}
_JOIN_MODES = {"open", "request", "password"}
_PREVIEW_FIELDS = {
    "about",
    "avatar",
    "banner",
    "history",
    "members_count",
    "rules",
    "username",
}
_DEFAULT_PREVIEW_FIELDS = sorted(_PREVIEW_FIELDS)
MAX_GROUPS_PER_USER = 15

_ROOM_LINK_HOSTS = {"ghostecos.duckdns.org", "ghostchats.duckdns.org"}
_ROOM_LINK_HANDLE = re.compile(r"^[a-z0-9_.]{3,64}$")


def _parse_room_search_link(raw: str) -> Optional[tuple[str, str | int]]:
    """Return the exact room reference encoded by a public GhostChat URL."""
    value = (raw or "").strip()
    if not value:
        return None
    if "://" not in value:
        value = f"https://{value}"
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
    except ValueError:
        return None
    if (
        parsed.scheme.lower() != "https"
        or host not in _ROOM_LINK_HOSTS
        or parsed.username is not None
        or parsed.password is not None
    ):
        return None

    segments = [unquote(part) for part in parsed.path.strip("/").split("/") if part]
    if len(segments) != 2:
        return None
    kind = segments[0].lower()
    reference = segments[1].lower()
    if kind == "c" and _ROOM_LINK_HANDLE.fullmatch(reference):
        return "channel_username", reference
    if kind != "g":
        return None
    if reference.isdigit():
        room_id = int(reference)
        if 0 < room_id <= (2**63 - 1):
            return "group_id", room_id
        return None
    if _ROOM_LINK_HANDLE.fullmatch(reference):
        return "group_username", reference
    return None


def _resolve_room_link_search(
    c,
    raw: str,
    user_id: Optional[int],
    room_type: Optional[str] = None,
) -> Optional[list[dict]]:
    """Resolve a room link, returning None when the query is ordinary text."""
    link_reference = _parse_room_search_link(raw)
    if link_reference is None:
        return None

    reference_kind, reference = link_reference
    expected_type = (
        "channel" if reference_kind == "channel_username" else "group"
    )
    if room_type is not None and room_type != expected_type:
        return []

    if reference_kind == "channel_username":
        row = c.execute(
            """
            SELECT * FROM gc_channels
            WHERE status='active' AND lower(username)=?
            """,
            (reference,),
        ).fetchone()
        kind = "channel"
    elif reference_kind == "group_id":
        row = c.execute(
            """
            SELECT * FROM gc_groups
            WHERE status='active' AND visibility='public' AND id=?
            """,
            (reference,),
        ).fetchone()
        kind = "group"
    else:
        row = c.execute(
            """
            SELECT * FROM gc_groups
            WHERE status='active' AND lower(username)=?
            """,
            (reference,),
        ).fetchone()
        kind = "group"

    if not row:
        return []
    payload = _preview_room_payload(c, kind, row, user_id)
    payload["is_member"] = (
        _room_role(c, kind, row["id"], user_id) is not None
        if user_id
        else False
    )
    return [payload]


def init_rooms_v2() -> None:
    c = db()
    try:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS gc_groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT,
                title TEXT NOT NULL,
                about TEXT NOT NULL DEFAULT '',
                avatar_url TEXT NULL,
                banner_config TEXT NULL,
                owner_id INTEGER NOT NULL,
                visibility TEXT NOT NULL DEFAULT 'private'
                    CHECK(visibility IN ('public', 'private')),
                history_mode TEXT NOT NULL DEFAULT 'new_only'
                    CHECK(history_mode IN ('new_only', 'all')),
                rules TEXT NOT NULL DEFAULT '',
                board_text TEXT NOT NULL DEFAULT '',
                preview_fields TEXT NOT NULL DEFAULT '["about","avatar","banner","history","members_count","rules","username"]',
                show_pinned_preview INTEGER NOT NULL DEFAULT 0,
                join_mode TEXT NOT NULL DEFAULT 'open'
                    CHECK(join_mode IN ('open', 'request', 'password')),
                join_password_hash TEXT NOT NULL DEFAULT '',
                encryption_mode TEXT NOT NULL DEFAULT 'e2ee_v2'
                    CHECK(encryption_mode IN ('none', 'e2ee_v2')),
                key_epoch INTEGER NOT NULL DEFAULT 1,
                status TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active', 'archived')),
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_gc_groups_owner
                ON gc_groups(owner_id, status, id DESC);

            CREATE TABLE IF NOT EXISTS gc_group_members (
                group_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                role TEXT NOT NULL DEFAULT 'member'
                    CHECK(role IN ('owner', 'admin', 'member')),
                joined_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                PRIMARY KEY(group_id, user_id),
                FOREIGN KEY(group_id) REFERENCES gc_groups(id),
                FOREIGN KEY(user_id) REFERENCES users(id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_group_members_user
                ON gc_group_members(user_id, joined_at DESC);

            CREATE TABLE IF NOT EXISTS gc_room_join_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                room_type TEXT NOT NULL CHECK(room_type IN ('channel', 'group')),
                room_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending', 'accepted', 'rejected')),
                requested_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                reviewed_by INTEGER,
                reviewed_at INTEGER,
                UNIQUE(room_type, room_id, user_id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_join_requests_review
                ON gc_room_join_requests(room_type, room_id, status, requested_at);

            CREATE TABLE IF NOT EXISTS gc_room_invite_links (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                room_type TEXT NOT NULL CHECK(room_type IN ('channel', 'group')),
                room_id INTEGER NOT NULL,
                token TEXT NOT NULL UNIQUE,
                token_hash TEXT NOT NULL UNIQUE,
                expires_at INTEGER,
                max_uses INTEGER,
                uses INTEGER NOT NULL DEFAULT 0,
                request_join INTEGER NOT NULL DEFAULT 0,
                active INTEGER NOT NULL DEFAULT 1,
                created_by INTEGER NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_invite_links_room
                ON gc_room_invite_links(room_type, room_id, active, created_at DESC);

            CREATE TABLE IF NOT EXISTS gc_room_invite_recipients (
                link_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                redeemed_at INTEGER,
                PRIMARY KEY(link_id, user_id),
                FOREIGN KEY(link_id) REFERENCES gc_room_invite_links(id),
                FOREIGN KEY(user_id) REFERENCES users(id)
            );

            CREATE TABLE IF NOT EXISTS gc_room_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                room_type TEXT NOT NULL CHECK(room_type IN ('channel', 'group')),
                room_id INTEGER NOT NULL,
                sender_id INTEGER NOT NULL,
                payload TEXT,
                is_encrypted INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                attachment_file_ids TEXT NOT NULL DEFAULT '[]'
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_messages_room
                ON gc_room_messages(room_type, room_id, id ASC);

            CREATE TABLE IF NOT EXISTS gc_room_pins (
                room_type TEXT NOT NULL CHECK(room_type IN ('channel', 'group')),
                room_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                pinned_by INTEGER NOT NULL,
                pinned_at INTEGER NOT NULL,
                notify INTEGER NOT NULL DEFAULT 1,
                preview_text TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(room_type, room_id, message_id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_pins_order
                ON gc_room_pins(room_type, room_id, pinned_at DESC);

            CREATE TABLE IF NOT EXISTS gc_room_files (
                file_id TEXT PRIMARY KEY,
                room_type TEXT NOT NULL CHECK(room_type IN ('channel', 'group')),
                room_id INTEGER NOT NULL,
                uploader_id INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_files_expiry
                ON gc_room_files(expires_at);

            CREATE TABLE IF NOT EXISTS gc_room_envelopes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id INTEGER NOT NULL,
                receiver_user_id INTEGER NOT NULL,
                receiver_device_id INTEGER NOT NULL,
                envelope TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                UNIQUE(message_id, receiver_device_id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_envelopes_device
                ON gc_room_envelopes(receiver_user_id, receiver_device_id, message_id);

            CREATE TABLE IF NOT EXISTS gc_room_message_receipts (
                message_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                delivered_at INTEGER,
                read_at INTEGER,
                PRIMARY KEY(message_id, user_id),
                FOREIGN KEY(message_id) REFERENCES gc_room_messages(id) ON DELETE CASCADE,
                FOREIGN KEY(user_id) REFERENCES users(id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_receipts_message
                ON gc_room_message_receipts(message_id, delivered_at, read_at);
            """
        )
        try:
            c.execute("ALTER TABLE gc_groups ADD COLUMN avatar_url TEXT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE gc_groups ADD COLUMN banner_config TEXT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE gc_groups ADD COLUMN username TEXT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute(
                "ALTER TABLE gc_room_messages ADD COLUMN "
                "attachment_file_ids TEXT NOT NULL DEFAULT '[]'"
            )
        except sqlite3.OperationalError:
            pass
        for column, definition in (
            ("rules", "TEXT NOT NULL DEFAULT ''"),
            ("board_text", "TEXT NOT NULL DEFAULT ''"),
            (
                "preview_fields",
                "TEXT NOT NULL DEFAULT '[\"about\",\"avatar\",\"banner\",\"history\",\"members_count\",\"rules\",\"username\"]'",
            ),
            ("show_pinned_preview", "INTEGER NOT NULL DEFAULT 0"),
            ("join_mode", "TEXT NOT NULL DEFAULT 'open'"),
            ("join_password_hash", "TEXT NOT NULL DEFAULT ''"),
        ):
            try:
                c.execute(f"ALTER TABLE gc_groups ADD COLUMN {column} {definition}")
            except sqlite3.OperationalError:
                pass
        c.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_gc_groups_username "
            "ON gc_groups(username) WHERE username IS NOT NULL"
        )
        # Groups existed before they had public usernames. Give those rows a
        # stable handle so every group returned by the new API has the same
        # identity contract, without changing any existing message IDs.
        legacy_groups = c.execute(
            "SELECT id FROM gc_groups WHERE username IS NULL ORDER BY id ASC"
        ).fetchall()
        for legacy in legacy_groups:
            candidate = _new_group_username(c, int(legacy["id"]))
            c.execute(
                "UPDATE gc_groups SET username=? WHERE id=?",
                (candidate, legacy["id"]),
            )
        # A public group is plaintext by contract. Repair rows created by an
        # older build so the client never asks for E2EE keys for them.
        c.execute(
            "UPDATE gc_groups SET encryption_mode='none' "
            "WHERE visibility='public' AND encryption_mode<>'none'"
        )
        c.commit()
    finally:
        c.close()


def _validate_options(visibility: str, history_mode: str) -> None:
    if visibility not in _VISIBILITIES:
        raise HTTPException(422, "visibility должна быть public или private")
    if history_mode not in _HISTORY_MODES:
        raise HTTPException(422, "history_mode должен быть new_only или all")


def _group_role(c, group_id: int, user_id: int) -> Optional[str]:
    row = c.execute(
        "SELECT role FROM gc_group_members WHERE group_id=? AND user_id=?",
        (group_id, user_id),
    ).fetchone()
    return row["role"] if row else None


def _claim_group_username(c, username: str, group_id: Optional[int] = None) -> str:
    """Validate and reserve a group username in the shared public namespace."""
    normalized = _val_username(username)
    params = [normalized]
    group_clause = ""
    if group_id is not None:
        group_clause = " AND id<>?"
        params.append(group_id)
    if c.execute(
        f"SELECT 1 FROM gc_groups WHERE lower(username)=?{group_clause} LIMIT 1",
        params,
    ).fetchone():
        raise HTTPException(409, "Имя пользователя уже занято")
    if c.execute(
        "SELECT 1 FROM gc_public_handles WHERE handle=? LIMIT 1", (normalized,)
    ).fetchone():
        raise HTTPException(409, "Имя пользователя уже занято")
    if c.execute(
        "SELECT 1 FROM users WHERE lower(username)=? LIMIT 1", (normalized,)
    ).fetchone():
        raise HTTPException(409, "Имя пользователя уже занято")
    if c.execute(
        "SELECT 1 FROM gc_channels WHERE lower(username)=? LIMIT 1", (normalized,)
    ).fetchone():
        raise HTTPException(409, "Имя пользователя уже занято")
    return normalized


def _new_group_username(c, group_id: int) -> str:
    candidate = f"group{group_id}"
    suffix = 0
    while True:
        try:
            return _claim_group_username(c, candidate)
        except HTTPException as error:
            if error.status_code != 409:
                raise
            suffix += 1
            candidate = f"group{group_id}{suffix}"


def _channel_role(c, channel_id: int, user_id: int) -> Optional[str]:
    row = c.execute(
        "SELECT role FROM gc_channel_members WHERE channel_id=? AND user_id=?",
        (channel_id, user_id),
    ).fetchone()
    return row["role"] if row else None


def _room_table(room_type: str) -> tuple[str, str, str]:
    if room_type == "channel":
        return "gc_channels", "gc_channel_members", "channel_id"
    if room_type == "group":
        return "gc_groups", "gc_group_members", "group_id"
    raise HTTPException(422, "Неизвестный тип комнаты")


def _room_row(c, room_type: str, room_id: int):
    table, _, _ = _room_table(room_type)
    row = c.execute(
        f"SELECT * FROM {table} WHERE id=? AND status='active'",
        (room_id,),
    ).fetchone()
    if not row:
        raise HTTPException(404, "Комната не найдена")
    return row


def _room_role(c, room_type: str, room_id: int, user_id: int) -> Optional[str]:
    if room_type == "channel":
        return _channel_role(c, room_id, user_id)
    return _group_role(c, room_id, user_id)


def _room_payload(c, room_type: str, row, user_id: Optional[int] = None) -> dict:
    if room_type == "channel":
        from channel_router_v2 import _channel_dict

        return {"room_type": "channel", **_channel_dict(c, row, user_id)}
    return _format_group(c, row, user_id)


def _room_join_mode(row) -> str:
    if row["visibility"] == "public":
        return "open"
    mode = row["join_mode"] if "join_mode" in row.keys() else "open"
    return mode if mode in _JOIN_MODES else "open"


def _decode_preview_fields(raw) -> list[str]:
    try:
        decoded = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, ValueError):
        decoded = None
    if not isinstance(decoded, list):
        return list(_DEFAULT_PREVIEW_FIELDS)
    return sorted({str(item) for item in decoded if str(item) in _PREVIEW_FIELDS})


def _normalize_preview_fields(raw) -> list[str]:
    if not isinstance(raw, list):
        raise HTTPException(422, "preview_fields должен быть списком")
    values = {str(item) for item in raw}
    if not values.issubset(_PREVIEW_FIELDS):
        raise HTTPException(422, "preview_fields содержит неизвестное поле")
    return sorted(values)


def _preview_room_payload(c, room_type: str, row, user_id: Optional[int]) -> dict:
    room = _room_payload(c, room_type, row, user_id)
    if row["visibility"] != "private" or (
        user_id is not None and _room_role(c, room_type, row["id"], user_id) is not None
    ):
        return room

    fields = _decode_preview_fields(
        row["preview_fields"] if "preview_fields" in row.keys() else None
    )
    room["preview_fields"] = fields
    if "about" not in fields:
        room["about"] = ""
    if "avatar" not in fields:
        room["avatar_url"] = None
    if "banner" not in fields:
        room["banner"] = None
    if "history" not in fields:
        room["history_mode"] = None
    if "members_count" not in fields:
        room["members_count"] = 0
    if "rules" not in fields:
        room["rules"] = ""
    if "username" not in fields:
        room["username"] = None
    # The room board is an explicit public lobby surface and ignores profile
    # field visibility switches by design.
    room["board_text"] = row["board_text"] if "board_text" in row.keys() else ""
    return room


def _hash_room_password(password: str) -> str:
    if len(password) < 8:
        raise HTTPException(422, "Пароль комнаты должен содержать минимум 8 символов")
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 240_000)
    return f"{salt.hex()}:{digest.hex()}"


def _room_password_matches(encoded: str, password: Optional[str]) -> bool:
    if not password:
        return False
    try:
        salt_hex, digest_hex = encoded.split(":", 1)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except (AttributeError, TypeError, ValueError):
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 240_000)
    return hmac.compare_digest(actual, expected)


def _apply_room_access_updates(updates: dict, row, *, join_mode, join_password) -> None:
    visibility = updates.get("visibility", row["visibility"])
    current_mode = _room_join_mode(row)
    mode = join_mode or current_mode
    if visibility == "public":
        if join_mode not in (None, "open"):
            raise HTTPException(422, "Для публичной комнаты доступ всегда открыт")
        mode = "open"
    elif row["visibility"] == "public" and join_mode is None:
        mode = "request"
    if mode not in _JOIN_MODES:
        raise HTTPException(422, "join_mode должен быть open, request или password")
    if visibility == "public" and mode != "open":
        raise HTTPException(422, "Для публичной комнаты доступ всегда открыт")

    password_hash = row["join_password_hash"] if "join_password_hash" in row.keys() else ""
    if join_password is not None:
        if mode != "password":
            raise HTTPException(422, "Пароль можно задать только для режима входа по паролю")
        password_hash = _hash_room_password(join_password)
    if mode == "password" and not password_hash:
        raise HTTPException(422, "Для режима входа по паролю задайте пароль")
    if mode != "password":
        password_hash = ""
    updates["join_mode"] = mode
    updates["join_password_hash"] = password_hash


def _room_join_request(c, room_type: str, room_id: int, user_id: int) -> None:
    now = int(time.time())
    c.execute(
        """
        INSERT INTO gc_room_join_requests
            (room_type, room_id, user_id, status, requested_at, reviewed_by, reviewed_at)
        VALUES (?, ?, ?, 'pending', ?, NULL, NULL)
        ON CONFLICT(room_type, room_id, user_id) DO UPDATE SET
            status='pending', requested_at=excluded.requested_at,
            reviewed_by=NULL, reviewed_at=NULL
        """,
        (room_type, room_id, user_id, now),
    )


def _direct_add_decision(c, inviter_id: int, target_id: int, room_type: str) -> tuple[bool, str]:
    """Return whether the target accepts this direct room invitation.

    A direct add is intentionally stricter than joining through a public link:
    the inviter must already be in the target's contacts and the target must
    allow this room type. Returning a structured refusal lets the client offer
    a targeted invite link instead of pretending the member was added.
    """
    contact = c.execute(
        "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
        (target_id, inviter_id),
    ).fetchone()
    if not contact:
        return False, "not_in_contacts"
    flags = _get_privacy_flags(c, target_id)
    key = "allow_channel_add" if room_type == "channel" else "allow_group_add"
    if not flags.get(key, True):
        return False, "blocked_by_privacy"
    return True, "ok"


def _format_group(c, row, user_id: Optional[int] = None) -> dict:
    count = c.execute(
        "SELECT COUNT(*) AS n FROM gc_group_members WHERE group_id=?",
        (row["id"],),
    ).fetchone()["n"]
    role = _group_role(c, row["id"], user_id) if user_id else None
    return {
        "room_type": "group",
        "id": row["id"],
        "username": row["username"] if "username" in row.keys() else None,
        "title": row["title"],
        "about": row["about"],
        "avatar_url": row["avatar_url"] if "avatar_url" in row.keys() else None,
        "banner": _decode_banner_config(
            row["banner_config"] if "banner_config" in row.keys() else None,
            default_if_missing=False,
        ),
        "owner_id": row["owner_id"],
        "visibility": row["visibility"],
        "history_mode": row["history_mode"],
        "rules": row["rules"] if "rules" in row.keys() else "",
        "board_text": row["board_text"] if "board_text" in row.keys() else "",
        "preview_fields": _decode_preview_fields(
            row["preview_fields"] if "preview_fields" in row.keys() else None
        ),
        "show_pinned_preview": bool(
            row["show_pinned_preview"]
            if "show_pinned_preview" in row.keys()
            else 0
        ),
        "join_mode": _room_join_mode(row),
        "has_join_password": bool(
            row["join_password_hash"] if "join_password_hash" in row.keys() else ""
        ),
        "encryption_mode": row["encryption_mode"],
        "key_epoch": row["key_epoch"],
        "members_count": count,
        "role": role,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _room_membership(c, room_type: str, room_id: int, user_id: int):
    if room_type == "channel":
        row = c.execute(
            """
            SELECT c.id, c.visibility, c.history_mode, c.encryption_mode,
                   m.role, m.joined_at
            FROM gc_channels c JOIN gc_channel_members m ON m.channel_id=c.id
            WHERE c.id=? AND c.status='active' AND m.user_id=?
            """,
            (room_id, user_id),
        ).fetchone()
    elif room_type == "group":
        row = c.execute(
            """
            SELECT g.id, g.visibility, g.history_mode, g.encryption_mode,
                   m.role, m.joined_at
            FROM gc_groups g JOIN gc_group_members m ON m.group_id=g.id
            WHERE g.id=? AND g.status='active' AND m.user_id=?
            """,
            (room_id, user_id),
        ).fetchone()
    else:
        raise HTTPException(422, "Неизвестный тип комнаты")
    if not row:
        raise HTTPException(404, "Комната не найдена")
    return row


def _normalize_room_file_ids(raw_ids: list[str]) -> list[str]:
    ids = []
    for raw in raw_ids:
        file_id = str(raw).strip()
        if not re.fullmatch(r"[0-9a-f]{32}", file_id):
            raise HTTPException(422, "Некорректный идентификатор вложения")
        if file_id not in ids:
            ids.append(file_id)
    return ids


def _validate_room_file_refs(c, room_type: str, room_id: int, raw_ids: list[str]) -> list[str]:
    file_ids = _normalize_room_file_ids(raw_ids)
    now = int(time.time())
    for file_id in file_ids:
        row = c.execute(
            "SELECT expires_at FROM gc_room_files "
            "WHERE file_id=? AND room_type=? AND room_id=?",
            (file_id, room_type, room_id),
        ).fetchone()
        if not row or (row["expires_at"] is not None and int(row["expires_at"]) <= now):
            raise HTTPException(410, "Вложение удалено или срок хранения истёк")
    return file_ids


def _room_pinned_file_ids(c, room_type: str, room_id: int) -> set[str]:
    rows = c.execute(
        """
        SELECT m.attachment_file_ids
        FROM gc_room_pins p
        JOIN gc_room_messages m
          ON m.id=p.message_id AND m.room_type=p.room_type AND m.room_id=p.room_id
        WHERE p.room_type=? AND p.room_id=?
        """,
        (room_type, room_id),
    ).fetchall()
    result: set[str] = set()
    for row in rows:
        try:
            raw_ids = json.loads(row["attachment_file_ids"] or "[]")
        except (TypeError, ValueError):
            continue
        if isinstance(raw_ids, list):
            result.update(str(value) for value in raw_ids if isinstance(value, str))
    return result


def _sync_room_file_expiry(c, room_type: str, room_id: int) -> None:
    pinned_ids = _room_pinned_file_ids(c, room_type, room_id)
    rows = c.execute(
        "SELECT file_id, created_at, expires_at FROM gc_room_files "
        "WHERE room_type=? AND room_id=?",
        (room_type, room_id),
    ).fetchall()
    for row in rows:
        file_id = row["file_id"]
        if file_id in pinned_ids:
            c.execute(
                "UPDATE gc_room_files SET expires_at=NULL WHERE file_id=?",
                (file_id,),
            )
        elif row["expires_at"] is None:
            c.execute(
                "UPDATE gc_room_files SET expires_at=? WHERE file_id=?",
                (int(row["created_at"]) + ROOM_FILE_TTL_SECONDS, file_id),
            )


def _cleanup_expired_room_files(c, now: Optional[int] = None) -> None:
    timestamp = now or int(time.time())
    rows = c.execute(
        "SELECT file_id, file_path FROM gc_room_files "
        "WHERE expires_at IS NOT NULL AND expires_at<=?",
        (timestamp,),
    ).fetchall()
    for row in rows:
        try:
            os.remove(row["file_path"])
        except OSError:
            pass
        c.execute("DELETE FROM gc_room_files WHERE file_id=?", (row["file_id"],))


def _room_device_rows(c, room_type: str, room_id: int):
    if room_type == "channel":
        return c.execute(
            """
            SELECT DISTINCT m.user_id, u.username, d.id AS device_id,
                   d.v2_device_pub
            FROM gc_channel_members m
            JOIN users u ON u.id=m.user_id
            JOIN user_devices d ON d.user_id=m.user_id
            WHERE m.channel_id=? AND d.is_active=1 AND d.is_blocked=0
              AND d.v2_device_pub IS NOT NULL
            """,
            (room_id,),
        ).fetchall()
    return c.execute(
        """
        SELECT DISTINCT m.user_id, u.username, d.id AS device_id,
               d.v2_device_pub
        FROM gc_group_members m
        JOIN users u ON u.id=m.user_id
        JOIN user_devices d ON d.user_id=m.user_id
        WHERE m.group_id=? AND d.is_active=1 AND d.is_blocked=0
          AND d.v2_device_pub IS NOT NULL
        """,
        (room_id,),
    ).fetchall()


def _room_member_rows(c, room_type: str, room_id: int):
    table = "gc_channel_members" if room_type == "channel" else "gc_group_members"
    column = "channel_id" if room_type == "channel" else "group_id"
    return c.execute(
        f"SELECT user_id FROM {table} WHERE {column}=?",
        (room_id,),
    ).fetchall()


def _public_preview_messages(c, room_type: str, room_id: int, limit: int = 30) -> list[dict]:
    rows = c.execute(
        """
        SELECT m.id, m.payload, m.created_at,
               u.username AS sender_username,
               u.display_name AS sender_display_name,
               u.avatar_url AS sender_avatar_url
        FROM gc_room_messages m
        JOIN users u ON u.id=m.sender_id
        WHERE m.room_type=? AND m.room_id=? AND m.is_encrypted=0
        ORDER BY m.id DESC LIMIT ?
        """,
        (room_type, room_id, max(1, min(int(limit or 30), 50))),
    ).fetchall()
    return [
        {
            "id": row["id"],
            "payload": row["payload"],
            "created_at": row["created_at"],
            "sender_username": row["sender_username"],
            "sender_display_name": row["sender_display_name"],
            "sender_avatar_url": row["sender_avatar_url"],
        }
        for row in reversed(rows)
    ]


def _room_pinned_messages(
    c,
    room_type: str,
    room_id: int,
    *,
    allow_private_preview: bool = False,
    preview_only: bool = False,
    room_is_public: bool = False,
) -> list[dict]:
    rows = c.execute(
        """
        SELECT p.message_id, p.pinned_at, p.notify, p.preview_text,
               m.payload, m.is_encrypted, m.created_at,
               u.username AS sender_username,
               u.display_name AS sender_display_name,
               u.avatar_url AS sender_avatar_url
        FROM gc_room_pins p
        LEFT JOIN gc_room_messages m
          ON m.id=p.message_id AND m.room_type=p.room_type AND m.room_id=p.room_id
        LEFT JOIN users u ON u.id=m.sender_id
        WHERE p.room_type=? AND p.room_id=?
        ORDER BY p.pinned_at DESC, p.message_id DESC
        LIMIT 100
        """,
        (room_type, room_id),
    ).fetchall()
    result = []
    for row in rows:
        payload = row["payload"]
        if row["is_encrypted"]:
            if allow_private_preview and row["preview_text"]:
                payload = json.dumps(
                    {"type": "msg", "text": row["preview_text"]},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            else:
                if preview_only:
                    continue
                payload = None
        elif preview_only and not room_is_public and not allow_private_preview:
            # A group can change from public to private without rewriting old
            # plaintext messages. Treat those pins as private after conversion.
            continue
        result.append(
            {
                "message_id": row["message_id"],
                "payload": payload,
                "sender_username": row["sender_username"] or "",
                "sender_display_name": row["sender_display_name"] or "",
                "sender_avatar_url": row["sender_avatar_url"],
                "created_at": row["created_at"] or 0,
                "pinned_at": row["pinned_at"],
                "notify": bool(row["notify"]),
            }
        )
    return result


@router.get("/public/{username}")
def public_room_preview(
    username: str,
    limit: int = Query(default=30, ge=1, le=50),
    authorization: Optional[str] = Header(None),
):
    """Return a safe profile/message preview for a public channel or group."""
    normalized = username.strip().lower().lstrip("@")
    if not normalized:
        raise HTTPException(404, "Room not found")
    current_id = None
    if authorization:
        try:
            current = auth(authorization)
            if not current.get("is_guest"):
                current_id = current["id"]
        except HTTPException:
            current_id = None
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_channels WHERE lower(username)=? AND status='active' AND visibility='public'",
            (normalized,),
        ).fetchone()
        room_type = "channel"
        if not row:
            row = c.execute(
                "SELECT * FROM gc_groups WHERE lower(username)=? AND status='active' AND visibility='public'",
                (normalized,),
            ).fetchone()
            room_type = "group"
        # Keep legacy public group links such as /g/1 valid while new links
        # use the globally unique group username.
        if not row and normalized.isdigit():
            row = c.execute(
                "SELECT * FROM gc_groups WHERE id=? AND status='active' AND visibility='public'",
                (int(normalized),),
            ).fetchone()
            room_type = "group"
        if not row:
            raise HTTPException(404, "Public room not found")
        role = _room_role(c, room_type, row["id"], current_id) if current_id else None
        return {
            "room": _preview_room_payload(c, room_type, row, current_id),
            "is_member": role is not None,
            "messages": _public_preview_messages(c, room_type, row["id"], limit),
            "pinned_messages": _room_pinned_messages(
                c,
                room_type,
                row["id"],
                allow_private_preview=bool(
                    row["show_pinned_preview"]
                    if "show_pinned_preview" in row.keys()
                    else 0
                ),
                preview_only=True,
                room_is_public=True,
            ),
        }
    finally:
        c.close()


def _last_room_message(c, room_type: str, room_id: int, user_id: int,
                       joined_at: int, history_mode: str) -> Optional[dict]:
    history_clause = "" if history_mode == "all" else " AND m.created_at>=?"
    params = [room_type, room_id]
    if history_clause:
        params.append(int(joined_at or 0))
    row = c.execute(
        """
        SELECT m.id, m.sender_id, m.created_at, u.username AS sender_username
        FROM gc_room_messages m JOIN users u ON u.id=m.sender_id
        WHERE m.room_type=? AND m.room_id=?
        """ + history_clause + " ORDER BY m.id DESC LIMIT 1",
        params,
    ).fetchone()
    if not row:
        return None
    from_me = int(row["sender_id"]) == int(user_id)
    delivered_count = 0
    read_count = 0
    if from_me:
        counts = c.execute(
            """
            SELECT COUNT(DISTINCT CASE WHEN delivered_at IS NOT NULL THEN user_id END) AS delivered,
                   COUNT(DISTINCT CASE WHEN read_at IS NOT NULL THEN user_id END) AS read
            FROM gc_room_message_receipts WHERE message_id=?
            """,
            (row["id"],),
        ).fetchone()
        delivered_count = int(counts["delivered"] or 0)
        read_count = int(counts["read"] or 0)
    return {
        "id": row["id"],
        "sender_username": row["sender_username"],
        "created_at": row["created_at"],
        "from_me": from_me,
        "delivered_count": delivered_count,
        "read_count": read_count,
    }


@router.get("/my")
def list_my_rooms(authorization: Optional[str] = Header(None)):
    """Return the new channel and group entities visible to this account."""
    user = auth_member(authorization)
    c = db()
    try:
        channels = c.execute(
            """
            SELECT c.*, m.role, m.joined_at AS member_joined_at FROM gc_channels c
            JOIN gc_channel_members m ON m.channel_id=c.id
            WHERE m.user_id=? AND c.status='active'
            ORDER BY c.id DESC
            """,
            (user["id"],),
        ).fetchall()
        groups = c.execute(
            """
            SELECT g.*, m.role, m.joined_at AS member_joined_at FROM gc_groups g
            JOIN gc_group_members m ON m.group_id=g.id
            WHERE m.user_id=? AND g.status='active'
            ORDER BY g.id DESC
            """,
            (user["id"],),
        ).fetchall()
        out = []
        for row in channels:
            item = _room_payload(c, "channel", row, user["id"])
            item["last_message"] = _last_room_message(
                c,
                "channel",
                row["id"],
                user["id"],
                row["member_joined_at"],
                row["history_mode"],
            )
            out.append(item)
        for row in groups:
            item = _format_group(c, row, user["id"])
            item["last_message"] = _last_room_message(
                c,
                "group",
                row["id"],
                user["id"],
                row["member_joined_at"],
                row["history_mode"],
            )
            out.append(item)
        out.sort(key=lambda item: (item["updated_at"] or item["created_at"] or 0), reverse=True)
        return {"rooms": out}
    finally:
        c.close()


@router.get("/search")
def search_rooms(
    q: str = Query(..., min_length=1, max_length=512),
    room_type: Optional[str] = Query(default=None, max_length=16),
    authorization: Optional[str] = Header(None),
):
    """Discover rooms by text or resolve one exact room from a GhostChat link."""
    user_id = None
    if authorization:
        try:
            current = auth_member(authorization)
            user_id = current["id"]
        except HTTPException:
            user_id = None
    normalized = q.strip().lower().lstrip("@")
    if not normalized:
        raise HTTPException(422, "Поисковый запрос пуст")
    if room_type not in {None, "channel", "group"}:
        raise HTTPException(422, "Неизвестный тип комнаты")
    c = db()
    try:
        link_rooms = _resolve_room_link_search(c, q, user_id, room_type)
        if link_rooms is not None:
            return {"rooms": link_rooms}

        like = f"%{normalized}%"
        rows = []
        if room_type in {None, "channel"}:
            rows.extend(
                ("channel", row)
                for row in c.execute(
                    """
                    SELECT * FROM gc_channels
                    WHERE status='active' AND (
                        (visibility='public' AND (lower(username) LIKE ? OR lower(title) LIKE ?))
                        OR (visibility='private' AND lower(username)=?)
                    ) ORDER BY visibility='public' DESC, updated_at DESC LIMIT 50
                    """,
                    (like, like, normalized),
                ).fetchall()
            )
        if room_type in {None, "group"}:
            rows.extend(
                ("group", row)
                for row in c.execute(
                    """
                    SELECT * FROM gc_groups
                    WHERE status='active' AND (
                        (visibility='public' AND (lower(username) LIKE ? OR lower(title) LIKE ?))
                        OR (visibility='private' AND lower(username)=?)
                    ) ORDER BY visibility='public' DESC, updated_at DESC LIMIT 50
                    """,
                    (like, like, normalized),
                ).fetchall()
            )
        result = []
        for kind, row in rows:
            payload = _preview_room_payload(c, kind, row, user_id)
            payload["is_member"] = _room_role(c, kind, row["id"], user_id) is not None if user_id else False
            result.append(payload)
        return {"rooms": result[:50]}
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/request-join")
def request_room_join(
    room_type: str,
    room_id: int,
    body: Optional[RoomJoinBody] = None,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    _rate_limit(f"room-join-request:{user['id']}", limit=60, window=3600)
    c = db()
    try:
        row = _room_row(c, room_type, room_id)
        role = _room_role(c, room_type, room_id, user["id"])
        if role is not None:
            return {"status": "already_member", **_room_payload(c, room_type, row, user["id"])}
        join_mode = _room_join_mode(row)
        if join_mode == "request":
            _room_join_request(c, room_type, room_id, user["id"])
            c.commit()
            return {"status": "requested", "room_type": room_type, "room_id": room_id}
        if join_mode == "password":
            _rate_limit(
                f"room-password:{user['id']}:{room_type}:{room_id}",
                limit=10,
                window=3600,
            )
            stored_hash = row["join_password_hash"] if "join_password_hash" in row.keys() else ""
            if not _room_password_matches(stored_hash, body.password if body else None):
                raise HTTPException(403, "Неверный пароль комнаты")
        if row["visibility"] == "public" or join_mode in {"open", "password"}:
            table = "gc_channel_members" if room_type == "channel" else "gc_group_members"
            column = "channel_id" if room_type == "channel" else "group_id"
            c.execute(
                f"INSERT OR IGNORE INTO {table}({column}, user_id, role) VALUES (?, ?, 'member')",
                (room_id, user["id"]),
            )
            c.commit()
            return {"status": "joined", **_room_payload(c, room_type, row, user["id"])}
        raise HTTPException(422, "Неизвестный режим доступа")
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/transfer-owner")
def transfer_room_owner(
    room_type: str,
    room_id: int,
    body: RoomOwnerTransferBody,
    authorization: Optional[str] = Header(None),
):
    """Transfer ownership to an existing member after a password proof."""
    user = auth_member(authorization)
    if room_type not in {"channel", "group"}:
        raise HTTPException(422, "Неизвестный тип комнаты")
    target_username = _val_username(body.username)
    context = f"room-owner-transfer:{room_type}:{room_id}:{target_username}"
    if len(context) > 128:
        raise HTTPException(422, "Некорректный запрос передачи комнаты")

    c = db()
    try:
        room = _room_row(c, room_type, room_id)
        if (
            _room_role(c, room_type, room_id, user["id"]) != "owner"
            or int(room["owner_id"]) != int(user["id"])
        ):
            raise HTTPException(403, "Только владелец может передать комнату")
        target = c.execute(
            "SELECT id FROM users WHERE lower(username)=?",
            (target_username,),
        ).fetchone()
        if not target:
            raise HTTPException(404, "Пользователь не найден")
        if int(target["id"]) == int(user["id"]):
            raise HTTPException(422, "Нельзя передать комнату самому себе")
        if _room_role(c, room_type, room_id, target["id"]) is None:
            raise HTTPException(409, "Новый владелец должен быть участником комнаты")

        _, verifier, _, server_proof = _consume_password_challenge(
            c,
            body.challenge_id,
            body.proof,
            "verify_password",
            user_id=user["id"],
            context=context,
            error_status=422,
        )

        c.execute("BEGIN IMMEDIATE")
        credentials = c.execute(
            "SELECT auth_v1_salt, auth_v1_kdf FROM users WHERE id=?",
            (user["id"],),
        ).fetchone()
        if credentials and not (
            credentials["auth_v1_salt"] and credentials["auth_v1_kdf"]
        ):
            _persist_password_verifier(c, user["id"], verifier)
        room = _room_row(c, room_type, room_id)
        if (
            _room_role(c, room_type, room_id, user["id"]) != "owner"
            or int(room["owner_id"]) != int(user["id"])
        ):
            raise HTTPException(409, "Владелец комнаты уже изменился")
        if _room_role(c, room_type, room_id, target["id"]) is None:
            raise HTTPException(409, "Новый владелец больше не состоит в комнате")

        room_table, members_table, member_column = _room_table(room_type)
        c.execute(
            f"UPDATE {members_table} SET role='admin' "
            f"WHERE {member_column}=? AND user_id=?",
            (room_id, user["id"]),
        )
        c.execute(
            f"UPDATE {members_table} SET role='owner' "
            f"WHERE {member_column}=? AND user_id=?",
            (room_id, target["id"]),
        )
        c.execute(
            f"UPDATE {room_table} SET owner_id=?, updated_at=? WHERE id=?",
            (target["id"], int(time.time()), room_id),
        )
        c.commit()
        fresh = c.execute(
            f"SELECT * FROM {room_table} WHERE id=?", (room_id,)
        ).fetchone()
        return {
            "status": "transferred",
            **_room_payload(c, room_type, fresh, user["id"]),
            "server_proof": server_proof,
        }
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/leave")
def leave_room(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    """Leave a room; owners must transfer ownership or delete it."""
    user = auth_member(authorization)
    c = db()
    try:
        _room_row(c, room_type, room_id)
        role = _room_role(c, room_type, room_id, user["id"])
        if role is None:
            raise HTTPException(404, "Вы не состоите в этой комнате")
        if role == "owner":
            raise HTTPException(
                409,
                "Владелец должен передать владение или удалить комнату",
            )
        _, members_table, member_column = _room_table(room_type)
        c.execute(
            f"DELETE FROM {members_table} WHERE {member_column}=? AND user_id=?",
            (room_id, user["id"]),
        )
        c.execute(
            "DELETE FROM gc_room_join_requests "
            "WHERE room_type=? AND room_id=? AND user_id=?",
            (room_type, room_id, user["id"]),
        )
        c.commit()
        return {"status": "left", "room_type": room_type, "room_id": room_id}
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()


@router.delete("/{room_type}/{room_id}")
def delete_room(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    """Permanently delete a room and its messages, invitations, and files."""
    user = auth_member(authorization)
    room_files: list[str] = []
    avatar_url = None
    c = db()
    try:
        room_table, members_table, member_column = _room_table(room_type)
        c.execute("BEGIN IMMEDIATE")
        room = _room_row(c, room_type, room_id)
        if (
            _room_role(c, room_type, room_id, user["id"]) != "owner"
            or int(room["owner_id"]) != int(user["id"])
        ):
            raise HTTPException(403, "Только владелец может удалить комнату")
        avatar_url = room["avatar_url"] if "avatar_url" in room.keys() else None
        room_files = [
            str(row["file_path"])
            for row in c.execute(
                "SELECT file_path FROM gc_room_files "
                "WHERE room_type=? AND room_id=?",
                (room_type, room_id),
            ).fetchall()
        ]

        c.execute(
            "DELETE FROM gc_room_message_receipts WHERE message_id IN "
            "(SELECT id FROM gc_room_messages WHERE room_type=? AND room_id=?)",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_envelopes WHERE message_id IN "
            "(SELECT id FROM gc_room_messages WHERE room_type=? AND room_id=?)",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_invite_recipients WHERE link_id IN "
            "(SELECT id FROM gc_room_invite_links WHERE room_type=? AND room_id=?)",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_invite_links WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_join_requests WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        if c.execute(
            "SELECT 1 FROM sqlite_master "
            "WHERE type='table' AND name='gc_client_idempotency'"
        ).fetchone():
            c.execute(
                "DELETE FROM gc_client_idempotency WHERE scope=?",
                (f"room:{room_type}:{room_id}",),
            )
        c.execute(
            "DELETE FROM gc_room_pins WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_files WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        c.execute(
            "DELETE FROM gc_room_messages WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        c.execute(
            f"DELETE FROM {members_table} WHERE {member_column}=?",
            (room_id,),
        )
        if room_type == "channel":
            c.execute(
                "DELETE FROM gc_public_handles "
                "WHERE owner_type='channel' AND owner_id=?",
                (room_id,),
            )
        c.execute(f"DELETE FROM {room_table} WHERE id=?", (room_id,))
        c.commit()
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()

    def _remove_owned_file(path: str, root: str) -> None:
        try:
            resolved_root = os.path.realpath(root)
            resolved_path = os.path.realpath(path)
            if (
                resolved_path != resolved_root
                and os.path.commonpath((resolved_root, resolved_path)) == resolved_root
            ):
                os.remove(resolved_path)
        except (OSError, ValueError):
            pass

    for path in room_files:
        _remove_owned_file(path, _ROOM_FILE_DIR)
    if avatar_url and avatar_url.startswith("/media/room_avatars/"):
        _remove_owned_file(
            os.path.join(_ROOM_AVATAR_DIR, os.path.basename(avatar_url)),
            _ROOM_AVATAR_DIR,
        )
    return {"status": "deleted", "room_type": room_type, "room_id": room_id}


@router.post("/{room_type}/{room_id}/convert")
def convert_room(
    room_type: str,
    room_id: int,
    body: RoomConvertBody,
    authorization: Optional[str] = Header(None),
):
    """Move a room between the channel and group tables as one transaction."""
    user = auth_member(authorization)
    target_type = body.room_type.strip().lower()
    if room_type not in {"channel", "group"} or target_type not in {"channel", "group"}:
        raise HTTPException(422, "Неизвестный тип комнаты")
    if target_type == room_type:
        raise HTTPException(422, "Комната уже имеет этот тип")

    c = db()
    try:
        source_table, source_members, source_column = _room_table(room_type)
        target_table, target_members, target_column = _room_table(target_type)
        source = _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) != "owner":
            raise HTTPException(403, "Только владелец может менять тип комнаты")

        username = (source["username"] or "").strip().lower()
        if not username:
            raise HTTPException(422, "Для смены типа нужен username")

        # The two tables have independent UNIQUE constraints, while users,
        # channels and the public handle registry share one visible namespace.
        # Exclude only the source row/handle; every other owner remains a hard
        # conflict.
        conflict = c.execute(
            "SELECT 1 FROM users WHERE lower(username)=? LIMIT 1", (username,)
        ).fetchone()
        if conflict:
            raise HTTPException(409, "Username уже занят")
        conflict = c.execute(
            f"SELECT 1 FROM {target_table} WHERE lower(username)=? LIMIT 1",
            (username,),
        ).fetchone()
        if conflict:
            raise HTTPException(409, "Username уже занят")
        if target_type == "channel":
            conflict = c.execute(
                "SELECT 1 FROM gc_groups WHERE lower(username)=? AND id<>? LIMIT 1",
                (username, room_id if room_type == "group" else -1),
            ).fetchone()
        else:
            conflict = c.execute(
                "SELECT 1 FROM gc_channels WHERE lower(username)=? AND id<>? LIMIT 1",
                (username, room_id if room_type == "channel" else -1),
            ).fetchone()
        if conflict:
            raise HTTPException(409, "Username уже занят")
        handle = c.execute(
            "SELECT owner_type, owner_id FROM gc_public_handles WHERE handle=?",
            (username,),
        ).fetchone()
        if handle and not (
            room_type == "channel"
            and handle["owner_type"] == "channel"
            and int(handle["owner_id"]) == room_id
        ):
            raise HTTPException(409, "Username уже занят")

        now = int(time.time())
        common = (
            username,
            source["title"],
            source["about"],
            source["avatar_url"] if "avatar_url" in source.keys() else None,
            source["banner_config"] if "banner_config" in source.keys() else None,
            source["owner_id"],
            source["visibility"],
            source["history_mode"],
            source["rules"],
            source["board_text"],
            source["preview_fields"],
            int(source["show_pinned_preview"] if "show_pinned_preview" in source.keys() else 0),
            _room_join_mode(source),
            source["join_password_hash"],
            source["encryption_mode"],
            source["key_epoch"],
            now,
        )
        c.execute(
            f"""
            INSERT INTO {target_table}
                (username, title, about, avatar_url, banner_config, owner_id,
                 visibility, history_mode, rules, board_text, preview_fields,
                 show_pinned_preview, join_mode, join_password_hash,
                 encryption_mode, key_epoch, status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
            """,
            common,
        )
        target_id = int(c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"])

        if target_type == "channel":
            from channel_router_v2 import _claim_public_handle

            _claim_public_handle(c, username, "channel", target_id)

        members = c.execute(
            f"SELECT user_id, role, joined_at FROM {source_members} WHERE {source_column}=?",
            (room_id,),
        ).fetchall()
        for member in members:
            c.execute(
                f"INSERT INTO {target_members}({target_column}, user_id, role, joined_at) VALUES (?, ?, ?, ?)",
                (target_id, member["user_id"], member["role"], member["joined_at"]),
            )

        c.execute(
            "UPDATE gc_room_messages SET room_type=?, room_id=? WHERE room_type=? AND room_id=?",
            (target_type, target_id, room_type, room_id),
        )
        c.execute(
            "UPDATE gc_room_join_requests SET room_type=?, room_id=? WHERE room_type=? AND room_id=?",
            (target_type, target_id, room_type, room_id),
        )
        c.execute(
            "UPDATE gc_room_invite_links SET room_type=?, room_id=? WHERE room_type=? AND room_id=?",
            (target_type, target_id, room_type, room_id),
        )
        c.execute(
            "UPDATE gc_room_pins SET room_type=?, room_id=? WHERE room_type=? AND room_id=?",
            (target_type, target_id, room_type, room_id),
        )
        if room_type == "channel":
            # The old channel cannot keep the same handle after the new group
            # takes it. It is archived, so its replacement name is never shown.
            archived_name = f"archived_channel_{room_id}"
            c.execute(
                "UPDATE gc_channels SET username=?, status='archived', updated_at=? WHERE id=?",
                (archived_name, now, room_id),
            )
            c.execute(
                "DELETE FROM gc_public_handles WHERE owner_type='channel' AND owner_id=?",
                (room_id,),
            )
        else:
            c.execute(
                "UPDATE gc_groups SET username=NULL, status='archived', updated_at=? WHERE id=?",
                (now, room_id),
            )
        c.commit()
        fresh = c.execute(
            f"SELECT * FROM {target_table} WHERE id=?", (target_id,)
        ).fetchone()
        return _room_payload(c, target_type, fresh, user["id"])
    except HTTPException:
        c.rollback()
        raise
    except sqlite3.IntegrityError as error:
        c.rollback()
        raise HTTPException(409, f"Не удалось изменить тип комнаты: {error}")
    finally:
        c.close()


@router.get("/{room_type}/{room_id}/join-requests")
def list_room_join_requests(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        rows = c.execute(
            """
            SELECT r.id, r.user_id, r.status, r.requested_at,
                   u.username, u.display_name, u.avatar_url
            FROM gc_room_join_requests r JOIN users u ON u.id=r.user_id
            WHERE r.room_type=? AND r.room_id=? AND r.status='pending'
            ORDER BY r.requested_at ASC
            """,
            (room_type, room_id),
        ).fetchall()
        return {
            "requests": [
                {
                    "id": row["id"],
                    "user_id": row["user_id"],
                    "username": row["username"],
                    "display_name": row["display_name"],
                    "avatar_url": row["avatar_url"],
                    "requested_at": row["requested_at"],
                }
                for row in rows
            ]
        }
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/join-requests/{request_id}")
def review_room_join_request(
    room_type: str,
    room_id: int,
    request_id: int,
    body: RoomJoinDecisionBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    action = body.action.strip().lower()
    if action not in {"accept", "reject"}:
        raise HTTPException(422, "action должен быть accept или reject")
    c = db()
    try:
        _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        request = c.execute(
            "SELECT * FROM gc_room_join_requests WHERE id=? AND room_type=? AND room_id=? AND status='pending'",
            (request_id, room_type, room_id),
        ).fetchone()
        if not request:
            raise HTTPException(404, "Заявка не найдена")
        now = int(time.time())
        if action == "accept":
            table = "gc_channel_members" if room_type == "channel" else "gc_group_members"
            column = "channel_id" if room_type == "channel" else "group_id"
            c.execute(
                f"INSERT OR IGNORE INTO {table}({column}, user_id, role) VALUES (?, ?, 'member')",
                (room_id, request["user_id"]),
            )
        c.execute(
            "UPDATE gc_room_join_requests SET status=?, reviewed_by=?, reviewed_at=? WHERE id=?",
            ("accepted" if action == "accept" else "rejected", user["id"], now, request_id),
        )
        c.commit()
        return {"status": "accepted" if action == "accept" else "rejected", "request_id": request_id}
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/invite-links")
def create_room_invite_link(
    room_type: str,
    room_id: int,
    body: RoomInviteLinkBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        row = _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        username = row["username"] if "username" in row.keys() else None
        if row["visibility"] == "public":
            if not username:
                raise HTTPException(409, "У публичной комнаты нет username")
            prefix = "c" if room_type == "channel" else "g"
            return {
                "status": "ok",
                "permanent": True,
                "link": f"/{prefix}/{username}",
                "username": username,
            }

        # A private room has one active ordinary link. Creating a new one
        # revokes the previous bearer link, as requested by the product rules.
        c.execute(
            "UPDATE gc_room_invite_links SET active=0 WHERE room_type=? AND room_id=? AND active=1",
            (room_type, room_id),
        )
        targeted = [name.strip().lower().lstrip("@") for name in body.usernames if name.strip()]
        target_ids = []
        for name in dict.fromkeys(targeted):
            target = c.execute("SELECT id FROM users WHERE username=?", (name,)).fetchone()
            if not target:
                raise HTTPException(404, f"Пользователь @{name} не найден")
            target_ids.append(int(target["id"]))
        token = secrets.token_urlsafe(32)
        now = int(time.time())
        expires_at = now + 3 * 24 * 3600 if target_ids else (
            now + body.expires_hours * 3600 if body.expires_hours else None
        )
        max_uses = None if target_ids else body.max_uses
        c.execute(
            """
            INSERT INTO gc_room_invite_links
                (room_type, room_id, token, token_hash, expires_at, max_uses,
                 request_join, active, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
            """,
            (
                room_type, room_id, token, hashlib.sha256(token.encode()).hexdigest(),
                expires_at, max_uses, 1 if body.request_join else 0, user["id"],
            ),
        )
        link_id = c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
        for target_id in target_ids:
            c.execute(
                "INSERT INTO gc_room_invite_recipients(link_id, user_id) VALUES (?, ?)",
                (link_id, target_id),
            )
        c.commit()
        return {
            "status": "ok",
            "permanent": False,
            "token": token,
            "link": f"/invite/{token}",
            "expires_at": expires_at,
            "max_uses": max_uses,
            "request_join": body.request_join,
            "usernames": targeted,
        }
    finally:
        c.close()


@router.get("/{room_type}/{room_id}/invite-links")
def list_room_invite_links(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        row = _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        username = row["username"] if "username" in row.keys() else None
        if row["visibility"] == "public":
            prefix = "c" if room_type == "channel" else "g"
            return {"links": [{"permanent": True, "link": f"/{prefix}/{username}"}]}
        links = c.execute(
            "SELECT id, token, expires_at, max_uses, uses, request_join, active, created_at "
            "FROM gc_room_invite_links WHERE room_type=? AND room_id=? ORDER BY created_at DESC",
            (room_type, room_id),
        ).fetchall()
        return {
            "links": [dict(link) for link in links],
        }
    finally:
        c.close()


@router.delete("/{room_type}/{room_id}/invite-links")
def revoke_room_invite_links(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        _room_row(c, room_type, room_id)
        if _room_role(c, room_type, room_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        c.execute(
            "UPDATE gc_room_invite_links SET active=0 WHERE room_type=? AND room_id=?",
            (room_type, room_id),
        )
        c.commit()
        return {"status": "revoked"}
    finally:
        c.close()


class RedeemRoomInviteBody(BaseModel):
    token: str = Field(min_length=16, max_length=256)
    password: Optional[str] = Field(default=None, max_length=128)


@router.get("/invite-links/preview/{token}")
def preview_room_invite(
    token: str,
    authorization: Optional[str] = Header(None),
):
    """Preview an invite without joining it or exposing private messages."""
    user = None
    if authorization:
        try:
            candidate = auth(authorization)
            if not candidate.get("is_guest"):
                user = candidate
        except HTTPException:
            # A bearer invite is still previewable before login. Joining or a
            # targeted invite continues to require an authenticated account.
            user = None
    token = token.strip()
    c = db()
    try:
        link = c.execute(
            "SELECT * FROM gc_room_invite_links WHERE token_hash=? AND active=1",
            (hashlib.sha256(token.encode()).hexdigest(),),
        ).fetchone()
        if not link:
            raise HTTPException(404, "Invite link not found")
        now = int(time.time())
        if link["expires_at"] and int(link["expires_at"]) <= now:
            raise HTTPException(410, "Invite link expired")
        targeted = c.execute(
            "SELECT 1 FROM gc_room_invite_recipients WHERE link_id=? LIMIT 1",
            (link["id"],),
        ).fetchone()
        if targeted and (user is None or not c.execute(
            "SELECT 1 FROM gc_room_invite_recipients WHERE link_id=? AND user_id=?",
            (link["id"], user["id"]),
        ).fetchone()):
            raise HTTPException(403, "This invite is assigned to another user")
        row = _room_row(c, link["room_type"], link["room_id"])
        role = (
            _room_role(c, link["room_type"], link["room_id"], user["id"])
            if user
            else None
        )
        join_mode = _room_join_mode(row)
        return {
            "room": _preview_room_payload(
                c, link["room_type"], row, user["id"] if user else None
            ),
            "is_member": role is not None,
            "request_join": bool(link["request_join"]) or join_mode == "request",
            "pinned_messages": _room_pinned_messages(
                c,
                link["room_type"],
                row["id"],
                allow_private_preview=(
                    row["visibility"] == "public"
                    or bool(
                        row["show_pinned_preview"]
                        if "show_pinned_preview" in row.keys()
                        else 0
                    )
                ),
                preview_only=True,
                room_is_public=row["visibility"] == "public",
            ),
            "expires_at": link["expires_at"],
            "token": token,
        }
    finally:
        c.close()


@router.post("/invite-links/redeem")
def redeem_room_invite(
    body: RedeemRoomInviteBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    token = body.token.strip()
    c = db()
    try:
        link = c.execute(
            "SELECT * FROM gc_room_invite_links WHERE token_hash=? AND active=1",
            (hashlib.sha256(token.encode()).hexdigest(),),
        ).fetchone()
        if not link:
            raise HTTPException(404, "Ссылка недействительна")
        now = int(time.time())
        if link["expires_at"] and int(link["expires_at"]) <= now:
            raise HTTPException(410, "Срок действия ссылки истёк")
        recipient = c.execute(
            "SELECT * FROM gc_room_invite_recipients WHERE link_id=? AND user_id=?",
            (link["id"], user["id"]),
        ).fetchone()
        if link["id"] and c.execute(
            "SELECT 1 FROM gc_room_invite_recipients WHERE link_id=? LIMIT 1",
            (link["id"],),
        ).fetchone():
            if not recipient:
                raise HTTPException(403, "Эта ссылка предназначена другому пользователю")
            if recipient["redeemed_at"]:
                raise HTTPException(409, "Вы уже использовали эту ссылку")
        elif link["max_uses"] is not None and int(link["uses"]) >= int(link["max_uses"]):
            raise HTTPException(410, "Лимит использований ссылки исчерпан")

        row = _room_row(c, link["room_type"], link["room_id"])
        role = _room_role(c, link["room_type"], link["room_id"], user["id"])
        if role is not None:
            return {"status": "already_member", **_room_payload(c, link["room_type"], row, user["id"])}
        join_mode = _room_join_mode(row)
        if link["request_join"] or join_mode == "request":
            _room_join_request(c, link["room_type"], link["room_id"], user["id"])
            result = {"status": "requested"}
        else:
            if join_mode == "password":
                _rate_limit(
                    f"room-password:{user['id']}:{link['room_type']}:{link['room_id']}",
                    limit=10,
                    window=3600,
                )
                stored_hash = row["join_password_hash"] if "join_password_hash" in row.keys() else ""
                if not _room_password_matches(stored_hash, body.password):
                    raise HTTPException(403, "Неверный пароль комнаты")
            table = "gc_channel_members" if link["room_type"] == "channel" else "gc_group_members"
            column = "channel_id" if link["room_type"] == "channel" else "group_id"
            c.execute(
                f"INSERT OR IGNORE INTO {table}({column}, user_id, role) VALUES (?, ?, 'member')",
                (link["room_id"], user["id"]),
            )
            result = {"status": "joined"}
        if recipient:
            c.execute(
                "UPDATE gc_room_invite_recipients SET redeemed_at=? WHERE link_id=? AND user_id=?",
                (now, link["id"], user["id"]),
            )
        else:
            c.execute("UPDATE gc_room_invite_links SET uses=uses+1 WHERE id=?", (link["id"],))
        c.commit()
        return {**result, **_room_payload(c, link["room_type"], row, user["id"])}
    finally:
        c.close()


@router.post("/groups")
def create_group(body: GroupCreateBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"room-group:create:{user['id']}", limit=20, window=3600)
    title = _val_name(body.title)
    _validate_options(body.visibility, body.history_mode)
    c = db()
    try:
        # Serialize the count-and-create transaction so parallel requests
        # cannot race past the per-owner quota.
        c.execute("BEGIN IMMEDIATE")
        owned_count = c.execute(
            "SELECT COUNT(*) FROM gc_groups WHERE owner_id=?",
            (user["id"],),
        ).fetchone()[0]
        if owned_count >= MAX_GROUPS_PER_USER:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "group_limit_reached",
                    "limit": MAX_GROUPS_PER_USER,
                    "message": "Можно создать не более 15 групп",
                },
            )
        username = (
            _claim_group_username(c, body.username)
            if body.username is not None
            else None
        )
        encryption_mode = "none" if body.visibility == "public" else "e2ee_v2"
        c.execute(
            """
            INSERT INTO gc_groups
                (username, title, about, owner_id, visibility, history_mode,
                 encryption_mode, key_epoch, status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'active', ?)
            """,
            (
                username,
                title,
                body.about.strip(),
                user["id"],
                body.visibility,
                body.history_mode,
                encryption_mode,
                int(time.time()),
            ),
        )
        group_id = c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
        if username is None:
            username = _new_group_username(c, group_id)
            c.execute(
                "UPDATE gc_groups SET username=? WHERE id=?",
                (username, group_id),
            )
        c.execute(
            "INSERT INTO gc_group_members(group_id, user_id, role) VALUES (?, ?, 'owner')",
            (group_id, user["id"]),
        )
        c.commit()
        row = c.execute("SELECT * FROM gc_groups WHERE id=?", (group_id,)).fetchone()
        return _format_group(c, row, user["id"])
    except HTTPException:
        c.rollback()
        raise
    except sqlite3.IntegrityError:
        c.rollback()
        raise HTTPException(409, "Не удалось создать группу")
    finally:
        c.close()


@router.get("/groups/{group_id}")
def get_group(group_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_groups WHERE id=? AND status='active'",
            (group_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Группа не найдена")
        role = _group_role(c, group_id, user["id"])
        if role is None:
            raise HTTPException(404, "Группа не найдена")
        return _format_group(c, row, user["id"])
    finally:
        c.close()


@router.patch("/groups/{group_id}")
def update_group(
    group_id: int,
    body: GroupPatchBody,
    authorization: Optional[str] = Header(None),
):
    """Update group profile and lobby settings for owners and administrators."""
    user = auth_member(authorization)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_groups WHERE id=? AND status='active'",
            (group_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Группа не найдена")
        role = _group_role(c, group_id, user["id"])
        if role not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        if body.username is not None and role != "owner":
            raise HTTPException(403, "Username группы меняет только владелец")
        if body.show_pinned_preview is not None and role != "owner":
            raise HTTPException(403, "Настройку показа закрепов меняет только владелец")

        updates = {}
        if body.username is not None:
            updates["username"] = _claim_group_username(
                c, body.username, group_id
            )
        if body.title is not None:
            updates["title"] = _val_name(body.title)
        if body.about is not None:
            updates["about"] = body.about.strip()
        if body.banner is not None and body.banner_clear:
            raise HTTPException(422, "Нельзя одновременно сохранить и убрать баннер")
        if body.banner is not None:
            updates["banner_config"] = json.dumps(
                _normalize_banner_config(body.banner), separators=(",", ":")
            )
        elif body.banner_clear:
            updates["banner_config"] = None
        if body.visibility is not None:
            if body.visibility not in _VISIBILITIES:
                raise HTTPException(422, "visibility должна быть public или private")
            updates["visibility"] = body.visibility
            updates["encryption_mode"] = "none" if body.visibility == "public" else "e2ee_v2"
        if body.history_mode is not None:
            if body.history_mode not in _HISTORY_MODES:
                raise HTTPException(422, "history_mode должен быть new_only или all")
            updates["history_mode"] = body.history_mode
        if body.rules is not None:
            updates["rules"] = body.rules.strip()
        if body.board_text is not None:
            updates["board_text"] = body.board_text.strip()
        if body.preview_fields is not None:
            updates["preview_fields"] = json.dumps(
                _normalize_preview_fields(body.preview_fields), separators=(",", ":")
            )
        if body.show_pinned_preview is not None:
            updates["show_pinned_preview"] = int(body.show_pinned_preview)
        if body.join_mode is not None or body.join_password is not None or body.visibility is not None:
            _apply_room_access_updates(
                updates,
                row,
                join_mode=body.join_mode,
                join_password=body.join_password,
            )
        if not updates:
            raise HTTPException(422, "Нечего изменять")

        updates["updated_at"] = int(time.time())
        set_clause = ", ".join(f"{key}=?" for key in updates)
        c.execute(
            f"UPDATE gc_groups SET {set_clause} WHERE id=?",
            list(updates.values()) + [group_id],
        )
        if body.show_pinned_preview is False:
            c.execute(
                "UPDATE gc_room_pins SET preview_text='' "
                "WHERE room_type='group' AND room_id=?",
                (group_id,),
            )
        c.commit()
        fresh = c.execute("SELECT * FROM gc_groups WHERE id=?", (group_id,)).fetchone()
        return _format_group(c, fresh, user["id"])
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()


_ROOM_AVATAR_DIR = os.getenv(
    "GHOSTCHAT_ROOM_AVATARS_DIR", "/opt/ghostchat/media/room_avatars"
)
_ROOM_AVATAR_MAX_BYTES = 5 * 1024 * 1024


def _process_room_avatar(raw: bytes) -> bytes:
    if len(raw) > _ROOM_AVATAR_MAX_BYTES:
        raise HTTPException(413, "Файл больше 5 МБ")
    if len(raw) < 100:
        raise HTTPException(400, "Файл слишком маленький")
    try:
        from PIL import Image

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
        image = image.crop(
            (
                (width - side) // 2,
                (height - side) // 2,
                (width - side) // 2 + side,
                (height - side) // 2 + side,
            )
        )
        image = image.resize((512, 512), Image.LANCZOS)
        out = io.BytesIO()
        image.save(out, format="JPEG", quality=85, optimize=True)
        return out.getvalue()
    except Exception as exc:
        raise HTTPException(400, f"Не удалось обработать изображение: {exc}")


@router.post("/{room_type}/{room_id}/avatar")
async def upload_room_avatar(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
    file: UploadFile = File(...),
):
    """Replace a channel/group avatar; only the creator can do this."""
    user = auth_member(authorization)
    if room_type not in {"channel", "group"}:
        raise HTTPException(422, "Неизвестный тип комнаты")
    if file.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(400, "Только JPEG / PNG / WebP")

    c = db()
    saved_path = None
    try:
        if room_type == "channel":
            row = c.execute(
                "SELECT * FROM gc_channels WHERE id=? AND status='active'",
                (room_id,),
            ).fetchone()
            role = _channel_role(c, room_id, user["id"])
        else:
            row = c.execute(
                "SELECT * FROM gc_groups WHERE id=? AND status='active'",
                (room_id,),
            ).fetchone()
            role = _group_role(c, room_id, user["id"])
        if not row:
            raise HTTPException(404, "Комната не найдена")
        if role != "owner":
            raise HTTPException(403, "Только владелец может менять аватарку")

        out_bytes = _process_room_avatar(await file.read())
        os.makedirs(_ROOM_AVATAR_DIR, exist_ok=True)
        filename = f"{room_type}_{room_id}_{int(time.time())}_{uuid.uuid4().hex}.jpg"
        saved_path = os.path.join(_ROOM_AVATAR_DIR, filename)
        with open(saved_path, "wb") as stream:
            stream.write(out_bytes)
        url = f"/media/room_avatars/{filename}"
        table = "gc_channels" if room_type == "channel" else "gc_groups"
        c.execute(
            f"UPDATE {table} SET avatar_url=?, updated_at=? WHERE id=?",
            (url, int(time.time()), room_id),
        )
        c.commit()
        old_url = row["avatar_url"] if "avatar_url" in row.keys() else None
    except HTTPException:
        c.rollback()
        if saved_path:
            try:
                os.remove(saved_path)
            except OSError:
                pass
        raise
    except Exception:
        c.rollback()
        if saved_path:
            try:
                os.remove(saved_path)
            except OSError:
                pass
        raise
    finally:
        c.close()

    if old_url and old_url.startswith("/media/room_avatars/"):
        old_name = os.path.basename(old_url)
        try:
            os.remove(os.path.join(_ROOM_AVATAR_DIR, old_name))
        except OSError:
            pass

    c = db()
    try:
        table = "gc_channels" if room_type == "channel" else "gc_groups"
        fresh = c.execute(f"SELECT * FROM {table} WHERE id=?", (room_id,)).fetchone()
        if room_type == "channel":
            from channel_router_v2 import _channel_dict

            return _channel_dict(c, fresh, user["id"])
        return _format_group(c, fresh, user["id"])
    finally:
        c.close()


@router.post("/groups/{group_id}/join")
def join_public_group(group_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"room-group:join:{user['id']}", limit=60, window=3600)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_groups WHERE id=? AND status='active'",
            (group_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Группа не найдена")
        if row["visibility"] != "public":
            raise HTTPException(403, "Приватная группа доступна только по приглашению")
        c.execute(
            "INSERT OR IGNORE INTO gc_group_members(group_id, user_id, role) VALUES (?, ?, 'member')",
            (group_id, user["id"]),
        )
        c.commit()
        return _format_group(c, row, user["id"])
    finally:
        c.close()


@router.post("/groups/handle/{username}/join")
def join_public_group_by_username(
    username: str, authorization: Optional[str] = Header(None)
):
    user = auth_member(authorization)
    _rate_limit(f"room-group:join:{user['id']}", limit=60, window=3600)
    normalized = _val_username(username)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_groups WHERE lower(username)=? AND status='active'",
            (normalized,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Группа не найдена")
        if row["visibility"] != "public":
            raise HTTPException(
                403,
                "Приватная группа доступна только по приглашению",
            )
        c.execute(
            "INSERT OR IGNORE INTO gc_group_members(group_id, user_id, role) "
            "VALUES (?, ?, 'member')",
            (row["id"], user["id"]),
        )
        c.commit()
        return _format_group(c, row, user["id"])
    finally:
        c.close()


@router.post("/groups/{group_id}/members")
def add_group_member(
    group_id: int,
    body: GroupMemberBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        group = c.execute(
            "SELECT * FROM gc_groups WHERE id=? AND status='active'",
            (group_id,),
        ).fetchone()
        if not group:
            raise HTTPException(404, "Группа не найдена")
        if _group_role(c, group_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        target = c.execute(
            "SELECT id, username, display_name FROM users WHERE username=?",
            (body.username.strip().lower().lstrip("@"),),
        ).fetchone()
        if not target:
            raise HTTPException(404, "Пользователь не найден")
        if target["id"] == user["id"]:
            raise HTTPException(422, "Нельзя добавить себя")
        allowed, reason = _direct_add_decision(c, user["id"], target["id"], "group")
        if not allowed:
            return {
                "status": "blocked",
                "room_type": "group",
                "group_id": group_id,
                "username": target["username"],
                "display_name": target["display_name"],
                "reason": reason,
                "invite_required": True,
            }
        c.execute(
            "INSERT OR IGNORE INTO gc_group_members(group_id, user_id, role) VALUES (?, ?, 'member')",
            (group_id, target["id"]),
        )
        c.commit()
        return {
            "status": "ok",
            "group_id": group_id,
            "username": target["username"],
            "display_name": target["display_name"],
        }
    finally:
        c.close()


@router.post("/channels/{channel_id}/members")
def add_channel_member(
    channel_id: int,
    body: GroupMemberBody,
    authorization: Optional[str] = Header(None),
):
    """Invite a user to a channel.

    Private channels have no open join flow, so owner/admin invitation is the
    membership transition that makes their E2EE device fan-out usable.
    """
    user = auth_member(authorization)
    c = db()
    try:
        channel = c.execute(
            "SELECT * FROM gc_channels WHERE id=? AND status='active'",
            (channel_id,),
        ).fetchone()
        if not channel:
            raise HTTPException(404, "Канал не найден")
        if _channel_role(c, channel_id, user["id"]) not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        target = c.execute(
            "SELECT id, username, display_name FROM users WHERE username=?",
            (body.username.strip().lower().lstrip("@"),),
        ).fetchone()
        if not target:
            raise HTTPException(404, "Пользователь не найден")
        if target["id"] == user["id"]:
            raise HTTPException(422, "Нельзя добавить себя")
        allowed, reason = _direct_add_decision(c, user["id"], target["id"], "channel")
        if not allowed:
            return {
                "status": "blocked",
                "room_type": "channel",
                "channel_id": channel_id,
                "username": target["username"],
                "display_name": target["display_name"],
                "reason": reason,
                "invite_required": True,
            }
        c.execute(
            "INSERT OR IGNORE INTO gc_channel_members(channel_id, user_id, role) "
            "VALUES (?, ?, 'member')",
            (channel_id, target["id"]),
        )
        c.commit()
        return {
            "status": "ok",
            "channel_id": channel_id,
            "username": target["username"],
            "display_name": target["display_name"],
        }
    finally:
        c.close()


@router.get("/groups/{group_id}/members")
def list_group_members(group_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        if _group_role(c, group_id, user["id"]) is None:
            raise HTTPException(404, "Группа не найдена")
        rows = c.execute(
            """
            SELECT u.id, u.username, u.display_name, m.role, m.joined_at
            FROM gc_group_members m JOIN users u ON u.id=m.user_id
            WHERE m.group_id=? ORDER BY m.role='owner' DESC, m.joined_at ASC
            """,
            (group_id,),
        ).fetchall()
        return {
            "members": [
                {
                    "id": row["id"],
                    "username": row["username"],
                    "display_name": row["display_name"],
                    "role": row["role"],
                    "joined_at": row["joined_at"],
                }
                for row in rows
            ]
        }
    finally:
        c.close()


@router.get("/channels/{channel_id}/members")
def list_channel_members(channel_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        _room_membership(c, "channel", channel_id, user["id"])
        rows = c.execute(
            """
            SELECT u.id, u.username, u.display_name, m.role, m.joined_at
            FROM gc_channel_members m JOIN users u ON u.id=m.user_id
            WHERE m.channel_id=? ORDER BY m.role='owner' DESC, m.joined_at ASC
            """,
            (channel_id,),
        ).fetchall()
        return {
            "members": [
                {
                    "id": row["id"],
                    "username": row["username"],
                    "display_name": row["display_name"],
                    "role": row["role"],
                    "joined_at": row["joined_at"],
                }
                for row in rows
            ]
        }
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/files")
async def upload_room_file(
    room_type: str,
    room_id: int,
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    _rate_limit(f"room-file-upload:{user['id']}", limit=30, window=3600)
    c = db()
    file_id = uuid.uuid4().hex
    destination = os.path.join(_ROOM_FILE_DIR, file_id)
    temporary_path = None
    saved = False
    total = 0
    try:
        membership = _room_membership(c, room_type, room_id, user["id"])
        if room_type == "channel" and membership["role"] not in {"owner", "admin"}:
            raise HTTPException(403, "В канале вложения отправляют только администраторы")
        _cleanup_expired_room_files(c)
        c.commit()
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=_ROOM_FILE_DIR, prefix=".room-upload-", delete=False
        ) as output:
            temporary_path = output.name
            while True:
                chunk = await file.read(64 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > ROOM_FILE_MAX_BYTES:
                    raise HTTPException(413, "Размер вложения в комнате не должен превышать 50 МБ")
                output.write(chunk)
        if total == 0:
            raise HTTPException(400, "Пустое вложение")
        os.replace(temporary_path, destination)
        temporary_path = None
        now = int(time.time())
        c.execute(
            """
            INSERT INTO gc_room_files
                (file_id, room_type, room_id, uploader_id, file_path,
                 file_size, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                file_id,
                room_type,
                room_id,
                user["id"],
                destination,
                total,
                now,
                now + ROOM_FILE_TTL_SECONDS,
            ),
        )
        c.commit()
        saved = True
        return {"file_id": file_id, "file_size": total, "expires_at": now + ROOM_FILE_TTL_SECONDS}
    except HTTPException:
        c.rollback()
        raise
    except OSError as error:
        c.rollback()
        raise HTTPException(500, "Не удалось сохранить вложение") from error
    except Exception:
        c.rollback()
        raise
    finally:
        if not saved:
            for path in (temporary_path, destination):
                if path:
                    try:
                        os.remove(path)
                    except OSError:
                        pass
        c.close()
        await file.close()


@router.get("/{room_type}/{room_id}/files/{file_id}")
def download_room_file(
    room_type: str,
    room_id: int,
    file_id: str,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        _room_membership(c, room_type, room_id, user["id"])
        _cleanup_expired_room_files(c)
        c.commit()
        row = c.execute(
            "SELECT file_path, expires_at FROM gc_room_files "
            "WHERE file_id=? AND room_type=? AND room_id=?",
            (file_id, room_type, room_id),
        ).fetchone()
        if not row or not os.path.isfile(row["file_path"]):
            raise HTTPException(404, "Вложение удалено или срок хранения истёк")
        return FileResponse(
            row["file_path"],
            media_type="application/octet-stream",
            filename="encrypted.bin",
            headers={"Cache-Control": "no-store"},
        )
    finally:
        c.close()


def _broadcast_room_pin_event(
    c, room_type: str, room_id: int, message_id: int, *, action: str, notify: bool
) -> None:
    payload = {
        "room_type": room_type,
        "room_id": room_id,
        "message_id": message_id,
        "action": action,
        "notify": notify,
    }
    for member in _room_member_rows(c, room_type, room_id):
        try:
            ws_hub.send_to(int(member["user_id"]), "room.v2.pin", payload)
        except Exception:
            pass


@router.get("/{room_type}/{room_id}/pins")
def list_room_pins(
    room_type: str,
    room_id: int,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        _room_membership(c, room_type, room_id, user["id"])
        return {
            "pins": _room_pinned_messages(
                c, room_type, room_id
            )
        }
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/pins")
def pin_room_message(
    room_type: str,
    room_id: int,
    body: RoomPinBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        membership = _room_membership(c, room_type, room_id, user["id"])
        if membership["role"] not in {"owner", "admin"}:
            raise HTTPException(403, "Закреплять сообщения могут только администраторы")
        room = _room_row(c, room_type, room_id)
        message = c.execute(
            "SELECT id, attachment_file_ids FROM gc_room_messages "
            "WHERE id=? AND room_type=? AND room_id=?",
            (body.message_id, room_type, room_id),
        ).fetchone()
        if not message:
            raise HTTPException(404, "Сообщение не найдено")

        existing = c.execute(
            "SELECT 1 FROM gc_room_pins WHERE room_type=? AND room_id=? AND message_id=?",
            (room_type, room_id, body.message_id),
        ).fetchone()
        count = int(
            c.execute(
                "SELECT COUNT(*) AS n FROM gc_room_pins WHERE room_type=? AND room_id=?",
                (room_type, room_id),
            ).fetchone()["n"]
        )
        if not existing and count >= 100:
            c.execute(
                "DELETE FROM gc_room_pins WHERE room_type=? AND room_id=? "
                "AND message_id IN (SELECT message_id FROM gc_room_pins "
                "WHERE room_type=? AND room_id=? ORDER BY pinned_at ASC, message_id ASC LIMIT ?)",
                (room_type, room_id, room_type, room_id, count - 99),
            )
        try:
            message_file_ids = json.loads(message["attachment_file_ids"] or "[]")
        except (TypeError, ValueError):
            message_file_ids = []
        if not isinstance(message_file_ids, list):
            message_file_ids = []
        message_file_ids = _validate_room_file_refs(
            c,
            room_type,
            room_id,
            [str(file_id) for file_id in message_file_ids],
        )
        pinned_file_ids = _room_pinned_file_ids(c, room_type, room_id)
        if len(pinned_file_ids | set(message_file_ids)) > 3:
            raise HTTPException(
                409,
                "В комнате можно хранить бессрочно не более 3 закреплённых вложений",
            )
        show_preview = bool(
            room["show_pinned_preview"]
            if "show_pinned_preview" in room.keys()
            else 0
        )
        preview_text = ""
        if membership["visibility"] == "private" and show_preview:
            preview_text = (body.preview_text or "").strip() or "Закреплённое сообщение"
        now = int(time.time())
        c.execute(
            """
            INSERT INTO gc_room_pins
                (room_type, room_id, message_id, pinned_by, pinned_at, notify, preview_text)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_type, room_id, message_id) DO UPDATE SET
                pinned_by=excluded.pinned_by,
                pinned_at=excluded.pinned_at,
                notify=excluded.notify,
                preview_text=excluded.preview_text
            """,
            (
                room_type,
                room_id,
                body.message_id,
                user["id"],
                now,
                int(body.notify),
                preview_text,
            ),
        )
        _sync_room_file_expiry(c, room_type, room_id)
        c.commit()
        _broadcast_room_pin_event(
            c,
            room_type,
            room_id,
            body.message_id,
            action="pin",
            notify=body.notify,
        )
        return {"status": "pinned", "message_id": body.message_id, "pinned_at": now}
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()


@router.delete("/{room_type}/{room_id}/pins/{message_id}")
def unpin_room_message(
    room_type: str,
    room_id: int,
    message_id: int,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        membership = _room_membership(c, room_type, room_id, user["id"])
        if membership["role"] not in {"owner", "admin"}:
            raise HTTPException(403, "Снимать закрепление могут только администраторы")
        c.execute(
            "DELETE FROM gc_room_pins WHERE room_type=? AND room_id=? AND message_id=?",
            (room_type, room_id, message_id),
        )
        _sync_room_file_expiry(c, room_type, room_id)
        c.commit()
        _broadcast_room_pin_event(
            c, room_type, room_id, message_id, action="unpin", notify=False
        )
        return {"status": "unpinned", "message_id": message_id}
    except HTTPException:
        c.rollback()
        raise
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/send")
def send_room_message(
    room_type: str,
    room_id: int,
    body: RoomSendBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    _rate_limit(f"room-send:{user['id']}", limit=240, window=3600)
    c = db()
    try:
        idem_scope = f"room:{room_type}:{room_id}"
        replay = idem_begin(c, user["id"], idem_scope, body)
        if replay is not None:
            return replay
        if body.sender_identity_pub is not None:
            own = c.execute("SELECT v2_identity_pub FROM users WHERE id=?", (user["id"],)).fetchone()
            if not own or own["v2_identity_pub"] != body.sender_identity_pub:
                raise HTTPException(409, "v2_identity_key_stale")
        membership = _room_membership(c, room_type, room_id, user["id"])
        if room_type == "channel" and membership["role"] not in {"owner", "admin"}:
            raise HTTPException(403, "В канале писать могут только владелец и администраторы")
        attachment_file_ids = _validate_room_file_refs(
            c, room_type, room_id, body.attachment_file_ids
        )
        now = int(time.time())
        if membership["visibility"] == "public":
            if not body.payload:
                raise HTTPException(400, "payload обязателен для публичной комнаты")
            cur = c.execute(
                """
                INSERT INTO gc_room_messages
                    (room_type, room_id, sender_id, payload, is_encrypted,
                     created_at, attachment_file_ids)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """,
                (
                    room_type,
                    room_id,
                    user["id"],
                    body.payload,
                    now,
                    json.dumps(attachment_file_ids, separators=(",", ":")),
                ),
            )
            message_id = cur.lastrowid

            recipient_rows = _room_member_rows(c, room_type, room_id)
        else:
            if body.payload is not None or not body.envelopes:
                raise HTTPException(400, "Для приватной комнаты нужны V2-конверты")
            devices = {
                int(row["device_id"]): row for row in _room_device_rows(c, room_type, room_id)
            }
            if len(body.envelopes) > 64:
                raise HTTPException(400, "Слишком много устройств")
            validated = []
            if len({e.target_device_id for e in body.envelopes}) != len(body.envelopes):
                raise HTTPException(422, "Повторяющийся target_device_id")
            if body.client_message_id and {e.target_device_id for e in body.envelopes} != set(devices):
                raise HTTPException(409, "v2_device_key_stale: обновите устройства участников")
            for envelope in body.envelopes:
                if not envelope.envelope or len(envelope.envelope) > 10000:
                    raise HTTPException(400, "Некорректный envelope")
                try:
                    base64.b64decode(envelope.envelope, validate=True)
                except Exception:
                    raise HTTPException(400, "envelope должен быть base64")
                target = devices.get(envelope.target_device_id)
                if not target:
                    continue
                if (
                    envelope.target_device_pub is not None
                    and envelope.target_device_pub != target["v2_device_pub"]
                ):
                    raise HTTPException(409, "v2_device_key_stale: обновите ключи участников")
                validated.append((envelope, target))
            if not validated:
                raise HTTPException(409, "У участников нет доступных V2-устройств")
            cur = c.execute(
                """
                INSERT INTO gc_room_messages
                    (room_type, room_id, sender_id, payload, is_encrypted,
                     created_at, attachment_file_ids)
                VALUES (?, ?, ?, NULL, 1, ?, ?)
                """,
                (
                    room_type,
                    room_id,
                    user["id"],
                    now,
                    json.dumps(attachment_file_ids, separators=(",", ":")),
                ),
            )
            message_id = cur.lastrowid
            for envelope, target in validated:
                c.execute(
                    """
                    INSERT INTO gc_room_envelopes
                        (message_id, receiver_user_id, receiver_device_id, envelope, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        message_id,
                        target["user_id"],
                        target["device_id"],
                        envelope.envelope,
                        now,
                    ),
                )

            recipient_rows = validated

        response = {"status": "ok", "message_id": message_id, "created_at": now}
        idem_save(c, user["id"], idem_scope, body, response)
        # Keep the unified chat list ordered by the latest room activity.
        # The table name is selected from the validated room_type, never from
        # user-controlled SQL input.
        room_table = "gc_channels" if room_type == "channel" else "gc_groups"
        c.execute(
            f"UPDATE {room_table} SET updated_at=? WHERE id=?",
            (now, room_id),
        )
        c.commit()

        # The socket event contains no message content. Clients fetch the
        # public payload or their own private envelope through GET messages.
        if membership["visibility"] == "public":
            recipients = {int(row["user_id"]) for row in recipient_rows}
        else:
            recipients = {int(target["user_id"]) for _, target in recipient_rows}
        for recipient_id in recipients:
            try:
                ws_hub.send_to(
                    recipient_id,
                    "room.v2.new",
                    {"room_type": room_type, "room_id": room_id, "message_id": message_id},
                )
            except Exception:
                pass
        return response
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/receipts")
def acknowledge_room_messages(
    room_type: str,
    room_id: int,
    body: RoomReceiptBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    if body.status not in {"delivered", "read"}:
        raise HTTPException(422, "status must be delivered or read")
    message_ids = list(dict.fromkeys(mid for mid in body.message_ids if mid > 0))
    if not message_ids:
        return {"status": "ok", "updated": 0}
    c = db()
    try:
        _room_membership(c, room_type, room_id, user["id"])
        if body.status == "read" and not _get_privacy_flags(c, user["id"])["send_read_receipts"]:
            return {"status": "suppressed", "updated": 0}
        placeholders = ",".join("?" for _ in message_ids)
        rows = c.execute(
            f"""
            SELECT id, sender_id FROM gc_room_messages
            WHERE room_type=? AND room_id=? AND sender_id<>?
              AND id IN ({placeholders})
            """,
            [room_type, room_id, user["id"], *message_ids],
        ).fetchall()
        now = int(time.time())
        for row in rows:
            read_at = now if body.status == "read" else None
            c.execute(
                """
                INSERT INTO gc_room_message_receipts
                    (message_id, user_id, delivered_at, read_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(message_id, user_id) DO UPDATE SET
                    delivered_at=COALESCE(gc_room_message_receipts.delivered_at, excluded.delivered_at),
                    read_at=COALESCE(gc_room_message_receipts.read_at, excluded.read_at)
                """,
                (row["id"], user["id"], now, read_at),
            )
        c.commit()
        by_sender: dict[int, list[int]] = {}
        for row in rows:
            by_sender.setdefault(int(row["sender_id"]), []).append(int(row["id"]))
        for sender_id, sender_message_ids in by_sender.items():
            try:
                ws_hub.send_to(
                    sender_id,
                    "room.v2.receipt",
                    {
                        "room_type": room_type,
                        "room_id": room_id,
                        "message_ids": sender_message_ids,
                        "status": body.status,
                    },
                )
            except Exception:
                pass
        return {"status": "ok", "updated": len(rows)}
    finally:
        c.close()


@router.get("/{room_type}/{room_id}/messages")
def list_room_messages(
    room_type: str,
    room_id: int,
    after_id: int = 0,
    limit: int = 100,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        membership = _room_membership(c, room_type, room_id, user["id"])
        limit = max(1, min(int(limit or 100), 200))
        cutoff = int(membership["joined_at"] or 0)
        history_clause = "" if membership["history_mode"] == "all" else " AND m.created_at>=?"
        params = [room_type, room_id, max(0, int(after_id or 0))]
        if history_clause:
            params.append(cutoff)
        params.append(limit)
        if membership["visibility"] == "public":
            rows = c.execute(
                """
                SELECT m.id, m.sender_id, m.payload, m.created_at,
                       (SELECT COUNT(DISTINCT user_id) FROM gc_room_message_receipts r
                        WHERE r.message_id=m.id AND r.delivered_at IS NOT NULL) AS delivered_count,
                       (SELECT COUNT(DISTINCT user_id) FROM gc_room_message_receipts r
                        WHERE r.message_id=m.id AND r.read_at IS NOT NULL) AS read_count,
                       u.username AS sender_username,
                       u.display_name AS sender_display_name,
                       u.avatar_url AS sender_avatar_url
                FROM gc_room_messages m JOIN users u ON u.id=m.sender_id
                WHERE m.room_type=? AND m.room_id=? AND m.id>? AND m.is_encrypted=0
                """
                + history_clause
                + " ORDER BY m.id ASC LIMIT ?",
                params,
            ).fetchall()
            return {
                "messages": [
                    {
                        "id": row["id"],
                        "payload": row["payload"],
                        "created_at": row["created_at"],
                        "sender_username": row["sender_username"],
                        "sender_display_name": row["sender_display_name"],
                        "sender_avatar_url": row["sender_avatar_url"],
                        "from_me": int(row["sender_id"]) == int(user["id"]),
                        "delivered_count": int(row["delivered_count"] or 0)
                        if int(row["sender_id"]) == int(user["id"]) else 0,
                        "read_count": int(row["read_count"] or 0)
                        if int(row["sender_id"]) == int(user["id"]) else 0,
                    }
                    for row in rows
                ]
            }

        token = (authorization or "").split(" ", 1)[-1] if authorization else ""
        device = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (token, user["id"]),
        ).fetchone()
        if not device:
            raise HTTPException(404, "Текущее устройство не найдено")
        params = [user["id"], device["id"], room_type, room_id, max(0, int(after_id or 0))]
        if history_clause:
            params.append(cutoff)
        params.append(limit)
        rows = c.execute(
            """
            SELECT m.id, m.sender_id, m.created_at, e.id AS envelope_id, e.envelope,
                   (SELECT COUNT(DISTINCT user_id) FROM gc_room_message_receipts r
                    WHERE r.message_id=m.id AND r.delivered_at IS NOT NULL) AS delivered_count,
                   (SELECT COUNT(DISTINCT user_id) FROM gc_room_message_receipts r
                    WHERE r.message_id=m.id AND r.read_at IS NOT NULL) AS read_count,
                   u.username AS sender_username,
                   u.display_name AS sender_display_name,
                   u.avatar_url AS sender_avatar_url
            FROM gc_room_messages m
            JOIN gc_room_envelopes e ON e.message_id=m.id
            JOIN users u ON u.id=m.sender_id
            WHERE e.receiver_user_id=? AND e.receiver_device_id=?
              AND m.room_type=? AND m.room_id=? AND m.id>?
            """
            + history_clause
            + " ORDER BY m.id ASC LIMIT ?",
            params,
        ).fetchall()
        return {
            "messages": [
                {
                    "id": row["id"],
                    "envelope_id": row["envelope_id"],
                    "envelope": row["envelope"],
                    "created_at": row["created_at"],
                    "sender_username": row["sender_username"],
                    "sender_display_name": row["sender_display_name"],
                    "sender_avatar_url": row["sender_avatar_url"],
                    "from_me": int(row["sender_id"]) == int(user["id"]),
                    "delivered_count": int(row["delivered_count"] or 0)
                    if int(row["sender_id"]) == int(user["id"]) else 0,
                    "read_count": int(row["read_count"] or 0)
                    if int(row["sender_id"]) == int(user["id"]) else 0,
                }
                for row in rows
            ]
        }
    finally:
        c.close()


init_rooms_v2()
