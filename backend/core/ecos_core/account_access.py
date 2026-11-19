"""Проверки пароля и восстановление аккаунта на стороне Core."""
import secrets
from typing import Optional
from fastapi import HTTPException
from pydantic import BaseModel

from ecos_core.credentials import verify_user_password
from ecos_core.identity import auth_member, db
from ecos_core.login import (
    ChallengeProofBody, _DUMMY_ARGON2_HASH, _start_password_challenge,
    _consume_password_challenge, _persist_password_verifier,
)
from ecos_core.shared import _rate_limit, hash_argon2, verify_argon2
from ecos_core.sessions import create_session, revoke_all_sessions



class PasswordChallengeBody(BaseModel):
    purpose: str
    client_nonce: str
    context: str = ""


class SeedRecoveryBody(BaseModel):
    username: str
    seed_phrase: str


class SeedRegenBody(BaseModel):
    password: Optional[str] = None
    challenge_id: Optional[str] = None
    proof: Optional[str] = None


def password_v2_challenge(
    body: PasswordChallengeBody,
    authorization: Optional[str],
):
    user = auth_member(authorization)
    if body.purpose not in {"verify_password", "change_password", "regen_seed", "delete_account"}:
        raise HTTPException(422, "Invalid password challenge purpose")
    _rate_limit(f"password-proof:{user['id']}", limit=10, window=600)
    c = db()
    row = c.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
    if not row:
        c.close()
        raise HTTPException(401, "Invalid token")
    challenge = _start_password_challenge(
        c, user["username"], body.purpose, body.client_nonce, body.context, dict(row)
    )
    c.close()
    return challenge


def password_v2_verify(
    body: ChallengeProofBody,
    authorization: Optional[str],
):
    user = auth_member(authorization)
    _rate_limit(f"password-verify:{user['id']}", limit=5, window=600)
    c = db()
    try:
        _, verifier, _, server_signature = _consume_password_challenge(
            c, body.challenge_id, body.proof, "verify_password",
            user_id=user["id"], context="", error_status=422,
        )
        if not (user.get("auth_v1_salt") and user.get("auth_v1_kdf")):
            _persist_password_verifier(c, user["id"], verifier)
            c.commit()
    finally:
        c.close()
    return {"status": "ok", "password_verified": True, "server_proof": server_signature}


def recovery_seed(body: SeedRecoveryBody, client_ip: str):
    """Восстановить доступ по seed-фразе. Возвращает новый токен."""
    _rate_limit(f"recov:{client_ip}", limit=10, window=3600)
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
    c.execute("DELETE FROM soc_tokens WHERE user_id=?", (user["id"],))
    import device_auth as _da
    _da.init_devices_table(c)
    c.execute(
        "UPDATE user_devices SET token=NULL, device_token_hash=NULL, "
        "device_token_expires_at=NULL WHERE user_id=?",
        (user["id"],),
    )
    revoke_all_sessions(c, int(user["id"]), "seed_recovered")
    recovered_device = _da.register_device(
        c, int(user["id"]), None, "Устройство восстановления", "unknown",
        is_owner=True,
    )
    device_row = c.execute(
        "SELECT id FROM user_devices WHERE user_id=? AND device_id=? LIMIT 1",
        (user["id"], recovered_device["device_id"]),
    ).fetchone()
    device_pk = int(device_row["id"])
    device_token = _da.issue_device_token(c, int(user["id"]), device_pk)
    session = create_session(c, int(user["id"]), device_pk, auth_method="seed_recovery")
    c.close()
    return {
        "username": user["username"],
        "token": session["token"],
        "session_token": session["session_token"],
        "session_id": session["session_id"],
        "token_type": session["token_type"],
        "expires_at": session["expires_at"],
        "expires_in": session["expires_in"],
        "status": session["status"],
        "device_token": device_token,
    }


def regen_seed(body: SeedRegenBody, authorization: Optional[str]):
    """Сгенерить новую seed-фразу (для тех у кого её нет, или забыли). Требует пароль."""
    user = auth_member(authorization)
    _rate_limit(f"regenseed:{user['id']}", limit=3, window=3600)
    server_signature = None
    if body.challenge_id and body.proof:
        c = db()
        try:
            _, verifier, _, server_signature = _consume_password_challenge(
                c, body.challenge_id, body.proof, "regen_seed", user_id=user["id"],
            )
        finally:
            c.close()
    elif body.password and verify_user_password(body.password, user):
        pass
    else:
        raise HTTPException(401, "Неверный пароль")
    seed_alpha = "abcdefghkmnpqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    seed = ''.join(secrets.choice(seed_alpha) for _ in range(16))
    seed_hash = hash_argon2(seed)
    c = db()
    c.execute("UPDATE users SET seed_hash=? WHERE id=?", (seed_hash, user["id"]))
    c.commit(); c.close()
    result = {"seed_phrase": seed}
    if server_signature:
        result["server_proof"] = server_signature
    return result
