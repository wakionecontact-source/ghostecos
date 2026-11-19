"""Вход и выдача сессий на стороне Core; публичные роуты не читают хэши паролей."""
import hashlib
import json
import secrets
import sqlite3
import time
import uuid
from typing import Optional
from argon2 import PasswordHasher
from fastapi import HTTPException
from pydantic import BaseModel

import password_auth as _password_auth
from ecos_core.credentials import verify_user_password
from ecos_core.identity import db
from ecos_core.realtime import ws_hub
from ecos_core.shared import _rate_limit, hash_argon2, verify_argon2
from ecos_core.sessions import create_session
from ecos_core.vault import save_password as _vault_save

_AUTH_CHALLENGE_TTL = 120
_AUTH_V1_KDF = {
    "name": "argon2id", "version": 19, "iterations": 3,
    "memory_kib": 65536, "parallelism": 1, "hash_len": 32,
}
_DUMMY_ARGON2_HASH = PasswordHasher().hash("__non-existent-user-dummy__")



class LoginBody(BaseModel):
    username: str
    password: str
    device_id: Optional[str] = None
    device_token: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


class LoginChallengeBody(BaseModel):
    username: str
    client_nonce: str
    device_id: Optional[str] = None
    device_token: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


class ChallengeProofBody(BaseModel):
    challenge_id: str
    proof: str


class LoginFinishBody(ChallengeProofBody):
    device_id: Optional[str] = None
    device_token: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


def _persist_password_verifier(c, user_id: int, verifier: dict):
    salt, kdf, stored_key, server_key = _password_auth.verifier_db_fields(verifier)
    c.execute(
        "UPDATE users SET auth_v1_salt=?, auth_v1_kdf=?, auth_v1_stored_key=?, auth_v1_server_key=? WHERE id=?",
        (salt, kdf, stored_key, server_key, user_id),
    )


def _start_password_challenge(c, username: str, purpose: str, client_nonce: str,
                              context: str, user: Optional[dict] = None) -> dict:
    if purpose not in {"login", "verify_password", "change_password", "regen_seed", "delete_account"}:
        raise HTTPException(422, "Invalid password challenge purpose")
    try:
        nonce_bytes = _password_auth.b64d(client_nonce)
    except ValueError:
        raise HTTPException(422, "Invalid client nonce")
    if not 16 <= len(nonce_bytes) <= 64:
        raise HTTPException(422, "Invalid client nonce")
    if not isinstance(context, str) or len(context) > 128 or "\n" in context or "\r" in context:
        raise HTTPException(422, "Invalid challenge context")

    user_id = int(user["id"]) if user else None
    verifier = None
    if user:
        try:
            verifier = _password_auth.verifier_for_user(user)
        except (ValueError, TypeError, KeyError):
            verifier = None
    if verifier is None:
        # Случайный верификатор выравнивает форму ответа без лишнего Argon2 для неизвестных юзеров.
        verifier = {
            "salt": _password_auth.b64e(secrets.token_bytes(16)),
            "kdf": dict(_AUTH_V1_KDF),
            "stored_key": _password_auth.b64e(secrets.token_bytes(32)),
            "server_key": _password_auth.b64e(secrets.token_bytes(32)),
        }

    challenge_id = secrets.token_urlsafe(24)
    server_nonce = _password_auth.b64e(secrets.token_bytes(32))
    expires_at = int(time.time()) + _AUTH_CHALLENGE_TTL
    c.execute("DELETE FROM soc_auth_challenges WHERE expires_at<?", (int(time.time()) - 300,))
    c.execute(
        "INSERT INTO soc_auth_challenges "
        "(challenge_id,user_id,username,purpose,client_nonce,server_nonce,context,salt,kdf,stored_key,server_key,expires_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            challenge_id, user_id, username.lower(), purpose, client_nonce, server_nonce,
            context, verifier["salt"], json.dumps(verifier["kdf"], sort_keys=True, separators=(",", ":")),
            verifier["stored_key"], verifier["server_key"], expires_at,
        ),
    )
    c.commit()
    return {
        "challenge_id": challenge_id,
        "username": username.lower(),
        "purpose": purpose,
        "client_nonce": client_nonce,
        "server_nonce": server_nonce,
        "context": context,
        "salt": verifier["salt"],
        "kdf": verifier["kdf"],
        "expires_in": _AUTH_CHALLENGE_TTL,
    }


