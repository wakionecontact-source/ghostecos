"""
GhostChat web — приватный мессенджер.

Концепция:
- Сообщения хранятся ВРЕМЕННО, только до доставки получателю
- E2E: на клиенте → ciphertext (base64). Сервер видит только шифрованный мусор
- История — на клиенте в IndexedDB. Сервер не знает о чём чаты после доставки
- Метаданные диалогов — тоже на клиенте

Endpoints:
- POST /keys/upload — загрузить свои E2E-ключи
- GET  /keys/me — мои ключи (для расшифровки на новом устройстве)
- GET  /keys/{username} — публичный ключ собеседника
- POST /send — отправить (ciphertext)
- GET  /pending — забрать всё, что не доставлено мне (и удалить)

WebSocket-события (через ws_hub):
- chat.new — новое сообщение получателю (если онлайн), затем удаляется
"""
from fastapi import APIRouter, Header, HTTPException, UploadFile, File, Form, Response, Query
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool
from pydantic import BaseModel
from typing import Optional
import asyncio, base64, json, os, sqlite3, tempfile, time, uuid

from ecos_core.identity import db
from ecos_core.client import auth_member
from ecos_core.shared import _get_privacy_flags, _record_dm_direction, _rate_limit
from ecos_core.profile import _profile_visibility
from ecos_core.realtime import ws_hub
from key_security import validate_key_upload

MAX_FILE_SIZE = 501 * 1024 * 1024
FILE_TTL_DAYS = 5
DM_FILE_DIR = os.environ.get(
    "GC_DM_FILE_DIR",
    os.path.join(os.environ.get("GC_UPLOADS_DIR", "/opt/ghostchat/uploads"), "dm_files"),
)

router = APIRouter(prefix="/api/chat", tags=["GhostChat"])


def _ensure_chat_file_path_column(c) -> None:
    columns = {row["name"] for row in c.execute("PRAGMA table_info(chat_files)")}
    if "file_path" not in columns:
        try:
            c.execute("ALTER TABLE chat_files ADD COLUMN file_path TEXT")
        except sqlite3.OperationalError:
            columns = {
                row["name"] for row in c.execute("PRAGMA table_info(chat_files)")
            }
            if "file_path" not in columns:
                raise


def _cleanup_expired_dm_files(c) -> None:
    rows = c.execute(
        "SELECT id, file_path FROM chat_files WHERE created_at < datetime('now', ?)",
        (f"-{FILE_TTL_DAYS} day",),
    ).fetchall()
    for row in rows:
        if row["file_path"]:
            try:
                os.remove(row["file_path"])
            except OSError:
                pass
    c.executemany("DELETE FROM chat_files WHERE id=?", [(row["id"],) for row in rows])

class SendBody(BaseModel):
    to_username: str
    ciphertext: Optional[str] = None  # base64; обычный DM уже зашифрован клиентом
    plain_text: Optional[str] = None  # разрешён только для server-identified bot DM


# Production accepts the same envelope size as the mobile client. Keeping the
# limit in one place prevents the HTTP and WS send paths from drifting apart.
MAX_CHAT_CIPHERTEXT_CHARS = 16_000

class KeysUploadBody(BaseModel):
    x25519_pub: str           # base64, 32 байта X25519 или 65 P-256
    encrypted_private_key: Optional[str] = None  # base64, ~60 байт (iv+priv+tag)
    key_salt: Optional[str] = None               # base64, 16 байт (для PBKDF2)
    # Metadata is part of the encrypted-container contract. Older clients do
    # not send it, so both fields stay optional for backward compatibility.
    key_kdf: Optional[str] = None
    key_format: Optional[str] = None
    storage_mode: Optional[str] = None           # 'server' | 'local' | None (сохранить текущий)

class StorageModeBody(BaseModel):
    mode: str  # 'server' или 'local'


class PrivacyBody(BaseModel):
    show_online: Optional[bool] = None
    send_read_receipts: Optional[bool] = None
    allow_channel_add: Optional[bool] = None
    allow_group_add: Optional[bool] = None
    message_privacy: Optional[str] = None
    username_visibility: Optional[str] = None
    display_name_visibility: Optional[str] = None
    avatar_visibility: Optional[str] = None
    banner_visibility: Optional[str] = None
    about_visibility: Optional[str] = None
    music_visibility: Optional[str] = None


_PRIVACY_AUDIENCES = {"all", "contacts", "nobody"}


def _set_privacy_bool(c, field: str, value: Optional[bool], user_id: int) -> None:
    if value is not None:
        c.execute(
            f"UPDATE user_privacy SET {field}=? WHERE user_id=?",
            (1 if value else 0, user_id),
        )


def _set_privacy_choice(c, field: str, value: Optional[str], user_id: int) -> None:
    if value is None:
        return
    normalized = value.strip().lower()
    if normalized not in _PRIVACY_AUDIENCES:
        raise HTTPException(422, f"{field}: допустимы all, contacts или nobody")
    c.execute(
        f"UPDATE user_privacy SET {field}=? WHERE user_id=?",
        (normalized, user_id),
    )


