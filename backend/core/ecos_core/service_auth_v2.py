"""GhostID v2: один запрос на вход и мультиаккаунт на устройстве.

Отличие от замороженного /api/sso — анкета сервиса едет в том же запросе,
что и создание входа, а клиент регистрируется через API без участия админа.
Токены и коды выдаются теми же таблицами, поэтому старые сервисы не ломаются.
"""
from __future__ import annotations

import json
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from urllib.parse import urlencode, urlsplit

from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel, Field

from ecos_core.identity import auth_member, db as identity_db
from ecos_core.login import LoginBody, login as _login
from ecos_core.service_sso import (
    CHAT_TOKEN_TTL,
    _CHALLENGE,
    _OPAQUE,
    _SCOPE_CATALOG,
    _client,
    _db,
    _hash,
    _issuer,
    _origin,
)
from ecos_core.shared import _rate_limit

router = APIRouter(prefix="/api/v2/auth", tags=["GhostID v2"])

MAX_ACCOUNTS_PER_DEVICE = 15      # аккаунтов на одно устройство, дальше только выход
CLIENT_TTL = 0                    # клиент живёт, пока его не отключат
AUTH_TTL = 1800                   # 30 минут на вход: пароль и seed вводят не за секунды
UA_SLUG = re.compile(r"[^a-z0-9]+")

# ── Схема ──────────────────────────────────────────────

AUTHORIZATION_SCHEMA = """
CREATE TABLE IF NOT EXISTS v2_authorizations (
    request_id TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
    scopes TEXT NOT NULL, state TEXT NOT NULL, challenge TEXT NOT NULL,
    anketa TEXT NOT NULL, device_id TEXT, user_id INTEGER, device_pk INTEGER,
    session_hash TEXT,
    created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    code_hash TEXT UNIQUE, code_expires_at INTEGER, redeemed_at INTEGER
);
CREATE INDEX IF NOT EXISTS v2_auth_expiry ON v2_authorizations(expires_at);
"""


@contextmanager
def _v2_db():
    """Пишем в ту же базу, что и замороженный SSO: клиенты и коды общие."""
    manager = _db()
    connection = manager.__enter__()
    try:
        connection.executescript(AUTHORIZATION_SCHEMA)
        try:
            connection.execute("ALTER TABLE v2_authorizations ADD COLUMN session_hash TEXT")
        except sqlite3.OperationalError:
            pass
        connection.commit()
        yield connection
    finally:
        manager.__exit__(None, None, None)


# ── Общие проверки ─────────────────────────────────────

def _ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _slug(name: str) -> str:
    base = UA_SLUG.sub("-", name.strip().lower()).strip("-")[:24]
    return (base or "service") + "-" + secrets.token_hex(3)


def _safe_redirect(url: str) -> bool:
    """Только https и локальная разработка: иначе токен уедет чужому."""
    parsed = urlsplit(url)
    if parsed.scheme == "https" and parsed.netloc:
        return True
    return parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1"}


def _ceiling(config: dict) -> set[str]:
    return {scope for scope in config.get("scopes", []) if scope in _SCOPE_CATALOG}


def _entrance(connection, client_id: str, revision: int, redirect_uri: str,
              scopes: list[str], state: str, challenge: str, anketa: dict,
              device_id: str | None) -> dict:
    request_id = secrets.token_urlsafe(24)
    now = int(time.time())
    connection.execute(
        "INSERT INTO v2_authorizations (request_id,client_id,redirect_uri,scopes,state,"
        "challenge,anketa,device_id,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (request_id, client_id, redirect_uri, json.dumps(scopes, ensure_ascii=False),
         state, challenge, json.dumps(anketa, ensure_ascii=False), device_id,
         now, now + AUTH_TTL),
    )
    connection.commit()
    return {"requestId": request_id, "expiresIn": AUTH_TTL}


def _auth_row(connection, request_id: str):
    if not _OPAQUE.fullmatch(request_id):
        raise HTTPException(404, "Запрос входа не найден")
    row = connection.execute("SELECT * FROM v2_authorizations WHERE request_id=?",
                             (request_id,)).fetchone()
    if not row or row["expires_at"] <= int(time.time()):
        raise HTTPException(410, "Запрос входа устарел. Начните вход заново.")
    return row


