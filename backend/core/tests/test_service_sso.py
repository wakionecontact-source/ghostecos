"""Реальные контракты HTTP/SQLite для входа GhostID через сервисы."""
import base64
import hashlib
import json
import secrets
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from ecos_core import service_sso as sso

ISSUER = "https://ghostecos.duckdns.org"
CALLBACK = "https://external.example/ghostid/callback?layout=small"
ADMIN = {"Authorization": "Bearer test-admin-session"}
MEMBER = {"Authorization": "Bearer test-member-session"}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("GE_SSO_DB_PATH", str(tmp_path / "sso.sqlite3"))
    monkeypatch.setenv("GE_SSO_ISSUER", ISSUER)
    monkeypatch.setattr(sso, "_rate_limit", lambda *args, **kwargs: None)
    database = tmp_path / "identity.sqlite3"
    monkeypatch.setenv("SOCIAL_DB_PATH", str(database))
    monkeypatch.setenv("GE_OWNER_USERNAME", "owner")
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, display_name TEXT, avatar_url TEXT, password_hash TEXT, private_key TEXT, is_admin INTEGER)")
    connection.execute("CREATE TABLE soc_tokens (token TEXT PRIMARY KEY, user_id INTEGER)")
    connection.execute("INSERT INTO users VALUES (7, 'member', 'Member Display', 'https://example.org/avatar.png', 'private-password-hash', 'private-key', 0)")
    connection.execute("INSERT INTO users VALUES (2, 'owner', 'Owner', NULL, 'owner-private-password', NULL, 1)")
    connection.executemany("INSERT INTO soc_tokens VALUES (?, ?)", [("test-admin-session", 2), ("test-member-session", 7)])
    connection.commit(); connection.close()
    app = FastAPI()
    sso.install(app)
    with TestClient(app) as http:
        yield http


def definition(client_id="my_service", **changes):
    return {"client_id": client_id, "name": "My service", "redirect_uris": [CALLBACK], **changes}


def register(client, client_id="my_service", **changes):
    response = client.post("/api/sso/clients", json=definition(client_id, **changes), headers=ADMIN)
    assert response.status_code == 201, response.text
    return response.json()


def pkce_parameters(verifier=None):
    verifier = verifier or secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return {"state": secrets.token_urlsafe(32), "code_challenge": challenge, "code_challenge_method": "S256"}


def entrance(client, **changes):
    verifier = changes.pop("_test_verifier", None) or secrets.token_urlsafe(48)
    payload = {**pkce_parameters(verifier), **changes}
    response = client.post("/api/sso/entrance", json={"client_id": "my_service", **payload})
    assert response.status_code == 201, response.text
    data = response.json()
    assert "code_verifier" not in data
    return {**data, "_test_verifier": verifier}


def authorize(client, request, consent=True):
    response = client.post(f"/api/sso/requests/{request['request_id']}/approve", json={"consent": consent}, headers=MEMBER)
    assert response.status_code == 200, response.text
    return parse_qs(urlsplit(response.json()["redirect_url"]).query)


def token_payload(request, query):
    return {"client_id": "my_service", "code": query["code"][0], "redirect_uri": CALLBACK,
            "code_verifier": request["_test_verifier"]}


def test_dynamic_registration_persists_without_code_changes(client):
    result = register(client, "new_product", name="A newly connected product")
    assert result["client"]["trusted"] is False
    response = client.get("/api/sso/clients/new_product")
    assert response.json()["client"]["name"] == "A newly connected product"
    request = entrance(client, client_id="new_product")
    info = client.get("/api/sso/requests/" + request["request_id"]).json()
    assert info["client"]["clientId"] == "new_product"
    # Разрешения сервиса — описания из каталога, только по его собственным скоупам.
    catalog = [item["description"] for item in sso._SCOPE_CATALOG.values()]
    assert info["client"]["permissions"]
    assert set(info["client"]["permissions"]) <= set(catalog)
    assert "code_verifier" not in info


