"""Core-owned login, proof validation and session issuance.

Only the signed internal Core API calls these functions. Public product routes
forward login data to Core and do not read password hashes themselves.
"""
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
    device_name: Optional[str] = None
    platform: Optional[str] = None


class LoginChallengeBody(BaseModel):
    username: str
    client_nonce: str
    device_id: Optional[str] = None
    device_name: Optional[str] = None
    platform: Optional[str] = None


class ChallengeProofBody(BaseModel):
    challenge_id: str
    proof: str


class LoginFinishBody(ChallengeProofBody):
    device_id: Optional[str] = None
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
        # A random verifier keeps the challenge shape uniform without burning
        # server CPU on a fake Argon2 run for every unknown username.
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
    # Consume before verifying the proof: a failed proof cannot be retried.
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
                    device_name=None, platform=None):
    """Issue a legacy or device token after either auth protocol succeeds."""
    if device_id:
        blocked = c.execute(
            "SELECT id FROM user_devices WHERE user_id=? AND device_id=? AND is_blocked=1 LIMIT 1",
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
            "SELECT COUNT(*) AS n FROM user_devices WHERE user_id=? AND is_active=1 AND is_blocked=0",
            (user["id"],),
        ).fetchone()["n"]
        tda_row = c.execute("SELECT tda_enabled FROM users WHERE id=?", (user["id"],)).fetchone()
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
        import device_auth as _da
        device = _da.register_device(
            c, user["id"], device_id, device_name, platform,
            is_owner=(trusted_count == 0),
        )
        c.close()
        return {
            "id": user["id"], "username": user["username"],
            "display_name": user["display_name"], "token": device["token"],
            "device_id": device["device_id"],
        }
    token_row = c.execute("SELECT token FROM soc_tokens WHERE user_id=?", (user["id"],)).fetchone()
    if token_row:
        token = token_row["token"]
    else:
        token = secrets.token_hex(32)
        c.execute("INSERT INTO soc_tokens (user_id, token) VALUES (?,?)", (user["id"], token))
        c.commit()
    c.close()
    return {
        "id": user["id"], "username": user["username"],
        "display_name": user["display_name"], "token": token,
    }


def _login_context_digest(device_id, device_name, platform) -> str:
    payload = json.dumps(
        {"device_id": device_id or "", "device_name": device_name or "", "platform": platform or ""},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")
    return _password_auth.b64e(hashlib.sha256(payload).digest())


def login_v2_challenge(body: LoginChallengeBody, client_ip: str):
    _rate_limit(f"login:{client_ip}", limit=15, window=600)
    username = body.username.strip().lower()
    if not username:
        raise HTTPException(422, "Введите имя пользователя")
    if body.device_name is not None and len(body.device_name) > 120:
        raise HTTPException(422, "Device name is too long")
    context = _login_context_digest(body.device_id, body.device_name, body.platform)
    c = db()
    row = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    challenge = _start_password_challenge(
        c, username, "login", body.client_nonce, context, dict(row) if row else None
    )
    c.close()
    return challenge


def login_v2_finish(body: LoginFinishBody, client_ip: str):
    _rate_limit(f"login-finish:{client_ip}", limit=15, window=600)
    context = _login_context_digest(body.device_id, body.device_name, body.platform)
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
        c, user, client_ip, body.device_id, body.device_name, body.platform
    )
    result["server_proof"] = server_signature
    return result


def login(body: LoginBody, client_ip: str):
    _rate_limit(f"login:{client_ip}", limit=15, window=600)
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
    ok = verify_user_password(body.password, u)
    if not ok:
        c.close()
        raise HTTPException(401, "Неверное имя пользователя или пароль")
    # Lazy migration lets older Argon2/PBKDF2 accounts use the new challenge
    # route without requiring a password reset. Keep the legacy hash for old
    # services until their migration is independently verified.
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
                "ip": client_ip,
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
