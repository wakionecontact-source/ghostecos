"""Data-driven GhostID login for registered web services; legacy Telegram adapter.

Public clients use short-lived authorization codes with S256 PKCE. Registration
is restricted to existing Core administrators. No ecosystem session token is
returned to a relying service. This API is not a complete OpenID provider.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from fastapi import APIRouter, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic_core import PydanticCustomError

from ecos_core.identity import auth_member, db as identity_db
from ecos_core.shared import _is_admin_user, _rate_limit

_FIELD_LABELS = {
    "body": "тело запроса в формате JSON", "client_id": "идентификатор сервиса",
    "name": "название сервиса", "redirect_uris": "адреса возврата",
    "redirect_uri": "адрес возврата", "scopes": "разрешения",
    "state": "идентификатор попытки входа", "code_challenge": "PKCE challenge",
    "code_challenge_method": "метод PKCE", "prompt": "сценарий входа",
    "consent": "решение пользователя о доступе", "code": "код авторизации",
    "code_verifier": "PKCE verifier", "grant_type": "тип обмена кода",
    "icon": "иконка сервиса", "website_url": "адрес сайта",
    "terms_url": "адрес условий использования", "privacy_url": "адрес политики конфиденциальности",
    "terms_version": "версия условий использования", "privacy_version": "версия политики конфиденциальности",
    "enabled": "доступность входа",
}


def _field_error(field: str, code: str, reason: str = "") -> dict:
    label = _FIELD_LABELS.get(field.split("[")[0], "данные запроса")
    if code == "required":
        message = f"Не указано поле {field} ({label})"
    elif code == "unknown_field":
        message = f"Неизвестное поле {field}"
    else:
        message = f"Некорректное поле {field} ({label})"
        if reason:
            message += ": " + reason
    return {"field": field, "code": code, "message": message}


def _data_response(errors: list[dict]) -> JSONResponse:
    missing = list(dict.fromkeys(error["field"] for error in errors if error["code"] == "required"))
    return JSONResponse({"detail": "; ".join(error["message"] for error in errors),
                         "code": "missing_fields" if len(missing) == len(errors) else "invalid_data",
                         "missing_fields": missing, "errors": errors}, status_code=422)


class SSODataError(Exception):
    def __init__(self, field: str, reason: str = "", *, required: bool = False):
        self.error = _field_error(field, "required" if required else "invalid", reason)


class SSORoute(APIRoute):
    """Format only this API's validation errors, without echoing codes or tokens."""
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def checked(request: Request):
            try:
                return await handler(request)
            except SSODataError as exc:
                return _data_response([exc.error])
            except RequestValidationError as exc:
                errors = []
                for error in exc.errors():
                    location = error.get("loc", ("body",))
                    parts = location[1:] if location and location[0] in {"body", "query", "path"} else location
                    field = "".join(f"[{part}]" if isinstance(part, int) else ("." if index else "") + str(part)
                                    for index, part in enumerate(parts)) or "body"
                    kind = error.get("type")
                    if kind == "json_invalid":
                        field = "body"
                    if kind in {"missing", "required_data"}:
                        errors.append(_field_error(field, "required"))
                    elif kind == "extra_forbidden":
                        errors.append(_field_error(field, "unknown_field"))
                    else:
                        reason = {"json_invalid": "нужен корректный JSON", "string_type": "ожидается строка",
                                  "list_type": "ожидается список", "bool_parsing": "ожидается true или false",
                                  "bool_type": "ожидается true или false",
                                  "model_attributes_type": "ожидается JSON-объект"}.get(kind, "недопустимое значение")
                        errors.append(_field_error(field, "invalid", reason))
                return _data_response(errors)

        return checked


