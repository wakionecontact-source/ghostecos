import base64
import hashlib
import json
from urllib.parse import urlsplit

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

import code_ota


APP_ID = "ghostchat-android"
ADMIN = {"Authorization": "Bearer test-code-ota-secret"}


def _client(tmp_path, monkeypatch):
    monkeypatch.setenv("GC_CODE_OTA_DIR", str(tmp_path / "artifacts"))
    monkeypatch.setenv("GC_CODE_OTA_DB_PATH", str(tmp_path / "code-ota.sqlite3"))
    monkeypatch.setenv("GC_CODE_OTA_ADMIN_TOKEN", "test-code-ota-secret")
    monkeypatch.setenv("GC_CODE_OTA_PUBLIC_URL", "https://ghostecos.duckdns.org")
    monkeypatch.setenv("GC_CODE_OTA_REQUIRE_SIGNATURE", "1")
    app = FastAPI()
    app.include_router(code_ota.router)
    return TestClient(app)


def test_runtime_router_disables_dart_ota_but_keeps_assets(monkeypatch):
    monkeypatch.delenv("GC_DART_CODE_OTA_ENABLED", raising=False)

    route_names = {route.name for route in code_ota.runtime_router().routes}

    assert route_names == {
        "create_code_ota_asset_release",
        "activate_code_ota_asset_release",
        "check_code_ota_assets",
        "download_code_ota_asset",
        "upload_code_ota_artifact",
    }


def test_runtime_router_can_explicitly_reenable_dart_ota(monkeypatch):
    monkeypatch.setenv("GC_DART_CODE_OTA_ENABLED", "true")

    assert code_ota.runtime_router() is code_ota.router


def test_disabled_dart_ota_rejects_existing_code_upload_tokens(tmp_path, monkeypatch):
    monkeypatch.setenv("GC_DART_CODE_OTA_ENABLED", "1")
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    payload = b"must not be uploadable while Dart OTA is disabled"
    response = client.post(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(payload).hexdigest(),
            "size": str(len(payload)),
            "filename": "release.apk",
        },
    )
    assert response.status_code == 200, response.text
    upload_path = urlsplit(response.json()["url"]).path

    monkeypatch.setenv("GC_DART_CODE_OTA_ENABLED", "0")
    app = FastAPI()
    app.include_router(code_ota.runtime_router())
    disabled_client = TestClient(app)
    response = disabled_client.post(
        upload_path,
        headers=ADMIN,
        files={"file": ("release.apk", payload, "application/octet-stream")},
    )

    assert response.status_code == 404


def _register_and_upload(client, url, content, filename="artifact.bin"):
    path = urlsplit(url).path
    response = client.post(
        path,
        headers=ADMIN,
        files={"file": (filename, content, "application/octet-stream")},
    )
    assert response.status_code == 204, response.text


def _create_active_release(client, version="1.2.2+4120"):
    response = client.post(
        f"/api/v1/apps/{APP_ID}/releases",
        headers=ADMIN,
        json={
            "version": version,
            "flutter_revision": "559ffa3f75",
            "flutter_version": "3.44.0",
        },
    )
    assert response.status_code == 200, response.text
    release = response.json()["release"]

    base_artifact = b"base release artifact"
    response = client.post(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(base_artifact).hexdigest(),
            "size": str(len(base_artifact)),
            "can_sideload": "false",
            "filename": "release.apk",
        },
    )
    assert response.status_code == 200, response.text
    _register_and_upload(client, response.json()["url"], base_artifact, "release.apk")

    response = client.patch(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}",
        headers=ADMIN,
        json={"platform": "android", "status": "active"},
    )
    assert response.status_code == 200, response.text
    return release


