"""End-to-end sign-in through Social's public routes and Core's internal API."""
import secrets

import httpx
import password_auth


def test_v2_login_round_trip_and_replay(client, reg_user):
    user = reg_user(username="core_v2_signin", password="correctpass987")
    client_nonce = password_auth.b64e(secrets.token_bytes(32))
    challenge_response = client.post("/api/soc/auth/v2/login/challenge", json={
        "username": user["username"], "client_nonce": client_nonce,
    })
    assert challenge_response.status_code == 200, challenge_response.text
    challenge = challenge_response.json()
    verifier = password_auth.verifier_from_password(
        "correctpass987", password_auth.b64d(challenge["salt"]), challenge["kdf"],
    )
    message = password_auth.transcript(
        "login", user["username"], challenge["challenge_id"],
        client_nonce, challenge["server_nonce"], challenge["context"],
    )
    proof = password_auth.client_proof_from_password("correctpass987", verifier, message)
    finish_body = {"challenge_id": challenge["challenge_id"], "proof": proof}
    finish = client.post("/api/soc/auth/v2/login/finish", json=finish_body)
    assert finish.status_code == 200, finish.text
    assert finish.json()["token"]
    assert password_auth.verify_server_proof(
        verifier, message, finish.json()["server_proof"],
    )
    replay = client.post("/api/soc/auth/v2/login/finish", json=finish_body)
    assert replay.status_code == 401


def test_login_fails_closed_when_core_is_unavailable(client, reg_user, monkeypatch):
    import ecos_core.client as service_client

    user = reg_user(username="core_login_unavailable")
    unavailable = httpx.Client(transport=httpx.MockTransport(
        lambda request: (_ for _ in ()).throw(httpx.ConnectError("offline"))
    ))
    monkeypatch.setattr(service_client, "_HTTP", unavailable)
    response = client.post("/api/soc/login", json={
        "username": user["username"], "password": user["password"],
    })
    assert response.status_code == 503
    unavailable.close()


def test_v2_register_creates_core_account_and_welcome_reward(client):
    import sqlite3
    from ecos_core.identity import DB

    verifier = password_auth.new_verifier("v2correctpass456")
    response = client.post("/api/soc/auth/v2/register", json={
        "username": "core_v2_registration", "display_name": "V2 Registration",
        "verifier": verifier, "age_18_confirm": True,
    })
    assert response.status_code == 200, response.text
    assert response.json()["seed_phrase"]
    with sqlite3.connect(DB) as db:
        user = db.execute(
            "SELECT id, argon2_hash, auth_v1_salt FROM users WHERE username=?",
            ("core_v2_registration",),
        ).fetchone()
        assert user[1] == ""
        assert user[2] == verifier["salt"]
        balance = db.execute(
            "SELECT gost FROM soc_wallets WHERE user_id=?", (user[0],),
        ).fetchone()
    assert balance == (100,)