router = APIRouter(prefix="/api/sso", tags=["GhostID service login"], route_class=SSORoute)
_ID = re.compile(r"^[a-z][a-z0-9_-]{2,63}$")
_OPAQUE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
_VERIFIER = re.compile(r"^[A-Za-z0-9._~-]{43,128}$")
_CHALLENGE = re.compile(r"^[A-Za-z0-9_-]{43}$")
_SCOPES = {
    "identity": "GhostID и имя пользователя для входа",
    "profile": "Публичные имя и аватар профиля",
}
_REQUEST_TTL, _CODE_TTL, _TOKEN_TTL = 600, 120, 900
_RESERVED_QUERY = {"code", "state", "error", "error_description", "iss"}


def _issuer() -> str:
    return os.getenv("GE_SSO_ISSUER", "https://ghostecos.duckdns.org").rstrip("/")


def _origin(url: str) -> str:
    parsed = urlsplit(url)
    return f"{parsed.scheme}://{parsed.netloc}"


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()


def _pkce(value: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(value.encode("ascii")).digest()).rstrip(b"=").decode("ascii")


def _url(value: str, *, local: bool = False, callback: bool = False, field: str = "url") -> str:
    if not value.strip():
        raise SSODataError(field, required=True)
    if local and value.startswith("/") and not value.startswith("//"):
        value = _issuer() + value
    try:
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise ValueError()
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise ValueError()
        if any(ord(ch) < 33 or ch == "\\" for ch in value) or len(value) > 2048:
            raise ValueError()
        if callback and any(key in _RESERVED_QUERY for key, _ in parse_qsl(parsed.query)):
            raise ValueError()
    except (ValueError, TypeError):
        raise SSODataError(field, "нужен HTTPS-адрес без логина, пароля и фрагмента")
    return value


class SSOBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    @field_validator("*", mode="before")
    @classmethod
    def nonempty_data(cls, value, info):
        field = cls.model_fields[info.field_name]
        if value is None and field.default is None:
            return value
        if (value is None or isinstance(value, list) and not value
                or isinstance(value, str) and not value.strip() and field.default != ""):
            raise PydanticCustomError("required_data", "Не указано обязательное поле")
        return value


class ClientBody(SSOBody):
    client_id: str = Field(min_length=3, max_length=64)
    name: str = Field(min_length=1, max_length=80)
    redirect_uris: list[str] = Field(min_length=1, max_length=10)
    icon: str = Field(default="", max_length=2048)
    website_url: str = Field(default="", max_length=2048)
    scopes: list[str] = Field(default_factory=lambda: ["identity", "profile"], min_length=1, max_length=3)
    terms_url: str = "/terms"
    privacy_url: str = "/privacy"
    terms_version: str = Field(default="2026-10-03", min_length=1, max_length=80)
    privacy_version: str = Field(default="2026-10-03", min_length=1, max_length=80)
    enabled: bool = True


class EntranceBody(SSOBody):
    client_id: str = Field(min_length=3, max_length=64)
    redirect_uri: str | None = Field(default=None, max_length=2048)
    scopes: list[str] | None = Field(default=None, min_length=1, max_length=3)
    state: str | None = Field(default=None, min_length=16, max_length=512)
    code_challenge: str | None = Field(default=None, min_length=43, max_length=43)
    code_challenge_method: str = "S256"
    prompt: str = "select_account"


class ApproveBody(SSOBody):
    consent: bool
    automatic: bool = False


class TokenBody(SSOBody):
    grant_type: str = "authorization_code"
    client_id: str = Field(min_length=3, max_length=64)
    code: str = Field(min_length=32, max_length=128)
    redirect_uri: str = Field(min_length=1, max_length=2048)
    code_verifier: str = Field(min_length=43, max_length=128)


