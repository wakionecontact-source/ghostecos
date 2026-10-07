"""Core-owned user registration and first session issuance."""
import secrets
import sqlite3
import time
from typing import Optional
from fastapi import HTTPException
from pydantic import BaseModel

import password_auth as _password_auth
from ecos_core.economy import award_gost
from ecos_core.identity import db
from ecos_core.login import _AUTH_V1_KDF
from ecos_core.shared import (
    _ctrl, _claim_public_handle, _rate_limit, _val_name, _val_username, hash_argon2,
)

_PASS_MIN, _PASS_MAX = 8, 150



class RegisterBody(BaseModel):
    username: str
    display_name: str
    password: str
    ref: Optional[str] = None
    age_18_confirm: bool = False
    device_id: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


class RegisterV2Body(BaseModel):
    username: str
    display_name: str
    verifier: dict
    ref: Optional[str] = None
    age_18_confirm: bool = False
    device_id: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


def _emoji(cp: int) -> bool:
    return (0x1F000 <= cp <= 0x1FAFF or 0x2600 <= cp <= 0x27BF or
            0x2300 <= cp <= 0x23FF or 0x2B00 <= cp <= 0x2BFF or
            0x1F1E6 <= cp <= 0x1F1FF or 0xFE00 <= cp <= 0xFE0F or
            cp in (0x200D, 0x20E3, 0x203C, 0x2049, 0x2122, 0x2139) or
            0x2194 <= cp <= 0x21AA or 0x231A <= cp <= 0x231B or
            cp == 0x24C2 or 0x25AA <= cp <= 0x25FE or 0x2934 <= cp <= 0x2935)


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


def register(body: RegisterBody, client_ip: str):
    # Регистрация: 20 попыток в час с одного IP. Пять попыток было слишком
    # мало для CAPTCHA/тестирования и блокировало первую реальную попытку
    # после нескольких неудачных или пробных запросов.
    _rate_limit(f"reg:{client_ip}", limit=20, window=3600)
    username = _val_username(body.username)
    display_name = _val_name(body.display_name)
    client_verifier = getattr(body, "verifier", None)
    if client_verifier is not None:
        try:
            client_verifier = _password_auth.validate_verifier(client_verifier)
        except (ValueError, TypeError, KeyError):
            raise HTTPException(422, "Invalid password verifier")
        if client_verifier["kdf"] != _AUTH_V1_KDF:
            raise HTTPException(422, "Unsupported password verifier parameters")
        # Keep the legacy NOT NULL column valid for v2 accounts. The actual
        # verifier is stored in the auth_v1_* columns; NULL here would
        # raise sqlite3.IntegrityError and be misreported as "username taken".
        argon2 = ""
    else:
        _val_password(body.password)
        argon2 = hash_argon2(body.password)
        client_verifier = _password_auth.verifier_from_argon2_hash(argon2)
    verifier_salt, verifier_kdf, verifier_stored_key, verifier_server_key = (
        _password_auth.verifier_db_fields(client_verifier)
    )
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
            "INSERT INTO users (username, display_name, argon2_hash, auth_v1_salt, auth_v1_kdf, "
            "auth_v1_stored_key, auth_v1_server_key, in_ghostchat, seed_hash, referrer_id, "
            "confirmed_18_at, key_storage_mode) VALUES (?,?,?,?,?,?,?,0,?,?,?,'local')",
            (username, display_name, argon2, verifier_salt, verifier_kdf,
             verifier_stored_key, verifier_server_key, seed_hash, referrer_id, confirmed_18_ts),
        )
        uid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        _claim_public_handle(c, username, "user", uid)
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
