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
    sockets_recv = list(ws_hub._by_uid.get(to_user["id"], ()))
    sockets_send = list(ws_hub._by_uid.get(user["id"], ()))
    sent = bool(sockets_recv)
    # Диагностика: вижу ли я WS-подключения receiver-а на момент /send.
    # Если 0 — клиент думает что online (WS живой у него), но сервер уже отвалился.
    import logging as _lg
    _lg.getLogger('gc').info(
        f"[send msg={msg_id}] sender={user['username']} → recv={to_user['username']} | "
        f"ws_sender={len(sockets_send)} ws_recv={len(sockets_recv)}"
    )
    ws_hub.send_to(to_user["id"], "chat.new", payload)
    # Echo отправителю — он не из БД получает, а сразу отображает
    ws_hub.send_to(user["id"], "chat.echo", payload)
    c.close()
    # Возвращаем `delivered_now` чтобы клиент сразу показал галочку
    # (если receiver онлайн — он почти точно сделает /ack в течение секунды;
    # это лучше чем "дискета навсегда" когда WS chat.delivered пропадает при offline)
    return {
        "status": "ok",
        "id": msg_id,
        "created_at": row["created_at"],
        "recipient_online": bool(sent),
    }

class DeliveryStatusBody(BaseModel):
    ids: list


