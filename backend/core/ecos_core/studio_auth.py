"""Приложения GhostStudio и вход с обработкой кода на стороне GhostID."""
from __future__ import annotations

import base64
import hashlib
import html
import http.client
import io
import ipaddress
import json
import secrets
import socket
import ssl
import time
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ecos_core import service_sso as sso
from ecos_core.studio_projects import _owner, _text

router = APIRouter(prefix="/api/developer/apps", tags=["GhostStudio applications"], route_class=sso.SSORoute)
public_router = APIRouter(prefix="/api/sso", tags=["GhostID managed login"], route_class=sso.SSORoute)
Platform = Literal["node", "php"]


def _origin(value: str) -> str:
    value = value.strip()
    if "://" not in value:
        value = "https://" + value
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").encode("idna").decode("ascii").lower()
        if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.query
                or parsed.fragment or parsed.path not in {"", "/"} or parsed.port not in {None, 443}
                or "." not in host or host.endswith((".", ".localhost", ".local", ".internal", ".invalid"))):
            raise ValueError()
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise ValueError()
        result = "https://" + host
        sso._url(result)
        if any(ord(c) <= 32 or c == "\\" for c in value):
            raise ValueError()
        return result
    except (ValueError, UnicodeError, sso.SSODataError):
        raise ValueError("Укажи домен сайта с HTTPS, без пути, порта и параметров")


class CreateApp(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=80)
    domain: str = Field(min_length=3, max_length=300)
    icon: str = Field(default="", max_length=2048)
    platform: Platform = "node"

    @field_validator("name")
    @classmethod
    def name_text(cls, value):
        result = _text(value)
        if not result:
            raise ValueError("Укажи название приложения")
        return result

    @field_validator("domain")
    @classmethod
    def domain_url(cls, value):
        return _origin(value)

    @field_validator("icon")
    @classmethod
    def icon_url(cls, value):
        return sso._url(value.strip(), field="icon") if value.strip() else ""


class UpdateApp(CreateApp):
    expected_revision: int = Field(ge=1)


