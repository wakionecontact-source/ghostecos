"""Регистрация, логин, устройства, logout, refresh."""
from __future__ import annotations
import uuid, time, re, base64, unicodedata
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field
from typing import Optional

import config, database as db, security
from ws.manager import manager
from dependencies import get_current_user, rate_limit_preauth

def _extract_token(authorization: Optional[str]) -> Optional[str]:
    if authorization and authorization.startswith("Bearer "):
        return authorization[7:]
    return None

# Зарезервированные имена — нельзя занять (анти-спуфинг саппорта/админа).
RESERVED_USERNAMES = {
    "support", "__support__", "admin", "administrator", "ghost", "ghostchat",
    "ghostecos", "system", "root", "moderator", "mod", "official", "null", "me",
}

def _has_heavy_chars(s: str) -> bool:
    """«Тяжёлые» символы: управляющие, zero-width, bidi-override, комбинирующие
    (zalgo). Именно zalgo-строкой проект однажды задосили — баним их в именах."""
    for ch in s:
        cp = ord(ch)
        if cp < 0x20 or (0x7F <= cp <= 0x9F):            # control C0/C1
            return True
        if cp in (0x00AD, 0x034F, 0xFEFF, 0x180E):        # invisible
            return True
        if (0x200B <= cp <= 0x200F or 0x202A <= cp <= 0x202E
                or 0x2060 <= cp <= 0x2064 or 0x2066 <= cp <= 0x206F):
            return True
        if unicodedata.category(ch) in ("Mn", "Mc", "Me"):  # combining marks
            return True
    return False

def _valid_pubkey(s: str) -> bool:
    """Публичный ключ X25519/Ed25519 — корректный base64 ровно 32 байт.
    Пустая строка допустима (ключи могут быть заданы позже)."""
    if not s:
        return True
    if len(s) > 64:
        return False
    try:
        raw = base64.b64decode(s, validate=True)
    except Exception:
        return False
    return len(raw) == 32

def _is_emoji(cp: int) -> bool:
    """Эмодзи и сопутствующие селекторы — зеркало клиентского валидатора."""
    return (
        0x1F000 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF
        or 0x2300 <= cp <= 0x23FF or 0x2B00 <= cp <= 0x2BFF
        or 0x1F1E6 <= cp <= 0x1F1FF or 0xFE00 <= cp <= 0xFE0F
        or 0x2194 <= cp <= 0x21AA or 0x231A <= cp <= 0x231B
        or 0x25AA <= cp <= 0x25FE or 0x2934 <= cp <= 0x2935
        or cp in (0x200D, 0x20E3, 0x203C, 0x2049, 0x2122, 0x2139, 0x24C2)
    )

def _password_error(p: str) -> Optional[str]:
    """Серверная валидация пароля (ТЗ): 8..150, любые КРОМЕ управляющих и эмодзи.
    Зеркало клиента — серверу нельзя доверять клиентской проверке."""
    n = len(p)
    if n < 8:
        return "Password too short (min 8)"
    if n > 150:
        return "Password too long (max 150)"
    for ch in p:
        cp = ord(ch)
        if cp < 0x20 or (0x7F <= cp <= 0x9F):
            return "Password contains forbidden characters"
        if _is_emoji(cp):
            return "Password must not contain emoji"
    return None

router = APIRouter(prefix="/api", tags=["auth"])

# ── Модели ────────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    # max_length=64 — общий лимит username по ТЗ (детальная проверка 3-60 без точек
    # в самом register). Раньше стоял 32 и резал длинные имена раньше кастомной логики.
    username:    str = Field(min_length=3, max_length=64)
    # Длину (8..150) и запрет управляющих/эмодзи проверяет _password_error —
    # даёт понятный 400 с текстом вместо невнятного Pydantic 422.
    password:    str
    device_id:   str = ""
    device_name: str = ""
    x25519_pub:  str = ""
    ed25519_pub: str = ""
    display_name: str = ""

class LoginRequest(BaseModel):
    username:    str
    password:    str
    device_id:   str = ""
    device_name: str = ""

class UpdateDeviceRequest(BaseModel):
    trust_type:  Optional[str] = None
    trust_level: Optional[int] = None
    permissions: Optional[dict] = None

# ── Эндпоинты ─────────────────────────────────────────────────────────────────