def _authorization_url(request_id: str) -> str:
    return _issuer() + "/v2/auth?" + urlencode({"sso_request": request_id})


# ── Модели ─────────────────────────────────────────────

class ClientRegisterBody(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    redirect_uris: list[str] = Field(min_length=1, max_length=10)
    scopes: list[str] = Field(default_factory=lambda: ["identity", "profile"], max_length=10)
    website_url: str = ""
    reason: str = Field(default="", max_length=200)


class AuthorizeBody(BaseModel):
    client_id: str = Field(min_length=3, max_length=64)
    redirect_uri: str = Field(min_length=8, max_length=400)
    state: str = Field(default="", max_length=200)
    scopes: list[str] | None = None
    anketa: dict | None = None
    device_id: str | None = Field(default=None, max_length=120)
    challenge: str = Field(min_length=43, max_length=43)


class LoginV2Body(LoginBody):
    """Проверка пароля остаётся за ядром входа, здесь только учёт аккаунтов."""


# ── Клиенты ────────────────────────────────────────────

@router.post("/clients", status_code=201)
def register_client(body: ClientRegisterBody, request: Request):
    """Саморегистрация сервиса: админ больше не нужен, потолок прав задаём здесь."""
    _rate_limit("auth-v2-clients:" + _ip(request), limit=5, window=3600)
    for uri in body.redirect_uris:
        if not _safe_redirect(uri):
            raise HTTPException(422, "Адрес возврата должен быть https, кроме localhost")
    unknown = [scope for scope in body.scopes if scope not in _SCOPE_CATALOG]
    if unknown:
        raise HTTPException(422, "Неизвестные права: " + ", ".join(unknown))
    client_id = _slug(body.name)
    issuer = _issuer()
    config = {
        "client_id": client_id, "name": body.name,
        "icon": (body.website_url or issuer) + "/favicon.png",
        "website_url": body.website_url or issuer,
        "redirect_uris": body.redirect_uris,
        "redirect_origins": sorted({_origin(uri) for uri in body.redirect_uris}),
        "scopes": list(dict.fromkeys(body.scopes)),
        "terms_url": issuer + "/terms", "privacy_url": issuer + "/privacy",
        "terms_version": "2026-11-16", "privacy_version": "2026-11-16",
        "enabled": True, "trusted": False, "transport": "authorization-code",
        "destination": body.name, "reason": body.reason,
        "permissions": [_SCOPE_CATALOG[s]["description"] for s in body.scopes],
    }
    with _v2_db() as connection:
        connection.execute(
            "INSERT INTO clients (client_id, config, revision, owner_id, updated_at) "
            "VALUES (?, ?, 1, 0, ?)",
            (client_id, json.dumps(config, ensure_ascii=False), int(time.time())))
        connection.commit()
    return {"clientId": client_id, "scopes": config["scopes"],
            "redirectUris": body.redirect_uris}


# ── Вход ───────────────────────────────────────────────

@router.post("/authorize", status_code=201)
def authorize(body: AuthorizeBody, request: Request):
    """Один запрос сервиса: анкета, скоупы и код-челлендж сразу, без второго похода."""
    _rate_limit("auth-v2-authorize:" + _ip(request), limit=60, window=60)
    if not _CHALLENGE.fullmatch(body.challenge):
        raise HTTPException(422, "Нужен PKCE-челлендж S256")
    with _v2_db() as connection:
        config, revision = _client(connection, body.client_id)
        allowed = config.get("redirect_uris") or []
        if body.redirect_uri not in allowed:
            raise HTTPException(403, "Адрес возврата не зарегистрирован для сервиса")
        ceiling = _ceiling(config)
        asked = body.scopes or sorted(ceiling)
        extra = [scope for scope in asked if scope not in ceiling]
        if extra:
            raise HTTPException(403, "Сервису не разрешены права: " + ", ".join(extra))
        anketa = dict(body.anketa or {})
        anketa.setdefault("name", config["name"])
        anketa.setdefault("icon", config.get("icon", ""))
        anketa.setdefault("scopes", asked)
        anketa.setdefault("reason", config.get("reason", ""))
        created = _entrance(connection, body.client_id, revision, body.redirect_uri,
                            asked, body.state, body.challenge, anketa, body.device_id)
    return {**created, "url": _authorization_url(created["requestId"]),
            "anketa": anketa}


@router.get("/requests/{request_id}")
def request_info(request_id: str):
    """Анкета для страницы входа: сервис, права, причина."""
    with _v2_db() as connection:
        row = _auth_row(connection, request_id)
        config, _ = _client(connection, row["client_id"])
        scopes = json.loads(row["scopes"])
        details = [
            {"id": scope, "title": _SCOPE_CATALOG[scope]["title"],
             "description": _SCOPE_CATALOG[scope]["description"],
             "required": _SCOPE_CATALOG[scope]["required"]}
            for scope in scopes if scope in _SCOPE_CATALOG
        ]
        return {
            "requestId": row["request_id"], "clientId": row["client_id"],
            "name": config["name"], "icon": config.get("icon", ""),
            "websiteUrl": config.get("website_url", ""),
            "anketa": json.loads(row["anketa"]), "scopes": scopes,
            "scopesDetail": details, "state": row["state"],
            "redirectUri": row["redirect_uri"],
            "expiresIn": max(0, int(row["expires_at"]) - int(time.time())),
        }


@router.post("/requests/{request_id}/renew")
def request_renew(request_id: str):
    """Страница входа просит продлить ссылку: пароль и seed вводят не за секунды."""
    if not _OPAQUE.fullmatch(request_id):
        raise HTTPException(404, "Запрос входа не найден")
    now = int(time.time())
    with _v2_db() as connection:
        row = connection.execute(
            "SELECT * FROM v2_authorizations WHERE request_id=?", (request_id,)
        ).fetchone()
        if not row or row["code_hash"] or row["redeemed_at"] is not None:
            raise HTTPException(404, "Запрос входа не найден")
        # Дольше суток висящую ссылку не продлеваем: это уже не «не успел ввести пароль».
        if int(row["expires_at"]) + 86400 < now:
            raise HTTPException(410, "Запрос входа устарел. Начните вход заново.")
        connection.execute(
            "UPDATE v2_authorizations SET expires_at=? WHERE request_id=?",
            (now + AUTH_TTL, request_id),
        )
        connection.commit()
    return {"requestId": request_id, "expiresIn": AUTH_TTL}


@router.post("/login")
def login(body: LoginV2Body, request: Request, response: Response):
    """Пароль проверяет ядро; здесь только лимит аккаунтов на устройстве."""
    result = _login(body, _ip(request))
    if result.get("requires_approval"):
        return result
    device_id = result.get("device_id") or body.device_id
    if device_id:
        # Сессии и устройства живут в базе аккаунтов, не в базе SSO.
        connection = identity_db()
        try:
            accounts = connection.execute(
                "SELECT COUNT(DISTINCT s.user_id) AS n FROM auth_sessions s "
                "JOIN user_devices d ON d.id = s.device_pk "
                "WHERE d.device_id=? AND s.status='active' AND s.expires_at>?",
                (device_id, int(time.time()))).fetchone()["n"]
        finally:
            connection.close()
        if accounts > MAX_ACCOUNTS_PER_DEVICE:
            _revoke_session(result.get("session_id"), result.get("id"))
            raise HTTPException(409, {
                "code": "device_limit_reached",
                "limit": MAX_ACCOUNTS_PER_DEVICE,
                "message": "На устройстве уже 15 аккаунтов. Выйдите из одного и повторите.",
            })
    if result.get("token") and result.get("id"):
        # Ключ аккаунта кладём в HttpOnly-cookie: им браузер докажет право на switch.
        account = identity_db()
        try:
            device_pk = _device_pk(account, result["token"], int(result["id"]))
        finally:
            account.close()
        with _v2_db() as connection:
            _remember_account(connection, response, int(result["id"]), device_pk, device_id)
    return result


def _revoke_session(session_id, user_id):
    """Свежую сессию сверх лимита гасим сразу, чтобы не осталось хвоста."""
    if not session_id or not user_id:
        return
    connection = identity_db()
    try:
        connection.execute(
            "UPDATE auth_sessions SET status='revoked', revoked_at=? "
            "WHERE session_id=? AND user_id=? AND status='active'",
            (int(time.time()), session_id, int(user_id)))
        connection.commit()
    finally:
        connection.close()


# ── Аккаунты и устройства ──────────────────────────────

def _bearer(request: Request) -> tuple[str, dict]:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "Нужна сессия GhostID")
    user = auth_member(header)
    return header.split(" ", 1)[1].strip(), user


