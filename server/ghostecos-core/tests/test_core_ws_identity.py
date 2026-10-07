"""WebSocket sessions use Core's canonical device and account validation."""
import pytest
from starlette.websockets import WebSocketDisconnect


def test_ws_identity_resolves_through_core(client, reg_user):
    user = reg_user(username="core_ws_identity")
    with client.websocket_connect(
        "/api/soc/ws", headers={"X-GS-Token": user["token"]},
    ) as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello"
        assert hello["data"]["uid"] == user["id"]
        assert hello["data"]["username"] == user["username"]


def test_ws_rejects_unknown_token(client):
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect(
            "/api/soc/ws", headers={"X-GS-Token": "invalid-unknown-token"},
        ) as ws:
            ws.receive_json()
    assert exc.value.code == 4401