def test_registration_requires_admin_and_cannot_overwrite(client):
    assert client.post("/api/sso/clients", json=definition()).status_code == 401
    assert client.post("/api/sso/clients", json=definition(), headers=MEMBER).status_code == 403
    register(client)
    assert client.post("/api/sso/clients", json=definition(), headers=ADMIN).status_code == 409


def test_shared_core_rejects_guest_and_revoked_session(client):
    register(client)
    request = entrance(client)
    endpoint = "/api/sso/requests/" + request["request_id"] + "/approve"
    assert client.post(endpoint, json={"consent": True}, headers={"Authorization": "Bearer guest_01234567890123456789"}).status_code == 403
    connection = sso.identity_db()
    connection.execute("DELETE FROM soc_tokens WHERE user_id=7")
    connection.commit(); connection.close()
    assert client.post(endpoint, json={"consent": True}, headers=MEMBER).status_code == 401


def test_full_login_exposes_only_allowed_public_profile(client):
    register(client)
    request = entrance(client)
    query = authorize(client, request)
    assert query["state"] == [request["state"]]
    assert query["iss"] == [ISSUER]
    assert query["layout"] == ["small"]
    grant = client.post("/api/sso/token", json=token_payload(request, query))
    assert grant.status_code == 200, grant.text
    token = grant.json()["access_token"]
    response = client.get("/api/sso/userinfo", headers={"Authorization": "Bearer " + token})
    assert response.json() == {"sub": "7", "username": "member", "client_id": "my_service",
                               "name": "Member Display", "picture": "https://example.org/avatar.png"}
    assert response.headers["cache-control"] == "no-store"
    with sso._db() as connection:
        text = json.dumps([dict(row) for row in connection.execute("SELECT * FROM entrances")])
        text += json.dumps([dict(row) for row in connection.execute("SELECT * FROM access_tokens")])
        assert "test-member-session" not in text and token not in text and query["code"][0] not in text


def test_profile_scopes_are_required_and_always_returned(client):
    register(client)
    request = entrance(client, scopes=["identity"])
    query = authorize(client, request)
    token = client.post("/api/sso/token", json=token_payload(request, query)).json()["access_token"]
    data = client.get("/api/sso/userinfo", headers={"Authorization": "Bearer " + token}).json()
    assert set(data) == {"sub", "username", "client_id", "name", "picture"}


@pytest.mark.parametrize("redirect", ["http://external.example/callback", "https://external.example/callback#fragment", "https://user:password@external.example/callback", "https://external.example/callback?state=preset", "javascript:alert(1)"])
def test_registration_rejects_unsafe_redirects(client, redirect):
    assert client.post("/api/sso/clients", json=definition(redirect_uris=[redirect]), headers=ADMIN).status_code == 422


def test_exact_callback_and_scope_allowlist(client):
    register(client, scopes=["identity", "profile"])
    for payload in ({"redirect_uri": CALLBACK + "&extra=1"}, {"redirect_uri": "https://external.example.evil.example/callback"}, {"scopes": ["identity", "profile", "password"]}):
        response = client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters(), **payload})
        assert response.status_code == 400
    assert client.post("/api/sso/clients", json=definition("bad_scopes", scopes=["identity", "messages"]), headers=ADMIN).status_code == 422


def test_pkce_callback_and_client_binding_preserve_valid_code(client):
    register(client)
    register(client, "other_service")
    request = entrance(client)
    query = authorize(client, request)
    payload = token_payload(request, query)
    for changed in ({"code_verifier": "x" * 64}, {"client_id": "other_service"}, {"redirect_uri": CALLBACK + "&extra=1"}):
        assert client.post("/api/sso/token", json={**payload, **changed}).status_code == 400
    assert client.post("/api/sso/token", json=payload).status_code == 200
    assert client.post("/api/sso/token", json=payload).status_code == 400


def test_browser_supplied_pkce_does_not_return_verifier(client):
    register(client)
    verifier = "a" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    request = entrance(client, code_challenge=challenge, state=secrets.token_urlsafe(32), _test_verifier=verifier)
    assert request["_test_verifier"] == verifier
    query = authorize(client, request)
    assert client.post("/api/sso/token", json={"client_id": "my_service", "redirect_uri": CALLBACK,
        "code": query["code"][0], "code_verifier": verifier}).status_code == 200


