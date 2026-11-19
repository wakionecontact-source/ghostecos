from fastapi import APIRouter, Header, HTTPException, Query, UploadFile, File, Request, WebSocket, WebSocketDisconnect
import asyncio
from typing import Optional, List
from pydantic import BaseModel
from collections import defaultdict
import sqlite3, secrets, os, uuid, json, io, hashlib, hmac, re, time, random, base64

router = APIRouter(prefix="/api/soc", tags=["GhostSocial"])

VERSION = "0.1.0"

DB = os.getenv("SOCIAL_DB_PATH", '/opt/ghostchat/ghostchat.db')
MEDIA_DIR = os.getenv("SOCIAL_MEDIA_DIR", "/var/www/ghostsocial/media")
try: os.makedirs(MEDIA_DIR, exist_ok=True)
except Exception: pass

ALLOWED_IMAGE = {"jpg","jpeg","png","gif","webp"}
ALLOWED_VIDEO = {"mp4","webm","mov"}
ALLOWED_AUDIO = {"mp3","wav","ogg","m4a"}
MAX_IMAGE = 30 * 1024 * 1024
MAX_VIDEO = 50 * 1024 * 1024
MAX_AUDIO = 15 * 1024 * 1024

_NAME_MIN, _NAME_MAX = 2, 100
_USER_MIN, _USER_MAX, _USER_TOTAL = 3, 60, 64
_PASS_MIN, _PASS_MAX = 8, 150
_RESERVED = {
    'admin','administrator','root','system','ghost','ghostchat','ghostsocial',
    'ghostecos','support','help','mod','moderator','staff','team','official',
    'api','www','mail','test',
}

# ── Pydantic models ────────────────────────────────────────────────────────────

class RegisterBody(BaseModel):
    username: str
    display_name: str
    password: str
    ref: Optional[str] = None
    age_18_confirm: bool = False
    device_id: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None

class LoginBody(BaseModel):
    username: str
    password: str
    device_id: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None

class PollBody(BaseModel):
    question: str
    options: List[str]
    is_quiz: bool = False
    correct_idx: Optional[int] = None

class PostBody(BaseModel):
    text: str
    media: Optional[List[dict]] = None
    poll: Optional[PollBody] = None
    is_nsfw: Optional[bool] = False  # 18+ контент с обязательным блюром в ленте

class VoteBody(BaseModel):
    option_idx: int

class EditPostBody(BaseModel):
    text: Optional[str] = None
    media: Optional[List[dict]] = None  # медиа можно только УБРАТЬ (сократить список), не добавить
    is_nsfw: Optional[bool] = None      # автор может пометить позже; снять можно только если nsfw_set_by IS NULL

class CommentBody(BaseModel):
    text: str
    parent_comment_id: Optional[int] = None

class CommentReactBody(BaseModel):
    emoji: str

class EditProfileBody(BaseModel):
    display_name: Optional[str] = None
    username: Optional[str] = None
    new_password: Optional[str] = None
    old_password: Optional[str] = None

class ReactBody(BaseModel):
    emoji: Optional[str] = None  # null = снять реакцию

# ── Validation (mirrors Dart validators.dart) ──────────────────────────────────

def _ctrl(cp: int) -> bool:
    return cp < 0x20 or (0x7F <= cp <= 0x9F)

def _invis(cp: int) -> bool:
    return (cp in (0x00AD, 0x034F, 0xFEFF, 0x180E) or
            0x200B <= cp <= 0x200F or 0x202A <= cp <= 0x202E or
            0x2060 <= cp <= 0x2064 or 0x2066 <= cp <= 0x206F or
            0xFFF9 <= cp <= 0xFFFB)

def _comb(cp: int) -> bool:
    return (0x0300 <= cp <= 0x036F or 0x0483 <= cp <= 0x0489 or
            0x0591 <= cp <= 0x05BD or
            cp in (0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7) or
            0x0610 <= cp <= 0x061A or 0x064B <= cp <= 0x065F or cp == 0x0670 or
            0x06D6 <= cp <= 0x06DC or 0x06DF <= cp <= 0x06E4 or
            0x06E7 <= cp <= 0x06E8 or 0x06EA <= cp <= 0x06ED or
            0x0900 <= cp <= 0x0903 or 0x093A <= cp <= 0x094F or
            0x0951 <= cp <= 0x0957 or 0x1AB0 <= cp <= 0x1AFF or
            0x1DC0 <= cp <= 0x1DFF or 0x20D0 <= cp <= 0x20FF or
            0xFE20 <= cp <= 0xFE2F)

def _emoji(cp: int) -> bool:
    return (0x1F000 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF or
            0x2300 <= cp <= 0x23FF or 0x2B00 <= cp <= 0x2BFF or
            0x1F1E6 <= cp <= 0x1F1FF or 0xFE00 <= cp <= 0xFE0F or
            cp in (0x200D, 0x20E3, 0x203C, 0x2049, 0x2122, 0x2139) or
            0x2194 <= cp <= 0x21AA or 0x231A <= cp <= 0x231B or
            cp == 0x24C2 or 0x25AA <= cp <= 0x25FE or 0x2934 <= cp <= 0x2935)

def _val_name(raw: str) -> str:
    v = raw.strip()
    runes = list(v)
    if not runes:
        raise HTTPException(422, "Введите имя")
    if len(runes) < _NAME_MIN:
        raise HTTPException(422, f"Имя слишком короткое (минимум {_NAME_MIN})")
    if len(runes) > _NAME_MAX:
        raise HTTPException(422, f"Имя слишком длинное (максимум {_NAME_MAX})")
    for c in runes:
        cp = ord(c)
        if _ctrl(cp) or _invis(cp) or _comb(cp):
            raise HTTPException(422, "Имя содержит недопустимые символы")
    return v

def _val_username(raw: str) -> str:
    v = raw.strip().lower()
    if not v:
        raise HTTPException(422, "Введите имя пользователя")
    if len(v) > _USER_TOTAL:
        raise HTTPException(422, "Имя пользователя слишком длинное")
    for c in v:
        cp = ord(c)
        if not (0x61 <= cp <= 0x7A or 0x30 <= cp <= 0x39 or cp in (0x5F, 0x2E)):
            raise HTTPException(422, "Только латиница, цифры, _ и точка")
    nd = v.replace('.', '')
    if len(nd) < _USER_MIN:
        raise HTTPException(422, f"Минимум {_USER_MIN} символа (точки не в счёт)")
    if len(nd) > _USER_MAX:
        raise HTTPException(422, f"Максимум {_USER_MAX} символов (точки не в счёт)")
    if v in _RESERVED:
        raise HTTPException(422, "Это имя пользователя зарезервировано")
    return v

def _val_password(v: str) -> str:
    runes = list(v)
    if not runes:
        raise HTTPException(422, "Введите пароль")
    if len(runes) < _PASS_MIN:
        raise HTTPException(422, f"Пароль слишком короткий (минимум {_PASS_MIN} символов)")
    if len(runes) > _PASS_MAX:
        raise HTTPException(422, f"Пароль слишком длинный (максимум {_PASS_MAX} символов)")
    for c in runes:
        cp = ord(c)
        if _ctrl(cp):
            raise HTTPException(422, "Пароль содержит запрещённые символы")
        if _emoji(cp):
            raise HTTPException(422, "Пароль не должен содержать эмодзи")
    return v

# ── Password hashing ─────────────────────────────────────────────────────────
# Canonical: argon2 (общий с GhostChat).
# Legacy: pbkdf2 (старые GhostSocial-юзеры) — при первом успешном логине апгрейдим в argon2.

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

_ph = PasswordHasher()
_PBKDF2_ITERS = 260_000
# Константный argon2-хэш заведомо-непроверяемой строки. Нужен чтобы /login
# тратил одинаковое время для существующих и несуществующих пользователей.
_DUMMY_ARGON2_HASH = _ph.hash("__non-existent-user-dummy__")

def hash_argon2(password: str) -> str:
    return _ph.hash(password)

def verify_argon2(password: str, stored: str) -> bool:
    try:
        return _ph.verify(stored, password)
    except (VerifyMismatchError, InvalidHashError, Exception):
        return False

def verify_pbkdf2(password: str, stored: str) -> bool:
    try:
        salt_hex, key_hex = stored.split(':', 1)
        key = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), bytes.fromhex(salt_hex), _PBKDF2_ITERS)
        return hmac.compare_digest(key.hex(), key_hex)
    except Exception:
        return False

# ── SQLite helpers ─────────────────────────────────────────────────────────────

def _ci_contains(haystack, needle):
    if haystack is None or needle is None:
        return 0
    return 1 if needle.lower() in haystack.lower() else 0

def db():
    # timeout=5: вместо мгновенного 'database is locked' ждём до 5 сек на освобождение
    c = sqlite3.connect(DB, timeout=5.0)
    c.row_factory = sqlite3.Row
    c.create_function("ci_contains", 2, _ci_contains, deterministic=True)
    try:
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.execute("PRAGMA busy_timeout=5000")
    except Exception:
        pass
    return c

# ── WebSocket hub ──────────────────────────────────────────────────────────────
# Простой in-memory pub/sub. Один процесс uvicorn — подойдёт.
# Если когда-нибудь запустим несколько воркеров — придётся вынести в Redis.

class _WSHub:
    def __init__(self):
        self._by_uid: dict = defaultdict(set)
        self._crypto: dict = {}
        self._lock = asyncio.Lock()
        # Главный event loop — фиксируем при первом register (где есть running loop).
        # КРИТИЧНО: FastAPI выполняет `def` (sync) ручки в threadpool, у этих потоков
        # СВОЙ asyncio loop НЕ существует. asyncio.get_event_loop() из них бросает
        # RuntimeError → старый код silently возвращал и broadcast не работал.
        # Теперь сохраняем main loop здесь и шлём корутины через run_coroutine_threadsafe.
        self._loop = None

    async def register(self, uid: int, ws: WebSocket):
        if self._loop is None:
            try:
                self._loop = asyncio.get_running_loop()
            except RuntimeError:
                pass
        async with self._lock:
            self._by_uid[uid].add(ws)

    async def unregister(self, uid: int, ws: WebSocket):
        async with self._lock:
            self._by_uid[uid].discard(ws)
            if not self._by_uid[uid]:
                self._by_uid.pop(uid, None)
            self._crypto.pop(ws, None)

    def set_crypto(self, ws: WebSocket, aesgcm):
        """Зарегистрировать AES-GCM ключ для исходящих сообщений на этом сокете.
        Вызывается после успешного cs.hello handshake."""
        self._crypto[ws] = aesgcm

    async def _send(self, ws: WebSocket, payload: dict):
        try:
            aesgcm = self._crypto.get(ws)
            if aesgcm is not None:
                import os as _os, json as _json, base64 as _b64
                pt = _json.dumps(payload).encode('utf-8')
                iv = _os.urandom(12)
                ct = aesgcm.encrypt(iv, pt, None)
                payload = {"type": "cs.enc", "data": _b64.b64encode(iv + ct).decode()}
            await ws.send_json(payload)
        except Exception:
            pass

    def _schedule(self, coro):
        """Безопасно запустить корутину независимо от того, в каком потоке
        мы находимся (async ручка → main loop running, sync ручка → threadpool)."""
        loop = self._loop
        if loop is None:
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                coro.close()
                return
        if loop.is_running():
            try:
                asyncio.run_coroutine_threadsafe(coro, loop)
            except Exception:
                try: coro.close()
                except Exception: pass
        else:
            try: coro.close()
            except Exception: pass

    _PUBLIC_BROADCAST = {"post.new", "post.edit", "post.delete", "post.react",
                          "post.comment", "post.vote", "presence"}

    def broadcast(self, ev_type: str, data: dict):
        """Послать событие подключённым. Приватные (notif.*, chat.*) — только залогиненным.
        Гости (uid=0) получают только публичные события из _PUBLIC_BROADCAST."""
        payload = {"type": ev_type, "data": data}
        is_public = ev_type in self._PUBLIC_BROADCAST
        for uid, sockets in list(self._by_uid.items()):
            if uid == 0 and not is_public:
                continue  # гостям приватные события не показываем
            for ws in list(sockets):
                self._schedule(self._send(ws, payload))

    def send_to(self, uid: int, ev_type: str, data: dict):
        """Послать конкретному юзеру (всем его открытым вкладкам/устройствам).
        Работает из любого потока: async ручки И sync ручки (FastAPI threadpool)."""
        if uid is None or uid <= 0:
            return
        payload = {"type": ev_type, "data": data}
        for ws in list(self._by_uid.get(uid, ())):
            self._schedule(self._send(ws, payload))

ws_hub = _WSHub()

_WS_MAX_PER_USER = 10        # 10 вкладок/устройств на юзера — достаточно
_WS_MAX_PER_IP_GUEST = 20    # гостям с одного IP не больше 20 коннектов

@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query("")):
    """Real-time канал. Аутентификация через ?token=. Гость тоже допускается.
    Принимает входящие события клиента (JSON): typing, presence.
    """
    uid = 0
    username = None
    if token and not token.startswith("guest_"):
        c = db()
        row = c.execute(
            "SELECT u.id, u.username FROM soc_tokens t JOIN users u ON u.id=t.user_id WHERE t.token=?",
            (token,)
        ).fetchone()
        if not row:
            # TDA-1 bridge: device-уровневый токен из user_devices (после recovery
            # или /login с device_id попадает сюда, а НЕ в soc_tokens). HTTP auth()
            # тоже делает этот fallback — WS без него видел юзера как гостя.
            row = c.execute(
                "SELECT u.id, u.username FROM users u "
                "JOIN user_devices d ON d.user_id=u.id "
                "WHERE d.token=? AND d.is_active=1 AND d.is_blocked=0 LIMIT 1",
                (token,)
            ).fetchone()
        c.close()
        if row:
            uid = row["id"]
            username = row["username"]
    if uid > 0 and len(ws_hub._by_uid.get(uid, set())) >= _WS_MAX_PER_USER:
        await websocket.close(code=1008)  # policy violation
        return
    if uid == 0 and len(ws_hub._by_uid.get(0, set())) >= _WS_MAX_PER_IP_GUEST:
        await websocket.close(code=1008)
        return
    await websocket.accept()
    await ws_hub.register(uid, websocket)
    _c = db()
    _stats = get_user_stats(_c, uid)
    _flags = _c.execute(
        "SELECT username, display_name, is_admin, is_moderator FROM users WHERE id=?", (uid,)
    ).fetchone()
    _c.close()
    _me_payload = {
        "uid": uid, "id": uid, "user_id": uid,
        "username": (_flags["username"] if _flags else username),
        "display_name": (_flags["display_name"] if _flags else username),
        "is_guest": False,
        "is_admin": _is_admin_user({"username": (_flags["username"] if _flags else username),
                                     "is_admin": (_flags["is_admin"] if _flags else 0)}),
        "is_moderator": bool(_flags and _flags["is_moderator"]),
        **_stats,
    }
    await websocket.send_json({"type": "hello", "data": _me_payload})
    # Локальный AES-GCM ключ для этого соединения. None пока клиент не сделал
    # cs.hello handshake. Опционально: старые клиенты без шифрования продолжают
    # работать как раньше.
    _aesgcm = None

    async def _send_safe(payload: dict):
        """Шлёт payload — encrypted если есть _aesgcm, иначе plain.
        Используется в handlers ниже вместо прямого websocket.send_json."""
        nonlocal _aesgcm
        try:
            if _aesgcm is not None:
                import os as _os, json as _json, base64 as _b64
                pt = _json.dumps(payload).encode('utf-8')
                iv = _os.urandom(12)
                ct = _aesgcm.encrypt(iv, pt, None)
                await websocket.send_json({"type": "cs.enc", "data": _b64.b64encode(iv + ct).decode()})
            else:
                # БЕЗ recursion: plain fallback идёт прямо в websocket.send_json,
                # НЕ через _send_safe (был bulk-replace bug → ∞ рекурсия → silent fail).
                await websocket.send_json(payload)
        except Exception as _e:
            import logging as _lg, traceback as _tb
            _lg.getLogger('gc').warning('[_send_safe] FAIL on %s: %s\n%s',
                                         payload.get('type', '?'), _e, _tb.format_exc())

    # NB: убран broadcast presence — раньше все онлайн юзеры узнавали о входе/выходе
    # любого другого юзера. Это утечка социального графа. Теперь интересующиеся
    # должны спросить через presence.ask по конкретному username.
    try:
        while True:
            try:
                msg = await asyncio.wait_for(websocket.receive_text(), timeout=90)
            except asyncio.TimeoutError:
                break  # зомби-коннект → отключаем
            if msg == 'ping' or msg == 'cs.ping':
                await websocket.send_text('pong')
                continue
            if not msg or msg[0] != '{':
                continue
            try:
                ev = json.loads(msg)
            except Exception:
                continue
            t = ev.get("type")
            data = ev.get("data") or {}

            # ── cs.hello: handshake (один раз на коннект, опционально) ──
            # ECDH/HKDF — CPU-bound (~30-60мс), уносим в thread чтобы не
            # блокировать event loop. Иначе параллельные коннекты ждут в
            # очереди и handshake занимает секунды.
            if t == "cs.hello" and _aesgcm is None:
                try:
                    import os as _os, base64 as _b64, asyncio as _aio
                    from cryptography.hazmat.primitives.asymmetric import ec as _ec
                    from cryptography.hazmat.primitives.serialization import Encoding as _ENC, PublicFormat as _PF
                    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
                    from cryptography.hazmat.primitives import hashes
                    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
                    client_pub_b64 = data.get("client_pub") or ""
                    client_pub_raw = _b64.b64decode(client_pub_b64)
                    if len(client_pub_raw) != 65:
                        await websocket.send_json({"type":"cs.hello.err","data":{"error":"client_pub: 65 байт"}})
                        continue
                    def _do_ecdh():
                        client_key = _ec.EllipticCurvePublicKey.from_encoded_point(_ec.SECP256R1(), client_pub_raw)
                        server_priv = _ec.generate_private_key(_ec.SECP256R1())
                        shared = server_priv.exchange(_ec.ECDH(), client_key)
                        master = HKDF(algorithm=hashes.SHA256(), length=32, salt=b'\x00'*32, info=b'ghostchat-cs-v1').derive(shared)
                        aes = AESGCM(master)
                        spub = server_priv.public_key().public_bytes(_ENC.X962, _PF.UncompressedPoint)
                        return aes, spub
                    _aesgcm, server_pub_raw = await _aio.to_thread(_do_ecdh)
                    ws_hub.set_crypto(websocket, _aesgcm)
                    await websocket.send_json({"type":"cs.hello.ok","data":{
                        "server_pub": _b64.b64encode(server_pub_raw).decode(),
                    }})
                except Exception as _e:
                    try:
                        await websocket.send_json({"type":"cs.hello.err","data":{"error":"handshake failed"}})
                    except Exception:
                        pass
                continue

            if t == "cs.enc" and _aesgcm is not None:
                try:
                    import base64 as _b64
                    raw = ev.get("data")
                    blob = _b64.b64decode(raw if isinstance(raw, str) else (raw or {}).get("data", ""))
                    iv, ct = blob[:12], blob[12:]
                    pt = _aesgcm.decrypt(iv, ct, None)
                    inner = json.loads(pt.decode('utf-8'))
                    ev = inner
                    t = ev.get("type")
                    data = ev.get("data") or {}
                except Exception:
                    continue
            if t == "chat.typing" and username:
                to_user = (data.get("to") or "").lower()
                if not to_user:
                    continue
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (to_user,)).fetchone()
                # Анти-спам/анти-стейк: typing разрешён только если peer в контактах юзера
                # (т.е. они уже добавили друг друга / есть DM-история). Без этого
                # любой залогиненый юзер может слать жертве «X печатает» в любой момент.
                allowed = False
                if peer:
                    in_contacts = c.execute(
                        "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?",
                        (peer["id"], uid),
                    ).fetchone()
                    allowed = bool(in_contacts)
                c.close()
                if peer and allowed:
                    ws_hub.send_to(peer["id"], "chat.typing", {
                        "from_username": username,
                        "is_typing": bool(data.get("is_typing", True)),
                    })
            elif t == "chat.send" and uid:
                rid = data.get("request_id")
                to_username = (data.get("to_username") or "").lower().strip().lstrip("@")
                ciphertext = data.get("ciphertext") or ""
                err = None
                if not to_username:
                    err = "to_username обязателен"
                elif not isinstance(ciphertext, str) or len(ciphertext) > 8000:
                    err = "ciphertext: некорректный формат"
                if err is None:
                    try:
                        from .chat_router import _rate_limit as _rl
                        _rl(f"chatsend:{uid}", limit=120, window=60)
                    except HTTPException as he:
                        err = he.detail
                if err is None:
                    c = db()
                    to_user = c.execute(
                        "SELECT id, username, display_name, x25519_pub FROM users WHERE username=?",
                        (to_username,),
                    ).fetchone()
                    if not to_user:
                        err = "Получатель не найден"
                    elif to_user["id"] == uid:
                        err = "Нельзя отправить себе"
                    elif not to_user["x25519_pub"]:
                        err = "У получателя ещё нет E2E-ключей"
                    else:
                        c.execute(
                            "INSERT INTO chat_dm (sender_id, receiver_id, text) VALUES (?,?,?)",
                            (uid, to_user["id"], ciphertext),
                        )
                        msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
                        row = c.execute("SELECT created_at FROM chat_dm WHERE id=?", (msg_id,)).fetchone()
                        c.commit()
                        sender_row = c.execute("SELECT display_name FROM users WHERE id=?", (uid,)).fetchone()
                        payload = {
                            "id": msg_id,
                            "from_username": username,
                            "from_display_name": sender_row["display_name"] if sender_row else username,
                            "to_username": to_user["username"],
                            "ciphertext": ciphertext,
                            "created_at": row["created_at"],
                        }
                        sockets_recv = list(ws_hub._by_uid.get(to_user["id"], ()))
                        ws_hub.send_to(to_user["id"], "chat.new", payload)
                        ws_hub.send_to(uid, "chat.echo", payload)
                        c.close()
                        await _send_safe({"type": "chat.send.ok", "data": {
                            "request_id": rid,
                            "id": msg_id,
                            "created_at": row["created_at"],
                            "recipient_online": bool(sockets_recv),
                        }})
                        continue
                    c.close()
                if err is not None:
                    await _send_safe({"type": "chat.send.err", "data": {
                        "request_id": rid,
                        "error": str(err),
                    }})
            elif t == "chat.ack" and uid:
                rid = data.get("request_id")
                ids = data.get("ids") or []
                ids = [int(x) for x in ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
                if not ids:
                    await _send_safe({"type": "chat.ack.ok", "data": {"request_id": rid, "deleted": 0}})
                    continue
                c = db()
                ph = ",".join("?" * len(ids))
                rows = c.execute(
                    f"SELECT id, sender_id FROM chat_dm WHERE receiver_id=? AND id IN ({ph})",
                    [uid] + ids,
                ).fetchall()
                c.execute(f"DELETE FROM chat_dm WHERE receiver_id=? AND id IN ({ph})", [uid] + ids)
                deleted = c.total_changes
                c.commit()
                c.close()
                by_sender = {}
                for r in rows:
                    by_sender.setdefault(r["sender_id"], []).append(r["id"])
                for sender_id, mids in by_sender.items():
                    ws_hub.send_to(sender_id, "chat.delivered", {"ids": mids, "by_username": username})
                await _send_safe({"type": "chat.ack.ok", "data": {"request_id": rid, "deleted": deleted}})

            elif t == "chat.read" and uid:
                rid = data.get("request_id")
                ids = data.get("ids") or []
                ids = [int(x) for x in ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
                sender_uname = (data.get("from_username") or "").strip().lower()
                if not ids or not sender_uname:
                    await _send_safe({"type": "chat.read.ok", "data": {"request_id": rid, "sent": 0}})
                    continue
                c = db()
                r = c.execute("SELECT id FROM users WHERE username=?", (sender_uname,)).fetchone()
                if not r:
                    c.close()
                    await _send_safe({"type": "chat.read.ok", "data": {"request_id": rid, "sent": 0}})
                    continue
                sender_id = r["id"]
                try:
                    c.executemany(
                        "INSERT OR IGNORE INTO chat_dm_read_marks (sender_id, msg_id, recipient_id) VALUES (?,?,?)",
                        [(sender_id, mid, uid) for mid in ids],
                    )
                    c.commit()
                    c.execute("DELETE FROM chat_dm_read_marks WHERE read_at < datetime('now', '-30 day')")
                    c.commit()
                except Exception:
                    pass
                c.close()
                ws_hub.send_to(sender_id, "chat.read", {"ids": ids, "by_username": username})
                await _send_safe({"type": "chat.read.ok", "data": {"request_id": rid, "sent": len(ids)}})

            elif t == "chat.peer_pub" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                if not target:
                    await _send_safe({"type":"chat.peer_pub.err","data":{"request_id":rid,"error":"username обязателен"}})
                    continue
                c = db()
                row = c.execute("SELECT id, x25519_pub FROM users WHERE username=?", (target,)).fetchone()
                if not row:
                    c.close()
                    await _send_safe({"type":"chat.peer_pub.err","data":{"request_id":rid,"error":"Юзер не найден"}})
                    continue
                dev_rows = c.execute(
                    "SELECT pub_key FROM user_devices WHERE user_id=? AND is_active=1 AND is_blocked=0 AND pub_key IS NOT NULL",
                    (row["id"],),
                ).fetchall()
                c.close()
                await _send_safe({"type":"chat.peer_pub.ok","data":{
                    "request_id": rid,
                    "username": target,
                    "x25519_pub": row["x25519_pub"],
                    "device_pubkeys": [d["pub_key"] for d in dev_rows if d["pub_key"]],
                }})

            elif t == "chat.pending" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"pendlegacy:{uid}", limit=30, window=60)
                except HTTPException as he:
                    await _send_safe({"type":"chat.pending.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                c = db()
                rows = c.execute("""
                    SELECT m.id, m.sender_id, m.text as ciphertext, m.created_at,
                           u.username as from_username, u.display_name as from_display_name
                    FROM chat_dm m JOIN users u ON u.id = m.sender_id
                    WHERE m.receiver_id = ?
                    ORDER BY m.id ASC LIMIT 500
                """, (uid,)).fetchall()
                me_row = c.execute("SELECT username FROM users WHERE id=?", (uid,)).fetchone()
                c.close()
                me_uname = me_row["username"] if me_row else username
                await _send_safe({"type":"chat.pending.ok","data":{
                    "request_id": rid,
                    "messages": [
                        {"id": r["id"], "from_username": r["from_username"],
                         "from_display_name": r["from_display_name"],
                         "to_username": me_uname,
                         "ciphertext": r["ciphertext"], "created_at": r["created_at"]}
                        for r in rows
                    ],
                }})

            elif t == "keys.me" and uid:
                rid = data.get("request_id")
                c = db()
                row = c.execute(
                    "SELECT x25519_pub, encrypted_private_key, key_salt, key_storage_mode FROM users WHERE id=?",
                    (uid,),
                ).fetchone()
                cur_tok = data.get("_self_token") or ""  # клиент может не знать
                other_devs = c.execute(
                    "SELECT pub_key FROM user_devices "
                    "WHERE user_id=? AND is_active=1 AND is_blocked=0 AND pub_key IS NOT NULL "
                    "AND token != ?", (uid, cur_tok),
                ).fetchall()
                c.close()
                storage_mode = row["key_storage_mode"] if row else None
                is_local = (storage_mode == "local")
                await _send_safe({"type":"keys.me.ok","data":{
                    "request_id": rid,
                    "x25519_pub": row["x25519_pub"] if row else None,
                    "encrypted_private_key": None if is_local else (row["encrypted_private_key"] if row else None),
                    "key_salt": None if is_local else (row["key_salt"] if row else None),
                    "other_device_pubkeys": [d["pub_key"] for d in other_devs],
                    "storage_mode": storage_mode,
                }})

            elif t == "keys.upload" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"keys:{uid}", limit=5, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"keys.upload.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                x25519_pub = data.get("x25519_pub") or ""
                encrypted_private_key = data.get("encrypted_private_key")
                key_salt = data.get("key_salt")
                storage_mode_in = (data.get("storage_mode") or "").lower() or None
                import base64 as _b64
                try:
                    raw_pub = _b64.b64decode(x25519_pub) if isinstance(x25519_pub, str) else b""
                except Exception:
                    raw_pub = b""
                if len(raw_pub) not in (32, 65):
                    await _send_safe({"type":"keys.upload.err","data":{"request_id":rid,"error":"x25519_pub: ожидается 32 или 65 байт"}})
                    continue
                c = db()
                cur = c.execute("SELECT key_storage_mode FROM users WHERE id=?", (uid,)).fetchone()
                saved_mode = cur["key_storage_mode"] if cur else None
                mode = (storage_mode_in or saved_mode or "server").lower()
                if mode not in ("server", "local"):
                    c.close()
                    await _send_safe({"type":"keys.upload.err","data":{"request_id":rid,"error":"storage_mode"}})
                    continue
                if mode == "server":
                    if not encrypted_private_key or not key_salt:
                        c.close()
                        await _send_safe({"type":"keys.upload.err","data":{"request_id":rid,"error":"server-mode требует encrypted_private_key+key_salt"}})
                        continue
                    priv_store, salt_store = encrypted_private_key, key_salt
                else:
                    priv_store, salt_store = None, None
                c.execute(
                    "UPDATE users SET x25519_pub=?, encrypted_private_key=?, key_salt=?, in_ghostchat=1, key_storage_mode=? WHERE id=?",
                    (x25519_pub, priv_store, salt_store, mode, uid),
                )
                c.commit()
                c.close()
                await _send_safe({"type":"keys.upload.ok","data":{"request_id":rid,"status":"ok","storage_mode":mode}})

            elif t == "keys.storage_mode.get" and uid:
                rid = data.get("request_id")
                c = db()
                row = c.execute(
                    "SELECT key_storage_mode, x25519_pub, (encrypted_private_key IS NOT NULL) AS has_server_priv FROM users WHERE id=?",
                    (uid,),
                ).fetchone()
                c.close()
                await _send_safe({"type":"keys.storage_mode.get.ok","data":{
                    "request_id": rid,
                    "mode": row["key_storage_mode"] if row else None,
                    "has_pub": bool(row and row["x25519_pub"]),
                    "has_server_priv": bool(row and row["has_server_priv"]),
                }})
            elif t == "keys.storage_mode.set" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"keymode:{uid}", limit=10, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"keys.storage_mode.set.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                mode = (data.get("mode") or "").lower()
                if mode not in ("server", "local"):
                    await _send_safe({"type":"keys.storage_mode.set.err","data":{"request_id":rid,"error":"mode"}})
                    continue
                c = db()
                if mode == "local":
                    c.execute(
                        "UPDATE users SET key_storage_mode='local', encrypted_private_key=NULL, key_salt=NULL WHERE id=?",
                        (uid,),
                    )
                    c.commit()
                    c.close()
                    await _send_safe({"type":"keys.storage_mode.set.ok","data":{"request_id":rid,"status":"ok","mode":"local"}})
                else:
                    has_priv = c.execute(
                        "SELECT (encrypted_private_key IS NOT NULL) AS has_priv FROM users WHERE id=?",
                        (uid,),
                    ).fetchone()
                    c.execute("UPDATE users SET key_storage_mode='server' WHERE id=?", (uid,))
                    c.commit()
                    c.close()
                    await _send_safe({"type":"keys.storage_mode.set.ok","data":{
                        "request_id": rid, "status":"ok", "mode":"server",
                        "needs_upload": not bool(has_priv and has_priv["has_priv"]),
                    }})

            elif t == "keys.server_copy.delete" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"keywipe:{uid}", limit=10, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"keys.server_copy.delete.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                c = db()
                c.execute("UPDATE users SET encrypted_private_key=NULL, key_salt=NULL WHERE id=?", (uid,))
                c.commit()
                c.close()
                await _send_safe({"type":"keys.server_copy.delete.ok","data":{"request_id":rid,"status":"ok"}})

            elif t == "devices.list" and uid:
                rid = data.get("request_id")
                import device_auth as _da
                c = db()
                try:
                    devs = _da.list_user_devices(c, uid)
                    cur_id = None
                    for d in devs:
                        d["is_current"] = False
                    await _send_safe({"type":"devices.list.ok","data":{
                        "request_id": rid, "devices": devs, "current_id": cur_id,
                    }})
                finally:
                    c.close()

            elif t == "devices.rename" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"devrename:{uid}", limit=20, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"devices.rename.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                device_pk = int(data.get("device_pk") or 0)
                name = (data.get("name") or "").strip()
                if not name or len(name) > 60:
                    await _send_safe({"type":"devices.rename.err","data":{"request_id":rid,"error":"name 1..60"}})
                    continue
                c = db()
                r = c.execute("SELECT id FROM user_devices WHERE id=? AND user_id=? LIMIT 1", (device_pk, uid)).fetchone()
                if not r:
                    c.close()
                    await _send_safe({"type":"devices.rename.err","data":{"request_id":rid,"error":"Устройство не найдено"}})
                    continue
                c.execute("UPDATE user_devices SET device_name=? WHERE id=?", (name, r["id"]))
                c.commit()
                c.close()
                await _send_safe({"type":"devices.rename.ok","data":{"request_id":rid,"status":"ok","name":name}})

            elif t == "devices.revoke" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"devrevoke:{uid}", limit=20, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"devices.revoke.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                device_pk = int(data.get("device_pk") or 0)
                import device_auth as _da
                c = db()
                try:
                    ok = _da.revoke_device(c, uid, device_pk)
                    if not ok:
                        await _send_safe({"type":"devices.revoke.err","data":{"request_id":rid,"error":"Устройство не найдено"}})
                    else:
                        try:
                            ws_hub.send_to(uid, "device.revoked", {"device_pk": device_pk})
                        except Exception:
                            pass
                        await _send_safe({"type":"devices.revoke.ok","data":{"request_id":rid,"status":"ok"}})
                finally:
                    c.close()

            elif t == "contacts.list" and uid:
                rid = data.get("request_id")
                c = db()
                rows = c.execute("""
                    SELECT u.username, u.display_name, cc.added_at
                    FROM chat_contacts cc JOIN users u ON cc.contact_id = u.id
                    WHERE cc.owner_id = ?
                    ORDER BY u.display_name COLLATE NOCASE
                """, (uid,)).fetchall()
                c.close()
                await _send_safe({"type":"contacts.list.ok","data":{
                    "request_id": rid,
                    "contacts": [{"username":r["username"],"display_name":r["display_name"],"added_at":r["added_at"]} for r in rows],
                }})

            elif t == "contacts.add" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"contactadd:{uid}", limit=60, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"contacts.add.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                target = (data.get("username") or "").lower().strip().lstrip("@")
                c = db()
                peer = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (target,)).fetchone()
                if not peer:
                    c.close()
                    await _send_safe({"type":"contacts.add.err","data":{"request_id":rid,"error":"Юзер не найден"}})
                    continue
                if peer["id"] == uid:
                    c.close()
                    await _send_safe({"type":"contacts.add.err","data":{"request_id":rid,"error":"self"}})
                    continue
                c.execute("INSERT OR IGNORE INTO chat_contacts (owner_id, contact_id) VALUES (?,?)", (uid, peer["id"]))
                c.commit()
                c.close()
                await _send_safe({"type":"contacts.add.ok","data":{"request_id":rid,"status":"ok","username":peer["username"],"display_name":peer["display_name"]}})
            elif t == "contacts.remove" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"contactdel:{uid}", limit=60, window=3600)
                except HTTPException as he:
                    await _send_safe({"type":"contacts.remove.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                target = (data.get("username") or "").lower().strip().lstrip("@")
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (target,)).fetchone()
                if peer:
                    c.execute("DELETE FROM chat_contacts WHERE owner_id=? AND contact_id=?", (uid, peer["id"]))
                    c.commit()
                c.close()
                await _send_safe({"type":"contacts.remove.ok","data":{"request_id":rid,"status":"ok"}})
            elif t == "contacts.check" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (target,)).fetchone()
                in_c = False
                if peer:
                    r = c.execute("SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?", (uid, peer["id"])).fetchone()
                    in_c = bool(r)
                c.close()
                await _send_safe({"type":"contacts.check.ok","data":{"request_id":rid,"in_contacts":in_c}})

            elif t == "support_admin" and uid:
                rid = data.get("request_id")
                c = db()
                from .chat_router import SUPPORT_ADMIN_USERNAME as _SUP
                r = c.execute(
                    "SELECT id, username, display_name, x25519_pub FROM users WHERE username=?",
                    (_SUP,),
                ).fetchone()
                c.close()
                if not r:
                    await _send_safe({"type":"support_admin.ok","data":{
                        "request_id": rid, "username": None, "display_name": None, "is_me": False, "pub": None,
                    }})
                else:
                    await _send_safe({"type":"support_admin.ok","data":{
                        "request_id": rid, "username": r["username"], "display_name": r["display_name"],
                        "x25519_pub": r["x25519_pub"], "is_me": (username == r["username"]),
                    }})

            elif t == "delivery_status" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"delivstat:{uid}", limit=60, window=60)
                except HTTPException as he:
                    await _send_safe({"type":"delivery_status.err","data":{"request_id":rid,"error":he.detail}})
                    continue
                ids = data.get("ids") or []
                ids = [int(x) for x in ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
                if not ids:
                    await _send_safe({"type":"delivery_status.ok","data":{"request_id":rid,"result":{}}})
                    continue
                c = db()
                ph = ",".join("?" * len(ids))
                pending_rows = c.execute(f"SELECT id FROM chat_dm WHERE sender_id=? AND id IN ({ph})", [uid] + ids).fetchall()
                still_pending = {r["id"] for r in pending_rows}
                read_rows = c.execute(f"SELECT msg_id FROM chat_dm_read_marks WHERE sender_id=? AND msg_id IN ({ph})", [uid] + ids).fetchall()
                read_ids = {r["msg_id"] for r in read_rows}
                c.close()
                def _stat(i):
                    if i in still_pending: return "pending"
                    if i in read_ids: return "read"
                    return "delivered"
                await _send_safe({"type":"delivery_status.ok","data":{
                    "request_id": rid, "result": {str(i): _stat(i) for i in ids},
                }})

            elif t == "prof.get" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                offset_n = int(data.get("offset") or 0)
                c = db()
                u_row = c.execute("SELECT * FROM users WHERE username=?", (target,)).fetchone()
                if not u_row:
                    c.close()
                    await _send_safe({"type":"prof.get.err","data":{"request_id":rid,"error":"User not found"}})
                    continue
                u = dict(u_row)
                stats = get_user_stats(c, u["id"])
                am_following = c.execute(
                    "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?", (uid, u["id"]),
                ).fetchone() is not None
                rows = c.execute("""
                    SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
                           u.username, u.display_name,
                           (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
                    FROM soc_posts p JOIN users u ON p.user_id=u.id
                    WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
                """, (u["id"], offset_n)).fetchall()
                posts = _hydrate_posts(c, rows, uid)
                c.close()
                rep_score = int(u.get("reputation_score") if u.get("reputation_score") is not None else 100)
                if u.get("eternal_status_text"):
                    status_text = u.get("eternal_status_text")
                    status_mood = u.get("eternal_status_mood")
                    status_eternal = True
                elif _status_active(u.get("daily_status_set_at")):
                    status_text = u.get("daily_status_text")
                    status_mood = u.get("daily_status_mood")
                    status_eternal = False
                else:
                    status_text = None; status_mood = None; status_eternal = False
                await _send_safe({"type":"prof.get.ok","data":{
                    "request_id": rid,
                    "user_id": u["id"],
                    "username": u["username"],
                    "display_name": u["display_name"],
                    "am_following": am_following,
                    "is_me": uid == u["id"],
                    "reputation_score": rep_score,
                    "reputation_band": "low" if rep_score < 30 else ("mid" if rep_score < 70 else "good"),
                    "daily_status": status_text,
                    "daily_status_mood": status_mood,
                    "daily_status_eternal": status_eternal,
                    **stats,
                    "posts": posts,
                }})

            elif t == "keys.me" and uid:
                rid = data.get("request_id")
                c = db()
                row = c.execute(
                    "SELECT x25519_pub, encrypted_private_key, key_salt, key_storage_mode FROM users WHERE id=?",
                    (uid,),
                ).fetchone()
                # Token этой сессии — чтобы исключить self-device из other_device_pubkeys.
                # WS не передаёт authorization, но у нас есть текущая token-переменная из handshake.
                ws_token = token  # из ?token=… handshake-параметра
                other_devs = c.execute(
                    "SELECT pub_key FROM user_devices WHERE user_id=? AND is_active=1 AND is_blocked=0 AND pub_key IS NOT NULL AND token != ?",
                    (uid, ws_token),
                ).fetchall()
                c.close()
                storage_mode = row["key_storage_mode"] if row else None
                is_local = (storage_mode == "local")
                await _send_safe({"type": "keys.me.ok", "data": {
                    "request_id": rid,
                    "x25519_pub": row["x25519_pub"] if row else None,
                    "encrypted_private_key": None if is_local else (row["encrypted_private_key"] if row else None),
                    "key_salt": None if is_local else (row["key_salt"] if row else None),
                    "other_device_pubkeys": [d["pub_key"] for d in other_devs],
                    "storage_mode": storage_mode,
                }})

            elif t == "keys.storage_mode.get" and uid:
                rid = data.get("request_id")
                c = db()
                row = c.execute(
                    "SELECT key_storage_mode, x25519_pub, (encrypted_private_key IS NOT NULL) AS has_server_priv FROM users WHERE id=?",
                    (uid,),
                ).fetchone()
                c.close()
                await _send_safe({"type": "keys.storage_mode.get.ok", "data": {
                    "request_id": rid,
                    "mode": row["key_storage_mode"] if row else None,
                    "has_pub": bool(row and row["x25519_pub"]),
                    "has_server_priv": bool(row and row["has_server_priv"]),
                }})

            elif t == "keys.storage_mode.set" and uid:
                rid = data.get("request_id")
                mode = (data.get("mode") or "").lower()
                if mode not in ("server", "local"):
                    await _send_safe({"type": "keys.storage_mode.set.err", "data": {"request_id": rid, "error": "mode: ожидается 'server' или 'local'"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"keymode:{uid}", limit=10, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "keys.storage_mode.set.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                if mode == "local":
                    c.execute(
                        "UPDATE users SET key_storage_mode='local', encrypted_private_key=NULL, key_salt=NULL WHERE id=?",
                        (uid,),
                    )
                    c.commit(); c.close()
                    await _send_safe({"type": "keys.storage_mode.set.ok", "data": {"request_id": rid, "mode": "local"}})
                else:
                    has_priv_row = c.execute(
                        "SELECT (encrypted_private_key IS NOT NULL) AS has_priv FROM users WHERE id=?", (uid,)
                    ).fetchone()
                    c.execute("UPDATE users SET key_storage_mode='server' WHERE id=?", (uid,))
                    c.commit(); c.close()
                    await _send_safe({"type": "keys.storage_mode.set.ok", "data": {
                        "request_id": rid,
                        "mode": "server",
                        "needs_upload": not bool(has_priv_row and has_priv_row["has_priv"]),
                    }})

            elif t == "devices.list" and uid:
                rid = data.get("request_id")
                import device_auth as _da
                c = db()
                try:
                    devs = _da.list_user_devices(c, uid)
                    ws_token = token  # из ?token=… handshake-параметра
                    cur = c.execute("SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1", (ws_token, uid)).fetchone()
                    cur_id = cur["id"] if cur else None
                    for d_ in devs:
                        d_["is_current"] = (d_["id"] == cur_id)
                    await _send_safe({"type": "devices.list.ok", "data": {"request_id": rid, "devices": devs, "current_id": cur_id}})
                finally:
                    c.close()

            elif t == "devices.rename" and uid:
                rid = data.get("request_id")
                pk = data.get("device_pk")
                name = (data.get("name") or "").strip()
                if not isinstance(pk, int) or not name or len(name) > 60:
                    await _send_safe({"type": "devices.rename.err", "data": {"request_id": rid, "error": "invalid params"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"devrename:{uid}", limit=20, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "devices.rename.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                try:
                    r = c.execute("SELECT id FROM user_devices WHERE id=? AND user_id=? LIMIT 1", (pk, uid)).fetchone()
                    if not r:
                        await _send_safe({"type": "devices.rename.err", "data": {"request_id": rid, "error": "Устройство не найдено"}})
                    else:
                        c.execute("UPDATE user_devices SET device_name=? WHERE id=?", (name, r["id"]))
                        c.commit()
                        await _send_safe({"type": "devices.rename.ok", "data": {"request_id": rid, "name": name}})
                finally:
                    c.close()

            elif t == "devices.revoke" and uid:
                rid = data.get("request_id")
                pk = data.get("device_pk")
                if not isinstance(pk, int):
                    await _send_safe({"type": "devices.revoke.err", "data": {"request_id": rid, "error": "device_pk required"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"devrevoke:{uid}", limit=20, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "devices.revoke.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                import device_auth as _da
                c = db()
                try:
                    ws_token = token  # из ?token=… handshake-параметра
                    cur = c.execute("SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1", (ws_token, uid)).fetchone()
                    if cur and cur["id"] == pk:
                        await _send_safe({"type": "devices.revoke.err", "data": {"request_id": rid, "error": "Нельзя отозвать текущее устройство — выйдите через «Выход»"}})
                    else:
                        ok = _da.revoke_device(c, uid, pk)
                        if not ok:
                            await _send_safe({"type": "devices.revoke.err", "data": {"request_id": rid, "error": "Устройство не найдено"}})
                        else:
                            try: ws_hub.send_to(uid, "device.revoked", {"device_pk": pk})
                            except Exception: pass
                            await _send_safe({"type": "devices.revoke.ok", "data": {"request_id": rid}})
                finally:
                    c.close()

            elif t == "contacts.list" and uid:
                rid = data.get("request_id")
                c = db()
                rows = c.execute("""
                    SELECT u.username, u.display_name, cc.added_at
                    FROM chat_contacts cc JOIN users u ON cc.contact_id = u.id
                    WHERE cc.owner_id = ?
                    ORDER BY u.display_name COLLATE NOCASE
                """, (uid,)).fetchall()
                c.close()
                await _send_safe({"type": "contacts.list.ok", "data": {
                    "request_id": rid,
                    "contacts": [{"username": r["username"], "display_name": r["display_name"], "added_at": r["added_at"]} for r in rows],
                }})

            elif t == "contacts.add" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                if not target:
                    await _send_safe({"type": "contacts.add.err", "data": {"request_id": rid, "error": "username required"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl, _get_user_by_username as _gu
                    _rl(f"contactadd:{uid}", limit=60, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "contacts.add.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                peer = _gu(c, target)
                if not peer:
                    c.close()
                    await _send_safe({"type": "contacts.add.err", "data": {"request_id": rid, "error": "Юзер не найден"}})
                    continue
                if peer["id"] == uid:
                    c.close()
                    await _send_safe({"type": "contacts.add.err", "data": {"request_id": rid, "error": "Нельзя добавить себя"}})
                    continue
                c.execute("INSERT OR IGNORE INTO chat_contacts (owner_id, contact_id) VALUES (?,?)", (uid, peer["id"]))
                c.commit(); c.close()
                await _send_safe({"type": "contacts.add.ok", "data": {"request_id": rid, "username": peer["username"], "display_name": peer["display_name"]}})

            elif t == "contacts.remove" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                if not target:
                    await _send_safe({"type": "contacts.remove.err", "data": {"request_id": rid, "error": "username required"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl, _get_user_by_username as _gu
                    _rl(f"contactdel:{uid}", limit=60, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "contacts.remove.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                peer = _gu(c, target)
                if not peer:
                    c.close()
                    await _send_safe({"type": "contacts.remove.err", "data": {"request_id": rid, "error": "Юзер не найден"}})
                    continue
                c.execute("DELETE FROM chat_contacts WHERE owner_id=? AND contact_id=?", (uid, peer["id"]))
                c.commit(); c.close()
                await _send_safe({"type": "contacts.remove.ok", "data": {"request_id": rid}})

            elif t == "contacts.check" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip().lstrip("@")
                if not target:
                    await _send_safe({"type": "contacts.check.ok", "data": {"request_id": rid, "in_contacts": False}})
                    continue
                from .chat_router import _get_user_by_username as _gu
                c = db()
                peer = _gu(c, target)
                if not peer:
                    c.close()
                    await _send_safe({"type": "contacts.check.ok", "data": {"request_id": rid, "in_contacts": False}})
                    continue
                r = c.execute("SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?", (uid, peer["id"])).fetchone()
                c.close()
                await _send_safe({"type": "contacts.check.ok", "data": {"request_id": rid, "in_contacts": r is not None}})

            elif t == "group.my" and uid:
                rid = data.get("request_id")
                c = db()
                rows = c.execute("""
                    SELECT g.id, g.name, g.kind, g.owner_id, g.created_at,
                           g.username, g.bio, g.is_public,
                           m.is_admin,
                           (SELECT COUNT(*) FROM chat_group_members WHERE group_id=g.id) as members_count
                    FROM chat_groups g
                    JOIN chat_group_members m ON m.group_id = g.id
                    WHERE m.user_id = ?
                    ORDER BY g.id DESC
                """, (uid,)).fetchall()
                c.close()
                groups = [{
                    "id": r["id"], "name": r["name"], "kind": r["kind"],
                    "owner_id": r["owner_id"], "username": r["username"],
                    "bio": r["bio"], "is_public": bool(r["is_public"]),
                    "is_admin": bool(r["is_admin"]),
                    "is_owner": r["owner_id"] == uid,
                    "members_count": r["members_count"],
                    "created_at": r["created_at"],
                } for r in rows]
                await _send_safe({"type": "group.my.ok", "data": {"request_id": rid, "groups": groups}})

            elif t == "group.pending" and uid:
                rid = data.get("request_id")
                gid = data.get("gid")
                if not isinstance(gid, int):
                    await _send_safe({"type": "group.pending.err", "data": {"request_id": rid, "error": "gid required"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl, _is_group_member as _ism
                    _rl(f"grouppend:{uid}:{gid}", limit=20, window=60)
                except HTTPException as he:
                    await _send_safe({"type": "group.pending.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                if not _ism(c, gid, uid):
                    c.close()
                    await _send_safe({"type": "group.pending.err", "data": {"request_id": rid, "error": "Не участник группы"}})
                    continue
                rows = c.execute("""
                    SELECT m.id, m.sender_id, m.ciphertext, m.envelope_keys, m.created_at,
                           u.username as from_username, u.display_name as from_display_name
                    FROM chat_group_messages m
                    JOIN users u ON u.id = m.sender_id
                    LEFT JOIN chat_group_acks a ON a.msg_id = m.id AND a.user_id = ?
                    WHERE m.group_id = ? AND a.msg_id IS NULL AND m.sender_id <> ?
                    ORDER BY m.id ASC
                    LIMIT 500
                """, (uid, gid, uid)).fetchall()
                c.close()
                out = []
                for r in rows:
                    try:
                        envs = json.loads(r["envelope_keys"])
                    except Exception:
                        envs = {}
                    my_env = envs.get(str(uid))
                    if not my_env:
                        continue
                    out.append({
                        "id": r["id"], "group_id": gid,
                        "sender_id": r["sender_id"],
                        "from_username": r["from_username"],
                        "from_display_name": r["from_display_name"],
                        "ciphertext": r["ciphertext"],
                        "envelope_keys": {str(uid): my_env},
                        "created_at": r["created_at"],
                    })
                await _send_safe({"type": "group.pending.ok", "data": {"request_id": rid, "messages": out}})

            elif t == "tda.pending.list" and uid:
                rid = data.get("request_id")
                now_ = int(time.time())
                c = db()
                rows = c.execute(
                    "SELECT request_id, device_id, device_name, phase, created_at, expires_at "
                    "FROM pending_logins WHERE username=? AND phase='pending' AND expires_at > ? "
                    "ORDER BY created_at DESC",
                    (username, now_),
                ).fetchall()
                c.close()
                await _send_safe({"type": "tda.pending.list.ok", "data": {
                    "request_id": rid,
                    "pending": [dict(r) for r in rows],
                }})

            elif t == "tda.approve" and uid:
                rid = data.get("request_id")
                target_rid = data.get("login_request_id") or ""
                code = (data.get("code") or "").strip()
                if not target_rid or not code:
                    await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "request_id и code обязательны"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"tda_appr:{uid}", limit=30, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                try:
                    from security import verify_argon2 as _verify
                except Exception:
                    from social_router import verify_argon2 as _verify
                import device_auth as _da
                c = db()
                try:
                    r = c.execute(
                        "SELECT * FROM pending_logins WHERE request_id=? AND username=? LIMIT 1",
                        (target_rid, username),
                    ).fetchone()
                    if not r:
                        await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "Запрос не найден"}})
                        continue
                    if r["phase"] != "pending":
                        await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "Запрос уже обработан"}})
                        continue
                    if int(r["expires_at"]) < int(time.time()):
                        await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "Срок запроса истёк"}})
                        continue
                    if int(r["attempt_count"]) >= 5:
                        c.execute("UPDATE pending_logins SET phase='denied' WHERE id=?", (r["id"],))
                        c.commit()
                        try: ws_hub.send_to(uid, "tda.pending.gone", {"login_request_id": target_rid, "phase": "denied", "reason": "too_many_attempts"})
                        except Exception: pass
                        await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "Превышен лимит попыток — запрос отклонён"}})
                        continue
                    if not _verify(code, r["code_hash"]):
                        c.execute("UPDATE pending_logins SET attempt_count=attempt_count+1 WHERE id=?", (r["id"],))
                        c.commit()
                        await _send_safe({"type": "tda.approve.err", "data": {"request_id": rid, "error": "Неверный код"}})
                        continue
                    d = _da.register_device(c, uid, r["device_id"], r["device_name"], None, is_owner=False)
                    c.execute(
                        "UPDATE pending_logins SET phase='approved', granted_token=? WHERE id=?",
                        (d["token"], r["id"]),
                    )
                    c.commit()
                    try: ws_hub.send_to(uid, "tda.pending.gone", {"login_request_id": target_rid, "phase": "approved", "device_name": r["device_name"]})
                    except Exception: pass
                    await _send_safe({"type": "tda.approve.ok", "data": {"request_id": rid, "device_name": r["device_name"]}})
                finally:
                    c.close()

            # ── tda.block: {login_request_id} — отклонить + заблокировать device навсегда ──
            elif t == "tda.block" and uid:
                rid = data.get("request_id")
                target_rid = data.get("login_request_id") or ""
                if not target_rid:
                    await _send_safe({"type": "tda.block.err", "data": {"request_id": rid, "error": "request_id обязателен"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"tda_block:{uid}", limit=30, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "tda.block.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                try:
                    r = c.execute(
                        "SELECT id, phase, device_id, device_name FROM pending_logins "
                        "WHERE request_id=? AND username=? LIMIT 1",
                        (target_rid, username),
                    ).fetchone()
                    if not r:
                        await _send_safe({"type": "tda.block.err", "data": {"request_id": rid, "error": "Запрос не найден"}})
                        continue
                    if r["phase"] == "pending":
                        c.execute("UPDATE pending_logins SET phase='denied' WHERE id=?", (r["id"],))
                    # 2) Блокируем device_id у этого юзера.
                    #    Если запись была — UPDATE; если нет — INSERT с is_active=0, is_blocked=1.
                    dev = c.execute(
                        "SELECT id FROM user_devices WHERE user_id=? AND device_id=? LIMIT 1",
                        (uid, r["device_id"]),
                    ).fetchone()
                    if dev:
                        c.execute(
                            "UPDATE user_devices SET is_blocked=1, is_active=0 WHERE id=?",
                            (dev["id"],),
                        )
                    else:
                        c.execute(
                            "INSERT INTO user_devices (user_id, device_id, device_name, platform, is_active, is_blocked, is_owner) "
                            "VALUES (?, ?, ?, NULL, 0, 1, 0)",
                            (uid, r["device_id"], (r["device_name"] or "Заблокировано")),
                        )
                    c.commit()
                    try: ws_hub.send_to(uid, "tda.pending.gone", {"login_request_id": target_rid, "phase": "blocked", "device_name": r["device_name"]})
                    except Exception: pass
                    await _send_safe({"type": "tda.block.ok", "data": {"request_id": rid, "device_name": r["device_name"]}})
                finally:
                    c.close()

            elif t == "tda.deny" and uid:
                rid = data.get("request_id")
                target_rid = data.get("login_request_id") or ""
                if not target_rid:
                    await _send_safe({"type": "tda.deny.err", "data": {"request_id": rid, "error": "request_id обязателен"}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"tda_deny:{uid}", limit=30, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "tda.deny.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                try:
                    r = c.execute(
                        "SELECT id, phase, device_name FROM pending_logins WHERE request_id=? AND username=? LIMIT 1",
                        (target_rid, username),
                    ).fetchone()
                    if not r:
                        await _send_safe({"type": "tda.deny.err", "data": {"request_id": rid, "error": "Запрос не найден"}})
                        continue
                    if r["phase"] != "pending":
                        await _send_safe({"type": "tda.deny.err", "data": {"request_id": rid, "error": "Запрос уже обработан"}})
                        continue
                    c.execute("UPDATE pending_logins SET phase='denied' WHERE id=?", (r["id"],))
                    c.commit()
                    try: ws_hub.send_to(uid, "tda.pending.gone", {"login_request_id": target_rid, "phase": "denied", "device_name": r["device_name"]})
                    except Exception: pass
                    await _send_safe({"type": "tda.deny.ok", "data": {"request_id": rid, "device_name": r["device_name"]}})
                finally:
                    c.close()

            elif t == "support_admin" and uid:
                rid = data.get("request_id")
                from .chat_router import SUPPORT_ADMIN_USERNAME as _SUP
                c = db()
                r = c.execute(
                    "SELECT id, username, display_name, x25519_pub FROM users WHERE username=?",
                    (_SUP,),
                ).fetchone()
                c.close()
                if not r:
                    await _send_safe({"type": "support_admin.ok", "data": {"request_id": rid, "username": None, "display_name": None, "is_me": False, "x25519_pub": None}})
                else:
                    await _send_safe({"type": "support_admin.ok", "data": {
                        "request_id": rid,
                        "username": r["username"],
                        "display_name": r["display_name"],
                        "x25519_pub": r["x25519_pub"],
                        "is_me": username == r["username"],
                    }})

            elif t == "keys.upload" and uid:
                rid = data.get("request_id")
                try:
                    from .chat_router import _rate_limit as _rl, _is_b64
                    _rl(f"keys:{uid}", limit=5, window=3600)
                except HTTPException as he:
                    await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                x25519_pub = data.get("x25519_pub") or ""
                enc_priv = data.get("encrypted_private_key")
                key_salt = data.get("key_salt")
                req_mode = (data.get("storage_mode") or "").lower() or None
                try:
                    raw_pub = base64.b64decode(x25519_pub) if _is_b64(x25519_pub) else b""
                except Exception:
                    raw_pub = b""
                if len(raw_pub) not in (32, 65):
                    await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": "x25519_pub: ожидается 32 (X25519) или 65 (P-256) байт в base64"}})
                    continue
                c = db()
                current_mode_row = c.execute("SELECT key_storage_mode FROM users WHERE id=?", (uid,)).fetchone()
                saved_mode = current_mode_row["key_storage_mode"] if current_mode_row else None
                mode = req_mode or saved_mode or "server"
                if mode not in ("server", "local"):
                    c.close()
                    await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": "storage_mode: ожидается 'server' или 'local'"}})
                    continue
                if mode == "server":
                    if not enc_priv or not key_salt:
                        c.close()
                        await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": "В режиме 'server' encrypted_private_key и key_salt обязательны"}})
                        continue
                    try:
                        raw_priv = base64.b64decode(enc_priv)
                    except Exception:
                        raw_priv = b""
                    if not _is_b64(enc_priv) or len(raw_priv) < 40 or len(raw_priv) > 500:
                        c.close()
                        await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": "encrypted_private_key: некорректный формат"}})
                        continue
                    if not _is_b64(key_salt, 16):
                        c.close()
                        await _send_safe({"type": "keys.upload.err", "data": {"request_id": rid, "error": "key_salt: ожидается 16 байт в base64"}})
                        continue
                    priv_to_store = enc_priv
                    salt_to_store = key_salt
                else:
                    priv_to_store = None
                    salt_to_store = None
                dev = c.execute("SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1", (token, uid)).fetchone()
                if dev:
                    c.execute("UPDATE user_devices SET pub_key=? WHERE id=?", (x25519_pub, dev["id"]))
                c.execute(
                    "UPDATE users SET x25519_pub=?, encrypted_private_key=?, key_salt=?, in_ghostchat=1, key_storage_mode=? WHERE id=?",
                    (x25519_pub, priv_to_store, salt_to_store, mode, uid),
                )
                c.commit(); c.close()
                await _send_safe({"type": "keys.upload.ok", "data": {"request_id": rid, "status": "ok", "storage_mode": mode}})

            elif t == "keys.server_copy.delete" and uid:
                rid = data.get("request_id")
                c = db()
                c.execute(
                    "UPDATE users SET encrypted_private_key=NULL, key_salt=NULL WHERE id=?",
                    (uid,),
                )
                c.commit(); c.close()
                await _send_safe({"type": "keys.server_copy.delete.ok", "data": {"request_id": rid, "status": "ok"}})

            elif t == "delivery_status" and uid:
                rid = data.get("request_id")
                ids = data.get("ids") or []
                ids = [int(x) for x in ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
                if not ids:
                    await _send_safe({"type": "delivery_status.ok", "data": {"request_id": rid, "status": {}}})
                    continue
                try:
                    from .chat_router import _rate_limit as _rl
                    _rl(f"delivstat:{uid}", limit=60, window=60)
                except HTTPException as he:
                    await _send_safe({"type": "delivery_status.err", "data": {"request_id": rid, "error": str(he.detail)}})
                    continue
                c = db()
                ph = ",".join("?" * len(ids))
                rows = c.execute(f"SELECT id FROM chat_dm WHERE sender_id=? AND id IN ({ph})", [uid] + ids).fetchall()
                still_pending = {r["id"] for r in rows}
                read_rows = c.execute(f"SELECT msg_id FROM chat_dm_read_marks WHERE sender_id=? AND msg_id IN ({ph})", [uid] + ids).fetchall()
                read_ids = {r["msg_id"] for r in read_rows}
                c.close()
                def _st(i):
                    if i in still_pending: return "pending"
                    if i in read_ids: return "read"
                    return "delivered"
                await _send_safe({"type": "delivery_status.ok", "data": {"request_id": rid, "status": {str(i): _st(i) for i in ids}}})

            elif t == "prof.get" and uid:
                rid = data.get("request_id")
                target = (data.get("username") or "").lower().strip()
                offset = int(data.get("offset") or 0)
                if not target:
                    await _send_safe({"type": "prof.get.err", "data": {"request_id": rid, "error": "username required"}})
                    continue
                c = db()
                u_row = c.execute("SELECT * FROM users WHERE username=?", (target,)).fetchone()
                if not u_row:
                    c.close()
                    await _send_safe({"type": "prof.get.err", "data": {"request_id": rid, "error": "User not found"}})
                    continue
                u_dict = dict(u_row)
                stats_p = get_user_stats(c, u_dict["id"])
                am_following = c.execute(
                    "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?", (uid, u_dict["id"])
                ).fetchone() is not None
                rows = c.execute("""
                    SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
                           u.username, u.display_name,
                           (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
                    FROM soc_posts p JOIN users u ON p.user_id=u.id
                    WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
                """, (u_dict["id"], offset)).fetchall()
                posts = _hydrate_posts(c, rows, uid)
                c.close()
                rep_score = int(u_dict.get("reputation_score") if u_dict.get("reputation_score") is not None else 100)
                if u_dict.get("eternal_status_text"):
                    status_text = u_dict.get("eternal_status_text"); status_mood = u_dict.get("eternal_status_mood"); status_eternal = True
                elif _status_active(u_dict.get("daily_status_set_at")):
                    status_text = u_dict.get("daily_status_text"); status_mood = u_dict.get("daily_status_mood"); status_eternal = False
                else:
                    status_text = None; status_mood = None; status_eternal = False
                await _send_safe({"type": "prof.get.ok", "data": {
                    "request_id": rid,
                    "user_id": u_dict["id"],
                    "username": u_dict["username"],
                    "display_name": u_dict["display_name"],
                    "am_following": am_following,
                    "is_me": uid == u_dict["id"],
                    "reputation_score": rep_score,
                    "reputation_band": "low" if rep_score < 30 else ("mid" if rep_score < 70 else "good"),
                    "daily_status": status_text,
                    "daily_status_mood": status_mood,
                    "daily_status_eternal": status_eternal,
                    **stats_p,
                    "posts": posts,
                }})

            elif t == "me.get" and uid:
                rid = data.get("request_id")
                c = db()
                stats = get_user_stats(c, uid)
                flags_row = c.execute("SELECT username, display_name, is_admin, is_moderator FROM users WHERE id=?", (uid,)).fetchone()
                c.close()
                u_username = flags_row["username"] if flags_row else username
                u_display = flags_row["display_name"] if flags_row else username
                payload = {
                    "id": uid, "user_id": uid,
                    "username": u_username, "display_name": u_display,
                    "is_guest": False,
                    "is_admin": _is_admin_user({"username": u_username, "is_admin": (flags_row["is_admin"] if flags_row else 0)}),
                    "is_moderator": bool(flags_row and flags_row["is_moderator"]),
                    **stats,
                }
                await _send_safe({"type": "me.get.ok", "data": {"request_id": rid, **payload}})

            elif t == "notif.unread" and uid:
                rid = data.get("request_id")
                c = db()
                cnt = c.execute(
                    "SELECT COUNT(*) as cnt FROM soc_notifications WHERE user_id=? AND is_read=0",
                    (uid,),
                ).fetchone()["cnt"]
                c.close()
                await _send_safe({"type": "notif.unread.ok", "data": {
                    "request_id": rid, "count": int(cnt),
                }})

            elif t == "presence.ask":
                target = (data.get("username") or "").lower()
                if not target:
                    continue
                c = db()
                peer = c.execute("SELECT id FROM users WHERE username=?", (target,)).fetchone()
                c.close()
                online = bool(peer and peer["id"] in ws_hub._by_uid and ws_hub._by_uid[peer["id"]])
                await _send_safe({"type": "presence", "data": {"username": target, "online": online}})
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        await ws_hub.unregister(uid, websocket)


def init():
    """Создаём только соцсетевые таблицы; users + soc_tokens мигрированы вручную."""
    c = db()
    c.executescript('''
        CREATE TABLE IF NOT EXISTS soc_posts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            media TEXT DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_reactions (
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            emoji TEXT NOT NULL DEFAULT 'heart',
            PRIMARY KEY (post_id, user_id),
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_comments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_follows (
            follower_id INTEGER NOT NULL,
            followee_id INTEGER NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (follower_id, followee_id),
            FOREIGN KEY (follower_id) REFERENCES users(id),
            FOREIGN KEY (followee_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            actor_id INTEGER NOT NULL,
            type TEXT NOT NULL,
            post_id INTEGER NOT NULL DEFAULT 0,
            preview TEXT DEFAULT NULL,
            is_read INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (actor_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_tokens (
            user_id INTEGER PRIMARY KEY,
            token TEXT UNIQUE NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_polls (
            post_id INTEGER PRIMARY KEY,
            question TEXT NOT NULL,
            options TEXT NOT NULL,
            is_quiz INTEGER NOT NULL DEFAULT 0,
            correct_idx INTEGER,
            FOREIGN KEY (post_id) REFERENCES soc_posts(id)
        );
        CREATE TABLE IF NOT EXISTS soc_poll_votes (
            post_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            option_idx INTEGER NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (post_id, user_id),
            FOREIGN KEY (post_id) REFERENCES soc_posts(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS soc_link_cache (
            url TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_dm (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender_id INTEGER NOT NULL,
            receiver_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (sender_id) REFERENCES users(id),
            FOREIGN KEY (receiver_id) REFERENCES users(id)
        );
        -- Группы (чат с N участниками). Каналы = группа с can_write_anyone=0.
        CREATE TABLE IF NOT EXISTS chat_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            owner_id INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'group',  -- 'group' | 'channel'
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (owner_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS chat_group_members (
            group_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            is_admin INTEGER NOT NULL DEFAULT 0,
            joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (group_id, user_id),
            FOREIGN KEY (group_id) REFERENCES chat_groups(id),
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_group_members_user ON chat_group_members(user_id);
        -- Групповые сообщения: один ciphertext + envelope_keys для каждого участника.
        -- envelope_keys в JSON: {user_id_str: base64(encrypted AES key)}.
        CREATE TABLE IF NOT EXISTS chat_group_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_id INTEGER NOT NULL,
            sender_id INTEGER NOT NULL,
            ciphertext TEXT NOT NULL,
            envelope_keys TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (group_id) REFERENCES chat_groups(id),
            FOREIGN KEY (sender_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_group_messages_group ON chat_group_messages(group_id, id);
        -- ack-логика: какие group-сообщения уже получены каким юзером
        CREATE TABLE IF NOT EXISTS chat_group_acks (
            user_id INTEGER NOT NULL,
            msg_id INTEGER NOT NULL,
            PRIMARY KEY (user_id, msg_id)
        );
        -- Зашифрованные на клиенте файлы. Сервер хранит только ciphertext blob —
        -- не знает имя, тип, размер исходного файла. Расшифровка только у получателя.
        -- TTL: ack-based — удаляется когда receiver подтвердил скачивание.
        -- Hard cutoff: автоудаление через 7 дней (cleanup).
        CREATE TABLE IF NOT EXISTS chat_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender_id INTEGER NOT NULL,
            receiver_id INTEGER NOT NULL,
            blob BLOB NOT NULL,
            size INTEGER NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (sender_id) REFERENCES users(id),
            FOREIGN KEY (receiver_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_files_recv ON chat_files(receiver_id);
        CREATE INDEX IF NOT EXISTS idx_chat_files_old ON chat_files(created_at);
        CREATE TABLE IF NOT EXISTS chat_contacts (
            owner_id INTEGER NOT NULL,
            contact_id INTEGER NOT NULL,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (owner_id, contact_id),
            FOREIGN KEY (owner_id) REFERENCES users(id),
            FOREIGN KEY (contact_id) REFERENCES users(id)
        );
        -- Read-метки: receiver открыл chat → /read POST → запись здесь.
        -- Нужно потому что после /ack чат_dm удаляется, и sender после refresh
        -- не мог узнать прочитано или нет. WS chat.read может потеряться.
        -- Cleanup по TTL — read-state имеет смысл только пока юзер видит чат.
        CREATE TABLE IF NOT EXISTS chat_dm_read_marks (
            sender_id INTEGER NOT NULL,
            msg_id INTEGER NOT NULL,
            recipient_id INTEGER NOT NULL,
            read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (sender_id, msg_id)
        );
        CREATE INDEX IF NOT EXISTS idx_dmread_sender ON chat_dm_read_marks(sender_id);
        CREATE INDEX IF NOT EXISTS idx_dmread_old ON chat_dm_read_marks(read_at);

        -- ══════ ЭКОНОМИКА: Soul + NFT ══════════════════════════════════════════
        -- Состояние сезона (одна строка с активным сезоном)
        CREATE TABLE IF NOT EXISTS soc_economy_state (
            season_id INTEGER PRIMARY KEY,
            cap INTEGER NOT NULL,
            system_balance INTEGER NOT NULL,
            burned_total INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1,
            started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            closed_at TIMESTAMP
        );
        -- Аудит-лог Soul-транзакций (как soc_wallet_tx для gost, но для soul)
        -- source: 'admin_emit'|'transfer_in'|'transfer_out'|'fee'|'nft_buy'|'nft_sell'|'nft_fee'|'burn'
        CREATE TABLE IF NOT EXISTS soc_soul_tx (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            delta INTEGER NOT NULL,
            source TEXT NOT NULL,
            counter_user_id INTEGER NOT NULL DEFAULT 0,
            ref_type TEXT NOT NULL DEFAULT '',
            ref_id INTEGER NOT NULL DEFAULT 0,
            note TEXT DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_soul_tx_user ON soc_soul_tx(user_id, id DESC);
        -- Каталог NFT (типы — например 'ghost', 'moon', ...)
        CREATE TABLE IF NOT EXISTS soc_nft_catalog (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slug TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            rarity TEXT NOT NULL DEFAULT 'common',
            max_supply INTEGER NOT NULL,
            creator_id INTEGER NOT NULL,
            start_price_soul INTEGER NOT NULL DEFAULT 5,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (creator_id) REFERENCES users(id)
        );
        -- Экземпляры NFT (instance)
        CREATE TABLE IF NOT EXISTS soc_nfts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            catalog_id INTEGER NOT NULL,
            serial INTEGER NOT NULL,
            owner_id INTEGER NOT NULL,
            minted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (catalog_id, serial),
            FOREIGN KEY (catalog_id) REFERENCES soc_nft_catalog(id),
            FOREIGN KEY (owner_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_nfts_owner ON soc_nfts(owner_id);
        CREATE INDEX IF NOT EXISTS idx_soc_nfts_catalog ON soc_nfts(catalog_id);
        -- Маркет: один NFT может быть выставлен только 1 раз
        -- currency='gost' — первичные продажи от GhostEcos (юзеры тратят Gost)
        -- currency='soul' — P2P-торговля между юзерами
        CREATE TABLE IF NOT EXISTS soc_nft_listings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nft_id INTEGER NOT NULL UNIQUE,
            seller_id INTEGER NOT NULL,
            price_soul INTEGER NOT NULL,
            currency TEXT NOT NULL DEFAULT 'soul',
            listed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (nft_id) REFERENCES soc_nfts(id),
            FOREIGN KEY (seller_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_nft_listings_catalog ON soc_nft_listings(price_soul);

        -- ══════ INVOICES (счета) ══════
        CREATE TABLE IF NOT EXISTS soc_invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT UNIQUE NOT NULL,
            owner_id INTEGER NOT NULL,
            amount_soul INTEGER NOT NULL,
            note TEXT DEFAULT NULL,
            paid_count INTEGER NOT NULL DEFAULT 0,
            total_received INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            expires_at TIMESTAMP NOT NULL,
            cancelled INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (owner_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_invoices_owner ON soc_invoices(owner_id, id DESC);

        -- ══════ USERNAMES (дополнительные, P2P) ══════
        -- Primary username хранится в users.username. Дополнительные — здесь.
        -- for_sale_price NULL = не продаётся
        CREATE TABLE IF NOT EXISTS soc_usernames (
            username TEXT PRIMARY KEY,
            owner_id INTEGER NOT NULL,
            for_sale_price INTEGER DEFAULT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            acquired_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (owner_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_usernames_owner ON soc_usernames(owner_id);
        CREATE INDEX IF NOT EXISTS idx_soc_usernames_market ON soc_usernames(for_sale_price) WHERE for_sale_price IS NOT NULL;

        CREATE INDEX IF NOT EXISTS idx_soc_posts_created ON soc_posts(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_posts_user ON soc_posts(user_id);
        CREATE INDEX IF NOT EXISTS idx_soc_reactions_post ON soc_reactions(post_id);
        CREATE INDEX IF NOT EXISTS idx_soc_comments_post ON soc_comments(post_id);
        CREATE INDEX IF NOT EXISTS idx_soc_follows_followee ON soc_follows(followee_id);
        CREATE INDEX IF NOT EXISTS idx_soc_notif_user ON soc_notifications(user_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_tokens_token ON soc_tokens(token);
        CREATE INDEX IF NOT EXISTS idx_chat_dm_recv ON chat_dm(receiver_id, id);

        -- ── Экономика GhostEcos: кошелёк (3 валюты) ──
        -- gost — non-transferable, бесплатная (активность)
        -- soul — основная, transferable, cap-эмиссия (пока 0 у всех — выкуп NFT не реализован)
        -- prem — премиальная (украшения), пока 0
        CREATE TABLE IF NOT EXISTS soc_wallets (
            user_id INTEGER PRIMARY KEY,
            gost INTEGER NOT NULL DEFAULT 0,
            soul INTEGER NOT NULL DEFAULT 0,
            prem INTEGER NOT NULL DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        -- Audit log + дедуп источников начисления.
        -- source = 'register'|'daily'|'post'|'react'|'comment'|'follow'|'spend'|'admin'|...
        -- actor_id — кто триггернул (например юзер который лайкнул); 0 если система
        -- ref_type/ref_id — на что ссылается (например 'post'/123); ref_id=0 если не применимо
        CREATE TABLE IF NOT EXISTS soc_wallet_tx (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            currency TEXT NOT NULL,
            delta INTEGER NOT NULL,
            source TEXT NOT NULL,
            actor_id INTEGER NOT NULL DEFAULT 0,
            ref_type TEXT NOT NULL DEFAULT '',
            ref_id INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
        -- Дедуп: одна пара (получатель, источник, актор, ref) даёт начисление только ОДИН раз
        CREATE UNIQUE INDEX IF NOT EXISTS uq_soc_wallet_tx_dedup
            ON soc_wallet_tx(user_id, source, actor_id, ref_type, ref_id)
            WHERE source IN ('react','comment','follow','post','register');
        CREATE INDEX IF NOT EXISTS idx_soc_wallet_tx_user ON soc_wallet_tx(user_id, id DESC);
        CREATE INDEX IF NOT EXISTS idx_soc_wallet_tx_day ON soc_wallet_tx(user_id, source, created_at);
    ''')
    try:
        c.execute("ALTER TABLE users ADD COLUMN is_official INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE soc_nft_listings ADD COLUMN currency TEXT NOT NULL DEFAULT 'soul'")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE soc_nft_catalog ADD COLUMN image_kind TEXT NOT NULL DEFAULT 'preset'")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE soc_nft_catalog ADD COLUMN image_data TEXT NOT NULL DEFAULT ''")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE soc_nft_catalog ADD COLUMN bg_color TEXT NOT NULL DEFAULT '#a855f7'")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE users ADD COLUMN seed_hash TEXT DEFAULT NULL")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE users ADD COLUMN nft_mints_count INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE users ADD COLUMN usernames_created INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE users ADD COLUMN referrer_id INTEGER DEFAULT NULL")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("CREATE INDEX IF NOT EXISTS idx_users_referrer ON users(referrer_id)")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE chat_groups ADD COLUMN username TEXT DEFAULT NULL")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE chat_groups ADD COLUMN bio TEXT DEFAULT NULL")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("ALTER TABLE chat_groups ADD COLUMN is_public INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_groups_username ON chat_groups(username) WHERE username IS NOT NULL")
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS chat_group_join_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                group_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted | rejected
                reviewed_by INTEGER,
                reviewed_at INTEGER,
                UNIQUE(group_id, user_id)
            )
        """)
    except sqlite3.OperationalError:
        pass
    try:
        c.execute("CREATE INDEX IF NOT EXISTS idx_join_req_group ON chat_group_join_requests(group_id, status)")
    except sqlite3.OperationalError:
        pass

    try: c.execute("ALTER TABLE soc_posts ADD COLUMN source_channel_id INTEGER")
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_posts_source_channel ON soc_posts(source_channel_id) WHERE source_channel_id IS NOT NULL")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN is_moderator INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")  # owner экосистемы
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN moderator_rating INTEGER NOT NULL DEFAULT 100")  # 0-100 (>=80 — хорошо)
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN moderator_reprimands INTEGER NOT NULL DEFAULT 0")  # 0..3, 4й=снятие
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN moderator_since INTEGER")  # когда дали роль
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN is_anon INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_moderator_applications (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted | rejected
                reviewed_by INTEGER,
                reviewed_at INTEGER,
                quality_score INTEGER NOT NULL DEFAULT 50,  -- для сортировки (50=средний, 100=топ)
                UNIQUE(user_id, status)  -- одна pending-заявка на юзера; можно делать новую если предыдущая закрыта
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_modapp_status ON soc_moderator_applications(status, quality_score DESC)")
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_overwatch_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id INTEGER NOT NULL,
                author_id INTEGER NOT NULL,
                kind TEXT NOT NULL DEFAULT 'manual',  -- manual | system_viral | system_reports
                price_gost INTEGER NOT NULL DEFAULT 300,
                created_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'open',  -- open | resolved | cancelled
                resolved_at INTEGER,
                delta_applied INTEGER,                -- итоговый сдвиг activity (±150 cap)
                votes_count INTEGER NOT NULL DEFAULT 0
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_ow_status ON soc_overwatch_requests(status, created_at DESC)")
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_overwatch_votes (
                request_id INTEGER NOT NULL,
                moderator_id INTEGER NOT NULL,
                delta INTEGER NOT NULL,        -- -150, -50, 0, +50, +150
                comment TEXT,                  -- опционально, причина
                created_at INTEGER NOT NULL,
                PRIMARY KEY (request_id, moderator_id)
            )
        """)
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE soc_posts ADD COLUMN activity INTEGER NOT NULL DEFAULT 500")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE soc_posts ADD COLUMN activity_set_at INTEGER")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE soc_posts ADD COLUMN automod_source TEXT")  # 'A'|'B'|'C'|'manual'
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_post_views (
                user_id INTEGER NOT NULL,
                post_id INTEGER NOT NULL,
                viewed_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, post_id)
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_post_views_user ON soc_post_views(user_id, viewed_at DESC)")
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_activity_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id INTEGER NOT NULL,
                old_activity INTEGER,
                new_activity INTEGER,
                delta INTEGER,
                source TEXT NOT NULL,   -- 'automod_B'|'automod_C'|'overwatch'|'system'|'manual'
                actor_id INTEGER,        -- кто изменил (юзер/админ/null=auto)
                note TEXT,
                created_at INTEGER NOT NULL
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_activity_log_post ON soc_activity_log(post_id, id DESC)")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE soc_posts ADD COLUMN kind TEXT NOT NULL DEFAULT 'post'")
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_posts_kind ON soc_posts(kind, id DESC)")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE soc_posts ADD COLUMN edited_at TIMESTAMP")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE soc_posts ADD COLUMN is_nsfw INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE soc_posts ADD COLUMN nsfw_set_by INTEGER")  # NULL=автор сам, INT=ID админа/мода
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_posts_nsfw ON soc_posts(is_nsfw, id DESC)")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN reputation_score INTEGER NOT NULL DEFAULT 100")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN reputation_updated_at INTEGER")
    except sqlite3.OperationalError: pass
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_reputation_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                delta INTEGER NOT NULL,
                old_score INTEGER NOT NULL,
                new_score INTEGER NOT NULL,
                reason TEXT NOT NULL,  -- 'nsfw_admin'|'restore_weekly'|'manual'
                actor_id INTEGER,       -- кто изменил (NULL=система)
                post_id INTEGER,        -- если связано с постом
                created_at INTEGER NOT NULL
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_rep_log_user ON soc_reputation_log(user_id, id DESC)")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN confirmed_18_at INTEGER")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN daily_status_text TEXT")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN daily_status_set_at INTEGER")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN daily_status_mood TEXT")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN eternal_status_text TEXT")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN eternal_status_mood TEXT")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE users ADD COLUMN eternal_status_purchased_at INTEGER")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN key_storage_mode TEXT DEFAULT NULL")
    except sqlite3.OperationalError: pass

    try: c.execute("ALTER TABLE users ADD COLUMN tda_enabled INTEGER NOT NULL DEFAULT 0")
    except sqlite3.OperationalError: pass
    try: c.execute("ALTER TABLE pending_logins ADD COLUMN granted_token TEXT NULL")
    except sqlite3.OperationalError: pass

    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS chat_dm_sealed (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                receiver_id INTEGER NOT NULL,
                ciphertext TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (receiver_id) REFERENCES users(id)
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_dm_sealed_recv ON chat_dm_sealed(receiver_id, id DESC)")
    except sqlite3.OperationalError: pass

    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_reposts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(post_id, user_id),
                FOREIGN KEY (post_id) REFERENCES soc_posts(id),
                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_reposts_user ON soc_reposts(user_id, created_at DESC)")
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_reposts_post ON soc_reposts(post_id, created_at DESC)")
    except sqlite3.OperationalError: pass

    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id INTEGER NOT NULL,
                reporter_id INTEGER NOT NULL,
                reason TEXT NOT NULL,  -- spam | nsfw_unmarked | illegal | harassment | other
                created_at INTEGER NOT NULL,
                UNIQUE(post_id, reporter_id)
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_reports_post ON soc_reports(post_id, created_at DESC)")
    except sqlite3.OperationalError: pass

    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_username_cooldown (
                username TEXT PRIMARY KEY,
                released_at INTEGER NOT NULL,  -- когда username освободится для повторной регистрации
                prev_user_id INTEGER,           -- кто владел до удаления (для audit)
                reason TEXT NOT NULL DEFAULT 'account_deleted'  -- account_deleted|username_changed|account_banned
            )
        """)
    except sqlite3.OperationalError: pass
    try: c.execute("CREATE INDEX IF NOT EXISTS idx_username_cd_released ON soc_username_cooldown(released_at)")
    except sqlite3.OperationalError: pass

    try:
        c.executescript('''
        CREATE TABLE IF NOT EXISTS soc_giveaways (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            prize_gost INTEGER NOT NULL,          -- Gost каждому победителю
            winners_count INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'active', -- active | finished | cancelled
            ends_at INTEGER NOT NULL,              -- unix-время дедлайна
            created_at INTEGER NOT NULL,
            drawn_at INTEGER NOT NULL DEFAULT 0,   -- unix-время розыгрыша (0 если ещё не разыгран)
            created_by INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_soc_giveaways_status ON soc_giveaways(status, ends_at);
        CREATE TABLE IF NOT EXISTS soc_giveaway_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            giveaway_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(giveaway_id, user_id)
        );
        CREATE INDEX IF NOT EXISTS idx_soc_ga_entries_ga ON soc_giveaway_entries(giveaway_id);
        CREATE TABLE IF NOT EXISTS soc_giveaway_winners (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            giveaway_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL,
            prize_gost INTEGER NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_soc_ga_winners_ga ON soc_giveaway_winners(giveaway_id);
        ''')
    except sqlite3.OperationalError:
        pass

    c.commit()
    c.close()

# ── Bootstrap: системный юзер GhostEcos, NFT-каталог, сезон 1 ─────────────────

_NFT_SEED = [
    {"slug":"ghost",   "name":"Призрак",  "rarity":"common", "price_gost":100,
     "desc":"Символ экосистемы GhostEcos — призрак, плавающий в эфире."},
    {"slug":"moon",    "name":"Луна",     "rarity":"common", "price_gost":100,
     "desc":"Лунный диск с пульсирующим свечением."},
    {"slug":"star",    "name":"Звезда",   "rarity":"rare",   "price_gost":300,
     "desc":"Медленно вращающаяся пятиконечная звезда."},
    {"slug":"flame",   "name":"Пламя",    "rarity":"common", "price_gost":100,
     "desc":"Колеблющееся пламя — энергия эфира."},
    {"slug":"heart",   "name":"Сердце",   "rarity":"common", "price_gost":100,
     "desc":"Бьющееся сердце GhostEcos."},
    {"slug":"bolt",    "name":"Молния",   "rarity":"rare",   "price_gost":300,
     "desc":"Молния с периодическими вспышками."},
    {"slug":"crystal", "name":"Кристалл", "rarity":"legend", "price_gost":1000,
     "desc":"Переливающийся кристалл — легендарная редкость."},
    {"slug":"eye",     "name":"Око",      "rarity":"rare",   "price_gost":300,
     "desc":"Всевидящее око — следит за вами."},
    {"slug":"key",     "name":"Ключ",     "rarity":"rare",   "price_gost":300,
     "desc":"Скелетный ключ — открывает то, что скрыто."},
    {"slug":"crown",   "name":"Корона",   "rarity":"legend", "price_gost":1000,
     "desc":"Корона избранных — три камня."},
]
SEASON_CAP = 100_000
GHOSTECOS_USERNAME = 'ghostecos'

def bootstrap_economy():
    """Идемпотентный сидинг: системный юзер, сезон 1, NFT-каталог + 100 экз каждого + листинги."""
    c = db()
    sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
    if not sys_row:
        sys_pwd = secrets.token_hex(48)  # никто никогда не залогинится — random
        try:
            c.execute(
                "INSERT INTO users (username, display_name, argon2_hash, in_ghostchat, is_official) VALUES (?,?,?,0,1)",
                (GHOSTECOS_USERNAME, 'GhostEcos', hash_argon2(sys_pwd)),
            )
            c.commit()
        except sqlite3.IntegrityError:
            pass
        sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
    else:
        c.execute("UPDATE users SET is_official=1, display_name='GhostEcos' WHERE username=?", (GHOSTECOS_USERNAME,))
        c.commit()
    sys_uid = sys_row['id']
    c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (sys_uid,))
    c.commit()

    season = c.execute("SELECT * FROM soc_economy_state WHERE season_id=1").fetchone()
    if not season:
        c.execute(
            "INSERT INTO soc_economy_state (season_id, cap, system_balance, is_active) VALUES (1, ?, ?, 1)",
            (SEASON_CAP, SEASON_CAP),
        )
        c.commit()
        print(f"[economy] season 1 started: cap={SEASON_CAP} system_balance={SEASON_CAP}")

    catalog_count = c.execute("SELECT COUNT(*) as c FROM soc_nft_catalog").fetchone()['c']
    if catalog_count == 0:
        for nft in _NFT_SEED:
            c.execute(
                "INSERT INTO soc_nft_catalog (slug, name, description, rarity, max_supply, creator_id, start_price_soul) "
                "VALUES (?,?,?,?,100,?,?)",
                (nft['slug'], nft['name'], nft['desc'], nft['rarity'], sys_uid, nft['price_gost']),
            )
            cat_id = c.execute("SELECT last_insert_rowid() as id").fetchone()['id']
            for serial in range(1, 101):
                c.execute(
                    "INSERT INTO soc_nfts (catalog_id, serial, owner_id) VALUES (?,?,?)",
                    (cat_id, serial, sys_uid),
                )
                nft_id = c.execute("SELECT last_insert_rowid() as id").fetchone()['id']
                price = nft['price_gost']
                if serial <= 10: price = int(nft['price_gost'] * 1.5)
                elif serial <= 30: price = int(nft['price_gost'] * 1.2)
                c.execute(
                    "INSERT INTO soc_nft_listings (nft_id, seller_id, price_soul, currency) VALUES (?,?,?,'gost')",
                    (nft_id, sys_uid, price),
                )
            print(f"[economy] minted {nft['name']} x100 за {nft['price_gost']} Gost (catalog #{cat_id})")
        c.commit()
    else:
        sys_listings = c.execute(
            "SELECT COUNT(*) as cnt FROM soc_nft_listings WHERE seller_id=? AND currency='soul'",
            (sys_uid,)
        ).fetchone()['cnt']
        if sys_listings > 0:
            print(f"[economy] migrating {sys_listings} ghostecos listings: soul → gost")
            slug_to_price = {n['slug']: n['price_gost'] for n in _NFT_SEED}
            rows = c.execute(
                "SELECT l.id as lid, l.nft_id, n.serial, cat.slug "
                "FROM soc_nft_listings l "
                "JOIN soc_nfts n ON l.nft_id=n.id "
                "JOIN soc_nft_catalog cat ON cat.id = n.catalog_id "
                "WHERE l.seller_id=?", (sys_uid,)
            ).fetchall()
            for r in rows:
                base = slug_to_price.get(r['slug'], 100)
                price = base
                if r['serial'] <= 10: price = int(base * 1.5)
                elif r['serial'] <= 30: price = int(base * 1.2)
                c.execute("UPDATE soc_nft_listings SET price_soul=?, currency='gost' WHERE id=?", (price, r['lid']))
            c.commit()
            print(f"[economy] migration done: now in Gost")
    c.close()



def broadcast_devices_changed(user_id: int, username: str):
    """Шлём всем WS-подключённым юзерам событие peer.devices_changed."""
    try:
        payload = {"username": username}
        for uid, sockets in list(getattr(ws_hub, '_by_uid', {}).items()):
            if uid == user_id:
                continue
            try:
                ws_hub.send_to(uid, "peer.devices_changed", payload)
            except Exception:
                pass
    except Exception:
        pass

init()
bootstrap_economy()

# ── Auth middleware ─────────────────────────────────────────────────────────────

def auth(authorization: Optional[str]) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = authorization.split(" ", 1)[1]
    if token.startswith("guest_") and len(token) > 16:
        return {"id": 0, "username": "__guest__", "display_name": "Гость", "token": token, "is_guest": True}
    c = db()
    row = c.execute(
        "SELECT u.* FROM users u JOIN soc_tokens t ON t.user_id = u.id WHERE t.token = ?",
        (token,),
    ).fetchone()
    if not row:
        row = c.execute(
            "SELECT u.*, d.id AS _device_pk, d.device_id AS _did FROM users u "
            "JOIN user_devices d ON d.user_id = u.id "
            "WHERE d.token=? AND d.is_active=1 AND d.is_blocked=0 LIMIT 1",
            (token,),
        ).fetchone()
    c.close()
    if not row:
        raise HTTPException(401, "Invalid token")
    u = dict(row)
    u["is_guest"] = False
    u["token"] = token
    return u

def require_member(user: dict):
    """Эндпоинт требует полноценного аккаунта (не гостя)."""
    if user.get("is_guest"):
        raise HTTPException(403, "Войдите или зарегистрируйтесь, чтобы продолжить")

def auth_member(authorization: Optional[str]) -> dict:
    user = auth(authorization)
    require_member(user)
    return user

# ── Post/profile helpers ───────────────────────────────────────────────────────

def fmt_post(row: dict, user_id: int, reactions: Optional[dict] = None, am_following: bool = False) -> dict:
    media_list = []
    if row.get("media"):
        try:
            media_list = json.loads(row["media"])
        except Exception:
            pass
    is_nsfw = 0
    try: is_nsfw = int(row.get("is_nsfw") or 0)
    except Exception: is_nsfw = 0
    nsfw_by = row.get("nsfw_set_by") if "nsfw_set_by" in row.keys() else None
    return {
        "id": row["id"],
        "content": row["content"],
        "created_at": row["created_at"],
        "edited_at": row.get("edited_at"),
        "user_id": row["user_id"],
        "username": row["username"],
        "display_name": row["display_name"],
        "reactions": reactions or {"counts": {}, "your_emoji": None, "total": 0},
        "comments_count": row["comments_count"],
        "media": media_list,
        "am_following": am_following,
        "is_nsfw": bool(is_nsfw),
        "nsfw_set_by_admin": bool(nsfw_by) if is_nsfw else False,
    }

def get_user_stats(c, user_id: int) -> dict:
    posts_count = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_posts WHERE user_id=?", (user_id,)
    ).fetchone()["cnt"]
    likes_received = c.execute("""
        SELECT COUNT(*) as cnt FROM soc_reactions l
        JOIN soc_posts p ON l.post_id=p.id WHERE p.user_id=?
    """, (user_id,)).fetchone()["cnt"]
    likes_given = c.execute("""
        SELECT COUNT(*) as cnt FROM soc_reactions l
        JOIN soc_posts p ON l.post_id=p.id
        WHERE l.user_id=? AND p.user_id!=?
    """, (user_id, user_id)).fetchone()["cnt"]
    followers = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_follows WHERE followee_id=?", (user_id,)
    ).fetchone()["cnt"]
    following = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_follows WHERE follower_id=?", (user_id,)
    ).fetchone()["cnt"]
    return {
        "posts_count": posts_count,
        "likes_received": likes_received,
        "likes_given": likes_given,
        "followers_count": followers,
        "following_count": following,
    }

# ── Media validation (anti stored-XSS) ──────────────────────────────────────────

import re
_MEDIA_URL_RE = re.compile(r'^/social/media/[A-Za-z0-9._-]+$')

def _val_media(media: Optional[List[dict]]) -> Optional[List[dict]]:
    """Media must reference our own uploaded files. Reject arbitrary URLs —
    they end up inside HTML attributes on the client and could carry script."""
    if not media:
        return None
    if len(media) > 5:
        raise HTTPException(400, "Максимум 5 медиафайлов")
    clean = []
    for m in media:
        if not isinstance(m, dict):
            raise HTTPException(400, "Некорректное медиа")
        url = m.get("url", "")
        ftype = m.get("type", "")
        if ftype not in ("image", "video", "audio"):
            raise HTTPException(400, "Некорректный тип медиа")
        if not isinstance(url, str) or not _MEDIA_URL_RE.match(url):
            raise HTTPException(400, "Некорректный URL медиа")
        name = m.get("name", "")
        if not isinstance(name, str):
            name = ""
        clean.append({"url": url, "type": ftype, "name": name[:200]})
    return clean

# ── Notifications ───────────────────────────────────────────────────────────────

def _add_notif(c, recipient_id: int, actor_id: int, ntype: str, post_id: int = 0, preview: Optional[str] = None):
    if recipient_id == actor_id:
        return  # don't notify yourself
    c.execute(
        "INSERT INTO soc_notifications (user_id, actor_id, type, post_id, preview) VALUES (?,?,?,?,?)",
        (recipient_id, actor_id, ntype, post_id, preview),
    )
    try:
        ws_hub.send_to(recipient_id, "notif.new", {"type": ntype})
    except Exception:
        pass

# ── Rate limit (in-memory, per IP) ──────────────────────────────────────────────

_rl_buckets: dict = defaultdict(list)

def _client_ip(request: Request) -> str:
    fwd = request.headers.get('x-forwarded-for', '')
    if fwd:
        return fwd.split(',')[0].strip()
    return request.client.host if request.client else 'unknown'

_RATE_LIMIT_DISABLED = os.getenv("DISABLE_RATE_LIMIT") == "1"

def _rate_limit(key: str, limit: int, window: int):
    if _RATE_LIMIT_DISABLED:
        return  # для тестов / dev окружения
    now = time.time()
    arr = _rl_buckets[key] = [t for t in _rl_buckets[key] if now - t < window]
    if len(arr) >= limit:
        raise HTTPException(429, "Слишком много попыток, попробуйте позже")
    arr.append(now)

# ── Hashtags & mentions parsing ─────────────────────────────────────────────────

_TAG_RE = re.compile(r'#([0-9A-Za-zА-Яа-яЁё_]{1,30})', re.UNICODE)
_MENTION_RE = re.compile(r'(?<![A-Za-z0-9_.])@([a-z0-9._]{3,64})')

def _extract_tags(text: str) -> list:
    seen = set()
    out = []
    for m in _TAG_RE.findall(text or ''):
        low = m.lower()
        if low not in seen:
            seen.add(low)
            out.append(low)
    return out[:10]  # ограничим 10 уникальных тегов на пост

def _extract_mentions(text: str) -> list:
    seen = set()
    out = []
    for m in _MENTION_RE.findall(text or ''):
        low = m.lower()
        if low not in seen:
            seen.add(low)
            out.append(low)
    return out[:10]

# ── Reactions aggregation ─────────────────────────────────────────────────────

ALLOWED_EMOJI = {'heart', 'fire', 'laugh', 'sad', 'clap', 'eyes'}

def _post_reactions(c, post_id: int, user_id: int) -> dict:
    """Возвращает { 'heart': 5, 'fire': 2 } и какую реакцию поставил юзер."""
    rows = c.execute(
        "SELECT emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id=? GROUP BY emoji",
        (post_id,)
    ).fetchall()
    counts = {r["emoji"]: r["cnt"] for r in rows}
    you = c.execute(
        "SELECT emoji FROM soc_reactions WHERE post_id=? AND user_id=?",
        (post_id, user_id)
    ).fetchone()
    return {"counts": counts, "your_emoji": you["emoji"] if you else None, "total": sum(counts.values())}

# ── Auth endpoints ─────────────────────────────────────────────────────────────

@router.post("/register")
def register(body: RegisterBody, request: Request):
    _rate_limit(f"reg:{_client_ip(request)}", limit=5, window=3600)
    username = _val_username(body.username)
    display_name = _val_name(body.display_name)
    _val_password(body.password)
    argon2 = hash_argon2(body.password)
    token = secrets.token_hex(32)
    seed_alpha = "abcdefghkmnpqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    seed = ''.join(secrets.choice(seed_alpha) for _ in range(16))
    seed_hash = hash_argon2(seed)
    # Резолвим пригласителя ДО INSERT — чтобы записать referrer_id сразу
    referrer_id = None
    ref_username = (body.ref or "").strip().lower().lstrip("@")
    if ref_username and ref_username != username:
        c0 = db()
        try:
            r = c0.execute("SELECT id FROM users WHERE username=?", (ref_username,)).fetchone()
            if r:
                referrer_id = r["id"]
        finally:
            c0.close()
    c = db()
    now_ts = int(time.time())
    cd_row = c.execute(
        "SELECT released_at FROM soc_username_cooldown WHERE username=?", (username,)
    ).fetchone()
    if cd_row and int(cd_row["released_at"]) > now_ts:
        days_left = max(1, (int(cd_row["released_at"]) - now_ts) // 86400)
        c.close()
        raise HTTPException(409, f"Имя освободится через {days_left} дн.")
    if cd_row:
        try: c.execute("DELETE FROM soc_username_cooldown WHERE username=?", (username,))
        except Exception: pass
    confirmed_18_ts = now_ts if getattr(body, 'age_18_confirm', False) else None
    if not confirmed_18_ts:
        c.close()
        raise HTTPException(422, "Для регистрации необходимо подтвердить, что вам исполнилось 18 лет")
    try:
        c.execute(
            "INSERT INTO users (username, display_name, argon2_hash, in_ghostchat, seed_hash, referrer_id, confirmed_18_at, key_storage_mode) "
            "VALUES (?,?,?,0,?,?,?,'local')",
            (username, display_name, argon2, seed_hash, referrer_id, confirmed_18_ts),
        )
        uid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (uid, token))
        c.commit()
    except sqlite3.IntegrityError:
        c.close()
        raise HTTPException(409, "Имя пользователя уже занято")
    finally:
        c.close()
    try: award_gost(uid, 'register')
    except Exception: pass
    if referrer_id and referrer_id != uid:
        try: award_gost(uid, 'refin')           # welcome бонус приглашённому
        except Exception: pass
        try: award_gost(referrer_id, 'refout')  # пригласителю
        except Exception: pass
    final_token = token
    final_did = None
    if getattr(body, 'device_id', None):
        import device_auth as _da
        c2 = db()
        try:
            dev = _da.register_device(
                c2, uid, body.device_id, body.device_name,
                getattr(body, 'platform', None), is_owner=True
            )
            final_token = dev["token"]
            final_did = dev["device_id"]
        finally:
            c2.close()
    return {
        "id": uid, "username": username, "display_name": display_name,
        "token": final_token,
        "device_id": final_did,
        "seed_phrase": seed,
        "referrer": ref_username if referrer_id else None,
    }


class SeedRecoveryBody(BaseModel):
    username: str
    seed_phrase: str

@router.post("/recovery/seed")
def recovery_seed(body: SeedRecoveryBody, request: Request):
    """Восстановить доступ по seed-фразе. Возвращает новый токен."""
    _rate_limit(f"recov:{_client_ip(request)}", limit=10, window=3600)
    username = body.username.strip().lower()
    seed = body.seed_phrase.strip()
    if not username or len(seed) != 16:
        # Dummy verify чтобы тайминги не разнились
        verify_argon2(seed, _DUMMY_ARGON2_HASH)
        raise HTTPException(401, "Неверная seed-фраза")
    c = db()
    user = c.execute("SELECT id, seed_hash, username FROM users WHERE username=?", (username,)).fetchone()
    if not user or not user["seed_hash"] or not verify_argon2(seed, user["seed_hash"]):
        c.close()
        verify_argon2(seed, _DUMMY_ARGON2_HASH)
        raise HTTPException(401, "Неверная seed-фраза")
    new_token = secrets.token_hex(32)
    c.execute("INSERT OR REPLACE INTO soc_tokens (user_id, token) VALUES (?,?)", (user["id"], new_token))
    c.commit()
    c.close()
    return {"username": user["username"], "token": new_token}


class SeedRegenBody(BaseModel):
    password: str

@router.post("/me/regen_seed")
def regen_seed(body: SeedRegenBody, authorization: Optional[str] = Header(None)):
    """Сгенерить новую seed-фразу (для тех у кого её нет, или забыли). Требует пароль."""
    user = auth_member(authorization)
    _rate_limit(f"regenseed:{user['id']}", limit=3, window=3600)
    stored_hash = user.get("argon2_hash") or user.get("password_hash")
    if not stored_hash or not verify_argon2(body.password, stored_hash):
        raise HTTPException(401, "Неверный пароль")
    seed_alpha = "abcdefghkmnpqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    seed = ''.join(secrets.choice(seed_alpha) for _ in range(16))
    seed_hash = hash_argon2(seed)
    c = db()
    c.execute("UPDATE users SET seed_hash=? WHERE id=?", (seed_hash, user["id"]))
    c.commit(); c.close()
    return {"seed_phrase": seed}

@router.post("/guest")
def guest_login(request: Request):
    """Гостевой токен — read-only доступ, без записи в БД."""
    _rate_limit(f"guest:{_client_ip(request)}", limit=20, window=3600)
    return {
        "id": 0,
        "username": "__guest__",
        "display_name": "Гость",
        "token": "guest_" + secrets.token_hex(24),
        "is_guest": True,
    }

@router.post("/login")
def login(body: LoginBody, request: Request):
    _rate_limit(f"login:{_client_ip(request)}", limit=15, window=600)
    username = body.username.strip().lower()
    if not username:
        raise HTTPException(422, "Введите имя пользователя")
    c = db()
    user = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not user:
        c.close()
        # Защита от user enumeration через тайминг: выполняем argon2-проверку
        # с фиктивным хэшем (одинаковый константный хэш, всегда не пройдёт),
        # чтобы время ответа было идентично "юзер существует + неверный пароль".
        verify_argon2(body.password, _DUMMY_ARGON2_HASH)
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    u = dict(user)
    ok = False
    # Сначала argon2 (канонический), потом legacy pbkdf2 с авто-апгрейдом
    if u.get("argon2_hash") and verify_argon2(body.password, u["argon2_hash"]):
        ok = True
    elif u.get("pbkdf2_hash") and verify_pbkdf2(body.password, u["pbkdf2_hash"]):
        ok = True
        new_hash = hash_argon2(body.password)
        c.execute("UPDATE users SET argon2_hash=?, pbkdf2_hash=NULL WHERE id=?", (new_hash, u["id"]))
        c.commit()
    if not ok:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    # TDA-1: если есть device_id — регистрируем устройство и возвращаем
    # device-уровневый токен. Если нет — legacy fallback на soc_tokens.
    import device_auth as _da
    if getattr(body, 'device_id', None):
        # Проверка блокировки: если юзер с trusted-устройства когда-то нажал
        # «Заблокировать» для этого device_id — отбиваем сразу с 403.
        blocked = c.execute(
            "SELECT id FROM user_devices WHERE user_id=? AND device_id=? AND is_blocked=1 LIMIT 1",
            (u["id"], body.device_id),
        ).fetchone()
        if blocked:
            c.close()
            raise HTTPException(403, "Это устройство заблокировано владельцем аккаунта")
        already = c.execute(
            "SELECT id FROM user_devices WHERE user_id=? AND device_id=? LIMIT 1",
            (u["id"], body.device_id),
        ).fetchone()
        trusted_count = c.execute(
            "SELECT COUNT(*) AS n FROM user_devices "
            "WHERE user_id=? AND is_active=1 AND is_blocked=0",
            (u["id"],),
        ).fetchone()["n"]
        tda_row = c.execute("SELECT tda_enabled FROM users WHERE id=?", (u["id"],)).fetchone()
        tda_on = bool(tda_row and tda_row["tda_enabled"])

        if tda_on and (not already) and trusted_count > 0:
            now_ = int(time.time())
            login_code = "".join(secrets.choice("0123456789") for _ in range(6))
            code_hash = hash_argon2(login_code)
            request_id = uuid.uuid4().hex
            c.execute(
                "INSERT INTO pending_logins "
                "(request_id, username, device_id, device_name, phase, code_hash, "
                " created_at, expires_at) "
                "VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)",
                (request_id, u["username"], body.device_id,
                 (body.device_name or "")[:120], code_hash, now_, now_ + 300),
            )
            c.commit()
            push_data = {
                "request_id": request_id,
                "login_request_id": request_id,  # явное имя для tda.* handler'ов
                "device_name": body.device_name or "Новое устройство",
                "platform": getattr(body, 'platform', None) or "unknown",
                "ip": _client_ip(request),
                "ts": now_,
                "expires_at": now_ + 300,
            }
            try:
                ws_hub.send_to(u["id"], "login.pending", push_data)
            except Exception:
                pass
            try:
                ws_hub.send_to(u["id"], "tda.pending.new", push_data)
            except Exception:
                pass
            c.close()
            return {
                "requires_approval": True,
                "request_id": request_id,
                "code": login_code,
                "username": u["username"],
                "display_name": u["display_name"],
                "expires_in": 300,
            }

        is_first_dev = (trusted_count == 0)
        d = _da.register_device(
            c, u["id"], body.device_id, body.device_name,
            getattr(body, 'platform', None), is_owner=is_first_dev
        )
        c.close()
        return {"id": u["id"], "username": u["username"],
                "display_name": u["display_name"], "token": d["token"],
                "device_id": d["device_id"]}
    # Legacy путь
    tok_row = c.execute("SELECT token FROM soc_tokens WHERE user_id=?", (u["id"],)).fetchone()
    if tok_row:
        token = tok_row["token"]
    else:
        token = secrets.token_hex(32)
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (u["id"], token))
        c.commit()
    c.close()
    return {"id": u["id"], "username": u["username"], "display_name": u["display_name"], "token": token}

# ── Media upload ───────────────────────────────────────────────────────────────

# Запуск ffmpeg БЕЗ блокировки event loop: отдельный процесс + низкий приоритет (nice).
# Семафор ограничивает число одновременных сжатий, чтобы не перегружать CPU.
_FFMPEG_SEM = asyncio.Semaphore(2)

async def _run_ffmpeg(cmd: list, timeout: int = 600) -> int:
    """Асинхронно запускает ffmpeg, не блокируя event loop. 0 = успех."""
    async with _FFMPEG_SEM:
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                await asyncio.wait_for(proc.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                return 1
            return proc.returncode if proc.returncode is not None else 1
        except Exception:
            return 1


@router.post("/upload")
async def upload_media(request: Request, file: UploadFile = File(...), authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"upload:{user['id']}", limit=60, window=3600)
    ext = file.filename.rsplit(".", 1)[-1].lower() if "." in file.filename else ""
    mime = file.content_type or ""
    mime_ext = {
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png",
        "image/gif": "gif", "image/webp": "webp",
        "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov",
        "video/3gpp": "mp4", "video/x-msvideo": "mp4",
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/wav": "wav",
        "audio/ogg": "ogg", "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "mp3",
    }.get(mime, "")
    if not ext or ext not in (ALLOWED_IMAGE | ALLOWED_VIDEO | ALLOWED_AUDIO):
        ext = mime_ext
    if ext in ALLOWED_IMAGE:
        ftype, max_size = "image", MAX_IMAGE
    elif ext in ALLOWED_VIDEO:
        ftype, max_size = "video", MAX_VIDEO
    elif ext in ALLOWED_AUDIO:
        ftype, max_size = "audio", MAX_AUDIO
    else:
        raise HTTPException(400, f"Недопустимый тип файла: .{ext}")
    data = await file.read()
    if len(data) > max_size:
        raise HTTPException(400, f"Файл слишком большой. Максимум: {max_size // 1024 // 1024}MB")
    filename = f"{uuid.uuid4()}.{ext}"
    filepath = os.path.join(MEDIA_DIR, filename)
    if ftype == "image":
        try:
            from PIL import Image
            Image.MAX_IMAGE_PIXELS = 50_000_000
            img = Image.open(io.BytesIO(data))
            img.verify()  # rapid integrity check
            img = Image.open(io.BytesIO(data))
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGB")
            if img.width > 1920 or img.height > 1920:
                img.thumbnail((1920, 1920), Image.LANCZOS)
            out = io.BytesIO()
            fmt = {"jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "webp": "WEBP", "gif": "GIF"}.get(ext, "JPEG")
            kwargs = {"optimize": True}
            if fmt == "JPEG":
                kwargs["quality"] = 82
            img.save(out, format=fmt, **kwargs)
            with open(filepath, "wb") as f:
                f.write(out.getvalue())
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(400, "Не удалось обработать изображение")
    elif ftype == "video":
        with open(filepath, "wb") as f:
            f.write(data)
        compressed = os.path.join(MEDIA_DIR, f"{uuid.uuid4()}.mp4")
        ret = await _run_ffmpeg([
            "nice", "-n", "19", "ffmpeg", "-i", filepath,
            "-vf", "scale=-2:720",
            "-vcodec", "libx264", "-crf", "28", "-preset", "ultrafast",
            "-maxrate", "2500k", "-bufsize", "5M",
            "-acodec", "aac", "-b:a", "128k", "-movflags", "+faststart",
            compressed, "-y", "-loglevel", "error"
        ])
        if ret == 0 and os.path.exists(compressed):
            os.remove(filepath)
            filepath, filename = compressed, os.path.basename(compressed)
    elif ftype == "audio":
        with open(filepath, "wb") as f:
            f.write(data)
        compressed = os.path.join(MEDIA_DIR, f"{uuid.uuid4()}.mp3")
        ret = await _run_ffmpeg([
            "nice", "-n", "19", "ffmpeg", "-i", filepath,
            "-acodec", "libmp3lame", "-b:a", "128k", compressed, "-y", "-loglevel", "error"
        ])
        if ret == 0 and os.path.exists(compressed):
            os.remove(filepath)
            filepath, filename = compressed, os.path.basename(compressed)
    return {"url": f"/social/media/{filename}", "type": ftype, "name": file.filename}

# ── Posts ──────────────────────────────────────────────────────────────────────

def _hydrate_posts(c, rows: list, uid: int) -> list:
    """Дополняет посты реакциями и подпиской текущего юзера на автора."""
    if not rows:
        return []
    ids = [r["id"] for r in rows]
    placeholders = ",".join("?" * len(ids))
    react_rows = c.execute(
        f"SELECT post_id, emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id IN ({placeholders}) GROUP BY post_id, emoji",
        ids
    ).fetchall()
    my_rows = c.execute(
        f"SELECT post_id, emoji FROM soc_reactions WHERE user_id=? AND post_id IN ({placeholders})",
        [uid] + ids
    ).fetchall()
    per_post: dict = {pid: {"counts": {}, "your_emoji": None, "total": 0} for pid in ids}
    for r in react_rows:
        per_post[r["post_id"]]["counts"][r["emoji"]] = r["cnt"]
        per_post[r["post_id"]]["total"] += r["cnt"]
    for r in my_rows:
        per_post[r["post_id"]]["your_emoji"] = r["emoji"]
    author_ids = list({r["user_id"] for r in rows})
    followed: set = set()
    if uid and author_ids:
        ap = ",".join("?" * len(author_ids))
        f_rows = c.execute(
            f"SELECT followee_id FROM soc_follows WHERE follower_id=? AND followee_id IN ({ap})",
            [uid] + author_ids
        ).fetchall()
        followed = {r["followee_id"] for r in f_rows}
    views_map = {pid: 0 for pid in ids}
    try:
        v_count_rows = c.execute(
            f"SELECT post_id, COUNT(*) as n FROM soc_post_views WHERE post_id IN ({placeholders}) GROUP BY post_id",
            ids,
        ).fetchall()
        for r in v_count_rows:
            views_map[r["post_id"]] = r["n"]
    except Exception:
        pass
    reposts_map = {pid: 0 for pid in ids}
    try:
        r_count_rows = c.execute(
            f"SELECT post_id, COUNT(*) as n FROM soc_reposts WHERE post_id IN ({placeholders}) GROUP BY post_id",
            ids,
        ).fetchall()
        for r in r_count_rows:
            reposts_map[r["post_id"]] = r["n"]
    except Exception:
        pass
    polls_map = {}
    p_rows = c.execute(
        f"SELECT post_id, question, options, is_quiz, correct_idx FROM soc_polls WHERE post_id IN ({placeholders})",
        ids
    ).fetchall()
    if p_rows:
        v_rows = c.execute(
            f"SELECT post_id, option_idx, COUNT(*) as cnt FROM soc_poll_votes WHERE post_id IN ({placeholders}) GROUP BY post_id, option_idx",
            ids
        ).fetchall()
        my_votes = {}
        if uid > 0:
            mv_rows = c.execute(
                f"SELECT post_id, option_idx FROM soc_poll_votes WHERE user_id=? AND post_id IN ({placeholders})",
                [uid] + ids
            ).fetchall()
            my_votes = {r["post_id"]: r["option_idx"] for r in mv_rows}
        votes_by_post = defaultdict(dict)
        for r in v_rows:
            votes_by_post[r["post_id"]][r["option_idx"]] = r["cnt"]
        for r in p_rows:
            pid = r["post_id"]
            try: opts = json.loads(r["options"])
            except: opts = []
            counts = votes_by_post.get(pid, {})
            mv = my_votes.get(pid)
            polls_map[pid] = {
                "question": r["question"],
                "options": opts,
                "counts": counts,
                "total": sum(counts.values()),
                "my_vote": mv,
                "is_quiz": bool(r["is_quiz"]),
                "correct_idx": r["correct_idx"] if (r["is_quiz"] and mv is not None) else None,
            }
    channel_map = {}
    src_ids = list({r["source_channel_id"] for r in rows if "source_channel_id" in r.keys() and r["source_channel_id"]})
    if src_ids:
        cph = ",".join("?" * len(src_ids))
        ch_rows = c.execute(
            f"SELECT id, name, username, kind FROM chat_groups WHERE id IN ({cph})",
            src_ids
        ).fetchall()
        channel_map = {ch["id"]: dict(ch) for ch in ch_rows}
    out = []
    for r in rows:
        post = fmt_post(dict(r), uid, per_post[r["id"]], r["user_id"] in followed)
        if r["id"] in polls_map:
            post["poll"] = polls_map[r["id"]]
        post["views_count"] = views_map.get(r["id"], 0)
        post["reposts_count"] = reposts_map.get(r["id"], 0)
        sci = r["source_channel_id"] if "source_channel_id" in r.keys() else None
        if sci and channel_map.get(sci):
            ch = channel_map[sci]
            post["from_channel"] = {
                "id": ch["id"], "name": ch["name"], "username": ch["username"],
            }
        out.append(post)
    return out

@router.get("/post")
def get_posts(
    sort: str = Query("new"),
    offset: int = Query(0),
    tag: Optional[str] = Query(None),
    seed: int = Query(0),
    authorization: Optional[str] = Header(None),
):
    user = auth(authorization)
    uid = user["id"]
    _rate_limit(f"posts:{uid}", limit=120, window=60)
    # Clamp offset чтобы не дёрнули миллион постов вперёд.
    offset = max(0, min(int(offset or 0), 100000))
    c = db()
    if sort == "top":
        order = (
            "((SELECT COUNT(*) FROM soc_reactions l WHERE l.post_id=p.id) + 1) "
            "* COALESCE(p.activity, 500) / 500.0 "
            "* (1.0 / (1.0 + (strftime('%s','now') - strftime('%s', p.created_at)) / 172800.0)) "
            "DESC, p.created_at DESC"
        )
    elif sort == "old":
        order = "p.created_at ASC"
    elif sort == "random":
        s = max(1, int(seed) % 1000003) or 1
        order = f"((p.id * {s}) % 1000003) / (COALESCE(p.activity, 500) / 500.0 + 0.1)"
    else:
        order = (
            "CASE WHEN COALESCE(p.activity, 500) >= 700 THEN 0 ELSE 1 END, "
            "p.created_at DESC"
        )

    where = ["p.kind='post'"]  # обычная лента — без минисок
    where.append("COALESCE(p.activity, 500) >= 10")  # ниже 10 = не показываем (модерация)
    params: list = []
    join_following = ""
    if sort == "following":
        join_following = "JOIN soc_follows f ON f.followee_id=p.user_id AND f.follower_id=?"
        params.append(uid)
    if tag:
        where.append("(p.content LIKE ? OR p.content LIKE ? OR p.content LIKE ? OR p.content = ?)")
        like = f'%#{tag}%'
        params.extend([like, like, like, f'#{tag}'])
    where_sql = "WHERE " + " AND ".join(where)

    # Сортировка:
    #   new — чисто по дате (юзер ХОЧЕТ новые, viewed-фильтр НЕ применяем)
    #   following — то же самое (новые от подписок)
    #   "Для вас" / другие — viewed уходят вниз (отдельной сортировкой)
    # Это исправляет баг "после открытия feed свой пост исчез из new".
    # (раньше CASE WHEN viewed_at IS NULL ставил viewed в конец и юзер думал что нет постов)

    params_with_uid = [uid] + params + [offset]
    rows = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name, p.activity,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p
        JOIN users u ON p.user_id=u.id
        LEFT JOIN soc_post_views v ON v.post_id = p.id AND v.user_id = ?
        {join_following}
        {where_sql}
        ORDER BY {order}
        LIMIT 15 OFFSET ?
    """, params_with_uid).fetchall()
    result = _hydrate_posts(c, rows, uid)
    c.close()
    return result

@router.get("/post/feed")
def get_feed_candidates(
    offset: int = Query(0),
    limit: int = Query(50),
    exclude: str = Query("", description="comma-separated post ids уже видены клиентом"),
    authorization: Optional[str] = Header(None),
):
    """Candidate-pool для алгоритмической ленты «Для вас».
    Mix: ~40% свежие (последние 24ч), ~30% топ по реакциям за неделю, ~30% случайные.
    Клиент ранжирует локально по своему профилю интересов.
    """
    user = auth(authorization)
    uid = user["id"]
    # DoS guard: каждый /post/feed делает 4 SQL (follow + fresh + top + random),
    # массовая отправка (DevTools console for-loop) кладёт сервер за секунды.
    # 60 запросов/мин на юзера — реалистичный максимум при свайп-ленте.
    _rate_limit(f"feed:{uid}", limit=60, window=60)
    limit = max(5, min(100, limit))
    excluded: list = []
    if exclude:
        try:
            excluded = [int(x) for x in exclude.split(",") if x.strip().isdigit()][:500]
        except Exception:
            pass
    excl_sql = ""
    excl_params: list = []
    if excluded:
        ph = ",".join("?" * len(excluded))
        excl_sql = f"AND p.id NOT IN ({ph})"
        excl_params = excluded

    n_follow = max(1, int(limit * 0.30))
    n_new = max(1, int(limit * 0.30))
    n_top = max(1, int(limit * 0.25))
    n_rnd = max(1, limit - n_follow - n_new - n_top)
    MIN_ACTIVITY = 10

    c = db()
    follow_taken = []
    if not excluded:
        follow_sql_excl = ""
        follow_params = [uid, MIN_ACTIVITY, n_follow]
    else:
        ph_excl = ",".join("?" * len(excluded))
        follow_sql_excl = f"AND p.id NOT IN ({ph_excl})"
        follow_params = [uid] + list(excluded) + [MIN_ACTIVITY, n_follow]
    follow_rows = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p
        JOIN users u ON p.user_id=u.id
        JOIN soc_follows f ON f.followee_id=p.user_id AND f.follower_id=?
        WHERE p.kind='post' {follow_sql_excl} AND COALESCE(p.activity,500) >= ?
          AND p.created_at >= datetime('now', '-7 days')
        ORDER BY p.created_at DESC
        LIMIT ?
    """, follow_params).fetchall()

    taken_ids = {r["id"] for r in follow_rows} | set(excluded)
    if taken_ids:
        ph_t = ",".join("?" * len(taken_ids))
        fresh_sql = f"AND p.id NOT IN ({ph_t})"
        fresh_params = list(taken_ids) + [MIN_ACTIVITY, n_new + offset]
    else:
        fresh_sql = ""
        fresh_params = [MIN_ACTIVITY, n_new + offset]
    fresh = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.kind='post' AND p.created_at >= datetime('now', '-1 day')
          {fresh_sql} AND COALESCE(p.activity,500) >= ?
        ORDER BY (COALESCE(p.activity,500) / 500.0) DESC, p.created_at DESC
        LIMIT ?
    """, fresh_params).fetchall()
    fresh = fresh[offset:offset + n_new] if offset < len(fresh) else []

    taken = {r["id"] for r in follow_rows} | {r["id"] for r in fresh} | set(excluded)
    if taken:
        not_in_sql_top = f"AND p.id NOT IN ({','.join('?' * len(taken))})"
        top_params = list(taken) + [MIN_ACTIVITY, n_top]
    else:
        not_in_sql_top = ""
        top_params = [MIN_ACTIVITY, n_top]
    top = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.kind='post' AND p.created_at >= datetime('now', '-7 days')
          {not_in_sql_top} AND COALESCE(p.activity,500) >= ?
        ORDER BY (
          ((SELECT COUNT(*) FROM soc_reactions WHERE post_id=p.id) + 1)
          * COALESCE(p.activity, 500) / 500.0
          * (1.0 / (1.0 + (strftime('%s','now') - strftime('%s', p.created_at)) / 172800.0))
        ) DESC, p.created_at DESC
        LIMIT ?
    """, top_params).fetchall()

    seed = (uid * 9973 + offset * 17 + 1) % 1000003
    taken |= {r["id"] for r in top}
    if taken:
        where_rnd = f"WHERE p.kind='post' AND p.id NOT IN ({','.join('?' * len(taken))}) AND COALESCE(p.activity,500) >= ?"
        rnd_params = list(taken) + [MIN_ACTIVITY, n_rnd]
    else:
        where_rnd = "WHERE p.kind='post' AND COALESCE(p.activity,500) >= ?"
        rnd_params = [MIN_ACTIVITY, n_rnd]
    rnd = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        {where_rnd}
        ORDER BY ((p.id * {seed}) % 1000003) / (COALESCE(p.activity, 500) / 500.0 + 0.1)
        LIMIT ?
    """, rnd_params).fetchall()

    all_rows = list(follow_rows) + list(fresh) + list(top) + list(rnd)
    result = _hydrate_posts(c, all_rows, uid)
    c.close()
    return result

@router.get("/post/newhere")
def check_new(last_id: int = Query(...), sort: str = Query("new"), authorization: Optional[str] = Header(None)):
    auth(authorization)
    if sort == "old":
        return {"has_new": False, "count": 0}
    c = db()
    row = c.execute("SELECT COUNT(*) as cnt FROM soc_posts WHERE id > ?", (last_id,)).fetchone()
    c.close()
    return {"has_new": row["cnt"] > 0, "count": row["cnt"]}

@router.get("/post/counts")
def get_post_counts(ids: str = Query(...), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    try:
        post_ids = [int(x) for x in ids.split(",") if x.strip()]
    except Exception:
        raise HTTPException(400, "Invalid ids")
    if not post_ids or len(post_ids) > 30:
        raise HTTPException(400, "1-30 ids required")
    c = db()
    placeholders = ",".join("?" * len(post_ids))
    comm_rows = c.execute(
        f"SELECT p.id, (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count "
        f"FROM soc_posts p WHERE p.id IN ({placeholders})",
        post_ids
    ).fetchall()
    react_rows = c.execute(
        f"SELECT post_id, emoji, COUNT(*) as cnt FROM soc_reactions WHERE post_id IN ({placeholders}) GROUP BY post_id, emoji",
        post_ids
    ).fetchall()
    my_rows = c.execute(
        f"SELECT post_id, emoji FROM soc_reactions WHERE user_id=? AND post_id IN ({placeholders})",
        [uid] + post_ids
    ).fetchall()
    result: dict = {}
    for r in comm_rows:
        result[r["id"]] = {
            "reactions": {"counts": {}, "your_emoji": None, "total": 0},
            "comments_count": r["comments_count"],
        }
    for r in react_rows:
        if r["post_id"] in result:
            result[r["post_id"]]["reactions"]["counts"][r["emoji"]] = r["cnt"]
            result[r["post_id"]]["reactions"]["total"] += r["cnt"]
    for r in my_rows:
        if r["post_id"] in result:
            result[r["post_id"]]["reactions"]["your_emoji"] = r["emoji"]
    c.close()
    return result

@router.get("/post/{post_id}")
def get_one_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Для шаринга — открыть один пост по id."""
    user = auth(authorization)
    uid = user["id"]
    c = db()
    row = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.id=?
    """, (post_id,)).fetchone()
    if not row:
        c.close()
        raise HTTPException(404, "Post not found")
    result = _hydrate_posts(c, [row], uid)
    c.close()
    return result[0]

@router.post("/post/new")
def create_post(body: PostBody, request: Request, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"post:{user['id']}", limit=30, window=3600)
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "Empty")
    if len(text) > 1000:
        raise HTTPException(400, "Too long")
    media = _val_media(body.media)
    media_json = json.dumps(media, ensure_ascii=False) if media else None

    poll = body.poll
    if poll is not None:
        q = (poll.question or "").strip()
        if not q or len(q) > 200:
            raise HTTPException(400, "Вопрос опроса: 1–200 символов")
        opts = [o.strip() for o in (poll.options or []) if o and o.strip()]
        if len(opts) < 2 or len(opts) > 6:
            raise HTTPException(400, "Опрос: от 2 до 6 вариантов")
        for o in opts:
            if len(o) > 80:
                raise HTTPException(400, "Вариант ответа: максимум 80 символов")
        if poll.is_quiz:
            if poll.correct_idx is None or poll.correct_idx < 0 or poll.correct_idx >= len(opts):
                raise HTTPException(400, "Викторина: укажите правильный ответ")

    c = db()
    now_ts = int(time.time())
    u_info = c.execute(
        "SELECT created_at FROM users WHERE id=?", (user["id"],)
    ).fetchone()
    posts_cnt = c.execute(
        "SELECT COUNT(*) as n FROM soc_posts WHERE user_id=?", (user["id"],)
    ).fetchone()["n"]
    is_banned = False  # колонки бан-флага сейчас нет в users; добавим позже
    try:
        import datetime as _dt
        reg_dt = _dt.datetime.fromisoformat(u_info["created_at"].replace('Z',''))
        days_reg = (_dt.datetime.now() - reg_dt).days
    except Exception:
        days_reg = 0
    if is_banned:
        init_activity = 50           # бан-юзер: минимальная видимость
    elif days_reg < 1:
        init_activity = 200          # совсем свежий аккаунт
    elif days_reg < 7 or posts_cnt < 3:
        init_activity = 350          # новый/мало активный
    elif posts_cnt < 30 or days_reg < 30:
        init_activity = 500          # стандарт
    else:
        init_activity = 600          # опытный юзер
    init_activity = max(10, min(1000, init_activity))

    nsfw_flag = 1 if body.is_nsfw else 0
    c.execute(
        "INSERT INTO soc_posts (user_id, content, media, activity, activity_set_at, automod_source, is_nsfw, nsfw_set_by) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (user["id"], text, media_json, init_activity, now_ts, 'B', nsfw_flag, None),
    )
    post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.execute(
        "INSERT INTO soc_activity_log (post_id, old_activity, new_activity, delta, source, actor_id, note, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (post_id, None, init_activity, init_activity, 'automod_B', None,
         f'days_reg={days_reg} posts_cnt={posts_cnt}', now_ts),
    )
    if poll is not None:
        c.execute(
            "INSERT INTO soc_polls (post_id, question, options, is_quiz, correct_idx) VALUES (?,?,?,?,?)",
            (post_id, q, json.dumps(opts, ensure_ascii=False),
             1 if poll.is_quiz else 0,
             poll.correct_idx if poll.is_quiz else None),
        )

    preview = text[:120]
    notified = {user["id"]}  # не дублируем уведомления автору / повторно

    followers = c.execute(
        "SELECT follower_id FROM soc_follows WHERE followee_id=?", (user["id"],)
    ).fetchall()
    for f in followers:
        fid = f["follower_id"]
        if fid in notified:
            continue
        _add_notif(c, fid, user["id"], "new_post", post_id, preview)
        notified.add(fid)

    for uname in _extract_mentions(text):
        u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
        if u and u["id"] not in notified:
            _add_notif(c, u["id"], user["id"], "mention", post_id, preview)
            notified.add(u["id"])

    c.commit()
    c2 = db()
    row = c2.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               0 as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id WHERE p.id=?
    """, (post_id,)).fetchone()
    if row:
        full = _hydrate_posts(c2, [row], 0)[0]
        ws_hub.broadcast("post.new", {"post": full})
    c2.close()
    c.close()
    try: award_gost(user["id"], 'post', ref_type='post', ref_id=post_id)
    except Exception: pass
    try: _restore_reputation_if_due(user["id"])
    except Exception: pass
    return {"status": "ok", "post_id": post_id}

@router.patch("/post/{post_id}")
def edit_post(post_id: int, body: EditPostBody, authorization: Optional[str] = Header(None)):
    """Редактирование своего поста. Текст можно менять. Медиа — только убрать
    (нельзя добавить, нельзя подменить url). Не чаще раза в 30 минут."""
    user = auth_member(authorization)
    _rate_limit(f"editpost:{user['id']}", limit=10, window=60)
    c = db()
    post = c.execute("SELECT * FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    p = dict(post)
    if p["user_id"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")

    nsfw_only_edit = (
        body.is_nsfw is not None and body.text is None and body.media is None
    )

    # Окно редактирования: только в течение 30 минут после публикации.
    # Также если уже редактировали — не чаще раз в 30 минут.
    # (раньше проверялось только edited_at; если NULL — можно было править через год)
    if not nsfw_only_edit:
        reference_ts = p.get("edited_at") or p.get("created_at")
        if reference_ts:
            ok_after = c.execute(
                "SELECT (strftime('%s','now') - strftime('%s', ?)) >= 1800 as ok", (reference_ts,)
            ).fetchone()["ok"]
            if not ok_after:
                wait = c.execute(
                    "SELECT 1800 - (strftime('%s','now') - strftime('%s', ?)) as s", (reference_ts,)
                ).fetchone()["s"]
                c.close()
                raise HTTPException(429, f"Можно редактировать раз в 30 минут. Подождите ещё {max(1, wait//60)} мин.")

    updates = []
    params = []

    if body.text is not None:
        text = body.text.strip()
        if not text:
            c.close()
            raise HTTPException(400, "Текст не может быть пустым")
        if len(text) > 1000:
            c.close()
            raise HTTPException(400, "Слишком длинный текст (макс 1000)")
        updates.append("content=?")
        params.append(text)

    if body.media is not None:
        old_media = []
        if p.get("media"):
            try: old_media = json.loads(p["media"])
            except: pass
        old_urls = {m.get("url") for m in old_media}
        new_urls = {m.get("url") for m in (body.media or [])}
        added = new_urls - old_urls
        if added:
            c.close()
            raise HTTPException(400, "Добавлять медиа нельзя — только удалять существующие")
        removed = old_urls - new_urls
        for m in old_media:
            if m.get("url") in removed:
                fname = m["url"].split("/")[-1]
                if fname:
                    fp = os.path.join(MEDIA_DIR, fname)
                    if os.path.exists(fp):
                        try: os.remove(fp)
                        except: pass
        kept = [m for m in old_media if m.get("url") in new_urls]
        updates.append("media=?")
        params.append(json.dumps(kept, ensure_ascii=False) if kept else None)

    if body.is_nsfw is not None:
        new_val = 1 if body.is_nsfw else 0
        cur_val = int(p.get("is_nsfw") or 0)
        cur_setby = p.get("nsfw_set_by")
        if new_val == 0 and cur_val == 1 and cur_setby is not None:
            c.close()
            raise HTTPException(403, "NSFW поставлен модерацией — снять может только модератор")
        if new_val != cur_val:
            updates.append("is_nsfw=?")
            params.append(new_val)
            updates.append("nsfw_set_by=NULL")

    if not updates:
        c.close()
        raise HTTPException(422, "Нечего менять")

    if not nsfw_only_edit:
        updates.append("edited_at=datetime('now')")
    params.append(post_id)
    c.execute(f"UPDATE soc_posts SET {', '.join(updates)} WHERE id=?", params)
    c.commit()
    row = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id WHERE p.id=?
    """, (post_id,)).fetchone()
    if row:
        full = _hydrate_posts(c, [row], 0)[0]
        ws_hub.broadcast("post.edit", {"post": full})
    c.close()
    return {"status": "ok"}

@router.delete("/post/{post_id}")
def delete_post(post_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"delpost:{user['id']}", limit=20, window=60)
    c = db()
    post = c.execute("SELECT * FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    if dict(post)["user_id"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")
    if post["media"]:
        try:
            for m in json.loads(post["media"]):
                fname = m.get("url", "").split("/")[-1]
                if fname:
                    path = os.path.join(MEDIA_DIR, fname)
                    if os.path.exists(path):
                        os.remove(path)
        except Exception:
            pass
    c.execute("DELETE FROM soc_reactions WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_comments WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_notifications WHERE post_id=?", (post_id,))
    c.execute("DELETE FROM soc_posts WHERE id=?", (post_id,))
    c.commit()
    c.close()
    ws_hub.broadcast("post.delete", {"post_id": post_id})
    return {"status": "ok"}

# ── Search ─────────────────────────────────────────────────────────────────────

@router.get("/search")
def search(q: str = Query(..., max_length=120), offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    # DoS guard: внешний security audit (Воlдемар Домиров, 2026-06-20) показал
    _rate_limit(f"search:{uid}", limit=30, window=60)
    q = q.strip()
    if not q:
        raise HTTPException(400, "Empty query")
    if len(q) < 2:
        raise HTTPException(400, "Query too short")
    if len(q) > 80:
        raise HTTPException(400, "Query too long")
    c = db()
    if q.startswith("@"):
        term = q[1:].strip()
        if not term:
            c.close()
            return {"type": "users", "results": []}
        rows = c.execute("""
            SELECT u.id, u.username, u.display_name,
                   (SELECT COUNT(*) FROM soc_posts p WHERE p.user_id=u.id) as posts_count
            FROM users u
            WHERE ci_contains(u.username, ?) OR ci_contains(u.display_name, ?)
            ORDER BY posts_count DESC LIMIT 20 OFFSET ?
        """, (term, term, offset)).fetchall()
        c.close()
        return {"type": "users", "results": [dict(r) for r in rows]}
    else:
        rows = c.execute("""
            SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
                   u.username, u.display_name,
                   (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
            FROM soc_posts p JOIN users u ON p.user_id=u.id
            WHERE ci_contains(p.content, ?)
            ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
        """, (q, offset)).fetchall()
        result = _hydrate_posts(c, rows, uid)
        c.close()
        return {"type": "posts", "results": result}

# ── Profile ────────────────────────────────────────────────────────────────────

@router.get("/prof/{username}")
def get_profile(username: str, offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    uid = user["id"]
    c = db()
    u = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    if not u:
        c.close()
        raise HTTPException(404, "User not found")
    u = dict(u)
    stats = get_user_stats(c, u["id"])
    am_following = c.execute(
        "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?", (uid, u["id"])
    ).fetchone() is not None
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
    """, (u["id"], offset)).fetchall()
    posts = _hydrate_posts(c, rows, uid)
    c.close()
    rep_score = int(u.get("reputation_score") if u.get("reputation_score") is not None else 100)
    if u.get("eternal_status_text"):
        status_text = u.get("eternal_status_text")
        status_mood = u.get("eternal_status_mood")
        status_eternal = True
    elif _status_active(u.get("daily_status_set_at")):
        status_text = u.get("daily_status_text")
        status_mood = u.get("daily_status_mood")
        status_eternal = False
    else:
        status_text = None; status_mood = None; status_eternal = False
    return {
        "user_id": u["id"],
        "username": u["username"],
        "display_name": u["display_name"],
        "am_following": am_following,
        "is_me": uid == u["id"],
        "reputation_score": rep_score,
        "reputation_band": "low" if rep_score < 30 else ("mid" if rep_score < 70 else "good"),
        "daily_status": status_text,
        "daily_status_mood": status_mood,
        "daily_status_eternal": status_eternal,
        **stats,
        "posts": posts,
    }

@router.get("/prof/{username}/posts")
def get_profile_posts(username: str, offset: int = Query(0), authorization: Optional[str] = Header(None)):
    """Пагинация постов профиля (без stats — для подгрузки)."""
    user = auth(authorization)
    uid = user["id"]
    c = db()
    u = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not u:
        c.close()
        raise HTTPException(404, "User not found")
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.user_id=? ORDER BY p.created_at DESC LIMIT 15 OFFSET ?
    """, (u["id"], offset)).fetchall()
    posts = _hydrate_posts(c, rows, uid)
    c.close()
    return posts

@router.post("/follow/{username}")
def follow(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"follow:{user['id']}", limit=30, window=60)
    c = db()
    target = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not target:
        c.close()
        raise HTTPException(404, "User not found")
    if target["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя подписаться на себя")
    existing = c.execute(
        "SELECT 1 FROM soc_follows WHERE follower_id=? AND followee_id=?",
        (user["id"], target["id"])
    ).fetchone()
    if existing:
        c.close()
        return {"status": "ok", "following": True}
    c.execute(
        "INSERT INTO soc_follows (follower_id, followee_id) VALUES (?,?)",
        (user["id"], target["id"])
    )
    _add_notif(c, target["id"], user["id"], "follow", 0)
    c.commit()
    c.close()
    try: award_gost(target["id"], 'follow', actor_id=user["id"])
    except Exception: pass
    return {"status": "ok", "following": True}

@router.delete("/follow/{username}")
def unfollow(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"unfollow:{user['id']}", limit=30, window=60)
    c = db()
    target = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
    if not target:
        c.close()
        raise HTTPException(404, "User not found")
    c.execute(
        "DELETE FROM soc_follows WHERE follower_id=? AND followee_id=?",
        (user["id"], target["id"])
    )
    # снять follow-уведомление чтобы не осталось мусора при follow-unfollow спаме
    c.execute(
        "DELETE FROM soc_notifications WHERE user_id=? AND actor_id=? AND type='follow' AND is_read=0",
        (target["id"], user["id"])
    )
    c.commit()
    c.close()
    return {"status": "ok", "following": False}

@router.get("/me")
def get_me(authorization: Optional[str] = Header(None)):
    user = auth(authorization)
    if user.get("is_guest"):
        return {
            "id": 0, "user_id": 0,
            "username": "__guest__",
            "display_name": "Гость",
            "is_guest": True,
            "posts_count": 0, "likes_received": 0, "likes_given": 0,
            "followers_count": 0, "following_count": 0,
        }
    c = db()
    stats = get_user_stats(c, user["id"])
    flags_row = c.execute(
        "SELECT is_admin, is_moderator FROM users WHERE id=?", (user["id"],)
    ).fetchone()
    c.close()
    return {
        "id": user["id"],
        "user_id": user["id"],
        "username": user["username"],
        "display_name": user["display_name"],
        "is_guest": False,
        "is_admin": _is_admin_user({**user, "is_admin": (flags_row["is_admin"] if flags_row else 0)}),
        "is_moderator": bool(flags_row and flags_row["is_moderator"]),
        **stats,
    }

@router.patch("/me")
def edit_me(body: EditProfileBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"editme:{user['id']}", limit=10, window=3600)

    needs_old_pwd = body.username is not None or body.new_password is not None
    if needs_old_pwd:
        if not body.old_password:
            raise HTTPException(422, "Введите текущий пароль")
        # Используем существующие argon2-функции; legacy PBKDF2 → upgrade при следующем логине
        stored_hash = user.get("argon2_hash") or user.get("password_hash")
        if not stored_hash or not verify_argon2(body.old_password, stored_hash):
            raise HTTPException(401, "Неверный текущий пароль")

    updates: dict = {}
    if body.display_name is not None:
        updates["display_name"] = _val_name(body.display_name)
    if body.username is not None:
        updates["username"] = _val_username(body.username)
    if body.new_password is not None:
        _val_password(body.new_password)
        updates["argon2_hash"] = hash_argon2(body.new_password)
        # Инвалидируем legacy-pbkdf2-хэш если он был — пусть остаётся только argon2
        updates["password_hash"] = None
        updates["x25519_pub"] = None
        updates["encrypted_private_key"] = None
        updates["key_salt"] = None

    if not updates:
        raise HTTPException(422, "Нечего изменять")

    c = db()
    if "username" in updates:
        clash = c.execute(
            "SELECT id FROM users WHERE username=? AND id!=?", (updates["username"], user["id"])
        ).fetchone()
        if clash:
            c.close()
            raise HTTPException(409, "Имя пользователя уже занято")

    set_clause = ", ".join(f"{k}=?" for k in updates)
    c.execute(f"UPDATE users SET {set_clause} WHERE id=?", list(updates.values()) + [user["id"]])
    new_token = None
    if body.new_password is not None:
        c.execute("DELETE FROM soc_tokens WHERE user_id=?", (user["id"],))
        new_token = secrets.token_hex(32)
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (user["id"], new_token))
    c.commit()
    row = c.execute(
        "SELECT id, username, display_name FROM users WHERE id=?", (user["id"],)
    ).fetchone()
    c.close()
    out = {"status": "ok", "id": row["id"], "username": row["username"], "display_name": row["display_name"]}
    if new_token:
        out["token"] = new_token
        out["password_changed"] = True
    return out


class DeleteAccountBody(BaseModel):
    password: str  # подтверждение паролем — без него уничтожить аккаунт нельзя


@router.delete("/me/account")
def delete_my_account(body: DeleteAccountBody, authorization: Optional[str] = Header(None)):
    """Полное удаление аккаунта.
    Передаёт wallet-балансы и NFT системному пользователю GhostEcos,
    добавляет username в cooldown на 30 дней, стирает посты/комменты/реакции/follow.
    """
    user = auth_member(authorization)
    _rate_limit(f"delacc:{user['id']}", limit=3, window=3600)
    stored_hash = user.get("argon2_hash") or user.get("password_hash")
    if not stored_hash or not verify_argon2(body.password, stored_hash):
        raise HTTPException(401, "Неверный пароль")
    if (user.get("username") or "") == GHOSTECOS_USERNAME:
        raise HTTPException(403, "Системный аккаунт нельзя удалить")

    uid = user["id"]
    uname = (user["username"] or "").lower()
    now = int(time.time())
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
        sys_uid = sys_row["id"] if sys_row else None

        if sys_uid:
            c.execute("UPDATE soc_nfts SET owner_id=? WHERE owner_id=?", (sys_uid, uid))
            c.execute("DELETE FROM soc_nft_listings WHERE seller_id=?", (uid,))
            try:
                w = c.execute("SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (uid,)).fetchone()
                if w:
                    gost = int(w["gost"] or 0); soul = int(w["soul"] or 0); prem = int(w["prem"] or 0)
                    if gost or soul or prem:
                        c.execute("UPDATE soc_wallets SET gost=0, soul=0, prem=0 WHERE user_id=?", (uid,))
                        c.execute(
                            "UPDATE soc_wallets SET gost=gost+?, soul=soul+?, prem=prem+? WHERE user_id=?",
                            (gost, soul, prem, sys_uid),
                        )
                        # Логируем для аудита (если есть таблица wallet_tx)
                        try:
                            c.execute(
                                "INSERT INTO soc_wallet_tx (user_id, kind, currency, amount, reason, created_at) "
                                "VALUES (?,?,?,?,?,?)",
                                (uid, 'account_deleted', 'gost', -gost, 'transfer_to_system', now),
                            )
                        except Exception:
                            pass
            except Exception:
                pass

        c.execute(
            "DELETE FROM soc_reactions WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
        )
        c.execute("DELETE FROM soc_reactions WHERE user_id=?", (uid,))
        c.execute("DELETE FROM soc_comments WHERE user_id=?", (uid,))
        c.execute(
            "DELETE FROM soc_comments WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
        )
        try:
            c.execute("DELETE FROM soc_poll_votes WHERE user_id=?", (uid,))
            c.execute(
                "DELETE FROM soc_polls WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
            )
        except Exception:
            pass
        c.execute("DELETE FROM soc_posts WHERE user_id=?", (uid,))
        c.execute("DELETE FROM soc_follows WHERE follower_id=? OR followee_id=?", (uid, uid))
        try:
            c.execute("DELETE FROM soc_notifications WHERE user_id=? OR actor_id=?", (uid, uid))
        except Exception:
            pass
        try:
            c.execute("DELETE FROM chat_dm WHERE from_id=? OR to_id=?", (uid, uid))
            c.execute("DELETE FROM chat_contacts WHERE user_id=? OR contact_id=?", (uid, uid))
            c.execute("DELETE FROM chat_group_members WHERE user_id=?", (uid,))
            c.execute("DELETE FROM chat_group_acks WHERE user_id=?", (uid,))
            c.execute("DELETE FROM chat_group_join_requests WHERE user_id=?", (uid,))
        except Exception:
            pass
        try:
            c.execute("DELETE FROM soc_moderator_applications WHERE user_id=?", (uid,))
            c.execute("DELETE FROM soc_overwatch_votes WHERE moderator_id=?", (uid,))
        except Exception:
            pass
        c.execute("DELETE FROM soc_tokens WHERE user_id=?", (uid,))

        try:
            owned_unames = [r["username"] for r in c.execute(
                "SELECT username FROM soc_usernames WHERE owner_id=?", (uid,)
            ).fetchall()]
            for un in owned_unames:
                c.execute(
                    "INSERT OR REPLACE INTO soc_username_cooldown (username, released_at, prev_user_id, reason) "
                    "VALUES (?,?,?,?)",
                    (un.lower(), now + 30 * 86400, uid, 'account_deleted'),
                )
            c.execute("DELETE FROM soc_usernames WHERE owner_id=?", (uid,))
        except Exception:
            pass

        if uname:
            c.execute(
                "INSERT OR REPLACE INTO soc_username_cooldown (username, released_at, prev_user_id, reason) "
                "VALUES (?,?,?,?)",
                (uname, now + 30 * 86400, uid, 'account_deleted'),
            )

        try: c.execute("DELETE FROM soc_wallets WHERE user_id=?", (uid,))
        except Exception: pass
        c.execute("DELETE FROM users WHERE id=?", (uid,))

        c.commit()
        _nation_token = os.getenv("NATION_INTERNAL_TOKEN")
        if _nation_token and uname:
            try:
                import urllib.request, urllib.error
                req = urllib.request.Request(
                    f"http://127.0.0.1:8010/api/nation/archive/{uname}",
                    method="POST",
                    headers={"X-Internal-Token": _nation_token},
                )
                urllib.request.urlopen(req, timeout=3).read()
            except Exception:
                pass  # GhostNation может быть offline — не критично, страна останется orphaned
    except Exception as e:
        c.rollback()
        c.close()
        raise HTTPException(500, f"Ошибка удаления: {e}")
    c.close()
    return {"status": "ok", "deleted": True, "username_freed_in_days": 30}


# ── Likes ──────────────────────────────────────────────────────────────────────

@router.post("/react/{post_id}")
def react(post_id: int, body: ReactBody, authorization: Optional[str] = Header(None)):
    """Установить/сменить/снять реакцию. emoji=null → снять."""
    user = auth_member(authorization)
    _rate_limit(f"react:{user['id']}", limit=120, window=60)
    if body.emoji is not None and body.emoji not in ALLOWED_EMOJI:
        raise HTTPException(400, "Недопустимая реакция")
    c = db()
    post = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    owner_id = post["user_id"]
    existing = c.execute(
        "SELECT emoji FROM soc_reactions WHERE post_id=? AND user_id=?", (post_id, user["id"])
    ).fetchone()

    # Помечаем что нужно наградить АВТОРА поста после commit (а не во время — иначе SQLite lock)
    do_award_owner = False

    if body.emoji is None:
        if existing:
            c.execute("DELETE FROM soc_reactions WHERE post_id=? AND user_id=?", (post_id, user["id"]))
            c.execute(
                "DELETE FROM soc_notifications WHERE user_id=? AND actor_id=? AND type='react' AND post_id=? AND is_read=0",
                (owner_id, user["id"], post_id),
            )
    else:
        if existing:
            if existing["emoji"] != body.emoji:
                c.execute(
                    "UPDATE soc_reactions SET emoji=? WHERE post_id=? AND user_id=?",
                    (body.emoji, post_id, user["id"]),
                )
        else:
            c.execute(
                "INSERT INTO soc_reactions (post_id, user_id, emoji) VALUES (?,?,?)",
                (post_id, user["id"], body.emoji),
            )
            _add_notif(c, owner_id, user["id"], "react", post_id, body.emoji)
            # Награду отдадим ПОСЛЕ c.commit() / c.close() — award_gost открывает своё
            # соединение и BEGIN IMMEDIATE: пока мы держим транзакцию здесь — он словит lock.
            if owner_id != user["id"]:
                do_award_owner = True

    c.commit()
    result = _post_reactions(c, post_id, user["id"])
    public = {"counts": result.get("counts", {}), "total": result.get("total", 0)}
    ws_hub.broadcast("post.react", {"post_id": post_id, "reactions": public})
    c.close()

    # Награда автору — отдельным соединением, без конфликта lock'ов
    if do_award_owner:
        try: award_gost(owner_id, 'react', actor_id=user["id"], ref_type='post', ref_id=post_id)
        except Exception: pass

    try:
        c2 = db()
        _check_and_create_overwatch_viral(c2, post_id)
        c2.commit(); c2.close()
    except Exception: pass

    return result

# ── Comments ───────────────────────────────────────────────────────────────────

def _hydrate_comments(c, comment_ids, viewer_id):
    if not comment_ids:
        return {}
    qs = ",".join("?" * len(comment_ids))
    out = {cid: {"counts": {}, "your": None, "replies_count": 0} for cid in comment_ids}
    for r in c.execute(f"""
        SELECT comment_id, emoji, COUNT(*) as cnt
        FROM soc_comment_reactions
        WHERE comment_id IN ({qs})
        GROUP BY comment_id, emoji
    """, comment_ids).fetchall():
        out[r["comment_id"]]["counts"][r["emoji"]] = r["cnt"]
    if viewer_id:
        for r in c.execute(f"""
            SELECT comment_id, emoji FROM soc_comment_reactions
            WHERE comment_id IN ({qs}) AND user_id=?
        """, comment_ids + [viewer_id]).fetchall():
            out[r["comment_id"]]["your"] = r["emoji"]
    for r in c.execute(f"""
        SELECT parent_id, COUNT(*) as cnt FROM soc_comments
        WHERE parent_id IN ({qs}) GROUP BY parent_id
    """, comment_ids).fetchall():
        if r["parent_id"] in out:
            out[r["parent_id"]]["replies_count"] = r["cnt"]
    return out

@router.get("/com/get/{post_id}")
def get_comments(post_id: int, offset: int = Query(0), limit: int = Query(10),
                 sort: str = Query("top"),
                 authorization: Optional[str] = Header(None)):
    # AUDIT-1 fix: ловим ТОЛЬКО HTTPException (auth_member кидает её для
    # неавторизованных). Любой другой Exception — это реальный баг и
    # должен пробросится наверх, а не делать пользователя анонимным.
    user_or_none = None
    try:
        user_or_none = auth_member(authorization)
    except HTTPException:
        pass
    viewer_id = user_or_none["id"] if user_or_none else None
    auth(authorization)
    # AUDIT-3 fix: явный whitelist sort, чтобы будущая правка не открыла SQL-injection
    if sort not in ("top", "new"):
        sort = "top"
    limit = max(1, min(50, limit))
    c = db()
    # AUDIT-2 fix: вместо коррелированных subquery'ев в ORDER BY (O(N²))
    if sort == "top":
        order_sql = "ORDER BY top_score DESC, cm.created_at DESC"
    else:
        order_sql = "ORDER BY cm.created_at DESC"
    rows = c.execute(f"""
        SELECT cm.id, cm.text, cm.created_at, cm.parent_id, cm.reply_to_id,
               u.username, u.display_name,
               (COALESCE(rx.cnt, 0) + COALESCE(rp.cnt, 0)) as top_score
        FROM soc_comments cm
        JOIN users u ON cm.user_id = u.id
        LEFT JOIN (
            SELECT comment_id, COUNT(*) as cnt
            FROM soc_comment_reactions GROUP BY comment_id
        ) rx ON rx.comment_id = cm.id
        LEFT JOIN (
            SELECT parent_id, COUNT(*) as cnt
            FROM soc_comments WHERE parent_id IS NOT NULL GROUP BY parent_id
        ) rp ON rp.parent_id = cm.id
        WHERE cm.post_id = ? AND cm.parent_id IS NULL
        {order_sql}
        LIMIT ? OFFSET ?
    """, (post_id, limit, offset)).fetchall()
    total = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_comments WHERE post_id=? AND parent_id IS NULL", (post_id,)
    ).fetchone()["cnt"]
    ids = [r["id"] for r in rows]
    hydr = _hydrate_comments(c, ids, viewer_id)
    c.close()
    out = []
    for r in rows:
        d = dict(r)
        h = hydr.get(r["id"], {"counts": {}, "your": None, "replies_count": 0})
        d["reactions"] = {"counts": h["counts"], "your_emoji": h["your"], "total": sum(h["counts"].values())}
        d["replies_count"] = h["replies_count"]
        out.append(d)
    return {"comments": out, "has_more": (offset + limit) < total, "total": total}

@router.get("/com/replies/{comment_id}")
def get_replies(comment_id: int, offset: int = Query(0), limit: int = Query(10), authorization: Optional[str] = Header(None)):
    # AUDIT-1 fix: ловим только HTTPException (см. get_comments)
    user_or_none = None
    try: user_or_none = auth_member(authorization)
    except HTTPException: pass
    viewer_id = user_or_none["id"] if user_or_none else None
    auth(authorization)
    limit = max(1, min(50, limit))
    c = db()
    rows = c.execute("""
        SELECT cm.id, cm.text, cm.created_at, cm.parent_id, cm.reply_to_id,
               u.username, u.display_name,
               rt.text as reply_to_text, rtu.username as reply_to_username, rtu.display_name as reply_to_name
        FROM soc_comments cm JOIN users u ON cm.user_id=u.id
        LEFT JOIN soc_comments rt ON cm.reply_to_id = rt.id
        LEFT JOIN users rtu ON rt.user_id = rtu.id
        WHERE cm.parent_id=?
        ORDER BY cm.created_at ASC LIMIT ? OFFSET ?
    """, (comment_id, limit, offset)).fetchall()
    total = c.execute("SELECT COUNT(*) as cnt FROM soc_comments WHERE parent_id=?", (comment_id,)).fetchone()["cnt"]
    ids = [r["id"] for r in rows]
    hydr = _hydrate_comments(c, ids, viewer_id)
    c.close()
    out = []
    for r in rows:
        d = dict(r)
        h = hydr.get(r["id"], {"counts": {}, "your": None, "replies_count": 0})
        d["reactions"] = {"counts": h["counts"], "your_emoji": h["your"], "total": sum(h["counts"].values())}
        out.append(d)
    return {"replies": out, "has_more": (offset + limit) < total, "total": total}

@router.post("/com/{post_id}")
def write_comment(post_id: int, body: CommentBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"com:{user['id']}", limit=30, window=60)
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "Empty")
    if len(text) > 500:
        raise HTTPException(400, "Too long")
    c = db()
    post = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not post:
        c.close()
        raise HTTPException(404, "Post not found")
    parent_id = body.parent_comment_id  # после flatten будет top-level
    reply_to_id = body.parent_comment_id  # ОРИГИНАЛ — то на что юзер реально ответил
    parent_author_id = None
    if parent_id is not None:
        prow = c.execute(
            "SELECT post_id, user_id, parent_id FROM soc_comments WHERE id=?", (parent_id,)
        ).fetchone()
        if not prow or prow["post_id"] != post_id:
            c.close()
            raise HTTPException(400, "Bad parent")
        # Threading в один уровень: если parent — это уже reply, перевешиваем на его top-level,
        # но reply_to_id сохраняет настоящий target — чтобы в UI показать «↳ @user»
        if prow["parent_id"] is not None:
            parent_id = prow["parent_id"]
        parent_author_id = prow["user_id"]
    c.execute(
        "INSERT INTO soc_comments (post_id, user_id, text, parent_id, reply_to_id) VALUES (?,?,?,?,?)",
        (post_id, user["id"], text, parent_id, reply_to_id)
    )
    comment_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    notified = {user["id"]}
    _add_notif(c, post["user_id"], user["id"], "comment", post_id, text[:120])
    notified.add(post["user_id"])
    if parent_author_id and parent_author_id not in notified:
        _add_notif(c, parent_author_id, user["id"], "reply", post_id, text[:120])
        notified.add(parent_author_id)
    for uname in _extract_mentions(text):
        u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
        if u and u["id"] not in notified:
            _add_notif(c, u["id"], user["id"], "mention", post_id, text[:120])
            notified.add(u["id"])
    c.commit()
    total = c.execute("SELECT COUNT(*) as cnt FROM soc_comments WHERE post_id=?", (post_id,)).fetchone()["cnt"]
    c.close()
    if post["user_id"] != user["id"]:
        try: award_gost(post["user_id"], 'comment', actor_id=user["id"], ref_type='comment', ref_id=comment_id)
        except Exception: pass
    ws_hub.broadcast("post.comment", {
        "post_id": post_id,
        "comments_count": total,
        "comment": {
            "id": comment_id, "text": text, "parent_id": parent_id,
            "username": user["username"], "display_name": user["display_name"],
        },
    })
    return {"status": "ok", "comment_id": comment_id, "parent_id": parent_id}

@router.post("/com/{comment_id}/react")
def react_comment(comment_id: int, body: CommentReactBody, authorization: Optional[str] = Header(None)):
    """Toggle реакция на коммент. Если такая же — снимаем; другая — заменяем; нет — ставим."""
    user = auth_member(authorization)
    _rate_limit(f"comrx:{user['id']}", limit=60, window=60)
    emoji = (body.emoji or "").strip()
    allowed = {"heart", "fire", "laugh", "sad", "clap", "eyes"}
    if emoji not in allowed:
        raise HTTPException(400, "Bad emoji")
    c = db()
    cm = c.execute("SELECT id, user_id, post_id FROM soc_comments WHERE id=?", (comment_id,)).fetchone()
    if not cm:
        c.close()
        raise HTTPException(404, "Comment not found")
    existing = c.execute(
        "SELECT emoji FROM soc_comment_reactions WHERE comment_id=? AND user_id=?",
        (comment_id, user["id"])
    ).fetchone()
    your = None
    if existing and existing["emoji"] == emoji:
        c.execute("DELETE FROM soc_comment_reactions WHERE comment_id=? AND user_id=?", (comment_id, user["id"]))
    elif existing:
        c.execute("UPDATE soc_comment_reactions SET emoji=? WHERE comment_id=? AND user_id=?",
                  (emoji, comment_id, user["id"]))
        your = emoji
    else:
        c.execute("INSERT INTO soc_comment_reactions (comment_id, user_id, emoji) VALUES (?,?,?)",
                  (comment_id, user["id"], emoji))
        your = emoji
        if cm["user_id"] != user["id"]:
            _add_notif(c, cm["user_id"], user["id"], "comment_react", cm["post_id"], emoji)
    c.commit()
    counts = {}
    for r in c.execute("SELECT emoji, COUNT(*) as cnt FROM soc_comment_reactions WHERE comment_id=? GROUP BY emoji", (comment_id,)).fetchall():
        counts[r["emoji"]] = r["cnt"]
    c.close()
    return {"status": "ok", "your_emoji": your, "counts": counts, "total": sum(counts.values())}

@router.delete("/com/{comment_id}")
def delete_comment(comment_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"delcom:{user['id']}", limit=30, window=60)
    c = db()
    row = c.execute("SELECT cm.user_id, p.user_id as post_owner FROM soc_comments cm JOIN soc_posts p ON cm.post_id=p.id WHERE cm.id=?", (comment_id,)).fetchone()
    if not row:
        c.close()
        raise HTTPException(404, "Comment not found")
    if row["user_id"] != user["id"] and row["post_owner"] != user["id"]:
        c.close()
        raise HTTPException(403, "Forbidden")
    c.execute("DELETE FROM soc_comments WHERE id=?", (comment_id,))
    c.commit()
    c.close()
    return {"status": "ok"}

# ── Notifications ───────────────────────────────────────────────────────────────

@router.get("/notif")
def get_notifications(offset: int = Query(0), authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT n.id, n.type, n.post_id, n.preview, n.is_read, n.created_at,
               a.username as actor_username, a.display_name as actor_name
        FROM soc_notifications n
        JOIN users a ON n.actor_id = a.id
        WHERE n.user_id = ?
        ORDER BY n.id DESC
        LIMIT 20 OFFSET ?
    """, (user["id"], offset)).fetchall()
    total = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_notifications WHERE user_id=?", (user["id"],)
    ).fetchone()["cnt"]
    c.close()
    return {
        "notifications": [
            {
                "id": r["id"],
                "type": r["type"],
                "post_id": r["post_id"],
                "preview": r["preview"],
                "is_read": bool(r["is_read"]),
                "created_at": r["created_at"],
                "actor_username": r["actor_username"],
                "actor_name": r["actor_name"],
            }
            for r in rows
        ],
        "has_more": offset + 20 < total,
        "total": total,
    }

@router.get("/notif/unread")
def unread_count(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    cnt = c.execute(
        "SELECT COUNT(*) as cnt FROM soc_notifications WHERE user_id=? AND is_read=0", (user["id"],)
    ).fetchone()["cnt"]
    c.close()
    return {"count": cnt}

@router.post("/notif/read")
def mark_read(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"notifread:{user['id']}", limit=30, window=60)
    c = db()
    c.execute("UPDATE soc_notifications SET is_read=1 WHERE user_id=? AND is_read=0", (user["id"],))
    c.commit()
    c.close()
    return {"status": "ok"}

# ── Health ─────────────────────────────────────────────────────────────────────

# ── Link preview (OG/twitter meta tags, SSRF-safe) ───────────────────────────

import ipaddress
import socket
from urllib.parse import urlparse, urljoin

_LINK_CACHE_TTL = 24 * 3600  # 24 часа
_LINK_FETCH_MAX = 200 * 1024  # 200 KB max HTML

def _safe_url(u: str) -> Optional[str]:
    """Возвращает нормализованный URL или None если небезопасный."""
    if not u or len(u) > 2000:
        return None
    try:
        p = urlparse(u)
    except Exception:
        return None
    if p.scheme not in ("http", "https"):
        return None
    if not p.netloc:
        return None
    host = p.hostname or ""
    try:
        for fam in (socket.AF_INET, socket.AF_INET6):
            try:
                infos = socket.getaddrinfo(host, None, fam)
            except Exception:
                continue
            for info in infos:
                addr = info[4][0]
                ip = ipaddress.ip_address(addr)
                if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
                    return None
    except Exception:
        return None
    return f"{p.scheme}://{p.netloc}{p.path or '/'}{'?' + p.query if p.query else ''}"

@router.get("/linkpreview")
async def link_preview(url: str = Query(..., max_length=2000), authorization: Optional[str] = Header(None)):
    """OG/Twitter meta preview. SSRF-safe, кэш 24ч."""
    u = auth(authorization)
    _rate_limit(f"linkprev:{u.get('id', 0)}", limit=30, window=60)
    safe = _safe_url(url)
    if not safe:
        raise HTTPException(400, "Невалидный URL")

    c = db()
    row = c.execute(
        "SELECT data, fetched_at FROM soc_link_cache WHERE url=?", (safe,)
    ).fetchone()
    now = int(time.time())
    if row and (now - row["fetched_at"]) < _LINK_CACHE_TTL:
        c.close()
        try:
            return json.loads(row["data"])
        except Exception:
            pass

    import httpx
    from bs4 import BeautifulSoup
    try:
        async with httpx.AsyncClient(
            timeout=3.0, follow_redirects=True, max_redirects=4,
            headers={"User-Agent": "GhostSocialPreview/1.0 (+https://ghostecos.duckdns.org)"}
        ) as client:
            r = await client.get(safe)
            ctype = r.headers.get("content-type", "")
            if "html" not in ctype.lower():
                c.close()
                raise HTTPException(415, "Не HTML")
            content = r.content[:_LINK_FETCH_MAX]
            final_url = str(r.url)
    except HTTPException:
        raise
    except Exception:
        c.close()
        raise HTTPException(502, "Не удалось загрузить")

    try:
        soup = BeautifulSoup(content, "html.parser")
    except Exception:
        c.close()
        raise HTTPException(500, "Ошибка парсинга")

    def meta(prop):
        for key in ("property", "name"):
            tag = soup.find("meta", attrs={key: prop})
            if tag and tag.get("content"):
                return tag["content"].strip()
        return None

    title = (meta("og:title") or meta("twitter:title") or
             (soup.title.string.strip() if soup.title and soup.title.string else None))
    description = meta("og:description") or meta("twitter:description") or meta("description")
    image = meta("og:image") or meta("twitter:image")
    site = meta("og:site_name") or urlparse(final_url).hostname

    if image and not image.startswith(("http://", "https://")):
        image = urljoin(final_url, image)
    if image:
        image = _safe_url(image) or None

    out = {
        "url": final_url,
        "title": (title or "")[:200],
        "description": (description or "")[:400],
        "image": image,
        "site": (site or "")[:100],
    }

    c.execute(
        "INSERT OR REPLACE INTO soc_link_cache (url, data, fetched_at) VALUES (?,?,?)",
        (safe, json.dumps(out, ensure_ascii=False), now),
    )
    c.commit()
    c.close()
    return out

# ── Просмотры постов + activity API (Фаза 0+1) ───────────────────────────────

class ViewBody(BaseModel):
    ids: list  # post_id-ы, попавшие в viewport

@router.post("/post/view")
def mark_viewed(body: ViewBody, authorization: Optional[str] = Header(None)):
    """Клиент шлёт сюда id постов которые юзер увидел на экране.
    Используется feed-ом для сортировки 'не показывать уже видённое сверху'.
    Batch — до 50 за раз."""
    if authorization and "guest_" in authorization:
        return {"recorded": 0, "guest": True}
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"recorded": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:50]
    if not ids:
        return {"recorded": 0}
    now = int(time.time())
    c = db()
    # Не помечаем как viewed СВОИ посты (иначе они проваливаются вниз "Для вас")
    own_ids = {r["id"] for r in c.execute(
        f"SELECT id FROM soc_posts WHERE id IN ({','.join('?'*len(ids))}) AND user_id=?",
        ids + [user["id"]]
    ).fetchall()}
    cnt = 0
    for pid in ids:
        if pid in own_ids:
            continue
        c.execute(
            "INSERT OR IGNORE INTO soc_post_views (user_id, post_id, viewed_at) VALUES (?,?,?)",
            (user["id"], pid, now),
        )
        cnt += 1
    c.commit(); c.close()
    return {"recorded": cnt, "skipped_own": len(ids) - cnt}


@router.get("/post/{post_id}/activity")
def post_activity(post_id: int, authorization: Optional[str] = Header(None)):
    """Текущая activity поста + история изменений. Видит только автор."""
    user = auth_member(authorization)
    c = db()
    p = c.execute(
        "SELECT user_id, activity, activity_set_at, automod_source FROM soc_posts WHERE id=?",
        (post_id,)
    ).fetchone()
    if not p:
        c.close(); raise HTTPException(404, "Не найден")
    if p["user_id"] != user["id"] and not _is_admin_user(user):
        c.close(); raise HTTPException(403, "Только автор или admin")
    history = c.execute(
        "SELECT old_activity, new_activity, delta, source, note, created_at "
        "FROM soc_activity_log WHERE post_id=? ORDER BY id DESC LIMIT 20",
        (post_id,)
    ).fetchall()
    c.close()
    return {
        "activity": p["activity"],
        "set_at": p["activity_set_at"],
        "automod_source": p["automod_source"],
        "scale": {"min": 0, "low": 100, "mid": 500, "max": 1000},
        "history": [dict(h) for h in history],
    }


# ══════════════════════════════════════════════════════════════════════════════
# МОДЕРАЦИЯ (Фаза 2+3)
# - Юзеры подают заявки на роль модератора за 200 Gost
# - Owner (юзер с is_admin=1) принимает/отклоняет
# - Авторы могут купить overwatch для своего поста (300 Gost базово,
#   динамическая цена потом)
# - Модераторы голосуют сдвигом ±50/±150, среднее → применяется к activity
# - Цена голосов ограничена ±150 за один overwatch
# ══════════════════════════════════════════════════════════════════════════════

MOD_APPLY_PRICE_GOST = 200
OVERWATCH_BASE_PRICE_GOST = 300
OVERWATCH_MAX_STEP = 150           # ±150 максимум за один overwatch
OVERWATCH_MOD_SHARE_PCT = 15       # 15% оплаты идёт модераторам, 85% сжигается
OVERWATCH_PER_MOD_BASE = 10        # базовая оплата модератору за голос


def _is_admin_user(user) -> bool:
    """Owner экосистемы — единственный юзер с is_admin=1 или username из env."""
    if user.get("is_admin"):
        return True
    owner = os.getenv("GE_OWNER_USERNAME", "").strip().lower()
    return bool(owner) and user.get("username", "").lower() == owner


_OG_CACHE_DIR = "/tmp/ge_og_cache"
try: os.makedirs(_OG_CACHE_DIR, exist_ok=True)
except Exception: pass

def _og_cached(key: str, max_age_s: int = 3600):
    """Возвращает путь к закэшированному PNG если свежий, иначе None."""
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", key)
    p = os.path.join(_OG_CACHE_DIR, safe + ".png")
    if os.path.exists(p):
        age = time.time() - os.path.getmtime(p)
        if age < max_age_s:
            return p
    return None

def _og_save(key: str, png_bytes: bytes) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", key)
    p = os.path.join(_OG_CACHE_DIR, safe + ".png")
    try:
        with open(p, "wb") as f:
            f.write(png_bytes)
    except Exception:
        pass
    return p

def _og_render(title: str, subtitle: str, footer: str, accent: str = "") -> bytes:
    """Базовый OG-генератор 1200×630, тёмно-фиолетовый градиент."""
    from PIL import Image, ImageDraw, ImageFont
    W, H = 1200, 630
    img = Image.new("RGB", (W, H), (10, 4, 26))  # #0a041a
    overlay = Image.new("RGB", (W, H), (10, 4, 26))
    od = ImageDraw.Draw(overlay)
    for y in range(H):
        t = y / H
        r = int(20 + (10 - 20) * t)
        g = int(8 + (4 - 8) * t)
        b = int(40 + (26 - 40) * t)
        od.line([(0, y), (W, y)], fill=(r, g, b))
    img = overlay
    d = ImageDraw.Draw(img)
    for (cx, cy, rr, alpha) in [(200, 100, 220, 22), (1000, 530, 280, 18), (1100, 150, 160, 16)]:
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        ld.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(168, 85, 247, alpha))
        img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
        d = ImageDraw.Draw(img)
    # Шрифты — fallback на DejaVuSans
    def _font(size, bold=False):
        for path in (
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
        ):
            if os.path.exists(path):
                try: return ImageFont.truetype(path, size)
                except Exception: pass
        return ImageFont.load_default()
    f_brand = _font(28, bold=True)
    f_title = _font(60, bold=True)
    f_sub = _font(34)
    f_accent = _font(22, bold=True)
    f_footer = _font(20)
    d.text((60, 56), "GHOSTECOS", font=f_brand, fill=(168, 85, 247))
    if accent:
        try:
            tw = d.textlength(accent, font=f_accent)
        except Exception:
            tw = len(accent) * 12
        bx, by = W - 60 - int(tw) - 28, 60
        d.rounded_rectangle([bx, by, W - 60, by + 36], radius=18, fill=(74, 222, 128, 30), outline=(74, 222, 128, 180), width=2)
        d.text((bx + 14, by + 6), accent, font=f_accent, fill=(74, 222, 128))
    def _wrap(text, font, max_w):
        words = text.split(); lines = []; cur = ""
        for w in words:
            t = (cur + " " + w).strip()
            try: w_w = d.textlength(t, font=font)
            except Exception: w_w = len(t) * 14
            if w_w > max_w and cur:
                lines.append(cur); cur = w
            else:
                cur = t
        if cur: lines.append(cur)
        return lines
    title_lines = _wrap(title or "", f_title, W - 120)[:3]
    y = 200
    for ln in title_lines:
        d.text((60, y), ln, font=f_title, fill=(241, 245, 249))
        y += 76
    if subtitle:
        sub_lines = _wrap(subtitle, f_sub, W - 120)[:2]
        y += 14
        for ln in sub_lines:
            d.text((60, y), ln, font=f_sub, fill=(148, 163, 184))
            y += 42
    d.text((60, H - 60), footer or "ghostecos.duckdns.org", font=f_footer, fill=(168, 85, 247))
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def _og_response(png_bytes: bytes):
    from fastapi.responses import Response
    return Response(content=png_bytes, media_type="image/png",
                    headers={"Cache-Control": "public, max-age=3600"})


@router.get("/og/user/{username}.png")
def og_user_png(username: str):
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    cached = _og_cached(f"u_{uname}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    u = c.execute(
        "SELECT display_name, username, reputation_score FROM users WHERE username=?", (uname,)
    ).fetchone()
    if not u:
        c.close(); raise HTTPException(404, "User not found")
    posts = c.execute("SELECT COUNT(*) as n FROM soc_posts WHERE user_id=(SELECT id FROM users WHERE username=?)", (uname,)).fetchone()["n"]
    followers = c.execute("SELECT COUNT(*) as n FROM soc_follows WHERE followee_id=(SELECT id FROM users WHERE username=?)", (uname,)).fetchone()["n"]
    c.close()
    rep = int(u["reputation_score"] or 100)
    title = u["display_name"] or u["username"]
    sub = f"@{u['username']} · {posts} постов · {followers} подписчиков · репутация {rep}/100"
    png = _og_render(title=title, subtitle=sub, footer="ghostecos.duckdns.org/social",
                     accent=("18+" if False else ""))
    _og_save(f"u_{uname}", png)
    return _og_response(png)


@router.get("/og/post/{post_id}.png")
def og_post_png(post_id: int):
    cached = _og_cached(f"p_{post_id}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    row = c.execute(
        "SELECT p.content, p.is_nsfw, u.username, u.display_name "
        "FROM soc_posts p JOIN users u ON p.user_id=u.id WHERE p.id=?",
        (post_id,),
    ).fetchone()
    if not row:
        c.close(); raise HTTPException(404, "Post not found")
    reactions = c.execute("SELECT COUNT(*) as n FROM soc_reactions WHERE post_id=?", (post_id,)).fetchone()["n"]
    comments = c.execute("SELECT COUNT(*) as n FROM soc_comments WHERE post_id=?", (post_id,)).fetchone()["n"]
    c.close()
    is_nsfw = bool(row["is_nsfw"])
    if is_nsfw:
        title = "Пост помечен 18+"
        sub = f"От {row['display_name']} (@{row['username']}). Откройте чтобы посмотреть."
        accent = "18+ NSFW"
    else:
        content = (row["content"] or "").strip()
        title = content[:140] + ("..." if len(content) > 140 else "")
        sub = f"{row['display_name']} (@{row['username']}) · {reactions} реакций · {comments} комментариев"
        accent = ""
    png = _og_render(title=title or "Пост в GhostSocial", subtitle=sub,
                     footer=f"ghostecos.duckdns.org/p/{post_id}", accent=accent)
    _og_save(f"p_{post_id}", png)
    return _og_response(png)


@router.get("/og/wrapped/{username}.png")
def og_wrapped_png(username: str):
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    cached = _og_cached(f"w_{uname}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    u = c.execute("SELECT display_name, username FROM users WHERE username=?", (uname,)).fetchone()
    if not u:
        c.close(); raise HTTPException(404, "User not found")
    posts = c.execute("SELECT COUNT(*) as n FROM soc_posts WHERE user_id=(SELECT id FROM users WHERE username=?)", (uname,)).fetchone()["n"]
    reactions = c.execute(
        "SELECT COUNT(*) as n FROM soc_reactions r JOIN soc_posts p ON r.post_id=p.id "
        "WHERE p.user_id=(SELECT id FROM users WHERE username=?)", (uname,)
    ).fetchone()["n"]
    c.close()
    title = f"{u['display_name']}: год в GhostEcos"
    sub = f"@{u['username']} · {posts} публикаций · {reactions} реакций"
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/wrapped/{uname}", accent="WRAPPED")
    _og_save(f"w_{uname}", png)
    return _og_response(png)


@router.get("/og/group/{group_id}.png")
def og_group_png(group_id: int):
    cached = _og_cached(f"g_{group_id}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    g = c.execute(
        "SELECT id, name, kind, username, bio FROM chat_groups WHERE id=?", (group_id,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Group not found")
    members = c.execute("SELECT COUNT(*) FROM chat_group_members WHERE group_id=?", (group_id,)).fetchone()[0] or 0
    c.close()
    kind_label = "Канал" if g["kind"] == "channel" else "Группа"
    handle = f"@{g['username']}" if g["username"] else ""
    title = g["name"] or kind_label
    sub_parts = [f"{kind_label} · {members} участ."]
    if handle: sub_parts.insert(0, handle)
    if g["bio"]: sub_parts.append(g["bio"][:80])
    sub = " · ".join(sub_parts)
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/g/{group_id}", accent=kind_label.upper())
    _og_save(f"g_{group_id}", png)
    return _og_response(png)


@router.get("/og/channel/{username}.png")
def og_channel_png(username: str):
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    cached = _og_cached(f"ch_{uname}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    g = c.execute(
        "SELECT id, name, kind, username, bio FROM chat_groups WHERE username=?", (uname,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Channel not found")
    members = c.execute("SELECT COUNT(*) FROM chat_group_members WHERE group_id=?", (g["id"],)).fetchone()[0] or 0
    c.close()
    title = g["name"] or f"@{uname}"
    sub_parts = [f"@{uname}", f"{members} подписч."]
    if g["bio"]: sub_parts.append(g["bio"][:80])
    sub = " · ".join(sub_parts)
    accent = "КАНАЛ" if g["kind"] == "channel" else "ГРУППА"
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/c/{uname}", accent=accent)
    _og_save(f"ch_{uname}", png)
    return _og_response(png)


@router.get("/og/giveaway/{gid}.png")
def og_giveaway_png(gid: int):
    """OG/share-картинка розыгрыша. Title — название, subtitle — приз + winners.
    Используется в bottom-sheet «Поделиться» на /bank/giveaway/."""
    cached = _og_cached(f"gv_{gid}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    g = c.execute(
        "SELECT id, title, description, prize_gost, winners_count, status, ends_at, drawn_at "
        "FROM soc_giveaways WHERE id=?", (gid,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Giveaway not found")
    entries = c.execute(
        "SELECT COUNT(*) FROM soc_giveaway_entries WHERE giveaway_id=?", (gid,)
    ).fetchone()[0] or 0
    c.close()
    title = g["title"] or f"Розыгрыш #{gid}"
    win_word = "победителю" if g["winners_count"] == 1 else "победителям"
    status_word = {
        "active": "Сейчас идёт", "finished": "Завершён",
        "cancelled": "Отменён",
    }.get(g["status"], "Розыгрыш")
    sub = f"{status_word} · приз {g['prize_gost']} Gost {win_word} · {entries} участ."
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/bank/giveaway/", accent="GIVEAWAY")
    _og_save(f"gv_{gid}", png)
    return _og_response(png)


@router.get("/og/miniska/{post_id}.png")
def og_miniska_png(post_id: int):
    cached = _og_cached(f"m_{post_id}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    row = c.execute(
        "SELECT p.content, p.is_nsfw, u.username, u.display_name "
        "FROM soc_posts p JOIN users u ON p.user_id=u.id "
        "WHERE p.id=? AND p.kind='miniska'",
        (post_id,),
    ).fetchone()
    if not row:
        c.close(); raise HTTPException(404, "Miniska not found")
    reactions = c.execute("SELECT COUNT(*) FROM soc_reactions WHERE post_id=?", (post_id,)).fetchone()[0] or 0
    c.close()
    is_nsfw = bool(row["is_nsfw"])
    if is_nsfw:
        title = "Миниска 18+"
        sub = f"От {row['display_name']} (@{row['username']}) · откройте чтобы посмотреть"
        accent = "18+"
    else:
        content = (row["content"] or "").strip() or "Миниска"
        title = content[:80] + ("..." if len(content) > 80 else "")
        sub = f"{row['display_name']} (@{row['username']}) · {reactions} реакций · видео 48 ч"
        accent = "МИНИСКА"
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/m/{post_id}", accent=accent)
    _og_save(f"m_{post_id}", png)
    return _og_response(png)


@router.get("/og/nft/{nft_id}.png")
def og_nft_png(nft_id: int):
    cached = _og_cached(f"nft_{nft_id}")
    if cached:
        with open(cached, "rb") as f:
            return _og_response(f.read())
    c = db()
    row = c.execute(
        "SELECT n.id, n.serial, n.owner_id, cat.name, cat.rarity, "
        "u.username as owner_username, u.display_name as owner_display "
        "FROM soc_nfts n "
        "JOIN soc_nft_catalog cat ON n.catalog_id=cat.id "
        "JOIN users u ON n.owner_id=u.id "
        "WHERE n.id=?",
        (nft_id,),
    ).fetchone()
    if not row:
        c.close(); raise HTTPException(404, "NFT not found")
    list_row = c.execute(
        "SELECT price, currency FROM soc_nft_listings WHERE nft_id=? ORDER BY id DESC LIMIT 1",
        (nft_id,),
    ).fetchone()
    c.close()
    title = f"{row['name']} #{row['serial']}"
    sub_parts = [f"редкость: {row['rarity']}", f"владелец: @{row['owner_username']}"]
    if list_row:
        cur = (list_row["currency"] or "gost").upper()
        sub_parts.append(f"в продаже за {list_row['price']} {cur}")
    sub = " · ".join(sub_parts)
    accent = row["rarity"].upper()
    png = _og_render(title=title, subtitle=sub,
                     footer=f"ghostecos.duckdns.org/nft/{nft_id}", accent=accent)
    _og_save(f"nft_{nft_id}", png)
    return _og_response(png)


@router.get("/wrapped/{username}")
def wrapped_data(username: str, authorization: Optional[str] = Header(None)):
    """Wrapped-страница юзера. Shareable URL — не требует авторизации, НО:
    финансовые данные (wallet balance, NFT count, gost_earned, reactions_given,
    top_post.preview) видны только владельцу аккаунта. Чтоб посторонний не мог
    через перебор узнать сколько у кого денег и кому ставили лайки."""
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    me_id = 0
    if authorization:
        try:
            me = auth(authorization)
            me_id = me["id"]
        except Exception:
            me_id = 0
    c = db()
    u = c.execute(
        "SELECT id, username, display_name, created_at, reputation_score FROM users WHERE username=?",
        (uname,),
    ).fetchone()
    if not u:
        c.close(); raise HTTPException(404, "User not found")
    uid = u["id"]
    is_owner = (me_id == uid)

    def _one(sql, params=()):
        r = c.execute(sql, params).fetchone()
        return (r[0] if r else 0) or 0

    posts = _one("SELECT COUNT(*) FROM soc_posts WHERE user_id=? AND kind='post'", (uid,))
    miniska = _one("SELECT COUNT(*) FROM soc_posts WHERE user_id=? AND kind='miniska'", (uid,))
    comments = _one("SELECT COUNT(*) FROM soc_comments WHERE user_id=?", (uid,))
    reactions_given = _one("SELECT COUNT(*) FROM soc_reactions WHERE user_id=?", (uid,))
    reactions_received = _one(
        "SELECT COUNT(*) FROM soc_reactions r JOIN soc_posts p ON r.post_id=p.id WHERE p.user_id=?", (uid,)
    )
    followers = _one("SELECT COUNT(*) FROM soc_follows WHERE followee_id=?", (uid,))
    following = _one("SELECT COUNT(*) FROM soc_follows WHERE follower_id=?", (uid,))

    top_react_rows = c.execute(
        "SELECT emoji, COUNT(*) as cnt FROM soc_reactions WHERE user_id=? GROUP BY emoji ORDER BY cnt DESC LIMIT 3",
        (uid,),
    ).fetchall()
    top_reactions = [{"emoji": r["emoji"], "count": r["cnt"]} for r in top_react_rows]

    top_post_row = c.execute(
        "SELECT p.id, p.content, (SELECT COUNT(*) FROM soc_reactions WHERE post_id=p.id) as cnt "
        "FROM soc_posts p WHERE p.user_id=? AND p.kind='post' ORDER BY cnt DESC, p.created_at DESC LIMIT 1",
        (uid,),
    ).fetchone()
    top_post = None
    if top_post_row and top_post_row["cnt"]:
        top_post = {
            "id": top_post_row["id"],
            "preview": (top_post_row["content"] or "")[:140],
            "reactions": top_post_row["cnt"],
        }

    # Кошелёк: всего заработано Gost (по wallet_tx если есть) + текущий баланс
    try:
        gost_earned = _one(
            "SELECT COALESCE(SUM(amount), 0) FROM soc_wallet_tx WHERE user_id=? AND amount > 0", (uid,)
        )
    except Exception:
        gost_earned = 0
    try:
        wallet = c.execute("SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (uid,)).fetchone()
        bal = {"gost": int(wallet["gost"] if wallet else 0), "soul": int(wallet["soul"] if wallet else 0), "prem": int(wallet["prem"] if wallet else 0)}
    except Exception:
        bal = {"gost": 0, "soul": 0, "prem": 0}

    try:
        nft_count = _one("SELECT COUNT(*) FROM soc_nfts WHERE owner_id=?", (uid,))
    except Exception:
        nft_count = 0

    rank_total = _one("SELECT COUNT(*) FROM users WHERE id IN (SELECT DISTINCT user_id FROM soc_posts)")
    try:
        my_posts = posts + miniska
        rank = _one(
            "SELECT COUNT(*) + 1 FROM (SELECT user_id, COUNT(*) as cnt FROM soc_posts GROUP BY user_id) "
            "WHERE cnt > ?", (my_posts,)
        )
    except Exception:
        rank = 0

    days_in = 0
    try:
        import datetime as _dt
        reg = _dt.datetime.fromisoformat((u["created_at"] or "").replace("Z", ""))
        days_in = max(0, (_dt.datetime.now() - reg).days)
    except Exception:
        pass

    c.close()
    out = {
        "username": u["username"],
        "display_name": u["display_name"],
        "days_in": days_in,
        "reputation": int(u["reputation_score"] or 100),
        "posts": posts, "miniska": miniska, "comments": comments,
        "reactions_received": reactions_received,
        "followers": followers, "following": following,
        "activity_rank": rank,
        "activity_rank_total": rank_total,
        "is_owner": is_owner,
    }
    if is_owner:
        out.update({
            "reactions_given": reactions_given,    # кому ставил лайки — приватно
            "top_reactions": top_reactions,        # какие эмодзи чаще ставит — приватно
            "top_post": top_post,                  # превью поста как highlight — приватно
            "gost_earned_total": gost_earned,      # сколько заработал — финансы
            "balance": bal,                        # текущий баланс — финансы
            "nft_count": nft_count,                # NFT в коллекции — финансы
        })
    return out



@router.get("/me/reposts/ids")
def my_reposts_ids(authorization: Optional[str] = Header(None)):
    """Список post_id которые я уже репостил — для UI-кэша на фронте."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute("SELECT post_id FROM soc_reposts WHERE user_id=?", (user["id"],)).fetchall()
    c.close()
    return [r["post_id"] for r in rows]


@router.post("/post/{post_id}/repost")
def repost_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Репостнуть пост в свой профиль. Не идёт в общую ленту/подписки.
    Идемпотентно: повторный вызов возвращает existing=True."""
    user = auth_member(authorization)
    _rate_limit(f"repost:{user['id']}", limit=60, window=3600)
    c = db()
    p = c.execute("SELECT id, user_id, kind FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        c.close(); raise HTTPException(404, "Post not found")
    if p["user_id"] == user["id"]:
        c.close(); raise HTTPException(400, "Свой пост репостить нельзя")
    if (p["kind"] or "post") == "miniska":
        c.close(); raise HTTPException(400, "Миниски не репостятся")
    now = int(time.time())
    try:
        c.execute(
            "INSERT INTO soc_reposts (post_id, user_id, created_at) VALUES (?, ?, ?)",
            (post_id, user["id"], now),
        )
        c.commit(); c.close()
        try:
            ws_hub.send_to(p["user_id"], "post.reposted", {
                "post_id": post_id, "by_user_id": user["id"], "by_username": user["username"],
            })
        except Exception: pass
        return {"status": "ok", "existing": False, "created_at": now}
    except sqlite3.IntegrityError:
        c.close()
        return {"status": "ok", "existing": True}


@router.delete("/post/{post_id}/repost")
def unrepost_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Снять свой репост."""
    user = auth_member(authorization)
    c = db()
    c.execute(
        "DELETE FROM soc_reposts WHERE post_id=? AND user_id=?",
        (post_id, user["id"]),
    )
    c.commit(); c.close()
    return {"status": "ok"}


@router.get("/post/{post_id}/reposters")
def post_reposters(post_id: int, limit: int = Query(20)):
    """Все юзеры кто репостнул пост (публично). Лимит 20 по умолчанию."""
    c = db()
    rows = c.execute("""
        SELECT u.id, u.username, u.display_name, r.created_at
        FROM soc_reposts r JOIN users u ON r.user_id=u.id
        WHERE r.post_id=? ORDER BY r.created_at DESC LIMIT ?
    """, (post_id, max(1, min(100, limit)))).fetchall()
    total = c.execute("SELECT COUNT(*) FROM soc_reposts WHERE post_id=?", (post_id,)).fetchone()[0] or 0
    c.close()
    return {
        "total": total,
        "items": [{"user_id": r["id"], "username": r["username"],
                   "display_name": r["display_name"], "created_at": r["created_at"]} for r in rows],
    }


@router.get("/post/{post_id}/reposters/contacts")
def post_reposters_contacts(post_id: int, authorization: Optional[str] = Header(None)):
    """Только мои подписки кто репостнул этот пост — для пилюли."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT u.id, u.username, u.display_name, r.created_at
        FROM soc_reposts r JOIN users u ON r.user_id=u.id
        WHERE r.post_id=? AND r.user_id IN (
            SELECT followee_id FROM soc_follows WHERE follower_id=?
        )
        ORDER BY r.created_at DESC LIMIT 10
    """, (post_id, user["id"])).fetchall()
    c.close()
    return [{"user_id": r["id"], "username": r["username"],
             "display_name": r["display_name"], "created_at": r["created_at"]} for r in rows]


@router.get("/user/{username}/feed_combined")
def user_feed_combined(username: str, offset: int = Query(0), limit: int = Query(40), authorization: Optional[str] = Header(None)):
    """Объединённая лента юзера: свои посты + репосты в хронологии.
    Используется на вкладке «Посты» в профиле для построения мозаик репостов.
    Возвращает items с полем kind: 'self' или 'repost'."""
    uid_caller = auth(authorization)["id"]
    uname = (username or "").strip().lower().lstrip("@")
    c = db()
    u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
    if not u:
        c.close(); raise HTTPException(404, "User not found")
    target_uid = u["id"]
    rows = c.execute("""
        SELECT 'self' as kind, p.id, strftime('%s', p.created_at) as ts,
               p.content, p.media, p.is_nsfw, p.nsfw_set_by, p.user_id, p.created_at, p.edited_at, p.source_channel_id,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count,
               NULL as repost_ts
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.user_id=? AND p.kind='post'
        UNION ALL
        SELECT 'repost' as kind, p.id, CAST(r.created_at AS TEXT) as ts,
               p.content, p.media, p.is_nsfw, p.nsfw_set_by, p.user_id, p.created_at, p.edited_at, p.source_channel_id,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count,
               r.created_at as repost_ts
        FROM soc_reposts r
        JOIN soc_posts p ON r.post_id=p.id
        JOIN users u ON p.user_id=u.id
        WHERE r.user_id=?
        ORDER BY ts DESC
        LIMIT ? OFFSET ?
    """, (target_uid, target_uid, max(1, min(80, limit)), max(0, offset))).fetchall()
    posts = _hydrate_posts(c, rows, uid_caller)
    c.close()
    out = []
    for i, r in enumerate(rows):
        item = {**posts[i], "kind": r["kind"]}
        if r["kind"] == "repost":
            item["repost_ts"] = r["repost_ts"]
            item["is_repost"] = True
        out.append(item)
    return out


@router.get("/user/{username}/reposts")
def user_reposts(username: str, offset: int = Query(0), limit: int = Query(20), authorization: Optional[str] = Header(None)):
    """Все репосты юзера (для вкладки «Репосты» в профиле + полной страницы)."""
    uid_caller = auth(authorization)["id"]
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    c = db()
    u = c.execute("SELECT id FROM users WHERE username=?", (uname,)).fetchone()
    if not u:
        c.close(); raise HTTPException(404, "User not found")
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u2.username, u2.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count,
               r.created_at as reposted_at
        FROM soc_reposts r
        JOIN soc_posts p ON r.post_id=p.id
        JOIN users u2 ON p.user_id=u2.id
        WHERE r.user_id=?
        ORDER BY r.created_at DESC
        LIMIT ? OFFSET ?
    """, (u["id"], max(1, min(50, limit)), max(0, offset))).fetchall()
    out = _hydrate_posts(c, rows, uid_caller)
    for i, row in enumerate(rows):
        out[i]["reposted_at"] = row["reposted_at"]
        out[i]["is_repost"] = True
    c.close()
    return out



_REPORT_REASONS = {"spam", "nsfw_unmarked", "illegal", "harassment", "other"}
_REPORTS_THRESHOLD_1H = 5
_REPORTS_THRESHOLD_24H = 10
_VIRAL_REACTIONS_30MIN = 30


class ReportBody(BaseModel):
    reason: str


def _check_and_create_overwatch_reports(c, post_id: int):
    """Если по посту накопилось >=5 жалоб за 1ч или >=10 за 24ч и нет
    открытого system_reports-overwatch — создаёт его автоматически."""
    now = int(time.time())
    cnt_1h = c.execute(
        "SELECT COUNT(*) FROM soc_reports WHERE post_id=? AND created_at > ?",
        (post_id, now - 3600),
    ).fetchone()[0] or 0
    cnt_24h = c.execute(
        "SELECT COUNT(*) FROM soc_reports WHERE post_id=? AND created_at > ?",
        (post_id, now - 86400),
    ).fetchone()[0] or 0
    if cnt_1h < _REPORTS_THRESHOLD_1H and cnt_24h < _REPORTS_THRESHOLD_24H:
        return
    already = c.execute(
        "SELECT id FROM soc_overwatch_requests "
        "WHERE post_id=? AND kind='system_reports' AND status='open'",
        (post_id,),
    ).fetchone()
    if already:
        return
    p = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        return
    c.execute(
        "INSERT INTO soc_overwatch_requests (post_id, author_id, kind, price_gost, created_at, status) "
        "VALUES (?, ?, 'system_reports', 0, ?, 'open')",
        (post_id, p["user_id"], now),
    )
    try:
        mods = c.execute("SELECT id FROM users WHERE is_moderator=1").fetchall()
        for m in mods:
            ws_hub.send_to(m["id"], "mod.auto_overwatch", {
                "post_id": post_id, "kind": "system_reports",
                "reports_1h": cnt_1h, "reports_24h": cnt_24h,
            })
    except Exception:
        pass


def _check_and_create_overwatch_viral(c, post_id: int):
    """Если за последние 30 минут пост получил 30+ реакций и нет открытого
    system_viral за последние 24 часа — создаёт автоматический overwatch."""
    now = int(time.time())
    try:
        activity = c.execute("SELECT activity FROM soc_posts WHERE id=?", (post_id,)).fetchone()
        activity_val = int(activity["activity"]) if activity else 500
    except Exception:
        return
    if activity_val < 800:
        return
    reactions = c.execute("SELECT COUNT(*) FROM soc_reactions WHERE post_id=?", (post_id,)).fetchone()[0] or 0
    if reactions < _VIRAL_REACTIONS_30MIN:
        return
    recent = c.execute(
        "SELECT id FROM soc_overwatch_requests "
        "WHERE post_id=? AND kind='system_viral' AND created_at > ?",
        (post_id, now - 86400),
    ).fetchone()
    if recent:
        return
    p = c.execute("SELECT user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        return
    c.execute(
        "INSERT INTO soc_overwatch_requests (post_id, author_id, kind, price_gost, created_at, status) "
        "VALUES (?, ?, 'system_viral', 0, ?, 'open')",
        (post_id, p["user_id"], now),
    )
    try:
        mods = c.execute("SELECT id FROM users WHERE is_moderator=1").fetchall()
        for m in mods:
            ws_hub.send_to(m["id"], "mod.auto_overwatch", {
                "post_id": post_id, "kind": "system_viral", "reactions": reactions,
            })
    except Exception:
        pass


@router.post("/post/{post_id}/report")
def report_post(post_id: int, body: ReportBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"report:{user['id']}", limit=30, window=3600)
    reason = (body.reason or "").strip().lower()
    if reason not in _REPORT_REASONS:
        raise HTTPException(400, f"reason должен быть одним из: {', '.join(sorted(_REPORT_REASONS))}")
    c = db()
    p = c.execute("SELECT id, user_id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        c.close(); raise HTTPException(404, "Post not found")
    if p["user_id"] == user["id"]:
        c.close(); raise HTTPException(403, "Нельзя жаловаться на свой пост")
    now = int(time.time())
    try:
        c.execute(
            "INSERT INTO soc_reports (post_id, reporter_id, reason, created_at) "
            "VALUES (?, ?, ?, ?)",
            (post_id, user["id"], reason, now),
        )
    except sqlite3.IntegrityError:
        c.close(); raise HTTPException(409, "Вы уже жаловались на этот пост")
    _check_and_create_overwatch_reports(c, post_id)
    c.commit(); c.close()
    return {"status": "ok"}


@router.delete("/post/{post_id}/report")
def unreport_post(post_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    c.execute(
        "DELETE FROM soc_reports WHERE post_id=? AND reporter_id=?",
        (post_id, user["id"]),
    )
    c.commit(); c.close()
    return {"status": "ok"}


_INCOMING_REPORTS_PRICE_PREM = 10


@router.post("/me/reports/incoming")
def me_reports_incoming(authorization: Optional[str] = Header(None)):
    """Premium-фича: список юзеров кто жаловался на твои посты.
    Стоит 10 Prem за запрос. Списывается атомарно."""
    user = auth_member(authorization)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        w = c.execute("SELECT prem FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
        prem = int(w["prem"] if w else 0)
        if prem < _INCOMING_REPORTS_PRICE_PREM:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(402, f"Нужно {_INCOMING_REPORTS_PRICE_PREM} Prem, у вас {prem}")
        c.execute(
            "UPDATE soc_wallets SET prem = prem - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (_INCOMING_REPORTS_PRICE_PREM, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
            "VALUES (?, 'prem', ?, 'incoming_reports_check', 0, '', 0)",
            (user["id"], -_INCOMING_REPORTS_PRICE_PREM),
        )
        c.execute("COMMIT")
    except HTTPException: raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except: pass
        c.close(); raise HTTPException(500, f"Ошибка: {e}")
    rows = c.execute("""
        SELECT r.reporter_id, r.reason, r.created_at,
               r.post_id, u.username, u.display_name,
               (SELECT content FROM soc_posts WHERE id=r.post_id) as post_preview
        FROM soc_reports r
        JOIN users u ON r.reporter_id = u.id
        WHERE r.post_id IN (SELECT id FROM soc_posts WHERE user_id=?)
        ORDER BY r.created_at DESC
        LIMIT 100
    """, (user["id"],)).fetchall()
    c.close()
    out = []
    for r in rows:
        prev = (r["post_preview"] or "")[:60]
        out.append({
            "reporter_id": r["reporter_id"], "username": r["username"],
            "display_name": r["display_name"], "reason": r["reason"],
            "post_id": r["post_id"], "post_preview": prev,
            "created_at": r["created_at"],
        })
    return {"spent_prem": _INCOMING_REPORTS_PRICE_PREM, "reports": out}


@router.get("/post/{post_id}/reports/count")
def reports_count(post_id: int, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    me_row = db().execute("SELECT is_admin, is_moderator FROM users WHERE id=?", (user["id"],)).fetchone()
    is_mod_or_admin = bool(me_row and (me_row["is_moderator"] or me_row["is_admin"])) or _is_admin_user(user)
    if not is_mod_or_admin:
        raise HTTPException(403, "Только для модераторов")
    c = db()
    now = int(time.time())
    cnt_total = c.execute("SELECT COUNT(*) FROM soc_reports WHERE post_id=?", (post_id,)).fetchone()[0] or 0
    cnt_24h = c.execute("SELECT COUNT(*) FROM soc_reports WHERE post_id=? AND created_at > ?", (post_id, now - 86400)).fetchone()[0] or 0
    rows = c.execute(
        "SELECT reason, COUNT(*) as n FROM soc_reports WHERE post_id=? GROUP BY reason ORDER BY n DESC",
        (post_id,),
    ).fetchall()
    c.close()
    return {
        "total": cnt_total, "last_24h": cnt_24h,
        "by_reason": [{"reason": r["reason"], "count": r["n"]} for r in rows],
    }



_STATUS_TTL = 86400  # 24 часа
_ALLOWED_MOODS = {"joy", "sad", "fire", "love", "tired", "chill", "angry", "surprised"}
_ETERNAL_STATUS_PRICE_SOUL = 100


def _status_active(set_at) -> bool:
    if not set_at:
        return False
    return (int(time.time()) - int(set_at)) < _STATUS_TTL


def _resolve_status(row):
    """Возвращает {text, mood, set_at, eternal} с приоритетом eternal."""
    if not row:
        return None
    eternal_text = row["eternal_status_text"] if "eternal_status_text" in row.keys() else None
    if eternal_text:
        return {
            "text": eternal_text,
            "mood": row["eternal_status_mood"] if "eternal_status_mood" in row.keys() else None,
            "set_at": int(row["eternal_status_purchased_at"] or 0) if "eternal_status_purchased_at" in row.keys() else None,
            "eternal": True,
        }
    if _status_active(row["daily_status_set_at"] if "daily_status_set_at" in row.keys() else None):
        return {
            "text": row["daily_status_text"],
            "mood": row["daily_status_mood"] if "daily_status_mood" in row.keys() else None,
            "set_at": int(row["daily_status_set_at"]),
            "eternal": False,
        }
    return None


class StatusSetBody(BaseModel):
    text: str
    mood: Optional[str] = None


class EternalStatusBody(BaseModel):
    text: str
    mood: Optional[str] = None


@router.get("/status/my")
def status_my(authorization: Optional[str] = Header(None)):
    """Текущий статус юзера (если ещё не просрочен). Если нет — must_set=true."""
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT daily_status_text, daily_status_set_at, daily_status_mood, "
        "eternal_status_text, eternal_status_mood, eternal_status_purchased_at "
        "FROM users WHERE id=?",
        (user["id"],),
    ).fetchone()
    c.close()
    st = _resolve_status(row)
    if st:
        return {
            **st,
            "expires_at": (st["set_at"] + _STATUS_TTL) if not st["eternal"] and st["set_at"] else None,
            "must_set": False,
        }
    return {"text": None, "mood": None, "set_at": None, "expires_at": None, "must_set": True, "eternal": False}


@router.post("/status/set")
def status_set(body: StatusSetBody, authorization: Optional[str] = Header(None)):
    """Ставит дневной статус. 1..140 символов, без переносов строк."""
    user = auth_member(authorization)
    _rate_limit(f"status:{user['id']}", limit=20, window=86400)
    text = (body.text or "").strip().replace("\n", " ").replace("\r", " ")
    if not text:
        raise HTTPException(400, "Статус не может быть пустым")
    if len(text) > 140:
        raise HTTPException(400, "Статус максимум 140 символов")
    mood = (body.mood or "").strip().lower() or None
    if mood and mood not in _ALLOWED_MOODS:
        raise HTTPException(400, f"Неизвестное mood. Допустимые: {', '.join(sorted(_ALLOWED_MOODS))}")
    now = int(time.time())
    c = db()
    c.execute(
        "UPDATE users SET daily_status_text=?, daily_status_set_at=?, daily_status_mood=? WHERE id=?",
        (text, now, mood, user["id"]),
    )
    c.commit(); c.close()
    return {"status": "ok", "text": text, "mood": mood, "set_at": now, "expires_at": now + _STATUS_TTL}


@router.post("/status/eternal")
def status_eternal(body: EternalStatusBody, authorization: Optional[str] = Header(None)):
    """Eternal-статус за 100 Soul — без 24ч-TTL. Списывает Soul атомарно."""
    user = auth_member(authorization)
    text = (body.text or "").strip().replace("\n", " ").replace("\r", " ")
    if not text:
        raise HTTPException(400, "Статус не может быть пустым")
    if len(text) > 140:
        raise HTTPException(400, "Статус максимум 140 символов")
    mood = (body.mood or "").strip().lower() or None
    if mood and mood not in _ALLOWED_MOODS:
        raise HTTPException(400, f"Неизвестное mood")
    now = int(time.time())
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        w = c.execute("SELECT soul FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
        soul = int(w["soul"] if w else 0)
        if soul < _ETERNAL_STATUS_PRICE_SOUL:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(402, f"Нужно {_ETERNAL_STATUS_PRICE_SOUL} Soul, у вас {soul}")
        c.execute(
            "UPDATE soc_wallets SET soul = soul - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (_ETERNAL_STATUS_PRICE_SOUL, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
            "VALUES (?, 'soul', ?, 'eternal_status', 0, '', 0)",
            (user["id"], -_ETERNAL_STATUS_PRICE_SOUL),
        )
        c.execute(
            "UPDATE users SET eternal_status_text=?, eternal_status_mood=?, eternal_status_purchased_at=? WHERE id=?",
            (text, mood, now, user["id"]),
        )
        c.execute("COMMIT")
    except HTTPException: raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except: pass
        c.close()
        raise HTTPException(500, f"Ошибка: {e}")
    c.close()
    return {"status": "ok", "text": text, "mood": mood, "eternal": True, "spent_soul": _ETERNAL_STATUS_PRICE_SOUL}


@router.delete("/status/eternal")
def status_eternal_delete(authorization: Optional[str] = Header(None)):
    """Снять eternal-статус (Soul не возвращается). После этого юзер снова должен ставить дневной."""
    user = auth_member(authorization)
    c = db()
    c.execute(
        "UPDATE users SET eternal_status_text=NULL, eternal_status_mood=NULL, eternal_status_purchased_at=NULL WHERE id=?",
        (user["id"],),
    )
    c.commit(); c.close()
    return {"status": "ok"}


@router.get("/status/feed")
def status_feed(authorization: Optional[str] = Header(None)):
    """Лента актуальных статусов юзеров на которых я подписан + я."""
    user = auth_member(authorization)
    uid = user["id"]
    c = db()
    rows = c.execute("""
        SELECT u.id, u.username, u.display_name,
               u.daily_status_text, u.daily_status_set_at, u.daily_status_mood,
               u.eternal_status_text, u.eternal_status_mood, u.eternal_status_purchased_at
        FROM users u
        WHERE u.id = ? OR u.id IN (SELECT followee_id FROM soc_follows WHERE follower_id=?)
    """, (uid, uid)).fetchall()
    c.close()
    out = []
    for r in rows:
        st = _resolve_status(r)
        if not st:
            continue
        out.append({
            "user_id": r["id"], "username": r["username"], "display_name": r["display_name"],
            "is_me": r["id"] == uid,
            **st,
        })
    out.sort(key=lambda x: (x.get("set_at") or 0), reverse=True)
    return out


@router.get("/status/{username}")
def status_of(username: str):
    """Публичный статус юзера. Если просрочен — null."""
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Empty username")
    c = db()
    row = c.execute(
        "SELECT daily_status_text, daily_status_set_at, daily_status_mood, "
        "eternal_status_text, eternal_status_mood, eternal_status_purchased_at "
        "FROM users WHERE username=?",
        (uname,),
    ).fetchone()
    c.close()
    if not row:
        raise HTTPException(404, "User not found")
    st = _resolve_status(row)
    if st:
        return st
    return {"text": None, "mood": None, "set_at": None, "eternal": False}


@router.get("/admin/stats")
def admin_stats(authorization: Optional[str] = Header(None)):
    """Базовые метрики для админа: пользователи, активность, контент, экономика, модерация."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    c = db()
    now = int(time.time())
    d1 = now - 86400
    d7 = now - 86400 * 7
    d30 = now - 86400 * 30

    def _one(sql, params=()):
        r = c.execute(sql, params).fetchone()
        return (r[0] if r else 0) or 0

    total_users = _one("SELECT COUNT(*) FROM users")
    reg_24h = _one("SELECT COUNT(*) FROM users WHERE strftime('%s', created_at) > ?", (str(d1),))
    reg_7d = _one("SELECT COUNT(*) FROM users WHERE strftime('%s', created_at) > ?", (str(d7),))
    reg_30d = _one("SELECT COUNT(*) FROM users WHERE strftime('%s', created_at) > ?", (str(d30),))
    moderators = _one("SELECT COUNT(*) FROM users WHERE is_moderator=1")
    age_confirmed = _one("SELECT COUNT(*) FROM users WHERE confirmed_18_at IS NOT NULL")

    try:
        dau = _one("SELECT COUNT(DISTINCT user_id) FROM soc_post_views WHERE viewed_at > ?", (d1,))
        wau = _one("SELECT COUNT(DISTINCT user_id) FROM soc_post_views WHERE viewed_at > ?", (d7,))
        mau = _one("SELECT COUNT(DISTINCT user_id) FROM soc_post_views WHERE viewed_at > ?", (d30,))
    except Exception:
        dau = wau = mau = 0

    posts_total = _one("SELECT COUNT(*) FROM soc_posts WHERE kind='post'")
    posts_24h = _one("SELECT COUNT(*) FROM soc_posts WHERE kind='post' AND strftime('%s', created_at) > ?", (str(d1),))
    posts_7d = _one("SELECT COUNT(*) FROM soc_posts WHERE kind='post' AND strftime('%s', created_at) > ?", (str(d7),))
    miniska_total = _one("SELECT COUNT(*) FROM soc_posts WHERE kind='miniska'")
    miniska_24h = _one("SELECT COUNT(*) FROM soc_posts WHERE kind='miniska' AND strftime('%s', created_at) > ?", (str(d1),))
    nsfw_total = _one("SELECT COUNT(*) FROM soc_posts WHERE is_nsfw=1")
    nsfw_by_admin = _one("SELECT COUNT(*) FROM soc_posts WHERE is_nsfw=1 AND nsfw_set_by IS NOT NULL")
    comments_total = _one("SELECT COUNT(*) FROM soc_comments")
    comments_24h = _one("SELECT COUNT(*) FROM soc_comments WHERE strftime('%s', created_at) > ?", (str(d1),))
    reactions_total = _one("SELECT COUNT(*) FROM soc_reactions")

    try:
        dm_24h = _one("SELECT COUNT(*) FROM chat_dm WHERE created_at > ?", (d1,))
        groups_total = _one("SELECT COUNT(*) FROM chat_groups")
        groups_public = _one("SELECT COUNT(*) FROM chat_groups WHERE is_public=1")
        group_msg_24h = _one("SELECT COUNT(*) FROM chat_group_messages WHERE created_at > ?", (d1,))
    except Exception:
        dm_24h = groups_total = groups_public = group_msg_24h = 0

    try:
        wallet_users = _one("SELECT COUNT(*) FROM soc_wallets WHERE gost > 0 OR soul > 0 OR prem > 0")
        gost_total = _one("SELECT COALESCE(SUM(gost), 0) FROM soc_wallets")
        soul_total = _one("SELECT COALESCE(SUM(soul), 0) FROM soc_wallets")
        nft_owned = _one("SELECT COUNT(*) FROM soc_nfts")
        nft_listed = _one("SELECT COUNT(*) FROM soc_nft_listings")
    except Exception:
        wallet_users = gost_total = soul_total = nft_owned = nft_listed = 0

    try:
        mod_apps_pending = _one("SELECT COUNT(*) FROM soc_moderator_applications WHERE status='pending'")
        overwatch_open = _one("SELECT COUNT(*) FROM soc_overwatch_requests WHERE status='open'")
        rep_low = _one("SELECT COUNT(*) FROM users WHERE reputation_score < 30")
        rep_mid = _one("SELECT COUNT(*) FROM users WHERE reputation_score >= 30 AND reputation_score < 70")
        rep_good = _one("SELECT COUNT(*) FROM users WHERE reputation_score >= 70")
    except Exception:
        mod_apps_pending = overwatch_open = rep_low = rep_mid = rep_good = 0

    follows_total = _one("SELECT COUNT(*) FROM soc_follows")

    refs_total = _one("SELECT COUNT(*) FROM users WHERE referrer_id IS NOT NULL")

    c.close()
    return {
        "generated_at": now,
        "users": {
            "total": total_users,
            "new_24h": reg_24h, "new_7d": reg_7d, "new_30d": reg_30d,
            "moderators": moderators,
            "age_confirmed_18plus": age_confirmed,
            "referred": refs_total,
        },
        "activity": {"dau": dau, "wau": wau, "mau": mau},
        "content": {
            "posts_total": posts_total, "posts_24h": posts_24h, "posts_7d": posts_7d,
            "miniska_total": miniska_total, "miniska_24h": miniska_24h,
            "nsfw_total": nsfw_total, "nsfw_set_by_admin": nsfw_by_admin,
            "comments_total": comments_total, "comments_24h": comments_24h,
            "reactions_total": reactions_total,
        },
        "chat": {
            "dm_24h": dm_24h,
            "groups_total": groups_total, "groups_public": groups_public,
            "group_messages_24h": group_msg_24h,
        },
        "economy": {
            "wallet_users_non_zero": wallet_users,
            "gost_in_circulation": gost_total,
            "soul_in_circulation": soul_total,
            "nft_minted": nft_owned, "nft_listed": nft_listed,
        },
        "moderation": {
            "applications_pending": mod_apps_pending,
            "overwatch_open": overwatch_open,
            "reputation_low_under_30": rep_low,
            "reputation_mid_30_70": rep_mid,
            "reputation_good_70_plus": rep_good,
        },
        "social_graph": {"follows_total": follows_total},
    }


@router.post("/mod/apply")
def mod_apply(authorization: Optional[str] = Header(None)):
    """Подать заявку на роль модератора. Стоит 200 Gost. У одного юзера может
    быть только одна pending-заявка."""
    user = auth_member(authorization)
    _rate_limit(f"modapply:{user['id']}", limit=3, window=86400)  # 3 заявки в сутки
    c = db()
    u = c.execute("SELECT is_moderator FROM users WHERE id=?", (user["id"],)).fetchone()
    if u and u["is_moderator"]:
        c.close(); raise HTTPException(400, "Вы уже модератор")
    existing = c.execute(
        "SELECT 1 FROM soc_moderator_applications WHERE user_id=? AND status='pending'",
        (user["id"],)
    ).fetchone()
    if existing:
        c.close(); raise HTTPException(409, "У вас уже есть заявка на рассмотрении")
    bal = get_balance(user["id"])["gost"]
    if bal < MOD_APPLY_PRICE_GOST:
        c.close(); raise HTTPException(400, f"Нужно {MOD_APPLY_PRICE_GOST} Gost (у вас {bal})")
    # Atomically: spend + insert
    try:
        c.execute("BEGIN IMMEDIATE")
        # Spend gost через wallet_tx
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
            "VALUES (?, 'gost', ?, 'mod_apply', 0, 'apply', 0)",
            (user["id"], -MOD_APPLY_PRICE_GOST),
        )
        c.execute(
            "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (MOD_APPLY_PRICE_GOST, user["id"]),
        )
        # Quality score 0-100: чем активнее аккаунт, тем выше.
        # Пустой/новый акк = 0 (раньше был +50 базовый — убрал, бесполезно).
        posts_cnt = c.execute(
            "SELECT COUNT(*) as n FROM soc_posts WHERE user_id=?", (user["id"],)
        ).fetchone()["n"]
        comments_cnt = c.execute(
            "SELECT COUNT(*) as n FROM soc_comments WHERE user_id=?", (user["id"],)
        ).fetchone()["n"]
        days_reg_row = c.execute(
            "SELECT (julianday('now') - julianday(created_at)) as days FROM users WHERE id=?",
            (user["id"],)
        ).fetchone()
        days_reg = int(days_reg_row["days"] or 0)
        quality = max(0, min(100, int(posts_cnt * 0.5 + days_reg * 0.5 + comments_cnt * 0.1)))
        c.execute(
            "INSERT INTO soc_moderator_applications (user_id, created_at, quality_score) VALUES (?,?,?)",
            (user["id"], int(time.time()), quality),
        )
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except: pass
        c.close(); raise
    c.close()
    return {"status": "ok", "quality_score": quality}


@router.get("/mod/applications")
def mod_applications_list(authorization: Optional[str] = Header(None)):
    """Список заявок (для admin/owner). Сортирован: pending по quality DESC,
    потом обработанные по дате."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    c = db()
    rows = c.execute("""
        SELECT a.id, a.user_id, a.created_at, a.status, a.quality_score, a.reviewed_at,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_posts WHERE user_id=a.user_id) as posts_count,
               (SELECT COUNT(*) FROM soc_comments WHERE user_id=a.user_id) as comments_count,
               (SELECT gost FROM soc_wallets WHERE user_id=a.user_id) as gost_balance
        FROM soc_moderator_applications a
        JOIN users u ON u.id = a.user_id
        ORDER BY
          CASE a.status WHEN 'pending' THEN 0 ELSE 1 END,
          a.quality_score DESC,
          a.created_at DESC
        LIMIT 200
    """).fetchall()
    c.close()
    return [dict(r) for r in rows]


@router.post("/mod/applications/{app_id}/decide")
def mod_application_decide(app_id: int, body: dict, authorization: Optional[str] = Header(None)):
    """Принять или отклонить заявку. accept=True → дать роль модератора."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    accept = bool(body.get("accept"))
    c = db()
    app_row = c.execute(
        "SELECT id, user_id, status FROM soc_moderator_applications WHERE id=?", (app_id,)
    ).fetchone()
    if not app_row:
        c.close(); raise HTTPException(404, "Заявка не найдена")
    if app_row["status"] != "pending":
        c.close(); raise HTTPException(400, "Заявка уже обработана")
    now = int(time.time())
    new_status = "accepted" if accept else "rejected"
    c.execute(
        "UPDATE soc_moderator_applications SET status=?, reviewed_by=?, reviewed_at=? WHERE id=?",
        (new_status, user["id"], now, app_id),
    )
    if accept:
        c.execute(
            "UPDATE users SET is_moderator=1, moderator_since=?, moderator_rating=100, moderator_reprimands=0 WHERE id=?",
            (now, app_row["user_id"]),
        )
    c.commit()
    c.close()
    try:
        ws_hub.send_to(app_row["user_id"], "mod.application_decided",
                       {"accepted": accept, "application_id": app_id})
    except Exception: pass
    return {"status": "ok", "accepted": accept}


@router.post("/post/{post_id}/overwatch")
def post_overwatch_buy(post_id: int, authorization: Optional[str] = Header(None)):
    """Купить ремодерацию своего поста за 300 Gost. Создаётся overwatch_request,
    модераторы смогут голосовать."""
    user = auth_member(authorization)
    _rate_limit(f"ow:{user['id']}", limit=5, window=86400)
    c = db()
    p = c.execute("SELECT user_id, activity FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        c.close(); raise HTTPException(404, "Пост не найден")
    is_admin = _is_admin_user(user)
    if p["user_id"] != user["id"] and not is_admin:
        c.close(); raise HTTPException(403, "Можно купить только для своего поста")
    open_req = c.execute(
        "SELECT id FROM soc_overwatch_requests WHERE post_id=? AND status='open'", (post_id,)
    ).fetchone()
    if open_req:
        c.close(); raise HTTPException(409, "Для этого поста уже идёт overwatch")
    bal = get_balance(user["id"])["gost"]
    if bal < OVERWATCH_BASE_PRICE_GOST:
        c.close(); raise HTTPException(400, f"Нужно {OVERWATCH_BASE_PRICE_GOST} Gost (у вас {bal})")
    try:
        c.execute("BEGIN IMMEDIATE")
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
            "VALUES (?, 'gost', ?, 'overwatch', 0, 'post', ?)",
            (user["id"], -OVERWATCH_BASE_PRICE_GOST, post_id),
        )
        c.execute(
            "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (OVERWATCH_BASE_PRICE_GOST, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_overwatch_requests (post_id, author_id, kind, price_gost, created_at) "
            "VALUES (?,?,?,?,?)",
            (post_id, user["id"], "manual", OVERWATCH_BASE_PRICE_GOST, int(time.time())),
        )
        req_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except: pass
        c.close(); raise
    mods = c.execute("SELECT id FROM users WHERE is_moderator=1").fetchall()
    for m in mods:
        try: ws_hub.send_to(m["id"], "overwatch.new", {"request_id": req_id, "post_id": post_id})
        except: pass
    c.close()
    return {"status": "ok", "request_id": req_id, "price": OVERWATCH_BASE_PRICE_GOST}


@router.get("/mod/overwatch_queue")
def mod_overwatch_queue(authorization: Optional[str] = Header(None)):
    """Список открытых overwatch — для модераторов. Видят ТОЛЬКО контент,
    без автора/реакций/комментов (защита анонимности)."""
    user = auth_member(authorization)
    c = db()
    u = c.execute("SELECT is_moderator, is_admin FROM users WHERE id=?", (user["id"],)).fetchone()
    is_admin = _is_admin_user({**user, "is_admin": (u["is_admin"] if u else 0)})
    is_mod = bool(u and u["is_moderator"])
    if not (is_mod or is_admin):
        c.close(); raise HTTPException(403, "Только для модераторов")
    rows = c.execute("""
        SELECT r.id as request_id, r.post_id, r.created_at, r.kind,
               p.content, p.activity, p.media,
               (SELECT delta FROM soc_overwatch_votes WHERE request_id=r.id AND moderator_id=?) as my_vote
        FROM soc_overwatch_requests r
        JOIN soc_posts p ON p.id = r.post_id
        WHERE r.status='open'
        ORDER BY r.created_at ASC
        LIMIT 50
    """, (user["id"],)).fetchall()
    c.close()
    # Feature 1: для каждого overwatch — разбивка жалоб по причинам
    out = []
    for r in rows:
        pid = r["post_id"]
        try:
            rep_rows = db().execute(
                "SELECT reason, COUNT(*) as n FROM soc_reports WHERE post_id=? GROUP BY reason ORDER BY n DESC",
                (pid,),
            ).fetchall()
            reports_breakdown = {
                "total": sum(x["n"] for x in rep_rows),
                "by_reason": [{"reason": x["reason"], "count": x["n"]} for x in rep_rows],
            }
        except Exception:
            reports_breakdown = {"total": 0, "by_reason": []}
        out.append({
            "request_id": r["request_id"],
            "post_id": r["post_id"],
            "content": r["content"],
            "current_activity": r["activity"],
            "media": json.loads(r["media"]) if r["media"] else None,
            "kind": r["kind"],
            "created_at": r["created_at"],
            "my_vote": r["my_vote"],
            "reports_breakdown": reports_breakdown,
        })
    return out


class OverwatchVoteBody(BaseModel):
    delta: int   # -150, -50, 0, +50, +150
    comment: Optional[str] = None


@router.post("/mod/overwatch/{request_id}/vote")
def mod_overwatch_vote(request_id: int, body: OverwatchVoteBody, authorization: Optional[str] = Header(None)):
    """Модератор голосует сдвигом activity. Когда наберётся ≥3 голосов —
    автоматически применяется среднее (capped ±150) и overwatch закрывается."""
    user = auth_member(authorization)
    c = db()
    u = c.execute("SELECT is_moderator, moderator_rating FROM users WHERE id=?", (user["id"],)).fetchone()
    if not u or not u["is_moderator"]:
        c.close(); raise HTTPException(403, "Только для модераторов")
    if body.delta not in (-150, -50, 0, 50, 150):
        c.close(); raise HTTPException(400, "delta: -150 / -50 / 0 / 50 / 150")
    req = c.execute(
        "SELECT id, post_id, author_id, price_gost, status FROM soc_overwatch_requests WHERE id=?",
        (request_id,)
    ).fetchone()
    if not req:
        c.close(); raise HTTPException(404, "Запрос не найден")
    if req["status"] != "open":
        c.close(); raise HTTPException(400, "Запрос уже закрыт")
    if req["author_id"] == user["id"]:
        c.close(); raise HTTPException(403, "Нельзя голосовать на своём посте")
    now = int(time.time())
    try:
        c.execute(
            "INSERT INTO soc_overwatch_votes (request_id, moderator_id, delta, comment, created_at) "
            "VALUES (?,?,?,?,?)",
            (request_id, user["id"], body.delta, (body.comment or "")[:200], now),
        )
    except sqlite3.IntegrityError:
        c.close(); raise HTTPException(409, "Вы уже проголосовали")
    votes = c.execute(
        "SELECT delta FROM soc_overwatch_votes WHERE request_id=?", (request_id,)
    ).fetchall()
    vote_count = len(votes)
    avg_delta = sum(v["delta"] for v in votes) / vote_count
    delta_applied = max(-OVERWATCH_MAX_STEP, min(OVERWATCH_MAX_STEP, int(round(avg_delta))))
    c.execute(
        "UPDATE soc_overwatch_requests SET votes_count=? WHERE id=?",
        (vote_count, request_id),
    )
    closed = False
    if vote_count >= 3:
        p = c.execute("SELECT activity FROM soc_posts WHERE id=?", (req["post_id"],)).fetchone()
        old_act = p["activity"] if p else 500
        new_act = max(0, min(1000, old_act + delta_applied))
        c.execute(
            "UPDATE soc_posts SET activity=?, activity_set_at=? WHERE id=?",
            (new_act, now, req["post_id"]),
        )
        c.execute(
            "INSERT INTO soc_activity_log (post_id, old_activity, new_activity, delta, source, actor_id, note, created_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (req["post_id"], old_act, new_act, delta_applied, "overwatch", None,
             f"avg={avg_delta:.1f}, votes={vote_count}", now),
        )
        for v_mod in c.execute(
            "SELECT v.moderator_id, u.moderator_rating FROM soc_overwatch_votes v "
            "JOIN users u ON u.id = v.moderator_id WHERE v.request_id=?",
            (request_id,)
        ).fetchall():
            mult = max(0.5, min(1.5, v_mod["moderator_rating"] / 100))
            reward = int(OVERWATCH_PER_MOD_BASE * mult)
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, 'overwatch_reward', 0, 'overwatch', ?)",
                (v_mod["moderator_id"], reward, request_id),
            )
            c.execute(
                "INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (v_mod["moderator_id"],)
            )
            c.execute(
                "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
                (reward, v_mod["moderator_id"]),
            )
        c.execute(
            "UPDATE soc_overwatch_requests SET status='resolved', resolved_at=?, delta_applied=? WHERE id=?",
            (now, delta_applied, request_id),
        )
        closed = True
        rewarded_reporters = []
        if delta_applied < 0:
            REPORT_CONFIRMED_REWARD = 5
            reporter_rows = c.execute(
                "SELECT DISTINCT reporter_id FROM soc_reports WHERE post_id=? "
                "AND created_at > ?",
                (req["post_id"], now - 86400 * 7),  # репорты за последнюю неделю
            ).fetchall()
            for rr in reporter_rows:
                rid = rr["reporter_id"]
                try:
                    c.execute(
                        "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                        "VALUES (?, 'gost', ?, 'report_confirmed', 0, 'post', ?)",
                        (rid, REPORT_CONFIRMED_REWARD, req["post_id"]),
                    )
                    c.execute(
                        "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
                        (REPORT_CONFIRMED_REWARD, rid),
                    )
                    rewarded_reporters.append(rid)
                except Exception: pass
        try:
            ws_hub.send_to(req["author_id"], "overwatch.resolved", {
                "request_id": request_id, "post_id": req["post_id"],
                "old_activity": old_act, "new_activity": new_act,
                "delta": delta_applied, "votes": vote_count,
            })
        except Exception: pass
        for rid in rewarded_reporters:
            try:
                ws_hub.send_to(rid, "report.rewarded", {
                    "post_id": req["post_id"], "gost": 5,
                    "message": "Спасибо, жалоба подтверждена модераторами",
                })
            except Exception: pass
    c.commit()
    c.close()
    return {
        "status": "ok",
        "votes_count": vote_count,
        "closed": closed,
        "delta_so_far": delta_applied if closed else None,
    }


@router.post("/mod/promote/{username}")
def mod_promote(username: str, authorization: Optional[str] = Header(None)):
    """Admin напрямую назначает юзера модератором (без заявки)."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    uname = username.strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Пустой username")
    c = db()
    target = c.execute("SELECT id, username, is_moderator FROM users WHERE username=?", (uname,)).fetchone()
    if not target:
        c.close(); raise HTTPException(404, "Юзер не найден")
    if target["is_moderator"]:
        c.close(); raise HTTPException(409, "Уже модератор")
    now = int(time.time())
    c.execute(
        "UPDATE users SET is_moderator=1, moderator_since=?, moderator_rating=100, moderator_reprimands=0 WHERE id=?",
        (now, target["id"]),
    )
    c.commit(); c.close()
    try: ws_hub.send_to(target["id"], "mod.promoted", {"by": user["username"]})
    except Exception: pass
    return {"status": "ok", "user_id": target["id"], "username": target["username"]}


class SetNsfwBody(BaseModel):
    value: bool  # true → пометить 18+, false → снять пометку


@router.post("/mod/post/{post_id}/nsfw")
def mod_set_nsfw(post_id: int, body: SetNsfwBody, authorization: Optional[str] = Header(None)):
    """Модератор/админ ставит NSFW-блюр на пост (если автор сам не пометил).
    Снижает репутацию автора на 10 при пометке; восстанавливает +10 при снятии.
    Идемпотентно: повторный вызов с тем же value возвращает unchanged=true.
    """
    user = auth_member(authorization)
    c = db()
    me_row = c.execute("SELECT is_admin, is_moderator FROM users WHERE id=?", (user["id"],)).fetchone()
    is_mod = bool(me_row and me_row["is_moderator"])
    is_admin = _is_admin_user({**user, "is_admin": (me_row["is_admin"] if me_row else 0)})
    if not (is_admin or is_mod):
        c.close(); raise HTTPException(403, "Только для модераторов")
    p = c.execute("SELECT id, user_id, is_nsfw, nsfw_set_by FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        c.close(); raise HTTPException(404, "Пост не найден")
    new_val = 1 if body.value else 0
    if int(p["is_nsfw"] or 0) == new_val:
        c.close()
        return {"status": "ok", "unchanged": True, "is_nsfw": bool(new_val)}

    author_id = p["user_id"]
    now = int(time.time())
    delta = 0
    reason = "nsfw_admin_clear"
    if new_val == 1:
        delta = -10
        reason = "nsfw_admin_set"
        c.execute(
            "UPDATE soc_posts SET is_nsfw=1, nsfw_set_by=? WHERE id=?",
            (user["id"], post_id),
        )
    else:
        if p["nsfw_set_by"]:
            delta = 10
        c.execute(
            "UPDATE soc_posts SET is_nsfw=0, nsfw_set_by=NULL WHERE id=?",
            (post_id,),
        )
    new_score = None
    if delta != 0:
        au = c.execute("SELECT reputation_score FROM users WHERE id=?", (author_id,)).fetchone()
        old_score = int(au["reputation_score"] if au and au["reputation_score"] is not None else 100)
        new_score = max(0, min(100, old_score + delta))
        if new_score != old_score:
            c.execute(
                "UPDATE users SET reputation_score=?, reputation_updated_at=? WHERE id=?",
                (new_score, now, author_id),
            )
            c.execute(
                "INSERT INTO soc_reputation_log (user_id, delta, old_score, new_score, reason, actor_id, post_id, created_at) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (author_id, delta, old_score, new_score, reason, user["id"], post_id, now),
            )
    c.commit(); c.close()
    try:
        ws_hub.send_to(
            author_id,
            "post.nsfw_changed",
            {"post_id": post_id, "is_nsfw": bool(new_val), "by_admin": True, "reputation": new_score},
        )
    except Exception:
        pass
    return {
        "status": "ok",
        "post_id": post_id,
        "is_nsfw": bool(new_val),
        "by_admin": True,
        "author_reputation": new_score,
    }


@router.post("/mod/demote/{username}")
def mod_demote(username: str, authorization: Optional[str] = Header(None)):
    """Admin снимает роль модератора."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    uname = username.strip().lower().lstrip("@")
    if not uname:
        raise HTTPException(400, "Пустой username")
    c = db()
    target = c.execute("SELECT id, username, is_moderator FROM users WHERE username=?", (uname,)).fetchone()
    if not target:
        c.close(); raise HTTPException(404, "Юзер не найден")
    if not target["is_moderator"]:
        c.close(); raise HTTPException(409, "Не модератор")
    c.execute("UPDATE users SET is_moderator=0 WHERE id=?", (target["id"],))
    c.commit(); c.close()
    try: ws_hub.send_to(target["id"], "mod.demoted", {"by": user["username"]})
    except Exception: pass
    return {"status": "ok", "user_id": target["id"], "username": target["username"]}


@router.get("/mod/list")
def mod_list(authorization: Optional[str] = Header(None)):
    """Список всех модераторов (для admin)."""
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    c = db()
    rows = c.execute("""
        SELECT id, username, display_name, moderator_rating, moderator_reprimands, moderator_since
        FROM users WHERE is_moderator=1
        ORDER BY moderator_since DESC NULLS LAST
    """).fetchall()
    c.close()
    return [dict(r) for r in rows]


@router.get("/mod/me")
def mod_me(authorization: Optional[str] = Header(None)):
    """Инфа о моей роли модератора + статистика."""
    user = auth_member(authorization)
    c = db()
    u = c.execute(
        "SELECT is_moderator, is_admin, moderator_rating, moderator_reprimands, moderator_since "
        "FROM users WHERE id=?",
        (user["id"],)
    ).fetchone()
    votes_cnt = 0
    if u and u["is_moderator"]:
        votes_cnt = c.execute(
            "SELECT COUNT(*) as n FROM soc_overwatch_votes WHERE moderator_id=?",
            (user["id"],)
        ).fetchone()["n"]
    c.close()
    return {
        "is_moderator": bool(u and u["is_moderator"]),
        "is_admin": _is_admin_user({**user, "is_admin": u["is_admin"] if u else 0}),
        "rating": u["moderator_rating"] if u else None,
        "reprimands": u["moderator_reprimands"] if u else None,
        "since": u["moderator_since"] if u else None,
        "votes_count": votes_cnt,
    }


# ── Polls / Quizzes ───────────────────────────────────────────────────────────

@router.post("/post/{post_id}/vote")
def vote(post_id: int, body: VoteBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"vote:{user['id']}", limit=60, window=3600)
    c = db()
    poll = c.execute("SELECT * FROM soc_polls WHERE post_id=?", (post_id,)).fetchone()
    if not poll:
        c.close()
        raise HTTPException(404, "Опрос не найден")
    try: opts = json.loads(poll["options"])
    except: opts = []
    if body.option_idx < 0 or body.option_idx >= len(opts):
        c.close()
        raise HTTPException(400, "Невалидный вариант")
    c.execute(
        "INSERT OR REPLACE INTO soc_poll_votes (post_id, user_id, option_idx) VALUES (?,?,?)",
        (post_id, user["id"], body.option_idx)
    )
    c.commit()
    state = _poll_state(c, post_id, user["id"])
    c.close()
    ws_hub.broadcast("post.vote", {"post_id": post_id, "poll": {
        "counts": state["counts"], "total": state["total"],
    }})
    return state

def _poll_state(c, post_id: int, uid: int) -> dict:
    """Полное состояние опроса для поста: вопрос, варианты, голоса, мой выбор."""
    poll = c.execute("SELECT * FROM soc_polls WHERE post_id=?", (post_id,)).fetchone()
    if not poll:
        return None
    try: opts = json.loads(poll["options"])
    except: opts = []
    rows = c.execute(
        "SELECT option_idx, COUNT(*) as cnt FROM soc_poll_votes WHERE post_id=? GROUP BY option_idx",
        (post_id,)
    ).fetchall()
    counts = {r["option_idx"]: r["cnt"] for r in rows}
    total = sum(counts.values())
    my_vote = None
    if uid > 0:
        mv = c.execute(
            "SELECT option_idx FROM soc_poll_votes WHERE post_id=? AND user_id=?",
            (post_id, uid)
        ).fetchone()
        if mv:
            my_vote = mv["option_idx"]
    return {
        "question": poll["question"],
        "options": opts,
        "counts": counts,
        "total": total,
        "my_vote": my_vote,
        "is_quiz": bool(poll["is_quiz"]),
        "correct_idx": poll["correct_idx"] if (poll["is_quiz"] and my_vote is not None) else None,
    }

# ── Миниски (короткие вертикальные видео) ───────────────────────────────────

class MiniskaBody(BaseModel):
    caption: str = ""
    video_url: str

MINISKA_MAX_DURATION = 30
MINISKA_MAX_TEXT = 200

@router.post("/miniska/new")
def create_miniska(body: MiniskaBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"miniska:{user['id']}", limit=10, window=3600)
    if not _MEDIA_URL_RE.match(body.video_url or ""):
        raise HTTPException(400, "Некорректный URL видео")
    caption = (body.caption or "").strip()
    if len(caption) > MINISKA_MAX_TEXT:
        raise HTTPException(400, f"Текст до {MINISKA_MAX_TEXT} символов")
    fname = body.video_url.split("/")[-1]
    fpath = os.path.join(MEDIA_DIR, fname)
    if not os.path.exists(fpath):
        raise HTTPException(404, "Видео не найдено")
    try:
        import subprocess
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", fpath],
            capture_output=True, text=True, timeout=10
        )
        dur = float((out.stdout or "0").strip() or 0)
        if dur > MINISKA_MAX_DURATION + 1:
            try: os.remove(fpath)
            except: pass
            raise HTTPException(400, f"Слишком длинно. Максимум {MINISKA_MAX_DURATION} сек")
    except HTTPException:
        raise
    except Exception:
        pass
    media = [{"url": body.video_url, "type": "video", "name": fname}]
    media_json = json.dumps(media, ensure_ascii=False)
    c = db()
    c.execute(
        "INSERT INTO soc_posts (user_id, content, media, kind) VALUES (?,?,?,'miniska')",
        (user["id"], caption or " ", media_json),
    )
    post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.commit()
    c.close()
    return {"status": "ok", "id": post_id}

@router.get("/miniska/feed")
def miniska_feed(
    offset: int = Query(0),
    limit: int = Query(20),
    exclude: str = Query(""),
    authorization: Optional[str] = Header(None),
):
    user = auth(authorization)
    uid = user["id"]
    limit = max(1, min(50, limit))
    excluded: list = []
    if exclude:
        try: excluded = [int(x) for x in exclude.split(",") if x.strip().isdigit()][:500]
        except: pass
    excl_sql = ""
    excl_params: list = []
    if excluded:
        excl_sql = f"AND p.id NOT IN ({','.join('?' * len(excluded))})"
        excl_params = excluded
    seed = (uid * 9973 + offset * 17 + 1) % 1000003 if uid else 12345
    c = db()
    rows = c.execute(f"""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media, p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u.username, u.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_posts p JOIN users u ON p.user_id=u.id
        WHERE p.kind='miniska' {excl_sql}
        ORDER BY (p.id * {seed}) % 1000003
        LIMIT ? OFFSET ?
    """, excl_params + [limit, offset]).fetchall()
    result = _hydrate_posts(c, rows, uid)
    c.close()
    return result


@router.get("/health")
def health():
    return {"status": "ok", "service": "GhostSocial", "version": VERSION}

@router.get("/version")
def get_version():
    return {"version": VERSION}

# ══════════════════════════════════════════════════════════════════════════════
# ЭКОНОМИКА: КОШЕЛЁК (gost / soul / prem)
# ══════════════════════════════════════════════════════════════════════════════
# Дизайн см. memory/project_economy.md
#   gost — бесплатная, активность, non-transferable, тратится только на первичные NFT
#   soul — transferable, cap-эмиссия, эмитируется через выкуп NFT (TODO)
#   prem — украшения, не пересекается с другими (TODO)

# Тарифы и лимиты — все в одном месте, чтобы балансировать без хождения по коду
GOST_REWARDS = {
    'register':  100,   # one-time welcome bonus
    'daily':      10,   # раз в 24ч
    'post':        5,   # за свой пост
    'react':       1,   # автор поста — за чужой лайк
    'comment':     2,   # автор поста — за чужой коммент
    'follow':      5,   # юзер — за нового подписчика
    'refout':     10,   # пригласителю — за приведённого юзера
    'refin':      30,   # приглашённому — welcome bonus сверх register
}
GOST_DAILY_CAP = {
    'post':     25,    # ≈ 5 постов в день максимум засчитано
    'react':    50,    # ≈ 50 лайков на свои посты
    'comment':  60,    # ≈ 30 комментов
    'follow':   25,    # ≈ 5 новых фолловеров
    'refout':   100,   # ≈ 10 рефералов в день засчитано (anti-spam)
}
DAILY_CLAIM_INTERVAL = 24 * 3600   # секунд между daily-claim
ALLOWED_CURRENCIES = {'gost', 'soul', 'prem'}


def _ensure_wallet(c, user_id: int) -> None:
    """Гарантирует наличие строки wallet (для join'ов и обновлений)."""
    c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user_id,))


def get_balance(user_id: int) -> dict:
    """Возвращает баланс юзера. Все три валюты — всегда возвращаем (нули если нет записи)."""
    c = db()
    row = c.execute(
        "SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (user_id,)
    ).fetchone()
    c.close()
    return {
        "gost": (row["gost"] if row else 0),
        "soul": (row["soul"] if row else 0),
        "prem": (row["prem"] if row else 0),
    }


def _sum_source_24h(c, user_id: int, source: str) -> int:
    """Сколько начислено за последние 24ч по этому источнику (для cap-чека)."""
    row = c.execute(
        "SELECT COALESCE(SUM(delta), 0) as s FROM soc_wallet_tx "
        "WHERE user_id=? AND source=? AND delta>0 "
        "AND created_at > datetime('now', '-1 day')",
        (user_id, source),
    ).fetchone()
    return row["s"] or 0


def _restore_reputation_if_due(user_id: int) -> Optional[int]:
    """Реактивное восстановление репутации: +1 если прошло >=7 дней с последнего изменения.
    Срабатывает при любом активном действии юзера (создание поста, коммента и т.п.).
    Если score уже 100 — ничего не делает. Возвращает new_score или None."""
    c = db()
    try:
        row = c.execute(
            "SELECT reputation_score, reputation_updated_at FROM users WHERE id=?", (user_id,)
        ).fetchone()
        if not row:
            c.close(); return None
        score = int(row["reputation_score"] if row["reputation_score"] is not None else 100)
        if score >= 100:
            c.close(); return None
        last = int(row["reputation_updated_at"] or 0)
        now = int(time.time())
        if last <= 0:
            c.execute("UPDATE users SET reputation_updated_at=? WHERE id=?", (now, user_id))
            c.commit(); c.close(); return score
        weeks = max(0, (now - last) // (7 * 86400))
        if weeks <= 0:
            c.close(); return score
        bonus = min(weeks, 100 - score)
        new_score = score + bonus
        c.execute(
            "UPDATE users SET reputation_score=?, reputation_updated_at=? WHERE id=?",
            (new_score, now, user_id),
        )
        c.execute(
            "INSERT INTO soc_reputation_log (user_id, delta, old_score, new_score, reason, actor_id, post_id, created_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (user_id, bonus, score, new_score, 'restore_weekly', None, None, now),
        )
        c.commit(); c.close()
        return new_score
    except Exception:
        try: c.close()
        except Exception: pass
        return None


def award_gost(
    user_id: int,
    source: str,
    actor_id: int = 0,
    ref_type: str = '',
    ref_id: int = 0,
    amount_override: Optional[int] = None,
) -> dict:
    """Начисляет gost за активность. Атомарно. Возвращает {credited, new_balance, reason}.

    Дедуп: для source ∈ {register, post, react, comment, follow} —
    UNIQUE индекс на (user_id, source, actor_id, ref_type, ref_id) не даст начислить дважды.
    daily — отдельный check по времени.
    Cap per-day по источнику — мягкий cap (выше cap'а просто не начисляется, без ошибки).
    """
    if user_id <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "guest"}
    if source not in GOST_REWARDS and amount_override is None:
        return {"credited": 0, "new_balance": 0, "reason": "unknown_source"}
    amount = amount_override if amount_override is not None else GOST_REWARDS[source]
    if amount <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "zero"}

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        _ensure_wallet(c, user_id)

        if source == 'daily':
            last = c.execute(
                "SELECT created_at FROM soc_wallet_tx "
                "WHERE user_id=? AND source='daily' "
                "ORDER BY id DESC LIMIT 1",
                (user_id,),
            ).fetchone()
            if last:
                age = c.execute(
                    "SELECT strftime('%s','now') - strftime('%s', ?) as age",
                    (last["created_at"],),
                ).fetchone()["age"]
                if (age or 0) < DAILY_CLAIM_INTERVAL:
                    c.execute("ROLLBACK")
                    c.close()
                    return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "too_soon"}

        if source in GOST_DAILY_CAP:
            already = _sum_source_24h(c, user_id, source)
            if already >= GOST_DAILY_CAP[source]:
                c.execute("ROLLBACK")
                c.close()
                return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "daily_cap"}
            if already + amount > GOST_DAILY_CAP[source]:
                amount = GOST_DAILY_CAP[source] - already

        # Запись tx (UNIQUE index блокирует дубль — IntegrityError)
        try:
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, ?, ?, ?, ?)",
                (user_id, amount, source, actor_id, ref_type, ref_id),
            )
        except sqlite3.IntegrityError:
            c.execute("ROLLBACK")
            c.close()
            return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "already_credited"}

        c.execute(
            "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (amount, user_id),
        )
        new_bal = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user_id,)).fetchone()["gost"]
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise
    c.close()
    ws_hub.send_to(user_id, "wallet.credit", {
        "currency": "gost", "delta": amount, "source": source,
        "balance": new_bal,
    })
    return {"credited": amount, "new_balance": new_bal, "reason": "ok"}


# ── Referral API ──────────────────────────────────────────────────────────────

@router.get("/ref/me")
def my_referrals(authorization: Optional[str] = Header(None)):
    """Моя реф-статистика: ссылка + сколько привёл + сколько заработал."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT id, username, display_name, created_at
        FROM users WHERE referrer_id=?
        ORDER BY id DESC LIMIT 50
    """, (user["id"],)).fetchall()
    invited = [
        {"id": r["id"], "username": r["username"], "display_name": r["display_name"], "created_at": r["created_at"]}
        for r in rows
    ]
    total = c.execute(
        "SELECT COUNT(*) as cnt FROM users WHERE referrer_id=?", (user["id"],)
    ).fetchone()["cnt"]
    earned = c.execute(
        "SELECT COALESCE(SUM(delta), 0) as s FROM soc_wallet_tx WHERE user_id=? AND currency='gost' AND source='refout'",
        (user["id"],)
    ).fetchone()["s"]
    invited_by = None
    me_row = c.execute("SELECT referrer_id FROM users WHERE id=?", (user["id"],)).fetchone()
    if me_row and me_row["referrer_id"]:
        r2 = c.execute("SELECT username, display_name FROM users WHERE id=?", (me_row["referrer_id"],)).fetchone()
        if r2:
            invited_by = {"username": r2["username"], "display_name": r2["display_name"]}
    c.close()
    return {
        "username": user["username"],
        "ref_link": f"/?ref={user['username']}",
        "total_invited": total,
        "total_earned_gost": earned,
        "reward_per_invite": GOST_REWARDS['refout'],
        "welcome_bonus": GOST_REWARDS['refin'],
        "invited": invited,
        "invited_by": invited_by,
    }


# ── SSO: Bearer gs_token → JWT (для микросервисов вроде GhostNation) ──────────

@router.post("/sso/jwt")
def sso_issue_jwt(authorization: Optional[str] = Header(None)):
    """Принимает обычный gs_token, возвращает JWT (HS256, GC_JWT_SECRET).
    Используется микросервисами на отдельных портах (GhostNation /api/nation/
    и т.п.) — там JWT-валидация быстрее чем походы в БД за токеном.

    sub  = username
    iat  = время выпуска
    exp  = +24ч
    """
    user = auth_member(authorization)
    try:
        import jwt as _jwt
    except ImportError:
        raise HTTPException(500, "PyJWT не установлен")
    secret = os.getenv("GC_JWT_SECRET", "").strip()
    if not secret:
        raise HTTPException(500, "GC_JWT_SECRET не задан в окружении")
    now = int(time.time())
    payload = {
        "sub": user["username"],
        "uid": user["id"],
        "display_name": user.get("display_name") or user["username"],
        "iat": now,
        "exp": now + 86400,
    }
    token_jwt = _jwt.encode(payload, secret, algorithm="HS256")
    if isinstance(token_jwt, bytes):
        token_jwt = token_jwt.decode("utf-8")
    return {
        "jwt": token_jwt,
        "username": user["username"],
        "display_name": user.get("display_name") or user["username"],
        "expires_at": now + 86400,
    }


@router.get("/ref/check/{username}")
def ref_check(username: str):
    """Публичный: проверить существует ли реферер. Используется на лендинге
    чтобы показать "вас пригласил @user" до регистрации."""
    uname = username.strip().lower().lstrip("@")
    if not uname:
        return {"exists": False}
    c = db()
    r = c.execute("SELECT username, display_name FROM users WHERE username=?", (uname,)).fetchone()
    c.close()
    if not r:
        return {"exists": False}
    return {"exists": True, "username": r["username"], "display_name": r["display_name"]}


# ── Wallet API ────────────────────────────────────────────────────────────────

@router.get("/wallet")
def my_wallet(authorization: Optional[str] = Header(None)):
    """Текущий баланс залогиненного юзера."""
    user = auth_member(authorization)
    bal = get_balance(user["id"])
    c = db()
    last = c.execute(
        "SELECT created_at FROM soc_wallet_tx WHERE user_id=? AND source='daily' "
        "ORDER BY id DESC LIMIT 1",
        (user["id"],),
    ).fetchone()
    next_daily_in = 0
    if last:
        age = c.execute(
            "SELECT strftime('%s','now') - strftime('%s', ?) as age", (last["created_at"],)
        ).fetchone()["age"] or 0
        next_daily_in = max(0, DAILY_CLAIM_INTERVAL - age)
    c.close()
    return {
        "balance": bal,
        "daily_reward": GOST_REWARDS['daily'],
        "next_daily_in": next_daily_in,  # секунд до следующего claim (0 = можно сейчас)
    }


@router.get("/wallet/tx")
def my_wallet_tx(offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """История транзакций (последние 30, пагинация)."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(
        "SELECT id, currency, delta, source, actor_id, ref_type, ref_id, created_at "
        "FROM soc_wallet_tx WHERE user_id=? "
        "ORDER BY id DESC LIMIT 30 OFFSET ?",
        (user["id"], offset),
    ).fetchall()
    actor_ids = list({r["actor_id"] for r in rows if r["actor_id"]})
    actor_map = {}
    if actor_ids:
        ph = ",".join("?" * len(actor_ids))
        for u in c.execute(f"SELECT id, username, display_name FROM users WHERE id IN ({ph})", actor_ids):
            actor_map[u["id"]] = {"username": u["username"], "display_name": u["display_name"]}
    c.close()
    return {
        "transactions": [
            {
                "id": r["id"],
                "currency": r["currency"],
                "delta": r["delta"],
                "source": r["source"],
                "ref_type": r["ref_type"],
                "ref_id": r["ref_id"],
                "actor": actor_map.get(r["actor_id"]),
                "created_at": r["created_at"],
            }
            for r in rows
        ],
        "has_more": len(rows) == 30,
    }


@router.post("/wallet/claim_daily")
def claim_daily(authorization: Optional[str] = Header(None)):
    """Ежедневный бонус gost. Раз в 24ч."""
    user = auth_member(authorization)
    _rate_limit(f"daily:{user['id']}", limit=5, window=60)  # анти-спам кнопки
    res = award_gost(user["id"], 'daily')
    if res["reason"] == "too_soon":
        raise HTTPException(429, "Ежедневный бонус уже получен. Приходи завтра.")
    return res


# ══════════════════════════════════════════════════════════════════════════════
# SOUL — основная валюта (transferable, cap-эмиссия, динамический курс)
# ══════════════════════════════════════════════════════════════════════════════

SOUL_MIN_RATE = 100              # 1 Soul = 100 Gost минимум
SOUL_TRANSFER_FEE_BPS = 300      # 3% (в базисных пунктах: 10000bps = 100%)
NFT_MARKET_FEE_BPS = 1000        # 10% при покупке с маркета
NFT_TRANSFER_FEE_SOUL = 1        # 1 Soul за передачу NFT

def _economy_state(c) -> Optional[dict]:
    row = c.execute("SELECT * FROM soc_economy_state WHERE is_active=1 LIMIT 1").fetchone()
    return dict(row) if row else None

def compute_soul_rate(system_balance: int, cap: int) -> int:
    """Курс: сколько Gost за 1 Soul. Формула 100 × cap / system_balance.
    При system_balance=0 курс «приостановлен» (-1 как маркер)."""
    if system_balance <= 0: return -1
    return max(SOUL_MIN_RATE, round(SOUL_MIN_RATE * cap / system_balance))

def _credit_soul_tx(c, user_id, delta, source, counter=0, ref_type='', ref_id=0, note=None):
    """Записать tx + обновить баланс. Должно вызываться внутри уже открытой транзакции."""
    c.execute(
        "INSERT INTO soc_soul_tx (user_id, delta, source, counter_user_id, ref_type, ref_id, note) "
        "VALUES (?,?,?,?,?,?,?)",
        (user_id, delta, source, counter, ref_type, ref_id, note),
    )
    if user_id > 0:
        c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user_id,))
        c.execute(
            "UPDATE soc_wallets SET soul = soul + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (delta, user_id),
        )

def _push_soul_event(user_id, delta, source, balance):
    """WS-уведомление владельцу о движении Soul."""
    ws_hub.send_to(user_id, "wallet.credit", {
        "currency": "soul", "delta": delta, "source": source, "balance": balance,
    })

def _soul_balance(c, user_id) -> int:
    row = c.execute("SELECT soul FROM soc_wallets WHERE user_id=?", (user_id,)).fetchone()
    return row["soul"] if row else 0


@router.get("/economy/state")
def economy_state(authorization: Optional[str] = Header(None)):
    """Состояние экономики: курс, системный баланс, сезон."""
    auth(authorization)  # любой авторизованный включая гостя
    c = db()
    state = _economy_state(c)
    c.close()
    if not state:
        raise HTTPException(503, "Экономика не инициализирована")
    rate = compute_soul_rate(state["system_balance"], state["cap"])
    return {
        "season_id": state["season_id"],
        "cap": state["cap"],
        "system_balance": state["system_balance"],
        "burned_total": state["burned_total"],
        "soul_rate_gost": rate,         # сколько Gost за 1 Soul (-1 если приостановлено)
        "rate_paused": rate == -1,
        "transfer_fee_bps": SOUL_TRANSFER_FEE_BPS,
        "market_fee_bps": NFT_MARKET_FEE_BPS,
        "nft_transfer_fee_soul": NFT_TRANSFER_FEE_SOUL,
    }


class SoulTransferBody(BaseModel):
    to_username: str
    amount: int
    note: Optional[str] = None


@router.post("/soul/transfer")
def soul_transfer(body: SoulTransferBody, authorization: Optional[str] = Header(None)):
    """Перевод Soul другому юзеру. Комиссия 3% сверху (платит отправитель).
    Минимум перевода: 1 Soul (значит итого спишется 1 + ceil(0.03) = 2)."""
    user = auth_member(authorization)
    _rate_limit(f"soul_tx:{user['id']}", limit=30, window=60)
    if body.amount <= 0:
        raise HTTPException(400, "Сумма должна быть положительной")
    if body.amount > 1_000_000:
        raise HTTPException(400, "Слишком большая сумма")
    to_username = (body.to_username or "").strip().lower()
    if to_username == user["username"]:
        raise HTTPException(400, "Нельзя перевести самому себе")
    note = (body.note or "").strip()[:200] if body.note else None

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        recipient = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (to_username,)).fetchone()
        if not recipient:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(404, "Получатель не найден")
        fee = max(1, (body.amount * SOUL_TRANSFER_FEE_BPS + 9999) // 10000)
        total_debit = body.amount + fee
        sender_bal = _soul_balance(c, user["id"])
        if sender_bal < total_debit:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul. Нужно {total_debit} (включая комиссию {fee}), у вас {sender_bal}")
        _credit_soul_tx(c, user["id"], -total_debit, 'transfer_out',
                        counter=recipient["id"], note=note)
        _credit_soul_tx(c, recipient["id"], body.amount, 'transfer_in',
                        counter=user["id"], note=note)
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        sender_new = _soul_balance(c, user["id"])
        recipient_new = _soul_balance(c, recipient["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка перевода: {e}")
    c.close()
    _push_soul_event(user["id"], -total_debit, 'transfer_out', sender_new)
    _push_soul_event(recipient["id"], body.amount, 'transfer_in', recipient_new)
    return {"status": "ok", "fee": fee, "new_balance": sender_new,
            "recipient": {"username": recipient["username"], "display_name": recipient["display_name"]}}


@router.get("/soul/tx")
def soul_tx_history(offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """История моих Soul-транзакций."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(
        "SELECT id, delta, source, counter_user_id, ref_type, ref_id, note, created_at "
        "FROM soc_soul_tx WHERE user_id=? ORDER BY id DESC LIMIT 30 OFFSET ?",
        (user["id"], offset),
    ).fetchall()
    counter_ids = list({r["counter_user_id"] for r in rows if r["counter_user_id"]})
    counter_map = {}
    if counter_ids:
        ph = ",".join("?" * len(counter_ids))
        for u in c.execute(f"SELECT id, username, display_name, is_official FROM users WHERE id IN ({ph})", counter_ids):
            counter_map[u["id"]] = {"username": u["username"], "display_name": u["display_name"], "is_official": bool(u["is_official"])}
    c.close()
    return {
        "transactions": [
            {
                "id": r["id"], "delta": r["delta"], "source": r["source"],
                "ref_type": r["ref_type"], "ref_id": r["ref_id"], "note": r["note"],
                "counter": counter_map.get(r["counter_user_id"]),
                "created_at": r["created_at"],
            }
            for r in rows
        ],
        "has_more": len(rows) == 30,
    }


class AdminEmitBody(BaseModel):
    amount: int
    token: str  # admin-secret (env)

def _check_admin_token(token: str) -> None:
    """Constant-time admin token validation (защита от timing attack)."""
    admin_token = os.environ.get('GE_ADMIN_TOKEN', '')
    if not admin_token or not hmac.compare_digest(token or '', admin_token):
        raise HTTPException(403, "Forbidden")


@router.post("/admin/economy/emit")
def admin_emit(body: AdminEmitBody, request: Request, authorization: Optional[str] = Header(None)):
    """Эмиссия Soul в system_balance (только админ). amount может быть отрицательным (изъятие)."""
    _rate_limit(f"admin:{_client_ip(request)}", limit=60, window=60)
    _check_admin_token(body.token)
    if abs(body.amount) > 10_000_000:
        raise HTTPException(400, "Слишком большая сумма")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        state = _economy_state(c)
        if not state:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(503, "Сезон не активен")
        new_bal = max(0, state["system_balance"] + body.amount)
        c.execute("UPDATE soc_economy_state SET system_balance=? WHERE season_id=?", (new_bal, state["season_id"]))
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    return {"status": "ok", "system_balance": new_bal, "delta": body.amount}


class AdminGrantBody(BaseModel):
    username: str
    amount: int                  # Soul (положительное = выдать, отрицательное = забрать)
    note: Optional[str] = None
    token: str

@router.post("/admin/economy/grant")
def admin_grant(body: AdminGrantBody, request: Request, authorization: Optional[str] = Header(None)):
    """Выдать Soul юзеру из system_balance (или забрать обратно). Только админ.
    Это «ручная» эмиссия в баланс юзера — для наград, тестов, компенсаций."""
    _rate_limit(f"admin:{_client_ip(request)}", limit=60, window=60)
    _check_admin_token(body.token)
    if body.amount == 0:
        raise HTTPException(400, "amount=0")
    if abs(body.amount) > 1_000_000:
        raise HTTPException(400, "Слишком большая сумма")
    username = body.username.strip().lower()
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        user = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
        if not user:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Юзер не найден")
        state = _economy_state(c)
        if not state:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(503, "Сезон не активен")
        if body.amount > 0:
            if state["system_balance"] < body.amount:
                c.execute("ROLLBACK"); c.close()
                raise HTTPException(400, f"В системе только {state['system_balance']} Soul")
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance - ? WHERE is_active=1", (body.amount,))
        else:
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (-body.amount,))
        _credit_soul_tx(c, user["id"], body.amount, 'admin_emit', note=(body.note or 'admin grant'))
        new_bal = _soul_balance(c, user["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise HTTPException(500, str(e))
    c.close()
    _push_soul_event(user["id"], body.amount, 'admin_emit', new_bal)
    return {"status": "ok", "user": username, "amount": body.amount, "new_balance": new_bal}


# ══════════════════════════════════════════════════════════════════════════════
# NFT — каталог, владение, маркет, передача
# ══════════════════════════════════════════════════════════════════════════════

def _nft_card(row: dict) -> dict:
    """Унифицированный формат NFT для API."""
    return {
        "id": row["id"],
        "serial": row["serial"],
        "owner": {
            "id": row["owner_id"],
            "username": row.get("owner_username"),
            "display_name": row.get("owner_display_name"),
            "is_official": bool(row.get("owner_is_official", 0)),
        },
        "catalog": {
            "id": row["catalog_id"],
            "slug": row["catalog_slug"],
            "name": row["catalog_name"],
            "rarity": row["catalog_rarity"],
            "max_supply": row["catalog_max_supply"],
            "image_kind": row.get("catalog_image_kind") or "preset",
            "image_data": row.get("catalog_image_data") or row["catalog_slug"],
            "bg_color": row.get("catalog_bg_color") or "#a855f7",
        },
        "listing": (
            {
                "id": row["listing_id"],
                "price": row["listing_price"],
                "currency": row.get("listing_currency") or "soul",
            }
            if row.get("listing_id") else None
        ),
    }

_NFT_JOIN_SQL = """
    SELECT n.id, n.serial, n.owner_id, n.catalog_id,
           u.username as owner_username, u.display_name as owner_display_name, u.is_official as owner_is_official,
           cat.slug as catalog_slug, cat.name as catalog_name, cat.rarity as catalog_rarity, cat.max_supply as catalog_max_supply,
           cat.image_kind as catalog_image_kind, cat.image_data as catalog_image_data, cat.bg_color as catalog_bg_color,
           l.id as listing_id, l.price_soul as listing_price, l.currency as listing_currency
    FROM soc_nfts n
    JOIN users u ON u.id = n.owner_id
    JOIN soc_nft_catalog cat ON cat.id = n.catalog_id
    LEFT JOIN soc_nft_listings l ON l.nft_id = n.id
"""


@router.get("/nft/catalog")
def nft_catalog(authorization: Optional[str] = Header(None)):
    """Список всех типов NFT в каталоге с floor_price отдельно для Gost и Soul."""
    auth(authorization)
    c = db()
    rows = c.execute("""
        SELECT cat.*, u.username as creator_username, u.display_name as creator_display_name, u.is_official as creator_is_official,
               (SELECT COUNT(*) FROM soc_nfts n WHERE n.catalog_id = cat.id) as minted,
               (SELECT COUNT(*) FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE n.catalog_id = cat.id) as listed,
               (SELECT MIN(l.price_soul) FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE n.catalog_id = cat.id AND l.currency='gost') as floor_gost,
               (SELECT MIN(l.price_soul) FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE n.catalog_id = cat.id AND l.currency='soul') as floor_soul
        FROM soc_nft_catalog cat
        JOIN users u ON u.id = cat.creator_id
        ORDER BY cat.id ASC
    """).fetchall()
    c.close()
    return {
        "catalog": [
            {
                "id": r["id"], "slug": r["slug"], "name": r["name"], "description": r["description"],
                "rarity": r["rarity"], "max_supply": r["max_supply"],
                "minted": r["minted"], "listed": r["listed"],
                "floor_gost": r["floor_gost"],
                "floor_soul": r["floor_soul"],
                "start_price_gost": r["start_price_soul"],
                "image_kind": r["image_kind"] or "preset",
                "image_data": r["image_data"] or r["slug"],
                "bg_color": r["bg_color"] or "#a855f7",
                "creator": {
                    "username": r["creator_username"],
                    "display_name": r["creator_display_name"],
                    "is_official": bool(r["creator_is_official"]),
                },
            }
            for r in rows
        ]
    }


@router.get("/nft/my")
def nft_my(authorization: Optional[str] = Header(None)):
    """Мои NFT (с пометкой выставлен ли на рынок)."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(_NFT_JOIN_SQL + " WHERE n.owner_id=? ORDER BY n.id DESC", (user["id"],)).fetchall()
    c.close()
    return {"nfts": [_nft_card(dict(r)) for r in rows]}


@router.get("/nft/listings")
def nft_listings(slug: Optional[str] = Query(None), sort: str = Query("price_asc"),
                  offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """Активные листинги маркета. Можно фильтровать по slug каталога."""
    auth(authorization)
    order = {"price_asc": "l.price_soul ASC", "price_desc": "l.price_soul DESC", "new": "l.id DESC"}.get(sort, "l.price_soul ASC")
    c = db()
    sql = _NFT_JOIN_SQL + " WHERE l.id IS NOT NULL"
    params: list = []
    if slug:
        sql += " AND cat.slug=?"; params.append(slug)
    sql += f" ORDER BY {order} LIMIT 30 OFFSET ?"
    params.append(offset)
    rows = c.execute(sql, params).fetchall()
    c.close()
    return {"listings": [_nft_card(dict(r)) for r in rows], "has_more": len(rows) == 30}


class NftListBody(BaseModel):
    nft_id: int
    price_soul: int


@router.post("/nft/list")
def nft_list_for_sale(body: NftListBody, authorization: Optional[str] = Header(None)):
    """Выставить свой NFT на маркет."""
    user = auth_member(authorization)
    _rate_limit(f"nftlist:{user['id']}", limit=30, window=60)
    if body.price_soul <= 0 or body.price_soul > 1_000_000:
        raise HTTPException(400, "Цена должна быть от 1 до 1 000 000 Soul")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        nft = c.execute("SELECT owner_id FROM soc_nfts WHERE id=?", (body.nft_id,)).fetchone()
        if not nft:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "NFT не найден")
        if nft["owner_id"] != user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(403, "Это не ваш NFT")
        existing = c.execute("SELECT id FROM soc_nft_listings WHERE nft_id=?", (body.nft_id,)).fetchone()
        if existing:
            c.execute("UPDATE soc_nft_listings SET price_soul=? WHERE nft_id=?", (body.price_soul, body.nft_id))
        else:
            c.execute("INSERT INTO soc_nft_listings (nft_id, seller_id, price_soul) VALUES (?,?,?)",
                      (body.nft_id, user["id"], body.price_soul))
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    return {"status": "ok"}


@router.delete("/nft/list/{nft_id}")
def nft_unlist(nft_id: int, authorization: Optional[str] = Header(None)):
    """Снять свой NFT с маркета."""
    user = auth_member(authorization)
    c = db()
    row = c.execute("SELECT seller_id FROM soc_nft_listings WHERE nft_id=?", (nft_id,)).fetchone()
    if not row:
        c.close(); raise HTTPException(404, "Не выставлен")
    if row["seller_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Не ваш листинг")
    c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (nft_id,))
    c.commit(); c.close()
    return {"status": "ok"}


@router.post("/nft/buy/{nft_id}")
def nft_buy(nft_id: int, authorization: Optional[str] = Header(None)):
    """Купить NFT с маркета.

    Логика по валюте листинга:
    - currency='gost' (первичные от GhostEcos) — платим Gost (без 10% комиссии,
      т.к. система не берёт с себя), Gost идёт в кошелёк ghostecos
    - currency='soul' (P2P) — платим Soul + 10% комиссия (см. ниже):
        - продавец = GhostEcos → 10% сжигается, цена в system_balance (дефляция)
        - продавец = обычный юзер → 10% в system_balance, цена продавцу
    """
    user = auth_member(authorization)
    _rate_limit(f"nftbuy:{user['id']}", limit=30, window=60)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        lst = c.execute(
            "SELECT l.id as lid, l.price_soul as price, l.currency, l.seller_id, "
            "n.id as nft_id, n.owner_id, n.catalog_id "
            "FROM soc_nft_listings l JOIN soc_nfts n ON l.nft_id=n.id WHERE l.nft_id=?",
            (nft_id,),
        ).fetchone()
        if not lst:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Не продаётся")
        if lst["seller_id"] == user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Нельзя купить свой NFT")
        price = lst["price"]
        currency = lst["currency"] or 'soul'

        if currency == 'gost':
            wallet = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
            buyer_gost = (wallet["gost"] if wallet else 0)
            if buyer_gost < price:
                c.execute("ROLLBACK"); c.close()
                raise HTTPException(400, f"Недостаточно Gost. Цена {price}, у вас {buyer_gost}")
            c.execute(
                "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
                (price, user["id"]),
            )
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, 'spend', ?, 'nft', ?)",
                (user["id"], -price, lst["seller_id"], nft_id),
            )
            c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (lst["seller_id"],))
            c.execute(
                "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
                (price, lst["seller_id"]),
            )
            c.execute("UPDATE soc_nfts SET owner_id=? WHERE id=?", (user["id"], nft_id))
            c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (nft_id,))
            buyer_gost_new = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()["gost"]
            c.execute("COMMIT")
            c.close()
            ws_hub.send_to(user["id"], "wallet.credit", {
                "currency": "gost", "delta": -price, "source": "spend", "balance": buyer_gost_new,
            })
            ws_hub.broadcast("nft.sold", {"nft_id": nft_id})
            return {"status": "ok", "price": price, "fee": 0, "currency": "gost", "new_balance_gost": buyer_gost_new}

        fee = max(1, (price * NFT_MARKET_FEE_BPS + 9999) // 10000)
        buyer_bal = _soul_balance(c, user["id"])
        if buyer_bal < price + fee:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul. Цена {price} + комиссия {fee} = {price+fee}, у вас {buyer_bal}")
        _credit_soul_tx(c, user["id"], -(price + fee), 'nft_buy',
                        counter=lst["seller_id"], ref_type='nft', ref_id=nft_id)
        seller_official = c.execute("SELECT is_official FROM users WHERE id=?", (lst["seller_id"],)).fetchone()
        if seller_official and seller_official["is_official"]:
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance - ?, burned_total = burned_total + ? WHERE is_active=1",
                      (price, fee))
            _credit_soul_tx(c, lst["seller_id"], 0, 'nft_sell',
                            counter=user["id"], ref_type='nft', ref_id=nft_id, note=f'sold for {price}, burn {fee}')
        else:
            _credit_soul_tx(c, lst["seller_id"], price, 'nft_sell',
                            counter=user["id"], ref_type='nft', ref_id=nft_id)
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        c.execute("UPDATE soc_nfts SET owner_id=? WHERE id=?", (user["id"], nft_id))
        c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (nft_id,))
        buyer_new = _soul_balance(c, user["id"])
        seller_new = _soul_balance(c, lst["seller_id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка покупки: {e}")
    c.close()
    _push_soul_event(user["id"], -(price + fee), 'nft_buy', buyer_new)
    if not (seller_official and seller_official["is_official"]):
        _push_soul_event(lst["seller_id"], price, 'nft_sell', seller_new)
    ws_hub.broadcast("nft.sold", {"nft_id": nft_id})
    return {"status": "ok", "price": price, "fee": fee, "currency": "soul", "new_balance": buyer_new}


# ══════════════════════════════════════════════════════════════════════════════
# INVOICES (счета на оплату Soul)
# ══════════════════════════════════════════════════════════════════════════════
INVOICE_CREATE_GOST = 100
INVOICE_EXTEND_GOST = 90
INVOICE_PAY_FEE_BPS = 500  # 5%
INVOICE_TTL_DAYS = 7
INVOICE_CODE_ALPHA = "abcdefghkmnpqrstuvwxyz23456789"  # без похожих символов

def _gen_invoice_code() -> str:
    """12-символьный код в формате xxxx-xxxx-xxxx."""
    p = lambda: ''.join(secrets.choice(INVOICE_CODE_ALPHA) for _ in range(4))
    return f"{p()}-{p()}-{p()}"


class InvoiceCreateBody(BaseModel):
    amount_soul: int
    note: Optional[str] = None


@router.post("/invoice/create")
def invoice_create(body: InvoiceCreateBody, authorization: Optional[str] = Header(None)):
    """Создать счёт. Платит автор 100 Gost. Живёт 7 дней. Можно оплатить много раз."""
    user = auth_member(authorization)
    _rate_limit(f"invoicec:{user['id']}", limit=20, window=3600)
    if body.amount_soul <= 0 or body.amount_soul > 1_000_000:
        raise HTTPException(400, "Сумма от 1 до 1 000 000 Soul")
    note = (body.note or "").strip()[:200] or None
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        wallet = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
        bal = (wallet["gost"] if wallet else 0)
        if bal < INVOICE_CREATE_GOST:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {INVOICE_CREATE_GOST} Gost для создания счёта (у вас {bal})")
        c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user["id"],))
        c.execute(
            "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (INVOICE_CREATE_GOST, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source) VALUES (?, 'gost', ?, 'spend')",
            (user["id"], -INVOICE_CREATE_GOST),
        )
        for _attempt in range(8):
            code = _gen_invoice_code()
            exists = c.execute("SELECT 1 FROM soc_invoices WHERE code=?", (code,)).fetchone()
            if not exists: break
        else:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(500, "Не удалось сгенерировать код")
        c.execute(
            "INSERT INTO soc_invoices (code, owner_id, amount_soul, note, expires_at) "
            "VALUES (?, ?, ?, ?, datetime('now', '+7 day'))",
            (code, user["id"], body.amount_soul, note),
        )
        new_gost = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()["gost"]
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    ws_hub.send_to(user["id"], "wallet.credit", {
        "currency": "gost", "delta": -INVOICE_CREATE_GOST, "source": "spend", "balance": new_gost,
    })
    return {"status": "ok", "code": code, "amount_soul": body.amount_soul, "note": note}


@router.get("/invoice/my")
def invoice_my(authorization: Optional[str] = Header(None)):
    """Мои инвойсы."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute(
        "SELECT id, code, amount_soul, note, paid_count, total_received, "
        "created_at, expires_at, cancelled, "
        "(strftime('%s', expires_at) - strftime('%s','now')) as seconds_left "
        "FROM soc_invoices WHERE owner_id=? ORDER BY id DESC LIMIT 30",
        (user["id"],),
    ).fetchall()
    c.close()
    return {
        "invoices": [
            {
                "id": r["id"], "code": r["code"], "amount_soul": r["amount_soul"],
                "note": r["note"], "paid_count": r["paid_count"],
                "total_received": r["total_received"], "created_at": r["created_at"],
                "expires_at": r["expires_at"], "cancelled": bool(r["cancelled"]),
                "seconds_left": max(0, r["seconds_left"] or 0),
            }
            for r in rows
        ]
    }


@router.get("/invoice/{code}")
def invoice_info(code: str, authorization: Optional[str] = Header(None)):
    """Публичная информация о счёте (для страницы оплаты по ссылке)."""
    auth(authorization)
    c = db()
    row = c.execute(
        "SELECT i.*, u.username as owner_username, u.display_name as owner_display_name, u.is_official as owner_is_official, "
        "(strftime('%s', expires_at) - strftime('%s','now')) as seconds_left "
        "FROM soc_invoices i JOIN users u ON u.id=i.owner_id WHERE i.code=?", (code,),
    ).fetchone()
    c.close()
    if not row:
        raise HTTPException(404, "Счёт не найден")
    return {
        "code": row["code"],
        "amount_soul": row["amount_soul"],
        "note": row["note"],
        "owner": {
            "username": row["owner_username"], "display_name": row["owner_display_name"],
            "is_official": bool(row["owner_is_official"]),
        },
        "paid_count": row["paid_count"],
        "expires_at": row["expires_at"],
        "seconds_left": max(0, row["seconds_left"] or 0),
        "cancelled": bool(row["cancelled"]),
        "expired": (row["seconds_left"] or 0) <= 0,
        "fee_bps": INVOICE_PAY_FEE_BPS,
    }


@router.post("/invoice/{code}/pay")
def invoice_pay(code: str, authorization: Optional[str] = Header(None)):
    """Оплатить счёт. Комиссия 5% сверху."""
    user = auth_member(authorization)
    _rate_limit(f"invpay:{user['id']}", limit=30, window=60)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        inv = c.execute("SELECT * FROM soc_invoices WHERE code=?", (code,)).fetchone()
        if not inv:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Счёт не найден")
        if inv["cancelled"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Счёт отменён")
        sl = c.execute("SELECT strftime('%s', ?) - strftime('%s','now') as s", (inv["expires_at"],)).fetchone()["s"]
        if (sl or 0) <= 0:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Срок счёта истёк")
        if inv["owner_id"] == user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Нельзя оплачивать свой счёт")
        amount = inv["amount_soul"]
        fee = max(1, (amount * INVOICE_PAY_FEE_BPS + 9999) // 10000)
        total = amount + fee
        bal = _soul_balance(c, user["id"])
        if bal < total:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul: нужно {total} (счёт {amount} + комиссия {fee}), у вас {bal}")
        _credit_soul_tx(c, user["id"], -total, 'invoice_pay',
                        counter=inv["owner_id"], ref_type='invoice', ref_id=inv["id"],
                        note=inv["note"])
        _credit_soul_tx(c, inv["owner_id"], amount, 'invoice_in',
                        counter=user["id"], ref_type='invoice', ref_id=inv["id"],
                        note=inv["note"])
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        c.execute("UPDATE soc_invoices SET paid_count = paid_count + 1, total_received = total_received + ? WHERE id=?",
                  (amount, inv["id"]))
        payer_new = _soul_balance(c, user["id"])
        owner_new = _soul_balance(c, inv["owner_id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    _push_soul_event(user["id"], -total, 'invoice_pay', payer_new)
    _push_soul_event(inv["owner_id"], amount, 'invoice_in', owner_new)
    return {"status": "ok", "amount": amount, "fee": fee, "new_balance": payer_new}


@router.post("/invoice/{code}/extend")
def invoice_extend(code: str, authorization: Optional[str] = Header(None)):
    """Продлить срок счёта ещё на 7 дней. Стоит 90 Gost."""
    user = auth_member(authorization)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        inv = c.execute("SELECT * FROM soc_invoices WHERE code=? AND owner_id=?", (code, user["id"])).fetchone()
        if not inv:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Не ваш счёт")
        wallet = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
        if (wallet["gost"] if wallet else 0) < INVOICE_EXTEND_GOST:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {INVOICE_EXTEND_GOST} Gost")
        c.execute(
            "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (INVOICE_EXTEND_GOST, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source) VALUES (?, 'gost', ?, 'spend')",
            (user["id"], -INVOICE_EXTEND_GOST),
        )
        c.execute("UPDATE soc_invoices SET expires_at = datetime(expires_at, '+7 day'), cancelled = 0 WHERE id=?",
                  (inv["id"],))
        new_gost = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()["gost"]
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    ws_hub.send_to(user["id"], "wallet.credit", {
        "currency": "gost", "delta": -INVOICE_EXTEND_GOST, "source": "spend", "balance": new_gost,
    })
    return {"status": "ok"}


@router.delete("/invoice/{code}")
def invoice_cancel(code: str, authorization: Optional[str] = Header(None)):
    """Отменить свой счёт (по нему нельзя будет платить, но история сохранится)."""
    user = auth_member(authorization)
    c = db()
    inv = c.execute("SELECT id FROM soc_invoices WHERE code=? AND owner_id=?", (code, user["id"])).fetchone()
    if not inv:
        c.close(); raise HTTPException(404, "Не ваш счёт")
    c.execute("UPDATE soc_invoices SET cancelled=1 WHERE id=?", (inv["id"],))
    c.commit(); c.close()
    return {"status": "ok"}


# ══════════════════════════════════════════════════════════════════════════════
# USERNAMES — кастомные имена за Soul (lifetime cap 3 на аккаунт)
# ══════════════════════════════════════════════════════════════════════════════
USERNAME_CREATE_PRICE_SOUL = 100
USERNAME_P2P_FEE_BPS = 1000  # 10%
USERNAME_LIFETIME_CAP = 3


class UsernameCreateBody(BaseModel):
    username: str


@router.post("/username/create")
def username_create(body: UsernameCreateBody, authorization: Optional[str] = Header(None)):
    """Создать новый уникальный username за 100 Soul. Не более 3 за жизнь аккаунта."""
    user = auth_member(authorization)
    _rate_limit(f"unc:{user['id']}", limit=5, window=3600)
    new_username = _val_username(body.username)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        u = c.execute("SELECT usernames_created FROM users WHERE id=?", (user["id"],)).fetchone()
        if (u["usernames_created"] or 0) >= USERNAME_LIFETIME_CAP:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(403, f"Лимит создания username: {USERNAME_LIFETIME_CAP}")
        clash = c.execute(
            "SELECT 1 FROM users WHERE username=? UNION ALL SELECT 1 FROM soc_usernames WHERE username=?",
            (new_username, new_username),
        ).fetchone()
        if clash:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(409, "Username уже занят")
        bal = _soul_balance(c, user["id"])
        if bal < USERNAME_CREATE_PRICE_SOUL:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {USERNAME_CREATE_PRICE_SOUL} Soul (у вас {bal})")
        _credit_soul_tx(c, user["id"], -USERNAME_CREATE_PRICE_SOUL, 'username_create',
                        ref_type='username', ref_id=0, note=new_username)
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1",
                  (USERNAME_CREATE_PRICE_SOUL,))
        c.execute("INSERT INTO soc_usernames (username, owner_id) VALUES (?, ?)", (new_username, user["id"]))
        c.execute("UPDATE users SET usernames_created = usernames_created + 1 WHERE id=?", (user["id"],))
        new_bal = _soul_balance(c, user["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    _push_soul_event(user["id"], -USERNAME_CREATE_PRICE_SOUL, 'username_create', new_bal)
    return {"status": "ok", "username": new_username, "remaining_lifetime": USERNAME_LIFETIME_CAP - (u["usernames_created"] + 1)}


@router.get("/username/my")
def username_my(authorization: Optional[str] = Header(None)):
    """Мои username (включая primary + дополнительные)."""
    user = auth_member(authorization)
    c = db()
    extras = c.execute(
        "SELECT username, for_sale_price, acquired_at FROM soc_usernames WHERE owner_id=? ORDER BY acquired_at",
        (user["id"],),
    ).fetchall()
    me_row = c.execute("SELECT username, usernames_created FROM users WHERE id=?", (user["id"],)).fetchone()
    c.close()
    return {
        "primary": me_row["username"],
        "lifetime_created": me_row["usernames_created"] or 0,
        "lifetime_cap": USERNAME_LIFETIME_CAP,
        "additional": [
            {"username": r["username"], "for_sale_price": r["for_sale_price"], "acquired_at": r["acquired_at"]}
            for r in extras
        ],
    }


class UsernameListBody(BaseModel):
    username: str
    price_soul: Optional[int] = None  # None = снять с продажи


@router.post("/username/list")
def username_list(body: UsernameListBody, authorization: Optional[str] = Header(None)):
    """Выставить свой username на P2P или снять с продажи."""
    user = auth_member(authorization)
    c = db()
    row = c.execute("SELECT owner_id FROM soc_usernames WHERE username=?", (body.username,)).fetchone()
    if not row or row["owner_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Не ваш username")
    if body.price_soul is not None and (body.price_soul < 1 or body.price_soul > 1_000_000):
        c.close(); raise HTTPException(400, "Цена 1..1 000 000")
    c.execute("UPDATE soc_usernames SET for_sale_price=? WHERE username=?", (body.price_soul, body.username))
    c.commit(); c.close()
    return {"status": "ok"}


@router.get("/username/market")
def username_market(offset: int = Query(0, ge=0), authorization: Optional[str] = Header(None)):
    """Активные листинги username на P2P."""
    auth(authorization)
    c = db()
    rows = c.execute(
        "SELECT n.username, n.for_sale_price, u.username as owner_username, u.display_name as owner_display_name, u.is_official "
        "FROM soc_usernames n JOIN users u ON u.id=n.owner_id "
        "WHERE n.for_sale_price IS NOT NULL ORDER BY n.for_sale_price ASC LIMIT 30 OFFSET ?",
        (offset,),
    ).fetchall()
    c.close()
    return {
        "listings": [
            {
                "username": r["username"], "price_soul": r["for_sale_price"],
                "owner": {"username": r["owner_username"], "display_name": r["owner_display_name"], "is_official": bool(r["is_official"])},
            } for r in rows
        ]
    }


@router.post("/username/buy/{username}")
def username_buy(username: str, authorization: Optional[str] = Header(None)):
    """Купить чужой username с P2P."""
    user = auth_member(authorization)
    _rate_limit(f"unbuy:{user['id']}", limit=10, window=3600)
    username = username.strip().lower()
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        row = c.execute("SELECT owner_id, for_sale_price FROM soc_usernames WHERE username=?", (username,)).fetchone()
        if not row or row["for_sale_price"] is None:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Не продаётся")
        if row["owner_id"] == user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Ваш же username")
        price = row["for_sale_price"]
        fee = max(1, (price * USERNAME_P2P_FEE_BPS + 9999) // 10000)
        seller_part = price - fee
        bal = _soul_balance(c, user["id"])
        if bal < price:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Недостаточно Soul: нужно {price} (у вас {bal})")
        _credit_soul_tx(c, user["id"], -price, 'username_buy',
                        counter=row["owner_id"], ref_type='username', note=username)
        _credit_soul_tx(c, row["owner_id"], seller_part, 'username_sell',
                        counter=user["id"], ref_type='username', note=username)
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (fee,))
        c.execute("UPDATE soc_usernames SET owner_id=?, for_sale_price=NULL, acquired_at=CURRENT_TIMESTAMP WHERE username=?",
                  (user["id"], username))
        buyer_new = _soul_balance(c, user["id"])
        seller_new = _soul_balance(c, row["owner_id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    _push_soul_event(user["id"], -price, 'username_buy', buyer_new)
    _push_soul_event(row["owner_id"], seller_part, 'username_sell', seller_new)
    return {"status": "ok", "username": username, "price": price, "fee": fee}


class UsernameSetPrimaryBody(BaseModel):
    username: str


@router.post("/username/set_primary")
def username_set_primary(body: UsernameSetPrimaryBody, authorization: Optional[str] = Header(None)):
    """Сделать дополнительный username основным. Бывший primary становится дополнительным."""
    user = auth_member(authorization)
    _rate_limit(f"setprim:{user['id']}", limit=10, window=3600)
    new_primary = body.username.strip().lower()
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        row = c.execute("SELECT owner_id, for_sale_price FROM soc_usernames WHERE username=?", (new_primary,)).fetchone()
        if not row or row["owner_id"] != user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(403, "Не ваш username")
        if row["for_sale_price"] is not None:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(400, "Сначала снимите username с продажи")
        clash = c.execute("SELECT id FROM users WHERE username=? AND id!=?", (new_primary, user["id"])).fetchone()
        if clash:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(409, "Этот username уже primary у другого юзера")
        if c.execute("SELECT 1 FROM soc_usernames WHERE username=?", (user["username"],)).fetchone():
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(500, "Inconsistent state: текущий primary уже в коллекции")
        old_primary = user["username"]
        c.execute("UPDATE users SET username=? WHERE id=?", (new_primary, user["id"]))
        c.execute("DELETE FROM soc_usernames WHERE username=?", (new_primary,))
        c.execute("INSERT INTO soc_usernames (username, owner_id, acquired_at) VALUES (?, ?, CURRENT_TIMESTAMP)",
                  (old_primary, user["id"]))
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    return {"status": "ok", "primary": new_primary}


# ══════════════════════════════════════════════════════════════════════════════
# MINT OWN NFT — юзеры создают свои NFT
# ══════════════════════════════════════════════════════════════════════════════
MINT_BASE_GOST = 50
MINT_SUPPLY_MIN = 100
MINT_SUPPLY_MAX = 10000
MINT_LIFETIME_CAP = 100  # не более 100 разных типов NFT на аккаунт (защита от спама)

def _mint_supply_fee(supply: int) -> int:
    """Доплата за тираж: (10000/supply)^1.1. Минимум 1, максимум адекватный."""
    if supply <= 0: return 0
    return max(1, round((10000 / supply) ** 1.1))


class MintNftBody(BaseModel):
    slug: str                  # уникальный слаг (a-z0-9-, 3-32)
    name: str                  # отображаемое название
    description: Optional[str] = None
    supply: int                # тираж 100..10000
    image_emoji: str           # 1-2 символа emoji (упрощённый MVP вместо upload картинки)
    bg_color: Optional[str] = None  # hex #RRGGBB, дефолт фиолет
    rarity: Optional[str] = None    # common/rare/legend (автор сам выбирает)
    auto_buy: int = 0          # сколько штук автор сам выкупает (0 ≤ auto_buy ≤ supply)
    sell_price_soul: int = 1   # цена выставления на маркет в Soul


@router.post("/nft/mint")
def nft_mint(body: MintNftBody, authorization: Optional[str] = Header(None)):
    """Минт собственного NFT. Автор платит Gost (50 + надбавка за низкий тираж).
    Если auto_buy>0 — система выкупает M первых штук у автора за Soul (эмиссия Soul автору),
    эти M штук система выставляет на маркет по той же цене (формирует floor).
    Остальные (supply - auto_buy) штук остаются у автора, он сам решает что с ними."""
    user = auth_member(authorization)
    _rate_limit(f"mint:{user['id']}", limit=10, window=3600)
    slug = (body.slug or "").strip().lower()
    if not re.match(r'^[a-z0-9_-]{3,32}$', slug):
        raise HTTPException(400, "Slug: 3-32 символов (a-z, 0-9, _, -)")
    if slug in {n['slug'] for n in _NFT_SEED}:
        raise HTTPException(409, "Этот slug зарезервирован системой")
    name = (body.name or "").strip()
    if not name or len(name) > 60:
        raise HTTPException(400, "Имя: 1-60 символов")
    desc = (body.description or "").strip()[:200]
    if body.supply < MINT_SUPPLY_MIN or body.supply > MINT_SUPPLY_MAX:
        raise HTTPException(400, f"Тираж: от {MINT_SUPPLY_MIN} до {MINT_SUPPLY_MAX}")
    emoji = (body.image_emoji or "").strip()
    if not emoji or len(emoji) > 6:
        raise HTTPException(400, "Эмодзи: 1-6 символов")
    bg = (body.bg_color or "#a855f7").strip()
    if not re.match(r'^#[0-9a-fA-F]{6}$', bg):
        raise HTTPException(400, "Цвет: формат #RRGGBB")
    rarity = body.rarity or 'common'
    if rarity not in ('common', 'rare', 'legend'):
        raise HTTPException(400, "rarity: common|rare|legend")
    if body.auto_buy < 0 or body.auto_buy > body.supply:
        raise HTTPException(400, "auto_buy 0..supply")
    if body.sell_price_soul < 1 or body.sell_price_soul > 1_000_000:
        raise HTTPException(400, "sell_price_soul 1..1 000 000")

    gost_fee = MINT_BASE_GOST + _mint_supply_fee(body.supply)

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        u = c.execute("SELECT nft_mints_count FROM users WHERE id=?", (user["id"],)).fetchone()
        if (u["nft_mints_count"] or 0) >= MINT_LIFETIME_CAP:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(403, f"Лимит созданных NFT: {MINT_LIFETIME_CAP}")
        if c.execute("SELECT 1 FROM soc_nft_catalog WHERE slug=?", (slug,)).fetchone():
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(409, "Slug занят")
        c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user["id"],))
        wallet = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()
        if wallet["gost"] < gost_fee:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {gost_fee} Gost (у вас {wallet['gost']})")
        c.execute(
            "UPDATE soc_wallets SET gost = gost - ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (gost_fee, user["id"]),
        )
        c.execute(
            "INSERT INTO soc_wallet_tx (user_id, currency, delta, source) VALUES (?, 'gost', ?, 'spend')",
            (user["id"], -gost_fee),
        )
        soul_to_author = 0
        if body.auto_buy > 0:
            soul_to_author = body.auto_buy * body.sell_price_soul
            state = _economy_state(c)
            if not state or state["system_balance"] < soul_to_author:
                c.execute("ROLLBACK"); c.close()
                raise HTTPException(503, "В системе недостаточно Soul для автовыкупа. Уменьшите auto_buy или цену.")
            c.execute("UPDATE soc_economy_state SET system_balance = system_balance - ? WHERE is_active=1",
                      (soul_to_author,))
            _credit_soul_tx(c, user["id"], soul_to_author, 'nft_mint_payout',
                            ref_type='nft_catalog', note=f"autobuy {body.auto_buy}")
        c.execute(
            "INSERT INTO soc_nft_catalog (slug, name, description, rarity, max_supply, creator_id, "
            "start_price_soul, image_kind, image_data, bg_color) "
            "VALUES (?,?,?,?,?,?,?, 'emoji', ?, ?)",
            (slug, name, desc, rarity, body.supply, user["id"], body.sell_price_soul, emoji, bg),
        )
        cat_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        ghostecos = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
        gh_uid = ghostecos["id"]
        for serial in range(1, body.supply + 1):
            if serial <= body.auto_buy:
                owner = gh_uid  # система получила (на маркет выставит)
            else:
                owner = user["id"]
            c.execute(
                "INSERT INTO soc_nfts (catalog_id, serial, owner_id) VALUES (?,?,?)",
                (cat_id, serial, owner),
            )
            nft_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
            if serial <= body.auto_buy:
                c.execute(
                    "INSERT INTO soc_nft_listings (nft_id, seller_id, price_soul, currency) VALUES (?,?,?,'soul')",
                    (nft_id, gh_uid, body.sell_price_soul),
                )
        c.execute("UPDATE users SET nft_mints_count = nft_mints_count + 1 WHERE id=?", (user["id"],))
        new_gost = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],)).fetchone()["gost"]
        new_soul = _soul_balance(c, user["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    c.close()
    ws_hub.send_to(user["id"], "wallet.credit", {
        "currency": "gost", "delta": -gost_fee, "source": "spend", "balance": new_gost,
    })
    if soul_to_author:
        _push_soul_event(user["id"], soul_to_author, 'nft_mint_payout', new_soul)
    ws_hub.broadcast("nft.minted", {"catalog_id": cat_id, "slug": slug, "name": name})
    return {
        "status": "ok", "catalog_id": cat_id, "slug": slug,
        "gost_paid": gost_fee, "soul_received": soul_to_author,
    }


class PostMintBody(BaseModel):
    post_id: int
    supply: int = 100               # 100..10000
    sell_price_soul: int = 5
    auto_buy: int = 0
    image_emoji: Optional[str] = None  # если не указано — берём 1-ю букву автора
    bg_color: Optional[str] = None


@router.post("/post/mint_as_nft")
def mint_post_as_nft(body: PostMintBody, authorization: Optional[str] = Header(None)):
    """Превратить свой пост в NFT (карточка-коллекционка).
    Создаётся новый тип в каталоге со slug `post-{id}-{rand}`, name = первые ~40
    символов текста поста или 'Пост от @username'. Логика та же что /nft/mint."""
    user = auth_member(authorization)
    c = db()
    post = c.execute("SELECT id, user_id, content FROM soc_posts WHERE id=?", (body.post_id,)).fetchone()
    c.close()
    if not post:
        raise HTTPException(404, "Пост не найден")
    if post["user_id"] != user["id"]:
        raise HTTPException(403, "Минтить можно только свои посты")
    text = (post["content"] or "").strip()
    name = text[:50] if text else f"Пост от @{user['username']}"
    desc = text[:200] if text else ''
    suffix = secrets.token_hex(3)
    slug = f"post-{post['id']}-{suffix}"
    emoji = (body.image_emoji or '').strip() or (user['display_name'] or user['username'])[0].upper()
    bg = body.bg_color or '#7c3aed'
    fake_body = MintNftBody(
        slug=slug, name=name, description=desc,
        supply=max(100, min(10000, body.supply)),
        image_emoji=emoji[:6], bg_color=bg, rarity='common',
        auto_buy=max(0, body.auto_buy),
        sell_price_soul=max(1, body.sell_price_soul),
    )
    return nft_mint(fake_body, authorization)


class NftTransferBody(BaseModel):
    nft_id: int
    to_username: str
    note: Optional[str] = None


@router.post("/nft/transfer")
def nft_transfer(body: NftTransferBody, authorization: Optional[str] = Header(None)):
    """Передать NFT юзеру. Комиссия — 1 Soul."""
    user = auth_member(authorization)
    _rate_limit(f"nfttx:{user['id']}", limit=30, window=60)
    to_username = (body.to_username or "").strip().lower()
    if to_username == user["username"]:
        raise HTTPException(400, "Нельзя передать самому себе")
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        nft = c.execute("SELECT owner_id FROM soc_nfts WHERE id=?", (body.nft_id,)).fetchone()
        if not nft:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "NFT не найден")
        if nft["owner_id"] != user["id"]:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(403, "Не ваш NFT")
        recipient = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (to_username,)).fetchone()
        if not recipient:
            c.execute("ROLLBACK"); c.close(); raise HTTPException(404, "Получатель не найден")
        sender_bal = _soul_balance(c, user["id"])
        if sender_bal < NFT_TRANSFER_FEE_SOUL:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, f"Нужно {NFT_TRANSFER_FEE_SOUL} Soul для оплаты комиссии передачи")
        _credit_soul_tx(c, user["id"], -NFT_TRANSFER_FEE_SOUL, 'nft_fee',
                        counter=recipient["id"], ref_type='nft', ref_id=body.nft_id)
        c.execute("UPDATE soc_economy_state SET system_balance = system_balance + ? WHERE is_active=1", (NFT_TRANSFER_FEE_SOUL,))
        c.execute("DELETE FROM soc_nft_listings WHERE nft_id=?", (body.nft_id,))
        c.execute("UPDATE soc_nfts SET owner_id=? WHERE id=?", (recipient["id"], body.nft_id))
        sender_new = _soul_balance(c, user["id"])
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка передачи: {e}")
    c.close()
    _push_soul_event(user["id"], -NFT_TRANSFER_FEE_SOUL, 'nft_fee', sender_new)
    ws_hub.send_to(recipient["id"], "nft.received", {"nft_id": body.nft_id, "from": user["username"]})
    return {"status": "ok", "fee": NFT_TRANSFER_FEE_SOUL,
            "recipient": {"username": recipient["username"], "display_name": recipient["display_name"]}}


# ══════════════════════════════════════════════════════════════════════════════
# РОЗЫГРЫШИ (GIVEAWAY) — движок розыгрышей Gost для GhostBank
# Создавать/разыгрывать/отменять/удалять может ТОЛЬКО владелец (GE_ADMIN_TOKEN),
# тем же токеном что и /admin/economy/*. Участие — бесплатно, 1 билет на аккаунт.
# Каждый розыгрыш разовый: по дедлайну выбираются случайные победители
# (random.SystemRandom) и им атомарно начисляется Gost. Страница: /bank/giveaway/
# ══════════════════════════════════════════════════════════════════════════════

GIVEAWAY_MAX_PRIZE = 1_000_000          # потолок Gost на одного победителя
GIVEAWAY_MAX_WINNERS = 1000
GIVEAWAY_MAX_DURATION_S = 366 * 86400   # макс. до дедлайна (1 год)
GIVEAWAY_MIN_DURATION_S = 10            # мин. до дедлайна (короткие тест-розыгрыши)


def _optional_uid(authorization: Optional[str]) -> int:
    """Мягкая авторизация: вернуть user_id если валидный токен реального юзера,
    иначе 0 (гость или без токена). Не бросает — список розыгрышей публичный."""
    if not authorization or not authorization.startswith("Bearer "):
        return 0
    try:
        u = auth(authorization)
    except HTTPException:
        return 0
    return u["id"] if (u and not u.get("is_guest")) else 0


def _giveaway_public(c, g: dict, uid: int = 0) -> dict:
    """Формат розыгрыша для API: счётчик участников, участвую ли я,
    список победителей (для завершённых)."""
    gid = g["id"]
    entries_count = c.execute(
        "SELECT COUNT(*) AS n FROM soc_giveaway_entries WHERE giveaway_id=?", (gid,)
    ).fetchone()["n"]
    my_entered = False
    if uid > 0:
        my_entered = c.execute(
            "SELECT 1 FROM soc_giveaway_entries WHERE giveaway_id=? AND user_id=?", (gid, uid)
        ).fetchone() is not None
    winners = []
    if g["status"] == "finished":
        wrows = c.execute(
            "SELECT w.user_id, w.prize_gost, u.username, u.display_name "
            "FROM soc_giveaway_winners w LEFT JOIN users u ON u.id = w.user_id "
            "WHERE w.giveaway_id=? ORDER BY w.id", (gid,),
        ).fetchall()
        winners = [
            {"username": r["username"], "display_name": r["display_name"], "prize_gost": r["prize_gost"]}
            for r in wrows
        ]
    return {
        "id": gid,
        "title": g["title"],
        "description": g["description"],
        "prize_gost": g["prize_gost"],
        "winners_count": g["winners_count"],
        "status": g["status"],
        "ends_at": g["ends_at"],
        "created_at": g["created_at"],
        "drawn_at": g["drawn_at"],
        "entries_count": entries_count,
        "my_entered": my_entered,
        "winners": winners,
    }


def _draw_giveaway(gid: int) -> dict:
    """Разыгрывает один розыгрыш атомарно: выбирает случайных победителей из
    участников, начисляет им Gost, помечает finished. Идемпотентно — повторный
    вызов на завершённом ничего не делает (защита от двойного розыгрыша)."""
    winners_payload = []
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        g = c.execute("SELECT * FROM soc_giveaways WHERE id=?", (gid,)).fetchone()
        if not g or g["status"] != "active":
            c.execute("ROLLBACK"); c.close()
            return {"drawn": False, "reason": "not_active"}
        now = int(time.time())
        pool = [r["user_id"] for r in c.execute(
            "SELECT user_id FROM soc_giveaway_entries WHERE giveaway_id=?", (gid,)
        ).fetchall()]
        prize = int(g["prize_gost"])
        k = min(int(g["winners_count"]), len(pool))
        winners = random.SystemRandom().sample(pool, k) if k > 0 else []
        for win_uid in winners:
            c.execute(
                "INSERT INTO soc_giveaway_winners (giveaway_id, user_id, prize_gost, created_at) "
                "VALUES (?,?,?,?)", (gid, win_uid, prize, now),
            )
            c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (win_uid,))
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, 'giveaway', 0, 'giveaway', ?)", (win_uid, prize, gid),
            )
            c.execute(
                "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
                (prize, win_uid),
            )
            new_bal = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (win_uid,)).fetchone()["gost"]
            winners_payload.append((win_uid, prize, new_bal))
        c.execute("UPDATE soc_giveaways SET status='finished', drawn_at=? WHERE id=?", (now, gid))
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise
    c.close()
    for win_uid, prize, new_bal in winners_payload:
        ws_hub.send_to(win_uid, "wallet.credit", {
            "currency": "gost", "delta": prize, "source": "giveaway", "balance": new_bal,
        })
        ws_hub.send_to(win_uid, "giveaway.win", {"giveaway_id": gid, "prize_gost": prize})
    return {"drawn": True, "winners_count": len(winners_payload)}


def _finalize_due_giveaways() -> None:
    """Ленивое завершение: разыгрывает активные розыгрыши с истёкшим дедлайном.
    Вызывается при чтении списка — не нужен фоновый планировщик."""
    c = db()
    try:
        due = c.execute(
            "SELECT id FROM soc_giveaways WHERE status='active' AND ends_at<=?",
            (int(time.time()),),
        ).fetchall()
    finally:
        c.close()
    for r in due:
        try:
            _draw_giveaway(r["id"])
        except Exception:
            pass


@router.get("/giveaway/list")
def giveaway_list(scope: str = Query("all"), authorization: Optional[str] = Header(None)):
    """Список розыгрышей. scope=active — только активные; all — активные + завершённые.
    Публичный (виден и без логина); my_entered заполняется для залогиненных."""
    uid = _optional_uid(authorization)
    _finalize_due_giveaways()
    c = db()
    if scope == "active":
        rows = c.execute(
            "SELECT * FROM soc_giveaways WHERE status='active' ORDER BY ends_at ASC"
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT * FROM soc_giveaways WHERE status != 'cancelled' "
            "ORDER BY (status='active') DESC, "
            "CASE WHEN status='active' THEN ends_at ELSE -drawn_at END ASC"
        ).fetchall()
    out = [_giveaway_public(c, dict(g), uid) for g in rows]
    c.close()
    return {"giveaways": out, "server_now": int(time.time())}


@router.get("/giveaway/{gid}")
def giveaway_get(gid: int, authorization: Optional[str] = Header(None)):
    """Один розыгрыш по id (для шеринга/детальной страницы). Публичный."""
    uid = _optional_uid(authorization)
    _finalize_due_giveaways()
    c = db()
    g = c.execute("SELECT * FROM soc_giveaways WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close()
        raise HTTPException(404, "Розыгрыш не найден")
    out = _giveaway_public(c, dict(g), uid)
    c.close()
    return {"giveaway": out, "server_now": int(time.time())}


@router.post("/giveaway/{gid}/enter")
def giveaway_enter(gid: int, authorization: Optional[str] = Header(None)):
    """Участие в розыгрыше. Только реальный аккаунт, 1 билет на аккаунт."""
    user = auth_member(authorization)
    _rate_limit(f"ga_enter:{user['id']}", limit=20, window=60)
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        g = c.execute("SELECT status, ends_at FROM soc_giveaways WHERE id=?", (gid,)).fetchone()
        if not g:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(404, "Розыгрыш не найден")
        if g["status"] != "active":
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, "Розыгрыш уже завершён")
        if int(time.time()) >= g["ends_at"]:
            c.execute("ROLLBACK"); c.close()
            raise HTTPException(400, "Время участия истекло")
        already = False
        try:
            c.execute(
                "INSERT INTO soc_giveaway_entries (giveaway_id, user_id, created_at) VALUES (?,?,?)",
                (gid, user["id"], int(time.time())),
            )
        except sqlite3.IntegrityError:
            already = True  # уже участвует (UNIQUE giveaway_id+user_id)
        count = c.execute(
            "SELECT COUNT(*) AS n FROM soc_giveaway_entries WHERE giveaway_id=?", (gid,)
        ).fetchone()["n"]
        c.execute("COMMIT")
    except HTTPException:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close(); raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise HTTPException(500, f"Ошибка участия: {e}")
    c.close()
    return {"entered": True, "already": already, "entries_count": count}



class GiveawayCreateBody(BaseModel):
    title: str
    description: Optional[str] = ""
    prize_gost: int
    winners_count: int = 1
    ends_at: Optional[int] = None        # unix-время дедлайна
    duration_hours: Optional[float] = None  # альтернатива ends_at: длительность от «сейчас»
    token: str


class GiveawayTokenBody(BaseModel):
    token: str


@router.post("/giveaway/create")
def giveaway_create(body: GiveawayCreateBody, request: Request):
    """Создать розыгрыш. Только владелец."""
    _rate_limit(f"ga_admin:{_client_ip(request)}", limit=60, window=60)
    _check_admin_token(body.token)
    title = re.sub(r"[\x00-\x1f\x7f]", "", body.title or "").strip()
    if not (1 <= len(title) <= 120):
        raise HTTPException(400, "Заголовок 1–120 символов")
    description = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", body.description or "").strip()[:1000]
    prize = int(body.prize_gost)
    if not (1 <= prize <= GIVEAWAY_MAX_PRIZE):
        raise HTTPException(400, f"Приз должен быть 1–{GIVEAWAY_MAX_PRIZE} Gost")
    winners = int(body.winners_count or 1)
    if not (1 <= winners <= GIVEAWAY_MAX_WINNERS):
        raise HTTPException(400, f"Победителей 1–{GIVEAWAY_MAX_WINNERS}")
    now = int(time.time())
    if body.ends_at is not None:
        ends_at = int(body.ends_at)
    elif body.duration_hours is not None:
        ends_at = now + int(float(body.duration_hours) * 3600)
    else:
        raise HTTPException(400, "Укажите ends_at или duration_hours")
    if ends_at - now < GIVEAWAY_MIN_DURATION_S:
        raise HTTPException(400, "Дедлайн слишком близко (минимум 60 секунд)")
    if ends_at - now > GIVEAWAY_MAX_DURATION_S:
        raise HTTPException(400, "Дедлайн слишком далеко (максимум 1 год)")
    c = db()
    try:
        cur = c.execute(
            "INSERT INTO soc_giveaways (title, description, prize_gost, winners_count, status, ends_at, created_at, drawn_at, created_by) "
            "VALUES (?,?,?,?,'active',?,?,0,0)",
            (title, description, prize, winners, ends_at, now),
        )
        gid = cur.lastrowid
        c.commit()
        g = c.execute("SELECT * FROM soc_giveaways WHERE id=?", (gid,)).fetchone()
        out = _giveaway_public(c, dict(g), 0)
    finally:
        c.close()
    return {"status": "ok", "giveaway": out}


@router.post("/giveaway/{gid}/draw")
def giveaway_draw(gid: int, body: GiveawayTokenBody, request: Request):
    """Разыграть досрочно (не дожидаясь дедлайна). Только владелец."""
    _rate_limit(f"ga_admin:{_client_ip(request)}", limit=60, window=60)
    _check_admin_token(body.token)
    res = _draw_giveaway(gid)
    if not res.get("drawn"):
        raise HTTPException(400, "Розыгрыш уже завершён или не найден")
    return {"status": "ok", **res}


@router.post("/giveaway/{gid}/cancel")
def giveaway_cancel(gid: int, body: GiveawayTokenBody, request: Request):
    """Отменить активный розыгрыш (без выплат). Только владелец."""
    _rate_limit(f"ga_admin:{_client_ip(request)}", limit=60, window=60)
    _check_admin_token(body.token)
    c = db()
    g = c.execute("SELECT status FROM soc_giveaways WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close()
        raise HTTPException(404, "Розыгрыш не найден")
    if g["status"] != "active":
        c.close()
        raise HTTPException(400, "Отменить можно только активный розыгрыш")
    c.execute("UPDATE soc_giveaways SET status='cancelled' WHERE id=?", (gid,))
    c.commit(); c.close()
    return {"status": "ok"}


@router.delete("/giveaway/{gid}")
def giveaway_delete(gid: int, token: str = Query(...)):
    """Удалить розыгрыш вместе с участниками и победителями. Только владелец.
    Не отзывает уже начисленный победителям Gost."""
    _check_admin_token(token)
    c = db()
    c.execute("DELETE FROM soc_giveaway_entries WHERE giveaway_id=?", (gid,))
    c.execute("DELETE FROM soc_giveaway_winners WHERE giveaway_id=?", (gid,))
    c.execute("DELETE FROM soc_giveaways WHERE id=?", (gid,))
    c.commit(); c.close()
    return {"status": "ok"}



def _ensure_saved_table():
    c = db()
    try:
        c.execute("""
            CREATE TABLE IF NOT EXISTS soc_saved (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(post_id, user_id)
            )
        """)
        c.execute("CREATE INDEX IF NOT EXISTS idx_saved_user ON soc_saved(user_id, created_at DESC)")
        c.commit()
    except sqlite3.OperationalError:
        pass
    finally:
        c.close()


@router.get("/me/saved/ids")
def my_saved_ids(authorization: Optional[str] = Header(None)):
    """Список post_id, которые я сохранил — для подсветки кнопки на фронте."""
    user = auth_member(authorization)
    _ensure_saved_table()
    c = db()
    rows = c.execute("SELECT post_id FROM soc_saved WHERE user_id=?", (user["id"],)).fetchall()
    c.close()
    return [r["post_id"] for r in rows]


@router.post("/me/saved/{post_id}")
def save_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Сохранить пост к себе (приватно). Идемпотентно."""
    user = auth_member(authorization)
    _ensure_saved_table()
    c = db()
    p = c.execute("SELECT id FROM soc_posts WHERE id=?", (post_id,)).fetchone()
    if not p:
        c.close()
        raise HTTPException(404, "Post not found")
    c.execute(
        "INSERT OR IGNORE INTO soc_saved (post_id, user_id, created_at) VALUES (?,?,?)",
        (post_id, user["id"], int(time.time())),
    )
    c.commit()
    c.close()
    return {"status": "ok", "saved": True}


@router.delete("/me/saved/{post_id}")
def unsave_post(post_id: int, authorization: Optional[str] = Header(None)):
    """Убрать пост из сохранённого."""
    user = auth_member(authorization)
    _ensure_saved_table()
    c = db()
    c.execute("DELETE FROM soc_saved WHERE post_id=? AND user_id=?", (post_id, user["id"]))
    c.commit()
    c.close()
    return {"status": "ok", "saved": False}


@router.get("/me/saved")
def my_saved(offset: int = Query(0), limit: int = Query(20), authorization: Optional[str] = Header(None)):
    """Мои сохранённые посты (только свои)."""
    user = auth_member(authorization)
    _ensure_saved_table()
    c = db()
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u2.username, u2.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count,
               s.created_at as saved_at
        FROM soc_saved s
        JOIN soc_posts p ON s.post_id=p.id
        JOIN users u2 ON p.user_id=u2.id
        WHERE s.user_id=?
        ORDER BY s.created_at DESC
        LIMIT ? OFFSET ?
    """, (user["id"], max(1, min(50, limit)), max(0, offset))).fetchall()
    out = _hydrate_posts(c, rows, user["id"])
    c.close()
    return out


@router.get("/me/reacted")
def my_reacted(offset: int = Query(0), limit: int = Query(20), authorization: Optional[str] = Header(None)):
    """Посты, на которые я ставил реакцию (только свои, приватно)."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT p.id, p.content, p.created_at, p.edited_at, p.user_id, p.media,
               p.source_channel_id, p.is_nsfw, p.nsfw_set_by,
               u2.username, u2.display_name,
               (SELECT COUNT(*) FROM soc_comments cm WHERE cm.post_id=p.id) as comments_count
        FROM soc_reactions rx
        JOIN soc_posts p ON rx.post_id=p.id
        JOIN users u2 ON p.user_id=u2.id
        WHERE rx.user_id=?
        ORDER BY p.created_at DESC
        LIMIT ? OFFSET ?
    """, (user["id"], max(1, min(50, limit)), max(0, offset))).fetchall()
    out = _hydrate_posts(c, rows, user["id"])
    c.close()
    return out


class MiniskaV2Item(BaseModel):
    url: str
    type: str = "image"   # "image" | "video"


class MiniskaV2Body(BaseModel):
    caption: str = ""
    media: list = []       # список MiniskaV2Item-подобных dict'ов
    is_nsfw: bool = False


@router.post("/miniska/new_v2")
def v11_create_miniska_carousel(body: MiniskaV2Body,
                                authorization: Optional[str] = Header(None)):
    """Создать миниску-карусель из массива медиа.
    Правила: 1..5 вложений, максимум 1 видео, видео ≤ MINISKA_MAX_DURATION сек.
    Каждый url должен быть уже загружен (через обычный аплоад) и существовать.
    """
    user = auth_member(authorization)
    _rate_limit(f"miniska:{user['id']}", limit=10, window=3600)

    caption = (body.caption or "").strip()
    if len(caption) > MINISKA_MAX_TEXT:
        raise HTTPException(400, f"Текст до {MINISKA_MAX_TEXT} символов")

    items = body.media or []
    if not isinstance(items, list) or len(items) < 1:
        raise HTTPException(400, "Нужно хотя бы одно вложение")
    if len(items) > 5:
        raise HTTPException(400, "Максимум 5 вложений")

    video_count = 0
    media = []
    for it in items:
        url = (it.get("url") if isinstance(it, dict) else getattr(it, "url", "")) or ""
        mtype = (it.get("type") if isinstance(it, dict) else getattr(it, "type", "image")) or "image"
        mtype = "video" if mtype == "video" else "image"

        if not _MEDIA_URL_RE.match(url):
            raise HTTPException(400, "Некорректный URL вложения")
        fname = url.split("/")[-1]
        fpath = os.path.join(MEDIA_DIR, fname)
        if not os.path.exists(fpath):
            raise HTTPException(404, "Файл не найден")

        if mtype == "video":
            video_count += 1
            if video_count > 1:
                raise HTTPException(400, "Максимум одно видео в миниске")
            try:
                import subprocess
                out = subprocess.run(
                    ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                     "-of", "default=noprint_wrappers=1:nokey=1", fpath],
                    capture_output=True, text=True, timeout=10
                )
                dur = float((out.stdout or "0").strip() or 0)
                if dur > MINISKA_MAX_DURATION + 1:
                    raise HTTPException(400, f"Видео слишком длинное. Максимум {MINISKA_MAX_DURATION} сек")
            except HTTPException:
                raise
            except Exception:
                pass

        media.append({"url": url, "type": mtype, "name": fname})

    media_json = json.dumps(media, ensure_ascii=False)
    nsfw = 1 if body.is_nsfw else 0
    c = db()
    try:
        c.execute(
            "INSERT INTO soc_posts (user_id, content, media, kind, is_nsfw) VALUES (?,?,?,'miniska',?)",
            (user["id"], caption or " ", media_json, nsfw),
        )
        post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        c.commit()
    finally:
        c.close()
    return {"status": "ok", "id": post_id, "count": len(media)}
