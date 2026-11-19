"""
GhostChat Keys v2 — серверная часть.

См. KEYS_V2_SPEC.md в репо.

Концепция:
- Identity: Ed25519, никогда не меняется, регенерируется из BIP-39 seed.
- Каждое устройство — свой X25519 keypair, подписанный identity.
- Сервер ВЕРИФИЦИРУЕТ подпись signed_prekey при публикации, и тогда другие
  юзеры могут доверять полученным device_pub'ам без отдельной TOFU-проверки.
- Сообщения хранятся per-device (на каждое устройство получателя — свой
  envelope), удаляются после доставки.

Эндпойнты под префиксом /api/chat/v2/.
v1 эндпойнты не трогаются, старая переписка живёт.
"""
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List
import base64, time
from chat_client_idempotency import begin as idem_begin, save as idem_save

from ecos_core.identity import db
from ecos_core.client import auth_member
from ecos_core.shared import _rate_limit, _record_dm_direction
from ecos_core.realtime import ws_hub
from key_security import validate_identity_backup

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
    _HAS_ED25519 = True
except Exception:
    _HAS_ED25519 = False


router = APIRouter(prefix="/api/chat/v2", tags=["GhostChat v2"])


# ── Вспомогательные функции ─────────────────────────────────────────────────────

def _is_b64(s: str, expected_len: Optional[int] = None) -> bool:
    if not s or not isinstance(s, str) or len(s) > 8000:
        return False
    try:
        raw = base64.b64decode(s, validate=True)
    except Exception:
        return False
    if expected_len is not None and len(raw) != expected_len:
        return False
    return True


def _verify_ed25519(identity_pub_b64: str, signature_b64: str, data: bytes) -> bool:
    """Проверка подписи Ed25519. Возвращает True если корректно подписано."""
    if not _HAS_ED25519:
        # SECURITY: отсутствие криптографической библиотеки не должно
        # превращать проверку владения identity в пропуск.
        return False
    try:
        pub_raw = base64.b64decode(identity_pub_b64)
        sig_raw = base64.b64decode(signature_b64)
        pk = Ed25519PublicKey.from_public_bytes(pub_raw)
        pk.verify(sig_raw, data)
        return True
    except (InvalidSignature, ValueError, Exception):
        return False


# ── Слой identity ──────────────────────────────────────────────

class IdentityPublishBody(BaseModel):
    identity_pub: str = Field(max_length=100)     # Ed25519 pub, 32 байта base64
    identity_priv_encrypted: Optional[str] = Field(None, max_length=8000)
    identity_salt: Optional[str] = Field(None, max_length=100)  # 16 байт base64
    identity_kdf: Optional[str] = Field(None, max_length=80)
    # Доказательство владения identity_priv: подпись фиксированной строки.
    proof_signature: str = Field(max_length=100)  # Ed25519_sign(...)