@router.post("/register")
async def register(req: RegisterRequest, request: Request,
                   _: None = Depends(rate_limit_preauth)):
    username = req.username.strip().lower()

    # SECURITY (H2): username ТОЛЬКО ASCII (латиница/цифры/_/.). Python isalnum()
    # пропускает Unicode (кириллицу) → можно подделать 'аdmin'. Точки не в счёт длины.
    no_dots = username.replace(".", "")
    if (not re.fullmatch(r"[a-z0-9_.]+", username) or len(username) > 64
            or len(no_dots) < 3 or len(no_dots) > 60):
        raise HTTPException(400, "Invalid username characters")
    if no_dots in RESERVED_USERNAMES or username in RESERVED_USERNAMES:
        raise HTTPException(409, "Username is reserved")

    # SECURITY (H2): display_name 2..100 без «тяжёлых» символов (zalgo/control/bidi).
    display = (req.display_name or username).strip()
    if not (2 <= len(display) <= 100) or _has_heavy_chars(display):
        raise HTTPException(400, "Invalid display name")

    # SECURITY: пароль 8..150 без управляющих/эмодзи (зеркало клиента, ТЗ).
    perr = _password_error(req.password)
    if perr:
        raise HTTPException(400, perr)

    # SECURITY (M3): публичные ключи — корректный base64 (32 байта), не мусор.
    if not _valid_pubkey(req.x25519_pub) or not _valid_pubkey(req.ed25519_pub):
        raise HTTPException(400, "Invalid public keys")

    existing = await db.fetchone("SELECT id FROM users WHERE username = ?", (username,))
    if existing:
        raise HTTPException(409, "Username already taken")

    hashed    = security.hash_password(req.password)
    now       = db.now()
    # Всегда создаём device_id — если клиент не передал, генерируем сами
    device_id = req.device_id or str(uuid.uuid4())

    await db.execute(
        "INSERT INTO users (username, display_name, argon2_hash, x25519_pub, ed25519_pub, created_at) "
        "VALUES (?,?,?,?,?,?)",
        (username, display, hashed,
         req.x25519_pub, req.ed25519_pub, now)
    )

    await db.execute(
        "INSERT OR IGNORE INTO device_registry "
        "(username, device_id, device_name, registered_at, trust_type) VALUES (?,?,?,?,?)",
        (username, device_id, req.device_name or "primary", now, "creator")
    )

    token = security.create_token(username, device_id)
    return {"token": token, "username": username, "device_id": device_id}



@router.post("/internal/shop_login")
async def shop_login_internal(req: dict, x_internal_key: Optional[str] = Header(default=None)):
    import security as _sec
    if not x_internal_key or not _sec.safe_equal(x_internal_key, config.INTERNAL_KEY):
        raise HTTPException(403, "forbidden")
    username = (req.get("username") or "").strip().lower()
    password = req.get("password") or ""
    user = await db.fetchone(
        "SELECT username, argon2_hash FROM users WHERE username = ?", (username,)
    )
    if not user or not _sec.verify_password(password, user["argon2_hash"]):
        raise HTTPException(401, "invalid_credentials")
    token = _sec.create_token(username)
    return {"token": token, "username": username}

@router.post("/login")
async def login(req: LoginRequest, request: Request,
                _: None = Depends(rate_limit_preauth)):
    username = req.username.strip().lower()
    user = await db.fetchone(
        "SELECT username, argon2_hash, is_premium FROM users WHERE username = ?",
        (username,)
    )
    if not user or not security.verify_password(req.password, user["argon2_hash"]):
        raise HTTPException(401, "Invalid credentials")

    # Проверить устройство
    device_id   = req.device_id
    device_name = req.device_name

    if device_id:
        dev = await db.fetchone(
            "SELECT blocked, trust_type FROM device_registry "
            "WHERE username = ? AND device_id = ?",
            (username, device_id)
        )
        if dev:
            if dev["blocked"]:
                raise HTTPException(403, "Device blocked")
            # Известное устройство — сразу токен
            if security.needs_rehash(user["argon2_hash"]):
                new_hash = security.hash_password(req.password)
                await db.execute(
                    "UPDATE users SET argon2_hash = ? WHERE username = ?",
                    (new_hash, username)
                )
            token = security.create_token(username, device_id)
            return {"token": token, "username": username,
                    "is_premium": bool(user["is_premium"])}
        else:
            # Новое устройство — запустить процесс подтверждения
            req_id   = str(uuid.uuid4())
            now      = db.now()
            expires  = now + 180  # 3 минуты
            await db.execute(
                "INSERT INTO pending_logins "
                "(request_id, username, device_id, device_name, phase, created_at, expires_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (req_id, username, device_id, device_name, "pending", now, expires)
            )
            # Зарегистрировать устройство как заблокированное до подтверждения
            await db.execute(
                "INSERT OR IGNORE INTO device_registry "
                "(username, device_id, device_name, registered_at, trust_type, blocked) "
                "VALUES (?,?,?,?,?,?)",
                (username, device_id, device_name, now, "numeric", 1)
            )
            # Уведомить онлайн устройства пользователя
            import time as _time
            msg = {
                "type": "login_request",
                "request_id": req_id,
                "device_id": device_id,
                "device_name": device_name or "Unknown",
                "login_type": "shop" if "shop" in (device_name or "").lower() else "device",
                "created_at": int(_time.time()),
            }
            await manager.broadcast([username], msg)
            return {"pending": True, "request_id": req_id}

    # SECURITY: device_id обязателен. Раньше пустой device_id выдавал токен
    # напрямую, минуя проверку доверия устройства (legacy-обход).
    raise HTTPException(400, "device_id required")


