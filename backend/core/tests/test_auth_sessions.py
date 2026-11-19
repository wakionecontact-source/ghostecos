"""Per-login GhostEcos session lifecycle."""
import hashlib
import time

import pytest
from fastapi import HTTPException


def test_login_sessions_are_unique_expiring_and_revokeable(client, reg_user):
    from ecos_core.identity import db
    from ecos_core.client import auth_member

    account = reg_user(username="session_lifecycle_user", password="testpass987")
    login_a = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
    })
    login_b = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
    })
    assert login_a.status_code == 200, login_a.text
    assert login_b.status_code == 200, login_b.text

    a, b = login_a.json(), login_b.json()
    assert a["token"] == a["session_token"]
    assert b["token"] == b["session_token"]
    assert a["token"] != b["token"]
    assert a["session_id"] != b["session_id"]
    assert a["expires_at"] > int(time.time())
    assert a["status"] == "active"

    with db() as connection:
        rows = connection.execute(
            "SELECT session_id, token_hash, status FROM auth_sessions "
            "WHERE session_id IN (?, ?)",
            (a["session_id"], b["session_id"]),
        ).fetchall()
        by_id = {row["session_id"]: row for row in rows}
        assert by_id[a["session_id"]]["token_hash"] == hashlib.sha256(
            a["token"].encode()
        ).hexdigest()
        assert by_id[b["session_id"]]["token_hash"] == hashlib.sha256(
            b["token"].encode()
        ).hexdigest()
        assert a["token"] not in {row["token_hash"] for row in rows}

    listed = client.get(
        "/api/soc/sessions",
        headers={"Authorization": "Bearer " + a["token"]},
    )
    assert listed.status_code == 200, listed.text
    sessions = {row["session_id"]: row for row in listed.json()["sessions"]}
    assert sessions[a["session_id"]]["is_current"] is True
    assert sessions[b["session_id"]]["status"] == "active"

    revoked = client.post(
        f"/api/soc/sessions/{b['session_id']}/revoke",
        headers={"Authorization": "Bearer " + a["token"]},
    )
    assert revoked.status_code == 200, revoked.text
    assert revoked.json()["ok"] is True
    with pytest.raises(HTTPException) as rejected:
        auth_member("Bearer " + b["token"])
    assert rejected.value.status_code == 401

    login_c = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
    })
    assert login_c.status_code == 200, login_c.text
    c = login_c.json()
    with db() as connection:
        connection.execute(
            "UPDATE auth_sessions SET expires_at=? WHERE session_id=?",
            (int(time.time()) - 1, c["session_id"]),
        )
        connection.commit()
    with pytest.raises(HTTPException) as expired:
        auth_member("Bearer " + c["token"])
    assert expired.value.status_code == 401

    logout = client.post(
        "/api/soc/logout",
        headers={"Authorization": "Bearer " + a["token"]},
    )
    assert logout.status_code == 200, logout.text
    assert logout.json()["ok"] is True
    with pytest.raises(HTTPException) as logged_out:
        auth_member("Bearer " + a["token"])
    assert logged_out.value.status_code == 401


def test_device_token_is_hash_only_and_links_new_sessions(client, reg_user):
    from ecos_core.identity import db
    from ecos_core.client import auth_member

    account = reg_user(username="device_token_user", password="testpass987")
    first = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
    })
    assert first.status_code == 200, first.text
    first_data = first.json()
    device_token = first_data.get("device_token")
    assert device_token and first_data["device_id"] is None

    with db() as connection:
        first_session = connection.execute(
            "SELECT device_pk FROM auth_sessions WHERE session_id=?",
            (first_data["session_id"],),
        ).fetchone()
        assert first_session["device_pk"] is not None
        device = connection.execute(
            "SELECT device_token_hash, token FROM user_devices WHERE id=?",
            (first_session["device_pk"],),
        ).fetchone()
        assert device["device_token_hash"] == hashlib.sha256(
            device_token.encode()
        ).hexdigest()
        assert device_token != device["token"]

    second = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
        "device_token": device_token,
    })
    assert second.status_code == 200, second.text
    second_data = second.json()
    assert second_data["session_id"] != first_data["session_id"]
    with db() as connection:
        linked = connection.execute(
            "SELECT device_pk FROM auth_sessions WHERE session_id IN (?, ?)",
            (first_data["session_id"], second_data["session_id"]),
        ).fetchall()
        assert len(linked) == 2
        assert linked[0]["device_pk"] == linked[1]["device_pk"]

    with pytest.raises(HTTPException) as not_access:
        auth_member("Bearer " + device_token)
    assert not_access.value.status_code == 401

    rejected = client.post("/api/soc/login", json={
        "username": account["username"], "password": account["password"],
        "device_token": "invalid-device-token",
    })
    assert rejected.status_code == 401
