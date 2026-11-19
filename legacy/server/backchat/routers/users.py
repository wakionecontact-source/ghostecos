"""Профили, контакты, поиск пользователей."""
from __future__ import annotations
import json
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

import database as db
from dependencies import get_current_user, get_current_user_optional

router = APIRouter(prefix="/api", tags=["users"])

# ── Модели ────────────────────────────────────────────────────────────────────

class ProfileUpdate(BaseModel):
    display_name:       Optional[str] = Field(None, max_length=64)
    about:              Optional[str] = Field(None, max_length=256)
    x25519_pub:         Optional[str] = None
    ed25519_pub:        Optional[str] = None
    glow_color:         Optional[str] = Field(None, max_length=16)
    avatar_bg_color:    Optional[str] = Field(None, max_length=16)
    pinned_channel_tag: Optional[str] = Field(None, max_length=32)
    screen_block:       Optional[bool] = None

class ContactAdd(BaseModel):
    username:          Optional[str] = None  # POST /api/contacts
    contact_username:  Optional[str] = None  # POST /api/contacts/add (legacy)

# ── Профиль ───────────────────────────────────────────────────────────────────

@router.get("/user/{username}")
async def get_user(username: str, me: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT username, display_name, about, x25519_pub, ed25519_pub, "
        "is_premium, glow_color, avatar_bg_color, pinned_channel_tag, ghost_score "
        "FROM users WHERE username = ?",
        (username.strip().lower(),)
    )
    if not row:
        raise HTTPException(404, "User not found")
    return row


@router.get("/public/user/{username}")
async def get_user_public(username: str):
    """Публичный профиль — без авторизации."""
    row = await db.fetchone(
        "SELECT username, display_name, about, is_premium, glow_color, avatar_bg_color "
        "FROM users WHERE username = ?",
        (username.strip().lower(),)
    )
    if not row:
        raise HTTPException(404, "User not found")
    return row


@router.post("/profile")
async def update_profile(req: ProfileUpdate, username: str = Depends(get_current_user)):
    fields, vals = [], []
    if req.display_name       is not None: fields.append("display_name = ?");        vals.append(req.display_name.strip())
    if req.about              is not None: fields.append("about = ?");               vals.append(req.about.strip())
    if req.x25519_pub         is not None: fields.append("x25519_pub = ?");          vals.append(req.x25519_pub)
    if req.ed25519_pub        is not None: fields.append("ed25519_pub = ?");         vals.append(req.ed25519_pub)
    if req.glow_color         is not None: fields.append("glow_color = ?");          vals.append(req.glow_color)
    if req.avatar_bg_color    is not None: fields.append("avatar_bg_color = ?");     vals.append(req.avatar_bg_color)
    if req.pinned_channel_tag is not None: fields.append("pinned_channel_tag = ?");  vals.append(req.pinned_channel_tag)
    if req.screen_block       is not None: fields.append("screen_block = ?");        vals.append(1 if req.screen_block else 0)
    if not fields:
        return {"ok": True}
    vals.append(username)
    await db.execute(
        f"UPDATE users SET {', '.join(fields)} WHERE username = ?",
        tuple(vals)
    )
    return {"ok": True}


# ── Контакты ──────────────────────────────────────────────────────────────────

@router.get("/contacts")
async def list_contacts(username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        """SELECT u.username, u.display_name, u.about, u.x25519_pub, u.ed25519_pub,
                  u.is_premium, u.glow_color, u.avatar_bg_color
           FROM contacts c
           JOIN users u ON u.username = c.user_b
           WHERE c.user_a = ?
           ORDER BY u.display_name""",
        (username,)
    )
    return {"contacts": rows}


async def _do_add_contact(username: str, target: str):
    if not target:
        raise HTTPException(400, "username required")
    target = target.strip().lower()
    if target == username:
        raise HTTPException(400, "Cannot add yourself")
    user = await db.fetchone("SELECT username FROM users WHERE username = ?", (target,))
    if not user:
        raise HTTPException(404, "User not found")
    now = db.now()
    await db.execute(
        "INSERT OR IGNORE INTO contacts (user_a, user_b, created_at) VALUES (?,?,?)",
        (username, target, now)
    )
    await db.execute(
        "INSERT OR IGNORE INTO contacts (user_a, user_b, created_at) VALUES (?,?,?)",
        (target, username, now)
    )
    return {"ok": True}

@router.post("/contacts")
async def add_contact(req: ContactAdd, username: str = Depends(get_current_user)):
    target = req.username or req.contact_username or ""
    return await _do_add_contact(username, target)

@router.post("/contacts/add")
async def add_contact_legacy(req: ContactAdd, username: str = Depends(get_current_user)):
    """Legacy alias для /api/contacts/add."""
    target = req.contact_username or req.username or ""
    return await _do_add_contact(username, target)


@router.delete("/contacts/{target}")
async def remove_contact(target: str, username: str = Depends(get_current_user)):
    target = target.strip().lower()
    await db.execute(
        "DELETE FROM contacts WHERE (user_a = ? AND user_b = ?) OR (user_a = ? AND user_b = ?)",
        (username, target, target, username)
    )
    return {"ok": True}


@router.delete("/account")
async def delete_account(username: str = Depends(get_current_user)):
    """Полное удаление аккаунта пользователя."""
    await db.execute("DELETE FROM contacts WHERE user_a = ? OR user_b = ?", (username, username))
    await db.execute("DELETE FROM device_registry WHERE username = ?", (username,))
    await db.execute("DELETE FROM pending_logins WHERE username = ?", (username,))
    await db.execute("DELETE FROM messages WHERE from_username = ? OR to_username = ?", (username, username))
    await db.execute("DELETE FROM channel_members WHERE username = ?", (username,))
    await db.execute("DELETE FROM channel_keys WHERE username = ?", (username,))
    await db.execute("DELETE FROM reactions WHERE username = ?", (username,))
    await db.execute("DELETE FROM support_messages WHERE from_username = ?", (username,))
    await db.execute("DELETE FROM users WHERE username = ?", (username,))
    return {"ok": True}
