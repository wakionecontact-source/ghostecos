"""Контракты GhostID v2: один запрос на вход, PKCE и границы прав."""
import base64
import hashlib
import os
import secrets
import sqlite3
import time

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from ecos_core import service_auth_v2 as v2
from ecos_core import service_sso as sso
from ecos_core import sessions as sess

ISSUER = "https://ghostecos.duckdns.org"
CALLBACK = "https://external.example/ghostid/callback"
MEMBER = {"Authorization": "Bearer test-member-session"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("GE_SSO_DB_PATH", str(tmp_path / "sso.sqlite3"))
    monkeypatch.setenv("GE_SSO_ISSUER", ISSUER)
    monkeypatch.setattr(sso, "_rate_limit", lambda *args, **kwargs: None)
    monkeypatch.setattr(v2, "_rate_limit", lambda *args, **kwargs: None)
    database = tmp_path / "identity.sqlite3"
    monkeypatch.setenv("SOCIAL_DB_PATH", str(database))
    connection = sqlite3.connect(database)
    connection.execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, display_name TEXT, "
        "avatar_url TEXT, password_hash TEXT, private_key TEXT, is_admin INTEGER)")
    connection.execute("CREATE TABLE soc_tokens (token TEXT PRIMARY KEY, user_id INTEGER)")
    connection.execute("INSERT INTO users VALUES (7, 'member', 'Member', NULL, 'hash', NULL, 0)")
    connection.execute("INSERT INTO soc_tokens VALUES ('test-member-session', 7)")
    connection.commit()
    connection.close()
    app = FastAPI()
    sso.install(app)
    v2.install(app)
    with TestClient(app) as http:
        yield http