def test_concurrent_redemption_is_single_use(client):
    register(client)
    request = entrance(client)
    query = authorize(client, request)
    payload = token_payload(request, query)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.post("/api/sso/token", json=payload).status_code, range(2)))
    assert sorted(results) == [200, 400]


def test_request_and_code_expiry(client):
    register(client)
    request = entrance(client)
    with sso._db() as connection:
        connection.execute("UPDATE entrances SET expires_at=0 WHERE request_id=?", (request["request_id"],))
    assert client.get("/api/sso/requests/" + request["request_id"]).status_code == 410
    request = entrance(client)
    query = authorize(client, request)
    with sso._db() as connection:
        connection.execute("UPDATE entrances SET code_expires_at=0 WHERE request_id=?", (request["request_id"],))
    assert client.post("/api/sso/token", json=token_payload(request, query)).status_code == 400


def test_consent_denial_and_request_replay(client):
    register(client)
    request = entrance(client)
    query = authorize(client, request, consent=False)
    assert query["error"] == ["access_denied"] and "code" not in query
    response = client.post("/api/sso/requests/" + request["request_id"] + "/approve", json={"consent": True}, headers=MEMBER)
    assert response.status_code == 410


def test_metadata_changes_invalidate_pending_request_and_grant(client):
    register(client)
    pending = entrance(client)
    request = entrance(client)
    query = authorize(client, request)
    grant = client.post("/api/sso/token", json=token_payload(request, query)).json()
    updated = client.put("/api/sso/clients/my_service", json=definition(name="Changed service"), headers=ADMIN)
    assert updated.status_code == 200
    assert client.get("/api/sso/requests/" + pending["request_id"]).status_code == 409
    assert client.get("/api/sso/userinfo", headers={"Authorization": "Bearer " + grant["access_token"]}).status_code == 401


def test_scoped_cors_and_cross_origin_approval(client):
    register(client)
    headers = {"Origin": "https://external.example"}
    request = client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters()}, headers=headers)
    assert request.status_code == 201
    assert request.headers["access-control-allow-origin"] == headers["Origin"]
    preflight = client.options("/api/sso/token", headers={**headers, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"})
    assert preflight.status_code == 204 and "access-control-allow-credentials" not in preflight.headers
    path = "/api/sso/requests/" + request.json()["request_id"] + "/approve"
    assert client.post(path, json={"consent": True}, headers={**MEMBER, **headers}).status_code == 403
    assert client.post("/api/sso/entrance", json={"client_id": "my_service"}, headers={"Origin": "https://unregistered.example"}).status_code == 403


def test_origin_cannot_use_another_registered_clients_redirect(client):
    register(client)
    register(client, "other_service", redirect_uris=["https://other.example/callback"])
    assert client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters()}, headers={"Origin": "https://other.example"}).status_code == 403


def test_disabled_service_and_expired_token(client):
    register(client)
    request = entrance(client)
    query = authorize(client, request)
    token = client.post("/api/sso/token", json=token_payload(request, query)).json()["access_token"]
    with sso._db() as connection:
        connection.execute("UPDATE access_tokens SET expires_at=0")
    assert client.get("/api/sso/userinfo", headers={"Authorization": "Bearer " + token}).status_code == 401
    assert client.put("/api/sso/clients/my_service", json=definition(enabled=False), headers=ADMIN).status_code == 200
    assert client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters()}).status_code == 403


def test_legacy_telegram_adapter_and_core_session_remain_distinct(client):
    legacy = client.get("/api/sso/clients/ghogem_bot").json()["client"]
    assert legacy["transport"] == "telegram-start"
    assert legacy["authorizationEndpoint"] == "/ghogem-api/auth/link/webapp"
    assert legacy["termsVersion"] == "2026-09-28"
    assert client.post("/api/sso/entrance", json={"client_id": "ghogem_bot"}).status_code == 422
    assert client.get("/api/sso/userinfo", headers=MEMBER).status_code == 401