def _consume_password_challenge(c, challenge_id: str, proof: str, purpose: str,
                                user_id: Optional[int] = None, context: Optional[str] = None,
                                error_status: int = 401) -> tuple[dict, dict, bytes, str]:
    now = int(time.time())
    c.execute("BEGIN IMMEDIATE")
    row = c.execute(
        "SELECT * FROM soc_auth_challenges WHERE challenge_id=?", (challenge_id,)
    ).fetchone()
    if not row or row["used_at"] is not None:
        c.rollback()
        raise HTTPException(error_status, "Invalid or expired password challenge")
    # Поглощаем челлендж до проверки доказательства: неудачу нельзя повторить.
    c.execute(
        "UPDATE soc_auth_challenges SET used_at=? WHERE challenge_id=? AND used_at IS NULL",
        (now, challenge_id),
    )
    c.commit()
    data = dict(row)
    if (int(data["expires_at"]) < now or data["purpose"] != purpose
            or (user_id is not None and data["user_id"] != user_id)
            or (context is not None and data["context"] != context)):
        raise HTTPException(error_status, "Invalid or expired password challenge")
    verifier = {
        "salt": data["salt"],
        "kdf": json.loads(data["kdf"]),
        "stored_key": data["stored_key"],
        "server_key": data["server_key"],
    }
    try:
        message = _password_auth.transcript(
            purpose, data["username"], challenge_id,
            data["client_nonce"], data["server_nonce"], data["context"],
        )
    except ValueError:
        raise HTTPException(error_status, "Invalid or expired password challenge")
    if not _password_auth.verify_client_proof(verifier, message, proof):
        raise HTTPException(error_status, "Неверный текущий пароль" if purpose != "login" else "Неверное имя пользователя или пароль")
    return data, verifier, message, _password_auth.server_proof(verifier, message)


def _complete_login(c, user: dict, client_ip: str, device_id=None,
                    device_name=None, platform=None, device_token=None):
    """Выдаёт сессию и отдельный серверный токен устройства."""
    import device_auth as _da

    client_device_id = device_id
    if device_token and len(device_token) > 256:
        c.close()
        raise HTTPException(400, "Некорректный device_token")

    device_pk = None
    device = None
    issued_device_token = None

    if device_token:
        device = _da.auth_device_token(c, device_token)
        if not device or int(device["user_id"]) != int(user["id"]):
            c.close()
            raise HTTPException(401, "Неверный device_token")
        if device_id and device_id != device["device_id"]:
            c.close()
            raise HTTPException(401, "device_id не соответствует device_token")
        device_pk = int(device["id"])
        # Мигрируем старые открытые токены устройств в хэшированные.
        if not device.get("device_token_hash"):
            c.execute("UPDATE user_devices SET token=NULL WHERE id=?", (device_pk,))
            issued_device_token = _da.issue_device_token(c, int(user["id"]), device_pk)
        if device_name or platform:
            c.execute(
                "UPDATE user_devices SET device_name=?, platform=?, last_seen=? WHERE id=?",
                ((device_name or device["device_name"] or "Неизвестное устройство")[:120],
                 (platform or device["platform"] or "unknown")[:32], int(time.time()), device_pk),
            )
            c.commit()
    else:
        # Клиент может скрывать локальный device_id и подтверждать вход выданным device_token.
        if not device_id:
            trusted_count = c.execute(
                "SELECT COUNT(*) AS n FROM user_devices "
                "WHERE user_id=? AND is_active=1 AND is_blocked=0",
                (user["id"],),
            ).fetchone()["n"]
            tda_row = c.execute(
                "SELECT tda_enabled FROM users WHERE id=?", (user["id"],)
            ).fetchone()
            if bool(tda_row and tda_row["tda_enabled"]) and trusted_count > 0:
                c.close()
                raise HTTPException(
                    428, "Для этого аккаунта нужен device_token или device_id"
                )
            device = _da.register_device(
                c, int(user["id"]), None, device_name, platform,
                is_owner=(trusted_count == 0),
            )
            device_id = device["device_id"]
        else:
            blocked = c.execute(
                "SELECT id FROM user_devices WHERE user_id=? AND device_id=? "
                "AND is_blocked=1 LIMIT 1",
                (user["id"], device_id),
            ).fetchone()
            if blocked:
                c.close()
                raise HTTPException(403, "Это устройство заблокировано владельцем аккаунта")
            already = c.execute(
                "SELECT id FROM user_devices WHERE user_id=? AND device_id=? LIMIT 1",
                (user["id"], device_id),
            ).fetchone()
            trusted_count = c.execute(
                "SELECT COUNT(*) AS n FROM user_devices "
                "WHERE user_id=? AND is_active=1 AND is_blocked=0",
                (user["id"],),
            ).fetchone()["n"]
            tda_row = c.execute(
                "SELECT tda_enabled FROM users WHERE id=?", (user["id"],)
            ).fetchone()
            if bool(tda_row and tda_row["tda_enabled"]) and not already and trusted_count > 0:
                now = int(time.time())
                login_code = "".join(secrets.choice("0123456789") for _ in range(6))
                request_id = uuid.uuid4().hex
                c.execute(
                    "INSERT INTO pending_logins "
                    "(request_id, username, device_id, device_name, phase, code_hash, created_at, expires_at) "
                    "VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)",
                    (request_id, user["username"], device_id, (device_name or "")[:120],
                     hash_argon2(login_code), now, now + 300),
                )
                c.commit()
                push_data = {
                    "request_id": request_id, "login_request_id": request_id,
                    "device_name": device_name or "Новое устройство",
                    "platform": platform or "unknown", "ip": client_ip,
                    "ts": now, "expires_at": now + 300,
                }
                for event in ("login.pending", "tda.pending.new"):
                    try:
                        ws_hub.send_to(user["id"], event, push_data)
                    except Exception:
                        pass
                c.close()
                return {
                    "requires_approval": True, "request_id": request_id,
                    "code": login_code, "username": user["username"],
                    "display_name": user["display_name"], "expires_in": 300,
                }

            device = _da.register_device(
                c, int(user["id"]), device_id, device_name, platform,
                is_owner=(trusted_count == 0),
            )

        device_row = c.execute(
            "SELECT id FROM user_devices WHERE user_id=? AND device_id=? LIMIT 1",
            (user["id"], device["device_id"]),
        ).fetchone()
        if not device_row:
            c.close()
            raise HTTPException(409, "Не удалось привязать устройство к сессии")
        device_pk = int(device_row["id"])
        issued_device_token = _da.issue_device_token(c, int(user["id"]), device_pk)

    session = create_session(c, int(user["id"]), device_pk, auth_method="password")
    c.close()
    return {
        "id": user["id"],
        "username": user["username"],
        "display_name": user["display_name"],
        "token": session["token"],
        "session_token": session["session_token"],
        "session_id": session["session_id"],
        "token_type": session["token_type"],
        "expires_at": session["expires_at"],
        "expires_in": session["expires_in"],
        "status": session["status"],
        "device_id": client_device_id,
        "device_token": issued_device_token,
    }


