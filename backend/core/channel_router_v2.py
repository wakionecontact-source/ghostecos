"""API каналов GhostChat 1.2: только identity и метаданные, без ключей и транспорта сообщений."""

import json
import sqlite3
import time
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, Field

from ecos_core.identity import db
from ecos_core.client import auth, auth_member
from ecos_core.shared import _decode_banner_config, _normalize_banner_config, _rate_limit, _val_name, _val_username, _claim_public_handle



router = APIRouter(prefix="/api/chat/v2/channels", tags=["GhostChat channels v2"])


class ChannelCreateBody(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    title: str = Field(min_length=2, max_length=100)
    about: str = Field(default="", max_length=512)
    visibility: str = Field(default="private", max_length=16)
    history_mode: str = Field(default="new_only", max_length=16)


class ChannelPatchBody(BaseModel):
    username: Optional[str] = Field(default=None, min_length=3, max_length=64)
    title: Optional[str] = Field(default=None, min_length=2, max_length=100)
    about: Optional[str] = Field(default=None, max_length=512)
    banner: Optional[dict] = None
    banner_clear: bool = False
    visibility: Optional[str] = Field(default=None, max_length=16)
    history_mode: Optional[str] = Field(default=None, max_length=16)


_VISIBILITIES = {"public", "private"}
_HISTORY_MODES = {"new_only", "all"}


def init_channels_v2() -> None:
    """Создаём таблицы каналов и заполняем реестр handle'ов."""
    c = db()
    try:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS gc_channels (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL UNIQUE,
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

            CREATE INDEX IF NOT EXISTS idx_gc_channels_owner
                ON gc_channels(owner_id, status, id DESC);
            CREATE INDEX IF NOT EXISTS idx_gc_channels_public
                ON gc_channels(visibility, status, id DESC);

            CREATE TABLE IF NOT EXISTS gc_channel_members (
                channel_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                role TEXT NOT NULL DEFAULT 'member'
                    CHECK(role IN ('owner', 'admin', 'member')),
                joined_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                PRIMARY KEY(channel_id, user_id),
                FOREIGN KEY(channel_id) REFERENCES gc_channels(id),
                FOREIGN KEY(user_id) REFERENCES users(id)
            );
            CREATE INDEX IF NOT EXISTS idx_gc_channel_members_user
                ON gc_channel_members(user_id, joined_at DESC);
            """
        )
        try:
            c.execute("ALTER TABLE gc_channels ADD COLUMN avatar_url TEXT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            c.execute("ALTER TABLE gc_channels ADD COLUMN banner_config TEXT NULL")
        except sqlite3.OperationalError:
            pass
        # Реестр обычно создаёт social_router.init(); здесь он нужен для изолированных тестов.
        c.execute(
            """
            CREATE TABLE IF NOT EXISTS gc_public_handles (
                handle TEXT PRIMARY KEY,
                owner_type TEXT NOT NULL
                    CHECK(owner_type IN ('user', 'channel', 'legacy_channel')),
                owner_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
            )
            """
        )
        c.execute(
            """
            INSERT OR IGNORE INTO gc_public_handles(handle, owner_type, owner_id)
            SELECT lower(username), 'user', id FROM users
            WHERE username IS NOT NULL AND trim(username) <> ''
            """
        )
        c.commit()
    finally:
        c.close()


def _validate_channel_options(visibility: str, history_mode: str) -> None:
    if visibility not in _VISIBILITIES:
        raise HTTPException(422, "visibility должна быть public или private")
    if history_mode not in _HISTORY_MODES:
        raise HTTPException(422, "history_mode должен быть new_only или all")


def _role(c, channel_id: int, user_id: int) -> Optional[str]:
    row = c.execute(
        "SELECT role FROM gc_channel_members WHERE channel_id=? AND user_id=?",
        (channel_id, user_id),
    ).fetchone()
    return row["role"] if row else None


def _channel_dict(c, row, user_id: Optional[int] = None) -> dict:
    count = c.execute(
        "SELECT COUNT(*) AS n FROM gc_channel_members WHERE channel_id=?",
        (row["id"],),
    ).fetchone()["n"]
    role = _role(c, row["id"], user_id) if user_id else None
    return {
        "id": row["id"],
        "username": row["username"],
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


def _get_channel(c, username: str):
    return c.execute(
        "SELECT * FROM gc_channels WHERE username=? AND status='active'",
        (username,),
    ).fetchone()


@router.get("/handle/check")
def check_channel_handle(username: str = Query(..., min_length=1, max_length=64)):
    """Проверка единого namespace username пользователей и каналов."""
    normalized = _val_username(username)
    c = db()
    try:
        row = c.execute(
            "SELECT owner_type FROM gc_public_handles WHERE handle=?",
            (normalized,),
        ).fetchone()
        return {
            "handle": normalized,
            "available": row is None,
            "occupied_by": row["owner_type"] if row else None,
        }
    finally:
        c.close()


@router.post("")
def create_channel(body: ChannelCreateBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"channel:create:{user['id']}", limit=20, window=3600)
    username = _val_username(body.username)
    title = _val_name(body.title)
    about = body.about.strip()
    _validate_channel_options(body.visibility, body.history_mode)

    c = db()
    try:
        encryption_mode = "none" if body.visibility == "public" else "e2ee_v2"
        c.execute(
            """
            INSERT INTO gc_channels
                (username, title, about, owner_id, visibility, history_mode,
                 encryption_mode, key_epoch, status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'active', ?)
            """,
            (
                username,
                title,
                about,
                user["id"],
                body.visibility,
                body.history_mode,
                encryption_mode,
                int(time.time()),
            ),
        )
        channel_id = c.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]
        _claim_public_handle(c, username, "channel", channel_id)
        c.execute(
            "INSERT INTO gc_channel_members(channel_id, user_id, role) VALUES (?, ?, 'owner')",
            (channel_id, user["id"]),
        )
        c.commit()
        row = c.execute("SELECT * FROM gc_channels WHERE id=?", (channel_id,)).fetchone()
        return _channel_dict(c, row, user["id"])
    except HTTPException:
        c.rollback()
        raise
    except sqlite3.IntegrityError:
        c.rollback()
        raise HTTPException(409, "Имя пользователя уже занято")
    finally:
        c.close()


@router.get("/my")
def list_my_channels(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        rows = c.execute(
            """
            SELECT c.* FROM gc_channels c
            JOIN gc_channel_members m ON m.channel_id=c.id
            WHERE m.user_id=? AND c.status='active'
            ORDER BY c.id DESC
            """,
            (user["id"],),
        ).fetchall()
        return {"channels": [_channel_dict(c, row, user["id"]) for row in rows]}
    finally:
        c.close()


@router.get("/{username}")
def get_channel(username: str, authorization: Optional[str] = Header(None)):
    normalized = _val_username(username)
    c = db()
    try:
        row = _get_channel(c, normalized)
        if not row:
            raise HTTPException(404, "Канал не найден")
        current_id = None
        if authorization:
            try:
                current = auth(authorization)
                if not current.get("is_guest"):
                    current_id = current["id"]
            except HTTPException:
                current_id = None
        role = _role(c, row["id"], current_id) if current_id else None
        if row["visibility"] == "private" and role is None:
            raise HTTPException(404, "Канал не найден")
        return _channel_dict(c, row, current_id)
    finally:
        c.close()


@router.post("/{username}/join")
def join_public_channel(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"channel:join:{user['id']}", limit=60, window=3600)
    normalized = _val_username(username)
    c = db()
    try:
        row = _get_channel(c, normalized)
        if not row:
            raise HTTPException(404, "Канал не найден")
        if row["visibility"] != "public":
            raise HTTPException(403, "Приватный канал доступен только по приглашению")
        c.execute(
            "INSERT OR IGNORE INTO gc_channel_members(channel_id, user_id, role) VALUES (?, ?, 'member')",
            (row["id"], user["id"]),
        )
        c.commit()
        return _channel_dict(c, row, user["id"])
    finally:
        c.close()


@router.patch("/id/{channel_id}")
def update_channel(
    channel_id: int,
    body: ChannelPatchBody,
    authorization: Optional[str] = Header(None),
):
    user = auth_member(authorization)
    c = db()
    try:
        row = c.execute(
            "SELECT * FROM gc_channels WHERE id=? AND status='active'",
            (channel_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Канал не найден")
        role = _role(c, channel_id, user["id"])
        if role not in {"owner", "admin"}:
            raise HTTPException(403, "Недостаточно прав")
        if body.username is not None and role != "owner":
            raise HTTPException(403, "Username канала меняет только владелец")

        updates = {}
        if body.username is not None:
            updates["username"] = _val_username(body.username)
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
            if body.visibility != row["visibility"]:
                # Смена публичности меняет шифрование: нельзя молча перетрактовать старую историю.
                raise HTTPException(409, "Тип канала нельзя менять после создания")
        if body.history_mode is not None:
            if body.history_mode not in _HISTORY_MODES:
                raise HTTPException(422, "history_mode должен быть new_only или all")
            updates["history_mode"] = body.history_mode
        if not updates:
            raise HTTPException(422, "Нечего изменять")

        if "username" in updates:
            _claim_public_handle(c, updates["username"], "channel", channel_id)
        updates["updated_at"] = int(time.time())
        set_clause = ", ".join(f"{key}=?" for key in updates)
        c.execute(
            f"UPDATE gc_channels SET {set_clause} WHERE id=?",
            list(updates.values()) + [channel_id],
        )
        if "username" in updates and updates["username"] != row["username"]:
            c.execute(
                "DELETE FROM gc_public_handles "
                "WHERE owner_type='channel' AND owner_id=? AND handle<>?",
                (channel_id, updates["username"]),
            )
        c.commit()
        fresh = c.execute("SELECT * FROM gc_channels WHERE id=?", (channel_id,)).fetchone()
        return _channel_dict(c, fresh, user["id"])
    except HTTPException:
        c.rollback()
        raise
    except sqlite3.IntegrityError:
        c.rollback()
        raise HTTPException(409, "Имя пользователя уже занято")
    finally:
        c.close()


# Повторный init() здесь делает прямые импорты и изолированные тесты детерминированными.
init_channels_v2()
