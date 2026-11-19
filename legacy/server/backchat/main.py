"""
GhostChat Relay Server  v1.9
============================
REST:
  POST /api/register
  POST /api/login
  GET  /api/user/{username}
  POST /api/profile
  POST /api/contacts
  GET  /api/contacts

WebSocket:
  WS /ws  — auth, relay_message, relay_ack, relay_seen,
             peer_online/offline (server-push), ping/pong

Changes v1.4:
  - Heartbeat system: clients ping every 10s; server marks offline after 15s silence.
  - Background task checks every 5s for stale connections.
  - _last_ping tracks last activity time per user.

Changes v1.3:
  - Server sends relay_ack to sender immediately upon message relay/store.
  - Server pushes peer_online to all contacts on connect.
  - Server pushes peer_offline to all contacts on disconnect.
  - Server pushes peer_online events for online contacts to newly connected user.
"""
import asyncio
import collections
import json
import logging
import time
from typing import Dict, Optional

import jwt
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Depends, Request, UploadFile, File, Form

# Подключение роутера GhostSocial


from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, ConfigDict
import hashlib
import os as _os

import db
import auth as _auth
from state_machine import server_state, ClientState, MsgRelayState, FileState

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("ghostchat")

_disable_docs = _os.environ.get("GHOSTCHAT_DISABLE_DOCS", "").lower() in ("1", "true", "yes")
app = FastAPI(

    title="GhostChat Relay Server",
    docs_url=None if _disable_docs else "/docs",
    redoc_url=None if _disable_docs else "/redoc",
    openapi_url=None if _disable_docs else "/openapi.json",
)
if _disable_docs:
    log.info("OpenAPI /docs /redoc disabled (GHOSTCHAT_DISABLE_DOCS)")

_SUPPORT_PASSWORD = _os.environ.get("GHOSTCHAT_SUPPORT_PASSWORD", "PER56712348727")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# username → WebSocket (active connections)
_online: Dict[str, WebSocket] = {}
# usernames that are connected but app is in background (messages delivered, not shown as online)
_background: set = set()
# username → last activity timestamp (for heartbeat)
_last_ping: Dict[str, float] = {}
# username → device_id for current WS session
_ws_device_id: Dict[str, str] = {}
# username → current client IP (updated on auth + each ping)
_ws_ip: Dict[str, str] = {}

_HEARTBEAT_TIMEOUT = 15  # seconds of silence before marking offline

# ── File relay constants ───────────────────────────────────────────────────
UPLOAD_DIR       = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "uploads")
FILE_EXPIRE_SECS = 1800          # 30 minutes
FILE_MAX_BYTES   = 100 * 1024 * 1024  # 100 MB
_os.makedirs(UPLOAD_DIR, exist_ok=True)

# ── Rate limiting ─────────────────────────────────────────────────────────
# ip → deque of attempt timestamps
_login_attempts: Dict[str, collections.deque] = {}
_RATE_WINDOW   = 60    # seconds
_RATE_MAX_LOGIN    = 10   # max login attempts per IP per window
_RATE_MAX_REGISTER = 5    # max register attempts per IP per window
_RATE_MAX_LOGIN_REQUEST = 60  # unauthenticated login_request poll endpoints per IP per window

def _check_rate_limit(ip: str, bucket: Dict[str, collections.deque], max_req: int):
    now = time.time()
    q   = bucket.setdefault(ip, collections.deque())
    # Drop old entries outside window
    while q and now - q[0] > _RATE_WINDOW:
        q.popleft()
    if len(q) >= max_req:
        raise HTTPException(429, detail={"error": "too_many_requests"})
    q.append(now)

_register_attempts: Dict[str, collections.deque] = {}
_login_request_attempts: Dict[str, collections.deque] = {}

# login_request IDs are UUIDs; reject huge / unicode paths (DoS)
_REQUEST_ID_MAX_LEN = 64
_REQUEST_ID_ALLOWED = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
)


def _validate_request_id(request_id: str) -> None:
    if not request_id or len(request_id) > _REQUEST_ID_MAX_LEN:
        raise HTTPException(400, detail={"error": "invalid_request_id"})
    if not all(c in _REQUEST_ID_ALLOWED for c in request_id):
        raise HTTPException(400, detail={"error": "invalid_request_id"})


def _rate_limit_login_request_ip(request: Request) -> None:
    ip = request.client.host if request.client else ""
    _check_rate_limit(ip, _login_request_attempts, _RATE_MAX_LOGIN_REQUEST)

bearer = HTTPBearer(auto_error=False)