def _device_pk(connection, token: str, user_id: int) -> int | None:
    from ecos_core.sessions import token_hash

    row = connection.execute(
        "SELECT device_pk FROM auth_sessions WHERE token_hash=? AND user_id=? "
        "AND status='active' AND expires_at>?",
        (token_hash(token), int(user_id), int(time.time()))).fetchone()
    return int(row["device_pk"]) if row and row["device_pk"] else None


def _service_token(token: str, user_id: int) -> dict | None:
    """Сервисный токен живёт в базе SSO, а не в базе аккаунтов."""
    from ecos_core import service_sso as sso

    try:
        with sso._db() as connection:
            row = connection.execute(
                "SELECT scopes, source_hash FROM access_tokens WHERE token_hash=? AND user_id=? "
                "AND expires_at>?",
                (sso._hash(token), int(user_id), int(time.time()))).fetchone()
    except sqlite3.Error:
        return None
    if not row:
        return None
    try:
        scopes = json.loads(row["scopes"] or "[]")
    except ValueError:
        scopes = str(row["scopes"] or "").split()
    return {"scopes": scopes, "source_hash": row["source_hash"]}


def _device_from_service(connection, token: str, user_id: int) -> int | None:
    """Устройство сервисного входа: сессия GhostID, которая его инициировала, лежит в source_hash."""
    info = _service_token(token, user_id)
    if not info or not info["source_hash"]:
        return None
    row = connection.execute(
        "SELECT device_pk FROM auth_sessions WHERE token_hash=? AND user_id=? "
        "AND status='active' AND expires_at>?",
        (info["source_hash"], int(user_id), int(time.time()))).fetchone()
    return int(row["device_pk"]) if row and row["device_pk"] else None