class AppState(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    enabled: bool


class StartBody(sso.SSOBody):
    client_id: str = Field(min_length=3, max_length=64)


class CompleteBody(StartBody):
    state: str = Field(min_length=43, max_length=43, repr=False)
    nonce: str = Field(min_length=43, max_length=43, repr=False)
    iss: str = Field(min_length=1, max_length=2048)
    code: str | None = Field(default=None, min_length=32, max_length=128, repr=False)
    error: Literal["access_denied"] | None = None

    @model_validator(mode="after")
    def result_kind(self):
        if bool(self.code) == bool(self.error):
            raise ValueError("Нужен код входа или отказ пользователя")
        return self


@contextmanager
def _db():
    with sso._db() as con:
        con.executescript("""
            CREATE TABLE IF NOT EXISTS studio_apps (
                client_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
                origin TEXT NOT NULL, platform TEXT NOT NULL, proof TEXT NOT NULL,
                verified_at INTEGER, created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS studio_apps_owner ON studio_apps(user_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS studio_apps_origin ON studio_apps(origin);
            CREATE TABLE IF NOT EXISTS studio_logins (
                state TEXT PRIMARY KEY, client_id TEXT NOT NULL, revision INTEGER NOT NULL,
                nonce_hash TEXT NOT NULL, verifier TEXT NOT NULL, request_id TEXT NOT NULL,
                expires_at INTEGER NOT NULL, used_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS studio_logins_expiry ON studio_logins(expires_at);
        """)
        yield con


def _find(con, client_id, owner=None):
    if not sso._ID.fullmatch(client_id):
        raise HTTPException(404, "Приложение не найдено")
    row = con.execute("""SELECT a.*,c.config,c.revision,c.owner_id FROM studio_apps a
        JOIN clients c USING(client_id) WHERE a.client_id=?""", (client_id,)).fetchone()
    if not row or row["user_id"] != row["owner_id"] or (owner is not None and row["user_id"] != owner):
        raise HTTPException(404, "Приложение не найдено")
    return row


def _paths(origin, platform, client_id):
    if platform == "php":
        return {key: origin + "/ghostid-" + client_id + ".php?action=" + action for key, action in
                (("start", "start"), ("callback", "callback"), ("verify", "verify"))}
    return {key: origin + "/ghostid/" + client_id + "/" + key for key in ("start", "callback", "verify")}


def _config(client_id, body, enabled=False):
    paths = _paths(body.domain, body.platform, client_id)
    config = sso.ClientBody(client_id=client_id, name=body.name, icon=body.icon,
                            website_url=body.domain, login_start_uri=paths["start"],
                            redirect_uris=[paths["callback"]], enabled=enabled).model_dump()
    config.update(transport="authorization-code", trusted=False,
                  terms_url=sso._issuer() + "/terms", privacy_url=sso._issuer() + "/privacy")
    return config


def _public(row):
    config = json.loads(row["config"])
    paths = _paths(row["origin"], row["platform"], row["client_id"])
    return {"client_id": row["client_id"], "name": config["name"], "domain": row["origin"],
            "icon": config["icon"], "platform": row["platform"], "revision": row["revision"],
            "state": "active" if row["verified_at"] and config["enabled"] else
                     "disabled" if row["verified_at"] else "pending",
            "verified_at": row["verified_at"], "created_at": row["created_at"],
            "verification_url": paths["verify"], "widget_url": sso._issuer() + "/api/sso/widget/" + row["client_id"],
            "start_url": paths["start"], "callback_url": paths["callback"]}


@router.get("")
def list_apps(request: Request):
    owner = _owner(request)
    with _db() as con:
        rows = con.execute("""SELECT a.*,c.config,c.revision FROM studio_apps a JOIN clients c USING(client_id)
            WHERE a.user_id=? AND c.owner_id=a.user_id ORDER BY a.created_at DESC,a.client_id""", (owner,)).fetchall()
        return {"apps": [_public(row) for row in rows]}


@router.post("", status_code=201)
def create_app(body: CreateApp, request: Request):
    owner, now = _owner(request, write=True), int(time.time())
    client_id = "app_" + secrets.token_hex(12)
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        if con.execute("SELECT COUNT(*) FROM studio_apps WHERE user_id=?", (owner,)).fetchone()[0] >= 50:
            raise HTTPException(409, "Можно создать не больше 50 приложений")
        con.execute("INSERT INTO clients VALUES (?,?,1,?,?)",
                    (client_id, json.dumps(_config(client_id, body), ensure_ascii=False), owner, now))
        con.execute("INSERT INTO studio_apps VALUES (?,?,?,?,?,NULL,?)",
                    (client_id, owner, body.domain, body.platform, secrets.token_urlsafe(32), now))
        return {"app": _public(_find(con, client_id, owner))}


@router.get("/{client_id}")
def get_app(client_id: str, request: Request):
    owner = _owner(request)
    with _db() as con:
        return {"app": _public(_find(con, client_id, owner))}


def _revision(row, expected):
    if row["revision"] != expected:
        raise HTTPException(409, "Приложение уже изменилось. Обнови его перед сохранением")


def _invalidate(con, row):
    old = json.loads(row["config"])
    if old.get("session_binding"):
        from ecos_core.sso_events import revoke_client_grants
        revoke_client_grants(con, old)
    for table in ("studio_logins", "entrances", "access_tokens", "consents"):
        con.execute("DELETE FROM " + table + " WHERE client_id=?", (row["client_id"],))


@router.put("/{client_id}")
def update_app(client_id: str, body: UpdateApp, request: Request):
    owner = _owner(request, write=True)
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        row = _find(con, client_id, owner)
        _revision(row, body.expected_revision)
        moved = row["origin"] != body.domain or row["platform"] != body.platform
        verified = None if moved else row["verified_at"]
        enabled = bool(verified and json.loads(row["config"])["enabled"])
        _invalidate(con, row)
        con.execute("UPDATE clients SET config=?,revision=revision+1,updated_at=? WHERE client_id=?",
                    (json.dumps(_config(client_id, body, enabled), ensure_ascii=False), int(time.time()), client_id))
        con.execute("UPDATE studio_apps SET origin=?,platform=?,verified_at=?,proof=? WHERE client_id=?",
                    (body.domain, body.platform, verified, secrets.token_urlsafe(32) if moved else row["proof"], client_id))
        return {"app": _public(_find(con, client_id, owner))}


@router.patch("/{client_id}/state")
def change_state(client_id: str, body: AppState, request: Request):
    owner = _owner(request, write=True)
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        row = _find(con, client_id, owner)
        _revision(row, body.expected_revision)
        if body.enabled and not row["verified_at"]:
            raise HTTPException(409, "Сначала установи обработчик и подтверди сайт")
        config = json.loads(row["config"])
        if config["enabled"] != body.enabled:
            _invalidate(con, row)
            config["enabled"] = body.enabled
            con.execute("UPDATE clients SET config=?,revision=revision+1,updated_at=? WHERE client_id=?",
                        (json.dumps(config, ensure_ascii=False), int(time.time()), client_id))
        return {"app": _public(_find(con, client_id, owner))}


class _PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, address):
        super().__init__(host, timeout=4, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, 443), timeout=self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def _fetch_proof(url):
    parsed = urlsplit(url)
    host = parsed.hostname
    addresses = sorted({item[4][0] for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)})
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ValueError("Сайт должен иметь публичный адрес")
    connection = _PinnedHTTPS(host, addresses[0])
    try:
        connection.request("GET", parsed.path + ("?" + parsed.query if parsed.query else ""),
                           headers={"Accept": "text/plain", "User-Agent": "GhostID domain verification"})
        response = connection.getresponse()
        data = response.read(257)
        if response.status != 200 or len(data) > 256:
            raise ValueError("Обработчик подтверждения пока недоступен")
        return data.decode("ascii").strip()
    finally:
        connection.close()


