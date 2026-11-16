"""GhostChat web device adapter. Service grants never leave the chat scope.

Native device credentials stay server-side. Browser device IDs are derived
from a proof-of-possession key, and enrollment follows Core's existing TDA.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import secrets
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect, UploadFile, File, Form
from fastapi.responses import JSONResponse
from pydantic import Field

from ecos_core import service_sso as sso
from ecos_core.identity import db
from ecos_core.shared import _rate_limit

LOGGER = logging.getLogger("ghostchat.web")

router = APIRouter(prefix="/api/chat/v2/client", route_class=sso.SSORoute)


def _schema(c):
    c.executescript("""
      CREATE TABLE IF NOT EXISTS chat_web_sessions (
        token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
        browser_pub TEXT NOT NULL, device_pk INTEGER, approval_handle TEXT UNIQUE,
        pending_request TEXT, expires_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS chat_web_approval_handles (
        user_id INTEGER NOT NULL, native_request TEXT NOT NULL, handle TEXT UNIQUE NOT NULL,
        expires_at INTEGER NOT NULL, PRIMARY KEY(user_id,native_request)
      );
    """)


def _bearer(header):
    scheme, _, token = (header or "").partition(" ")
    if scheme.lower() != "bearer" or not sso._OPAQUE.fullmatch(token):
        raise HTTPException(401, "Нужен токен входа GhostChat")
    return token


def _source_active(user_id, source_hash):
    """Источник входа: сессия GhostID, устройство или токен соцсети."""
    if not source_hash:
        return False
    now = int(time.time())
    c = db()
    try:
        # Вход из браузера держит источник в auth_sessions — без неё любой вход считался отозванным.
        if c.execute("SELECT 1 FROM auth_sessions WHERE user_id=? AND token_hash=? AND status='active' "
                     "AND revoked_at IS NULL AND ended_at IS NULL AND expires_at>?",
                     (user_id, source_hash, now)).fetchone():
            return True
        for r in c.execute("SELECT token, expires_at FROM soc_tokens WHERE user_id=?", (user_id,)).fetchall():
            if (not r["expires_at"] or r["expires_at"] > now) and r["token"] and \
                    secrets.compare_digest(sso._hash(r["token"]), source_hash):
                return True
        for r in c.execute("SELECT token FROM user_devices WHERE user_id=? AND is_active=1 AND is_blocked=0 "
                           "AND (expires_at=0 OR expires_at>?)", (user_id, now)).fetchall():
            if r["token"] and secrets.compare_digest(sso._hash(r["token"]), source_hash):
                return True
        return False
    finally:
        c.close()


def _touch(g):
    """Скользящий вход: срок продлевается при использовании и сгорает при бездействии."""
    now = int(time.time())
    mark = now + sso.CHAT_TOKEN_TTL
    # ВАЖНО: не чаще раза в час, иначе каждая вкладка писала бы в БД на каждый запрос.
    edge = mark - 3600
    with sso._db() as c:
        _schema(c)
        c.execute("UPDATE access_tokens SET expires_at=? WHERE token_hash=? AND expires_at<?",
                  (mark, g["token_hash"], edge))
        row = c.execute("SELECT device_pk FROM chat_web_sessions WHERE token_hash=?",
                        (g["token_hash"],)).fetchone()
        c.execute("UPDATE chat_web_sessions SET expires_at=? WHERE token_hash=? AND expires_at<?",
                  (mark, g["token_hash"], edge))
    if not row or not row["device_pk"]:
        return
    c = db()
    try:
        c.execute("UPDATE user_devices SET expires_at=? WHERE id=? AND expires_at>0 AND expires_at<?",
                  (mark, row["device_pk"], edge))
        c.commit()
    finally:
        c.close()


def grant(token, origin=None):
    if origin and origin != sso._origin(sso._issuer()):
        raise HTTPException(403, "Этот доступ предназначен для GhostChat")
    with sso._db() as c:
        r = c.execute("SELECT * FROM access_tokens WHERE token_hash=?", (sso._hash(token),)).fetchone()
        if not r or r["expires_at"] <= int(time.time()):
            raise HTTPException(401, "Вход в GhostChat истёк")
        config, revision = sso._client(c, r["client_id"])
        if r["client_id"] != "ghostchat" or not config.get("trusted") or "chat" not in json.loads(r["scopes"]):
            raise HTTPException(403, "Нет разрешения chat: повтори вход в GhostChat")
        if revision != r["revision"]:
            raise HTTPException(401, "Разрешения изменились: повтори вход")
        result = dict(r)
    if not _source_active(result["user_id"], result.get("source_hash")):
        raise HTTPException(401, "Исходная сессия отозвана: повтори вход")
    _touch(result)
    return result


def device_session(token, origin=None):
    g = grant(token, origin)
    with sso._db() as c:
        _schema(c)
        r = c.execute("SELECT * FROM chat_web_sessions WHERE token_hash=?", (g["token_hash"],)).fetchone()
    if not r or not r["device_pk"]:
        raise HTTPException(409, "device_enrollment_required")
    c = db()
    try:
        d = c.execute("SELECT * FROM user_devices WHERE id=? AND user_id=? AND is_active=1 "
                      "AND is_blocked=0 AND (expires_at=0 OR expires_at>?)",
                      (r["device_pk"], g["user_id"], int(time.time()))).fetchone()
        if not d:
            raise HTTPException(401, "Устройство отозвано или его вход истёк")
        return g, dict(d)
    finally:
        c.close()


class Enrollment(sso.SSOBody):
    browser_pub: str = Field(min_length=44, max_length=44)
    proof: str = Field(min_length=88, max_length=88)
    timestamp: int
    device_name: str = Field(default="GhostChat Web", min_length=1, max_length=60)


def _proof(body, token):
    if abs(int(time.time()) - body.timestamp) > 120:
        raise HTTPException(401, "Доказательство устройства истекло")
    try:
        pub = base64.b64decode(body.browser_pub, validate=True)
        sig = base64.b64decode(body.proof, validate=True)
        message = f"ghostchat-web-device:v2\n{sso._hash(token)}\n{body.timestamp}".encode()
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, message)
    except Exception:
        raise HTTPException(401, "Неверная подпись устройства")
    return "gcw2-" + hashlib.sha256(pub).hexdigest()


def _record(g, pub, native_token):
    import device_auth as _da
    c = db()
    try:
        # Новые токены устройств лежат только хешем, поэтому сначала пробуем их.
        d = _da.auth_device_token(c, native_token) if native_token else None
        if not d:
            d = c.execute("SELECT * FROM user_devices WHERE token=? AND user_id=?",
                          (native_token, g["user_id"])).fetchone()
        # ВАЖНО: expires_at=0 у устройства значит «бессрочно», как и в остальном чате.
        if not d or int(d["user_id"]) != int(g["user_id"]) or not d["is_active"] or d["is_blocked"] or (
                d["expires_at"] and d["expires_at"] <= time.time()):
            raise HTTPException(401, "Устройство недоступно")
        device_pk = int(d["id"])
    finally:
        c.close()
    with sso._db() as c:
        _schema(c)
        c.execute("INSERT INTO chat_web_sessions (token_hash,user_id,browser_pub,device_pk,expires_at) "
                  "VALUES (?,?,?,?,?) ON CONFLICT(token_hash) DO UPDATE SET device_pk=excluded.device_pk, "
                  "pending_request=NULL, approval_handle=NULL", (g["token_hash"], g["user_id"], pub, device_pk, g["expires_at"]))
    return {"status": "ready", "device_id": device_pk, "user_id": str(g["user_id"]), "expires_at": g["expires_at"]}


def _rebind_known_browser(g, pub):
    """Тот же браузер с новым токеном получает прежнее устройство без одобрения.

    Proof уже подтвердил владение ключом браузера, поэтому привязка по browser_pub
    безопасна: нового устройства не создаём и одобрение не спрашиваем.
    """
    with sso._db() as c:
        _schema(c)
        row = c.execute(
            "SELECT device_pk FROM chat_web_sessions WHERE user_id=? AND browser_pub=? "
            "AND device_pk IS NOT NULL ORDER BY expires_at DESC LIMIT 1",
            (g["user_id"], pub),
        ).fetchone()
    if not row:
        return None
    c = db()
    try:
        d = c.execute(
            "SELECT * FROM user_devices WHERE id=? AND user_id=? AND is_active=1 "
            "AND is_blocked=0 AND (expires_at=0 OR expires_at>?)",
            (row["device_pk"], g["user_id"], int(time.time())),
        ).fetchone()
    finally:
        c.close()
    if not d:
        return None
    with sso._db() as c:
        _schema(c)
        c.execute(
            "INSERT INTO chat_web_sessions (token_hash,user_id,browser_pub,device_pk,expires_at) "
            "VALUES (?,?,?,?,?) ON CONFLICT(token_hash) DO UPDATE SET device_pk=excluded.device_pk, "
            "browser_pub=excluded.browser_pub, pending_request=NULL, approval_handle=NULL",
            (g["token_hash"], g["user_id"], pub, int(d["id"]), g["expires_at"]),
        )
    return {"status": "ready", "device_id": int(d["id"]), "user_id": str(g["user_id"]),
            "expires_at": g["expires_at"]}


@router.post("/session")
def enroll(body: Enrollment, request: Request):
    token = _bearer(request.headers.get("authorization"))
    g = grant(token, request.headers.get("origin"))
    did = _proof(body, token)
    _rate_limit(f"chat-web-enroll:{g['user_id']}", limit=20, window=600)
    with sso._db() as c:
        _schema(c)
        existing = c.execute("SELECT * FROM chat_web_sessions WHERE token_hash=?", (g["token_hash"],)).fetchone()
    if existing:
        if existing["browser_pub"] != body.browser_pub:
            raise HTTPException(409, "Вход уже связан с другим устройством")
        if existing["device_pk"]:
            _, d = device_session(token)
            return {"status": "ready", "device_id": d["id"], "user_id": str(g["user_id"]), "expires_at": g["expires_at"]}
        c = db()
        try:
            pending = c.execute("SELECT phase,expires_at,granted_token FROM pending_logins WHERE request_id=?", (existing["pending_request"],)).fetchone()
        finally:
            c.close()
        if pending and pending["phase"] == "approved":
            return _record(g, body.browser_pub, pending["granted_token"])
        if pending and pending["phase"] == "pending" and pending["expires_at"] > time.time():
            return {"status": "approval_required", "approval_id": existing["approval_handle"],
                    "expires_in": max(0, pending["expires_at"] - int(time.time())), "resumed": True}
        with sso._db() as c:
            c.execute("DELETE FROM chat_web_sessions WHERE token_hash=?", (g["token_hash"],))
    bound = _rebind_known_browser(g, body.browser_pub)
    if bound:
        return bound
    c = db()
    user = c.execute("SELECT * FROM users WHERE id=?", (g["user_id"],)).fetchone()
    if not user:
        c.close()
        raise HTTPException(401, "Аккаунт не существует")
    # This private ID cannot alias an Android/iOS device ID.
    from ecos_core.login import _complete_login
    result = _complete_login(c, dict(user), request.client.host if request.client else "web",
                             did, body.device_name, "web-v2-sso")
    if not result.get("requires_approval"):
        return _record(g, body.browser_pub, result.get("device_token") or result["token"])
    handle = secrets.token_urlsafe(32)
    with sso._db() as c:
        _schema(c)
        c.execute("INSERT INTO chat_web_sessions (token_hash,user_id,browser_pub,approval_handle,pending_request,expires_at) "
                  "VALUES (?,?,?,?,?,?)", (g["token_hash"], g["user_id"], body.browser_pub, handle, result["request_id"], g["expires_at"]))
    # Never expose Core's request_id: its legacy status endpoint returns a
    # platform credential after approval. This handle only works in this API.
    return {"status": "approval_required", "approval_id": handle, "code": result["code"], "expires_in": result["expires_in"]}


@router.get("/session/approval/{handle}")
def approval(handle: str, request: Request):
    token = _bearer(request.headers.get("authorization"))
    g = grant(token, request.headers.get("origin"))
    with sso._db() as c:
        _schema(c)
        row = c.execute("SELECT * FROM chat_web_sessions WHERE token_hash=? AND approval_handle=?",
                        (g["token_hash"], handle)).fetchone()
    if not row:
        raise HTTPException(404, "Запрос подтверждения не найден")
    c = db()
    try:
        pending = c.execute("SELECT * FROM pending_logins WHERE request_id=?", (row["pending_request"],)).fetchone()
        if not pending:
            raise HTTPException(410, "Запрос истёк")
        if pending["phase"] == "approved":
            return _record(g, row["browser_pub"], pending["granted_token"])
        status = "expired" if pending["expires_at"] < time.time() else pending["phase"]
        return {"status": status}
    finally:
        c.close()


@router.get("/capabilities")
def capabilities(request: Request):
    device_session(_bearer(request.headers.get("authorization")), request.headers.get("origin"))
    return {"protocol": 2, "signed_messages": True, "idempotent_dm": True, "idempotent_rooms": True, "idempotent_files": True,
            "max_file_bytes": 100 * 1024 * 1024, "max_envelope_chars": 8000,
            "websocket": "/api/chat/v2/client/ws", "file_retention_days": 7,
            "public_rooms_encrypted": False, "bots_encrypted": False}


@router.get("/devices/pending")
def pending_devices(request: Request):
    g, _ = device_session(_bearer(request.headers.get("authorization")), request.headers.get("origin"))
    c = db()
    try:
        user = c.execute("SELECT username FROM users WHERE id=?", (g["user_id"],)).fetchone()
        rows = c.execute("SELECT request_id,device_id,device_name,created_at,expires_at FROM pending_logins "
                         "WHERE username=? AND phase='pending' AND expires_at>? ORDER BY created_at DESC",
                         (user["username"], int(time.time()))).fetchall()
    finally:
        c.close()
    pending = []
    with sso._db() as c:
        _schema(c)
        c.execute("DELETE FROM chat_web_approval_handles WHERE expires_at<?", (int(time.time()),))
        for row in rows:
            c.execute("INSERT OR IGNORE INTO chat_web_approval_handles VALUES (?,?,?,?)",
                      (g["user_id"], row["request_id"], secrets.token_urlsafe(32), row["expires_at"]))
            handle = c.execute("SELECT handle FROM chat_web_approval_handles WHERE user_id=? AND native_request=?",
                               (g["user_id"], row["request_id"])).fetchone()["handle"]
            pending.append({"request_id": handle, **{k: row[k] for k in ("device_id", "device_name", "created_at", "expires_at")}})
    return {"pending": pending}


class ApprovalCode(sso.SSOBody):
    code: str = Field(min_length=6, max_length=6)


def _pending_handle(request, handle):
    g, d = device_session(_bearer(request.headers.get("authorization")), request.headers.get("origin"))
    with sso._db() as c:
        _schema(c)
        row = c.execute("SELECT native_request FROM chat_web_approval_handles WHERE user_id=? AND handle=? AND expires_at>?",
                        (g["user_id"], handle, int(time.time()))).fetchone()
    if not row:
        raise HTTPException(404, "Запрос устройства не найден или истёк")
    return row["native_request"], d


@router.post("/devices/pending/{handle}/approve")
def approve_device(handle: str, body: ApprovalCode, request: Request):
    from chat_router import approve_pending, TdaApproveBody
    native, d = _pending_handle(request, handle)
    return approve_pending(native, TdaApproveBody(code=body.code), authorization="Bearer " + d["token"])


@router.post("/devices/pending/{handle}/deny")
def deny_device(handle: str, request: Request):
    from chat_router import deny_pending
    native, d = _pending_handle(request, handle)
    return deny_pending(native, authorization="Bearer " + d["token"])


@router.post("/files/upload")
async def upload_file(request: Request, to_username: str = Form(...), client_file_id: str = Form(...), blob: UploadFile = File(...)):
    g, _ = await asyncio.to_thread(device_session, _bearer(request.headers.get("authorization")), request.headers.get("origin"))
    if not 16 <= len(client_file_id) <= 128 or not to_username.strip():
        raise HTTPException(422, "Нужны to_username и client_file_id длиной 16–128 символов")
    _rate_limit(f"chat-web-file:{g['user_id']}", limit=30, window=600)
    chunks, total = [], 0
    try:
        while True:
            chunk = await blob.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > 100 * 1024 * 1024:
                raise HTTPException(413, "Максимальный размер шифрованного файла — 100 МБ")
            chunks.append(chunk)
    finally:
        await blob.close()
    if total < 16:
        raise HTTPException(422, "Не хватает шифрованных данных файла")
    encrypted = b"".join(chunks)
    chunks.clear()
    return await asyncio.to_thread(_save_file, g["user_id"], to_username.lower(), client_file_id, encrypted)


def _save_file(user_id, to_username, client_file_id, encrypted):
    from chat_router import _is_blocked
    from ecos_core.shared import _get_privacy_flags
    c = db()
    try:
        c.execute("CREATE TABLE IF NOT EXISTS gc_web_file_uploads (user_id INTEGER, client_file_id TEXT, receiver_id INTEGER, "
                  "content_hash TEXT, file_id INTEGER, created_at INTEGER, PRIMARY KEY(user_id, client_file_id))")
        c.commit()
        c.execute("BEGIN IMMEDIATE")
        peer = c.execute("SELECT id, is_bot FROM users WHERE username=?", (to_username,)).fetchone()
        if not peer:
            raise HTTPException(404, "Получатель не найден")
        digest = hashlib.sha256(encrypted).hexdigest()
        prior = c.execute("SELECT * FROM gc_web_file_uploads WHERE user_id=? AND client_file_id=?", (user_id, client_file_id)).fetchone()
        if prior:
            if prior["receiver_id"] != peer["id"] or prior["content_hash"] != digest:
                raise HTTPException(409, "client_file_id уже использован для другого файла")
            if not c.execute("SELECT 1 FROM chat_files WHERE id=? AND created_at>=datetime('now','-5 days')", (prior["file_id"],)).fetchone():
                raise HTTPException(410, "Файл уже удалён: нужна новая отправка")
            return {"file_id": prior["file_id"], "size": len(encrypted)}
        if peer["is_bot"] or _is_blocked(c, user_id, peer["id"]):
            raise HTTPException(403, "Этот получатель не принимает такое вложение")
        privacy = _get_privacy_flags(c, peer["id"]).get("message_privacy", "all")
        if privacy == "nobody" or (privacy == "contacts" and not c.execute("SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?", (peer["id"], user_id)).fetchone()):
            raise HTTPException(403, "Получатель ограничил личные сообщения")
        cur = c.execute("INSERT INTO chat_files (sender_id,receiver_id,blob,size) VALUES (?,?,?,?)", (user_id, peer["id"], encrypted, len(encrypted)))
        file_id = cur.lastrowid
        c.execute("INSERT INTO gc_web_file_uploads VALUES (?,?,?,?,?,?)", (user_id, client_file_id, peer["id"], digest, file_id, int(time.time())))
        c.commit()
        return {"file_id": file_id, "size": len(encrypted)}
    finally:
        c.close()


class BotSend(sso.SSOBody):
    to_username: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=4000)
    client_message_id: str = Field(min_length=16, max_length=128)


@router.post("/bots/send")
async def send_bot(body: BotSend, request: Request):
    from bot_api import send_human_message_to_bot
    from ecos_core.identity import auth_member
    _, d = await asyncio.to_thread(device_session, _bearer(request.headers.get("authorization")), request.headers.get("origin"))
    user = await asyncio.to_thread(auth_member, "Bearer " + d["token"])
    return await send_human_message_to_bot(user, to_username=body.to_username, text=body.text,
                                           client_message_id=body.client_message_id)


@router.get("/bots/{username}/info")
def bot_info(username: str, request: Request):
    grant_row, _ = device_session(_bearer(request.headers.get("authorization")), request.headers.get("origin"))
    _rate_limit(f"gcweb:botinfo:{grant_row['user_id']}", limit=60, window=60)
    username = username.strip().lower().lstrip("@")
    if not username or len(username) > 64:
        raise HTTPException(422, "Нужно имя пользователя бота")
    c = db()
    try:
        row = c.execute(
            "SELECT b.id, u.username, u.display_name, b.status FROM bots b "
            "JOIN users u ON u.id=b.user_id WHERE u.username=? AND u.is_bot=1 AND b.is_active=1",
            (username,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Бот не найден")
        return {"bot_id": row["id"], "username": row["username"], "display_name": row["display_name"], "status": row["status"]}
    finally:
        c.close()


class ChatScopeMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        if path == router.prefix + "/files/upload":
            headers = dict(scope.get("headers", []))
            try:
                await asyncio.to_thread(device_session, _bearer(headers.get(b"authorization", b"").decode()), headers.get(b"origin", b"").decode() or None)
            except HTTPException as exc:
                return await JSONResponse({"detail": exc.detail}, status_code=exc.status_code,
                                          headers={"Cache-Control": "no-store"})(scope, receive, send)
            return await self.app(scope, receive, send)
        if not (path.startswith("/api/chat/") or path.startswith("/api/bots/")) or path.startswith(router.prefix + "/"):
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        auth = headers.get(b"authorization", b"").decode()
        try:
            token = _bearer(auth)
        except HTTPException:
            return await self.app(scope, receive, send)
        with sso._db() as c:
            known = c.execute("SELECT 1 FROM access_tokens WHERE token_hash=?", (sso._hash(token),)).fetchone()
        if not known:
            return await self.app(scope, receive, send)
        try:
            if (path.startswith(("/api/bots/internal/", "/api/bots/storage/")) or path == "/api/bots/ws"
                    or path == "/api/chat/devices/pending" or path.startswith("/api/chat/devices/pending/")):
                raise HTTPException(403, "Эта операция не входит в доступ GhostChat")
            _, d = await asyncio.to_thread(device_session, token, headers.get(b"origin", b"").decode() or None)
        except HTTPException as exc:
            return await JSONResponse({"detail": exc.detail}, status_code=exc.status_code,
                                      headers={"Cache-Control": "no-store"})(scope, receive, send)
        scoped = dict(scope)
        scoped["headers"] = [(k, v) for k, v in scope["headers"] if k not in {b"authorization", b"x-gs-token"}]
        scoped["headers"].append((b"authorization", ("Bearer " + d["token"]).encode()))
        return await self.app(scoped, receive, send)


class _ScopedSocket:
    """Delegate to the proven signaling handler, with a narrow event allowlist."""
    def __init__(self, ws, token):
        self.ws, self.token = ws, token

    def __getattr__(self, key):
        return getattr(self.ws, key)

    async def accept(self, *args, **kwargs):
        pass  # accepted before the authentication frame

    async def receive_text(self):
        while True:
            text = await self.ws.receive_text()
            if len(text) > 65536:
                await self.ws.close(code=1009)
                raise WebSocketDisconnect(1009)
            try:
                await asyncio.to_thread(device_session, self.token)
            except HTTPException:
                await self.ws.close(code=4401)
                raise WebSocketDisconnect(4401)
            if text == "ping":
                return text
            try:
                kind = json.loads(text).get("type")
            except (ValueError, AttributeError):
                continue
            if kind in {"chat.typing", "presence.ask", "call.ice", "call.signal"}:
                return text

    async def send_json(self, value, *args, **kwargs):
        kind = value.get("type", "")
        if kind == "hello":
            data = value.get("data", {})
            value = {"type": "hello", "data": {k: data.get(k) for k in ("id", "username", "display_name")}}
        elif kind.startswith(("login.", "tda.")):
            value = {"type": "device.approval-pending", "data": {}}
        elif kind != "presence" and not kind.startswith(("chat.", "group.", "room.", "call.", "device.", "login.", "tda.", "bot.", "presence.")):
            return
        await self.ws.send_json(value, *args, **kwargs)


@router.websocket("/ws")
async def client_socket(ws: WebSocket):
    await ws.accept()
    origin = ws.headers.get("origin")
    try:
        if origin != sso._origin(sso._issuer()):
            LOGGER.warning("chat ws: чужой origin %r, закрываю 4403", origin)
            return await ws.close(code=4403)
        first = await asyncio.wait_for(ws.receive_json(), timeout=10)
        if not isinstance(first, dict) or first.get("type") != "auth":
            LOGGER.warning("chat ws: первый кадр не auth (%r), закрываю 4401", type(first).__name__)
            return await ws.close(code=4401)
        token = _bearer("Bearer " + str(first.get("token", "")))
        try:
            _, d = await asyncio.to_thread(device_session, token, origin)
        except HTTPException as exc:
            LOGGER.warning("chat ws: device_session отклонил (%s %s), закрываю 4401", exc.status_code,
                           exc.detail)
            raise
        from social_router import websocket_endpoint
        scoped = _ScopedSocket(ws, token)
        await websocket_endpoint(scoped, token=d["token"], x_gs_token="")
    except (HTTPException, asyncio.TimeoutError, ValueError) as exc:
        LOGGER.warning("chat ws: закрыт 4401 (%s: %s)", type(exc).__name__, exc)
        try:
            await ws.close(code=4401)
        except RuntimeError:
            pass
    except WebSocketDisconnect as exc:
        LOGGER.info("chat ws: клиент отключился (code=%s)", getattr(exc, "code", "?"))
    except Exception:
        LOGGER.exception("chat ws: неожиданная ошибка")
        try:
            await ws.close(code=1011)
        except RuntimeError:
            pass


def install(app):
    app.include_router(router)
    app.add_middleware(ChatScopeMiddleware)