@router.get("/accounts")
def accounts(request: Request):
    """Аккаунты, живые на этом устройстве; истёкшие браузер помечает сам."""
    token, user = _bearer(request)
    uid = int(user["id"])
    connection = identity_db()
    try:
        device_pk = _device_pk(connection, token, uid)
        if not device_pk:
            # Сервисный токен: устройство определяем по сессии GhostID, начавшей вход,
            # и только если сервису выдано право device.
            info = _service_token(token, uid)
            if not info:
                raise HTTPException(409, "Сессия не привязана к устройству")
            if "device" not in info["scopes"]:
                raise HTTPException(403, "Сервису не выдано право device")
            device_pk = _device_from_service(connection, token, uid)
            if not device_pk:
                raise HTTPException(409, "Сессия не привязана к устройству")
        rows = connection.execute(
            "SELECT DISTINCT s.user_id, u.username, u.display_name, u.avatar_url, "
            "MAX(s.last_seen_at) AS last_seen FROM auth_sessions s "
            "JOIN users u ON u.id = s.user_id "
            "WHERE s.device_pk=? AND s.status='active' AND s.expires_at>? "
            "GROUP BY s.user_id ORDER BY last_seen DESC",
            (device_pk, int(time.time()))).fetchall()
        items = [{
            "id": int(row["user_id"]), "username": row["username"],
            "displayName": row["display_name"] or row["username"],
            "avatarUrl": row["avatar_url"],
            "lastSeen": int(row["last_seen"] or 0),
            "current": int(row["user_id"]) == int(user["id"]),
        } for row in rows]
    finally:
        connection.close()
    return {"accounts": items, "limit": MAX_ACCOUNTS_PER_DEVICE,
            "canAdd": len(items) < MAX_ACCOUNTS_PER_DEVICE}


