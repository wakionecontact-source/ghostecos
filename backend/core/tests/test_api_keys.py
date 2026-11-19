"""Управление API-ключами GhostStudio и проверка области доступа."""
import json
import re

from fastapi.testclient import TestClient


def _api_client():
    from ecos_core_app import app
    return TestClient(app)


def _session(token):
    return {"Authorization": "Bearer " + token}


def test_api_keys_are_account_bound_one_time_and_revocable(client, reg_user):
    owner = reg_user(username="studio_key_owner", display_name="Studio Owner")
    other = reg_user(username="studio_key_other")
    with _api_client() as api:
        assert api.get("/api/developer/keys").status_code == 401
        guest = api.get("/api/developer/keys", headers=_session("guest_" + "x" * 40))
        assert guest.status_code == 403

        created = api.post("/api/developer/keys", headers=_session(owner["token"]), json={
            "name": "My first integration",
            "scopes": ["identity:read", "profile:read"],
            "expires_in_days": 30,
        })
        assert created.status_code == 201, created.text
        data = created.json()
        api_key = data["api_key"]
        assert re.fullmatch(r"ge_live_[A-Za-z0-9_-]{43}", api_key)
        assert data["name"] == "My first integration"
        assert data["status"] == "active"
        assert created.headers["cache-control"] == "no-store"

        listed = api.get("/api/developer/keys", headers=_session(owner["token"]))
        assert listed.status_code == 200
        assert len(listed.json()["keys"]) == 1
        key_info = listed.json()["keys"][0]
        assert key_info["key_id"] == data["key_id"]
        assert "api_key" not in key_info
        assert "token_hash" not in json.dumps(key_info)
        assert api_key not in json.dumps(listed.json())

        assert api.get("/api/developer/keys", headers=_session(other["token"])).json()["keys"] == []
        wrong_owner_revoke = api.post(
            "/api/developer/keys/" + data["key_id"] + "/revoke",
            headers=_session(other["token"]),
        )
        assert wrong_owner_revoke.status_code == 404

        profile = api.get("/api/developer/v1/me", headers=_session(api_key))
        assert profile.status_code == 200, profile.text
        assert profile.json()["sub"] == str(owner["id"])
        assert profile.json()["username"] == owner["username"]
        assert profile.json()["name"] == owner["display_name"]
        assert "picture" in profile.json()

        # API-ключ не может управлять ключами или создавать новые — нужна сессия GhostID.
        assert api.get("/api/developer/keys", headers=_session(api_key)).status_code == 401

        revoked = api.post(
            "/api/developer/keys/" + data["key_id"] + "/revoke",
            headers=_session(owner["token"]),
        )
        assert revoked.status_code == 200
        assert api.get("/api/developer/v1/me", headers=_session(api_key)).status_code == 401


def test_api_key_scope_and_expiry(client, reg_user):
    owner = reg_user(username="studio_key_identity_only")
    with _api_client() as api:
        created = api.post("/api/developer/keys", headers=_session(owner["token"]), json={
            "name": "Identity only",
            "scopes": ["identity:read"],
            "expires_in_days": 1,
        })
        assert created.status_code == 201, created.text
        data = created.json()

        result = api.get("/api/developer/v1/me", headers=_session(data["api_key"]))
        assert result.status_code == 200
        assert set(result.json()) == {"sub", "username"}

        from ecos_core import api_keys
        with api_keys._db() as connection:
            connection.execute(
                "UPDATE api_keys SET expires_at=0 WHERE key_id=?",
                (data["key_id"],),
            )
        assert api.get("/api/developer/v1/me", headers=_session(data["api_key"])).status_code == 401


def test_api_key_creation_rejects_invalid_scope_and_missing_account(client, reg_user):
    owner = reg_user(username="studio_key_validation")
    with _api_client() as api:
        assert api.post("/api/developer/keys", json={
            "name": "No account", "scopes": ["identity:read"],
        }).status_code == 401
        invalid = api.post("/api/developer/keys", headers=_session(owner["token"]), json={
            "name": "Too much access", "scopes": ["identity:read", "account:delete"],
        })
        assert invalid.status_code == 422
