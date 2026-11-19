"""API метаданных комнат GhostChat 1.2: каналы и группы."""

import base64
import hashlib
import io
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from typing import Optional
from urllib.parse import unquote, urlsplit

from fastapi import APIRouter, File, Header, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field

from social_router import (
    _decode_banner_config,
    _normalize_banner_config,
    _rate_limit,
    _val_name,
    _val_username,
    _get_privacy_flags,
    auth,
    auth_member,
    db,
    ws_hub,
)


router = APIRouter(prefix="/api/chat/v2/rooms", tags=["GhostChat rooms v2"])


class GroupCreateBody(BaseModel):
    username: Optional[str] = Field(default=None, min_length=3, max_length=64)
    title: str = Field(min_length=2, max_length=100)
    about: str = Field(default="", max_length=512)
    visibility: str = Field(default="private", max_length=16)
    history_mode: str = Field(default="new_only", max_length=16)


class GroupMemberBody(BaseModel):
    username: str = Field(min_length=3, max_length=64)


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


class RoomConvertBody(BaseModel):
    room_type: str = Field(min_length=5, max_length=16)


class RoomEnvelopeBody(BaseModel):
    target_device_id: int
    envelope: str
    target_device_pub: Optional[str] = None


class RoomSendBody(BaseModel):
    payload: Optional[str] = Field(default=None, max_length=20000)
    envelopes: list[RoomEnvelopeBody] = Field(default_factory=list, max_length=64)


class RoomReceiptBody(BaseModel):
    message_ids: list[int] = Field(default_factory=list, max_length=200)
    status: str = Field(min_length=1, max_length=16)


_VISIBILITIES = {"public", "private"}
_HISTORY_MODES = {"new_only", "all"}
MAX_GROUPS_PER_USER = 15

_ROOM_LINK_HOSTS = {"ghostecos.duckdns.org", "ghostchats.duckdns.org"}
_ROOM_LINK_HANDLE = re.compile(r"^[a-z0-9_.]{3,64}$")


def _parse_room_search_link(raw: str) -> Optional[tuple[str, str | int]]:
    """Извлекаем точную ссылку на комнату из публичного URL GhostChat."""
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
    """Разбираем ссылку на комнату; None — запрос обычный текст."""
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
    payload = _room_payload(c, kind, row, user_id)
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
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_gc_room_messages_room
                ON gc_room_messages(room_type, room_id, id ASC);

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
        c.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_gc_groups_username "
            "ON gc_groups(username) WHERE username IS NOT NULL"
        )
        # Старым группам без публичного имени даём стабильный handle.
        # Так новый API возвращает единый идентификатор без смены ID сообщений.
        legacy_groups = c.execute(
            "SELECT id FROM gc_groups WHERE username IS NULL ORDER BY id ASC"
        ).fetchall()
        for legacy in legacy_groups:
            candidate = _new_group_username(c, int(legacy["id"]))
            c.execute(
                "UPDATE gc_groups SET username=? WHERE id=?",
                (candidate, legacy["id"]),
            )
        # Публичная группа по контракту открытым текстом.
        # Исправляем старые записи, чтобы клиент не запрашивал ключи E2EE.
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
    """Проверяем и резервируем username группы в общем публичном пространстве имён."""
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
    """Проверяет, принимает ли цель прямое приглашение в комнату."""
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