@router.get("/devices")
def devices(request: Request):
    """Где ещё открыт этот аккаунт; отзыв закрывает все его сессии в сервисах."""
    _, user = _bearer(request)
    connection = identity_db()
    try:
        rows = connection.execute(
            "SELECT d.id, d.device_id, d.device_name, d.platform, d.last_seen, "
            "COUNT(s.session_id) AS sessions FROM user_devices d "
            "LEFT JOIN auth_sessions s ON s.device_pk=d.id AND s.status='active' "
            "AND s.expires_at>? WHERE d.user_id=? GROUP BY d.id ORDER BY d.last_seen DESC",
            (int(time.time()), int(user["id"]))).fetchall()
        return {"devices": [{
            "id": int(row["id"]), "deviceId": row["device_id"],
            "name": row["device_name"] or "Устройство",
            "platform": row["platform"] or "unknown",
            "lastSeen": int(row["last_seen"] or 0),
            "sessions": int(row["sessions"] or 0),
        } for row in rows]}
    finally:
        connection.close()


@router.post("/devices/{device_pk}/revoke")
def revoke_device(device_pk: int, request: Request):
    token, user = _bearer(request)
    connection = identity_db()
    try:
        own = _device_pk(connection, token, int(user["id"]))
        if own is None:
            raise HTTPException(409, "Сессия не привязана к устройству")
        if own == device_pk:
            raise HTTPException(409, "Текущее устройство закрывайте выходом из аккаунта")
        now = int(time.time())
        cursor = connection.execute(
            "UPDATE auth_sessions SET status='revoked', revoked_at=? "
            "WHERE device_pk=? AND user_id=? AND status='active'",
            (now, device_pk, int(user["id"])))
        connection.commit()
        if not cursor.rowcount:
            raise HTTPException(404, "Устройство не найдено")
        return {"id": device_pk, "revoked": cursor.rowcount}
    finally:
        connection.close()


@router.post("/logout")
def logout(request: Request, response: Response):
    """Выход с этого устройства: сессии GhostID, выданные здесь, умирают вместе с сервисными."""
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "Нужна сессия GhostID")
    from ecos_core.sessions import logout_for_token

    user = auth_member(header)
    result = logout_for_token(header)
    with _v2_db() as connection:
        _forget_account(connection, response, int(user["id"]))
    return result


@router.post("/logout-all")
def logout_all(request: Request):
    _, user = _bearer(request)
    from ecos_core.sessions import revoke_all_sessions

    connection = identity_db()
    try:
        revoke_all_sessions(connection, int(user["id"]), reason="user_logout_all")
        connection.commit()
    finally:
        connection.close()
    return {"revoked": True}


# ── Выдача доступа и токены ────────────────────────────

class ApproveV2Body(BaseModel):
    scopes: list[str] | None = None


@router.post("/requests/{request_id}/approve")
def approve(request_id: str, body: ApproveV2Body, request: Request):
    """Согласие всегда заново: код живёт минуту и обменивается один раз."""
    token, user = _bearer(request)
    from ecos_core.sessions import token_hash as _session_digest  # noqa: PLC0415

    approving_session = _session_digest(token)
    connection = identity_db()
    try:
        device_pk = _device_pk(connection, token, int(user["id"]))
    finally:
        connection.close()
    with _v2_db() as connection:
        row = _auth_row(connection, request_id)
        if row["code_hash"]:
            raise HTTPException(409, "Доступ по этому запросу уже выдан")
        granted = json.loads(row["scopes"])
        chosen = body.scopes or granted
        extra = [scope for scope in chosen if scope not in granted]
        if extra:
            raise HTTPException(403, "Сервис не просил эти права: " + ", ".join(extra))
        code = secrets.token_urlsafe(32)
        now = int(time.time())
        connection.execute(
            "UPDATE v2_authorizations SET user_id=?, device_pk=?, session_hash=?, scopes=?, "
            "code_hash=?, code_expires_at=? WHERE request_id=?",
            (int(user["id"]), device_pk, approving_session,
             json.dumps(chosen, ensure_ascii=False),
             _hash(code), now + 60, request_id))
        connection.commit()
        parsed = urlsplit(row["redirect_uri"])
    query = urlencode({"code": code, "state": row["state"], "iss": _issuer()})
    separator = "&" if parsed.query else "?"
    return {"code": code,
            "redirectUrl": f"{parsed.scheme}://{parsed.netloc}{parsed.path}{separator}{query}",
            "scopes": chosen}


class TokenV2Body(BaseModel):
    grant_type: str = "authorization_code"
    code: str | None = None
    redirect_uri: str | None = None
    client_id: str | None = None
    code_verifier: str | None = None
    refresh_token: str | None = None


