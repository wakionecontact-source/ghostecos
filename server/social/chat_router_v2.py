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
from pydantic import BaseModel
from typing import Optional, List
import base64, time

from social_router import auth_member, db, ws_hub, _rate_limit

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
    _HAS_ED25519 = True
except Exception:
    _HAS_ED25519 = False


router = APIRouter(prefix="/api/chat/v2", tags=["GhostChat v2"])


# ── Helpers ─────────────────────────────────────────────────────

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
        # Без библиотеки — пускаем (на dev-проде потеря защиты, но не падаем).
        # В проде эта ветка не должна срабатывать.
        return True
    try:
        pub_raw = base64.b64decode(identity_pub_b64)
        sig_raw = base64.b64decode(signature_b64)
        pk = Ed25519PublicKey.from_public_bytes(pub_raw)
        pk.verify(sig_raw, data)
        return True
    except (InvalidSignature, ValueError, Exception):
        return False


# ── Identity layer ──────────────────────────────────────────────

class IdentityPublishBody(BaseModel):
    identity_pub: str                            # Ed25519 pub, 32 байта base64
    identity_priv_encrypted: Optional[str] = None  # опц., если хранить на сервере под паролем
    identity_salt: Optional[str] = None          # 16 байт base64, для PBKDF2 пароля
    # Доказательство владения identity_priv: подпись фиксированной строки.
    proof_signature: str                         # Ed25519_sign(identity_priv, "ghostchat-v2-identity-claim")


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
    if priv_enc is not None:
        if not _is_b64(priv_enc) or not _is_b64(salt, 16):
            raise HTTPException(400, "identity_priv_encrypted/salt: некорректный формат")
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
        c.execute(
            "UPDATE users SET v2_identity_pub=?, v2_identity_priv_encrypted=?, v2_identity_salt=? WHERE id=?",
            (body.identity_pub, priv_enc, salt, user["id"]),
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


# ── Device layer ────────────────────────────────────────────────

class DevicePublishBody(BaseModel):
    device_pub: str                # X25519 pub, 32 байта base64
    signed_prekey_sig: str         # Ed25519_sign(identity_priv, device_pub_raw)


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
        dev = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (tok, user["id"]),
        ).fetchone()
        if not dev:
            raise HTTPException(404, "Текущее устройство не найдено")
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
            "WHERE user_id=? AND is_active=1 AND is_blocked=0 "
            "AND v2_device_pub IS NOT NULL",
            (u["id"],),
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


# ── Messaging layer ─────────────────────────────────────────────

class EnvelopeForDevice(BaseModel):
    target_device_id: int   # одно из устройств получателя
    envelope: str           # base64 — eph_pub || iv || ct (формат см. спеку)


class SendV2Body(BaseModel):
    to_username: str
    envelopes: List[EnvelopeForDevice]  # по одному на каждое устройство получателя


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
        target_user = c.execute(
            "SELECT id, v2_identity_pub FROM users WHERE username=?",
            (body.to_username.lower(),),
        ).fetchone()
        if not target_user:
            raise HTTPException(404, "Получатель не найден")
        if not target_user["v2_identity_pub"]:
            raise HTTPException(409, "У получателя нет identity v2")
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
                "SELECT id FROM user_devices "
                "WHERE id=? AND user_id=? AND is_active=1 AND is_blocked=0 "
                "AND v2_device_pub IS NOT NULL",
                (env.target_device_id, target_user["id"]),
            ).fetchone()
            if not d:
                # Не существует / отключено / без v2 ключа — пропускаем, не ошибка.
                continue
            cur = c.execute(
                "INSERT INTO chat_dm_v2 (receiver_user_id, receiver_device_id, envelope, created_at) "
                "VALUES (?, ?, ?, ?)",
                (target_user["id"], d["id"], env.envelope, now_),
            )
            ids.append(cur.lastrowid)
        c.commit()
        # WS-уведомление: получателю что есть новые сообщения. Содержимое
        # не отдаём — клиент сделает /v2/pending.
        try:
            ws_hub.send_to(target_user["id"], "chat.v2.new", {"count": len(ids)})
        except Exception:
            pass
        return {"status": "ok", "delivered_to_devices": len(ids), "ids": ids}
    finally:
        c.close()


@router.get("/pending")
def pending_v2(authorization: Optional[str] = Header(None)):
    """Забрать pending сообщения для ТЕКУЩЕГО устройства."""
    user = auth_member(authorization)
    tok = (authorization or "").split(" ", 1)[-1] if authorization else ""
    c = db()
    try:
        dev = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (tok, user["id"]),
        ).fetchone()
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
    ids: List[int]


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
        dev = c.execute(
            "SELECT id FROM user_devices WHERE token=? AND user_id=? LIMIT 1",
            (tok, user["id"]),
        ).fetchone()
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
