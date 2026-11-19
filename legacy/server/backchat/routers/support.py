"""Чат поддержки: история, отправка."""
from __future__ import annotations
import uuid
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import database as db
from dependencies import get_current_user, require_admin

router = APIRouter(prefix="/api", tags=["support"])

class SupportMsgRequest(BaseModel):
    body:            str = Field(min_length=1, max_length=4000)
    reply_to_msg_id: str = ""


@router.get("/support/messages")
async def get_support_history(username: str = Depends(get_current_user)):
    rows = await db.fetchall(
        "SELECT msg_id, from_username, to_username, body, sent_at, direction, reply_to_msg_id "
        "FROM support_messages WHERE from_username = ? ORDER BY sent_at",
        (username,)
    )
    return {"messages": rows}


@router.post("/support/messages")
async def send_support_message(req: SupportMsgRequest, username: str = Depends(get_current_user)):
    msg_id = str(uuid.uuid4())
    now    = db.now()
    await db.execute(
        "INSERT INTO support_messages "
        "(from_username, to_username, body, msg_id, sent_at, reply_to_msg_id, direction, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (username, "support", req.body, msg_id, now, req.reply_to_msg_id, "in", now)
    )
    return {"ok": True, "msg_id": msg_id}


# ── Admin: отвечать в поддержку ───────────────────────────────────────────────

@router.get("/admin/support/messages")
async def admin_list_support(_: bool = Depends(require_admin)):
    rows = await db.fetchall(
        "SELECT msg_id, from_username, to_username, body, sent_at, direction "
        "FROM support_messages ORDER BY sent_at DESC LIMIT 500"
    )
    return {"messages": rows}


@router.get("/admin/support/users")
async def admin_list_support_users(_: bool = Depends(require_admin)):
    rows = await db.fetchall(
        "SELECT DISTINCT from_username, MAX(sent_at) as last_at "
        "FROM support_messages WHERE direction = 'in' GROUP BY from_username ORDER BY last_at DESC"
    )
    return {"users": rows}


@router.post("/admin/support/reply")
async def admin_reply_support(body: dict, _: bool = Depends(require_admin)):
    to_user = (body.get("to_username") or "").strip().lower()
    text    = (body.get("body") or "").strip()
    if not to_user or not text:
        raise HTTPException(400, "to_username and body required")
    msg_id = str(uuid.uuid4())
    now    = db.now()
    await db.execute(
        "INSERT INTO support_messages "
        "(from_username, to_username, body, msg_id, sent_at, reply_to_msg_id, direction, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        ("support", to_user, text, msg_id, now, body.get("reply_to_msg_id", ""), "out", now)
    )
    return {"ok": True, "msg_id": msg_id}