@router.post("/delivery_status")
def delivery_status(body: DeliveryStatusBody, authorization: Optional[str] = Header(None)):
    """Sender узнаёт статус своих !delivered сообщений после возвращения онлайн.
    Возвращает {id: 'pending'|'delivered'}. Если сообщения нет в chat_dm
    (sender_id=ME) — значит receiver сделал /ack и сервер удалил → delivered.
    """
    user = auth_member(authorization)
    # Анти-polling DoS: клиент дёргает это после wake/reconnect, не постоянно.
    _rate_limit(f"delivstat:{user['id']}", limit=60, window=60)
    if not body.ids or not isinstance(body.ids, list):
        return {}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
    if not ids:
        return {}
    c = db()
    ph = ",".join("?" * len(ids))
    # Какие из моих ещё лежат в chat_dm (= не доставлены)
    rows = c.execute(
        f"SELECT id FROM chat_dm WHERE sender_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    still_pending = {r["id"] for r in rows}
    # Какие уже прочитаны (запись в chat_dm_read_marks)
    read_rows = c.execute(
        f"SELECT msg_id FROM chat_dm_read_marks WHERE sender_id=? AND msg_id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    read_ids = {r["msg_id"] for r in read_rows}
    c.close()
    def _status(i):
        if i in still_pending: return "pending"
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
    # Rate-limit per-sender (token известен из Authorization).
    # Полный sealed (без identity у сервера) требует blind tokens — отдельная фаза.
    _rate_limit(f"sealsend:{user['id']}", limit=120, window=60)
    if not _is_b64(body.ciphertext) or len(body.ciphertext) > 16000:
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
        raise HTTPException(400, "У получателя ещё нет E2E-ключей")
    # Анти-targeted-spam: per-pair лимит. Сам отправитель скрыт от сервера за
    # счёт sealed, но сервер всё равно видит (sender_token, recipient_id) пару
    # и должен не давать одному юзеру заливать одного получателя. 30 sealed за
    # 5 минут от одной пары — достаточно для любого живого диалога, но кладёт
    # на лопатки любой автоматизированный спам. В жёстком sealed (с blind
    # token-ами) это перестанет работать — там нужны будут групповые лимиты.
    _rate_limit(f"sealpair:{user['id']}:{to_user['id']}", limit=30, window=300)
    now = int(time.time())
    c.execute(
        "INSERT INTO chat_dm_sealed (receiver_id, ciphertext, created_at) VALUES (?,?,?)",
        (to_user["id"], body.ciphertext, now),
    )
    msg_id = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    c.commit()
    # Real-time доставка ТОЛЬКО receiver-у. Sender идентификатор НЕ передаётся.
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
def pending_sealed(authorization: Optional[str] = Header(None)):
    """Все накопленные мне sealed-сообщения. Клиент сам сделает /ack_sealed."""
    user = auth_member(authorization)
    # Анти-DoS: legit клиент дёргает /pending_sealed только при reconnect или wake.
    # 30 запросов в минуту — это уже подозрительный polling, серверу будет тяжело
    # с тысячами параллельных вкладок.
    _rate_limit(f"pendsealed:{user['id']}", limit=30, window=60)
    c = db()
    rows = c.execute(
        "SELECT id, ciphertext, created_at FROM chat_dm_sealed WHERE receiver_id=? ORDER BY id ASC LIMIT 500",
        (user["id"],),
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
def ack_sealed(body: AckSealedBody, authorization: Optional[str] = Header(None)):
    """Receiver подтвердил приём — сервер удаляет. БЕЗ WS sender'у
    (мы не знаем кто sender). Receiver сам шлёт sender'у уведомление
    'delivered' через POST /send_sealed с envelope {type:'delivered', msg_sid}."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"deleted": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:500]
    if not ids:
        return {"deleted": 0}
    c = db()
    ph = ",".join("?" * len(ids))
    c.execute(
        f"DELETE FROM chat_dm_sealed WHERE receiver_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    )
    deleted = c.total_changes
    c.commit()
    c.close()
    return {"deleted": deleted}


@router.post("/ack")
def ack_messages(body: AckBody, authorization: Optional[str] = Header(None)):
    """Клиент подтверждает что получил и сохранил сообщения локально.
    Сервер их удаляет + уведомляет отправителя через WS (для двойных галочек)."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"deleted": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
    if not ids:
        return {"deleted": 0}
    c = db()
    ph = ",".join("?" * len(ids))
    # До удаления — соберём какие сообщения чьи (нужно для broadcast'а sender'ам)
    rows = c.execute(
        f"SELECT id, sender_id FROM chat_dm WHERE receiver_id=? AND id IN ({ph})",
        [user["id"]] + ids,
    ).fetchall()
    # Удаляем
    c.execute(f"DELETE FROM chat_dm WHERE receiver_id=? AND id IN ({ph})", [user["id"]] + ids)
    deleted = c.total_changes
    c.commit()
    c.close()
    # Уведомим отправителей о delivered (двойная галочка)
    by_sender = {}
    for r in rows:
        by_sender.setdefault(r["sender_id"], []).append(r["id"])
    for sender_id, mids in by_sender.items():
        ws_hub.send_to(sender_id, "chat.delivered", {"ids": mids, "by_username": user["username"]})
    return {"deleted": deleted}


class ReadBody(BaseModel):
    ids: list
    from_username: str   # чьи именно сообщения юзер прочитал

@router.post("/read")
def read_messages(body: ReadBody, authorization: Optional[str] = Header(None)):
    """Клиент сообщает что прочитал сообщения от {from_username}. Бэк ничего не
    хранит (transient) — только пересылает sender'у WS event для синих галочек."""
    user = auth_member(authorization)
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
        # Opportunistic cleanup старых read-меток (>30 дней — точно не нужны)
        c.execute("DELETE FROM chat_dm_read_marks WHERE read_at < datetime('now', '-30 day')")
        c.commit()
    except Exception as e:
        # Не падаем — WS broadcast всё равно делаем
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
        # Мои исходящие → ему (не доставленные ещё)
        c.execute(
            "DELETE FROM chat_dm WHERE sender_id=? AND receiver_id=?",
            (user["id"], peer["id"]),
        )
        deleted_outgoing = c.total_changes
        # Мои read-метки для его сообщений (он отправлял, я прочитал)
        c.execute(
            "DELETE FROM chat_dm_read_marks WHERE sender_id=? AND recipient_id=?",
            (peer["id"], user["id"]),
        )
        if both:
            # Его исходящие → мне (которые я ещё не ack-нул)
            c.execute(
                "DELETE FROM chat_dm WHERE sender_id=? AND receiver_id=?",
                (peer["id"], user["id"]),
            )
            deleted_incoming = c.total_changes
            # Его read-метки для моих сообщений
            c.execute(
                "DELETE FROM chat_dm_read_marks WHERE sender_id=? AND recipient_id=?",
                (user["id"], peer["id"]),
            )
        c.commit()
    finally:
        c.close()
    # Если both=True — сообщим peer-у через WS, пусть удалит у себя локально.
    # Если peer offline сейчас — событие потеряется, удаление будет только серверное.
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
    if len(term) > 50:
        term = term[:50]
    c = db()
    like = f"%{term}%"
    rows = c.execute(
        """
        SELECT username, display_name,
               (x25519_pub IS NOT NULL AND x25519_pub != '') AS has_keys
          FROM users
         WHERE LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?
         LIMIT 50
        """,
        (like, like),
    ).fetchall()
    c.close()
    # Сортируем на питоне для точных совпадений в верхушке
    def score(r):
        u = (r["username"] or "").lower()
        d = (r["display_name"] or "").lower()
        if u == term or d == term:
            return 0          # точное совпадение
        if u.startswith(term) or d.startswith(term):
            return 1          # префикс
        return 2              # contains
    sorted_rows = sorted(rows, key=score)[:20]
    return {
        "results": [
            {
                "username": r["username"],
                "display_name": r["display_name"] or r["username"],
                "has_keys": bool(r["has_keys"]),
            }
            for r in sorted_rows
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
    # Анти-DoS: legit-клиент дёргает /pending только при login/reconnect/wake.
    _rate_limit(f"pendlegacy:{user['id']}", limit=30, window=60)
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
    # Стримим чанками — иначе 100MB×10 параллельных uploads = 1GB RAM spike
    chunks = []
    total = 0
    CHUNK = 64 * 1024
    while True:
        chunk = await blob.read(CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_FILE_SIZE:
            raise HTTPException(413, f"Слишком большой. Максимум {MAX_FILE_SIZE // 1024 // 1024}MB")
        chunks.append(chunk)
    if not total:
        raise HTTPException(400, "Пустой файл")
    data = b"".join(chunks)
    del chunks
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
    # Rate-limit на скачивание: защита от ID-enumeration + DoS большими файлами
    _rate_limit(f"filedl:{user['id']}", limit=120, window=60)
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
    # Базовый лимит групп на юзера — антиспам
    own = c.execute(
        "SELECT COUNT(*) as cnt FROM chat_groups WHERE owner_id=?", (user["id"],)
    ).fetchone()
    if own["cnt"] >= 50:
        c.close(); raise HTTPException(400, "Лимит групп исчерпан (50)")
    # is_public имеет смысл только для каналов; группы всегда приватные/E2E
    is_public = 1 if (kind == "channel" and body.is_public) else 0
    c.execute(
        "INSERT INTO chat_groups (name, owner_id, kind, is_public) VALUES (?,?,?,?)",
        (name, user["id"], kind, is_public),
    )
    gid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    # Создатель — админ
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
    # Уведомим всех участников через WS — у них появилась новая группа
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
    # Owner-а удалить нельзя (только через удаление всей группы)
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
    # Каждый ключ должен быть валидной base64-строкой разумного размера
    for uid_str, ek in body.envelope_keys.items():
        if not isinstance(ek, str) or len(ek) > 600 or not _is_b64(ek):
            raise HTTPException(400, f"envelope_keys[{uid_str}]: некорректный")
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    g = c.execute("SELECT kind, owner_id, name FROM chat_groups WHERE id=?", (gid,)).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Группа не найдена")
    # В канале писать могут только админы
    if g["kind"] == "channel" and not _is_group_admin(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "В канале писать могут только админы")
    # envelope_keys должны покрывать всех участников КРОМЕ отправителя
    # Если группа из одного участника (только sender) — envelope_keys может быть пустым.
    members = [r["user_id"] for r in c.execute(
        "SELECT user_id FROM chat_group_members WHERE group_id=?", (gid,)
    ).fetchall()]
    recipients = [uid for uid in members if uid != user["id"]]
    keys_int = {int(k): v for k, v in body.envelope_keys.items() if str(k).lstrip('-').isdigit()}
    missing = [uid for uid in recipients if uid not in keys_int]
    if missing:
        c.close()
        raise HTTPException(400, f"envelope_keys не покрывают всех получателей: missing {missing}")
    # Если получателей нет (Saved Messages-like) — допустим пустой envelope, но требуем ciphertext.
    # Сообщение не будет реально доставлено никому, но останется в истории на сервере недолго.
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
    # Doставка всем участникам в реальном времени
    for uid in recipients:
        # Каждому шлём только его envelope — экономим bandwidth и не светим чужие
        per_user = dict(payload)
        per_user["envelope_keys"] = {str(uid): keys_int[uid]}
        ws_hub.send_to(uid, "group.new", per_user)
    # Echo отправителю — он сразу видит у себя
    echo = dict(payload)
    echo["envelope_keys"] = {}  # себе envelope не нужен, шифровка дешифруется на стороне sender-а из локального AES-кэша
    ws_hub.send_to(user["id"], "group.echo", echo)
    # Если получателей нет (Saved Messages случай) — сразу удалим серверную копию,
    # клиент уже сохранил в IDB через echo. Сервер бессмысленно держать.
    if not recipients:
        c.execute("DELETE FROM chat_group_messages WHERE id=?", (msg_id,))
        c.commit()
    c.close()
    return {"status": "ok", "id": msg_id, "created_at": row["created_at"]}


@router.get("/group/{gid}/pending")
def group_pending(gid: int, authorization: Optional[str] = Header(None)):
    """Сообщения в группе, которые я ещё не ack-ал."""
    import json as _json
    user = auth_member(authorization)
    _rate_limit(f"grouppend:{user['id']}:{gid}", limit=20, window=60)
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    rows = c.execute("""
        SELECT m.id, m.sender_id, m.ciphertext, m.envelope_keys, m.created_at,
               u.username as from_username, u.display_name as from_display_name
        FROM chat_group_messages m
        JOIN users u ON u.id = m.sender_id
        LEFT JOIN chat_group_acks a ON a.msg_id = m.id AND a.user_id = ?
        WHERE m.group_id = ? AND a.msg_id IS NULL AND m.sender_id <> ?
        ORDER BY m.id ASC
        LIMIT 500
    """, (user["id"], gid, user["id"])).fetchall()
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
def group_ack(gid: int, body: GroupAckBody, authorization: Optional[str] = Header(None)):
    """Подтвердить получение сообщений. Если все участники ack-ли — удаляем msg.
    Иначе только помечаем что юзер получил."""
    user = auth_member(authorization)
    if not body.ids or not isinstance(body.ids, list):
        return {"acked": 0}
    ids = [int(x) for x in body.ids if isinstance(x, (int, str)) and str(x).isdigit()][:200]
    if not ids:
        return {"acked": 0}
    c = db()
    if not _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(403, "Не участник группы")
    ph = ",".join("?" * len(ids))
    # ВАЖНО: ack-ать можно только сообщения которые реально в этой группе.
    # Иначе можно перекрёстно ack-ать чужие сообщения и косвенно ускорять их purge.
    valid_ids = {r["id"] for r in c.execute(
        f"SELECT id FROM chat_group_messages WHERE group_id=? AND id IN ({ph})",
        [gid] + ids,
    ).fetchall()}
    ids = [i for i in ids if i in valid_ids]
    if not ids:
        c.close(); return {"acked": 0}
    ph = ",".join("?" * len(ids))
    for mid in ids:
        c.execute(
            "INSERT OR IGNORE INTO chat_group_acks (user_id, msg_id) VALUES (?,?)",
            (user["id"], mid),
        )
    c.commit()
    # Проверим какие сообщения теперь ack-нуты всеми получателями (кроме отправителя) → удалим
    rows = c.execute(
        f"SELECT id, sender_id FROM chat_group_messages WHERE group_id=? AND id IN ({ph})",
        [gid] + ids,
    ).fetchall()
    deleted = 0
    for r in rows:
        members_cnt = c.execute(
            "SELECT COUNT(*) as cnt FROM chat_group_members WHERE group_id=? AND user_id<>?",
            (gid, r["sender_id"]),
        ).fetchone()["cnt"]
        acks_cnt = c.execute(
            "SELECT COUNT(*) as cnt FROM chat_group_acks WHERE msg_id=?",
            (r["id"],),
        ).fetchone()["cnt"]
        if acks_cnt >= members_cnt:
            c.execute("DELETE FROM chat_group_messages WHERE id=?", (r["id"],))
            c.execute("DELETE FROM chat_group_acks WHERE msg_id=?", (r["id"],))
            deleted += 1
    c.commit(); c.close()
    return {"acked": len(ids), "purged": deleted}


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
    # Создаём пост от имени owner-а канала (он — формально автор поста)
    # Начальная activity = 500 (стандарт), source_channel_id для UI-бейджа
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
    # Лимиты: 20 заявок на приват / 100 на паблик в 30 мин — но публичные
    # каналы можно join без заявки → проверка пускаемся ниже
    c = db()
    g = c.execute(
        "SELECT id, name, kind, is_public, owner_id FROM chat_groups WHERE id=?", (gid,)
    ).fetchone()
    if not g:
        c.close(); raise HTTPException(404, "Не найдено")
    # Уже участник?
    if _is_group_member(c, gid, user["id"]):
        c.close(); raise HTTPException(409, "Вы уже участник")
    # Публичный канал — добавляем сразу без заявки
    if g["kind"] == "channel" and g["is_public"]:
        _rate_limit(f"pjoin:{user['id']}", limit=100, window=1800)
        c.execute(
            "INSERT INTO chat_group_members (group_id, user_id) VALUES (?,?)",
            (gid, user["id"]),
        )
        c.commit()
        # Уведомить админов о новом участнике (минорно)
        c.close()
        return {"status": "joined", "auto": True}
    # Приватная группа / приватный канал — заявка
    _rate_limit(f"prjoin:{user['id']}", limit=20, window=1800)
    # Уже есть pending-заявка?
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
    # Уведомить владельца + админов
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
    # Уведомить заявителя
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