def _publish_patch(client, release_id, payload=b"compiled-patch"):
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches",
        headers=ADMIN,
        json={"release_id": release_id, "metadata": {"source": "test"}},
    )
    assert response.status_code == 200, response.text
    patch = response.json()
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches/{patch['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(payload).hexdigest(),
            "size": str(len(payload)),
            "hash_signature": "test-signature",
        },
    )
    assert response.status_code == 200, response.text
    _register_and_upload(client, response.json()["url"], payload)

    channels = client.get(f"/api/v1/apps/{APP_ID}/channels", headers=ADMIN)
    assert channels.status_code == 200
    stable_id = next(c["id"] for c in channels.json() if c["name"] == "stable")
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches/promote",
        headers=ADMIN,
        json={"patch_id": patch["id"], "channel_id": stable_id},
    )
    assert response.status_code == 204, response.text
    return patch


def test_patch_check_download_and_current_patch_short_circuit(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    patch = _publish_patch(client, release["id"], b"new-patch-bytes")

    listed = client.get(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}/patches", headers=ADMIN
    )
    assert listed.status_code == 200, listed.text
    listed_patch = listed.json()["patches"][0]
    assert listed_patch["id"] == patch["id"]
    assert listed_patch["artifacts"][0]["patch_id"] == patch["id"]
    assert listed_patch["artifacts"][0]["created_at"].endswith("Z")

    request = {
        "app_id": APP_ID,
        "channel": "stable",
        "release_version": release["version"],
        "platform": "android",
        "arch": "aarch64",
        "client_id": "must-not-be-stored",
    }
    checked = client.post("/api/v1/patches/check", json=request)
    assert checked.status_code == 200, checked.text
    body = checked.json()
    assert body["patch_available"] is True
    assert body["patch"]["number"] == patch["number"]
    assert body["patch"]["hash_signature"] == "test-signature"

    artifact_path = urlsplit(body["patch"]["download_url"]).path
    downloaded = client.get(artifact_path)
    assert downloaded.status_code == 200
    assert downloaded.content == b"new-patch-bytes"
    assert downloaded.headers["x-checksum-sha256"] == hashlib.sha256(b"new-patch-bytes").hexdigest()

    request["current_patch_number"] = patch["number"]
    current = client.post("/api/v1/patches/check", json=request).json()
    assert current["patch_available"] is False
    assert current["patch"] is None


def test_rollback_tells_client_to_uninstall_patch(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    patch = _publish_patch(client, release["id"])

    response = client.post(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}/patches/{patch['id']}/rollback",
        headers=ADMIN,
    )
    assert response.status_code == 204

    checked = client.post(
        "/api/v1/patches/check",
        json={
            "app_id": APP_ID,
            "channel": "stable",
            "release_version": release["version"],
            "platform": "android",
            "arch": "aarch64",
            "current_patch_number": patch["number"],
        },
    ).json()
    assert checked["patch_available"] is False
    assert checked["rolled_back_patch_numbers"] == [patch["number"]]


def test_upload_rejects_wrong_hash_and_patch_requires_signature(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches",
        headers=ADMIN,
        json={"release_id": release["id"], "metadata": {}},
    )
    patch = response.json()

    missing_signature = client.post(
        f"/api/v1/apps/{APP_ID}/patches/{patch['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(b"expected").hexdigest(),
            "size": "8",
        },
    )
    assert missing_signature.status_code == 400

    registered = client.post(
        f"/api/v1/apps/{APP_ID}/patches/{patch['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(b"expected").hexdigest(),
            "size": "8",
            "hash_signature": "test-signature",
        },
    )
    assert registered.status_code == 200, registered.text
    upload = client.post(
        urlsplit(registered.json()["url"]).path,
        headers=ADMIN,
        files={"file": ("artifact.bin", b"tamper!!", "application/octet-stream")},
    )
    assert upload.status_code == 422


