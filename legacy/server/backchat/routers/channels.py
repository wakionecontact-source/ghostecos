"""Каналы и группы: CRUD, участники, сообщения, ключи, реакции."""
from __future__ import annotations
import uuid, json
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List

import database as db
from dependencies import get_current_user

router = APIRouter(prefix="/api", tags=["channels"])

# ── Модели ────────────────────────────────────────────────────────────────────

class CreateChannelRequest(BaseModel):
    name:        str = Field(min_length=2, max_length=64)
    tag:         str = Field(min_length=2, max_length=32)
    description: str = Field("", max_length=256)
    type:        str = "group"           # group | channel
    is_private:  bool = False

class UpdateChannelRequest(BaseModel):
    name:        Optional[str] = Field(None, max_length=64)
    description: Optional[str] = Field(None, max_length=256)

class SendChannelMsgRequest(BaseModel):
    body:            str
    msg_id:          str
    reply_to_msg_id: str = ""
    # reply_body и reply_from намеренно убраны — клиент резолвит из локальной БД

class SetWrappedKeyRequest(BaseModel):
    wrapped_keys: dict   # {username: wrapped_key}

class JoinRequestAction(BaseModel):
    action: str   # approve | reject

# ── Каналы ────────────────────────────────────────────────────────────────────


@router.get("/channels/my")
async def my_channels_alias(username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        """SELECT c.id, c.name, c.tag, c.description, c.type, c.is_private, c.creator,
                  cm.role
           FROM channels c
           JOIN channel_members cm ON cm.channel_id = c.id
           WHERE cm.username = ?""",
        (username,)
    )
    return {"channels": [dict(r) for r in rows]}

@router.get("/channels")
async def list_my_channels(username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        """SELECT c.id, c.name, c.tag, c.description, c.type, c.is_private, c.creator,
                  cm.role
           FROM channels c
           JOIN channel_members cm ON cm.channel_id = c.id AND cm.username = ?
           ORDER BY c.name""",
        (username,)
    )
    return {"channels": rows}


@router.get("/channels/by_tag/{tag}")
async def get_channel_by_tag(tag: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT id, name, tag, description, type, is_private, creator FROM channels WHERE tag = ?",
        (tag.strip().lower(),)
    )
    if not row:
        raise HTTPException(404, "Channel not found")
    return row


@router.get("/channels/{channel_id}")
async def get_channel(channel_id: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT id, name, tag, description, type, is_private, creator, created_at FROM channels WHERE id = ?",
        (channel_id,)
    )
    if not row:
        raise HTTPException(404, "Channel not found")
    # Проверить доступ: если приватный — только участники
    if row["is_private"]:
        mem = await db.fetchone(
            "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
            (channel_id, username)
        )
        if not mem:
            raise HTTPException(403, "Access denied")
    return row


@router.post("/channels")
async def create_channel(req: CreateChannelRequest, username: str = Depends(get_current_user)):
    tag = req.tag.strip().lower()
    if not all(c.isalnum() or c == '_' for c in tag):
        raise HTTPException(400, "Invalid tag characters")

    existing = await db.fetchone("SELECT id FROM channels WHERE tag = ?", (tag,))
    if existing:
        raise HTTPException(409, "Tag already taken")

    channel_id = str(uuid.uuid4())
    now = db.now()
    await db.execute(
        "INSERT INTO channels (id, name, tag, description, type, is_private, creator, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (channel_id, req.name.strip(), tag, req.description.strip(),
         req.type, 1 if req.is_private else 0, username, now)
    )
    await db.execute(
        "INSERT INTO channel_members (channel_id, username, role, joined_at) VALUES (?,?,?,?)",
        (channel_id, username, "owner", now)
    )
    return {"channel_id": channel_id, "tag": tag}


@router.patch("/channels/{channel_id}")
async def update_channel(channel_id: str, req: UpdateChannelRequest,
                         username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] not in ("owner", "admin"):
        raise HTTPException(403, "Only owner/admin can update channel")
    fields, vals = [], []
    if req.name        is not None: fields.append("name = ?");        vals.append(req.name.strip())
    if req.description is not None: fields.append("description = ?"); vals.append(req.description.strip())
    if not fields:
        return {"ok": True}
    vals.append(channel_id)
    await db.execute(f"UPDATE channels SET {', '.join(fields)} WHERE id = ?", tuple(vals))
    return {"ok": True}


@router.delete("/channels/{channel_id}")
async def delete_channel(channel_id: str, username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] != "owner":
        raise HTTPException(403, "Only owner can delete channel")
    await db.execute("DELETE FROM channel_messages WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_members WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_keys WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_join_requests WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channels WHERE id = ?", (channel_id,))
    return {"ok": True}


# ── Участники ─────────────────────────────────────────────────────────────────