@router.get("/login_request/{request_id}")
async def poll_login_request(request_id: str):
    req = await db.fetchone(
        "SELECT phase, username, expires_at FROM pending_logins WHERE request_id = ?",
        (request_id,)
    )
    if not req:
        raise HTTPException(404, "Request not found")

    phase = req["phase"]
    # SECURITY (C3): истёкший запрос (кроме уже успешного) дальше не двигается.
    if phase != "success" and req["expires_at"] < db.now():
        return {"phase": "expired"}
    if phase == "success":
        token = security.create_token(req["username"])
        # Разблокировать устройство
        login_req = await db.fetchone(
            "SELECT device_id FROM pending_logins WHERE request_id = ?", (request_id,)
        )
        if login_req:
            await db.execute(
                "UPDATE device_registry SET blocked = 0 "
                "WHERE username = ? AND device_id = ?",
                (req["username"], login_req["device_id"])
            )
        return {"phase": "success", "token": token, "username": req["username"]}

    if phase in ("denied", "blocked"):
        return {"phase": phase}

    return {"phase": phase}


@router.post("/login_request/{request_id}/code_ready")
async def code_ready(request_id: str):
    # DEPRECATED (C2): фаза code_phase теперь выставляется ТОЛЬКО при одобрении
    # доверенным устройством, которое одновременно получает серверный код.
    # Эндпоинт оставлен для обратной совместимости и ничего не делает.
    return {"ok": True}


@router.post("/login_request/{request_id}/code_verify")
async def code_verify(request_id: str, body: dict):
    """Новое устройство присылает введённый 6-значный код. Сервер сверяет его
    с собственным хэшом. SECURITY (C2/C3): совпадение решает СЕРВЕР, не клиент."""
    code = str(body.get("code", "")).strip()
    req = await db.fetchone(
        "SELECT * FROM pending_logins WHERE request_id = ?", (request_id,)
    )
    if not req:
        raise HTTPException(404, "Request not found")
    if req["phase"] != "code_phase":
        raise HTTPException(409, "Not awaiting code")
    if req["expires_at"] < db.now():
        await db.execute(
            "UPDATE pending_logins SET phase='expired' WHERE request_id=?", (request_id,)
        )
        return {"result": "expired"}
    if not code.isdigit() or len(code) != 6:
        raise HTTPException(400, "Invalid code format")

    if security.safe_equal(security.hash_code(code), req["code_hash"] or ""):
        await db.execute(
            "UPDATE pending_logins SET phase='success' WHERE request_id=?", (request_id,)
        )
        await db.execute(
            "UPDATE device_registry SET blocked = 0 "
            "WHERE username = ? AND device_id = ?",
            (req["username"], req["device_id"])
        )
        token = security.create_token(req["username"], req["device_id"])
        return {"result": "success", "token": token, "username": req["username"]}

    # Неверный код: атомарно увеличиваем счётчик, лочим после 5 попыток.
    await db.execute(
        "UPDATE pending_logins SET attempt_count = attempt_count + 1 WHERE request_id = ?",
        (request_id,)
    )
    fresh = await db.fetchone(
        "SELECT attempt_count FROM pending_logins WHERE request_id = ?", (request_id,)
    )
    attempts = fresh["attempt_count"] if fresh else 99
    if attempts >= 5:
        await db.execute(
            "UPDATE pending_logins SET phase='denied' WHERE request_id=?", (request_id,)
        )
        return {"result": "locked"}
    return {"result": "wrong", "attempts_left": 5 - attempts}


@router.get("/my_pending_logins")
async def my_pending_logins(username: str = Depends(get_current_user)):
    reqs = await db.fetchall(
        "SELECT request_id, device_id, device_name, phase, created_at, expires_at "
        "FROM pending_logins WHERE username = ? AND phase = 'pending' AND expires_at > ?",
        (username, db.now())
    )
    return {"requests": reqs}


