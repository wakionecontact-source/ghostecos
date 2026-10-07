"""Upload prebuilt updater artifacts to the GhostEcos-owned OTA endpoint."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

from publish_asset_ota import _https_base, _request_json, _upload_file


ALLOWED_FILES = {
    "aot-tools.dill",
    "patch-darwin-arm64.zip",
    "patch-darwin-x64.zip",
    "patch-linux-x64.zip",
    "patch-windows-x64.zip",
}
MAX_FILE_BYTES = 256 * 1024 * 1024


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-revision", required=True)
    parser.add_argument("--artifact", action="append", required=True, metavar="NAME=PATH")
    parser.add_argument("--base-url", default="https://ghostecos.duckdns.org")
    args = parser.parse_args()

    token = os.environ.get("GC_CODE_OTA_ADMIN_TOKEN", "").strip()
    if not token:
        parser.error("set GC_CODE_OTA_ADMIN_TOKEN to the GhostEcos OTA publishing token")

    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.engine_revision):
            raise ValueError("invalid engine revision")
        base = _https_base(args.base_url)
        seen = set()
        for specification in args.artifact:
            name, separator, raw_path = specification.partition("=")
            if not separator or name not in ALLOWED_FILES or name in seen:
                raise ValueError(f"invalid or duplicate toolchain artifact: {specification}")
            source = Path(raw_path).resolve()
            size = source.stat().st_size
            if not source.is_file() or not 0 < size <= MAX_FILE_BYTES:
                raise ValueError(f"artifact must be a file up to 256 MiB: {source}")
            registration = _request_json(
                base,
                f"/api/v1/code-ota/toolchain/{args.engine_revision}/{name}",
                token,
                {"hash": _sha256(source), "size": size},
            )
            if not registration.get("uploaded", False):
                _upload_file(base, registration["upload_url"], token, source)
            seen.add(name)
            print(f"published {args.engine_revision}/{name} ({size} bytes)")
        return 0
    except (OSError, KeyError, TypeError, ValueError, RuntimeError) as error:
        print(f"toolchain OTA publish failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