def _login_context_digest(device_id, device_name, platform, device_token=None) -> str:
    if device_token and len(device_token) > 256:
        raise HTTPException(422, "Некорректный device_token")
    token_fingerprint = (
        hashlib.sha256(device_token.encode("utf-8")).hexdigest()
        if device_token else ""
    )
    payload_data = {
        "device_id": device_id or "",
        "device_name": device_name or "",
        "platform": platform or "",
    }
    if device_token:
        payload_data["device_token_fingerprint"] = token_fingerprint
    payload = json.dumps(
        payload_data,
        sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")
    return _password_auth.b64e(hashlib.sha256(payload).digest())


def login_v2_challenge(body: LoginChallengeBody, client_ip: str):
    _rate_limit(f"login:{client_ip}", limit=15, window=600)
    username = body.username.strip().lower().removeprefix("@")
    if not username:
        raise HTTPException(422, "Введите имя пользователя")
    if body.device_name is not None and len(body.device_name) > 120:
        raise HTTPException(422, "Device name is too long")
    context = _login_context_digest(body.device_id, body.device_name, body.platform, body.device_token)
    c = db()
    row = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    challenge = _start_password_challenge(
        c, username, "login", body.client_nonce, context, dict(row) if row else None
    )
    c.close()
    return challenge


def login_v2_finish(body: LoginFinishBody, client_ip: str):
    _rate_limit(f"login-finish:{client_ip}", limit=15, window=600)
    context = _login_context_digest(body.device_id, body.device_name, body.platform, body.device_token)
    c = db()
    challenge = c.execute(
        "SELECT * FROM soc_auth_challenges WHERE challenge_id=?", (body.challenge_id,)
    ).fetchone()
    if not challenge:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    data, verifier, message, server_signature = _consume_password_challenge(
        c, body.challenge_id, body.proof, "login", context=context,
    )
    if data["user_id"] is None:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    row = c.execute("SELECT * FROM users WHERE id=?", (data["user_id"],)).fetchone()
    if not row:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    user = dict(row)
    if not (user.get("auth_v1_salt") and user.get("auth_v1_kdf")):
        _persist_password_verifier(c, user["id"], verifier)
        c.commit()
    result = _complete_login(
        c, user, client_ip, body.device_id, body.device_name, body.platform, body.device_token
    )
    result["server_proof"] = server_signature
    return result


def login(body: LoginBody, client_ip: str):
    _rate_limit(f"login:{client_ip}", limit=15, window=600)
    username = body.username.strip().lower().removeprefix("@")
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
    ok = verify_user_password(body.password, u)
    if not ok:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    # Пароль подтверждён входом — обновляем сейф GhostID для выдачи сервисам.
    try:
        _vault_save(u["id"], body.password)
    except (OSError, ValueError):
        pass
    # Ленивая миграция: старые аккаунты идут в новый flow без сброса пароля, старый хэш нужен старым сервисам.
    if not (u.get("auth_v1_salt") and u.get("auth_v1_kdf")):
        try:
            _persist_password_verifier(c, u["id"], _password_auth.verifier_for_user(u))
            c.commit()
        except (ValueError, TypeError, KeyError):
            pass
    if u.get("pbkdf2_hash") and not u.get("argon2_hash"):
        new_hash = hash_argon2(body.password)
        c.execute("UPDATE users SET argon2_hash=?, pbkdf2_hash=NULL WHERE id=?", (new_hash, u["id"]))
        c.commit()
    return _complete_login(
        c, u, client_ip, body.device_id, body.device_name, body.platform, body.device_token
    )
