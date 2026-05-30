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
from pydantic import BaseModel
from typing import Optional
import base64, time

from social_router import auth_member, db, ws_hub, _rate_limit

# Лимиты по плану Premium (см. https://t.me/waki_one):
#   Base (без премиума): ЛС 100 MB, группы/каналы 50 MB
#   Premium: ЛС 500 MB, группы 200 MB (×5 base)
# Сейчас premium-проверка не реализована — используем base ЛС лимит.
# nginx должен быть >= 110M (сейчас 55M — надо поднять, см. ниже).
MAX_FILE_SIZE = 100 * 1024 * 1024
FILE_TTL_DAYS = 7

router = APIRouter(prefix="/api/chat", tags=["GhostChat"])

# ── Models ──
class SendBody(BaseModel):
    to_username: str
    ciphertext: str  # base64; клиент уже зашифровал

class KeysUploadBody(BaseModel):
    x25519_pub: str           # base64, 32 байта
    encrypted_private_key: str  # base64, ~60 байт (iv+priv+tag)
    key_salt: str             # base64, 16 байт (для PBKDF2)

# ── Helpers ──
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

# ── Keys management (E2E) ──
@router.post("/keys/upload")
def upload_keys(body: KeysUploadBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # Аплоад ключей — редкая операция (1 раз при первом входе, иногда при ротации).
    # 5 в час хватит даже на смену пароля; даже с украденным токеном атакующий
    # не сможет тихо подменить pubkey массово.
    _rate_limit(f"keys:{user['id']}", limit=5, window=3600)
    # 32 для X25519, 65 для P-256 ECDH (web-клиент использует P-256 для совместимости со всеми браузерами)
    raw_pub = base64.b64decode(body.x25519_pub) if _is_b64(body.x25519_pub) else b""
    if len(raw_pub) not in (32, 65):
        raise HTTPException(400, "x25519_pub: ожидается 32 (X25519) или 65 (P-256) байт в base64")
    raw = base64.b64decode(body.encrypted_private_key)
    if not _is_b64(body.encrypted_private_key) or len(raw) < 40 or len(raw) > 500:
        raise HTTPException(400, "encrypted_private_key: некорректный формат")
    if not _is_b64(body.key_salt, 16):
        raise HTTPException(400, "key_salt: ожидается 16 байт в base64")
    c = db()
    c.execute(
        "UPDATE users SET x25519_pub=?, encrypted_private_key=?, key_salt=?, in_ghostchat=1 WHERE id=?",
        (body.x25519_pub, body.encrypted_private_key, body.key_salt, user["id"]),
    )
    c.commit()
    c.close()
    return {"status": "ok"}

@router.get("/keys/me")
def get_my_keys(authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT x25519_pub, encrypted_private_key, key_salt FROM users WHERE id=?",
        (user["id"],),
    ).fetchone()
    c.close()
    return {
        "x25519_pub": row["x25519_pub"] if row else None,
        "encrypted_private_key": row["encrypted_private_key"] if row else None,
        "key_salt": row["key_salt"] if row else None,
    }

@router.get("/keys/{username}")
def get_user_pub_key(username: str, authorization: Optional[str] = Header(None)):
    auth_member(authorization)
    c = db()
    row = c.execute("SELECT x25519_pub FROM users WHERE username=?", (username.lower(),)).fetchone()
    c.close()
    if not row:
        raise HTTPException(404, "Юзер не найден")
    return {"username": username.lower(), "x25519_pub": row["x25519_pub"]}

# ── Messaging (transient — хранится только до доставки) ──
@router.post("/send")
def send_message(body: SendBody, authorization: Optional[str] = Header(None)):
    user = auth_member(authorization)
    # 120 сообщений в минуту — даже самый активный чат укладывается.
    _rate_limit(f"chatsend:{user['id']}", limit=120, window=60)
    if not _is_b64(body.ciphertext) or len(body.ciphertext) > 8000:
        raise HTTPException(400, "ciphertext: некорректный формат")
    c = db()
    to_user = _get_user_by_username(c, body.to_username)
    if not to_user:
        c.close()
        raise HTTPException(404, "Получатель не найден")
    if to_user["id"] == user["id"]:
        c.close()
        raise HTTPException(400, "Нельзя отправить сообщение себе")
    if not to_user["x25519_pub"]:
        c.close()
        raise HTTPException(400, "У получателя ещё нет E2E-ключей — попросите его зайти в /chat")

    c.execute(
        "INSERT INTO chat_dm (sender_id, receiver_id, text) VALUES (?,?,?)",
        (user["id"], to_user["id"], body.ciphertext),
    )
    msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    row = c.execute("SELECT created_at FROM chat_dm WHERE id=?", (msg_id,)).fetchone()
    c.commit()
    payload = {
        "id": msg_id,
        "from_username": user["username"],
        "from_display_name": user["display_name"],
        "to_username": to_user["username"],
        "ciphertext": body.ciphertext,
        "created_at": row["created_at"],
    }
    # Real-time доставка получателю — если онлайн, отправляем и тут же удаляем
    sent = False
    for ws in list(ws_hub._by_uid.get(to_user["id"], ())):
        sent = True
        break
    ws_hub.send_to(to_user["id"], "chat.new", payload)
    # Echo отправителю — он не из БД получает, а сразу отображает
    ws_hub.send_to(user["id"], "chat.echo", payload)
    if sent:
        # Получатель онлайн — стираем pending сразу. Если WS-send в очереди дойдёт после — это OK,
        # т.к. payload уже в JSON в очереди отправки. Если WS отвалится между — клиент получит через /pending при reconnect (но мы уже удалили!).
        # Поэтому стираем только при явном ack от клиента. На пока — не стираем здесь, удалим по /ack.
        pass
    c.close()
    return {"status": "ok", "id": msg_id, "created_at": row["created_at"]}

class AckBody(BaseModel):
    ids: list

@router.post("/ack")
def ack_messages(body: AckBody, authorization: Optional[str] = Header(None)):
    """Клиент подтверждает что получил и сохранил сообщения локально. Сервер их удаляет."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"deleted": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
    if not ids:
        return {"deleted": 0}
    c = db()
    ph = ",".join("?" * len(ids))
    # Удаляем только те, что адресованы этому юзеру
    c.execute(f"DELETE FROM chat_dm WHERE receiver_id=? AND id IN ({ph})", [user["id"]] + ids)
    deleted = c.total_changes
    c.commit()
    c.close()
    return {"deleted": deleted}

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
def unread_count(authorization: Optional[str] = Header(None)):
    """Сколько мне ждёт сообщений (pending). После ack они удалятся → станет 0."""
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT COUNT(*) as cnt FROM chat_dm WHERE receiver_id=?", (user["id"],)
    ).fetchone()
    c.close()
    return {"count": row["cnt"]}

@router.get("/pending")
def get_pending(authorization: Optional[str] = Header(None)):
    """Все накопленные мне сообщения (НЕ удаляет — клиент сам подтвердит через /ack).
    Используется при login/reconnect когда мог пропустить что-то."""
    user = auth_member(authorization)
    c = db()
    rows = c.execute("""
        SELECT m.id, m.sender_id, m.text as ciphertext, m.created_at,
               u.username as from_username, u.display_name as from_display_name
        FROM chat_dm m JOIN users u ON u.id = m.sender_id
        WHERE m.receiver_id = ?
        ORDER BY m.id ASC
        LIMIT 500
    """, (user["id"],)).fetchall()
    c.close()
    return {
        "messages": [
            {
                "id": r["id"],
                "from_username": r["from_username"],
                "from_display_name": r["from_display_name"],
                "to_username": user["username"],
                "ciphertext": r["ciphertext"],
                "created_at": r["created_at"],
            }
            for r in rows
        ]
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
    user = auth_member(authorization)
    _rate_limit(f"fileup:{user['id']}", limit=20, window=3600)
    data = await blob.read()
    if not data:
        raise HTTPException(400, "Пустой файл")
    if len(data) > MAX_FILE_SIZE:
        raise HTTPException(413, f"Слишком большой. Максимум {MAX_FILE_SIZE // 1024 // 1024}MB")
    c = db()
    to_user = _get_user_by_username(c, to_username)
    if not to_user:
        c.close(); raise HTTPException(404, "Получатель не найден")
    if to_user["id"] == user["id"]:
        c.close(); raise HTTPException(400, "Нельзя слать себе")
    # Cleanup просроченных файлов оппортунистически (не блокируем upload)
    c.execute("DELETE FROM chat_files WHERE created_at < datetime('now', ?)",
              (f"-{FILE_TTL_DAYS} day",))
    c.execute(
        "INSERT INTO chat_files (sender_id, receiver_id, blob, size) VALUES (?,?,?,?)",
        (user["id"], to_user["id"], data, len(data)),
    )
    file_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.commit(); c.close()
    return {"file_id": file_id, "size": len(data)}


@router.get("/file/{file_id}")
def file_download(file_id: int, authorization: Optional[str] = Header(None)):
    """Скачать зашифрованный blob. Доступ только sender или receiver."""
    user = auth_member(authorization)
    c = db()
    row = c.execute(
        "SELECT sender_id, receiver_id, blob, size FROM chat_files WHERE id=?",
        (file_id,),
    ).fetchone()
    c.close()
    if not row:
        raise HTTPException(404, "Файл не найден или удалён")
    if user["id"] not in (row["sender_id"], row["receiver_id"]):
        raise HTTPException(403, "Нет доступа")
    return Response(content=row["blob"], media_type="application/octet-stream", headers={
        "Content-Length": str(row["size"]),
        "Cache-Control": "no-store",
    })


@router.post("/file/{file_id}/ack")
def file_ack(file_id: int, authorization: Optional[str] = Header(None)):
    """Receiver подтверждает что скачал файл → сервер удаляет blob."""
    user = auth_member(authorization)
    c = db()
    row = c.execute("SELECT receiver_id FROM chat_files WHERE id=?", (file_id,)).fetchone()
    if not row:
        c.close(); return {"deleted": 0}
    if row["receiver_id"] != user["id"]:
        c.close(); raise HTTPException(403, "Только получатель может удалить")
    c.execute("DELETE FROM chat_files WHERE id=?", (file_id,))
    c.commit(); c.close()
    return {"deleted": 1}