def pkce():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def register(client, **changes):
    payload = {"name": "External service", "redirect_uris": [CALLBACK],
               "scopes": ["identity", "profile"], **changes}
    response = client.post("/api/v2/auth/clients", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def authorize(client, client_id, challenge, **changes):
    payload = {"client_id": client_id, "redirect_uri": CALLBACK, "state": "st-1",
               "challenge": challenge, **changes}
    return client.post("/api/v2/auth/authorize", json=payload)


# ── Клиенты ────────────────────────────────────────────

def test_client_self_registers_without_admin(client):
    data = register(client)
    assert data["clientId"].startswith("external-service-")
    assert data["scopes"] == ["identity", "profile"]
    assert data["redirectUris"] == [CALLBACK]


def test_client_rejects_plain_http_redirect(client):
    response = client.post("/api/v2/auth/clients", json={
        "name": "Bad", "redirect_uris": ["http://evil.example/cb"]})
    assert response.status_code == 422


def test_client_rejects_unknown_scope(client):
    response = client.post("/api/v2/auth/clients", json={
        "name": "Bad", "redirect_uris": [CALLBACK], "scopes": ["identity", "admin"]})
    assert response.status_code == 422
    assert "admin" in response.text


# ── Один запрос на вход ────────────────────────────────

def test_authorize_returns_url_and_inline_anketa(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    response = authorize(client, client_id, challenge,
                         anketa={"name": "External service", "reason": "войти в чат"})
    assert response.status_code == 201, response.text
    data = response.json()
    assert data["url"].startswith(ISSUER + "/v2/auth?sso_request=")
    assert data["anketa"]["reason"] == "войти в чат"
    assert data["anketa"]["scopes"] == ["identity", "profile"]


def test_authorize_rejects_foreign_redirect(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    response = client.post("/api/v2/auth/authorize", json={
        "client_id": client_id, "redirect_uri": "https://evil.example/cb",
        "challenge": challenge})
    assert response.status_code == 403


def test_authorize_rejects_scopes_above_ceiling(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    response = authorize(client, client_id, challenge, scopes=["identity", "password"])
    assert response.status_code == 403
    assert "password" in response.text


def test_authorize_requires_s256_challenge(client):
    client_id = register(client)["clientId"]
    response = authorize(client, client_id, "short")
    assert response.status_code == 422


def test_request_info_exposes_anketa(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    created = authorize(client, client_id, challenge).json()
    info = client.get(f"/api/v2/auth/requests/{created['requestId']}")
    assert info.status_code == 200, info.text
    body = info.json()
    assert body["clientId"] == client_id
    assert [item["id"] for item in body["scopesDetail"]] == ["identity", "profile"]
    assert body["state"] == "st-1"


# ── Согласие и токены ──────────────────────────────────

def test_approve_requires_session(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    created = authorize(client, client_id, challenge).json()
    response = client.post(f"/api/v2/auth/requests/{created['requestId']}/approve",
                           json={})
    assert response.status_code == 401


def test_token_exchange_requires_right_verifier(client):
    client_id = register(client)["clientId"]
    verifier, challenge = pkce()
    created = authorize(client, client_id, challenge).json()
    approved = client.post(f"/api/v2/auth/requests/{created['requestId']}/approve",
                           json={}, headers=MEMBER)
    assert approved.status_code == 200, approved.text
    code = approved.json()["code"]

    wrong = client.post("/api/v2/auth/token", json={
        "code": code, "client_id": client_id, "redirect_uri": CALLBACK,
        "code_verifier": secrets.token_urlsafe(48)})
    assert wrong.status_code == 401

    good = client.post("/api/v2/auth/token", json={
        "code": code, "client_id": client_id, "redirect_uri": CALLBACK,
        "code_verifier": verifier})
    assert good.status_code == 200, good.text
    tokens = good.json()
    assert tokens["expires_in"] == sso.CHAT_TOKEN_TTL == 30 * 24 * 3600
    assert tokens["scopes"] == ["identity", "profile"]

    reused = client.post("/api/v2/auth/token", json={
        "code": code, "client_id": client_id, "redirect_uri": CALLBACK,
        "code_verifier": verifier})
    assert reused.status_code == 401

    rotated = client.post("/api/v2/auth/token", json={
        "grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
        "client_id": client_id})
    assert rotated.status_code == 200, rotated.text
    assert rotated.json()["access_token"] != tokens["access_token"]


def test_approve_cannot_add_unrequested_scopes(client):
    client_id = register(client)["clientId"]
    _, challenge = pkce()
    created = authorize(client, client_id, challenge, scopes=["identity"]).json()
    response = client.post(f"/api/v2/auth/requests/{created['requestId']}/approve",
                           json={"scopes": ["identity", "profile"]}, headers=MEMBER)
    assert response.status_code == 403


# ── Аккаунты и сессии ──────────────────────────────────

def test_accounts_require_session(client):
    assert client.get("/api/v2/auth/accounts").status_code == 401
    assert client.get("/api/v2/auth/me").status_code == 401
    assert client.post("/api/v2/auth/logout").status_code == 401


def test_me_returns_current_account(client):
    response = client.get("/api/v2/auth/me", headers=MEMBER)
    assert response.status_code == 200, response.text
    assert response.json()["username"] == "member"


# ── Устройство, лимит и отзыв ──────────────────────────

def _account_db():
    connection = sqlite3.connect(os.environ["SOCIAL_DB_PATH"])
    connection.row_factory = sqlite3.Row
    connection.execute(
        "CREATE TABLE IF NOT EXISTS user_devices (id INTEGER PRIMARY KEY, user_id INTEGER, "
        "device_id TEXT, device_name TEXT, platform TEXT, last_seen INTEGER, "
        "is_active INTEGER DEFAULT 1, is_blocked INTEGER DEFAULT 0, expires_at INTEGER, "
        "token TEXT, device_token_hash TEXT)")
    sess.ensure_schema(connection)
    return connection


def _device(connection, device_pk, user_id, device_id, name, platform):
    connection.execute(
        "INSERT INTO user_devices (id, user_id, device_id, device_name, platform, last_seen, "
        "is_active, is_blocked, expires_at) VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?)",
        (device_pk, user_id, device_id, name, platform, int(time.time()),
         int(time.time()) + 90 * 86400))


def _session(connection, user_id, device_pk, token):
    now = int(time.time())
    connection.execute(
        "INSERT OR REPLACE INTO auth_sessions (session_id, token_hash, user_id, device_pk, "
        "auth_method, status, created_at, last_seen_at, expires_at) "
        "VALUES (?, ?, ?, ?, 'password', 'active', ?, ?, ?)",
        (f"s-{user_id}-{device_pk}", sess.token_hash(token), user_id, device_pk,
         now, now, now + 86400))


def test_accounts_lists_device_and_counts_limit(client):
    connection = _account_db()
    _device(connection, 1, 7, "dev-1", "Ноутбук", "windows")
    _session(connection, 7, 1, "test-member-session")
    connection.commit()
    connection.close()

    first = client.get("/api/v2/auth/accounts", headers=MEMBER)
    assert first.status_code == 200, first.text
    assert [item["username"] for item in first.json()["accounts"]] == ["member"]
    assert first.json()["canAdd"] is True

    connection = _account_db()
    for index in range(14):
        user_id = 100 + index
        connection.execute(
            "INSERT INTO users VALUES (?, ?, ?, NULL, 'hash', NULL, 0)",
            (user_id, f"user{index}", f"User {index}"))
        _session(connection, user_id, 1, f"token-{index}")
    connection.commit()
    connection.close()

    full = client.get("/api/v2/auth/accounts", headers=MEMBER)
    body = full.json()
    assert len(body["accounts"]) == 15
    assert body["limit"] == 15
    assert body["canAdd"] is False


def test_revoke_foreign_device_and_refuse_own(client):
    connection = _account_db()
    _device(connection, 1, 7, "dev-1", "Ноутбук", "windows")
    _device(connection, 2, 7, "dev-2", "Телефон", "android")
    _session(connection, 7, 1, "test-member-session")
    _session(connection, 7, 2, "other-token")
    connection.commit()
    connection.close()

    devices = client.get("/api/v2/auth/devices", headers=MEMBER)
    assert devices.status_code == 200, devices.text
    assert {row["deviceId"] for row in devices.json()["devices"]} == {"dev-1", "dev-2"}

    own = client.post("/api/v2/auth/devices/1/revoke", headers=MEMBER)
    assert own.status_code == 409

    foreign = client.post("/api/v2/auth/devices/2/revoke", headers=MEMBER)
    assert foreign.status_code == 200, foreign.text
    assert foreign.json()["revoked"] == 1

    connection = _account_db()
    status = connection.execute(
        "SELECT status FROM auth_sessions WHERE device_pk=2").fetchone()["status"]
    connection.close()
    assert status == "revoked"


# ── Переключение без пароля ────────────────────────────

def test_switch_requires_account_cookie(client):
    assert client.post("/api/v2/auth/switch", json={"account_id": 7}).status_code == 401


def test_switch_issues_session_with_cookie(client):
    connection = _account_db()
    _device(connection, 1, 7, "dev-1", "Ноутбук", "windows")
    connection.commit()
    connection.close()

    sso_db = os.environ["GE_SSO_DB_PATH"]
    connection = sqlite3.connect(sso_db)
    connection.executescript(v2.DEVICE_ACCOUNT_SCHEMA)
    now = int(time.time())
    connection.execute(
        "INSERT INTO v2_device_accounts (account_key_hash, user_id, device_pk, device_id, "
        "created_at, last_used) VALUES (?, 7, 1, 'dev-1', ?, ?)",
        (v2._hash("account-secret"), now, now))
    connection.commit()
    connection.close()

    headers = {"cookie": "gid_acc_7=account-secret"}
    response = client.post("/api/v2/auth/switch", json={"account_id": 7}, headers=headers)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["username"] == "member"
    assert data["token"]

    wrong = client.post("/api/v2/auth/switch", json={"account_id": 7},
                        headers={"cookie": "gid_acc_7=nope"})
    assert wrong.status_code == 401


# ── Привязка токена к устройству ───────────────────────

def test_revoked_device_kills_service_refresh(client):
    connection = _account_db()
    _device(connection, 1, 7, "dev-1", "Ноутбук", "windows")
    _session(connection, 7, 1, "test-member-session")
    connection.commit()
    connection.close()

    client_id = register(client)["clientId"]
    verifier, challenge = pkce()
    created = authorize(client, client_id, challenge).json()
    approved = client.post(f"/api/v2/auth/requests/{created['requestId']}/approve",
                           json={}, headers=MEMBER)
    assert approved.status_code == 200, approved.text

    tokens = client.post("/api/v2/auth/token", json={
        "code": approved.json()["code"], "client_id": client_id,
        "redirect_uri": CALLBACK, "code_verifier": verifier}).json()
    assert tokens["refresh_token"]

    connection = _account_db()
    connection.execute("UPDATE auth_sessions SET status='revoked' WHERE device_pk=1")
    connection.commit()
    connection.close()

    dead = client.post("/api/v2/auth/token", json={
        "grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
        "client_id": client_id})
    assert dead.status_code == 401
    assert "отозвана" in dead.text