@router.get("/channels/{channel_id}/members")
async def list_members(channel_id: str, username: str = Depends(get_current_user)):
    _assert_member(await db.fetchone(
        "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    ))
    rows = await db.fetchall(
        "SELECT username, role, joined_at FROM channel_members WHERE channel_id = ? ORDER BY joined_at",
        (channel_id,)
    )
    return {"members": rows}


@router.post("/channels/{channel_id}/members/{target}")
async def add_member(channel_id: str, target: str, username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] not in ("owner", "admin"):
        raise HTTPException(403, "Only owner/admin can add members")
    target = target.strip().lower()
    user = await db.fetchone("SELECT username FROM users WHERE username = ?", (target,))
    if not user:
        raise HTTPException(404, "User not found")
    await db.execute(
        "INSERT OR IGNORE INTO channel_members (channel_id, username, role, joined_at) VALUES (?,?,?,?)",
        (channel_id, target, "member", db.now())
    )
    return {"ok": True}


@router.delete("/channels/{channel_id}/members/{target}")
async def remove_member(channel_id: str, target: str, username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    # Себя может удалить любой (выход из группы); других — только owner/admin
    if target != username:
        if not mem or mem["role"] not in ("owner", "admin"):
            raise HTTPException(403, "Only owner/admin can remove members")
    await db.execute(
        "DELETE FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, target)
    )
    return {"ok": True}


@router.patch("/channels/{channel_id}/members/{target}/role")
async def update_member_role(channel_id: str, target: str, body: dict,
                             username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] != "owner":
        raise HTTPException(403, "Only owner can change roles")
    new_role = body.get("role", "member")
    if new_role not in ("admin", "member"):
        raise HTTPException(400, "Invalid role")
    await db.execute(
        "UPDATE channel_members SET role = ? WHERE channel_id = ? AND username = ?",
        (new_role, channel_id, target)
    )
    return {"ok": True}


# ── Сообщения ─────────────────────────────────────────────────────────────────

@router.get("/channels/{channel_id}/messages")
async def get_messages(channel_id: str, before: int = 0, limit: int = 50,
                       username: str = Depends(get_current_user)):
    _assert_member(await db.fetchone(
        "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    ))
    limit = min(limit, 100)
    if before:
        rows = await db.fetchall(
            "SELECT msg_id, from_username, display_name, body, sent_at, "
            "reply_to_msg_id "
            "FROM channel_messages WHERE channel_id = ? AND sent_at < ? AND deleted = 0 "
            "ORDER BY sent_at DESC LIMIT ?",
            (channel_id, before, limit)
        )
    else:
        rows = await db.fetchall(
            "SELECT msg_id, from_username, display_name, body, sent_at, "
            "reply_to_msg_id "
            "FROM channel_messages WHERE channel_id = ? AND deleted = 0 "
            "ORDER BY sent_at DESC LIMIT ?",
            (channel_id, limit)
        )
    return {"messages": list(reversed(rows))}


@router.post("/channels/{channel_id}/messages")
async def send_message(channel_id: str, req: SendChannelMsgRequest,
                       username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    _assert_member(mem)
    user = await db.fetchone("SELECT display_name FROM users WHERE username = ?", (username,))
    display_name = user["display_name"] if user else username
    now = db.now()
    await db.execute(
        "INSERT INTO channel_messages "
        "(channel_id, from_username, display_name, body, msg_id, sent_at, reply_to_msg_id) "
        "VALUES (?,?,?,?,?,?,?)",
        (channel_id, username, display_name, req.body, req.msg_id, now, req.reply_to_msg_id)
    )
    return {"ok": True, "sent_at": now}


@router.delete("/channels/{channel_id}/messages/{msg_id}")
async def delete_message(channel_id: str, msg_id: str, username: str = Depends(get_current_user)):
    msg = await db.fetchone(
        "SELECT from_username FROM channel_messages WHERE msg_id = ? AND channel_id = ?",
        (msg_id, channel_id)
    )
    if not msg:
        raise HTTPException(404, "Message not found")
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if msg["from_username"] != username and (not mem or mem["role"] not in ("owner", "admin")):
        raise HTTPException(403, "Cannot delete this message")
    await db.execute(
        "UPDATE channel_messages SET deleted = 1 WHERE msg_id = ?", (msg_id,)
    )
    return {"ok": True}


# ── Ключи шифрования ──────────────────────────────────────────────────────────

@router.get("/channels/{channel_id}/keys")
async def get_my_key(channel_id: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT wrapped_key FROM channel_keys WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not row:
        raise HTTPException(404, "No key found")
    return {"wrapped_key": row["wrapped_key"]}


@router.post("/channels/{channel_id}/keys")
async def set_keys(channel_id: str, req: SetWrappedKeyRequest,
                   username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] not in ("owner", "admin"):
        raise HTTPException(403, "Only owner/admin can distribute keys")
    for target_user, wrapped_key in req.wrapped_keys.items():
        await db.execute(
            "INSERT OR REPLACE INTO channel_keys (channel_id, username, wrapped_key) VALUES (?,?,?)",
            (channel_id, target_user, wrapped_key)
        )
    return {"ok": True}


# ── Заявки на вступление ─────────────────────────────────────────────────────

@router.get("/channels/{channel_id}/join_requests")
async def list_join_requests(channel_id: str, username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] not in ("owner", "admin"):
        raise HTTPException(403, "Only owner/admin")
    rows = await db.fetchall(
        "SELECT id, username, status, created_at FROM channel_join_requests "
        "WHERE channel_id = ? AND status = 'pending' ORDER BY created_at",
        (channel_id,)
    )
    return {"requests": rows}


@router.post("/channels/{channel_id}/join_requests")
async def request_join(channel_id: str, username: str = Depends(get_current_user)):
    ch = await db.fetchone("SELECT id, is_private FROM channels WHERE id = ?", (channel_id,))
    if not ch:
        raise HTTPException(404, "Channel not found")
    existing = await db.fetchone(
        "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if existing:
        raise HTTPException(409, "Already a member")
    if not ch["is_private"]:
        # Публичный — сразу добавляем
        await db.execute(
            "INSERT OR IGNORE INTO channel_members (channel_id, username, role, joined_at) VALUES (?,?,?,?)",
            (channel_id, username, "member", db.now())
        )
        return {"ok": True, "joined": True}
    await db.execute(
        "INSERT OR IGNORE INTO channel_join_requests (channel_id, username, status, created_at) "
        "VALUES (?,?,?,?)",
        (channel_id, username, "pending", db.now())
    )
    return {"ok": True, "joined": False, "pending": True}


@router.post("/channels/{channel_id}/join_requests/{request_id}")
async def handle_join_request(channel_id: str, request_id: int, req: JoinRequestAction,
                              username: str = Depends(get_current_user)):
    mem = await db.fetchone(
        "SELECT role FROM channel_members WHERE channel_id = ? AND username = ?",
        (channel_id, username)
    )
    if not mem or mem["role"] not in ("owner", "admin"):
        raise HTTPException(403, "Only owner/admin can handle requests")
    jr = await db.fetchone(
        "SELECT username FROM channel_join_requests WHERE id = ? AND channel_id = ?",
        (request_id, channel_id)
    )
    if not jr:
        raise HTTPException(404, "Request not found")
    if req.action == "approve":
        await db.execute(
            "INSERT OR IGNORE INTO channel_members (channel_id, username, role, joined_at) VALUES (?,?,?,?)",
            (channel_id, jr["username"], "member", db.now())
        )
        await db.execute(
            "UPDATE channel_join_requests SET status = 'approved' WHERE id = ?", (request_id,)
        )
    elif req.action == "reject":
        await db.execute(
            "UPDATE channel_join_requests SET status = 'rejected' WHERE id = ?", (request_id,)
        )
    else:
        raise HTTPException(400, "Invalid action")
    return {"ok": True}


# ── Реакции ───────────────────────────────────────────────────────────────────

FREE_EMOJIS = {"👍", "❤️", "😂", "😮", "😢", "🔥"}
FREE_MAX    = 1
PREM_MAX    = 5

@router.get("/reactions/{msg_id}")
async def get_reactions(msg_id: str, username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        "SELECT emoji, COUNT(*) as count FROM reactions WHERE msg_id = ? GROUP BY emoji",
        (msg_id,)
    )
    my = await db.fetchall(
        "SELECT emoji FROM reactions WHERE msg_id = ? AND username = ?",
        (msg_id, username)
    )
    return {"reactions": rows, "my": [r["emoji"] for r in my]}


@router.post("/reactions/{msg_id}")
async def toggle_reaction(msg_id: str, body: dict, username: str = Depends(get_current_user)):
    emoji = body.get("emoji", "")
    if not emoji:
        raise HTTPException(400, "Emoji required")

    user = await db.fetchone("SELECT is_premium FROM users WHERE username = ?", (username,))
    is_prem = bool(user and user["is_premium"])

    if not is_prem and emoji not in FREE_EMOJIS:
        raise HTTPException(403, "Premium required for custom reactions")

    # Проверить лимит
    existing = await db.fetchall(
        "SELECT emoji FROM reactions WHERE msg_id = ? AND username = ?",
        (msg_id, username)
    )
    already = next((r for r in existing if r["emoji"] == emoji), None)
    if already:
        # Убрать реакцию
        await db.execute(
            "DELETE FROM reactions WHERE msg_id = ? AND username = ? AND emoji = ?",
            (msg_id, username, emoji)
        )
        return {"ok": True, "removed": True}

    max_r = PREM_MAX if is_prem else FREE_MAX
    if len(existing) >= max_r:
        raise HTTPException(429, "Reaction limit reached")

    await db.execute(
        "INSERT OR IGNORE INTO reactions (msg_id, username, emoji, created_at) VALUES (?,?,?,?)",
        (msg_id, username, emoji, db.now())
    )
    return {"ok": True, "added": True}


# ── Утилиты ───────────────────────────────────────────────────────────────────

def _assert_member(row):
    if not row:
        raise HTTPException(403, "Not a member")
