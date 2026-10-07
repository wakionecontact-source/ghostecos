"""The product-service Core client signs requests and fails closed."""
import hashlib
import hmac
import json
import httpx
import pytest

import ecos_core.client as core_client

SECRET = "test-only-ghostecos-internal-key-0123456789abcdef"


@pytest.fixture
def core_transport(monkeypatch):
    seen = []
    monkeypatch.setenv("GE_SERVICE_NAME", "ghostsocial")
    monkeypatch.setenv("GE_INTERNAL_KEY_GHOSTSOCIAL", SECRET)
    monkeypatch.setenv("GE_CORE_URL", "http://core.test")

    def handler(request):
        body = request.content
        timestamp = request.headers["X-GE-Timestamp"]
        nonce = request.headers["X-GE-Nonce"]
        path = request.url.path
        prefix = f"{timestamp}\n{nonce}\n{request.method}\n{path}\n".encode()
        expected = hmac.new(SECRET.encode(), prefix + body, hashlib.sha256).hexdigest()
        assert hmac.compare_digest(expected, request.headers["X-GE-Signature"])
        seen.append((path, json.loads(body)))
        return httpx.Response(200, json={
            "id": 7, "username": "mila", "display_name": "Mila",
            "is_guest": False, "is_admin": False, "is_moderator": False,
        }, request=request)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(core_client, "_HTTP", client)
    yield seen
    client.close()
def test_auth_resolves_identity_and_preserves_local_contract(core_transport):
    user = core_client.auth("Bearer session-token")
    assert user["id"] == 7
    assert user["token"] == "session-token"
    assert core_transport == [
        ("/internal/v1/identity/resolve", {"token": "session-token"})
    ]


def test_member_auth_rejects_core_guest_response(monkeypatch, core_transport):
    client = core_client._HTTP
    def guest_handler(request):
        return httpx.Response(200, json={
            "id": 0, "username": "__guest__", "display_name": "Гость",
            "is_guest": True, "is_admin": False, "is_moderator": False,
        }, request=request)
    guest_client = httpx.Client(transport=httpx.MockTransport(guest_handler))
    monkeypatch.setattr(core_client, "_HTTP", guest_client)
    with pytest.raises(core_client.HTTPException) as exc:
        core_client.auth_member("Bearer guest_token_123456789")
    assert exc.value.status_code == 403
    guest_client.close()


def test_event_call_uses_signed_core_contract(core_transport):
    result = core_client.send_event(42, "chat.new", {"message_id": 8})
    assert result["id"] == 7
    assert core_transport == [
        ("/internal/v1/events/send", {
            "user_id": 42, "type": "chat.new", "data": {"message_id": 8},
        })
    ]
def test_client_fails_closed_without_service_key(monkeypatch):
    monkeypatch.delenv("GE_INTERNAL_KEY_GHOSTSOCIAL", raising=False)
    monkeypatch.setenv("GE_SERVICE_NAME", "ghostsocial")
    with pytest.raises(core_client.HTTPException) as exc:
        core_client.auth("Bearer session-token")
    assert exc.value.status_code == 503


def test_client_maps_core_auth_errors(monkeypatch):
    monkeypatch.setenv("GE_SERVICE_NAME", "ghostsocial")
    monkeypatch.setenv("GE_INTERNAL_KEY_GHOSTSOCIAL", SECRET)
    client = httpx.Client(transport=httpx.MockTransport(
        lambda request: httpx.Response(401, json={"detail": "Invalid token"}, request=request)
    ))
    monkeypatch.setattr(core_client, "_HTTP", client)
    with pytest.raises(core_client.HTTPException) as exc:
        core_client.auth("Bearer bad-token")
    assert exc.value.status_code == 401
    assert exc.value.detail == "Invalid token"
    client.close()