def _configure_asset_signing(tmp_path, monkeypatch):
    pytest.importorskip("cryptography.hazmat.primitives.asymmetric.rsa")
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    key_path = tmp_path / "asset-ota-private.pem"
    key_path.write_bytes(
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    monkeypatch.setenv("GC_CODE_OTA_ASSET_PRIVATE_KEY", str(key_path))
    return private_key.public_key()


def _create_asset_release(client, version, assets):
    response = client.post(
        f"/api/v1/apps/{APP_ID}/asset-releases",
        headers=ADMIN,
        json={"version": version, "assets": assets},
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_asset_release_lifecycle_and_server_deduplicates_installed_hashes(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(
        code_ota,
        "_sign_asset_manifest",
        lambda payload: base64.b64encode(b"test-signature").decode("ascii"),
    )
    client = _client(tmp_path, monkeypatch)
    content = b"updated-avatar-image"
    digest = hashlib.sha256(content).hexdigest()

    release = _create_asset_release(
        client,
        "1.2.2+4120-assets1",
        [{"path": "assets/app_avatars/avatar.png", "hash": digest, "size": len(content)}],
    )
    resumed = _create_asset_release(
        client,
        "1.2.2+4120-assets1",
        [{"path": "assets/app_avatars/avatar.png", "hash": digest, "size": len(content)}],
    )
    assert resumed["id"] == release["id"]
    assert resumed["assets"][0]["upload_token"] == release["assets"][0]["upload_token"]
    blocked = client.post(
        f"/api/v1/apps/{APP_ID}/asset-releases/{release['id']}/activate", headers=ADMIN
    )
    assert blocked.status_code == 409

    upload = release["assets"][0]
    _register_and_upload(client, upload["upload_url"], content, "avatar.png")
    resumed_after_upload = _create_asset_release(
        client,
        "1.2.2+4120-assets1",
        [{"path": "assets/app_avatars/avatar.png", "hash": digest, "size": len(content)}],
    )
    assert resumed_after_upload["assets"][0]["uploaded"] is True
    activated = client.post(
        f"/api/v1/apps/{APP_ID}/asset-releases/{release['id']}/activate", headers=ADMIN
    )
    assert activated.status_code == 200, activated.text

    checked = client.post(
        "/api/v1/assets/check", json={"app_id": APP_ID, "installed_hashes": []}
    )
    assert checked.status_code == 200, checked.text
    payload = checked.json()
    assert payload["update_available"] is True
    assert len(payload["files"]) == 1
    assert base64.b64decode(payload["signature"]) == b"test-signature"
    manifest = json.loads(payload["manifest_json"])
    assert manifest["release_id"] == release["id"]
    downloaded = client.get(urlsplit(manifest["assets"][0]["url"]).path)
    assert downloaded.status_code == 200
    assert downloaded.content == content

    same_release = client.post(
        "/api/v1/assets/check",
        json={
            "app_id": APP_ID,
            "installed_release_id": release["id"],
            "installed_hashes": [digest],
        },
    ).json()
    assert same_release["update_available"] is False
    same_release_missing_blob = client.post(
        "/api/v1/assets/check",
        json={"app_id": APP_ID, "installed_release_id": release["id"], "installed_hashes": []},
    ).json()
    assert same_release_missing_blob["update_available"] is True
    assert len(same_release_missing_blob["files"]) == 1

    next_release = _create_asset_release(
        client,
        "1.2.2+4120-assets2",
        [{"path": "assets/app_avatars/avatar.png", "hash": digest, "size": len(content)}],
    )
    _register_and_upload(
        client, next_release["assets"][0]["upload_url"], content, "avatar.png"
    )
    activated = client.post(
        f"/api/v1/apps/{APP_ID}/asset-releases/{next_release['id']}/activate",
        headers=ADMIN,
    )
    assert activated.status_code == 200, activated.text
    deduplicated = client.post(
        "/api/v1/assets/check",
        json={
            "app_id": APP_ID,
            "installed_release_id": release["id"],
            "installed_hashes": [digest],
        },
    ).json()
    assert deduplicated["update_available"] is True
    assert deduplicated["files"] == []


def test_asset_manifest_signatures_are_rsa_sha256(tmp_path, monkeypatch):
    public_key = _configure_asset_signing(tmp_path, monkeypatch)
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    message = b'{"app_id":"ghostchat-android","protocol":1}'
    signature = base64.b64decode(code_ota._sign_asset_manifest(message))
    public_key.verify(signature, message, padding.PKCS1v15(), hashes.SHA256())


def test_ghostecos_toolchain_artifact_register_upload_and_download(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    content = b"compressed-patch-toolchain"
    payload = {"hash": hashlib.sha256(content).hexdigest(), "size": len(content)}
    url = "/api/v1/code-ota/toolchain/559ffa3f75/patch-linux-x64.zip"

    forbidden = client.post(url, json=payload)
    assert forbidden.status_code == 401
    registered = client.post(url, headers=ADMIN, json=payload)
    assert registered.status_code == 200, registered.text
    _register_and_upload(client, registered.json()["upload_url"], content)
    registered_again = client.post(url, headers=ADMIN, json=payload)
    assert registered_again.status_code == 200
    assert registered_again.json()["uploaded"] is True

    downloaded = client.get(url)
    assert downloaded.status_code == 200
    assert downloaded.content == content
    assert downloaded.headers["x-checksum-sha256"] == payload["hash"]

    invalid = client.post(
        "/api/v1/code-ota/toolchain/revision/../../private.bin",
        headers=ADMIN,
        json=payload,
    )
    assert invalid.status_code in {404, 400}


def test_patch_promotion_requires_every_active_release_architecture(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)

    base = b"second architecture base"
    response = client.post(
        f"/api/v1/apps/{APP_ID}/releases/{release['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "arm",
            "platform": "android",
            "hash": hashlib.sha256(base).hexdigest(),
            "size": str(len(base)),
            "can_sideload": "false",
            "filename": "release-arm.apk",
        },
    )
    assert response.status_code == 200, response.text
    _register_and_upload(client, response.json()["url"], base, "release-arm.apk")

    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches",
        headers=ADMIN,
        json={"release_id": release["id"], "metadata": {}},
    )
    patch = response.json()
    payload = b"aarch64-only-patch"
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches/{patch['id']}/artifacts",
        headers=ADMIN,
        data={
            "arch": "aarch64",
            "platform": "android",
            "hash": hashlib.sha256(payload).hexdigest(),
            "size": str(len(payload)),
            "hash_signature": "test-signature",
        },
    )
    assert response.status_code == 200, response.text
    _register_and_upload(client, response.json()["url"], payload)

    channels = client.get(f"/api/v1/apps/{APP_ID}/channels", headers=ADMIN).json()
    stable_id = next(channel["id"] for channel in channels if channel["name"] == "stable")
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches/promote",
        headers=ADMIN,
        json={"patch_id": patch["id"], "channel_id": stable_id},
    )
    assert response.status_code == 409
    assert "every architecture" in response.json()["detail"]