def test_malformed_request_has_no_redirect_and_no_server_error(client):
    assert client.get("/api/sso/requests/too_short").status_code == 404
    register(client)
    assert client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters(), "code_challenge_method": "plain"}).status_code == 422
    assert client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters(), "scopes": ["messages"]}).status_code == 400
    assert client.post("/api/sso/clients", json={**definition("my_extra"), "trusted": True}, headers=ADMIN).status_code == 422


@pytest.mark.parametrize("endpoint,fields", [
    ("/api/sso/clients", ["client_id", "name", "redirect_uris"]),
    ("/api/sso/clients/my_service", ["client_id", "name", "redirect_uris"]),
    ("/api/sso/entrance", ["client_id"]),
    ("/api/sso/token", ["client_id", "code", "redirect_uri", "code_verifier"]),
    ("/api/sso/requests/" + "a" * 43 + "/approve", ["consent"]),
])
def test_missing_fields_are_all_named(client, endpoint, fields):
    response = client.request("PUT" if endpoint.endswith("/my_service") else "POST", endpoint, json={})
    assert response.status_code == 422
    data = response.json()
    assert data["code"] == "missing_fields"
    assert data["missing_fields"] == fields
    assert [error["field"] for error in data["errors"]] == fields
    assert all(error["code"] == "required" and error["field"] in error["message"] for error in data["errors"])
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("value", [None, "", " \t "])
def test_empty_required_strings_are_named(client, value):
    response = client.post("/api/sso/clients", json=definition(name=value), headers=ADMIN)
    assert response.status_code == 422
    assert response.json()["missing_fields"] == ["name"]
    assert "название сервиса" in response.json()["detail"]


def test_empty_redirects_and_redirect_item_are_named(client):
    response = client.post("/api/sso/clients", json=definition(redirect_uris=[]), headers=ADMIN)
    assert response.json()["missing_fields"] == ["redirect_uris"]
    response = client.post("/api/sso/clients", json=definition(redirect_uris=[" "]), headers=ADMIN)
    assert response.json()["missing_fields"] == ["redirect_uris[0]"]
    response = client.post("/api/sso/clients", json=definition(redirect_uris=["http://external.example/callback"]), headers=ADMIN)
    assert response.json()["errors"][0]["field"] == "redirect_uris[0]"
    assert response.json()["code"] == "invalid_data"


@pytest.mark.parametrize("body", ["", "null", '{"client_id":'])
def test_missing_or_invalid_json_body_is_named(client, body):
    response = client.post("/api/sso/entrance", content=body, headers={"Content-Type": "application/json"})
    assert response.status_code == 422
    assert response.json()["errors"][0]["field"] == "body"
    assert "body" in response.json()["detail"]


def test_validation_errors_never_echo_authorization_secrets(client):
    code = "private-authorization-code-" + "a" * 43
    verifier = "private-PKCE-verifier-" + "b" * 150
    response = client.post("/api/sso/token", json={"code": code, "code_verifier": verifier})
    assert response.status_code == 422
    assert response.json()["missing_fields"] == ["client_id", "redirect_uri"]
    assert response.json()["code"] == "invalid_data"
    assert code not in response.text and verifier not in response.text
    assert all(set(error) == {"field", "code", "message"} for error in response.json()["errors"])


def test_optional_data_and_false_consent_remain_supported(client):
    register(client, icon="", website_url="")
    request = entrance(client, redirect_uri=None, scopes=None)
    assert request["redirect_uri"] == CALLBACK and request["_test_verifier"]
    assert authorize(client, request, consent=False)["error"] == ["access_denied"]


def test_missing_authorization_names_the_header(client):
    response = client.get("/api/sso/userinfo")
    assert response.status_code == 401 and "Authorization" in response.json()["detail"]
    response = client.post("/api/sso/clients", json=definition())
    assert response.status_code == 401 and "Authorization" in response.json()["detail"]


def test_validation_formatter_preserves_other_routes_and_handlers():
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse

    app = FastAPI()

    @app.exception_handler(RequestValidationError)
    async def custom_validation(request, error):
        return JSONResponse({"custom": True}, status_code=400)

    @app.post("/other")
    def other(body: sso.ApproveBody):
        return {"ok": True}

    sso.install(app)
    with TestClient(app) as http:
        response = http.post("/other", json={})
        assert response.status_code == 400 and response.json() == {"custom": True}
        response = http.post("/api/sso/entrance", json={})
        assert response.status_code == 422 and response.json()["missing_fields"] == ["client_id"]