# ── Устройства ────────────────────────────────────────────────────────────────

@router.get("/devices")
async def list_devices(username: str = Depends(get_current_user)):
    import json as _json
    devs = await db.fetchall(
        "SELECT device_id, device_name, registered_at, blocked, trust_type, trust_level, permissions "
        "FROM device_registry WHERE username = ? ORDER BY registered_at DESC",
        (username,)
    )
    # permissions хранится как JSON-строка — парсим в dict
    for d in devs:
        if isinstance(d.get("permissions"), str):
            try:
                d["permissions"] = _json.loads(d["permissions"])
            except Exception:
                d["permissions"] = {}
    return {"devices": devs}



@router.get("/devices/blocked")
async def list_blocked_devices(username: str = Depends(get_current_user)):
    import json as _json
    devs = await db.fetchall(
        "SELECT device_id, device_name, registered_at, blocked, trust_type, trust_level, permissions "
        "FROM device_registry WHERE username = ? AND blocked = 1 ORDER BY registered_at DESC",
        (username,)
    )
    for d in devs:
        if isinstance(d.get("permissions"), str):
            try:
                d["permissions"] = _json.loads(d["permissions"])
            except Exception:
                d["permissions"] = {}
    return {"devices": devs}

@router.post("/devices/{device_id}/trust")
async def update_device(device_id: str, req: UpdateDeviceRequest,
                        username: str = Depends(get_current_user)):
    updates, vals = [], []
    if req.trust_type  is not None: updates.append("trust_type = ?");  vals.append(req.trust_type)
    if req.trust_level is not None: updates.append("trust_level = ?"); vals.append(req.trust_level)
    if not updates:
        return {"ok": True}
    vals += [username, device_id]
    await db.execute(
        f"UPDATE device_registry SET {', '.join(updates)} "
        "WHERE username = ? AND device_id = ?",
        tuple(vals)
    )
    return {"ok": True}


@router.post("/devices/{device_id}/permissions")
async def update_device_permissions(device_id: str, req: dict,
                                    username: str = Depends(get_current_user)):
    import json
    await db.execute(
        "UPDATE device_registry SET permissions = ? WHERE username = ? AND device_id = ?",
        (json.dumps(req), username, device_id)
    )
    return {"ok": True}



@router.delete("/devices/{device_id}/unblock")
async def unblock_device(device_id: str, username: str = Depends(get_current_user)):
    await db.execute(
        "UPDATE device_registry SET blocked = 0 WHERE username = ? AND device_id = ?",
        (username, device_id)
    )
    return {"ok": True}

@router.delete("/devices/{device_id}")
async def revoke_device(device_id: str, username: str = Depends(get_current_user)):
    await db.execute(
        "UPDATE device_registry SET blocked = 1 WHERE username = ? AND device_id = ?",
        (username, device_id)
    )
    return {"ok": True}


# ── Token management ──────────────────────────────────────────────────────────

@router.post("/auth/logout")
async def logout(
    username: str = Depends(get_current_user),
    authorization: Optional[str] = Header(default=None),
):
    """
    Отзывает текущий токен (logout).
    Токен становится недействительным немедленно даже до истечения срока.
    """
    token = _extract_token(authorization)
    if token:
        payload = security.decode_token_soft(token)
        if payload:
            jti = payload.get("jti")
            if jti:
                await db.revoke_jti(jti, username)
    return {"ok": True}


@router.post("/auth/logout_all")
async def logout_all(username: str = Depends(get_current_user)):
    """
    Отзывает ВСЕ токены пользователя (смена пароля / компрометация).
    Все устройства будут разлогинены.
    """
    await db.revoke_all_user_tokens(username)
    return {"ok": True}


@router.post("/auth/refresh")
async def refresh_token(
    username: str = Depends(get_current_user),
    authorization: Optional[str] = Header(default=None),
):
    """
    Выдаёт новый токен, отзывая старый.
    Используется для продления сессии без переввода пароля.
    """
    # Отозвать старый токен
    token = _extract_token(authorization)
    if token:
        payload = security.decode_token_soft(token)
        if payload:
            jti = payload.get("jti")
            device_id = payload.get("did", "")
            if jti:
                await db.revoke_jti(jti, username)
            new_token = security.create_token(username, device_id)
            return {"token": new_token}
    raise HTTPException(status.HTTP_400_BAD_REQUEST, "No token to refresh")
