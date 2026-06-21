"""Premium / Shop: тикеты оплаты, статус, настройки."""
from __future__ import annotations
import uuid
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

import database as db
from dependencies import get_current_user, require_admin, require_internal

router = APIRouter(prefix="/api", tags=["shop"])

# ── Модели ────────────────────────────────────────────────────────────────────

class CreateTicketRequest(BaseModel):
    payment_method: str = Field(max_length=32)
    amount_rub:     int = Field(ge=0)

class TicketMessageRequest(BaseModel):
    body: str = Field(min_length=1, max_length=2000)

class TicketAction(BaseModel):
    action: str   # approve | reject | close

class PremiumGrantRequest(BaseModel):
    gc_username: str
    grant:       bool = True

class ShopSettingRequest(BaseModel):
    key:   str
    value: str

# ── Тикеты (пользователь) ────────────────────────────────────────────────────

@router.post("/shop/tickets")
async def create_ticket(req: CreateTicketRequest, username: str = Depends(get_current_user)):
    # Проверить открытый тикет
    existing = await db.fetchone(
        "SELECT id FROM shop_tickets WHERE gc_username = ? AND status = 'open'",
        (username,)
    )
    if existing:
        raise HTTPException(409, "Already have an open ticket")

    ticket_id = str(uuid.uuid4())
    now = db.now()
    await db.execute(
        "INSERT INTO shop_tickets (ticket_id, gc_username, status, payment_method, amount_rub, created_at, updated_at) "
        "VALUES (?,?,?,?,?,?,?)",
        (ticket_id, username, "open", req.payment_method, req.amount_rub, now, now)
    )
    return {"ticket_id": ticket_id}


@router.get("/shop/tickets")
async def list_my_tickets(username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        "SELECT ticket_id, status, payment_method, amount_rub, created_at, updated_at "
        "FROM shop_tickets WHERE gc_username = ? ORDER BY created_at DESC",
        (username,)
    )
    return {"tickets": rows}


@router.get("/shop/tickets/{ticket_id}")
async def get_ticket(ticket_id: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT * FROM shop_tickets WHERE ticket_id = ? AND gc_username = ?",
        (ticket_id, username)
    )
    if not row:
        raise HTTPException(404, "Ticket not found")
    msgs = await db.fetchall(
        "SELECT sender, body, sent_at FROM shop_ticket_messages WHERE ticket_id = ? ORDER BY sent_at",
        (ticket_id,)
    )
    return {"ticket": row, "messages": msgs}


@router.post("/shop/tickets/{ticket_id}/messages")
async def send_ticket_message(ticket_id: str, req: TicketMessageRequest,
                              username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT status FROM shop_tickets WHERE ticket_id = ? AND gc_username = ?",
        (ticket_id, username)
    )
    if not row:
        raise HTTPException(404, "Ticket not found")
    if row["status"] not in ("open", "in_review"):
        raise HTTPException(400, "Ticket is closed")
    await db.execute(
        "INSERT INTO shop_ticket_messages (ticket_id, sender, body, sent_at) VALUES (?,?,?,?)",
        (ticket_id, username, req.body, db.now())
    )
    return {"ok": True}


# ── Настройки магазина (публичные) ───────────────────────────────────────────

@router.get("/shop/settings")
async def get_shop_settings():
    rows = await db.fetchall("SELECT key, value FROM shop_settings")
    return {r["key"]: r["value"] for r in rows}


# ── Внутренний API (shop_bot → server) ───────────────────────────────────────

@router.post("/internal/premium/grant")
async def grant_premium(req: PremiumGrantRequest, _: bool = Depends(require_internal)):
    user = await db.fetchone(
        "SELECT username FROM users WHERE username = ?", (req.gc_username,)
    )
    if not user:
        raise HTTPException(404, "User not found")
    await db.execute(
        "UPDATE users SET is_premium = ? WHERE username = ?",
        (1 if req.grant else 0, req.gc_username)
    )
    return {"ok": True, "is_premium": req.grant}


@router.post("/internal/ticket/{ticket_id}/action")
async def ticket_action_internal(ticket_id: str, req: TicketAction,
                                 _: bool = Depends(require_internal)):
    row = await db.fetchone(
        "SELECT gc_username FROM shop_tickets WHERE ticket_id = ?", (ticket_id,)
    )
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
        status = "rejected" if req.action == "reject" else "closed"
        await db.execute(
            "UPDATE shop_tickets SET status = ?, updated_at = ? WHERE ticket_id = ?",
            (status, now, ticket_id)
        )
    else:
        raise HTTPException(400, "Invalid action")
    return {"ok": True}


@router.post("/internal/ticket/{ticket_id}/messages")
async def ticket_message_internal(ticket_id: str, req: TicketMessageRequest,
                                  _: bool = Depends(require_internal)):
    await db.execute(
        "INSERT INTO shop_ticket_messages (ticket_id, sender, body, sent_at) VALUES (?,?,?,?)",
        (ticket_id, "support", req.body, db.now())
    )
    return {"ok": True}


@router.post("/internal/shop/settings")
async def set_shop_setting(req: ShopSettingRequest, _: bool = Depends(require_internal)):
    await db.execute(
        "INSERT OR REPLACE INTO shop_settings (key, value) VALUES (?,?)",
        (req.key, req.value)
    )
    return {"ok": True}


# ── Сайт: логин GhostChat ─────────────────────────────────────────────────────

@router.post("/site/login")
async def site_login(body: dict):
    """Логин через сайт — возвращает данные пользователя для отображения."""
    import security
    username = (body.get("username") or "").strip().lower()
    password = body.get("password") or ""
    if not username or not password:
        raise HTTPException(400, "username and password required")
    user = await db.fetchone(
        "SELECT username, display_name, argon2_hash, is_premium FROM users WHERE username = ?",
        (username,)
    )
    if not user or not security.verify_password(password, user["argon2_hash"]):
        raise HTTPException(401, "Invalid credentials")
    await db.execute(
        "INSERT INTO site_login_log (gc_username, logged_in_at) VALUES (?,?)",
        (username, db.now())
    )
    return {
        "username":     user["username"],
        "display_name": user["display_name"],
        "is_premium":   bool(user["is_premium"]),
    }