@router.post("/{client_id}/verify")
def verify_app(client_id: str, request: Request):
    owner = _owner(request, write=True)
    sso._limit(request, "verify-domain", 10)
    with _db() as con:
        row = _find(con, client_id, owner)
        snapshot = dict(row)
    try:
        result = _fetch_proof(_paths(snapshot["origin"], snapshot["platform"], client_id)["verify"])
        if not secrets.compare_digest(result, snapshot["proof"]):
            raise ValueError("На сайте установлен обработчик другого приложения")
    except (OSError, ValueError, http.client.HTTPException):
        raise HTTPException(409, "Не удалось подтвердить сайт. Установи выданный файл и проверь его HTTPS-адрес")
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        row = _find(con, client_id, owner)
        _revision(row, snapshot["revision"])
        if not row["verified_at"]:
            config = json.loads(row["config"])
            config["enabled"] = True
            con.execute("UPDATE studio_apps SET verified_at=? WHERE client_id=?", (int(time.time()), client_id))
            con.execute("UPDATE clients SET config=?,revision=revision+1,updated_at=? WHERE client_id=?",
                        (json.dumps(config, ensure_ascii=False), int(time.time()), client_id))
        return {"app": _public(_find(con, client_id, owner))}


def _button(row):
    return '<div data-ghostid-button data-app="' + row["client_id"] + '"></div>\n' + \
           '<script src="' + html.escape(sso._issuer(), quote=True) + '/api/sso/button.js"\n' + \
           '  defer></script>\n'