@router.get("/privacy")
def get_privacy(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        return _get_privacy_flags(c, user["id"])
    finally:
        c.close()


@router.post("/privacy")
def set_privacy(body: PrivacyBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"privacy:{user['id']}", limit=60, window=60)
    c = db()
    try:
        c.execute(
            "INSERT OR IGNORE INTO user_privacy (user_id) VALUES (?)",
            (user["id"],),
        )
        if body.show_online is not None:
            c.execute(
                "UPDATE user_privacy SET show_online=? WHERE user_id=?",
                (1 if body.show_online else 0, user["id"]),
            )
        if body.send_read_receipts is not None:
            c.execute(
                "UPDATE user_privacy SET send_read_receipts=? WHERE user_id=?",
                (1 if body.send_read_receipts else 0, user["id"]),
            )
        _set_privacy_bool(c, "allow_channel_add", body.allow_channel_add, user["id"])
        _set_privacy_bool(c, "allow_group_add", body.allow_group_add, user["id"])
        _set_privacy_choice(c, "message_privacy", body.message_privacy, user["id"])
        _set_privacy_choice(c, "username_visibility", body.username_visibility, user["id"])
        _set_privacy_choice(c, "display_name_visibility", body.display_name_visibility, user["id"])
        _set_privacy_choice(c, "avatar_visibility", body.avatar_visibility, user["id"])
        _set_privacy_choice(c, "banner_visibility", body.banner_visibility, user["id"])
        _set_privacy_choice(c, "about_visibility", body.about_visibility, user["id"])
        _set_privacy_choice(c, "music_visibility", body.music_visibility, user["id"])
        c.commit()
        return _get_privacy_flags(c, user["id"])
    finally:
        c.close()

def _is_b64(s: str, expected_len: Optional[int] = None) -> bool:
    if not s or not isinstance(s, str) or len(s) > 4000:
        return False
    try:
        raw = base64.b64decode(s, validate=True)
    except Exception:
        return False
    if expected_len is not None and len(raw) != expected_len:
        return False
    return True

def _get_user_by_username(c, username: str) -> Optional[dict]:
    row = c.execute(
        "SELECT id, username, display_name, x25519_pub FROM users WHERE username=?",
        (username.lower(),),
    ).fetchone()
    return dict(row) if row else None


def _is_blocked(c, first_id: int, second_id: int) -> bool:
    """Блокировка действует в обе стороны: если один из участников
    заблокировал другого, новые DM не принимаются ни от кого."""
    row = c.execute(
        "SELECT 1 FROM chat_blocks "
        "WHERE (owner_id=? AND blocked_id=?) OR (owner_id=? AND blocked_id=?) "
        "LIMIT 1",
        (first_id, second_id, second_id, first_id),
    ).fetchone()
    return row is not None


def _send_message_core(
    *,
    sender_id: int,
    sender_username: str,
    to_username: str,
    ciphertext: str,
    sender_display_name: Optional[str] = None,
    sender_avatar_url: Optional[str] = None,
) -> dict:
    """Persist and fan out one legacy DM.

    This is deliberately synchronous because sqlite3 is synchronous, but the
    WebSocket handler runs it via asyncio.to_thread. Keeping the validation,
    block checks and fanout identical for HTTP and WS avoids two subtly
    different message protocols and removes the DB work from the event loop.
    """
    _rate_limit(f"chatsend:{sender_id}", limit=120, window=60)
    if (
        not isinstance(ciphertext, str)
        or not ciphertext
        or len(ciphertext) > MAX_CHAT_CIPHERTEXT_CHARS
    ):
        raise HTTPException(400, "ciphertext: некорректный формат")
    try:
        if len(base64.b64decode(ciphertext, validate=True)) < 13:
            raise HTTPException(400, "ciphertext: слишком короткий")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(400, "ciphertext: невалидный base64")

    c = db()
    try:
        to_user = _get_user_by_username(c, to_username)
        if not to_user:
            raise HTTPException(404, "Получатель не найден")
        if to_user["id"] == sender_id:
            raise HTTPException(400, "Нельзя отправить сообщение себе")
        if _is_blocked(c, sender_id, to_user["id"]):
            raise HTTPException(403, "Пользователь заблокирован")
        receiver_privacy = _get_privacy_flags(c, to_user["id"])
        message_privacy = receiver_privacy.get("message_privacy", "all")
        if message_privacy == "nobody":
            raise HTTPException(403, "Пользователь запретил ему писать")
        if message_privacy == "contacts":
            contact = c.execute(
                "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
                (to_user["id"], sender_id),
            ).fetchone()
            if not contact:
                raise HTTPException(403, "Писать этому пользователю могут только его контакты")
        if not to_user["x25519_pub"]:
            raise HTTPException(
                400,
                "У получателя ещё нет E2E-ключей — попросите его зайти в /chat",
            )

        sender_row = c.execute(
            "SELECT username, display_name, avatar_url FROM users WHERE id=?",
            (sender_id,),
        ).fetchone()
        sender_name = (
            sender_display_name
            or (sender_row["display_name"] if sender_row else None)
            or sender_username
        )
        sender_avatar = (
            sender_avatar_url
            if sender_avatar_url is not None
            else (sender_row["avatar_url"] if sender_row else None)
        )

        cur = c.execute(
            "INSERT INTO chat_dm (sender_id, receiver_id, text) VALUES (?,?,?)",
            (sender_id, to_user["id"], ciphertext),
        )
        msg_id = cur.lastrowid
        row = c.execute(
            "SELECT created_at FROM chat_dm WHERE id=?", (msg_id,)
        ).fetchone()
        _record_dm_direction(c, sender_id, int(to_user["id"]))
        c.commit()

        payload = {
            "id": msg_id,
            "from_username": sender_username,
            "from_display_name": sender_name,
            "from_avatar_url": sender_avatar,
            "to_username": to_user["username"],
            "ciphertext": ciphertext,
            "created_at": row["created_at"],
        }
        sockets_recv = list(ws_hub._by_uid.get(to_user["id"], ()))
        sockets_send = list(ws_hub._by_uid.get(sender_id, ()))
        sent = bool(sockets_recv)
        import logging as _lg
        _lg.getLogger("gc").info(
            f"[send msg={msg_id}] sender={sender_username} → recv={to_user['username']} | "
            f"ws_sender={len(sockets_send)} ws_recv={len(sockets_recv)}"
        )
        ws_hub.send_to(to_user["id"], "chat.new", payload)
        ws_hub.send_to(sender_id, "chat.echo", payload)
        return {
            "status": "ok",
            "id": msg_id,
            "created_at": row["created_at"],
            "recipient_online": sent,
        }
    except Exception:
        try:
            c.rollback()
        except Exception:
            pass
        raise
    finally:
        c.close()


def _deliver_message(
    c,
    sender: dict,
    to_user: dict,
    ciphertext: Optional[str],
    plain_text: Optional[str],
    reply_markup: Optional[dict] = None,
) -> dict:
    """Compatibility delivery path used by the production bot API.

    Bots intentionally use the legacy readable-text route.  Keep this small
    adapter separate from the E2E-only human send path so the existing bot
    service can import it without weakening normal DM validation.
    """
    text_to_store = plain_text if plain_text is not None else ciphertext
    markup_json = (
        json.dumps(reply_markup, ensure_ascii=False, separators=(",", ":"))
        if reply_markup is not None
        else None
    )
    sender_ava_row = c.execute(
        "SELECT avatar_url FROM users WHERE id=?", (sender["id"],)
    ).fetchone()
    sender_ava = sender_ava_row["avatar_url"] if sender_ava_row else None
    c.execute(
        "INSERT INTO chat_dm (sender_id, receiver_id, text, bot_reply_markup) "
        "VALUES (?,?,?,?)",
        (sender["id"], to_user["id"], text_to_store, markup_json),
    )
    msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    row = c.execute(
        "SELECT created_at FROM chat_dm WHERE id=?", (msg_id,)
    ).fetchone()
    c.commit()
    payload = {
        "id": msg_id,
        "from_username": sender["username"],
        "from_display_name": sender["display_name"],
        "from_avatar_url": sender_ava,
        "to_username": to_user["username"],
        "created_at": row["created_at"],
    }
    if plain_text is not None:
        payload["plain_text"] = plain_text
    else:
        payload["ciphertext"] = ciphertext
    if reply_markup is not None:
        payload["reply_markup"] = reply_markup
    sockets_recv = list(ws_hub._by_uid.get(to_user["id"], ()))
    sockets_send = list(ws_hub._by_uid.get(sender["id"], ()))
    import logging as _lg

    _lg.getLogger("gc").debug(
        "message routed: ws_sender=%d ws_recv=%d",
        len(sockets_send),
        len(sockets_recv),
    )
    ws_hub.send_to(to_user["id"], "chat.new", payload)
    ws_hub.send_to(sender["id"], "chat.echo", payload)
    try:
        from fcm_helper import get_tokens_for_user, send_wake_push

        toks = get_tokens_for_user(c, to_user["id"])
        if toks:
            send_wake_push(toks)
    except Exception as exc:
        _lg.getLogger("gc").warning("FCM push fail: %s", exc)
    return {
        "id": msg_id,
        "created_at": row["created_at"],
        "recipient_online": bool(sockets_recv),
    }


# ─── Multi-device delivery (24h TTL после первого ack'a) ───────────────────────
import json as _mdd_json
import time as _mdd_time
import hashlib as _mdd_hash

_DELIVERY_TTL_SECONDS = 24 * 3600

def _device_id_from_request(x_device_id: Optional[str], authorization: Optional[str]) -> str:
    """Берёт ID устройства из заголовка X-Device-Id, иначе хэш токена.
    Хэш-fallback — для старых клиентов которые ещё не шлют header."""
    if x_device_id and isinstance(x_device_id, str) and 4 <= len(x_device_id) <= 80:
        return x_device_id.strip()
    tok = (authorization or "").removeprefix("Bearer ").strip()
    if tok:
        return "tok:" + _mdd_hash.sha256(tok.encode()).hexdigest()[:24]
    return "anon:" + str(_mdd_time.time())

def _mark_delivered(c, table: str, msg_id: int, device_id: str) -> bool:
    """Помечает сообщение доставленным конкретному устройству.
    Возвращает True если это была ПЕРВАЯ доставка (для chat.delivered к sender'у)."""
    row = c.execute(f"SELECT delivered_to FROM {table} WHERE id=?", (msg_id,)).fetchone()
    if not row:
        return False
    try:
        devs = _mdd_json.loads(row["delivered_to"] or "[]")
        if not isinstance(devs, list):
            devs = []
    except Exception:
        devs = []
    was_empty = len(devs) == 0
    if device_id not in devs:
        devs.append(device_id)
    now = int(_mdd_time.time())
    c.execute(
        f"UPDATE {table} SET delivered_to=?, last_delivery_at=? WHERE id=?",
        (_mdd_json.dumps(devs), now, msg_id),
    )
    return was_empty

def _not_delivered_filter(device_id: str) -> str:
    """SQL-фрагмент: сообщение НЕ доставлено этому device_id.
    Поле delivered_to — JSON-массив; ищем точное вхождение строки."""
    return "(delivered_to IS NULL OR delivered_to NOT LIKE ?)"

def _not_delivered_param(device_id: str) -> str:
    """Параметр к _not_delivered_filter — '%"<device_id>"%'."""
    safe = device_id.replace('%', '').replace('_', '').replace('"', '')
    return f'%"{safe}"%'

@router.post("/keys/upload")
def upload_keys(body: KeysUploadBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"keys:{user['id']}", limit=5, window=3600)
    raw_pub = base64.b64decode(body.x25519_pub) if _is_b64(body.x25519_pub) else b""
    if len(raw_pub) not in (32, 65):
        raise HTTPException(400, "x25519_pub: ожидается 32 (X25519) или 65 (P-256) байт в base64")

    # Определяем режим хранения: явный из body > сохранённый в БД > 'server' (legacy fallback).
    c = db()
    current_mode_row = c.execute(
        "SELECT key_storage_mode FROM users WHERE id=?", (user["id"],)
    ).fetchone()
    saved_mode = current_mode_row["key_storage_mode"] if current_mode_row else None
    mode = (body.storage_mode or saved_mode or "server").lower()
    if mode not in ("server", "local"):
        c.close()
        raise HTTPException(400, "storage_mode: ожидается 'server' или 'local'")

    try:
        checked = validate_key_upload(
            public_key=body.x25519_pub,
            encrypted_private_key=body.encrypted_private_key,
            key_salt=body.key_salt,
            key_kdf=body.key_kdf,
            key_format=body.key_format,
            storage_mode=mode,
        )
    except ValueError as exc:
        c.close()
        raise HTTPException(400, str(exc)) from None

    if mode == "server":
        if not body.encrypted_private_key or not body.key_salt:
            c.close()
            raise HTTPException(400, "В режиме 'server' encrypted_private_key и key_salt обязательны")
        raw = base64.b64decode(body.encrypted_private_key)
        if not _is_b64(body.encrypted_private_key) or len(raw) < 40 or len(raw) > 500:
            c.close()
            raise HTTPException(400, "encrypted_private_key: некорректный формат")
        if not _is_b64(body.key_salt, 16):
            c.close()
            raise HTTPException(400, "key_salt: ожидается 16 байт в base64")
        priv_to_store = body.encrypted_private_key
        salt_to_store = body.key_salt
        kdf_to_store = body.key_kdf
        format_to_store = body.key_format
    else:
        priv_to_store = None
        salt_to_store = None
        kdf_to_store = None
        format_to_store = None

    # Always persist the normalized values returned by the shared validator.
    # The legacy checks above remain for compatibility with this older router,
    # but never get to choose what is written to the database.
    pub_to_store = checked["public_key"]
    priv_to_store = checked["encrypted_private_key"]
    salt_to_store = checked["key_salt"]
    kdf_to_store = checked["key_kdf"]
    format_to_store = checked["key_format"]

    tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
    dev = c.execute(
        "SELECT id, is_owner FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
        (tok, user["id"]),
    ).fetchone()
    if dev:
        c.execute(
            "UPDATE user_devices SET pub_key=? WHERE id=?",
            (body.x25519_pub, dev["id"]),
        )
        # v1: на пару users.x25519_pub смотрят все собеседники через legacy
        c.execute(
            "UPDATE users SET x25519_pub=?, encrypted_private_key=?, key_salt=?, key_kdf=?, key_format=?, in_ghostchat=1, key_storage_mode=? WHERE id=?",
            (pub_to_store, priv_to_store, salt_to_store, kdf_to_store, format_to_store, mode, user["id"]),
        )
    else:
        # Legacy: токен из soc_tokens (старый веб), пишем напрямую в users.
        c.execute(
            "UPDATE users SET x25519_pub=?, encrypted_private_key=?, key_salt=?, key_kdf=?, key_format=?, in_ghostchat=1, key_storage_mode=? WHERE id=?",
            (pub_to_store, priv_to_store, salt_to_store, kdf_to_store, format_to_store, mode, user["id"]),
        )
    c.commit()
    c.close()
    return {
        "status": "ok",
        "storage_mode": mode,
        "has_server_key": bool(priv_to_store and salt_to_store),
        "key_kdf": kdf_to_store,
        "key_format": format_to_store,
    }

@router.get("/keys/me")
def get_my_keys(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT x25519_pub, encrypted_private_key, key_salt, key_kdf, key_format, key_storage_mode FROM users WHERE id=?",
        (user["id"],),
    ).fetchone()
    # TDA-4: список pubkey'ев МОИХ других устройств — для self-echo
    # (когда я отправляю сообщение, шифрую его также под свои другие устройства,
    # чтобы они увидели исходящее).
    tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
    other_devs = c.execute(
        "SELECT pub_key FROM user_devices "
        "WHERE user_id=? AND is_active=1 AND is_blocked=0 AND pub_key IS NOT NULL "
        "AND token != ?",
        (user["id"], tok),
    ).fetchall()
    c.close()

    storage_mode = row["key_storage_mode"] if row else None
    is_local = (storage_mode == "local")
    return {
        "x25519_pub": row["x25519_pub"] if row else None,
        "encrypted_private_key": None if is_local else (row["encrypted_private_key"] if row else None),
        "key_salt": None if is_local else (row["key_salt"] if row else None),
        "key_kdf": None if is_local else (row["key_kdf"] if row else None),
        "key_format": None if is_local else (row["key_format"] if row else None),
        "has_server_key": bool(
            row and row["encrypted_private_key"] and row["key_salt"]
        ),
        "other_device_pubkeys": [d["pub_key"] for d in other_devs],
        "storage_mode": storage_mode,  # 'server' | 'local' | None (не выбрано)
    }

@router.get("/keys/storage_mode")
def get_storage_mode(authorization: Optional[str] = Header(None)):
    """Текущий режим хранения приватника (server/local/None)."""
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT key_storage_mode, x25519_pub, "
        "(encrypted_private_key IS NOT NULL) AS has_server_priv "
        "FROM users WHERE id=?",
        (user["id"],),
    ).fetchone()
    c.close()
    return {
        "mode": row["key_storage_mode"] if row else None,
        "has_pub": bool(row and row["x25519_pub"]),
        "has_server_priv": bool(row and row["has_server_priv"]),
    }


@router.post("/keys/storage_mode")
def set_storage_mode(body: StorageModeBody, authorization: Optional[str] = Header(None)):
    """Сохранить режим хранения. local → серверная копия зануляется; server → needs_upload=true если приватника на сервере нет."""
    user = auth_member(authorization)
    _rate_limit(f"keymode:{user['id']}", limit=10, window=3600)
    mode = (body.mode or "").lower()
    if mode not in ("server", "local"):
        raise HTTPException(400, "mode: ожидается 'server' или 'local'")
    c = db()
    if mode == "local":
        c.execute(
            "UPDATE users SET key_storage_mode='local', encrypted_private_key=NULL, key_salt=NULL, key_kdf=NULL, key_format=NULL WHERE id=?",
            (user["id"],),
        )
        c.commit()
        c.close()
        return {"status": "ok", "mode": "local"}
    else:
        has_priv_row = c.execute(
            "SELECT (encrypted_private_key IS NOT NULL) AS has_priv FROM users WHERE id=?",
            (user["id"],),
        ).fetchone()
        c.execute(
            "UPDATE users SET key_storage_mode='server' WHERE id=?",
            (user["id"],),
        )
        c.commit()
        c.close()
        return {
            "status": "ok",
            "mode": "server",
            "needs_upload": not bool(has_priv_row and has_priv_row["has_priv"]),
        }