@router.post("/identity/publish")
def publish_identity(body: IdentityPublishBody, authorization: Optional[str] = Header(None)):
    """Юзер публикует свой identity_pub. Опционально — encrypted priv для
    server-mode recovery (зашифрован паролем аккаунта PBKDF2)."""
    user = auth_member(authorization)
    _rate_limit(f"v2id:{user['id']}", limit=5, window=3600)
    # Валидация identity_pub
    if not _is_b64(body.identity_pub, 32):
        raise HTTPException(400, "identity_pub: ожидается Ed25519 32 байт в base64")
    # Доказательство владения
    if not _verify_ed25519(body.identity_pub, body.proof_signature,
                           b"ghostchat-v2-identity-claim"):
        raise HTTPException(400, "proof_signature: подпись не проходит проверку")
    # Опциональная server-копия зашифрованного priv
    priv_enc = body.identity_priv_encrypted
    salt = body.identity_salt
    backup_supplied = any(
        value is not None
        for value in (body.identity_priv_encrypted, body.identity_salt, body.identity_kdf)
    )
    try:
        checked_backup = validate_identity_backup(
            encrypted_private_key=priv_enc,
            key_salt=salt,
            key_kdf=body.identity_kdf,
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from None
    c = db()
    try:
        # Защита от случайной смены identity без явного recovery:
        # если у юзера уже есть identity_pub и присылается другой — отказываем.
        # Смена identity делается отдельным эндпойнтом (TODO).
        cur = c.execute(
            "SELECT v2_identity_pub FROM users WHERE id=?", (user["id"],)
        ).fetchone()
        if cur and cur["v2_identity_pub"] and cur["v2_identity_pub"] != body.identity_pub:
            raise HTTPException(409, "У вас уже опубликован другой identity. Смена identity — отдельная процедура.")
        if backup_supplied:
            # Полный зашифрованный бэкап заменяет прежний, но обновление identity или устройства не стирает его.
            c.execute(
                "UPDATE users SET v2_identity_pub=?, in_ghostchat=1, v2_identity_priv_encrypted=?, v2_identity_salt=? WHERE id=?",
                (
                    body.identity_pub,
                    checked_backup["encrypted"],
                    checked_backup["salt"],
                    user["id"],
                ),
            )
        else:
            c.execute(
                "UPDATE users SET v2_identity_pub=?, in_ghostchat=1 WHERE id=?",
                (body.identity_pub, user["id"]),
            )
        c.commit()
        return {"status": "ok"}
    finally:
        c.close()


@router.post("/identity/rotate")
def rotate_identity(body: IdentityPublishBody, authorization: Optional[str] = Header(None)):
    # Явная ротация V2 identity после подтверждённой клиентом регенерации ключа.
    user = auth_member(authorization)
    _rate_limit(f"v2rotate:{user['id']}", limit=3, window=3600)
    if not _is_b64(body.identity_pub, 32):
        raise HTTPException(400, "identity_pub: ожидается Ed25519 32 байт в base64")
    if not _verify_ed25519(body.identity_pub, body.proof_signature,
                           b"ghostchat-v2-identity-claim"):
        raise HTTPException(400, "proof_signature: подпись не проходит проверку")
    c = db()
    try:
        cur = c.execute(
            "SELECT v2_identity_pub FROM users WHERE id=?", (user["id"],)
        ).fetchone()
        if not cur:
            raise HTTPException(404, "Пользователь не найден")
        if cur["v2_identity_pub"] == body.identity_pub:
            raise HTTPException(409, "Эта V2 identity уже опубликована")
        c.execute(
            "UPDATE users SET v2_identity_pub=?, "
            "v2_identity_priv_encrypted=NULL, v2_identity_salt=NULL WHERE id=?",
            (body.identity_pub, user["id"]),
        )
        c.execute(
            "UPDATE user_devices SET v2_device_pub=NULL, "
            "v2_signed_prekey_sig=NULL WHERE user_id=?",
            (user["id"],),
        )
        c.commit()
        return {"status": "ok"}
    finally:
        c.close()


@router.get("/identity/me")
def get_my_identity(authorization: Optional[str] = Header(None)):
    """Возвращает мою identity. Если есть зашифрованный priv — отдаём его
    тоже (клиент расшифрует паролем). Если нет — клиент должен ввести seed-фразу."""
    user = auth_member(authorization)
    c = db()
    try:
        r = c.execute(
            "SELECT v2_identity_pub, v2_identity_priv_encrypted, v2_identity_salt "
            "FROM users WHERE id=?", (user["id"],)
        ).fetchone()
        return {
            "identity_pub": r["v2_identity_pub"] if r else None,
            "identity_priv_encrypted": r["v2_identity_priv_encrypted"] if r else None,
            "identity_salt": r["v2_identity_salt"] if r else None,
        }
    finally:
        c.close()


# ── Слой устройств ────────────────────────────────────────────────

class DevicePublishBody(BaseModel):
    device_pub: str = Field(max_length=100)       # X25519 pub, 32 байта base64
    signed_prekey_sig: str = Field(max_length=100)  # Ed25519_sign(identity_priv, device_pub_raw)
    # Замена действующего ключа устройства — только по явному согласию пользователя.
    replace: bool = False


@router.post("/device/publish")
def publish_device(body: DevicePublishBody, authorization: Optional[str] = Header(None)):
    """Текущее устройство публикует свой device_pub + signature от identity.
    Сервер верифицирует подпись и привязывает к текущему device_id."""
    user = auth_member(authorization)
    _rate_limit(f"v2dev:{user['id']}", limit=10, window=3600)
    if not _is_b64(body.device_pub, 32):
        raise HTTPException(400, "device_pub: ожидается 32 байт в base64")
    if not _is_b64(body.signed_prekey_sig, 64):
        raise HTTPException(400, "signed_prekey_sig: ожидается Ed25519 64 байт в base64")
    c = db()
    try:
        # Берём identity_pub юзера и проверяем подпись device_pub им.
        id_row = c.execute(
            "SELECT v2_identity_pub FROM users WHERE id=?", (user["id"],)
        ).fetchone()
        if not id_row or not id_row["v2_identity_pub"]:
            raise HTTPException(409, "Сначала опубликуйте identity (/v2/identity/publish)")
        device_pub_raw = base64.b64decode(body.device_pub)
        if not _verify_ed25519(id_row["v2_identity_pub"], body.signed_prekey_sig, device_pub_raw):
            raise HTTPException(400, "signed_prekey_sig: подпись не проходит проверку identity")
        # Находим текущее устройство по токену.
        tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
        from ecos_core.sessions import device_for_token
        dev = device_for_token(c, tok, user["id"])
        if not dev:
            raise HTTPException(404, "Текущее устройство не найдено")
        cur = c.execute(
            "SELECT v2_device_pub FROM user_devices WHERE id=?", (dev["id"],)
        ).fetchone()
        if (
            cur
            and cur["v2_device_pub"]
            and cur["v2_device_pub"] != body.device_pub
            and not body.replace
        ):
            raise HTTPException(409, "v2_device_key_replace: у устройства уже другой v2-ключ")
        c.execute(
            "UPDATE user_devices SET v2_device_pub=?, v2_signed_prekey_sig=? WHERE id=?",
            (body.device_pub, body.signed_prekey_sig, dev["id"]),
        )
        c.commit()
        return {"status": "ok", "device_id": dev["id"]}
    finally:
        c.close()


@router.get("/keys/{username}")
def get_user_v2_keys(username: str, authorization: Optional[str] = Header(None)):
    """Получить identity_pub собеседника + список signed_prekey его активных
    устройств с подписями."""
    auth_member(authorization)
    c = db()
    try:
        u = c.execute(
            "SELECT id, v2_identity_pub FROM users WHERE username=?", (username.lower(),)
        ).fetchone()
        if not u:
            raise HTTPException(404, "Юзер не найден")
        if not u["v2_identity_pub"]:
            return {"username": username.lower(), "identity_pub": None, "devices": []}
        devs = c.execute(
            "SELECT id, v2_device_pub, v2_signed_prekey_sig FROM user_devices "
            "WHERE user_id=? AND is_active=1 AND is_blocked=0 AND expires_at>? "
            "AND v2_device_pub IS NOT NULL",
            (u["id"], int(time.time())),
        ).fetchall()
        return {
            "username": username.lower(),
            "identity_pub": u["v2_identity_pub"],
            "devices": [
                {
                    "device_id": d["id"],
                    "device_pub": d["v2_device_pub"],
                    "signed_prekey_sig": d["v2_signed_prekey_sig"],
                }
                for d in devs
            ],
        }
    finally:
        c.close()


# ── Обратный поиск identity → username ──────────────────────────

@router.get("/whois")
def whois_by_identity(identity_pub: str, authorization: Optional[str] = Header(None)):
    """Резолв identity_pub (base64) → username. Нужен для приёма sealed-сообщения:
    payload содержит identity_pub отправителя; чтобы отобразить чат, надо знать
    его username. Без этого приходится сканировать локальный список диалогов.

    Privacy-tradeoff: позволяет дешевле найти владельца publicly-known identity_pub.
    Но identity_pub и так публикуется через /v2/keys/{username}, так что приватность
    не теряется — обратный lookup — это просто инверсия публичной таблицы."""
    auth_member(authorization)
    if not identity_pub or len(identity_pub) > 200:
        raise HTTPException(400, "identity_pub: некорректный")
    c = db()
    try:
        u = c.execute(
            "SELECT username, display_name FROM users WHERE v2_identity_pub=?", (identity_pub,)
        ).fetchone()
        if not u:
            raise HTTPException(404, "Не найден")
        return {"username": u["username"], "display_name": u["display_name"]}
    finally:
        c.close()


# ── Слой сообщений ─────────────────────────────────────────────

class EnvelopeForDevice(BaseModel):
    target_device_id: int = Field(gt=0)   # одно из устройств получателя
    target_device_pub: Optional[str] = None
    envelope: str = Field(max_length=10_000)           # base64 — eph_pub || iv || ct (формат см. спеку)


class SendV2Body(BaseModel):
    client_message_id: Optional[str] = Field(default=None, min_length=16, max_length=128)
    sender_identity_pub: Optional[str] = Field(default=None, max_length=100)
    to_username: str = Field(min_length=1, max_length=64)
    envelopes: List[EnvelopeForDevice] = Field(max_length=32)  # по одному на каждое устройство получателя


@router.post("/send")
def send_v2(body: SendV2Body, authorization: Optional[str] = Header(None)):
    """Отправить сообщение v2. Клиент сам шифрует под каждое активное
    устройство получателя — серверу плевать на содержимое."""
    user = auth_member(authorization)
    _rate_limit(f"v2send:{user['id']}", limit=120, window=3600)
    if not body.envelopes:
        raise HTTPException(400, "envelopes пуст")
    if len(body.envelopes) > 32:
        raise HTTPException(400, "слишком много target-устройств в одном /send")
    c = db()
    try:
        replay = idem_begin(c, user["id"], "dm-v2", body)
        if replay is not None:
            return replay
        if body.sender_identity_pub is not None:
            own = c.execute("SELECT v2_identity_pub FROM users WHERE id=?", (user["id"],)).fetchone()
            if not own or own["v2_identity_pub"] != body.sender_identity_pub:
                raise HTTPException(409, "v2_identity_key_stale: восстановите актуальный ключ аккаунта")
        target_user = c.execute(
            "SELECT id, v2_identity_pub FROM users WHERE username=?",
            (body.to_username.lower(),),
        ).fetchone()
        if not target_user:
            raise HTTPException(404, "Получатель не найден")
        if not target_user["v2_identity_pub"]:
            raise HTTPException(409, "У получателя нет identity v2")
        if target_user["id"] != user["id"]:
            from chat_router import _is_blocked
            from ecos_core.shared import _get_privacy_flags
            if _is_blocked(c, user["id"], target_user["id"]):
                raise HTTPException(403, "Пользователь заблокирован")
            privacy = _get_privacy_flags(c, target_user["id"]).get("message_privacy", "all")
            if privacy == "nobody" or (privacy == "contacts" and not c.execute(
                    "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=?",
                    (target_user["id"], user["id"])).fetchone()):
                raise HTTPException(403, "Получатель ограничил личные сообщения")
        if len({env.target_device_id for env in body.envelopes}) != len(body.envelopes):
            raise HTTPException(422, "Повторяющийся target_device_id")
        now_ = int(time.time())
        ids = []
        for env in body.envelopes:
            # Валидация envelope: должен быть валидный base64, разумной длины.
            if not env.envelope or len(env.envelope) > 10000:
                raise HTTPException(400, "envelope: пусто или слишком большое")
            if not _is_b64(env.envelope):
                raise HTTPException(400, "envelope: ожидается base64")
            # Проверим, что target_device_id принадлежит получателю.
            d = c.execute(
                "SELECT id, v2_device_pub FROM user_devices "
                "WHERE id=? AND user_id=? AND is_active=1 AND is_blocked=0 AND expires_at>? "
                "AND v2_device_pub IS NOT NULL",
                (env.target_device_id, target_user["id"], now_),
            ).fetchone()
            if not d:
                raise HTTPException(409, "v2_device_key_stale")
            if env.target_device_pub is not None and env.target_device_pub != d["v2_device_pub"]:
                raise HTTPException(409, "v2_device_key_stale")
            cur = c.execute(
                "INSERT INTO chat_dm_v2 (receiver_user_id, receiver_device_id, envelope, created_at) "
                "VALUES (?, ?, ?, ?)",
                (target_user["id"], d["id"], env.envelope, now_),
            )
            ids.append(cur.lastrowid)
        if ids:
            _record_dm_direction(c, int(user["id"]), int(target_user["id"]))
        response = {"status": "ok", "delivered_to_devices": len(ids), "ids": ids}
        idem_save(c, user["id"], "dm-v2", body, response)
        c.commit()
        try:
            ws_hub.send_to(target_user["id"], "chat.v2.new", {"count": len(ids)})
        except Exception:
            pass
        # FCM push на устройства получателя — generic, без plaintext.
        if ids:
            try:
                from fcm_helper import get_tokens_for_user, send_wake_push
                toks = get_tokens_for_user(c, target_user["id"])
                if toks:
                    # push в фоне: блокирующий вызов FCM задерживал ответ и давал 504
                    import threading as _t
                    _t.Thread(target=send_wake_push, args=(toks,), daemon=True).start()
            except Exception as _e:
                import logging as _lg
                _lg.getLogger('gc').warning(f"FCM v2 push fail: {_e}")
        return response
    finally:
        c.close()


@router.get("/pending")
def pending_v2(authorization: Optional[str] = Header(None)):
    """Забрать pending сообщения для ТЕКУЩЕГО устройства."""
    user = auth_member(authorization)
    tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
    c = db()
    try:
        from ecos_core.sessions import device_for_token
        dev = device_for_token(c, tok, user["id"])
        if not dev:
            raise HTTPException(404, "Текущее устройство не найдено")
        rows = c.execute(
            "SELECT id, envelope, created_at FROM chat_dm_v2 "
            "WHERE receiver_user_id=? AND receiver_device_id=? ORDER BY id ASC LIMIT 200",
            (user["id"], dev["id"]),
        ).fetchall()
        return {
            "messages": [
                {"id": r["id"], "envelope": r["envelope"], "created_at": r["created_at"]}
                for r in rows
            ]
        }
    finally:
        c.close()


class AckV2Body(BaseModel):
    ids: List[int] = Field(max_length=500)


@router.post("/ack")
def ack_v2(body: AckV2Body, authorization: Optional[str] = Header(None)):
    """Подтверждение доставки — сервер удаляет из chat_dm_v2."""
    user = auth_member(authorization)
    if not body.ids:
        return {"status": "ok"}
    if len(body.ids) > 500:
        raise HTTPException(400, "too many ids")
    tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
    c = db()
    try:
        from ecos_core.sessions import device_for_token
        dev = device_for_token(c, tok, user["id"])
        if not dev:
            raise HTTPException(404, "Текущее устройство не найдено")
        placeholders = ",".join("?" * len(body.ids))
        cur = c.execute(
            f"DELETE FROM chat_dm_v2 WHERE receiver_user_id=? AND receiver_device_id=? "
            f"AND id IN ({placeholders})",
            (user["id"], dev["id"], *body.ids),
        )
        c.commit()
        return {"status": "ok", "deleted": cur.rowcount}
    finally:
        c.close()
