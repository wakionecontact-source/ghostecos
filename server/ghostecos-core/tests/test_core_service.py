"""Contracts for the standalone GhostEcos Core service."""
import hashlib
import hmac
import json
import time
import uuid
import pytest

SECRET = "test-only-ghostecos-internal-key-0123456789abcdef"
SERVICE = "ghostsocial"


@pytest.fixture
def core_client():
    from fastapi.testclient import TestClient
    from ecos_core_app import app
    return TestClient(app)


def signed_request(monkeypatch, method, path, payload, *, timestamp=None, nonce=None):
    monkeypatch.setenv("GE_INTERNAL_KEY_GHOSTSOCIAL", SECRET)
    timestamp = str(int(time.time()) if timestamp is None else timestamp)
    nonce = nonce or uuid.uuid4().hex
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    prefix = f"{timestamp}\n{nonce}\n{method.upper()}\n{path}\n".encode("utf-8")
    signature = hmac.new(SECRET.encode("utf-8"), prefix + body, hashlib.sha256).hexdigest()
    headers = {
        "Content-Type": "application/json",
        "X-GE-Service": SERVICE,
        "X-GE-Timestamp": timestamp,
        "X-GE-Nonce": nonce,
        "X-GE-Signature": signature,
    }
    return body, headers


def test_core_health(core_client):
    response = core_client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"ok": True, "service": "ghostecos-core"}


def test_core_resolves_existing_social_session(core_client, monkeypatch, reg_user):
    registered = reg_user(username="core_service_test")
    path = "/internal/v1/identity/resolve"
    body, headers = signed_request(monkeypatch, "POST", path, {"token": registered["token"]})
    response = core_client.post(path, content=body, headers=headers)
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["id"] == registered["id"]
    assert result["username"] == registered["username"]
    assert "token" not in result
    assert "password_hash" not in result


def test_core_rejects_bad_signature(core_client, monkeypatch):
    path = "/internal/v1/events/send"
    body, headers = signed_request(monkeypatch, "POST", path, {"user_id": 1, "type": "chat.new", "data": {}})
    headers["X-GE-Signature"] = "0" * 64
    response = core_client.post(path, content=body, headers=headers)
    assert response.status_code == 401


def test_core_rejects_stale_request(core_client, monkeypatch):
    path = "/internal/v1/events/send"
    body, headers = signed_request(monkeypatch, "POST", path, {"user_id": 1, "type": "chat.new", "data": {}}, timestamp=int(time.time()) - 120)
    response = core_client.post(path, content=body, headers=headers)
    assert response.status_code == 401


def test_core_event_send_uses_shared_hub(core_client, monkeypatch):
    import ecos_core_app
    calls = []
    monkeypatch.setenv("GE_INTERNAL_KEY_GHOSTSOCIAL", SECRET)
    monkeypatch.setattr(ecos_core_app.ws_hub, "send_to", lambda uid, event_type, data: calls.append((uid, event_type, data)))
    path = "/internal/v1/events/send"
    payload = {"user_id": 42, "type": "chat.new", "data": {"message_id": 7}}
    body, headers = signed_request(monkeypatch, "POST", path, payload)
    response = core_client.post(path, content=body, headers=headers)
    assert response.status_code == 200, response.text
    assert calls == [(42, "chat.new", {"message_id": 7})]


def test_core_rejects_replayed_request(core_client, monkeypatch):
    path = "/internal/v1/events/send"
    body, headers = signed_request(monkeypatch, "POST", path, {"user_id": 42, "type": "chat.new", "data": {}})
    first = core_client.post(path, content=body, headers=headers)
    second = core_client.post(path, content=body, headers=headers)
    assert first.status_code == 200
    assert second.status_code == 401

def test_core_checks_password_without_returning_hash(core_client, monkeypatch, reg_user):
    registered = reg_user(username="core_password_check", password="verify-pass-123")
    path = "/internal/v1/identity/verify-password"
    for password, expected in (("verify-pass-123", True), ("wrong-password", False)):
        body, headers = signed_request(monkeypatch, "POST", path, {
            "token": registered["token"], "password": password,
        })
        response = core_client.post(path, content=body, headers=headers)
        assert response.status_code == 200, response.text
        assert response.json() == {"valid": expected}

def test_core_serves_existing_social_api_surface(core_client):
    response = core_client.get("/api/soc/health")
    assert response.status_code == 200
    assert response.json()["service"] == "GhostSocial"