def _seeds() -> list[dict]:
    issuer = _issuer()
    return [
        {
            "client_id": "ghostchat", "name": "GhostChat", "icon": issuer + "/favicon.png",
            "website_url": issuer, "redirect_uris": [issuer + "/auth/sso-demo.html", issuer + "/v2/chat/sso/callback"],
            "scopes": ["identity", "profile", "chat"], "terms_url": issuer + "/terms", "privacy_url": issuer + "/privacy",
            "terms_version": "2026-10-03", "privacy_version": "2026-10-03",
            "enabled": True, "trusted": True, "transport": "authorization-code",
        },
        {
            "client_id": "ghogem_bot", "name": "GhoGemo", "icon": issuer + "/ghogem/ghogemava.jpg",
            "website_url": "https://t.me", "redirect_uris": [], "redirect_origins": ["https://t.me"],
            "scopes": ["ghostid:basic", "telegram:link"], "terms_url": issuer + "/terms", "privacy_url": issuer + "/privacy",
            "terms_version": "2026-09-28", "privacy_version": "2026-09-28",
            "enabled": True, "trusted": True, "transport": "telegram-start",
            "destination": "Telegram-бот GhoGemo", "authorization_endpoint": "/ghogem-api/auth/link/webapp",
            "permissions": ["ID и имя пользователя GhostEcos, чтобы определить выбранный аккаунт",
                            "Telegram ID и публичное имя пользователя для привязки и входа в бота",
                            "После привязки чаты и файлы GhoGemo будут общими между сайтом и ботом"],
        },
    ]


@contextmanager
def _db():
    path = Path(os.getenv("GE_SSO_DB_PATH", "/opt/ghostecos-core/private/service_sso.sqlite3"))
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=5)
    connection.row_factory = sqlite3.Row
    os.chmod(path, 0o600)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=5000")
    connection.executescript("""
        CREATE TABLE IF NOT EXISTS clients (
            client_id TEXT PRIMARY KEY, config TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
            owner_id INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS entrances (
            request_id TEXT PRIMARY KEY, client_id TEXT NOT NULL, revision INTEGER NOT NULL,
            redirect_uri TEXT NOT NULL, scopes TEXT NOT NULL, state TEXT NOT NULL,
            challenge TEXT NOT NULL, prompt TEXT NOT NULL, expires_at INTEGER NOT NULL,
            decided_at INTEGER, user_id INTEGER, code_hash TEXT UNIQUE, code_expires_at INTEGER, redeemed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS access_tokens (
            token_hash TEXT PRIMARY KEY, client_id TEXT NOT NULL, revision INTEGER NOT NULL,
            user_id INTEGER NOT NULL, scopes TEXT NOT NULL, expires_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS consents (
            user_id INTEGER NOT NULL, client_id TEXT NOT NULL, revision INTEGER NOT NULL,
            scopes TEXT NOT NULL, accepted_at INTEGER NOT NULL,
            PRIMARY KEY(user_id, client_id, revision)
        );
        CREATE INDEX IF NOT EXISTS entrance_expiry ON entrances(expires_at);
        CREATE INDEX IF NOT EXISTS access_expiry ON access_tokens(expires_at);
    """)
    for seed in _seeds():
        connection.execute("INSERT OR IGNORE INTO clients VALUES (?, ?, 1, 0, ?)",
                           (seed["client_id"], json.dumps(seed, ensure_ascii=False), int(time.time())))
    for table in ("entrances", "access_tokens"):
        columns = {r[1] for r in connection.execute(f"PRAGMA table_info({table})")}
        if "source_hash" not in columns:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN source_hash TEXT")
    existing = connection.execute("SELECT config, revision, owner_id FROM clients WHERE client_id='ghostchat'").fetchone()
    if existing and existing["owner_id"] == 0:
        config = json.loads(existing["config"])
        if config.get("trusted") and "chat" not in config["scopes"]:
            config["scopes"].append("chat")
            connection.execute("UPDATE clients SET config=?, revision=revision+1, updated_at=? WHERE client_id='ghostchat'",
                               (json.dumps(config, ensure_ascii=False), int(time.time())))
    connection.commit()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def _client(connection, client_id: str) -> tuple[dict, int]:
    row = connection.execute("SELECT config, revision FROM clients WHERE client_id=?", (client_id,)).fetchone()
    if not row:
        raise HTTPException(404, "Сервис не подключён к GhostID")
    config = json.loads(row["config"])
    if not config["enabled"]:
        raise HTTPException(403, "Вход в этот сервис отключён")
    return config, row["revision"]