@router.get("/public/{username}")
def public_room_preview(
    username: str,
    limit: int = Query(default=30, ge=1, le=50),
    authorization: Optional[str] = Header(None),
):
    """Безопасный превью-профиль публичного канала или группы."""
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
        # Старые ссылки вроде /g/1 сохраняем: новые используют уникальное имя группы.
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
            "room": _room_payload(c, room_type, row, current_id),
            "is_member": role is not None,
            "messages": _public_preview_messages(c, room_type, row["id"], limit),
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
    """Каналы и группы, видимые этому аккаунту."""
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
            item = {
                "room_type": "channel",
                "id": row["id"],
                "username": row["username"],
                "title": row["title"],
                "about": row["about"],
                "avatar_url": row["avatar_url"] if "avatar_url" in row.keys() else None,
                "owner_id": row["owner_id"],
                "visibility": row["visibility"],
                "history_mode": row["history_mode"],
                "encryption_mode": row["encryption_mode"],
                "key_epoch": row["key_epoch"],
                "members_count": c.execute(
                    "SELECT COUNT(*) AS n FROM gc_channel_members WHERE channel_id=?",
                    (row["id"],),
                ).fetchone()["n"],
                "role": row["role"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "last_message": _last_room_message(
                    c,
                    "channel",
                    row["id"],
                    user["id"],
                    row["member_joined_at"],
                    row["history_mode"],
                ),
            }
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
    """Поиск комнат по тексту или точное разрешение одной ссылки GhostChat."""
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
            payload = _room_payload(c, kind, row, user_id)
            payload["is_member"] = _room_role(c, kind, row["id"], user_id) is not None if user_id else False
            result.append(payload)
        return {"rooms": result[:50]}
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/request-join")
def request_room_join(
    room_type: str,
    room_id: int,
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
        if row["visibility"] == "public":
            table = "gc_channel_members" if room_type == "channel" else "gc_group_members"
            column = "channel_id" if room_type == "channel" else "group_id"
            c.execute(
                f"INSERT OR IGNORE INTO {table}({column}, user_id, role) VALUES (?, ?, 'member')",
                (room_id, user["id"]),
            )
            c.commit()
            return {"status": "joined", **_room_payload(c, room_type, row, user["id"])}
        _room_join_request(c, room_type, room_id, user["id"])
        c.commit()
        return {"status": "requested", "room_type": room_type, "room_id": room_id}
    finally:
        c.close()


@router.post("/{room_type}/{room_id}/convert")
def convert_room(
    room_type: str,
    room_id: int,
    body: RoomConvertBody,
    authorization: Optional[str] = Header(None),
):
    """Перенос комнаты между таблицами каналов и групп одной транзакцией."""
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

        # У таблиц независимые UNIQUE-ограничения, но пользователи, каналы и реестр
        # handle делят одно видимое пространство имён.
        # Исключаем только исходную запись; остальные владельцы — конфликт.
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
            source["encryption_mode"],
            source["key_epoch"],
            now,
        )
        c.execute(
            f"""
            INSERT INTO {target_table}
                (username, title, about, avatar_url, banner_config, owner_id,
                 visibility, history_mode, encryption_mode, key_epoch,
                 status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
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
        if room_type == "channel":
            # Старый канал не может оставить handle, который заняла новая группа.
            # Канал архивируется, новое имя пользователю не показываем.
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

        # У приватной комнаты одна активная обычная ссылка.
        # Новая ссылка отзывает предыдущую по правилам продукта.
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


@router.get("/invite-links/preview/{token}")
def preview_room_invite(
    token: str,
    authorization: Optional[str] = Header(None),
):
    """Превью приглашения без вступления и без раскрытия приватных сообщений."""
    user = None
    if authorization:
        try:
            candidate = auth(authorization)
            if not candidate.get("is_guest"):
                user = candidate
        except HTTPException:
            # Приглашение по ссылке доступно для просмотра до входа.
            # Вступление и адресное приглашение требуют авторизации.
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
        return {
            "room": _room_payload(
                c,
                link["room_type"],
                row,
                user["id"] if user else None,
            ),
            "is_member": role is not None,
            "request_join": bool(link["request_join"]),
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
        if link["request_join"]:
            _room_join_request(c, link["room_type"], link["room_id"], user["id"])
            result = {"status": "requested"}
        else:
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
        # Сериализуем подсчёт и создание: параллельные запросы не обходят квоту.
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
    """Правка полей профиля группы; редактировать может только creator."""
    user = auth_member(authorization)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_groups WHERE id=? AND status='active'",
            (group_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Группа не найдена")
        if row["owner_id"] != user["id"]:
            raise HTTPException(403, "Только владелец может редактировать группу")

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
        if not updates:
            raise HTTPException(422, "Нечего изменять")

        updates["updated_at"] = int(time.time())
        set_clause = ", ".join(f"{key}=?" for key in updates)
        c.execute(
            f"UPDATE gc_groups SET {set_clause} WHERE id=?",
            list(updates.values()) + [group_id],
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
    """Замена аватара канала/группы; только creator."""
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
    """Приглашает пользователя в канал."""
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
        membership = _room_membership(c, room_type, room_id, user["id"])
        if room_type == "channel" and membership["role"] not in {"owner", "admin"}:
            raise HTTPException(403, "В канале писать могут только владелец и администраторы")
        now = int(time.time())
        if membership["visibility"] == "public":
            if not body.payload:
                raise HTTPException(400, "payload обязателен для публичной комнаты")
            cur = c.execute(
                """
                INSERT INTO gc_room_messages
                    (room_type, room_id, sender_id, payload, is_encrypted, created_at)
                VALUES (?, ?, ?, ?, 0, ?)
                """,
                (room_type, room_id, user["id"], body.payload, now),
            )
            message_id = cur.lastrowid
            c.commit()
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
                    (room_type, room_id, sender_id, payload, is_encrypted, created_at)
                VALUES (?, ?, ?, NULL, 1, ?)
                """,
                (room_type, room_id, user["id"], now),
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
            c.commit()
            recipient_rows = validated

        # Общий список чатов сортируем по последней активности.
        # Имя таблицы берётся из проверенного room_type, не из пользовательского ввода.
        room_table = "gc_channels" if room_type == "channel" else "gc_groups"
        c.execute(
            f"UPDATE {room_table} SET updated_at=? WHERE id=?",
            (now, room_id),
        )
        c.commit()

        # Событие WS не содержит текста сообщения.
        # Клиент получает payload или свой конверт через GET messages.
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
        return {"status": "ok", "message_id": message_id, "created_at": now}
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