def _bundle(row):
    config = {"clientId": row["client_id"], "origin": row["origin"], "issuer": sso._issuer(),
              "proof": row["proof"], "name": json.loads(row["config"])["name"],
              "urls": _paths(row["origin"], row["platform"], row["client_id"])}
    source = Path(__file__).with_name("ghostid_templates")
    node = row["platform"] == "node"
    filename = "ghostid.mjs" if node else "ghostid-" + row["client_id"] + ".php"
    template = (source / ("ghostid.mjs.tpl" if node else "ghostid.php.tpl")).read_text()
    settings = json.dumps(config, ensure_ascii=False)
    text = template.replace("__GHOSTID_CONFIG__", settings if node else base64.b64encode(settings.encode()).decode())
    readme = (source / "README.txt").read_text().replace("__PLATFORM__", "Node.js 18+" if node else "PHP 8+ с cURL")
    readme = readme.replace("__PHPFILE__", filename)
    readme = readme.replace("__VERIFY__", _paths(row["origin"], row["platform"], row["client_id"])["verify"])
    readme = readme.replace("__START__", _paths(row["origin"], row["platform"], row["client_id"])["start"])
    readme = readme.replace("__CALLBACK__", _paths(row["origin"], row["platform"], row["client_id"])["callback"])
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(filename, text)
        archive.writestr("button.html", _button(row))
        archive.writestr("README.txt", readme)
        if node:
            archive.writestr("connect.mjs", 'import ghostID from "./ghostid.mjs";\n' +
                'app.use(ghostID(async (user, req, res) => {\n' +
                '  // Здесь можно найти пользователя по user.sub и продолжить вход на своём сайте.\n' +
                '  res.json(user);\n}));\n')
    return data.getvalue()


@router.get("/{client_id}/integration")
def integration(client_id: str, request: Request):
    owner = _owner(request)
    with _db() as con:
        row = _find(con, client_id, owner)
        return {"app": _public(row), "button": _button(row),
                "server": 'import ghostID from "./ghostid.mjs";\napp.use(ghostID((user, req, res) => res.json(user)));'
                if row["platform"] == "node" else
                '// Замени последний вызов ghostid_handle в выданном PHP-файле:\nghostid_handle(function (array $user) {\n    // Данные пользователя доступны в $user.\n    echo json_encode($user);\n});',
                "bundle_url": "/api/developer/apps/" + client_id + "/bundle"}


@router.get("/{client_id}/bundle")
def download_bundle(client_id: str, request: Request):
    owner = _owner(request)
    with _db() as con:
        data = _bundle(_find(con, client_id, owner))
    return Response(data, media_type="application/zip", headers={
        "Content-Disposition": 'attachment; filename="GhostID-' + client_id + '.zip"',
        "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"})


@public_router.get("/apps/resolve")
def resolve_app(request: Request, origin: str = Query(max_length=300), client_id: str | None = Query(default=None, max_length=64)):
    sso._limit(request, "resolve-app", 120)
    try:
        normalized = _origin(origin)
    except ValueError:
        raise HTTPException(400, "Проверь домен приложения")
    if request.headers.get("origin") != normalized:
        raise HTTPException(403, "Домен кнопки не совпадает с сайтом")
    with _db() as con:
        rows = con.execute("""SELECT a.*,c.config,c.revision,c.owner_id FROM studio_apps a JOIN clients c USING(client_id)
            WHERE a.origin=? AND a.verified_at IS NOT NULL AND a.user_id=c.owner_id""", (normalized,)).fetchall()
        rows = [row for row in rows if json.loads(row["config"])["enabled"] and
                (client_id is None or row["client_id"] == client_id)]
        if not rows:
            raise HTTPException(404, "Для этого сайта пока нет подключённого приложения")
        if len(rows) != 1:
            raise HTTPException(409, "На сайте несколько приложений. Используй кнопку из настроек нужного приложения")
        return {"app": _public(rows[0])}


@public_router.get("/button.js")
def button_script():
    script = Path(__file__).with_name("ghostid_templates").joinpath("button.js").read_text()
    script = script.replace("__GHOSTID_ISSUER__", json.dumps(sso._issuer()))
    return Response(script, media_type="application/javascript", headers={"X-Content-Type-Options": "nosniff"})


def _active(con, client_id):
    row = _find(con, client_id)
    config = json.loads(row["config"])
    if not row["verified_at"] or not config["enabled"]:
        raise HTTPException(403, "Вход в приложение пока не включён")
    return row


