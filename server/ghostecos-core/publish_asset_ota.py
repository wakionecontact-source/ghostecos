"""Publish a signed GhostChat Flutter-asset release to GhostEcos.

The input directory is the Flutter project's `assets/` directory (or the
`build/flutter_assets/` directory containing it). Only data files are uploaded;
this tool never evaluates or publishes Dart/JavaScript code.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import secrets
import ssl
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_RELEASE_BYTES = 2 * 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024


def _https_base(value: str) -> str:
    parsed = urlsplit(value.strip().rstrip("/"))
    if parsed.scheme != "https" or not parsed.hostname or parsed.path or parsed.query or parsed.fragment:
        raise ValueError("base URL must be an HTTPS origin without a path")
    return f"https://{parsed.netloc}"


def _request_json(base: str, path: str, token: str, payload: dict) -> dict:
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = Request(
        f"{base}{path}",
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except HTTPError as error:
        detail = error.read(2048).decode("utf-8", "replace")
        raise RuntimeError(f"server returned HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise RuntimeError(f"could not reach the OTA server: {error.reason}") from error


def _upload_file(base: str, upload_url: str, token: str, source: Path) -> None:
    base_parts = urlsplit(base)
    upload_parts = urlsplit(upload_url)
    if (
        upload_parts.scheme != "https"
        or upload_parts.hostname != base_parts.hostname
        or upload_parts.port not in (None, 443)
        or upload_parts.query
        or upload_parts.fragment
    ):
        raise ValueError("server returned an unexpected upload URL")

    boundary = f"ghostecos-{secrets.token_hex(20)}"
    prefix = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="asset.bin"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode("ascii")
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    content_length = len(prefix) + source.stat().st_size + len(suffix)
    connection = http.client.HTTPSConnection(
        upload_parts.hostname,
        upload_parts.port or 443,
        timeout=300,
        context=ssl.create_default_context(),
    )
    try:
        connection.putrequest("POST", upload_parts.path)
        connection.putheader("Authorization", f"Bearer {token}")
        connection.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
        connection.putheader("Content-Length", str(content_length))
        connection.endheaders()
        connection.send(prefix)
        with source.open("rb") as file:
            while chunk := file.read(CHUNK_BYTES):
                connection.send(chunk)
        connection.send(suffix)
        response = connection.getresponse()
        message = response.read(2048).decode("utf-8", "replace")
        if response.status != 204:
            raise RuntimeError(f"upload failed for {source}: HTTP {response.status}: {message}")
    finally:
        connection.close()


def _asset_root(argument: Path) -> Path:
    root = argument.resolve()
    if (root / "assets").is_dir():
        root = (root / "assets").resolve()
    if not root.is_dir():
        raise ValueError(f"asset directory does not exist: {root}")
    return root


def _collect_assets(root: Path) -> list[dict]:
    result = []
    total_size = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"symlinks are not allowed in OTA assets: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if (
            not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,255}", relative)
            or any(part in {"", ".", ".."} for part in relative.split("/"))
        ):
            raise ValueError(f"invalid asset path: {relative}")
        size = path.stat().st_size
        if not 0 < size <= MAX_FILE_BYTES:
            raise ValueError(f"asset must be between 1 byte and 256 MiB: {path}")
        total_size += size
        if total_size > MAX_RELEASE_BYTES:
            raise ValueError("asset release exceeds the 2 GiB server limit")
        digest = hashlib.sha256()
        with path.open("rb") as file:
            while chunk := file.read(CHUNK_BYTES):
                digest.update(chunk)
        result.append(
            {
                "path": f"assets/{relative}",
                "hash": digest.hexdigest(),
                "size": size,
                "source": path,
            }
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", required=True, type=Path)
    parser.add_argument("--version", required=True, help="unique asset release label")
    parser.add_argument("--base-url", default="https://ghostecos.duckdns.org")
    parser.add_argument("--app-id", default="ghostchat-android")
    args = parser.parse_args()

    token = os.environ.get("GC_CODE_OTA_ADMIN_TOKEN", "").strip()
    if not token:
        parser.error("set GC_CODE_OTA_ADMIN_TOKEN to the GhostEcos OTA publishing token")

    try:
        base = _https_base(args.base_url)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", args.app_id):
            raise ValueError("invalid app id")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}", args.version):
            raise ValueError("invalid asset release version")
        root = _asset_root(args.assets_dir)
        assets = _collect_assets(root)
        registration = _request_json(
            base,
            f"/api/v1/apps/{args.app_id}/asset-releases",
            token,
            {
                "version": args.version,
                "assets": [
                    {"path": item["path"], "hash": item["hash"], "size": item["size"]}
                    for item in assets
                ],
            },
        )
        upload_details = {item["path"]: item for item in registration["assets"]}
        for index, item in enumerate(assets, start=1):
            upload = upload_details[item["path"]]
            if not upload.get("uploaded", False):
                _upload_file(base, upload["upload_url"], token, item["source"])
            print(f"uploaded {index}/{len(assets)}: {item['path']}")

        activated = _request_json(
            base,
            f"/api/v1/apps/{args.app_id}/asset-releases/{registration['id']}/activate",
            token,
            {},
        )
        print(
            f"activated asset release {activated['id']} ({args.version}, {len(assets)} files)"
        )
        return 0
    except (HTTPError, URLError, OSError, KeyError, TypeError, ValueError, RuntimeError) as error:
        print(f"asset OTA publish failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