@router.delete("/keys/server_copy")
def delete_server_key_copy(authorization: Optional[str] = Header(None)):
    """Удалить серверную копию приватника (режим не меняет — это /storage_mode)."""
    user = auth_member(authorization)
    _rate_limit(f"keywipe:{user['id']}", limit=10, window=3600)
    c = db()
    c.execute(
        "UPDATE users SET encrypted_private_key=NULL, key_salt=NULL, key_kdf=NULL, key_format=NULL WHERE id=?",
        (user["id"],),
    )
    c.commit()
    c.close()
    return {"status": "ok"}


# ── Управление устройствами ─────────────────────────────────────────
# Логика хранения уже есть в device_auth.py (list_user_devices, revoke_device),
# rename пишется здесь. Эндпойнты — под префиксом /api/chat/devices/...

class RenameDeviceBody(BaseModel):
    name: str


@router.get("/devices")
def list_my_devices(authorization: Optional[str] = Header(None)):
    """Все устройства юзера (is_current — текущий по токену)."""
    user = auth_member(authorization)
    import device_auth as _da
    c = db()
    try:
        devs = _da.list_user_devices(c, user["id"])
        tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
        cur = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (tok, user["id"]),
        ).fetchone()
        cur_id = cur["id"] if cur else None
        for d in devs:
            d["is_current"] = (d["id"] == cur_id)
        return {"devices": devs, "current_id": cur_id}
    finally:
        c.close()


@router.post("/devices/{device_pk}/rename")
def rename_my_device(device_pk: int, body: RenameDeviceBody,
                     authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"devrename:{user['id']}", limit=20, window=3600)
    name = (body.name or "").strip()
    if not name:
        raise HTTPException(422, "Имя не может быть пустым")
    if len(name) > 60:
        raise HTTPException(422, "Имя не длиннее 60 символов")
    c = db()
    try:
        r = c.execute(
            "SELECT id FROM user_devices WHERE id=? AND user_id=? LIMIT 1",
            (device_pk, user["id"]),
        ).fetchone()
        if not r:
            raise HTTPException(404, "Устройство не найдено")
        c.execute("UPDATE user_devices SET device_name=? WHERE id=?", (name, r["id"]))
        c.commit()
        return {"status": "ok", "name": name}
    finally:
        c.close()


@router.post("/devices/{device_pk}/revoke")
def revoke_my_device(device_pk: int, authorization: Optional[str] = Header(None)):
    """Отозвать устройство (owner не отзывается — защита в device_auth)."""
    user = auth_member(authorization)
    _rate_limit(f"devrevoke:{user['id']}", limit=20, window=3600)
    import device_auth as _da
    c = db()
    try:
        tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
        cur = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (tok, user["id"]),
        ).fetchone()
        if cur and cur["id"] == device_pk:
            raise HTTPException(400, "Нельзя отозвать текущее устройство — выйдите через «Выход»")
        ok = _da.revoke_device(c, user["id"], device_pk)
        if not ok:
            raise HTTPException(404, "Устройство не найдено")
        try:
            ws_hub.send_to(user["id"], "device.revoked", {"device_pk": device_pk})
        except Exception:
            pass
        return {"status": "ok"}
    finally:
        c.close()


# ── Support admin (закреплённый чат поддержки) ──────────────────────
# Юзер, который получает все сообщения «в поддержку». Хардкодим в коде —
# при необходимости вынесем в config / БД-флаг users.is_support_admin.
SUPPORT_ADMIN_USERNAME = "waki"


@router.get("/support_admin")
def get_support_admin(authorization: Optional[str] = Header(None)):
    """Клиент по этому ответу решает, показывать ли pinned-диалог
    «Поддержка GhostChat» сверху списка чатов."""
    user = auth_member(authorization)
    c = db()
    try:
        r = c.execute(
            "SELECT id, username, display_name, x25519_pub FROM users WHERE username=?",
            (SUPPORT_ADMIN_USERNAME,),
        ).fetchone()
        if not r:
            return {"username": None, "display_name": None, "is_me": False, "pub": None}
        return {
            "username": r["username"],
            "display_name": r["display_name"],
            "x25519_pub": r["x25519_pub"],
            "is_me": user["username"] == r["username"],
        }
    finally:
        c.close()


# ── TDA: Trust Device Authorization ─────────────────────────────────
# Юзер включает требование подтверждать новые устройства с уже доверенного.
# Новое устройство при логине вместо токена получает request_id + 6-значный
# код, и ждёт пока юзер с доверенного устройства этот код введёт.

class TdaToggleBody(BaseModel):
    enabled: bool


class TdaApproveBody(BaseModel):
    code: str


@router.get("/tda")
def get_tda(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    try:
        r = c.execute("SELECT tda_enabled FROM users WHERE id=?", (user["id"],)).fetchone()
        return {"enabled": bool(r and r["tda_enabled"])}
    finally:
        c.close()


@router.post("/tda")
def set_tda(body: TdaToggleBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"tda:{user['id']}", limit=10, window=3600)
    c = db()
    try:
        c.execute("UPDATE users SET tda_enabled=? WHERE id=?",
                  (1 if body.enabled else 0, user["id"]))
        c.commit()
        return {"status": "ok", "enabled": bool(body.enabled)}
    finally:
        c.close()


@router.get("/devices/pending")
def list_pending_logins(authorization: Optional[str] = Header(None)):
    """Pending-логины юзера (для UI на trusted устройстве)."""
    user = auth_member(authorization)
    now_ = int(time.time())
    c = db()
    try:
        rows = c.execute(
            "SELECT request_id, device_id, device_name, phase, "
            "       created_at, expires_at "
            "FROM pending_logins "
            "WHERE username=? AND phase='pending' AND expires_at > ? "
            "ORDER BY created_at DESC",
            (user["username"], now_),
        ).fetchall()
        return {"pending": [dict(r) for r in rows]}
    finally:
        c.close()


@router.post("/devices/pending/{request_id}/approve")
def approve_pending(request_id: str, body: TdaApproveBody,
                    authorization: Optional[str] = Header(None)):
    """Одобрить pending-логин 6-значным кодом."""
    user = auth_member(authorization)
    _rate_limit(f"tda_appr:{user['id']}", limit=30, window=3600)
    import device_auth as _da
    # Импортируем verify_argon2 из social_router/security
    try:
        from security import verify_argon2
    except Exception:
        from ecos_core.shared import verify_argon2
    code = (body.code or "").strip()
    if not code:
        raise HTTPException(422, "Введите код")
    c = db()
    try:
        r = c.execute(
            "SELECT * FROM pending_logins WHERE request_id=? AND username=? LIMIT 1",
            (request_id, user["username"]),
        ).fetchone()
        if not r:
            raise HTTPException(404, "Запрос не найден")
        if r["phase"] != "pending":
            raise HTTPException(409, "Запрос уже обработан")
        if int(r["expires_at"]) < int(time.time()):
            raise HTTPException(410, "Срок запроса истёк")
        if int(r["attempt_count"]) >= 5:
            c.execute("UPDATE pending_logins SET phase='denied' WHERE id=?", (r["id"],))
            c.commit()
            raise HTTPException(429, "Превышен лимит попыток — запрос отклонён")
        if not verify_argon2(code, r["code_hash"]):
            c.execute(
                "UPDATE pending_logins SET attempt_count=attempt_count+1 WHERE id=?",
                (r["id"],),
            )
            c.commit()
            raise HTTPException(401, "Неверный код")
        d = _da.register_device(c, user["id"], r["device_id"], r["device_name"], None, is_owner=False)
        c.execute(
            "UPDATE pending_logins SET phase='approved', granted_token=? WHERE id=?",
            (d["token"], r["id"]),
        )
        c.commit()
        return {"status": "ok"}
    finally:
        c.close()


@router.post("/devices/pending/{request_id}/deny")
def deny_pending(request_id: str, authorization: Optional[str] = Header(None)):
    """Отклонить pending-логин."""
    user = auth_member(authorization)
    _rate_limit(f"tda_deny:{user['id']}", limit=30, window=3600)
    c = db()
    try:
        r = c.execute(
            "SELECT id, phase FROM pending_logins WHERE request_id=? AND username=? LIMIT 1",
            (request_id, user["username"]),
        ).fetchone()
        if not r:
            raise HTTPException(404, "Запрос не найден")
        if r["phase"] != "pending":
            raise HTTPException(409, "Запрос уже обработан")
        c.execute("UPDATE pending_logins SET phase='denied' WHERE id=?", (r["id"],))
        c.commit()
        return {"status": "ok"}
    finally:
        c.close()


@router.get("/devices/pending/{request_id}/status")
def pending_status(request_id: str):
    """Новое устройство долбит этот эндпойнт раз в 1.5-2 сек.
    Без auth — потому что у нового устройства ещё нет токена.
    Защита: request_id — 32 hex, угадать невозможно."""
    c = db()
    try:
        r = c.execute(
            "SELECT phase, granted_token, expires_at FROM pending_logins WHERE request_id=? LIMIT 1",
            (request_id,),
        ).fetchone()
        if not r:
            raise HTTPException(404, "Запрос не найден")
        if r["phase"] == "approved":
            return {"phase": "approved", "token": r["granted_token"]}
        if r["phase"] == "denied":
            return {"phase": "denied"}
        if int(r["expires_at"]) < int(time.time()):
            return {"phase": "expired"}
        return {"phase": "pending"}
    finally:
        c.close()


# ── QR-синхронизация устройств (слепой прокси) ──────────────────────
# Используется когда юзер выбрал режим 'local' и хочет добавить новое
# устройство (или восстановиться после потери приватника на одном из них).
#
# Сервер видит ТОЛЬКО:
#   - короткоживущие ephemeral pubkey'и обоих устройств (для ECDH),
#   - зашифрованный мусор (приватник, упакованный под общий ECDH-секрет),
#   - 8-значный short_code (нужен для ручного ввода).
# Никаких записей в БД — всё в RAM, TTL 3 минуты. После poll-а или TTL —
# сессия удаляется.

import secrets as _secrets
import time as _time
import string as _string
import threading as _threading

_KEYSYNC_TTL = 180  # секунды
_KEYSYNC_MAX_POSTS_PER_SESSION = 6   # 1 ephB_pub + 1 enc_priv + резерв на повтор
_KEYSYNC_MAX_PAYLOAD_LEN = 2000      # base64 chars
_keysync_sessions: dict = {}         # sid -> {ephA_pub, short_code, posts, created_at}
_keysync_by_code: dict = {}          # short_code -> sid
_keysync_lock = _threading.Lock()


def _keysync_gc():
    """Сборка протухших сессий. Зовётся лениво при каждом обращении."""
    now = _time.time()
    expired = []
    for sid, s in list(_keysync_sessions.items()):
        if now - s["created_at"] > _KEYSYNC_TTL:
            expired.append((sid, s.get("short_code")))
    for sid, code in expired:
        _keysync_sessions.pop(sid, None)
        if code:
            _keysync_by_code.pop(code, None)


def _make_short_code() -> str:
    """8 символов из непохожих букв и цифр — без 0/O/1/I/l для разборчивости."""
    alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    code = "".join(_secrets.choice(alphabet) for _ in range(8))
    return code[:4] + "-" + code[4:]  # формат XXXX-XXXX


class KeysyncStartBody(BaseModel):
    eph_pub: str  # base64; ephemeral X25519/P-256 pubkey старого устройства


class KeysyncLookupBody(BaseModel):
    short_code: str


class KeysyncPostBody(BaseModel):
    from_role: str   # 'A' (старое) или 'B' (новое)
    payload: str     # base64 — либо ephB_pub, либо enc_priv, либо служебка


@router.post("/keysync/start")
def keysync_start(body: KeysyncStartBody, authorization: Optional[str] = Header(None)):
    """Старое устройство (А) создаёт канал. Возвращает sid + short_code."""
    user = auth_member(authorization)
    _rate_limit(f"ks_start:{user['id']}", limit=8, window=3600)
    if not _is_b64(body.eph_pub):
        raise HTTPException(400, "eph_pub: ожидается base64")
    raw = base64.b64decode(body.eph_pub)
    if len(raw) not in (32, 65):
        raise HTTPException(400, "eph_pub: ожидается 32 или 65 байт")
    with _keysync_lock:
        _keysync_gc()
        # Чтобы short_code не повторился среди активных сессий
        for _ in range(20):
            code = _make_short_code()
            if code not in _keysync_by_code:
                break
        else:
            raise HTTPException(503, "Не удалось сгенерировать код, попробуйте ещё раз")
        sid = _secrets.token_urlsafe(18)
        _keysync_sessions[sid] = {
            "owner_user_id": user["id"],   # привязка к юзеру — чужой sid в poll не вытянет ничего
            "eph_pub_A": body.eph_pub,
            "short_code": code,
            "posts": [],                   # [{from_role, payload, ts}]
            "created_at": _time.time(),
        }
        _keysync_by_code[code] = sid
    return {"sid": sid, "short_code": code, "ttl": _KEYSYNC_TTL}


@router.post("/keysync/lookup")
def keysync_lookup(body: KeysyncLookupBody, authorization: Optional[str] = Header(None)):
    """Новое устройство (Б) вводит short_code вручную — узнаёт sid и eph_pub_A.
    Не требует чтобы Б был тем же юзером — это намеренно: код для синхронизации
    может быть введён до полноценного логина."""
    auth_member(authorization)  # любой залогиненный (в т.ч. гость) может смотреть
    code = (body.short_code or "").strip().upper().replace(" ", "")
    if "-" not in code and len(code) == 8:
        code = code[:4] + "-" + code[4:]
    with _keysync_lock:
        _keysync_gc()
        sid = _keysync_by_code.get(code)
        if not sid:
            raise HTTPException(404, "Код не найден или истёк")
        s = _keysync_sessions.get(sid)
        if not s:
            raise HTTPException(404, "Сессия не найдена")
        return {"sid": sid, "eph_pub_A": s["eph_pub_A"], "ttl": _KEYSYNC_TTL - int(_time.time() - s["created_at"])}


@router.post("/keysync/{sid}/post")
def keysync_post(sid: str, body: KeysyncPostBody, authorization: Optional[str] = Header(None)):
    """Положить зашифрованный фрагмент в канал. Серверу содержимое непрозрачно."""
    auth_member(authorization)
    if body.from_role not in ("A", "B"):
        raise HTTPException(400, "from_role: ожидается 'A' или 'B'")
    if not body.payload or len(body.payload) > _KEYSYNC_MAX_PAYLOAD_LEN:
        raise HTTPException(400, "payload: пусто или слишком большое")
    if not _is_b64(body.payload):
        raise HTTPException(400, "payload: ожидается base64")
    with _keysync_lock:
        _keysync_gc()
        s = _keysync_sessions.get(sid)
        if not s:
            raise HTTPException(404, "Сессия не найдена или истекла")
        if len(s["posts"]) >= _KEYSYNC_MAX_POSTS_PER_SESSION:
            raise HTTPException(429, "Слишком много фрагментов в сессии")
        s["posts"].append({
            "from_role": body.from_role,
            "payload": body.payload,
            "ts": _time.time(),
        })
        idx = len(s["posts"])
    return {"status": "ok", "index": idx}


@router.get("/keysync/{sid}/poll")
def keysync_poll(sid: str, for_role: str = Query(...), after: int = Query(0),
                 authorization: Optional[str] = Header(None)):
    """Забрать сообщения от другой роли с индексом > after.
    Не long-poll (uvicorn-sync, чтобы не блокировать воркер): клиент сам
    повторяет каждые 1.5-2 секунды. TTL сессии короткий, нагрузка ок."""
    auth_member(authorization)
    if for_role not in ("A", "B"):
        raise HTTPException(400, "for_role: ожидается 'A' или 'B'")
    other = "B" if for_role == "A" else "A"
    with _keysync_lock:
        _keysync_gc()
        s = _keysync_sessions.get(sid)
        if not s:
            raise HTTPException(404, "Сессия не найдена или истекла")
        posts = []
        for i, p in enumerate(s["posts"], start=1):
            if i <= after:
                continue
            if p["from_role"] == other:
                posts.append({"index": i, "payload": p["payload"]})
        ttl_left = _KEYSYNC_TTL - int(_time.time() - s["created_at"])
    return {"posts": posts, "ttl_left": max(0, ttl_left)}


@router.delete("/keysync/{sid}")
def keysync_close(sid: str, authorization: Optional[str] = Header(None)):
    """Явное завершение сессии (юзер закрыл QR-окно)."""
    auth_member(authorization)
    with _keysync_lock:
        s = _keysync_sessions.pop(sid, None)
        if s and s.get("short_code"):
            _keysync_by_code.pop(s["short_code"], None)
    return {"status": "ok"}


@router.get("/keys/{username}")
def get_user_pub_key(username: str, authorization: Optional[str] = Header(None)):
    auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT id, x25519_pub, display_name, avatar_url, is_bot "
        "FROM users WHERE username=?",
        (username.lower(),),
    ).fetchone()
    if not row:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    uid = row["id"]
    bot_status = None
    if bool(row["is_bot"]):
        bot_row = c.execute(
            "SELECT status FROM bots WHERE user_id=? AND is_active=1 LIMIT 1",
            (uid,),
        ).fetchone()
        bot_status = bot_row["status"] if bot_row else "offline"
    dev_rows = c.execute(
        "SELECT device_id, pub_key FROM user_devices "
        "WHERE user_id=? AND is_active=1 AND is_blocked=0 AND pub_key IS NOT NULL",
        (uid,),
    ).fetchall()
    c.close()
    return {
        "username": username.lower(),
        "display_name": row["display_name"],
        "avatar_url": row["avatar_url"],
        "is_bot": bool(row["is_bot"]),
        "bot_status": bot_status,
        "x25519_pub": row["x25519_pub"],
        "device_pubkeys": [d["pub_key"] for d in dev_rows if d["pub_key"]],
    }