def _require_auth(
        creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> str:
    if not creds:
        raise HTTPException(401, "Missing token")
    try:
        return _auth.decode_token(creds.credentials)
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid token")


# ── REST ──────────────────────────────────────────────────────────────────


class RegisterRequest(BaseModel):
    username:     str
    display_name: str
    password:     str
    x25519_pub:   str = ""
    ed25519_pub:  str = ""


class LoginRequest(BaseModel):
    username:    str
    password:    str
    device_id:   str = ""
    device_name: str = ""


class LoginApproveRequest(BaseModel):
    request_id: str

class LoginKeyRequest(BaseModel):
    request_id: str
    key:        str

class LoginStatusRequest(BaseModel):
    request_id: str


class LoginCodeVerifyBody(BaseModel):
    matches: bool
    model_config = ConfigDict(extra="forbid")


class ProfileRequest(BaseModel):
    display_name: Optional[str] = None
    about:        Optional[str] = None
    x25519_pub:   Optional[str] = None
    ed25519_pub:  Optional[str] = None
    screen_block: Optional[bool] = None


class AddContactRequest(BaseModel):
    username: str


class CreateChannelRequest(BaseModel):
    name:        str
    tag:         str
    description: str  = ""
    type:        str  = "group"   # 'channel' or 'group'
    is_private:  bool = False

class UpdateChannelRequest(BaseModel):
    is_private:  bool | None = None
    description: str  | None = None

class SetChannelKeyRequest(BaseModel):
    username:    str
    wrapped_key: str

class ApproveJoinRequest(BaseModel):
    wrapped_key: str  # group key wrapped for new member (empty for public channels)


@app.post("/api/register")
async def register(req: RegisterRequest, request: Request):
    _check_rate_limit(request.client.host, _register_attempts, _RATE_MAX_REGISTER)
    if len(req.username) < 3 or len(req.username) > 32:
        raise HTTPException(400, detail={"error": "invalid_username"})
    if not req.username.replace("_", "").isalnum():
        raise HTTPException(400, detail={"error": "invalid_username"})
    if len(req.password) < 6:
        raise HTTPException(400, detail={"error": "password_too_short"})
    if db.user_exists(req.username):
        raise HTTPException(409, detail={"error": "username_taken"})
    h   = _auth.hash_password(req.password)
    uid = db.create_user(
        username=req.username,
        display_name=req.display_name or req.username,
        argon2_hash=h,
        x25519_pub=req.x25519_pub,
        ed25519_pub=req.ed25519_pub,
    )
    log.info("register: user=%s id=%d", req.username, uid)
    return {"ok": True, "user_id": uid}


@app.post("/api/login")
async def login(req: LoginRequest, request: Request):
    _check_rate_limit(request.client.host, _login_attempts, _RATE_MAX_LOGIN)
    row = db.get_user(req.username)
    if not row or not _auth.verify_password(row["argon2_hash"], req.password):
        raise HTTPException(401, detail={"error": "invalid_credentials"})

    device_id   = req.device_id.strip()
    device_name = req.device_name.strip() or "Unknown device"
    client_ip   = request.client.host

    # No device_id → old client, just login
    if not device_id:
        token = _auth.make_token(req.username)
        return {"token": token, "user_id": row["id"], "status": "ok"}

    # Device permanently blocked
    if db.is_device_blocked(req.username, device_id):
        raise HTTPException(403, detail={"error": "device_blocked"})

    # Already registered device → normal login
    if db.is_device_registered(req.username, device_id):
        db.register_device(req.username, device_id, device_name)
        token = _auth.make_token(req.username)
        log.info("login: user=%s device=%s (known)", req.username, device_id[:8])
        return {"token": token, "user_id": row["id"], "status": "ok"}

    # New device — check if there are existing devices to approve
    dev_count = db.get_user_device_count(req.username)
    if dev_count == 0:
        db.register_device(req.username, device_id, device_name, trust_type='creator')
        token = _auth.make_token(req.username)
        log.info("login: user=%s first_device=%s", req.username, device_id[:8])
        return {"token": token, "user_id": row["id"], "status": "ok"}

    # Cancel old pending for this device, create new one
    db.cancel_pending_for_device(req.username, device_id)
    import uuid as _uuid
    request_id = str(_uuid.uuid4())
    db.create_pending_login(request_id, req.username, device_id, device_name, client_ip)

    # Notify all online devices of this user
    msg = {
        "type":        "login_request",
        "request_id":  request_id,
        "device_id":   device_id,
        "device_name": device_name,
        "client_ip":   client_ip,
        "created_at":  int(__import__("time").time()),
    }
    notified = 0
    for uname, ws in list(_online.items()):
        if uname == req.username:
            try:
                await _send(ws, msg)
                notified += 1
                db.set_pending_notified(request_id)  # timer starts now
            except Exception:
                pass

    log.info("login_request: user=%s device=%s notified=%d", req.username, device_id[:8], notified)
    return {"status": "pending", "request_id": request_id, "user_id": row["id"]}


@app.get("/api/login_request/{request_id}")
async def login_request_status(request_id: str, request: Request):
    """Polled by the new device every 2s to check approval state."""
    _rate_limit_login_request_ip(request)
    _validate_request_id(request_id)
    row = db.get_pending_login(request_id)
    if not row:
        return {"status": "not_found"}
    phase = row["phase"]
    now   = int(__import__("time").time())

    # Always deliver success even if technically expired
    if phase == "success":
        token = _auth.make_token(row["username"])
        db.register_device(row["username"], row["device_id"], row["device_name"])
        db.delete_pending_login(request_id)
        return {"status": "ok", "token": token}

    # Check expiry (timer started after first device notified)
    if row["expires_at"] > 0 and row["expires_at"] < now:
        return {"status": "expired"}

    if phase == "denied":
        return {"status": "denied"}
    if phase == "blocked":
        return {"status": "blocked"}
    if phase == "code_phase":
        # Tell new device to generate code
        return {"status": "code_phase"}
    if phase == "verify_phase":
        # Tell new device what code the approver submitted (encrypted in transit)
        return {"status": "verify_phase", "submitted_code": row["submitted_code"]}
    return {"status": "pending"}


@app.get("/api/my_pending_logins")
async def my_pending_logins(me: str = Depends(_require_auth)):
    """Approving device polls this to find pending login requests."""
    rows = db.get_my_pending_logins(me)
    result = []
    now = int(__import__("time").time())
    for row in rows:
        phase = row["phase"]
        if phase in ("denied", "blocked", "success"):
            continue
        if row["expires_at"] > 0 and row["expires_at"] < now:
            continue
        result.append({
            "request_id":  row["request_id"],
            "device_id":   row["device_id"],
            "device_name": row["device_name"],
            "client_ip":   row["client_ip"],
            "phase":       phase,
            "created_at":  row["created_at"],
            "attempts_left": 5 - row["attempt_count"],
        })
    return {"requests": result}


@app.post("/api/login_request/{request_id}/code_ready")
async def login_code_ready(request_id: str, request: Request):
    """New device reports it generated a code. Notify approving devices."""
    _rate_limit_login_request_ip(request)
    _validate_request_id(request_id)
    row = db.get_pending_login(request_id)
    if not row or row["phase"] != "code_phase":
        return {"ok": False}
    # Notify approving devices
    msg = {"type": "code_ready_notify", "request_id": request_id,
           "attempts_left": 5 - row["attempt_count"]}
    for uname, ws in list(_online.items()):
        if uname == row["username"]:
            try:
                await _send(ws, msg)
            except Exception:
                pass
    return {"ok": True}


@app.post("/api/login_request/{request_id}/code_verify")
async def login_code_verify(request_id: str, body: LoginCodeVerifyBody, request: Request):
    """New device reports whether the submitted code matched."""
    _rate_limit_login_request_ip(request)
    _validate_request_id(request_id)
    row = db.get_pending_login(request_id)
    if not row or row["phase"] != "verify_phase":
        return {"ok": False}
    matches = body.matches
    username = row["username"]
    if matches:
        db.set_pending_phase(request_id, "success")
        log.info("login_verify: success for %s device=%s", username, row["device_id"][:8])
        # Notify approving devices
        for uname, ws in list(_online.items()):
            if uname == username:
                try:
                    await _send(ws, {"type": "login_confirmed", "request_id": request_id,
                                     "device_name": row["device_name"]})
                except Exception:
                    pass
        return {"ok": True, "result": "success"}
    else:
        count = db.increment_attempt(request_id)
        if count >= 5:
            db.set_pending_phase(request_id, "denied")
            for uname, ws in list(_online.items()):
                if uname == username:
                    try:
                        await _send(ws, {"type": "login_denied_notify", "request_id": request_id,
                                         "reason": "max_attempts"})
                    except Exception:
                        pass
            return {"ok": True, "result": "denied"}
        else:
            # Reset to code_phase for retry
            db.set_pending_phase(request_id, "code_phase")
            attempts_left = 5 - count
            for uname, ws in list(_online.items()):
                if uname == username:
                    try:
                        await _send(ws, {"type": "code_wrong_notify", "request_id": request_id,
                                         "attempts_left": attempts_left})
                    except Exception:
                        pass
            return {"ok": True, "result": "wrong", "attempts_left": attempts_left}


@app.get("/api/user/{username}")
async def get_user(username: str, me: str = Depends(_require_auth)):
    row = db.get_user(username)
    if not row:
        raise HTTPException(404, detail={"error": "not_found"})
    share_keys = username == me or db.are_contacts(me, username)
    return {
        "user_id":      row["id"],
        "username":     row["username"],
        "display_name": row["display_name"],
        "about":        row["about"],
        "x25519_pub":   row["x25519_pub"] if share_keys else "",
        "ed25519_pub":  row["ed25519_pub"] if share_keys else "",
        "screen_block": bool(row["screen_block"]),
    }


@app.post("/api/contacts")
async def add_contact(req: AddContactRequest,
                      me: str = Depends(_require_auth)):
    target_username = req.username.lstrip("@").strip()
    if not target_username or target_username == me:
        raise HTTPException(400, detail={"error": "invalid_username"})
    target = db.get_user(target_username)
    if not target:
        raise HTTPException(404, detail={"error": "not_found"})
    db.add_contact(me, target_username)

    # Notify target if online
    target_ws = _online.get(target_username)
    if target_ws:
        me_row = db.get_user(me)
        await _send(target_ws, {
            "type":         "contact_added",
            "username":     me,
            "display_name": me_row["display_name"] if me_row else me,
            "x25519_pub":   me_row["x25519_pub"]   if me_row else "",
            "ed25519_pub":  me_row["ed25519_pub"]   if me_row else "",
        })
        # Also tell the requester that target is online right now
        me_ws = _online.get(me)
        if me_ws:
            await _send(me_ws, {
                "type":     "peer_online",
                "username": target_username,
            })

    log.info("add_contact: %s -> %s", me, target_username)
    return {
        "ok": True,
        "user": {
            "username":     target["username"],
            "display_name": target["display_name"],
            "about":        target["about"],
            "x25519_pub":   target["x25519_pub"],
            "ed25519_pub":  target["ed25519_pub"],
        },
    }


@app.get("/api/contacts")
async def get_contacts(me: str = Depends(_require_auth)):
    usernames = db.get_contacts(me)
    result = []
    for username in usernames:
        row = db.get_user(username)
        if row:
            result.append({
                "username":     row["username"],
                "display_name": row["display_name"],
                "about":        row["about"],
                "x25519_pub":   row["x25519_pub"],
                "ed25519_pub":  row["ed25519_pub"],
            })
    return {"contacts": result}


@app.post("/api/profile")
async def update_profile(req: ProfileRequest,
                         me: str = Depends(_require_auth)):
    data = req.model_dump()
    # Handle screen_block separately (not in update_user whitelist)
    if data.get('screen_block') is not None:
        db.set_screen_block(me, data.pop('screen_block'))
    else:
        data.pop('screen_block', None)
    kwargs = {k: v for k, v in data.items() if v is not None}
    if kwargs:
        db.update_user(me, **kwargs)
    return {"ok": True}


# ── Channels REST ──────────────────────────────────────────────────────────

import uuid as _uuid_mod


import re as _re

@app.post("/api/channels")
async def create_channel(req: CreateChannelRequest, me: str = Depends(_require_auth)):
    name = req.name.strip()
    tag  = req.tag.strip().lower().lstrip('@')
    if not name:
        raise HTTPException(400, "name required")
    if not tag:
        raise HTTPException(400, "tag required")
    if not _re.fullmatch(r'[a-z0-9_]{3,32}', tag):
        raise HTTPException(400, "tag_invalid")  # 3-32 chars, lowercase a-z, 0-9, _
    if req.type not in ("channel", "group"):
        raise HTTPException(400, "type must be 'channel' or 'group'")
    cid = str(_uuid_mod.uuid4())
    try:
        db.create_channel(cid, name, tag, req.description.strip(), req.type, me,
                          is_private=req.is_private)
    except Exception:
        raise HTTPException(409, "name_or_tag_taken")
    return {"channel": {"id": cid, "name": name, "tag": tag, "description": req.description,
                        "type": req.type, "is_private": req.is_private,
                        "creator": me, "member_count": 1, "role": "admin"}}


@app.get("/api/channels")
async def list_channels(q: str = "", me: str = Depends(_require_auth)):
    rows = db.get_all_channels(query=q)
    return {"channels": [
        {"id": r["id"], "name": r["name"], "tag": r["tag"], "description": r["description"],
         "type": r["type"], "is_private": bool(r["is_private"]),
         "creator": r["creator"], "member_count": r["member_count"]}
        for r in rows
    ]}


@app.get("/api/channels/my")
async def my_channels(me: str = Depends(_require_auth)):
    rows = db.get_user_channels(me)
    return {"channels": [
        {"id": r["id"], "name": r["name"], "tag": r["tag"], "description": r["description"],
         "type": r["type"], "is_private": bool(r["is_private"]),
         "creator": r["creator"], "member_count": r["member_count"], "role": r["role"]}
        for r in rows
    ]}


@app.get("/api/channels/{channel_id}")
async def get_channel_info(channel_id: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    member = db.get_channel_member(channel_id, me)
    return {"id": ch["id"], "name": ch["name"], "tag": ch["tag"],
            "description": ch["description"],
            "type": ch["type"], "is_private": bool(ch["is_private"]),
            "creator": ch["creator"],
            "member_count": db.get_channel_member_count(channel_id),
            "role": member["role"] if member else None}


@app.patch("/api/channels/{channel_id}")
async def update_channel(channel_id: str, req: UpdateChannelRequest,
                          me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    kwargs = {}
    if req.is_private is not None:
        kwargs["is_private"] = int(req.is_private)
    if req.description is not None:
        kwargs["description"] = req.description.strip()
    if kwargs:
        db.update_channel(channel_id, **kwargs)
    return {"ok": True}


@app.post("/api/channels/{channel_id}/join")
async def join_channel(channel_id: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["is_private"]:
        # For private channels, create a join request instead
        existing = db.get_join_request(channel_id, me)
        if existing:
            return {"status": existing["status"]}
        db.create_join_request(channel_id, me)
        # Notify creator via WS if online
        creator = ch["creator"]
        if creator in _connections:
            await _send(_connections[creator], {
                "type": "join_request",
                "channel_id": channel_id,
                "channel_name": ch["name"],
                "username": me,
            })
        return {"status": "pending"}
    db.add_channel_member(channel_id, me)
    return {"ok": True, "status": "joined"}


@app.get("/api/channels/{channel_id}/join_requests")
async def get_join_requests(channel_id: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    rows = db.get_join_requests(channel_id)
    return {"requests": [
        {"username": r["username"], "display_name": r["display_name"] or r["username"],
         "created_at": r["created_at"]}
        for r in rows
    ]}


@app.post("/api/channels/{channel_id}/approve/{username}")
async def approve_join(channel_id: str, username: str, req: ApproveJoinRequest,
                        me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    rq = db.get_join_request(channel_id, username)
    if not rq or rq["status"] != "pending":
        raise HTTPException(404, "request_not_found")
    db.update_join_request(channel_id, username, "approved")
    db.add_channel_member(channel_id, username)
    if req.wrapped_key:
        db.set_channel_key(channel_id, username, req.wrapped_key)
    # Notify approved user
    if username in _connections:
        await _send(_connections[username], {
            "type": "join_approved",
            "channel_id": channel_id,
            "channel_name": ch["name"],
        })
    return {"ok": True}


@app.post("/api/channels/{channel_id}/reject/{username}")
async def reject_join(channel_id: str, username: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    db.update_join_request(channel_id, username, "rejected")
    if username in _connections:
        await _send(_connections[username], {
            "type": "join_rejected",
            "channel_id": channel_id,
        })
    return {"ok": True}


@app.post("/api/channels/{channel_id}/key")
async def set_channel_key(channel_id: str, req: SetChannelKeyRequest,
                           me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    db.set_channel_key(channel_id, req.username, req.wrapped_key)
    return {"ok": True}


@app.get("/api/channels/{channel_id}/key")
async def get_channel_key(channel_id: str, me: str = Depends(_require_auth)):
    if not db.get_channel_member(channel_id, me):
        raise HTTPException(403, "not_member")
    wrapped = db.get_channel_key(channel_id, me)
    ch = db.get_channel(channel_id)
    creator_info = db.get_user(ch["creator"]) if ch else None
    return {
        "wrapped_key": wrapped,
        "admin_pub": creator_info["x25519_pub"] if creator_info else "",
    }


@app.delete("/api/channels/{channel_id}/messages/{msg_id}")
async def delete_channel_message(channel_id: str, msg_id: str,
                                  me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    member = db.get_channel_member(channel_id, me)
    if not member:
        raise HTTPException(403, "not_member")
    # Admin can delete any; members can only delete their own (checked server-side via msg lookup)
    if member["role"] != "admin":
        # verify ownership
        row = db.get_conn().execute(
            "SELECT from_username FROM channel_messages WHERE msg_id = ? AND channel_id = ?",
            (msg_id, channel_id)
        ).fetchone()
        if not row or row["from_username"] != me:
            raise HTTPException(403, "not_your_message")
    deleted = db.delete_channel_message(channel_id, msg_id)
    if not deleted:
        raise HTTPException(404, "message_not_found")
    # Broadcast delete to all online members
    members = db.get_channel_members(channel_id)
    for m in members:
        uname = m["username"]
        if uname != me and uname in _connections:
            await _send(_connections[uname], {
                "type": "channel_message_deleted",
                "channel_id": channel_id,
                "msg_id": msg_id,
            })
    return {"ok": True}


@app.post("/api/channels/{channel_id}/leave")
async def leave_channel(channel_id: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] == me:
        raise HTTPException(400, "creator_cannot_leave")
    db.remove_channel_member(channel_id, me)
    return {"ok": True}


@app.delete("/api/channels/{channel_id}")
async def delete_channel(channel_id: str, me: str = Depends(_require_auth)):
    ch = db.get_channel(channel_id)
    if not ch:
        raise HTTPException(404, "not_found")
    if ch["creator"] != me:
        raise HTTPException(403, "not_admin")
    db.delete_channel(channel_id)
    return {"ok": True}


@app.get("/api/channels/{channel_id}/messages")
async def get_channel_messages(channel_id: str, limit: int = 50,
                                before_id: int = 0, me: str = Depends(_require_auth)):
    if not db.get_channel_member(channel_id, me):
        raise HTTPException(403, "not_member")
    rows = db.get_channel_messages(channel_id, limit=limit, before_id=before_id)
    return {"messages": [
        {"id": r["id"], "from_username": r["from_username"],
         "display_name": r["display_name"], "body": r["body"],
         "msg_id": r["msg_id"], "sent_at": r["sent_at"]}
        for r in rows
    ]}


@app.get("/api/channels/{channel_id}/members")
async def get_channel_members(channel_id: str, me: str = Depends(_require_auth)):
    if not db.get_channel_member(channel_id, me):
        raise HTTPException(403, "not_member")
    rows = db.get_channel_members(channel_id)
    return {"members": [
        {"username": r["username"], "role": r["role"],
         "display_name": r["display_name"] or r["username"]}
        for r in rows
    ]}


@app.get("/api/support/messages")
async def get_support_messages(me: str = Depends(_require_auth)):
    if me == 'hhh':
        rows = db.get_all_support_messages(limit=200)
    else:
        rows = db.get_support_messages_for_user(me, limit=100)
    return {"messages": [
        {"from_username": r["from_username"], "to_username": r["to_username"],
         "body": r["body"], "msg_id": r["msg_id"], "sent_at": r["sent_at"],
         "reply_to_msg_id": r["reply_to_msg_id"], "direction": r["direction"]}
        for r in rows
    ]}


# ── File relay REST ───────────────────────────────────────────────────────

@app.post("/api/files/upload")
async def upload_file(
    file:        UploadFile = File(...),
    to_username: str = Form(""),
    channel_id:  str = Form(""),
    filename:    str = Form(...),
    mime_type:   str = Form(...),
    msg_id:      str = Form(...),
    enc_key:     str = Form(""),
    sha256_hex:  str = Form(""),
    me: str = Depends(_require_auth),
):
    if not to_username and not channel_id:
        raise HTTPException(400, detail={"error": "to_username or channel_id required"})
    content = await file.read()
    if len(content) > FILE_MAX_BYTES:
        raise HTTPException(413, detail={"error": "file_too_large",
                                         "max_mb": FILE_MAX_BYTES // (1024 * 1024)})
    actual_sha = hashlib.sha256(content).hexdigest()
    if sha256_hex and actual_sha != sha256_hex:
        raise HTTPException(422, detail={"error": "file_corrupted"})
    # Validate recipient (DM) or channel membership
    if to_username and not db.user_exists(to_username):
        raise HTTPException(404, detail={"error": "user_not_found"})
    if channel_id and not db.get_channel_member(channel_id, me):
        raise HTTPException(403, detail={"error": "not_a_member"})

    import uuid as _uuid_mod2
    file_id   = str(_uuid_mod2.uuid4())
    file_path = _os.path.join(UPLOAD_DIR, file_id)
    with open(file_path, 'wb') as f:
        f.write(content)

    now = int(time.time())
    db.save_pending_file(
        file_id=file_id, from_username=me, to_username=to_username,
        filename=filename, mime_type=mime_type, file_size=len(content),
        file_path=file_path, enc_key=enc_key, msg_id=msg_id,
        sha256=actual_sha, expires_at=now + FILE_EXPIRE_SECS,
        channel_id=channel_id,
    )
    server_state.file.set(file_id, FileState.uploaded)
    log.info("file uploaded: %s → %s/%s (%d bytes)", me, to_username or channel_id, channel_id, len(content))
    return {"ok": True, "file_id": file_id}


@app.get("/api/files/{file_id}")
async def download_file(file_id: str, me: str = Depends(_require_auth)):
    pf = db.get_pending_file(file_id)
    if not pf:
        raise HTTPException(404, detail={"error": "file_not_found"})
    ch_id = pf["channel_id"] if "channel_id" in pf.keys() else ""
    if ch_id:
        # Channel file: any member may download
        if not db.get_channel_member(ch_id, me):
            raise HTTPException(403, detail={"error": "forbidden"})
    elif pf["to_username"] != me and pf["from_username"] != me:
        raise HTTPException(403, detail={"error": "forbidden"})
    if not _os.path.exists(pf["file_path"]):
        raise HTTPException(410, detail={"error": "file_expired"})
    with open(pf["file_path"], 'rb') as f:
        content = f.read()
    server_state.file.set(file_id, FileState.downloaded)
    return Response(
        content=content,
        media_type="application/octet-stream",
        headers={
            "X-File-Name": pf["filename"],
            "X-Enc-Key":   pf["enc_key"],
            "X-Mime-Type": pf["mime_type"],
            "X-File-Size": str(pf["file_size"]),
        },
    )


@app.post("/api/files/{file_id}/ack")
async def ack_file(file_id: str, me: str = Depends(_require_auth)):
    pf = db.get_pending_file(file_id)
    if not pf or pf["to_username"] != me:
        raise HTTPException(404, detail={"error": "not_found"})
    try:
        _os.remove(pf["file_path"])
    except OSError:
        pass
    db.delete_pending_file(file_id)
    log.info("file acked and deleted: %s by %s", file_id, me)
    return {"ok": True}


@app.post("/api/files/{file_id}/reupload")
async def reupload_file(
    file_id:    str,
    file:       UploadFile = File(...),
    filename:   str = Form(...),
    mime_type:  str = Form(...),
    enc_key:    str = Form(""),
    sha256_hex: str = Form(""),
    me: str = Depends(_require_auth),
):
    """Sender re-uploads a file after the original expired (re-request flow)."""
    # Find the file_request
    reqs = db.get_pending_file_requests()
    req  = next((r for r in reqs if r["file_id"] == file_id and r["from_username"] == me), None)
    if not req:
        raise HTTPException(404, detail={"error": "request_not_found"})

    content    = await file.read()
    if len(content) > FILE_MAX_BYTES:
        raise HTTPException(413, detail={"error": "file_too_large",
                                         "max_mb": FILE_MAX_BYTES // (1024 * 1024)})
    actual_sha = hashlib.sha256(content).hexdigest()
    if sha256_hex and actual_sha != sha256_hex:
        raise HTTPException(422, detail={"error": "file_corrupted"})

    import uuid as _uuid_mod3
    new_file_id = str(_uuid_mod3.uuid4())
    file_path   = _os.path.join(UPLOAD_DIR, new_file_id)
    with open(file_path, 'wb') as f:
        f.write(content)

    now = int(time.time())
    db.save_pending_file(
        file_id=new_file_id, from_username=me, to_username=req["to_username"],
        filename=filename, mime_type=mime_type, file_size=len(content),
        file_path=file_path, enc_key=enc_key, msg_id=req["msg_id"],
        sha256=actual_sha, expires_at=now + FILE_EXPIRE_SECS,
    )
    db.delete_file_request(req["id"])
    log.info("file re-uploaded: %s → %s", me, req["to_username"])
    return {"ok": True, "file_id": new_file_id}


# ── WebSocket helpers ──────────────────────────────────────────────────────

async def _send(ws: WebSocket, data: dict):
    try:
        await ws.send_text(json.dumps(data))
    except Exception:
        pass


async def _deliver_offline_messages(username: str, ws: WebSocket) -> None:
    """Send sync_summary then deliver all pending offline messages to user."""
    pending = db.get_pending_messages(username)
    if not pending:
        await _send(ws, {"type": "sync_summary", "total": 0, "senders": []})
        return

    # Build summary: count per sender
    from collections import Counter
    counts = Counter(row["from_username"] for row in pending)
    senders = [{"username": u, "count": c} for u, c in counts.items()]
    await _send(ws, {
        "type":    "sync_summary",
        "total":   len(pending),
        "senders": senders,
    })

    # Deliver messages one by one
    for row in pending:
        payload = {
            "type":          "relay_message",
            "from_username": row["from_username"],
            "enc_body":      row["enc_body"],
            "msg_id":        row["msg_id"],
            "sent_at":       row["sent_at"],
        }
        if row["forwarded_from"]:
            payload["forwarded_from"] = row["forwarded_from"]
        if row["reply_to_msg_id"]:
            payload["reply_to_msg_id"] = row["reply_to_msg_id"]
        await _send(ws, payload)
        db.mark_delivered(row["msg_id"])

    log.info("sync: delivered %d offline messages to %s", len(pending), username)


async def _notify_contacts_online(username: str, event: str):
    """Push peer_online / peer_offline to all online contacts of username.
    If user is in background, they are connected but NOT shown as online."""
    if event == "peer_online" and username in _background:
        return  # Don't announce as online while app is backgrounded
    contacts = db.get_contacts(username)
    for contact in contacts:
        ws = _online.get(contact)
        if ws:
            await _send(ws, {"type": event, "username": username})


async def _heartbeat_checker():
    """Background task: close connections silent for more than HEARTBEAT_TIMEOUT seconds."""
    while True:
        await asyncio.sleep(5)
        now = time.time()
        stale = [
            u for u, t in list(_last_ping.items())
            if now - t > _HEARTBEAT_TIMEOUT and u in _online
        ]
        for username in stale:
            ws = _online.get(username)
            if ws:
                log.info("heartbeat: no ping from %s for %.0fs — closing",
                         username, now - _last_ping.get(username, 0))
                server_state.client.set(username, ClientState.disconnected)
                try:
                    await ws.close()
                except Exception:
                    pass


# ── Message sync ───────────────────────────────────────────────────────────

@app.post("/api/messages/sync")
async def messages_sync(req: Request, username: str = Depends(_require_auth)):
    data = await req.json()
    msg_ids = data.get("msg_ids", [])
    if not msg_ids or len(msg_ids) > 200:
        raise HTTPException(400, "bad msg_ids")
    result = db.get_msg_statuses(msg_ids, username)
    return {"statuses": result}


# ── Device trust management ────────────────────────────────────────────────

@app.get("/api/devices")
async def list_devices(username: str = Depends(_require_auth)):
    devices = db.get_all_devices(username)
    return {"devices": devices}


@app.post("/api/devices/{device_id}/trust")
async def update_device_trust(device_id: str, req: Request,
                               username: str = Depends(_require_auth)):
    data = await req.json()
    trust_type  = data.get("trust_type")
    trust_level = data.get("trust_level")
    if trust_type not in (None, "numeric", "guest"):
        raise HTTPException(400, "invalid trust_type")
    ok = db.set_device_trust(username, device_id,
                             trust_type=trust_type, trust_level=trust_level)
    if not ok:
        raise HTTPException(403, "cannot modify creator or device not found")
    return {"ok": True}


@app.post("/api/devices/{device_id}/permissions")
async def update_device_permissions(device_id: str, req: Request,
                                     username: str = Depends(_require_auth)):
    data = await req.json()
    perms = data.get("permissions")
    if not isinstance(perms, dict):
        raise HTTPException(400, "permissions must be object")
    ok = db.set_device_trust(username, device_id, permissions=perms)
    if not ok:
        raise HTTPException(403, "cannot modify creator or device not found")
    return {"ok": True}


@app.delete("/api/devices/{device_id}")
async def revoke_device(device_id: str, username: str = Depends(_require_auth)):
    db.block_device(username, device_id)
    return {"ok": True}


# ── Internal shop API (для shop_bot) ──────────────────────────────────────

@app.get("/internal/check_user")
async def internal_check_user(username: str, key: str):
    """Проверяет существование GC-юзернейма. Только для shop_bot (внутренний ключ)."""
    if key != _SUPPORT_PASSWORD:
        raise HTTPException(403, detail="forbidden")
    if not username:
        raise HTTPException(400, detail="username required")
    row = db.get_user(username.lstrip("@"))
    return {"exists": row is not None}


# ── WebSocket endpoint ─────────────────────────────────────────────────────

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    username: Optional[str] = None

    try:
        # Auth handshake — must arrive within 5 seconds
        try:
            raw = await asyncio.wait_for(ws.receive_text(), timeout=5.0)
            pkt = json.loads(raw)
        except asyncio.TimeoutError:
            await _send(ws, {"type": "auth_fail", "reason": "timeout"})
            await ws.close()
            return

        if pkt.get("type") != "auth":
            await _send(ws, {"type": "auth_fail", "reason": "expected_auth"})
            await ws.close()
            return

        try:
            username = _auth.decode_token(pkt.get("token", ""))
        except jwt.InvalidTokenError:
            await _send(ws, {"type": "auth_fail", "reason": "invalid_token"})
            await ws.close()
            return
        _ws_device_id[username] = pkt.get("device_id", "")
        _ws_ip[username] = ws.client.host if ws.client else ""
        server_state.client.set(username, ClientState.authenticating)

        # Kick old connection if exists
        old_ws = _online.get(username)
        if old_ws:
            await _send(old_ws, {"type": "kicked"})
            try:
                await old_ws.close()
            except Exception:
                pass

        _online[username] = ws
        _last_ping[username] = time.time()
        server_state.client.set(username, ClientState.connected)
        await _send(ws, {"type": "auth_ok"})
        log.info("ws connected: user=%s", username)

        # Notify contacts that this user came online
        await _notify_contacts_online(username, "peer_online")

        # Tell this user which of their contacts are currently online
        contacts = db.get_contacts(username)
        for contact in contacts:
            if contact in _online:
                await _send(ws, {"type": "peer_online", "username": contact})

        # Deliver offline events (relay_delete, relay_edit)
        events = db.get_pending_events(username)
        for ev in events:
            await _send(ws, {
                "type":     ev["type"],
                "msg_id":   ev["msg_id"],
                **({"enc_body": ev["enc_body"]} if ev["enc_body"] else {}),
            })

        # Deliver pending offline messages and send sync_summary
        await _deliver_offline_messages(username, ws)
        if events:
            db.clear_pending_events(username)
            log.info("delivered %d offline events to %s", len(events), username)

        # Deliver offline messages
        pending = db.get_pending_messages(username)
        for msg in pending:
            offline_pkt = {
                "type":          "relay_message",
                "from_username": msg["from_username"],
                "enc_body":      msg["enc_body"],
                "msg_id":        msg["msg_id"],
                "sent_at":       msg["sent_at"],
            }
            fwd = msg["forwarded_from"] if msg["forwarded_from"] else ""
            if fwd:
                offline_pkt["forwarded_from"] = fwd
            rpl = msg["reply_to_msg_id"] if msg["reply_to_msg_id"] else ""
            if rpl:
                offline_pkt["reply_to_msg_id"] = rpl
            await _send(ws, offline_pkt)
            db.mark_delivered(msg["msg_id"])
        if pending:
            log.info("delivered %d offline messages to %s",
                     len(pending), username)

        # ── Startup sync ──────────────────────────────────────────────────
        # 1. Own device trust info
        dev_id = _ws_device_id.get(username, "")
        if dev_id:
            trust = db.get_device_trust(username, dev_id)
            if trust:
                await _send(ws, {"type": "device_trust", **trust})

        # 2. Support chat history (last 50 messages)
        try:
            if username == "hhh":
                support_rows = db.get_all_support_messages(limit=50)
            else:
                support_rows = db.get_support_messages_for_user(username, limit=50)
            if support_rows:
                msgs = []
                for r in support_rows:
                    msgs.append({
                        "msg_id":       r["msg_id"],
                        "from_username": r["from_username"],
                        "to_username":  r["to_username"],
                        "body":         r["body"],
                        "sent_at":      r["sent_at"],
                        "direction":    r["direction"] if "direction" in r.keys() else "",
                    })
                await _send(ws, {"type": "support_history", "messages": msgs})
        except Exception as e:
            log.warning("startup_sync support_history error: %s", e)

        # 3. Pending login requests (for approval)
        try:
            pending_logins = db.get_my_pending_logins(username)
            if pending_logins:
                reqs = [{"request_id": r["request_id"], "device_id": r["device_id"],
                         "device_name": r["device_name"], "client_ip": r["client_ip"],
                         "created_at": r["created_at"], "phase": r["phase"]}
                        for r in pending_logins]
                await _send(ws, {"type": "pending_logins_sync", "requests": reqs})
        except Exception as e:
            log.warning("startup_sync pending_logins error: %s", e)

        # Main message loop
        while True:
            try:
                raw = await asyncio.wait_for(ws.receive_text(), timeout=60.0)
            except asyncio.TimeoutError:
                await _send(ws, {"type": "pong"})  # keepalive
                continue

            try:
                pkt = json.loads(raw)
            except Exception:
                continue

            ptype = pkt.get("type")

            if ptype == "ping":
                _last_ping[username] = time.time()
                if ws.client:
                    _ws_ip[username] = ws.client.host
                await _send(ws, {"type": "pong"})

            elif ptype == "app_ready":
                # Client signals it's fully initialized and ready to receive
                # Re-deliver any missed offline messages
                await _deliver_offline_messages(username, ws)
                await _send(ws, {"type": "app_ready_ack"})

            elif ptype == "sync_request":
                # Explicit request to re-sync (e.g. after reconnect or manual pull)
                await _deliver_offline_messages(username, ws)

            elif ptype == "set_background":
                # App went to background/foreground — update visibility without disconnecting
                in_bg = bool(pkt.get("value", False))
                if in_bg:
                    _background.add(username)
                    server_state.client.set(username, ClientState.background)
                    await _notify_contacts_online(username, "peer_offline")
                else:
                    _background.discard(username)
                    server_state.client.set(username, ClientState.connected)
                    await _notify_contacts_online(username, "peer_online")
                    # On foreground — also re-sync in case messages arrived while backgrounded
                    await _deliver_offline_messages(username, ws)

            elif ptype == "relay_message":
                _last_ping[username] = time.time()
                to          = pkt.get("to_username", "")
                body        = pkt.get("enc_body", "")
                mid         = pkt.get("msg_id", "")
                sat         = pkt.get("sent_at", 0)
                fwd_from    = pkt.get("forwarded_from", "")
                reply_to    = pkt.get("reply_to_msg_id", "")

                if not to or not body or not mid:
                    continue

                # Track receipt immediately
                server_state.msg.set(mid, MsgRelayState.received)
                db.record_msg_received(mid, username, to, sat)

                payload = {
                    "type":          "relay_message",
                    "from_username": username,
                    "enc_body":      body,
                    "msg_id":        mid,
                    "sent_at":       sat,
                }
                if fwd_from:
                    payload["forwarded_from"] = fwd_from
                if reply_to:
                    payload["reply_to_msg_id"] = reply_to

                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws, payload)
                    db.mark_delivered(mid)
                    server_state.msg.set(mid, MsgRelayState.relayed)
                    log.info("relay_message: %s→%s msg_id=%s (online)",
                             username, to, mid[:8])
                else:
                    db.save_offline_message(username, to, body, mid, sat,
                                            forwarded_from=fwd_from,
                                            reply_to_msg_id=reply_to)
                    server_state.msg.set(mid, MsgRelayState.stored_offline)
                    log.info("relay_message: %s→%s msg_id=%s (offline, stored)",
                             username, to, mid[:8])

                # Always ACK back to sender: message received by server
                await _send(ws, {"type": "relay_ack", "msg_id": mid})

            elif ptype == "relay_ack":
                to  = pkt.get("to_username", "")
                mid = pkt.get("msg_id", "")
                if mid:
                    server_state.msg.set(mid, MsgRelayState.delivered)
                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws, {"type": "relay_ack", "msg_id": mid})

            elif ptype == "relay_seen":
                to      = pkt.get("to_username", "")
                msg_ids = pkt.get("msg_ids", [])
                if msg_ids:
                    for _mid in msg_ids:
                        server_state.msg.set(_mid, MsgRelayState.seen)
                    db.record_msg_seen(msg_ids, username)
                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws,
                                {"type": "relay_seen", "msg_ids": msg_ids})

            elif ptype == "relay_delete":
                _last_ping[username] = time.time()
                to  = pkt.get("to_username", "")
                mid = pkt.get("msg_id", "")
                if not to or not mid:
                    continue
                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws, {"type": "relay_delete", "msg_id": mid})
                    log.info("relay_delete: %s→%s msg_id=%s (online)", username, to, mid[:8])
                else:
                    db.save_offline_event(to, "relay_delete", mid)
                    log.info("relay_delete: %s→%s msg_id=%s (offline, stored)", username, to, mid[:8])

            elif ptype == "relay_edit":
                _last_ping[username] = time.time()
                to   = pkt.get("to_username", "")
                mid  = pkt.get("msg_id", "")
                body = pkt.get("enc_body", "")
                if not to or not mid or not body:
                    continue
                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws, {
                        "type":          "relay_edit",
                        "from_username": username,
                        "msg_id":        mid,
                        "enc_body":      body,
                    })
                    log.info("relay_edit: %s→%s msg_id=%s (online)", username, to, mid[:8])
                else:
                    db.save_offline_event(to, "relay_edit", mid, enc_body=body)
                    log.info("relay_edit: %s→%s msg_id=%s (offline, stored)", username, to, mid[:8])

            elif ptype == "relay_screen_lock":
                # Real-time screenshot block signal: forward to peer if online
                to      = pkt.get("to", "")
                enabled = bool(pkt.get("enabled", False))
                target_ws = _online.get(to)
                if target_ws:
                    await _send(target_ws, {
                        "type":          "relay_screen_lock",
                        "from_username": username,
                        "enabled":       enabled,
                    })
                # Also persist the setting in user profile
                db.set_screen_block(username, enabled)

            elif ptype == "channel_message":
                _last_ping[username] = time.time()
                cid  = pkt.get("channel_id", "")
                body = pkt.get("body", "")
                mid  = pkt.get("msg_id", "")
                sat  = pkt.get("sent_at", 0)
                if not cid or not body or not mid:
                    continue
                member = db.get_channel_member(cid, username)
                if not member:
                    continue
                channel = db.get_channel(cid)
                if not channel:
                    continue
                # Channels: only admins post
                if channel["type"] == "channel" and member["role"] != "admin":
                    continue
                user = db.get_user(username)
                dn = user["display_name"] if user else username
                db.save_channel_message(cid, username, dn, body, mid, sat)
                # Broadcast to all online members
                payload = {
                    "type":          "channel_message",
                    "channel_id":    cid,
                    "from_username": username,
                    "display_name":  dn,
                    "body":          body,
                    "msg_id":        mid,
                    "sent_at":       sat,
                }
                for m in db.get_channel_members(cid):
                    if m["username"] == username:
                        continue
                    ws_t = _online.get(m["username"])
                    if ws_t:
                        await _send(ws_t, payload)

            elif ptype == "support_message":
                # User → Support
                body    = pkt.get('body', '')
                msg_id  = pkt.get('msg_id', '')
                sent_at = pkt.get('sent_at', int(time.time() * 1000))
                if not body or not msg_id:
                    continue
                db.save_support_message(username, body, msg_id, sent_at, direction='in')
                # Forward to admin
                admin = 'hhh'
                admin_body = f'[От @{username}]: {body}'
                admin_msg_id = str(_uuid_mod.uuid4())
                db.save_support_message(username, admin_body, admin_msg_id, sent_at,
                                         direction='in')
                payload = {
                    'type':             'support_incoming',
                    'from_username':    username,
                    'body':             admin_body,
                    'msg_id':           admin_msg_id,
                    'original_msg_id':  msg_id,
                    'sent_at':          sent_at,
                }
                if admin in _online:
                    await _send(_online[admin], payload)
                else:
                    db.save_offline_message(username, admin, admin_body, admin_msg_id, sent_at)
                # ACK back to user
                await _send(ws, {'type': 'support_ack', 'msg_id': msg_id})

            elif ptype == "support_reply":
                # Admin (@hhh) → specific user
                pwd      = pkt.get('password', '')
                to_user  = pkt.get('to_username', '')
                body     = pkt.get('body', '')
                msg_id   = pkt.get('msg_id', str(_uuid_mod.uuid4()))
                sent_at  = pkt.get('sent_at', int(time.time() * 1000))
                reply_to = pkt.get('reply_to_msg_id', '')
                if username != 'hhh' or pwd != _SUPPORT_PASSWORD:
                    continue
                if not to_user or not body:
                    # If no to_user but has reply_to, look up original sender
                    if reply_to:
                        orig = db.get_support_message_by_id(reply_to)
                        if orig:
                            to_user = orig['from_username']
                if not to_user:
                    continue
                db.save_support_message(username, body, msg_id, sent_at,
                                         to_username=to_user, direction='out')
                payload = {
                    'type':     'support_reply',
                    'body':     body,
                    'msg_id':   msg_id,
                    'sent_at':  sent_at,
                }
                if to_user in _online:
                    await _send(_online[to_user], payload)
                else:
                    db.save_offline_message(username, to_user, body, msg_id, sent_at)

            elif ptype == "support_broadcast":
                # Admin (@hhh) → all users
                pwd     = pkt.get('password', '')
                body    = pkt.get('body', '')
                msg_id  = pkt.get('msg_id', str(_uuid_mod.uuid4()))
                sent_at = pkt.get('sent_at', int(time.time() * 1000))
                if username != 'hhh' or pwd != _SUPPORT_PASSWORD:
                    continue
                if not body:
                    continue
                db.save_support_message(username, body, msg_id, sent_at,
                                         to_username='all', direction='out')
                payload = {'type': 'support_reply', 'body': body,
                           'msg_id': msg_id, 'sent_at': sent_at}
                for uname, uws in list(_online.items()):
                    if uname != username:
                        await _send(uws, payload)

            elif ptype == "peer_status_req":
                who = pkt.get("username", "")
                await _send(ws, {
                    "type":     "peer_online" if who in _online else "peer_offline",
                    "username": who,
                })

            elif ptype == "file_ack":
                fid = pkt.get("file_id", "")
                if fid:
                    pf = db.get_pending_file(fid)
                    if pf and pf["to_username"] == username:
                        try:
                            _os.remove(pf["file_path"])
                        except OSError:
                            pass
                        db.delete_pending_file(fid)
                        server_state.file.set(fid, FileState.acked)
                        log.info("file_ack: deleted %s", fid)

            elif ptype == "login_approve":
                # Existing device approved — move to code_phase
                rid = pkt.get("request_id", "")
                row = db.get_pending_login(rid) if rid else None
                if row and row["username"] == username and row["phase"] == "pending":
                    db.set_pending_phase(rid, "code_phase")
                    log.info("login_approve: %s approved %s", username, rid[:8])
                    await _send(ws, {"type": "login_approve_ack", "request_id": rid})

            elif ptype == "login_deny":
                # Existing device denied
                rid = pkt.get("request_id", "")
                row = db.get_pending_login(rid) if rid else None
                if row and row["username"] == username and row["phase"] in ("pending", "code_phase", "verify_phase"):
                    db.set_pending_phase(rid, "denied")
                    log.info("login_deny: %s denied %s", username, rid[:8])
                    await _send(ws, {"type": "login_deny_ack", "request_id": rid})

            elif ptype == "login_block":
                # Existing device blocked this device_id permanently
                rid = pkt.get("request_id", "")
                row = db.get_pending_login(rid) if rid else None
                if row and row["username"] == username:
                    db.block_device(username, row["device_id"])
                    db.set_pending_phase(rid, "blocked")
                    log.info("login_block: %s blocked device %s", username, row["device_id"][:8])
                    await _send(ws, {"type": "login_block_ack", "request_id": rid})

            elif ptype == "code_submit":
                # Existing device typed the code they see on the new device
                rid  = pkt.get("request_id", "")
                code = pkt.get("code", "").strip()
                row  = db.get_pending_login(rid) if rid else None
                if row and row["username"] == username and row["phase"] == "code_phase" and len(code) == 6:
                    db.set_submitted_code(rid, code)
                    log.info("code_submit: %s submitted code for %s", username, rid[:8])
                    await _send(ws, {"type": "code_submit_ack", "request_id": rid})

    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.warning("ws error user=%s: %s", username, e)
    finally:
        if username and _online.get(username) is ws:
            del _online[username]
            _last_ping.pop(username, None)
            _background.discard(username)
            _ws_ip.pop(username, None)
            server_state.client.set(username, ClientState.disconnected)
            log.info("ws disconnected: user=%s", username)
            # Notify contacts that this user went offline
            await _notify_contacts_online(username, "peer_offline")


# ── Startup ───────────────────────────────────────────────────────────────

async def _cleanup_loop():
    """Delete old delivered/expired messages daily."""
    while True:
        await asyncio.sleep(86400)
        try:
            db.cleanup_old_messages(days=7)
            db.cleanup_channel_messages(days=1)
            db.cleanup_old_files()
            log.info("cleanup: old messages/files deleted")
        except Exception as e:
            log.warning("cleanup error: %s", e)


async def _file_delivery_loop():
    """Every 30s: deliver pending files to online recipients, expire old ones, re-request."""
    while True:
        await asyncio.sleep(30)
        try:
            now = int(time.time())

            # 1. Notify online recipients about uploaded files
            for pf in db.get_pending_files_to_deliver():
                to_ws = _online.get(pf["to_username"])
                if to_ws:
                    await _send(to_ws, {
                        "type":          "file_incoming",
                        "file_id":       pf["file_id"],
                        "from_username": pf["from_username"],
                        "filename":      pf["filename"],
                        "mime_type":     pf["mime_type"],
                        "file_size":     pf["file_size"],
                        "enc_key":       pf["enc_key"],
                        "msg_id":        pf["msg_id"],
                        "sent_at":       pf["created_at"] * 1000,
                    })
                    db.update_pending_file_status(pf["file_id"], "notified")
                    server_state.file.set(pf["file_id"], FileState.notified)
                    log.info("file_incoming pushed: %s → %s", pf["file_id"], pf["to_username"])

            # 2. Expire files whose TTL has passed
            for pf in db.get_expired_files(now):
                db.save_file_request(
                    file_id=pf["file_id"], from_username=pf["from_username"],
                    to_username=pf["to_username"], filename=pf["filename"],
                    msg_id=pf["msg_id"],
                )
                try:
                    _os.remove(pf["file_path"])
                except OSError:
                    pass
                db.delete_pending_file(pf["file_id"])
                server_state.file.set(pf["file_id"], FileState.expired)
                log.info("file expired: %s", pf["file_id"])

            # 3. Re-request: both users must be online right now
            for req in db.get_pending_file_requests():
                from_ws = _online.get(req["from_username"])
                to_ws   = _online.get(req["to_username"])
                if from_ws and to_ws:
                    await _send(from_ws, {
                        "type":            "file_reupload_request",
                        "original_msg_id": req["msg_id"],
                        "file_id":         req["file_id"],
                        "to_username":     req["to_username"],
                        "filename":        req["filename"],
                        "request_id":      req["id"],
                    })
                    db.mark_file_request_sent(req["id"])
                    server_state.file.set(req["file_id"], FileState.rerequest_sent)
                    log.info("file_reupload_request: %s → %s", req["file_id"], req["from_username"])

        except Exception as e:
            log.warning("file_delivery_loop error: %s", e)


@app.on_event("startup")
async def startup():
    db.get_conn()
    db.init_device_tables()
    asyncio.create_task(_heartbeat_checker())
    asyncio.create_task(_cleanup_loop())
    asyncio.create_task(_file_delivery_loop())
    log.info("GhostChat relay server v2.0 started")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