def test_patch_artifact_must_match_an_active_base_release_target(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    response = client.post(
        f"/api/v1/apps/{APP_ID}/patches",
        headers=ADMIN,
        json={"release_id": release["id"], "metadata": {}},
    )
    patch = response.json()

    for platform, arch in (("windows", "x64"), ("android", "arm")):
        response = client.post(
            f"/api/v1/apps/{APP_ID}/patches/{patch['id']}/artifacts",
            headers=ADMIN,
            data={
                "arch": arch,
                "platform": platform,
                "hash": hashlib.sha256(b"unused").hexdigest(),
                "size": "6",
                "hash_signature": "test-signature",
            },
        )
        assert response.status_code == 409


def test_admin_routes_require_dedicated_token(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    assert client.get("/api/v1/apps").status_code == 401
    assert client.get("/api/v1/apps", headers={"Authorization": "Bearer wrong"}).status_code == 401

    monkeypatch.delenv("GC_CODE_OTA_ADMIN_TOKEN")
    assert client.get("/api/v1/apps", headers=ADMIN).status_code == 503


def test_patch_check_is_scoped_to_exact_release_and_arch(tmp_path, monkeypatch):
    client = _client(tmp_path, monkeypatch)
    release = _create_active_release(client)
    _publish_patch(client, release["id"])

    request = {
        "app_id": APP_ID,
        "channel": "stable",
        "release_version": "1.2.3+4121",
        "platform": "android",
        "arch": "aarch64",
    }
    assert client.post("/api/v1/patches/check", json=request).json()["patch_available"] is False
    request["release_version"] = release["version"]
    request["arch"] = "arm"
    assert client.post("/api/v1/patches/check", json=request).json()["patch_available"] is False