@router.post("/send")
async def send_message(body: SendBody, authorization: Optional[str] = Header(None)):
    user = await run_in_threadpool(auth_member, authorization)
    if body.plain_text is not None:
        if body.ciphertext is not None:
            raise HTTPException(422, "Укажите только один формат сообщения")
        # Bot accounts have no user-device E2E keys. Keep the client contract
        # and durable DM queue, but allow readable payloads only after the
        # authoritative bot API verifies that the recipient is a bot.
        from bot_api import send_human_message_to_bot

        return await send_human_message_to_bot(
            user, to_username=body.to_username, text=body.plain_text
        )
    if body.ciphertext is None:
        raise HTTPException(422, "ciphertext обязателен для обычного чата")
    return await asyncio.to_thread(
        _send_message_core,
        sender_id=user["id"],
        sender_username=user["username"],
        to_username=body.to_username,
        ciphertext=body.ciphertext,
        sender_display_name=user.get("display_name"),
        sender_avatar_url=user.get("avatar_url"),
    )

class DeliveryStatusBody(BaseModel):
    ids: list


@router.post("/delivery_status")
def delivery_status(body: DeliveryStatusBody, authorization: Optional[str] = Header(None)):
    """Sender узнаёт статус своих !delivered сообщений после возвращения онлайн.
    Возвращает {id: 'pending'|'delivered'}. Если сообщения нет в chat_dm
    (sender_id=ME) — значит receiver сделал /ack и сервер удалил → delivered.
    """
    user = auth_member(authorization)
    _rate_limit(f"delivstat:{user['id']}", limit=60, window=60)
    if not body.ids or not isinstance(body.ids, list):
        return {}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
    if not ids:
        return {}
    c = db()
    ph = ",".join("?" * len(ids))
    rows = c.execute(
        f"SELECT id, delivered_to FROM chat_dm WHERE sender_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    # Раньше: сообщение в БД → pending; нет → delivered (удалено после ack).
    # Сейчас сообщения живут 24ч после ack'a — смотрим delivered_to.
    pending_ids = set()
    for r in rows:
        try:
            devs = _mdd_json.loads(r["delivered_to"] or "[]")
        except Exception:
            devs = []
        if not devs:
            pending_ids.add(r["id"])
    read_rows = c.execute(
        f"SELECT msg_id FROM chat_dm_read_marks WHERE sender_id=? AND msg_id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    read_ids = {r["msg_id"] for r in read_rows}
    c.close()
    def _status(i):
        if i in pending_ids: return "pending"
        if i in read_ids: return "read"
        return "delivered"
    return {str(i): _status(i) for i in ids}


class AckBody(BaseModel):
    ids: list

# ─── Sealed Sender (DM без sender_id в БД) ──────────────────────────────────

class SendSealedBody(BaseModel):
    to_username: str
    ciphertext: str  # envelope: encrypt(receiver_pub, {type, from_username, text, sid, ts, ...})


@router.post("/send_sealed")
def send_sealed(body: SendSealedBody, authorization: Optional[str] = Header(None)):
    """Sealed-sender: только receiver виден серверу. От кого — внутри ciphertext.
    Сервер не пишет sender_id в БД и не передаёт его в WS."""
    user = auth_member(authorization)
    _rate_limit(f"sealsend:{user['id']}", limit=120, window=60)
    if not body.ciphertext or not _is_b64(body.ciphertext) or len(body.ciphertext) > 16000:
        raise HTTPException(400, "ciphertext: некорректный формат")
    try:
        if len(base64.b64decode(body.ciphertext)) < 13:
            raise HTTPException(400, "ciphertext: слишком короткий")
    except HTTPException: raise
    except Exception:
        raise HTTPException(400, "ciphertext: невалидный base64")
    c = db()
    to_user = _get_user_by_username(c, body.to_username)
    if not to_user:
        c.close()
        raise HTTPException(404, "Получатель не найден")
    if to_user["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя отправить сообщение себе")
    if _is_blocked(c, user["id"], to_user["id"]):
        c.close()
        raise HTTPException(403, "Пользователь заблокирован")
    if not to_user["x25519_pub"]:
        c.close()
        raise HTTPException(400, "У получателя ещё нет E2E-ключей")
    _rate_limit(f"sealpair:{user['id']}:{to_user['id']}", limit=30, window=300)
    now = int(time.time())
    c.execute(
        "INSERT INTO chat_dm_sealed (receiver_id, ciphertext, created_at) VALUES (?,?,?)",
        (to_user["id"], body.ciphertext, now),
    )
    msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    _record_dm_direction(c, int(user["id"]), int(to_user["id"]))
    c.commit()
    sent = False
    for _ws in list(ws_hub._by_uid.get(to_user["id"], ())):
        sent = True
        break
    ws_hub.send_to(to_user["id"], "chat.sealed_new", {
        "id": msg_id,
        "ciphertext": body.ciphertext,
        "created_at": now,
    })
    c.close()
    return {
        "status": "ok",
        "id": msg_id,
        "created_at": now,
        "recipient_online": bool(sent),
    }


@router.get("/pending_sealed")
def pending_sealed(authorization: Optional[str] = Header(None),
                   x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Sealed-сообщения, ещё не доставленные ЭТОМУ устройству."""
    user = auth_member(authorization)
    _rate_limit(f"pendsealed:{user['id']}", limit=30, window=60)
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    rows = c.execute(
        f"SELECT id, ciphertext, created_at FROM chat_dm_sealed "
        f"WHERE receiver_id=? AND {_not_delivered_filter(device_id)} ORDER BY id ASC LIMIT 500",
        (user["id"], _not_delivered_param(device_id)),
    ).fetchall()
    c.close()
    return {
        "messages": [
            {"id": r["id"], "ciphertext": r["ciphertext"], "created_at": r["created_at"]}
            for r in rows
        ]
    }


class AckSealedBody(BaseModel):
    ids: list


@router.post("/ack_sealed")
def ack_sealed(body: AckSealedBody, authorization: Optional[str] = Header(None),
               x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Подтверждение конкретным устройством. Сообщение живёт 24ч после первого ack."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"acked": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
    if not ids:
        return {"acked": 0}
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    ph = ",".join("?" * len(ids))
    rows = c.execute(
        f"SELECT id FROM chat_dm_sealed WHERE receiver_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    for r in rows:
        _mark_delivered(c, "chat_dm_sealed", r["id"], device_id)
    c.commit()
    c.close()
    return {"acked": len(rows), "device_id": device_id[:16]}


@router.post("/ack")
def ack_messages(body: AckBody, authorization: Optional[str] = Header(None),
                 x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Подтверждение получения сообщений конкретным устройством.
    Сообщение НЕ удаляется — живёт 24ч после первого ack чтобы другие
    устройства того же юзера тоже могли получить (cleanup task убирает по TTL)."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"deleted": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
    if not ids:
        return {"deleted": 0}
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    ph = ",".join("?" * len(ids))
    rows = c.execute(
        f"SELECT id, sender_id, delivered_to FROM chat_dm WHERE receiver_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    first_delivery_ids_by_sender = {}
    for r in rows:
        is_first = _mark_delivered(c, "chat_dm", r["id"], device_id)
        if is_first:
            first_delivery_ids_by_sender.setdefault(r["sender_id"], []).append(r["id"])
    c.commit()
    c.close()
    # WS chat.delivered к sender'у — только на ПЕРВУЮ доставку (первое устройство).
    for sender_id, mids in first_delivery_ids_by_sender.items():
        ws_hub.send_to(sender_id, "chat.delivered", {"ids": mids, "by_username": user["username"]})
    return {"acked": len(rows), "device_id": device_id[:16]}


class ReadBody(BaseModel):
    ids: list
    from_username: str   # чьи именно сообщения юзер прочитал

@router.post("/read")
def read_messages(body: ReadBody, authorization: Optional[str] = Header(None)):
    """Клиент сообщает что прочитал сообщения от {from_username}. Бэк ничего не
    хранит (transient) — только пересылает sender'у WS event для синих галочек."""
    user = auth_member(authorization)
    c = db()
    if not _get_privacy_flags(c, user["id"])["send_read_receipts"]:
        c.close()
        return {"sent": 0}
    c.close()
    if not body.ids or not isinstance(body.ids, list):
        return {"sent": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
    if not ids:
        return {"sent": 0}
    sender_uname = (body.from_username or "").strip().lower()
    if not sender_uname:
        return {"sent": 0}
    c = db()
    r = c.execute("SELECT id FROM users WHERE username=?", (sender_uname,)).fetchone()
    if not r:
        c.close()
        return {"sent": 0}
    sender_id = r["id"]
    # Persisting read state: чтобы после refresh sender мог узнать прочитано или
    # нет (WS chat.read мог потеряться). INSERT OR IGNORE — повторный /read той
    # же id не перезапишет first read_at.
    try:
        c.executemany(
            "INSERT OR IGNORE INTO chat_dm_read_marks (sender_id, msg_id, recipient_id) VALUES (?,?,?)",
            [(sender_id, mid, user["id"]) for mid in ids],
        )
        c.commit()
        c.execute("DELETE FROM chat_dm_read_marks WHERE read_at < datetime('now', '-30 day')")
        c.commit()
    except Exception as e:
        pass
    c.close()
    ws_hub.send_to(sender_id, "chat.read", {"ids": ids, "by_username": user["username"]})
    return {"sent": len(ids)}

# ── Contacts ──────────────────────────────────────────────────────────────────
@router.get("/contacts")
def list_contacts(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT u.username, u.display_name, cc.added_at
        FROM chat_contacts cc JOIN users u ON cc.contact_id = u.id
        WHERE cc.owner_id = ?
        ORDER BY u.display_name COLLATE NOCASE
    """, (user["id"],)).fetchall()
    c.close()
    return [{"username": r["username"], "display_name": r["display_name"], "added_at": r["added_at"]} for r in rows]

@router.post("/contacts/{username}")
def add_contact(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"contactadd:{user['id']}", limit=60, window=3600)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    if peer["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя добавить себя")
    c.execute(
        "INSERT OR IGNORE INTO chat_contacts (owner_id, contact_id) VALUES (?,?)",
        (user["id"], peer["id"]),
    )
    c.commit()
    c.close()
    return {"status": "ok", "username": peer["username"], "display_name": peer["display_name"]}

@router.delete("/contacts/{username}")
def del_contact(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"contactdel:{user['id']}", limit=60, window=3600)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    c.execute(
        "DELETE FROM chat_contacts WHERE owner_id=? AND contact_id=?",
        (user["id"], peer["id"]),
    )
    c.commit()
    c.close()
    return {"status": "ok"}


@router.post("/block/{username}")
def block_user(username: str, authorization: Optional[str] = Header(None)):
    """Заблокировать пользователя для DM. Блокировка персональная и
    сохраняется на сервере, чтобы действовать на всех устройствах аккаунта."""
    user = auth_member(authorization)
    _rate_limit(f"chatblock:{user['id']}", limit=30, window=3600)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    if peer["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя заблокировать себя")
    c.execute(
        "INSERT OR IGNORE INTO chat_blocks (owner_id, blocked_id) VALUES (?,?)",
        (user["id"], peer["id"]),
    )
    c.execute(
        "DELETE FROM chat_contacts WHERE owner_id=? AND contact_id=?",
        (user["id"], peer["id"]),
    )
    c.commit()
    c.close()
    return {"status": "ok", "username": peer["username"]}


@router.delete("/block/{username}")
def unblock_user(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"chatunblock:{user['id']}", limit=30, window=3600)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    c.execute(
        "DELETE FROM chat_blocks WHERE owner_id=? AND blocked_id=?",
        (user["id"], peer["id"]),
    )
    c.commit()
    c.close()
    return {"status": "ok", "username": peer["username"]}

@router.delete("/chat/with/{username}")
def delete_chat_with(
    username: str,
    both: bool = False,
    authorization: Optional[str] = Header(None),
):
    """Удалить серверный буфер чата с peer.
    both=False: только МОИ исходящие к нему (которые он ещё не получил)
                + мои read-метки для его сообщений.
    both=True:  обе стороны (его непрочитанные + мои) + WS-сигнал
                peer-у чтобы он удалил локально у себя.

    Сервер не хранит уже-доставленные сообщения (они в IDB у клиента),
    поэтому полное «удалить у всех» работает только пока peer онлайн или
    придёт онлайн в течение цикла. Best effort, как в TG.
    """
    user = auth_member(authorization)
    _rate_limit(f"chatdel:{user['id']}", limit=10, window=60)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        raise HTTPException(404, "Юзер не найден")
    if peer["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя удалить чат с собой")
    deleted_outgoing = 0
    deleted_incoming = 0
    try:
        c.execute(
            "DELETE FROM chat_dm WHERE sender_id=? AND receiver_id=?",
            (user["id"], peer["id"]),
        )
        deleted_outgoing = c.total_changes
        c.execute(
            "DELETE FROM chat_dm_read_marks WHERE sender_id=? AND recipient_id=?",
            (peer["id"], user["id"]),
        )
        if both:
            c.execute(
                "DELETE FROM chat_dm WHERE sender_id=? AND receiver_id=?",
                (peer["id"], user["id"]),
            )
            deleted_incoming = c.total_changes
            c.execute(
                "DELETE FROM chat_dm_read_marks WHERE sender_id=? AND recipient_id=?",
                (user["id"], peer["id"]),
            )
        c.commit()
    finally:
        c.close()
    if both:
        ws_hub.send_to(peer["id"], "chat.cleared_by_peer", {
            "by_username": user["username"],
        })
    return {
        "status": "ok",
        "deleted_outgoing": deleted_outgoing,
        "deleted_incoming": deleted_incoming,
        "notified_peer": both,
    }


@router.get("/users/search")
def search_users(
    q: str,
    authorization: Optional[str] = Header(None),
):
    """Поиск пользователей для чата по username / display_name.
    Отличие от /api/soc/search: всегда возвращает юзеров (не посты ленты),
    игнорирует префикс @, сортирует exact > prefix > contains, помечает
    есть ли у юзера E2E-ключи (можно ли сразу начать чат)."""
    user = auth_member(authorization)
    _rate_limit(f"usearch:{user['id']}", limit=60, window=60)
    term = (q or "").strip().lstrip("@").lower()
    if not term:
        return {"results": []}

    # GhostChat 1.2.1 uses this legacy global-search endpoint. Keep the old
    # user result contract intact, but expose an additive rooms field when
    # the query itself is a GhostChat room link.
    link_rooms = None
    try:
        from room_router_v2 import _resolve_room_link_search

        link_db = db()
        try:
            link_rooms = _resolve_room_link_search(link_db, q, user["id"])
        finally:
            link_db.close()
    except ImportError:
        link_rooms = None
    if link_rooms is not None:
        return {"results": [], "rooms": link_rooms}
    if len(term) > 50:
        term = term[:50]
    c = db()
    like = f"%{term}%"
    rows = c.execute(
        """
        SELECT id, username, display_name, about, avatar_url, banner_config,
               (x25519_pub IS NOT NULL AND x25519_pub != '') AS has_keys
          FROM users
         WHERE LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?
         LIMIT 50
        """,
        (like, like),
    ).fetchall()
    def score(r):
        u = (r["username"] or "").lower()
        d = (r["display_name"] or "").lower()
        if u == term or d == term:
            return 0          # точное совпадение
        if u.startswith(term) or d.startswith(term):
            return 1          # префикс
        return 2              # contains
    sorted_rows = sorted(rows, key=score)[:20]
    visible_rows = []
    for row in sorted(rows, key=score)[:20]:
        profile = _profile_visibility(c, dict(row), user["id"])
        if profile["username"] is None:
            continue
        visible_rows.append((row, profile))
    c.close()
    return {
        "results": [
            {
                "username": profile["username"],
                "display_name": profile["display_name"] or profile["username"],
                "has_keys": bool(r["has_keys"]),
            }
            for r, profile in visible_rows
        ]
    }


@router.get("/contacts/check/{username}")
def check_contact(username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close()
        return {"in_contacts": False}
    r = c.execute(
        "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?",
        (user["id"], peer["id"]),
    ).fetchone()
    c.close()
    return {"in_contacts": r is not None}

@router.get("/unread")
def unread_count(authorization: Optional[str] = Header(None),
                 x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Сколько мне ждёт сообщений (pending) для конкретного устройства."""
    user = auth_member(authorization)
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    row = c.execute(
        f"SELECT COUNT(*) as cnt FROM chat_dm WHERE receiver_id=? "
        f"AND NOT EXISTS (SELECT 1 FROM chat_blocks b WHERE b.owner_id=receiver_id AND b.blocked_id=sender_id) "
        f"AND {_not_delivered_filter(device_id)}",
        (user["id"], _not_delivered_param(device_id))
    ).fetchone()
    c.close()
    return {"count": row["cnt"]}

def _pending_markup_field(raw: Optional[str]) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return {}
    return {"reply_markup": value} if isinstance(value, dict) else {}

def _chat_text_fields(row) -> dict:
    """Expose text only for server-identified bot messages."""
    if row["plain_text"] is not None:
        return {"ciphertext": None, "plain_text": row["plain_text"]}
    return {"ciphertext": row["ciphertext"]}


@router.get("/pending")
def get_pending(authorization: Optional[str] = Header(None),
                x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Все сообщения, ещё не доставленные ЭТОМУ устройству.
    Не удаляет — клиент сам подтвердит через /ack (сообщение проживёт 24ч после
    первого ack чтобы другие устройства того же юзера тоже могли получить)."""
    user = auth_member(authorization)
    _rate_limit(f"pendlegacy:{user['id']}", limit=30, window=60)
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    rows = c.execute(f"""
        SELECT m.id, m.sender_id,
               CASE WHEN b.user_id IS NULL THEN m.text END AS ciphertext,
               CASE WHEN b.user_id IS NOT NULL THEN m.text END AS plain_text,
               m.created_at,
               m.bot_reply_markup,
               u.username as from_username, u.display_name as from_display_name, u.avatar_url as from_avatar_url
        FROM chat_dm m JOIN users u ON u.id = m.sender_id
        LEFT JOIN bots b ON b.user_id = m.sender_id
        WHERE m.receiver_id = ?
          AND NOT EXISTS (
              SELECT 1 FROM chat_blocks b
              WHERE b.owner_id = m.receiver_id AND b.blocked_id = m.sender_id
          )
          AND {_not_delivered_filter(device_id)}
        ORDER BY m.id ASC
        LIMIT 500
    """, (user["id"], _not_delivered_param(device_id))).fetchall()
    c.close()
    return {
        "messages": [
            {
                "id": r["id"],
                "from_username": r["from_username"],
                "from_display_name": r["from_display_name"],
                "from_avatar_url": r["from_avatar_url"],
                "to_username": user["username"],
                **_chat_text_fields(r),
                "created_at": r["created_at"],
                **_pending_markup_field(r["bot_reply_markup"]),
            }
            for r in rows
        ]
    }


@router.get("/history")
def get_history(
    after_id: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=500),
    authorization: Optional[str] = Header(None),
):
    """Return retained encrypted DM history for the authenticated account.

    Delivery queues are device-scoped and therefore cannot restore a chat on a
    new device after another device already acknowledged the messages.  This
    endpoint still returns ciphertext only; all decryption remains on the
    client.  ``after_id`` keeps retries bounded and idempotent.
    """
    user = auth_member(authorization)
    _rate_limit(f"history:{user['id']}", limit=12, window=60)
    c = db()
    rows = c.execute(
        """
        SELECT m.id,
               CASE WHEN b.user_id IS NULL THEN m.text END AS ciphertext,
               CASE WHEN b.user_id IS NOT NULL THEN m.text END AS plain_text,
               m.created_at, m.bot_reply_markup,
               su.username AS from_username,
               su.display_name AS from_display_name,
               su.avatar_url AS from_avatar_url,
               ru.username AS to_username
        FROM chat_dm m
        JOIN users su ON su.id = m.sender_id
        JOIN users ru ON ru.id = m.receiver_id
        LEFT JOIN bots b ON b.user_id = m.sender_id
        WHERE (m.sender_id=? OR m.receiver_id=?) AND m.id>?
        ORDER BY m.id ASC
        LIMIT ?
        """,
        (user["id"], user["id"], after_id, limit),
    ).fetchall()
    c.close()
    return {
        "messages": [
            {
                "id": r["id"],
                "from_username": r["from_username"],
                "from_display_name": r["from_display_name"],
                "from_avatar_url": r["from_avatar_url"],
                "to_username": r["to_username"],
                **_chat_text_fields(r),
                "created_at": r["created_at"],
                **_pending_markup_field(r["bot_reply_markup"]),
            }
            for r in rows
        ],
        "next_after_id": rows[-1]["id"] if rows else after_id,
        "has_more": len(rows) == limit,
    }


@router.get("/history_sealed")
def get_history_sealed(
    after_id: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=500),
    authorization: Optional[str] = Header(None),
):
    """Return retained sealed ciphertext for this account, without metadata."""
    user = auth_member(authorization)
    _rate_limit(f"historysealed:{user['id']}", limit=12, window=60)
    c = db()
    rows = c.execute(
        """
        SELECT id, ciphertext, created_at
        FROM chat_dm_sealed
        WHERE receiver_id=? AND id>?
        ORDER BY id ASC
        LIMIT ?
        """,
        (user["id"], after_id, limit),
    ).fetchall()
    c.close()
    return {
        "messages": [
            {"id": r["id"], "ciphertext": r["ciphertext"], "created_at": r["created_at"]}
            for r in rows
        ],
        "next_after_id": rows[-1]["id"] if rows else after_id,
        "has_more": len(rows) == limit,
    }


# ══════════════════════════════════════════════════════════════════════════════
# E2E FILES — зашифрованные файлы. Сервер видит только ciphertext blob.
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/file/upload")
async def file_upload(
    to_username: str = Form(...),
    blob: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
):
    """Загрузить зашифрованный blob. Клиент шифрует на своей стороне (AES-GCM),
    сервер хранит только ciphertext — не знает имя, тип, содержимое.
    Возвращает file_id, который sender передаёт receiver-у в сообщении (с ключом)."""
    user = await run_in_threadpool(auth_member, authorization)
    _rate_limit(f"fileup:{user['id']}", limit=20, window=3600)
    c = db()
    temp_path = None
    destination = None
    saved = False
    try:
        _ensure_chat_file_path_column(c)
        to_user = _get_user_by_username(c, to_username)
        if not to_user:
            raise HTTPException(404, "Получатель не найден")
        if to_user["id"] == user["id"]:
            raise HTTPException(400, "Нельзя слать себе")
        if _is_blocked(c, user["id"], to_user["id"]):
            raise HTTPException(403, "Пользователь заблокирован")
        privacy = _get_privacy_flags(c, to_user["id"]).get("message_privacy", "all")
        if privacy == "nobody" or (
            privacy == "contacts"
            and not c.execute(
                "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?",
                (to_user["id"], user["id"]),
            ).fetchone()
        ):
            raise HTTPException(403, "Получатель ограничил личные сообщения")

        _cleanup_expired_dm_files(c)
        c.commit()
        total = 0
        os.makedirs(DM_FILE_DIR, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=DM_FILE_DIR, prefix=".dm-upload-", delete=False
        ) as output:
            temp_path = output.name
            while True:
                chunk = await blob.read(64 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_FILE_SIZE:
                    raise HTTPException(
                        413,
                        f"Слишком большой. Максимум {MAX_FILE_SIZE // 1024 // 1024}MB",
                    )
                output.write(chunk)
        if total == 0:
            raise HTTPException(400, "Пустой файл")

        file_token = uuid.uuid4().hex
        destination = os.path.join(DM_FILE_DIR, file_token)
        os.replace(temp_path, destination)
        temp_path = None
        cur = c.execute(
            "INSERT INTO chat_files (sender_id,receiver_id,blob,size,file_path) "
            "VALUES (?,?,?, ?, ?)",
            (user["id"], to_user["id"], b"", total, destination),
        )
        file_id = cur.lastrowid
        c.commit()
        saved = True
        return {"file_id": file_id, "size": total}
    except HTTPException:
        c.rollback()
        raise
    except OSError as error:
        c.rollback()
        raise HTTPException(500, "Не удалось сохранить файл") from error
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()
        if not saved:
            for path in (temp_path, destination):
                if path:
                    try:
                        os.remove(path)
                    except OSError:
                        pass


@router.get("/file/{file_id}")
def file_download(file_id: int, authorization: Optional[str] = Header(None)):
    """Скачать зашифрованный blob. Доступ только sender или receiver."""
    user = auth_member(authorization)
    _rate_limit(f"filedl:{user['id']}", limit=120, window=60)
    c = db()
    _ensure_chat_file_path_column(c)
    _cleanup_expired_dm_files(c)
    c.commit()
    row = c.execute(
        "SELECT sender_id, receiver_id, blob, size, file_path, "
        "(created_at < datetime('now', ?)) AS expired "
        "FROM chat_files WHERE id=?",
        (f"-{FILE_TTL_DAYS} day", file_id),
    ).fetchone()
    c.close()
    if not row:
        raise HTTPException(404, "Файл не найден или удалён")
    if user["id"] not in (row["sender_id"], row["receiver_id"]):
        raise HTTPException(403, "Нет доступа")
    if row["expired"]:
        raise HTTPException(404, "Файл не найден или удалён")
    file_path = row["file_path"]
    if file_path:
        if not os.path.isfile(file_path):
            raise HTTPException(404, "Файл не найден или удалён")
        return FileResponse(
            file_path,
            media_type="application/octet-stream",
            filename="encrypted.bin",
            headers={"Cache-Control": "no-store"},
        )
    return Response(content=row["blob"], media_type="application/octet-stream", headers={
        "Content-Length": str(row["size"]),
        "Cache-Control": "no-store",
    })


@router.post("/file/{file_id}/ack")
def file_ack(file_id: int, authorization: Optional[str] = Header(None)):
    """Receiver подтверждает что скачал файл → сервер удаляет blob."""
    user = auth_member(authorization)
    c = db()
    _ensure_chat_file_path_column(c)
    c.commit()
    row = c.execute(
        "SELECT receiver_id, file_path FROM chat_files WHERE id=?", (file_id,)
    ).fetchone()
    if not row:
        c.close(); return {"deleted": 0}
    if row["receiver_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только получатель может удалить")
    c.execute("DELETE FROM chat_files WHERE id=?", (file_id,))
    c.commit(); c.close()
    if row["file_path"]:
        try:
            os.remove(row["file_path"])
        except OSError:
            pass
    return {"deleted": 1}


# ══════════════════════════════════════════════════════════════════════════════
# GROUPS — групповые чаты с E2E через sender-key схему.
#
# Принцип:
#   1. Sender генерирует случайный AES-256 ключ для каждого сообщения
#   2. Шифрует payload этим ключом → один общий ciphertext
#   3. Шифрует AES для каждого участника через их публичный ECDH-ключ → N envelope_keys
#   4. Backend хранит {ciphertext, envelope_keys: {user_id: enc_key}}
#   5. Каждый получатель расшифровывает свой envelope, потом общий ciphertext
#
# Backend остаётся blind: видит только зашифрованные blob-ы и метаданные кто-кому.
# Каналы (kind='channel') = группы где писать может только owner+admins.
# ══════════════════════════════════════════════════════════════════════════════

class GroupCreateBody(BaseModel):
    name: str
    member_usernames: list = []   # стартовые участники (помимо создателя)
    kind: str = "group"           # 'group' | 'channel'
    is_public: bool = False       # только для kind='channel'; True=открытый, False=по заявкам/E2E

class GroupSendBody(BaseModel):
    ciphertext: str               # base64, общий шифротекст
    envelope_keys: dict           # {user_id_str: base64(encrypted AES key for that user)}

class GroupAckBody(BaseModel):
    ids: list                     # msg id-шники которые юзер успешно сохранил локально


def _is_group_member(c, group_id: int, user_id: int) -> bool:
    r = c.execute(
        "SELECT 1 FROM chat_group_members WHERE group_id=? AND user_id=?",
        (group_id, user_id),
    ).fetchone()
    return r is not None


def _is_group_admin(c, group_id: int, user_id: int) -> bool:
    r = c.execute(
        "SELECT is_admin FROM chat_group_members WHERE group_id=? AND user_id=?",
        (group_id, user_id),
    ).fetchone()
    return bool(r and r["is_admin"])


@router.post("/group/create")
def group_create(body: GroupCreateBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"groupcreate:{user['id']}", limit=10, window=3600)
    name = (body.name or "").strip()
    if not (1 <= len(name) <= 80):
        raise HTTPException(400, "Название: 1-80 символов")
    kind = body.kind if body.kind in ("group", "channel") else "group"
    if not isinstance(body.member_usernames, list) or len(body.member_usernames) > 100:
        raise HTTPException(400, "Слишком много участников (макс 100)")
    c = db()
    own = c.execute(
        "SELECT COUNT(*) as cnt FROM chat_groups WHERE owner_id=?", (user["id"],)
    ).fetchone()
    if own["cnt"] >= 50:
        c.close(); raise HTTPException(400, "Лимит групп исчерпан (50)")
    is_public = 1 if (kind == "channel" and body.is_public) else 0
    c.execute(
        "INSERT INTO chat_groups (name, owner_id, kind, is_public) VALUES (?,?,?,?)",
        (name, user["id"], kind, is_public),
    )
    gid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.execute(
        "INSERT INTO chat_group_members (group_id, user_id, is_admin) VALUES (?,?,1)",
        (gid, user["id"]),
    )
    added = []
    for uname in body.member_usernames:
        if not isinstance(uname, str):
            continue
        peer = _get_user_by_username(c, uname)
        if not peer or peer["id"] == user["id"]:
            continue
        if not peer["x25519_pub"]:
            continue  # не может получать E2E — пропускаем
        c.execute(
            "INSERT OR IGNORE INTO chat_group_members (group_id, user_id) VALUES (?,?)",
            (gid, peer["id"]),
        )
        added.append({"id": peer["id"], "username": peer["username"], "display_name": peer["display_name"]})
    c.commit()
    for m in added:
        ws_hub.send_to(m["id"], "group.added", {"group_id": gid, "name": name, "kind": kind})
    c.close()
    return {"id": gid, "name": name, "kind": kind, "is_public": bool(is_public), "members": added}


@router.get("/group/my")
def group_my(authorization: Optional[str] = Header(None)):
    """Список моих групп с базовой инфой."""
    user = auth_member(authorization)
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
    """, (user["id"],)).fetchall()
    c.close()
    return [
        {
            "id": r["id"],
            "name": r["name"],
            "kind": r["kind"],
            "owner_id": r["owner_id"],
            "username": r["username"],
            "bio": r["bio"],
            "is_public": bool(r["is_public"]),
            "is_admin": bool(r["is_admin"]),
            "is_owner": r["owner_id"] == user["id"],
            "members_count": r["members_count"],
            "created_at": r["created_at"],
        }
        for r in rows
    ]


@router.get("/group/{gid}")
def group_info(gid: int, authorization: Optional[str] = Header(None)):
    """Детали группы: участники + их публичные ключи (нужны для шифрования)."""
    user = auth_member(authorization)
    c = db()
    g = c.execute(
        "SELECT id, name, kind, owner_id, created_at, username, bio, is_public FROM chat_groups WHERE id=?", (gid,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    members = c.execute("""
        SELECT u.id, u.username, u.display_name, u.x25519_pub,
               m.is_admin, m.joined_at
        FROM chat_group_members m JOIN users u ON u.id = m.user_id
        WHERE m.group_id = ?
        ORDER BY m.is_admin DESC, m.joined_at ASC
    """, (gid,)).fetchall()
    c.close()
    return {
        "id": g["id"],
        "name": g["name"],
        "kind": g["kind"],
        "owner_id": g["owner_id"],
        "username": g["username"],
        "bio": g["bio"],
        "is_public": bool(g["is_public"]),
        "created_at": g["created_at"],
        "members": [
            {
                "id": m["id"],
                "username": m["username"],
                "display_name": m["display_name"],
                "x25519_pub": m["x25519_pub"],
                "is_admin": bool(m["is_admin"]),
                "is_owner": m["id"] == g["owner_id"],
                "joined_at": m["joined_at"],
            }
            for m in members
        ],
    }


@router.post("/group/{gid}/members/{username}")
def group_add_member(gid: int, username: str, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    _rate_limit(f"groupadd:{user['id']}", limit=60, window=3600)
    c = db()
    if not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Только админ может добавлять")
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close(); raise HTTPException(404, "Юзер не найден")
    if not peer["x25519_pub"]:
        c.close(); raise HTTPException(400, "У юзера нет E2E-ключей — пусть зайдёт в /chat")
    c.execute(
        "INSERT OR IGNORE INTO chat_group_members (group_id, user_id) VALUES (?,?)",
        (gid, peer["id"]),
    )
    c.commit()
    g = c.execute("SELECT name, kind FROM chat_groups WHERE id=?", (gid,)).fetchone()
    # Соберём членов до закрытия (раньше открывали 2й коннект и не закрывали → leak fd)
    members_uids = [r["user_id"] for r in c.execute(
        "SELECT user_id FROM chat_group_members WHERE group_id=?", (gid,)
    ).fetchall()]
    c.close()
    ws_hub.send_to(peer["id"], "group.added", {"group_id": gid, "name": g["name"], "kind": g["kind"]})
    for uid in members_uids:
        if uid != peer["id"]:
            ws_hub.send_to(uid, "group.members_changed", {"group_id": gid})
    return {"status": "ok", "user": {"id": peer["id"], "username": peer["username"], "display_name": peer["display_name"]}}


@router.delete("/group/{gid}/members/{username}")
def group_remove_member(gid: int, username: str, authorization: Optional[str] = Header(None)):
    """Удалить участника. Может: админ — любого; сам юзер — себя (= покинуть)."""
    user = auth_member(authorization)
    c = db()
    peer = _get_user_by_username(c, username)
    if not peer:
        c.close(); raise HTTPException(404, "Юзер не найден")
    is_self = peer["id"] == user["id"]
    if not is_self and not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Только админ может удалять других")
    g = c.execute("SELECT owner_id, name FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if peer["id"] == g["owner_id"]:
        c.close(); raise HTTPException(400, "Нельзя удалить владельца группы")
    c.execute(
        "DELETE FROM chat_group_members WHERE group_id=? AND user_id=?",
        (gid, peer["id"]),
    )
    c.commit()
    c.close()
    ws_hub.send_to(peer["id"], "group.removed", {"group_id": gid})
    return {"status": "ok"}


@router.delete("/group/{gid}")
def group_delete(gid: int, authorization: Optional[str] = Header(None)):
    """Удалить группу полностью. Только owner."""
    user = auth_member(authorization)
    c = db()
    g = c.execute("SELECT owner_id FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if g["owner_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только владелец может удалить группу")
    # Соберём всех участников чтобы оповестить
    members = [r["user_id"] for r in c.execute(
        "SELECT user_id FROM chat_group_members WHERE group_id=?", (gid,)
    ).fetchall()]
    c.execute("DELETE FROM chat_group_messages WHERE group_id=?", (gid,))
    c.execute("DELETE FROM chat_group_members WHERE group_id=?", (gid,))
    c.execute("DELETE FROM chat_groups WHERE id=?", (gid,))
    c.commit(); c.close()
    for uid in members:
        ws_hub.send_to(uid, "group.removed", {"group_id": gid})
    return {"status": "ok"}


@router.post("/group/{gid}/send")
def group_send(gid: int, body: GroupSendBody, authorization: Optional[str] = Header(None)):
    """Отправить сообщение в группу.
    Клиент шифрует payload общим AES-ключом → ciphertext,
    затем шифрует этот AES для каждого участника → envelope_keys.
    """
    import json as _json
    user = auth_member(authorization)
    _rate_limit(f"groupsend:{user['id']}", limit=120, window=60)
    if not _is_b64(body.ciphertext) or len(body.ciphertext) > 16000:
        raise HTTPException(400, "ciphertext: некорректный формат или > 16KB")
    if not isinstance(body.envelope_keys, dict):
        raise HTTPException(400, "envelope_keys: обязательно (dict)")
    if len(body.envelope_keys) > 200:
        raise HTTPException(400, "Слишком много envelope_keys")
    for uid_str, ek in body.envelope_keys.items():
        if not isinstance(ek, str) or len(ek) > 600 or not _is_b64(ek):
            raise HTTPException(400, f"envelope_keys[{uid_str}]: некорректный")
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    g = c.execute("SELECT kind, owner_id, name FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if g["kind"] == "channel" and not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "В канале писать могут только админы")
    members = [r["user_id"] for r in c.execute(
        "SELECT user_id FROM chat_group_members WHERE group_id=?", (gid,)
    ).fetchall()]
    recipients = [uid for uid in members if uid != user["id"]]
    keys_int = {int(k): v for k, v in body.envelope_keys.items() if str(k).lstrip('-').isdigit()}
    missing = [uid for uid in recipients if uid not in keys_int]
    if missing:
        c.close()
        raise HTTPException(400, f"envelope_keys не покрывают всех получателей: missing {missing}")
    envelope_json = _json.dumps({str(k): v for k, v in keys_int.items()}, ensure_ascii=False)
    c.execute(
        "INSERT INTO chat_group_messages (group_id, sender_id, ciphertext, envelope_keys) VALUES (?,?,?,?)",
        (gid, user["id"], body.ciphertext, envelope_json),
    )
    msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    row = c.execute("SELECT created_at FROM chat_group_messages WHERE id=?", (msg_id,)).fetchone()
    c.commit()
    payload = {
        "id": msg_id,
        "group_id": gid,
        "sender_id": user["id"],
        "from_username": user["username"],
        "from_display_name": user["display_name"],
        "ciphertext": body.ciphertext,
        "envelope_keys": {str(k): v for k, v in keys_int.items()},
        "created_at": row["created_at"],
    }
    for uid in recipients:
        per_user = dict(payload)
        per_user["envelope_keys"] = {str(uid): keys_int[uid]}
        ws_hub.send_to(uid, "group.new", per_user)
    echo = dict(payload)
    echo["envelope_keys"] = {}  # себе envelope не нужен, шифровка дешифруется на стороне sender-а из локального AES-кэша
    ws_hub.send_to(user["id"], "group.echo", echo)
    if not recipients:
        c.execute("DELETE FROM chat_group_messages WHERE id=?", (msg_id,))
        c.commit()
    c.close()
    return {"status": "ok", "id": msg_id, "created_at": row["created_at"]}


@router.get("/group/{gid}/pending")
def group_pending(gid: int, authorization: Optional[str] = Header(None),
                  x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Сообщения в группе, ещё не доставленные ЭТОМУ устройству."""
    import json as _json
    user = auth_member(authorization)
    _rate_limit(f"grouppend:{user['id']}:{gid}", limit=20, window=60)
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    rows = c.execute(f"""
        SELECT m.id, m.sender_id, m.ciphertext, m.envelope_keys, m.created_at,
               u.username as from_username, u.display_name as from_display_name
        FROM chat_group_messages m
        JOIN users u ON u.id = m.sender_id
        WHERE m.group_id = ? AND m.sender_id <> ? AND {_not_delivered_filter(device_id)}
        ORDER BY m.id ASC
        LIMIT 500
    """, (gid, user["id"], _not_delivered_param(device_id))).fetchall()
    c.close()
    out = []
    for r in rows:
        try:
            envs = _json.loads(r["envelope_keys"])
        except Exception:
            envs = {}
        my_env = envs.get(str(user["id"]))
        if not my_env:
            continue  # для меня шифровки нет — пропускаем (странно, но защитимся)
        out.append({
            "id": r["id"],
            "group_id": gid,
            "sender_id": r["sender_id"],
            "from_username": r["from_username"],
            "from_display_name": r["from_display_name"],
            "ciphertext": r["ciphertext"],
            "envelope_keys": {str(user["id"]): my_env},
            "created_at": r["created_at"],
        })
    return {"messages": out}


@router.post("/group/{gid}/ack")
def group_ack(gid: int, body: GroupAckBody, authorization: Optional[str] = Header(None),
              x_device_id: Optional[str] = Header(None, alias="X-Device-Id")):
    """Подтвердить получение сообщений конкретным устройством.
    Сообщения НЕ удаляются — живут 24ч после первого ack (любого устройства)
    чтобы все устройства всех участников успели получить.
    Cleanup task убирает по TTL."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"acked": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
    if not ids:
        return {"acked": 0}
    device_id = _device_id_from_request(x_device_id, authorization)
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    ph = ",".join("?" * len(ids))
    valid_ids = {r["id"] for r in c.execute(
        f"SELECT id FROM chat_group_messages WHERE group_id=? AND id IN ({ph})",
        [gid] + ids,
    ).fetchall()}
    ids = [i for i in ids if i in valid_ids]
    if not ids:
        c.close(); return {"acked": 0}
    for mid in ids:
        _mark_delivered(c, "chat_group_messages", mid, device_id)
        c.execute(
            "INSERT OR IGNORE INTO chat_group_acks (user_id, msg_id) VALUES (?,?)",
            (user["id"], mid),
        )
    c.commit(); c.close()
    return {"acked": len(ids)}


# ══════════════════════════════════════════════════════════════════════════════
# GROUPS/CHANNELS — Фаза 1: теги, bio, публичность
# ══════════════════════════════════════════════════════════════════════════════
import re
_USERNAME_RE = re.compile(r"^[a-z0-9_]{3,20}$")


class GroupUsernameBody(BaseModel):
    username: str

class GroupBioBody(BaseModel):
    bio: str

class GroupVisibilityBody(BaseModel):
    is_public: bool


def _check_username_collision(c, username: str, exclude_group_id: Optional[int] = None) -> Optional[str]:
    """Возвращает 'user' / 'soc_username' / 'group' если занято, иначе None.
    Глобальный namespace: users + soc_usernames + chat_groups."""
    r1 = c.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone()
    if r1:
        return "user"
    r2 = c.execute("SELECT 1 FROM soc_usernames WHERE username=?", (username,)).fetchone()
    if r2:
        return "soc_username"
    if exclude_group_id is not None:
        r3 = c.execute("SELECT 1 FROM chat_groups WHERE username=? AND id<>?",
                       (username, exclude_group_id)).fetchone()
    else:
        r3 = c.execute("SELECT 1 FROM chat_groups WHERE username=?", (username,)).fetchone()
    if r3:
        return "group"
    return None


@router.post("/group/{gid}/username")
def group_set_username(gid: int, body: GroupUsernameBody, authorization: Optional[str] = Header(None)):
    """Установить/изменить @тег группы или канала. Только owner.
    Глобально уникальный namespace (общий с юзерами)."""
    user = auth_member(authorization)
    _rate_limit(f"gruname:{user['id']}", limit=10, window=3600)
    new_name = (body.username or "").strip().lower().lstrip("@")
    if not _USERNAME_RE.match(new_name):
        raise HTTPException(400, "Тег: 3-20 символов, только a-z0-9_")
    c = db()
    g = c.execute("SELECT owner_id, username FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if g["owner_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только владелец может менять тег")
    if g["username"] == new_name:
        c.close(); return {"status": "ok", "username": new_name, "unchanged": True}
    clash = _check_username_collision(c, new_name, exclude_group_id=gid)
    if clash:
        c.close(); raise HTTPException(409, f"Тег @{new_name} уже занят ({clash})")
    c.execute("UPDATE chat_groups SET username=? WHERE id=?", (new_name, gid))
    c.commit(); c.close()
    return {"status": "ok", "username": new_name}


@router.post("/group/{gid}/bio")
def group_set_bio(gid: int, body: GroupBioBody, authorization: Optional[str] = Header(None)):
    """Установить био канала/группы. Только owner. Максимум 300 символов."""
    user = auth_member(authorization)
    _rate_limit(f"grbio:{user['id']}", limit=30, window=3600)
    bio = (body.bio or "").strip()[:300]
    c = db()
    g = c.execute("SELECT owner_id FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if g["owner_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только владелец может менять био")
    c.execute("UPDATE chat_groups SET bio=? WHERE id=?", (bio or None, gid))
    c.commit(); c.close()
    return {"status": "ok", "bio": bio}


@router.post("/group/{gid}/visibility")
def group_set_visibility(gid: int, body: GroupVisibilityBody, authorization: Optional[str] = Header(None)):
    """Поменять public ↔ private (только для каналов, только owner).
    Логика истории: при смене сообщения НЕ перешифровываются. Старые юзеры
    видят свою историю, новые — только сообщения с момента когда стали участниками."""
    user = auth_member(authorization)
    _rate_limit(f"grvis:{user['id']}", limit=5, window=3600)
    c = db()
    g = c.execute("SELECT owner_id, kind, is_public FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    if g["owner_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только владелец может менять видимость")
    if g["kind"] != "channel":
        c.close(); raise HTTPException(400, "Видимость можно менять только у канала")
    new_val = 1 if body.is_public else 0
    if g["is_public"] == new_val:
        c.close(); return {"status": "ok", "is_public": bool(new_val), "unchanged": True}
    c.execute("UPDATE chat_groups SET is_public=? WHERE id=?", (new_val, gid))
    c.commit(); c.close()
    return {"status": "ok", "is_public": bool(new_val)}


class GroupJoinRequestBody(BaseModel):
    pass  # пустое тело — endpoint berёт user из auth, group_id из path


class ChannelPublishBody(BaseModel):
    text: str  # открытый текст для GS-поста (НЕ зашифрован)


@router.post("/group/{gid}/publish_to_gs")
def group_publish_to_gs(gid: int, body: ChannelPublishBody, authorization: Optional[str] = Header(None)):
    """Опубликовать сообщение от имени канала как пост в GhostSocial.
    Только публичные каналы (приватные = E2E, не для общего доступа).
    Только админ/owner канала. Создаёт обычный пост с source_channel_id."""
    user = auth_member(authorization)
    _rate_limit(f"chpub:{user['id']}", limit=60, window=3600)
    text = (body.text or "").strip()
    if not text:
        raise HTTPException(400, "Текст обязателен")
    if len(text) > 1000:
        raise HTTPException(400, "До 1000 символов")
    c = db()
    g = c.execute(
        "SELECT id, name, kind, is_public, owner_id, username FROM chat_groups WHERE id=?",
        (gid,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Канал не найден")
    if g["kind"] != "channel":
        c.close(); raise HTTPException(400, "Только каналы могут публиковать в GS")
    if not g["is_public"]:
        c.close(); raise HTTPException(403, "Только публичные каналы могут публиковать")
    if not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Только админ канала")
    import time as _t
    now_ts = int(_t.time())
    c.execute(
        "INSERT INTO soc_posts (user_id, content, media, activity, activity_set_at, automod_source, source_channel_id) "
        "VALUES (?,?,?,500,?,?,?)",
        (g["owner_id"], text, None, now_ts, 'channel_publish', gid),
    )
    post_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.execute(
        "INSERT INTO soc_activity_log (post_id, old_activity, new_activity, delta, source, actor_id, note, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (post_id, None, 500, 500, 'channel_publish', user["id"],
         f"channel #{gid} @{g['username'] or g['name']}", now_ts),
    )
    c.commit(); c.close()
    try:
        ws_hub.broadcast("post.new", {"post_id": post_id, "from_channel": True})
    except Exception: pass
    return {"status": "ok", "post_id": post_id}


@router.post("/group/{gid}/join_request")
def group_join_request(gid: int, authorization: Optional[str] = Header(None)):
    """Подать заявку на вступление в приватный канал/группу."""
    user = auth_member(authorization)
    c = db()
    g = c.execute(
        "SELECT id, name, kind, is_public, owner_id FROM chat_groups WHERE id=?", (gid,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Не найдено")
    if _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(409, "Вы уже участник")
    if g["kind"] == "channel" and g["is_public"]:
        _rate_limit(f"pjoin:{user['id']}", limit=100, window=1800)
        c.execute(
            "INSERT INTO chat_group_members (group_id, user_id) VALUES (?,?)",
            (gid, user["id"]),
        )
        c.commit()
        c.close()
        return {"status": "joined", "auto": True}
    _rate_limit(f"prjoin:{user['id']}", limit=20, window=1800)
    existing = c.execute(
        "SELECT id FROM chat_group_join_requests WHERE group_id=? AND user_id=? AND status='pending'",
        (gid, user["id"])
    ).fetchone()
    if existing:
        c.close(); raise HTTPException(409, "Заявка уже отправлена")
    now = int(time.time())
    c.execute(
        "INSERT INTO chat_group_join_requests (group_id, user_id, created_at, status) "
        "VALUES (?,?,?,'pending')",
        (gid, user["id"], now),
    )
    c.commit()
    admins = c.execute(
        "SELECT user_id FROM chat_group_members WHERE group_id=? AND (is_admin=1 OR user_id=?)",
        (gid, g["owner_id"])
    ).fetchall()
    c.close()
    for a in admins:
        try:
            ws_hub.send_to(a["user_id"], "group.join_request",
                          {"group_id": gid, "user_id": user["id"], "username": user["username"]})
        except Exception: pass
    return {"status": "pending", "auto": False}


@router.get("/group/{gid}/join_requests")
def group_join_requests_list(gid: int, authorization: Optional[str] = Header(None)):
    """Список pending-заявок (для админов группы)."""
    user = auth_member(authorization)
    c = db()
    if not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Только админ группы")
    rows = c.execute("""
        SELECT r.id, r.user_id, r.created_at,
               u.username, u.display_name
        FROM chat_group_join_requests r
        JOIN users u ON u.id = r.user_id
        WHERE r.group_id=? AND r.status='pending'
        ORDER BY r.created_at ASC
    """, (gid,)).fetchall()
    c.close()
    return [dict(r) for r in rows]


@router.post("/group/{gid}/join_requests/{req_id}/decide")
def group_join_request_decide(gid: int, req_id: int, body: dict, authorization: Optional[str] = Header(None)):
    """Админ группы принимает или отклоняет заявку."""
    user = auth_member(authorization)
    accept = bool(body.get("accept"))
    c = db()
    if not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Только админ группы")
    req = c.execute(
        "SELECT id, user_id, group_id, status FROM chat_group_join_requests WHERE id=? AND group_id=?",
        (req_id, gid)
    ).fetchone()
    if not req:
        c.close(); raise HTTPException(404, "Заявка не найдена")
    if req["status"] != "pending":
        c.close(); raise HTTPException(400, "Заявка уже обработана")
    now = int(time.time())
    new_status = "accepted" if accept else "rejected"
    c.execute(
        "UPDATE chat_group_join_requests SET status=?, reviewed_by=?, reviewed_at=? WHERE id=?",
        (new_status, user["id"], now, req_id),
    )
    if accept:
        c.execute(
            "INSERT OR IGNORE INTO chat_group_members (group_id, user_id) VALUES (?,?)",
            (gid, req["user_id"]),
        )
    c.commit()
    g = c.execute("SELECT name, kind FROM chat_groups WHERE id=?", (gid,)).fetchone()
    c.close()
    try:
        ws_hub.send_to(req["user_id"], "group.join_decided", {
            "group_id": gid, "accepted": accept,
            "name": g["name"] if g else "?", "kind": g["kind"] if g else "?"
        })
        if accept:
            ws_hub.send_to(req["user_id"], "group.added", {
                "group_id": gid, "name": g["name"] if g else "?", "kind": g["kind"] if g else "?"
            })
    except Exception: pass
    return {"status": "ok", "accepted": accept}


@router.get("/group/by_tag/{tag}")
def group_by_tag(tag: str, authorization: Optional[str] = Header(None)):
    """Найти группу/канал по @тегу. Публичная инфа (любой авторизованный)."""
    auth_member(authorization)
    tag = tag.strip().lower().lstrip("@")
    if not tag:
        raise HTTPException(400, "Пустой тег")
    c = db()
    g = c.execute("""
        SELECT id, name, kind, owner_id, username, bio, is_public, created_at,
               (SELECT COUNT(*) FROM chat_group_members WHERE group_id=chat_groups.id) as members_count
        FROM chat_groups WHERE username=?
    """, (tag,)).fetchone()
    c.close()
    if not g:
        raise HTTPException(404, "Не найдено")
    return {
        "id": g["id"],
        "name": g["name"],
        "kind": g["kind"],
        "username": g["username"],
        "bio": g["bio"],
        "is_public": bool(g["is_public"]),
        "members_count": g["members_count"],
        "created_at": g["created_at"],
    }