_CHAT_PERMISSION = "Чаты, устройства, зашифрованные сообщения, файлы, звонки и боты GhostChat"


def _public(config: dict, revision: int, scopes: list[str] | None = None) -> dict:
    scopes = config["scopes"] if scopes is None else scopes
    legacy = config["transport"] == "telegram-start"
    origins = config.get("redirect_origins") or sorted({_origin(url) for url in config["redirect_uris"]})
    return {
        "clientId": config["client_id"], "name": config["name"], "icon": config["icon"],
        "websiteUrl": config["website_url"], "trusted": config.get("trusted", False),
        "destination": config.get("destination") or config["name"],
        "transport": config["transport"], "revision": revision, "scopes": scopes,
        "authorizationEndpoint": config.get("authorization_endpoint", ""),
        "redirectOrigins": origins, "redirectUris": config["redirect_uris"],
        "termsUrl": config["terms_url"], "privacyUrl": config["privacy_url"],
        "termsVersion": config["terms_version"], "privacyVersion": config["privacy_version"],
        "permissions": config["permissions"] if legacy else [(_CHAT_PERMISSION if scope == "chat" else _SCOPES[scope]) for scope in scopes],
    }


def _member(request: Request) -> dict:
    authorization = request.headers.get("authorization")
    if not authorization and request.headers.get("x-gs-token"):
        authorization = "Bearer " + request.headers["x-gs-token"]
    if not authorization:
        raise HTTPException(401, "Не указана сессия GhostEcos: нужен заголовок Authorization или X-Gs-Token")
    if authorization and len(authorization) > 4200:
        raise HTTPException(401, "Invalid authorization header")
    return auth_member(authorization)


def _admin(request: Request) -> dict:
    user = _member(request)
    if not _is_admin_user(user):
        raise HTTPException(403, "Подключать и менять сервисы может только администратор GhostEcos")
    return user


def _check_origin(request: Request, config: dict, *, local_only: bool = False):
    origin = request.headers.get("origin")
    allowed = {_origin(_issuer())} if local_only else {_origin(url) for url in config["redirect_uris"]} | {_origin(_issuer())}
    if origin and origin not in allowed:
        raise HTTPException(403, "Origin does not belong to this service")


def _limit(request: Request, operation: str, limit: int = 60):
    ip = request.client.host if request.client else "unknown"
    _rate_limit("service-sso:" + operation + ":" + ip, limit=limit, window=60)


def _request(connection, request_id: str):
    if not _OPAQUE.fullmatch(request_id):
        raise HTTPException(404, "Запрос входа не найден")
    row = connection.execute("SELECT * FROM entrances WHERE request_id=?", (request_id,)).fetchone()
    if not row or row["expires_at"] <= int(time.time()) or row["decided_at"] is not None:
        raise HTTPException(410, "Запрос входа устарел или уже завершён. Начни вход заново.")
    config, revision = _client(connection, row["client_id"])
    if row["revision"] != revision:
        raise HTTPException(409, "Настройки сервиса изменились. Начни вход заново.")
    return row, config, revision


def _callback(row, **values: str) -> str:
    parsed = urlsplit(row["redirect_uri"])
    query = parse_qsl(parsed.query, keep_blank_values=True) + [("state", row["state"]), ("iss", _issuer())] + list(values.items())
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))


