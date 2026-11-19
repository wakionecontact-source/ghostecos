"""Восстановление аккаунта и проверка пароля через подписанный Core API."""
import secrets

import password_auth


def test_seed_recovery_and_regeneration(client):
    user = client.post("/api/soc/register", json={
        "username": "core_recovery_test", "display_name": "Recovery Test",
        "password": "recovery-pass-987", "age_18_confirm": True,
    })
    assert user.status_code == 200, user.text
    registered = user.json()
    recovered = client.post("/api/soc/recovery/seed", json={
        "username": registered["username"], "seed_phrase": registered["seed_phrase"],
    })
    assert recovered.status_code == 200, recovered.text
    token = recovered.json()["token"]
    identity = client.get("/api/soc/me", headers={"Authorization": "Bearer " + token})
    assert identity.status_code == 200
    assert identity.json()["username"] == registered["username"]
    renewed = client.post("/api/soc/me/regen_seed", json={
        "password": "recovery-pass-987",
    }, headers={"Authorization": "Bearer " + token})
    assert renewed.status_code == 200, renewed.text
    assert renewed.json()["seed_phrase"] != registered["seed_phrase"]
    old_seed = client.post("/api/soc/recovery/seed", json={
        "username": registered["username"], "seed_phrase": registered["seed_phrase"],
    })
    assert old_seed.status_code == 401


def test_password_proof_is_single_use(client, reg_user):
    user = reg_user(username="core_password_proof", password="proof-pass-123")
    client_nonce = password_auth.b64e(secrets.token_bytes(32))
    headers = {"Authorization": "Bearer " + user["token"]}
    challenge = client.post("/api/soc/auth/v2/password/challenge", json={
        "purpose": "verify_password", "client_nonce": client_nonce,
    }, headers=headers)
    assert challenge.status_code == 200, challenge.text
    data = challenge.json()
    verifier = password_auth.verifier_from_password(
        user["password"], password_auth.b64d(data["salt"]), data["kdf"],
    )
    message = password_auth.transcript(
        "verify_password", user["username"], data["challenge_id"],
        client_nonce, data["server_nonce"], data["context"],
    )
    proof = password_auth.client_proof_from_password(user["password"], verifier, message)
    body = {"challenge_id": data["challenge_id"], "proof": proof}
    verified = client.post("/api/soc/auth/v2/password/verify", json=body, headers=headers)
    assert verified.status_code == 200, verified.text
    assert password_auth.verify_server_proof(
        verifier, message, verified.json()["server_proof"],
    )
    replay = client.post("/api/soc/auth/v2/password/verify", json=body, headers=headers)
    assert replay.status_code == 422


def test_sso_token_is_issued_by_core(client, reg_user):
    import os
    import jwt

    user = reg_user(username="core_sso_test")
    response = client.post("/api/soc/sso/jwt", headers={
        "Authorization": "Bearer " + user["token"],
    })
    assert response.status_code == 200, response.text
    token = response.json()["jwt"]
    payload = jwt.decode(token, os.environ["GC_JWT_SECRET"], algorithms=["HS256"])
    assert payload["sub"] == user["username"]
    assert payload["uid"] == user["id"]
