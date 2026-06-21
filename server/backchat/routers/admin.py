"""Административные эндпоинты: статистика, управление пользователями, логи."""
from __future__ import annotations
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional

import database as db
from dependencies import require_admin

router = APIRouter(prefix="/api/admin", tags=["admin"])


# ── Пользователи ──────────────────────────────────────────────────────────────

@router.get("/users")
async def list_users(limit: int = 100, offset: int = 0, _: bool = Depends(require_admin)):
    rows = await db.fetchall(
        "SELECT username, display_name, is_premium, ghost_score, created_at "
        "FROM users ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (min(limit, 500), offset)
    )
    total = await db.fetchone("SELECT COUNT(*) as cnt FROM users")
    return {"users": rows, "total": total["cnt"] if total else 0}


@router.get("/users/{username}")
async def get_user_admin(username: str, _: bool = Depends(require_admin)):
    row = await db.fetchone(
        "SELECT username, display_name, about, is_premium, ghost_score, "
        "screen_block, glow_color, avatar_bg_color, created_at "
        "FROM users WHERE username = ?",
        (username,)
    )
    if not row:
        raise HTTPException(404, "User not found")
    devices = await db.fetchall(
        "SELECT device_id, device_name, trust_type, trust_level, blocked, registered_at "
        "FROM device_registry WHERE username = ? ORDER BY registered_at DESC",
        (username,)
    )
    return {"user": row, "devices": devices}


class AdminUserUpdate(BaseModel):
    is_premium:   Optional[bool] = None
    ghost_score:  Optional[int]  = None
    screen_block: Optional[bool] = None

@router.patch("/users/{username}")
async def update_user_admin(username: str, req: AdminUserUpdate, _: bool = Depends(require_admin)):
    fields, vals = [], []
    if req.is_premium   is not None: fields.append("is_premium = ?");   vals.append(1 if req.is_premium else 0)
    if req.ghost_score  is not None: fields.append("ghost_score = ?");  vals.append(req.ghost_score)
    if req.screen_block is not None: fields.append("screen_block = ?"); vals.append(1 if req.screen_block else 0)
    if not fields:
        return {"ok": True}
    vals.append(username)
    await db.execute(f"UPDATE users SET {', '.join(fields)} WHERE username = ?", tuple(vals))
    return {"ok": True}


@router.delete("/users/{username}")
async def delete_user_admin(username: str, _: bool = Depends(require_admin)):
    await db.execute("DELETE FROM contacts WHERE user_a = ? OR user_b = ?", (username, username))
    await db.execute("DELETE FROM device_registry WHERE username = ?", (username,))
    await db.execute("DELETE FROM pending_logins WHERE username = ?", (username,))
    await db.execute("DELETE FROM messages WHERE from_username = ? OR to_username = ?", (username, username))
    await db.execute("DELETE FROM channel_members WHERE username = ?", (username,))
    await db.execute("DELETE FROM users WHERE username = ?", (username,))
    return {"ok": True}


# ── Устройства ────────────────────────────────────────────────────────────────

@router.delete("/devices/{username}/{device_id}")
async def block_device_admin(username: str, device_id: str, _: bool = Depends(require_admin)):
    await db.execute(
        "UPDATE device_registry SET blocked = 1 WHERE username = ? AND device_id = ?",
        (username, device_id)
    )
    return {"ok": True}


# ── Каналы ────────────────────────────────────────────────────────────────────

@router.get("/channels")
async def list_channels_admin(limit: int = 100, offset: int = 0, _: bool = Depends(require_admin)):
    rows = await db.fetchall(
        "SELECT id, name, tag, type, is_private, creator, created_at, "
        "(SELECT COUNT(*) FROM channel_members cm WHERE cm.channel_id = channels.id) as member_count "
        "FROM channels ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (min(limit, 500), offset)
    )
    total = await db.fetchone("SELECT COUNT(*) as cnt FROM channels")
    return {"channels": rows, "total": total["cnt"] if total else 0}


@router.delete("/channels/{channel_id}")
async def delete_channel_admin(channel_id: str, _: bool = Depends(require_admin)):
    await db.execute("DELETE FROM channel_messages WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_members WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_keys WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channel_join_requests WHERE channel_id = ?", (channel_id,))
    await db.execute("DELETE FROM channels WHERE id = ?", (channel_id,))
    return {"ok": True}


# ── Статистика ────────────────────────────────────────────────────────────────