def _save_client(body: ClientBody, request: Request, *, replace: bool) -> dict:
    user = _admin(request)
    if not _ID.fullmatch(body.client_id):
        raise SSODataError("client_id", "нужны латинские строчные буквы, цифры, _ или -; первая буква обязательна")
    if any(ord(ch) < 32 for ch in body.name):
        raise SSODataError("name", "управляющие символы запрещены")
    scopes = list(dict.fromkeys(body.scopes))
    if "identity" not in scopes or any(scope not in _SCOPES and not (scope == "chat" and body.client_id == "ghostchat") for scope in scopes):
        raise HTTPException(422, "Допустимые scopes: identity, profile; identity обязателен")
    redirects = list(dict.fromkeys(_url(url, callback=True, field=f"redirect_uris[{index}]")
                                   for index, url in enumerate(body.redirect_uris)))
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        existing = connection.execute("SELECT config, revision FROM clients WHERE client_id=?", (body.client_id,)).fetchone()
        if existing and not replace:
            raise HTTPException(409, "Этот client_id уже зарегистрирован")
        old = json.loads(existing["config"]) if existing else {}
        if old.get("transport") == "telegram-start":
            raise HTTPException(409, "У этого сервиса используется отдельный Telegram-адаптер")
        trusted = old.get("trusted", False)
        if trusted and any(_origin(url) != _origin(_issuer()) for url in redirects):
            raise HTTPException(422, "Внутренний сервис должен возвращать на домен GhostEcos")
        config = body.model_dump()
        config.update(name=body.name.strip(), scopes=scopes, redirect_uris=redirects,
                      icon=_url(body.icon, local=True, field="icon") if body.icon else "",
                      website_url=_url(body.website_url, field="website_url") if body.website_url else _origin(redirects[0]),
                      terms_url=_url(body.terms_url, local=True, field="terms_url"),
                      privacy_url=_url(body.privacy_url, local=True, field="privacy_url"),
                      trusted=trusted, transport="authorization-code")
        revision = int(existing["revision"]) + 1 if existing else 1
        connection.execute("INSERT INTO clients VALUES (?, ?, ?, ?, ?) ON CONFLICT(client_id) DO UPDATE SET config=excluded.config, revision=excluded.revision, owner_id=excluded.owner_id, updated_at=excluded.updated_at",
                           (body.client_id, json.dumps(config, ensure_ascii=False), revision, int(user["id"]), int(time.time())))
    return {"client_id": body.client_id, "client": _public(config, revision), "entrance_endpoint": _issuer() + "/api/sso/entrance", "token_endpoint": _issuer() + "/api/sso/token"}


@router.post("/clients", status_code=201)
def register_client(body: ClientBody, request: Request):
    return _save_client(body, request, replace=False)


@router.put("/clients/{client_id}")
def update_client(client_id: str, body: ClientBody, request: Request):
    if client_id != body.client_id:
        raise HTTPException(422, "client_id в адресе и JSON должен совпадать")
    return _save_client(body, request, replace=True)


@router.get("/clients/{client_id}")
def read_client(client_id: str):
    with _db() as connection:
        config, revision = _client(connection, client_id)
        return {"client": _public(config, revision)}


