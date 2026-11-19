"""Синхронный клиент сервисов для вызовов GhostEcos Core."""
from __future__ import annotations

import hashlib
import hmac
import httpx
import json
import os
import re
import secrets
import time
from fastapi import HTTPException

_SERVICE_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
_HTTP = httpx.Client(timeout=httpx.Timeout(3.0, connect=1.0))


def _credentials() -> tuple[str, bytes]:
    service = os.getenv("GE_SERVICE_NAME", "").strip().lower()
    if not _SERVICE_RE.fullmatch(service):
        raise HTTPException(503, "GhostEcos Core client is not configured")
    env_name = "GE_INTERNAL_KEY_" + re.sub(r"[^A-Z0-9]", "_", service.upper())
    key = os.getenv(env_name, "")
    if len(key) < 32:
        raise HTTPException(503, "GhostEcos Core client is not configured")
    return service, key.encode("utf-8")


def _post(path: str, payload: dict) -> dict:
    service, key = _credentials()
    try:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError):
        raise HTTPException(422, "Invalid internal payload")
    timestamp = str(int(time.time()))
    nonce = secrets.token_hex(16)
    prefix = f"{timestamp}\n{nonce}\nPOST\n{path}\n".encode("utf-8")
    signature = hmac.new(key, prefix + body, hashlib.sha256).hexdigest()
    headers = {
        "Content-Type": "application/json",
        "X-GE-Service": service,
        "X-GE-Timestamp": timestamp,
        "X-GE-Nonce": nonce,
        "X-GE-Signature": signature,
    }
    base_url = os.getenv("GE_CORE_URL", "http://127.0.0.1:8002").rstrip("/")
    try:
        response = _HTTP.post(base_url + path, content=body, headers=headers)
    except httpx.HTTPError:
        raise HTTPException(503, "GhostEcos Core is unavailable")
    try:
        result = response.json()
    except ValueError:
        result = {}
    if response.status_code >= 400:
        detail = result.get("detail") if isinstance(result, dict) else None
        raise HTTPException(response.status_code, detail or "GhostEcos Core request failed")
    if not isinstance(result, dict):
        raise HTTPException(502, "Invalid response from GhostEcos Core")
    return result


def auth(authorization: str | None) -> dict:
    if not authorization or not authorization.strip():
        raise HTTPException(401, "Missing token")
    scheme, separator, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not separator or not token:
        raise HTTPException(401, "Invalid authorization header")

    # Роутеры Core не звонят тому же серверу по HTTP из воркера: иначе всплеск вызывает таймауты.
    if os.getenv("GE_SERVICE_NAME", "").strip().lower() == "ghostecos-core":
        from ecos_core.identity import auth as core_auth
        from ecos_core.shared import _is_admin_user

        identity = core_auth(authorization)
        return {
            "id": int(identity.get("id") or 0),
            "username": str(identity.get("username") or ""),
            "display_name": str(identity.get("display_name") or ""),
            "avatar_url": identity.get("avatar_url"),
            "about": str(identity.get("about") or ""),
            "is_guest": bool(identity.get("is_guest")),
            "is_admin": bool(_is_admin_user(identity)),
            "is_moderator": bool(identity.get("is_moderator")),
            "is_app_device": bool(identity.get("_device_pk") and identity.get("_did")),
            "token": token,
        }

    user = _post("/internal/v1/identity/resolve", {"token": token})
    user["token"] = token
    return user


def verify_password(authorization: str | None, password: str) -> bool:
    if not authorization or not authorization.strip():
        raise HTTPException(401, "Missing token")
    scheme, separator, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not separator or not token:
        raise HTTPException(401, "Invalid authorization header")
    result = _post("/internal/v1/identity/verify-password", {
        "token": token, "password": password,
    })
    return bool(result.get("valid"))


def require_member(user: dict) -> None:
    if user.get("is_guest"):
        raise HTTPException(403, "Войдите или зарегистрируйтесь, чтобы продолжить")


def auth_member(authorization: str | None) -> dict:
    user = auth(authorization)
    require_member(user)
    return user


def award_gost(
    user_id: int, source: str, actor_id: int = 0, ref_type: str = "",
    ref_id: int = 0, amount_override: int | None = None,
) -> dict:
    return _post("/internal/v1/wallet/award", {
        "user_id": user_id, "source": source, "actor_id": actor_id,
        "ref_type": ref_type, "ref_id": ref_id, "amount_override": amount_override,
    })


def send_event(user_id: int, event_type: str, data: dict) -> dict:
    return _post("/internal/v1/events/send", {
        "user_id": user_id, "type": event_type, "data": data,
    })


def broadcast_event(event_type: str, data: dict) -> dict:
    return _post("/internal/v1/events/broadcast", {
        "type": event_type, "data": data,
    })


def _session_token(authorization: str | None) -> str:
    if not authorization or not authorization.strip():
        raise HTTPException(401, "Missing token")
    scheme, separator, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not separator or not token:
        raise HTTPException(401, "Invalid authorization header")
    return token


def recovery_seed(body: dict, client_ip: str) -> dict:
    return _post("/internal/v1/identity/recovery/seed", {
        **body, "client_ip": client_ip,
    })


def regen_seed(body: dict, authorization: str | None) -> dict:
    return _post("/internal/v1/identity/regen-seed", {
        **body, "token": _session_token(authorization),
    })


def password_challenge(body: dict, authorization: str | None) -> dict:
    return _post("/internal/v1/identity/password/challenge", {
        **body, "token": _session_token(authorization),
    })


def password_proof(body: dict, authorization: str | None) -> dict:
    return _post("/internal/v1/identity/password/verify", {
        **body, "token": _session_token(authorization),
    })


def delete_account(body: dict, authorization: str | None) -> dict:
    return _post("/internal/v1/identity/delete-account", {
        **body, "token": _session_token(authorization),
    })


def issue_sso_jwt(authorization: str | None) -> dict:
    return _post("/internal/v1/identity/sso/jwt", {
        "token": _session_token(authorization),
    })


def register(body: dict, client_ip: str, *, version: int) -> dict:
    return _post("/internal/v1/identity/register", {
        **body, "client_ip": client_ip, "auth_version": version,
    })


def login(body: dict, client_ip: str) -> dict:
    return _post("/internal/v1/identity/login", {**body, "client_ip": client_ip})


def login_v2_challenge(body: dict, client_ip: str) -> dict:
    return _post("/internal/v1/identity/login/challenge", {**body, "client_ip": client_ip})


def login_v2_finish(body: dict, client_ip: str) -> dict:
    return _post("/internal/v1/identity/login/finish", {**body, "client_ip": client_ip})


def list_sessions(authorization: str | None) -> dict:
    return _post("/internal/v1/identity/sessions", {
        "token": _session_token(authorization),
    })


def logout(authorization: str | None) -> dict:
    return _post("/internal/v1/identity/logout", {
        "token": _session_token(authorization),
    })


def revoke_session(authorization: str | None, session_id: str) -> dict:
    return _post("/internal/v1/identity/sessions/revoke", {
        "token": _session_token(authorization), "session_id": session_id,
    })