@router.get("/stats")
async def get_stats(_: bool = Depends(require_admin)):
    users     = await db.fetchone("SELECT COUNT(*) as cnt FROM users")
    premium   = await db.fetchone("SELECT COUNT(*) as cnt FROM users WHERE is_premium = 1")
    channels  = await db.fetchone("SELECT COUNT(*) as cnt FROM channels")
    devices   = await db.fetchone("SELECT COUNT(*) as cnt FROM device_registry WHERE blocked = 0")
    tickets   = await db.fetchone("SELECT COUNT(*) as cnt FROM shop_tickets WHERE status = 'open'")
    files     = await db.fetchone("SELECT COUNT(*) as cnt, COALESCE(SUM(file_size),0) as sz FROM pending_files")
    visitors  = await db.fetchone("SELECT COUNT(*) as cnt FROM site_visitors")
    downloads = await db.fetchone("SELECT COUNT(*) as cnt FROM site_visitors WHERE downloaded_at > 0")

    return {
        "users":            users["cnt"]     if users     else 0,
        "premium_users":    premium["cnt"]   if premium   else 0,
        "channels":         channels["cnt"]  if channels  else 0,
        "active_devices":   devices["cnt"]   if devices   else 0,
        "open_tickets":     tickets["cnt"]   if tickets   else 0,
        "pending_files":    files["cnt"]     if files     else 0,
        "pending_files_mb": round(files["sz"] / 1048576, 2) if files else 0,
        "site_visitors":    visitors["cnt"]  if visitors  else 0,
        "apk_downloads":    downloads["cnt"] if downloads else 0,
    }


# ── Тикеты (admin) ────────────────────────────────────────────────────────────

@router.get("/shop/tickets")
async def list_tickets_admin(status: str = "open", _: bool = Depends(require_admin)):
    rows = await db.fetchall(
        "SELECT ticket_id, gc_username, status, payment_method, amount_rub, created_at, updated_at "
        "FROM shop_tickets WHERE status = ? ORDER BY created_at DESC LIMIT 200",
        (status,)
    )
    return {"tickets": rows}


@router.get("/shop/tickets/{ticket_id}")
async def get_ticket_admin(ticket_id: str, _: bool = Depends(require_admin)):
    row = await db.fetchone("SELECT * FROM shop_tickets WHERE ticket_id = ?", (ticket_id,))
    if not row:
        raise HTTPException(404, "Ticket not found")
    msgs = await db.fetchall(
        "SELECT sender, body, sent_at FROM shop_ticket_messages WHERE ticket_id = ? ORDER BY sent_at",
        (ticket_id,)
    )
    return {"ticket": row, "messages": msgs}


class AdminTicketAction(BaseModel):
    action: str  # approve | reject | close

@router.post("/shop/tickets/{ticket_id}/action")
async def ticket_action_admin(ticket_id: str, req: AdminTicketAction, _: bool = Depends(require_admin)):
    row = await db.fetchone("SELECT gc_username FROM shop_tickets WHERE ticket_id = ?", (ticket_id,))
    if not row:
        raise HTTPException(404, "Ticket not found")
    now = db.now()
    if req.action == "approve":
        await db.execute(
            "UPDATE shop_tickets SET status = 'approved', updated_at = ? WHERE ticket_id = ?",
            (now, ticket_id)
        )
        await db.execute(
            "UPDATE users SET is_premium = 1 WHERE username = ?", (row["gc_username"],)
        )
    elif req.action in ("reject", "close"):
        st = "rejected" if req.action == "reject" else "closed"
        await db.execute(
            "UPDATE shop_tickets SET status = ?, updated_at = ? WHERE ticket_id = ?",
            (st, now, ticket_id)
        )
    else:
        raise HTTPException(400, "Invalid action")
    return {"ok": True}


# ── Статистика сайта ──────────────────────────────────────────────────────────

@router.post("/site/visitor")
async def record_visitor(body: dict, _: bool = Depends(require_admin)):
    """Зафиксировать посетителя сайта (без IP, только анонимный visitor_id)."""
    vid = (body.get("visitor_id") or "").strip()
    if not vid:
        raise HTTPException(400, "visitor_id required")
    now = db.now()
    await db.execute(
        "INSERT OR IGNORE INTO site_visitors (visitor_id, first_seen_at) VALUES (?,?)",
        (vid, now)
    )
    if body.get("downloaded"):
        await db.execute(
            "UPDATE site_visitors SET downloaded_at = ?, downloaded_version = ?, is_update = ? "
            "WHERE visitor_id = ?",
            (now, body.get("version", ""), 1 if body.get("is_update") else 0, vid)
        )
    if body.get("skipped"):
        await db.execute(
            "UPDATE site_visitors SET skipped = 1 WHERE visitor_id = ?", (vid,)
        )
    return {"ok": True}