@router.post("/entrance", status_code=201)
def entrance(body: EntranceBody, request: Request):
    _limit(request, "entrance", 30)
    if body.prompt not in {"select_account", "login", "auto"}:
        raise HTTPException(422, "prompt должен быть select_account, login или auto")
    if body.code_challenge_method != "S256" or (body.code_challenge and not _CHALLENGE.fullmatch(body.code_challenge)):
        raise HTTPException(422, "Поддерживается только PKCE S256")
    if body.state and any(ord(ch) < 33 for ch in body.state):
        raise HTTPException(422, "Некорректный state")
    verifier = secrets.token_urlsafe(48) if not body.code_challenge else None
    challenge = body.code_challenge or _pkce(verifier)
    now = int(time.time())
    with _db() as connection:
        config, revision = _client(connection, body.client_id)
        _check_origin(request, config)
        if config["transport"] != "authorization-code":
            raise HTTPException(422, "Этот сервис использует Telegram-адаптер")
        if body.prompt == "auto" and not config.get("trusted"):
            raise HTTPException(403, "Автоматический вход доступен только внутренним сервисам GhostEcos")
        redirect = body.redirect_uri or config["redirect_uris"][0]
        if redirect not in config["redirect_uris"]:
            raise HTTPException(400, "Адрес возврата не зарегистрирован для этого сервиса")
        scopes = list(dict.fromkeys(body.scopes or config["scopes"]))
        if "identity" not in scopes or not set(scopes) <= set(config["scopes"]) or ("chat" in scopes and (body.client_id != "ghostchat" or not config.get("trusted"))):
            raise HTTPException(400, "Сервис запросил недоступные разрешения")
        request_id, state = secrets.token_urlsafe(32), body.state or secrets.token_urlsafe(32)
        connection.execute("DELETE FROM entrances WHERE expires_at < ?", (now - 600,))
        connection.execute("DELETE FROM access_tokens WHERE expires_at < ?", (now,))
        connection.execute("INSERT INTO entrances (request_id, client_id, revision, redirect_uri, scopes, state, challenge, prompt, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           (request_id, body.client_id, revision, redirect, json.dumps(scopes), state, challenge, body.prompt, now + _REQUEST_TTL))
    response = {"request_id": request_id, "authorization_url": _issuer() + "/v2/auth?sso_request=" + request_id,
                "state": state, "redirect_uri": redirect, "expires_in": _REQUEST_TTL}
    if verifier:
        response["code_verifier"] = verifier
    return response


@router.get("/requests/{request_id}")
def request_info(request_id: str):
    with _db() as connection:
        row, config, revision = _request(connection, request_id)
        return {"request_id": request_id, "client": _public(config, revision, json.loads(row["scopes"])),
                "redirect_uri": row["redirect_uri"], "prompt": row["prompt"], "expires_at": row["expires_at"]}


@router.post("/requests/{request_id}/approve")
def approve(request_id: str, body: ApproveBody, request: Request):
    user = _member(request)
    _limit(request, "approve", 30)
    now = int(time.time())
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        row, config, revision = _request(connection, request_id)
        _check_origin(request, config, local_only=True)
        if body.automatic:
            if not body.consent or row["prompt"] != "auto" or not config.get("trusted"):
                raise HTTPException(403, "Для этого запроса автоматический вход не разрешён")
            accepted = connection.execute("SELECT scopes FROM consents WHERE user_id=? AND client_id=? AND revision=?",
                                          (int(user["id"]), row["client_id"], revision)).fetchone()
            if not accepted or not set(json.loads(row["scopes"])) <= set(json.loads(accepted["scopes"])):
                return JSONResponse({"detail": "Подтверди доступ к сервису перед автоматическим входом",
                                     "code": "consent_required"}, status_code=409)
        if not body.consent:
            connection.execute("UPDATE entrances SET decided_at=? WHERE request_id=?", (now, request_id))
            return {"redirect_url": _callback(row, error="access_denied")}
        code = secrets.token_urlsafe(32)
        if "chat" in json.loads(row["scopes"]):
            header = request.headers.get("authorization") or "Bearer " + request.headers.get("x-gs-token", "")
            raw = header.partition(" ")[2]
            connection.execute("UPDATE entrances SET source_hash=? WHERE request_id=?", (_hash(raw), request_id))
        connection.execute("UPDATE entrances SET decided_at=?, user_id=?, code_hash=?, code_expires_at=? WHERE request_id=?",
                           (now, int(user["id"]), _hash(code), now + _CODE_TTL, request_id))
        connection.execute("INSERT INTO consents VALUES (?, ?, ?, ?, ?) ON CONFLICT(user_id, client_id, revision) DO UPDATE SET scopes=excluded.scopes, accepted_at=excluded.accepted_at",
                           (int(user["id"]), row["client_id"], revision, row["scopes"], now))
        return {"redirect_url": _callback(row, code=code), "expires_in": _CODE_TTL}


@router.post("/token")
def exchange_token(body: TokenBody, request: Request):
    _limit(request, "token")
    if body.grant_type != "authorization_code" or not _OPAQUE.fullmatch(body.code) or not _VERIFIER.fullmatch(body.code_verifier):
        raise HTTPException(400, "Некорректный запрос обмена кода")
    now = int(time.time())
    with _db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        config, revision = _client(connection, body.client_id)
        _check_origin(request, config)
        row = connection.execute("SELECT * FROM entrances WHERE code_hash=?", (_hash(body.code),)).fetchone()
        if (not row or row["client_id"] != body.client_id or row["revision"] != revision
                or row["redirect_uri"] != body.redirect_uri or row["redeemed_at"] is not None
                or not row["code_expires_at"] or row["code_expires_at"] <= now
                or not secrets.compare_digest(row["challenge"], _pkce(body.code_verifier))):
            raise HTTPException(400, "Код недействителен, истёк или не принадлежит этому запросу")
        token = secrets.token_urlsafe(48)
        connection.execute("UPDATE entrances SET redeemed_at=? WHERE request_id=?", (now, row["request_id"]))
        ttl = 8 * 3600 if body.client_id == "ghostchat" and "chat" in json.loads(row["scopes"]) else _TOKEN_TTL
        connection.execute("INSERT INTO access_tokens (token_hash,client_id,revision,user_id,scopes,expires_at,source_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           (_hash(token), body.client_id, revision, row["user_id"], row["scopes"], now + ttl, row["source_hash"]))
        return {"access_token": token, "token_type": "Bearer", "expires_in": ttl,
                "scope": " ".join(json.loads(row["scopes"]))}


@router.get("/userinfo")
def userinfo(request: Request):
    header = request.headers.get("authorization", "")
    if not header:
        raise HTTPException(401, "Не указан токен доступа сервиса в заголовке Authorization")
    scheme, separator, token = header.partition(" ")
    if scheme.lower() != "bearer" or not separator or not _OPAQUE.fullmatch(token):
        raise HTTPException(401, "Нужен токен доступа сервиса")
    with _db() as connection:
        row = connection.execute("SELECT * FROM access_tokens WHERE token_hash=?", (_hash(token),)).fetchone()
        if not row or row["expires_at"] <= int(time.time()):
            raise HTTPException(401, "Токен доступа истёк или отозван")
        config, revision = _client(connection, row["client_id"])
        _check_origin(request, config)
        if row["revision"] != revision:
            raise HTTPException(401, "Настройки сервиса изменились. Повтори вход.")
        scopes, user_id, client_id = json.loads(row["scopes"]), row["user_id"], row["client_id"]
    connection = identity_db()
    try:
        user = connection.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    finally:
        connection.close()
    if not user:
        raise HTTPException(401, "Аккаунт больше не существует")
    user = dict(user)
    response = {"sub": str(user_id), "username": user.get("username") or "", "client_id": client_id}
    if "profile" in scopes:
        response.update(name=user.get("display_name") or user.get("username") or "", picture=user.get("avatar_url"))
    return response


def install(app):
    app.include_router(router)

    @app.middleware("http")
    async def sso_headers(request: Request, call_next):
        if not request.url.path.startswith("/api/sso/"):
            return await call_next(request)
        origin = request.headers.get("origin")
        cors = False
        local_only = request.url.path.endswith("/approve") or ("/clients" in request.url.path and request.method not in {"GET", "OPTIONS"})
        if origin:
            with _db() as connection:
                origins = {_origin(_issuer())}
                if not local_only:
                    for item in connection.execute("SELECT config FROM clients"):
                        config = json.loads(item["config"])
                        if config.get("enabled") and config.get("transport") == "authorization-code":
                            origins.update(_origin(url) for url in config["redirect_uris"])
            cors = origin in origins
            if not cors:
                return JSONResponse({"detail": "Origin is not registered for GhostID"}, status_code=403,
                                    headers={"Cache-Control": "no-store"})
        if request.method == "OPTIONS":
            response = Response(status_code=204)
        else:
            response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
        if cors:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, OPTIONS"
            response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-Gs-Token"
            response.headers["Vary"] = "Origin"
        return response