@router.post("/token")
def token(body: TokenV2Body, request: Request):
    """Код + PKCE: секрета у сервиса нет, браузер токен не видит."""
    _rate_limit("auth-v2-token:" + _ip(request), limit=60, window=60)
    from ecos_core.service_sso import _issue_access, _issue_refresh, _pkce  # noqa: PLC0415

    with _v2_db() as connection:
        if body.grant_type == "refresh_token":
            if not body.refresh_token:
                raise HTTPException(422, "Нужен refresh_token")
            row = connection.execute(
                "SELECT * FROM refresh_tokens WHERE token_hash=?",
                (_hash(body.refresh_token),)).fetchone()
            if not row or row["redeemed_at"] or row["expires_at"] <= int(time.time()):
                raise HTTPException(401, "refresh_token больше не действует")
            if body.client_id and body.client_id != row["client_id"]:
                raise HTTPException(401, "refresh_token выдан другому сервису")
            if _session_revoked(row["source_hash"], int(row["user_id"])):
                raise HTTPException(401, "Сессия GhostID отозвана — войдите заново")
            scopes = json.loads(row["scopes"])
            connection.execute("UPDATE refresh_tokens SET redeemed_at=? WHERE token_hash=?",
                               (int(time.time()), row["token_hash"]))
            access = _issue_access(connection, row["client_id"], row["revision"],
                                   int(row["user_id"]), json.dumps(scopes, ensure_ascii=False),
                                   CHAT_TOKEN_TTL, row["source_hash"])
            refresh = _issue_refresh(connection, row["client_id"], row["revision"],
                                     int(row["user_id"]), json.dumps(scopes, ensure_ascii=False),
                                     row["source_hash"])
            connection.commit()
            return {"access_token": access, "refresh_token": refresh,
                    "token_type": "Bearer", "expires_in": CHAT_TOKEN_TTL,
                    "scopes": scopes}

        if not body.code or not body.client_id or not body.redirect_uri:
            raise HTTPException(422, "Нужны code, client_id и redirect_uri")
        if not body.code_verifier:
            raise HTTPException(422, "Нужен code_verifier")
        row = connection.execute("SELECT * FROM v2_authorizations WHERE code_hash=?",
                                 (_hash(body.code),)).fetchone()
        if not row or row["redeemed_at"] or not row["code_expires_at"]:
            raise HTTPException(401, "Код недействителен или уже использован")
        if int(row["code_expires_at"]) <= int(time.time()):
            raise HTTPException(401, "Код истёк, начните вход заново")
        if body.client_id != row["client_id"] or body.redirect_uri != row["redirect_uri"]:
            raise HTTPException(401, "Код выдан другому сервису или адресу возврата")
        if _pkce(body.code_verifier) != row["challenge"]:
            raise HTTPException(401, "PKCE-проверка не пройдена")
        if _session_revoked(row["session_hash"], int(row["user_id"])):
            raise HTTPException(401, "Сессия GhostID отозвана — войдите заново")
        scopes = json.loads(row["scopes"])
        config, revision = _client(connection, row["client_id"])
        connection.execute("UPDATE v2_authorizations SET redeemed_at=? WHERE request_id=?",
                           (int(time.time()), row["request_id"]))
        access = _issue_access(connection, row["client_id"], revision, int(row["user_id"]),
                               json.dumps(scopes, ensure_ascii=False), CHAT_TOKEN_TTL,
                               row["session_hash"])
        refresh = _issue_refresh(connection, row["client_id"], revision, int(row["user_id"]),
                                 json.dumps(scopes, ensure_ascii=False),
                               row["session_hash"])
        connection.commit()
    return {"access_token": access, "refresh_token": refresh, "token_type": "Bearer",
            "expires_in": CHAT_TOKEN_TTL, "scopes": scopes}


def _session_revoked(source_hash, user_id: int) -> bool:
    """True только при явном отзыве сессии GhostID; неизвестная — не повод отказать."""
    if not source_hash:
        return False
    from ecos_core.sessions import session_is_active_hash  # noqa: PLC0415

    connection = identity_db()
    try:
        return session_is_active_hash(connection, source_hash, int(user_id)) is False
    except sqlite3.OperationalError:
        return False
    finally:
        connection.close()


# ── Профиль и регистрация ──────────────────────────────

