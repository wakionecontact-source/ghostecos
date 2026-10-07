import hashlib

import pytest

from publish_asset_ota import _asset_root, _collect_assets, _https_base


def test_collect_assets_from_flutter_build_directory(tmp_path):
    flutter_assets = tmp_path / "build" / "flutter_assets" / "assets"
    avatars = flutter_assets / "app_avatars"
    avatars.mkdir(parents=True)
    payload = b"avatar-bytes"
    (avatars / "avatar.png").write_bytes(payload)

    root = _asset_root(tmp_path / "build" / "flutter_assets")
    assets = _collect_assets(root)

    assert len(assets) == 1
    assert assets[0]["path"] == "assets/app_avatars/avatar.png"
    assert assets[0]["hash"] == hashlib.sha256(payload).hexdigest()
    assert assets[0]["size"] == len(payload)


def test_asset_collector_rejects_paths_that_server_would_reject(tmp_path):
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "картинка.png").write_bytes(b"data")

    with pytest.raises(ValueError, match="invalid asset path"):
        _collect_assets(assets)


@pytest.mark.parametrize("url", ["http://ghostecos.example", "https://host/path"])
def test_ota_api_only_accepts_an_https_origin(url):
    with pytest.raises(ValueError):
        _https_base(url)