def trusted_entrance(client, **changes):
    verifier = changes.pop("_test_verifier", None) or secrets.token_urlsafe(48)
    payload = {"client_id": "ghostchat", "redirect_uri": ISSUER + "/v2/chat/sso/callback",
               "prompt": "auto", **pkce_parameters(verifier), **changes}
    response = client.post("/api/sso/entrance", json=payload)
    assert response.status_code == 201, response.text
    data = response.json()
    assert "code_verifier" not in data
    return {**data, "_test_verifier": verifier}


def auto_approve(client, request, **changes):
    return client.post("/api/sso/requests/" + request["request_id"] + "/approve", json={"consent": True, "automatic": True}, headers={**MEMBER, **changes})


def test_auto_login_requires_prior_consent_then_completes_bound_pkce_flow(client):
    request = trusted_entrance(client)
    response = auto_approve(client, request)
    assert response.status_code == 409 and response.json()["code"] == "consent_required"
    assert client.get("/api/sso/requests/" + request["request_id"]).status_code == 200
    authorize(client, request)
    next_request = trusted_entrance(client)
    response = auto_approve(client, next_request)
    assert response.status_code == 200
    query = parse_qs(urlsplit(response.json()["redirect_url"]).query)
    assert query["state"] == [next_request["state"]]
    token = client.post("/api/sso/token", json={"client_id": "ghostchat", "code": query["code"][0], "redirect_uri": ISSUER + "/v2/chat/sso/callback", "code_verifier": next_request["_test_verifier"]})
    assert token.status_code == 200
    profile = client.get("/api/sso/userinfo", headers={"Authorization": "Bearer " + token.json()["access_token"]}).json()
    assert profile["sub"] == "7" and profile["client_id"] == "ghostchat"
    assert auto_approve(client, next_request).status_code == 410


def test_external_services_cannot_request_automatic_login(client):
    register(client)
    response = client.post("/api/sso/entrance", json={"client_id": "my_service", **pkce_parameters(), "prompt": "auto"})
    assert response.status_code == 403
    request = entrance(client)
    assert auto_approve(client, request).status_code == 403


def test_auto_login_cannot_be_added_to_manual_request(client):
    request = trusted_entrance(client, prompt="select_account")
    assert auto_approve(client, request).status_code == 403
    assert authorize(client, request)["code"]


def test_auto_login_does_not_reuse_other_users_or_narrower_consent(client):
    request = trusted_entrance(client, scopes=["identity", "profile"])
    authorize(client, request)
    response = auto_approve(client, trusted_entrance(client))
    assert response.status_code == 409
    response = auto_approve(client, trusted_entrance(client, scopes=["identity", "profile"]), Authorization="Bearer test-admin-session")
    assert response.status_code == 409
    assert auto_approve(client, trusted_entrance(client, scopes=["identity", "profile"])).status_code == 200


def test_auto_login_requires_live_session_and_local_origin(client):
    request = trusted_entrance(client)
    authorize(client, request)
    request = trusted_entrance(client)
    assert auto_approve(client, request, Origin="https://evil.example").status_code == 403
    assert auto_approve(client, request, Authorization="Bearer guest_01234567890123456789").status_code == 403
    connection = sso.identity_db(); connection.execute("DELETE FROM soc_tokens WHERE user_id=7"); connection.commit(); connection.close()
    assert auto_approve(client, request).status_code == 401


def test_configuration_revision_requires_fresh_consent_for_auto_login(client):
    request = trusted_entrance(client)
    authorize(client, request)
    updated = client.put("/api/sso/clients/ghostchat", json=definition("ghostchat", name="Updated GhostChat", redirect_uris=[ISSUER + "/v2/chat/sso/callback"]), headers=ADMIN)
    assert updated.status_code == 200
    assert auto_approve(client, trusted_entrance(client)).status_code == 409