@router.get("/me")
def me(request: Request):
    _, user = _bearer(request)
    return {"id": int(user["id"]), "username": user.get("username", ""),
            "displayName": user.get("display_name") or user.get("username", ""),
            "avatarUrl": user.get("avatar_url"), "isAdmin": bool(user.get("is_admin"))}


@router.post("/register", status_code=201)
def register(request: Request):
    """Регистрация остаётся одна: правила живут в модуле регистрации."""
    from ecos_core.registration import RegisterBody, register as _register  # noqa: PLC0415

    payload = dict(request.query_params)
    body = RegisterBody(**payload)
    return _register(body, _ip(request))


# ── Переключение между аккаунтами ──────────────────────

ACCOUNT_COOKIE = "gid_acc_{user_id}"
ACCOUNT_TTL = 365 * 86400      # год: столько же живёт сессия GhostID

DEVICE_ACCOUNT_SCHEMA = """
CREATE TABLE IF NOT EXISTS v2_device_accounts (
    account_key_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, device_pk INTEGER,
    device_id TEXT, created_at INTEGER NOT NULL, last_used INTEGER NOT NULL
);
"""


def _account_cookie_name(user_id: int) -> str:
    return ACCOUNT_COOKIE.format(user_id=int(user_id))


def _remember_account(connection, response, user_id: int, device_pk, device_id) -> None:
    """Ключ аккаунта лежит в HttpOnly-cookie: браузер не может его прочитать."""
    connection.executescript(DEVICE_ACCOUNT_SCHEMA)
    secret = secrets.token_urlsafe(32)
    now = int(time.time())
    connection.execute(
        "INSERT OR REPLACE INTO v2_device_accounts (account_key_hash, user_id, device_pk, "
        "device_id, created_at, last_used) VALUES (?, ?, ?, ?, ?, ?)",
        (_hash(secret), int(user_id), device_pk, device_id, now, now))
    connection.commit()
    response.set_cookie(_account_cookie_name(user_id), secret, max_age=ACCOUNT_TTL,
                        httponly=True, secure=True, samesite="lax", path="/api/v2/auth")


def _forget_account(connection, response, user_id: int) -> None:
    connection.executescript(DEVICE_ACCOUNT_SCHEMA)
    connection.execute("DELETE FROM v2_device_accounts WHERE user_id=?", (int(user_id),))
    connection.commit()
    response.delete_cookie(_account_cookie_name(user_id), path="/api/v2/auth")


class SwitchBody(BaseModel):
    account_id: int


@router.post("/switch")
def switch(body: SwitchBody, request: Request, response: Response):
    """Без пароля: браузер доказывает владение ключом аккаунта HttpOnly-cookie."""
    secret = request.cookies.get(_account_cookie_name(body.account_id))
    if not secret:
        raise HTTPException(401, "Нет сохранённого ключа этого аккаунта: войдите паролем")
    from ecos_core.sessions import create_session  # noqa: PLC0415

    with _v2_db() as connection:
        connection.executescript(DEVICE_ACCOUNT_SCHEMA)
        row = connection.execute(
            "SELECT * FROM v2_device_accounts WHERE account_key_hash=? AND user_id=?",
            (_hash(secret), int(body.account_id))).fetchone()
        if not row:
            raise HTTPException(401, "Ключ аккаунта больше не действует: войдите паролем")
        device_pk = int(row["device_pk"]) if row["device_pk"] else None
        connection.execute("UPDATE v2_device_accounts SET last_used=? WHERE account_key_hash=?",
                           (int(time.time()), row["account_key_hash"]))
        connection.commit()
    account = identity_db()
    try:
        user = account.execute("SELECT * FROM users WHERE id=?",
                               (int(body.account_id),)).fetchone()
        if not user:
            raise HTTPException(404, "Аккаунт больше не существует")
        session = create_session(account, int(user["id"]), device_pk, auth_method="switch")
    finally:
        account.close()
    with _v2_db() as connection:
        _remember_account(connection, response, int(user["id"]), device_pk, row["device_id"])
    return {"id": int(user["id"]), "username": user["username"],
            "displayName": user["display_name"] or user["username"],
            "token": session["token"], "session_id": session["session_id"],
            "expires_at": session["expires_at"]}


def install(app):
    app.include_router(router)