@public_router.post("/managed/start", status_code=201)
def managed_start(body: StartBody, request: Request):
    sso._limit(request, "managed-start", 30)
    with _db() as con:
        row = _active(con, body.client_id)
        callback = _paths(row["origin"], row["platform"], body.client_id)["callback"]
    state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
    data = sso.entrance(sso.EntranceBody(client_id=body.client_id, redirect_uri=callback,
                        state=state, code_challenge=sso._pkce(verifier), code_challenge_method="S256"), request)
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        current = _active(con, body.client_id)
        _revision(current, row["revision"])
        now = int(time.time())
        con.execute("DELETE FROM studio_logins WHERE expires_at < ?", (now,))
        con.execute("INSERT INTO studio_logins VALUES (?,?,?,?,?,?,?,NULL)",
                    (state, body.client_id, row["revision"], sso._hash(nonce), verifier, data["request_id"], now + 600))
    return {"authorization_url": data["authorization_url"], "state": state, "nonce": nonce, "expires_in": 600}


@public_router.post("/managed/complete")
def managed_complete(body: CompleteBody, request: Request):
    sso._limit(request, "managed-complete", 60)
    if (body.iss != sso._issuer() or not sso._OPAQUE.fullmatch(body.state)
            or not sso._OPAQUE.fullmatch(body.nonce) or (body.code and not sso._OPAQUE.fullmatch(body.code))):
        raise HTTPException(400, "Неверный ответ входа")
    now = int(time.time())
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        app = _active(con, body.client_id)
        sso._check_origin(request, json.loads(app["config"]))
        attempt = con.execute("SELECT * FROM studio_logins WHERE state=?", (body.state,)).fetchone()
        if (not attempt or attempt["client_id"] != body.client_id or attempt["revision"] != app["revision"]
                or attempt["used_at"] is not None or attempt["expires_at"] <= now
                or not secrets.compare_digest(attempt["nonce_hash"], sso._hash(body.nonce))):
            raise HTTPException(400, "Попытка входа устарела или не принадлежит этому браузеру")
        entrance = con.execute("SELECT * FROM entrances WHERE request_id=?", (attempt["request_id"],)).fetchone()
        if (not entrance or entrance["state"] != body.state or entrance["decided_at"] is None
                or (body.code and (not entrance["code_hash"] or
                    not secrets.compare_digest(entrance["code_hash"], sso._hash(body.code))))
                or (body.error and entrance["code_hash"] is not None)):
            raise HTTPException(400, "Код не относится к этой попытке входа")
        con.execute("UPDATE studio_logins SET used_at=? WHERE state=?", (now, body.state))
        verifier = attempt["verifier"]
        callback = _paths(app["origin"], app["platform"], body.client_id)["callback"]
    if body.error:
        return {"error": "access_denied"}
    exchanged = sso.exchange_token(sso.TokenBody(client_id=body.client_id, code=body.code,
                                                redirect_uri=callback, code_verifier=verifier), request)
    token = exchanged["access_token"]
    try:
        authenticated = Request({"type": "http", "method": "GET", "path": "/api/sso/userinfo",
                                 "headers": [(b"authorization", ("Bearer " + token).encode())],
                                 "query_string": b"", "scheme": "https", "server": ("ghostid", 443)})
        profile = sso.userinfo(authenticated)
        return {"client_id": body.client_id, "user": {key: profile[key] for key in
                ("sub", "username", "name", "picture") if key in profile}}
    finally:
        with sso._db() as con:
            con.execute("DELETE FROM access_tokens WHERE token_hash=?", (sso._hash(token),))


def purge_for_user(user_id):
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        rows = con.execute("""SELECT a.*,c.config,c.revision FROM studio_apps a JOIN clients c USING(client_id)
            WHERE a.user_id=? AND c.owner_id=a.user_id""", (int(user_id),)).fetchall()
        for row in rows:
            _invalidate(con, row)
            con.execute("DELETE FROM clients WHERE client_id=?", (row["client_id"],))
        con.execute("DELETE FROM studio_apps WHERE user_id=?", (int(user_id),))
        return len(rows)


def install(app):
    app.include_router(router)
    app.include_router(public_router)
