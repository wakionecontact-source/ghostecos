#!/usr/bin/env python3
"""Provision the managed-bot AES-GCM key once; never prints the key."""

from __future__ import annotations

import os
import secrets
import stat
from pathlib import Path


def provision(path: Path = Path("/etc/ghostchat/bot-runner.env")) -> None:
    if os.geteuid() != 0:
        raise RuntimeError("Run as root to provision the managed bot key")
    if path.exists() or path.is_symlink():
        raise RuntimeError(f"Refusing to overwrite existing key file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    parent_info = path.parent.lstat()
    if not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != 0:
        raise RuntimeError("Key directory must be a root-owned real directory")
    if parent_info.st_mode & 0o022:
        raise RuntimeError("Key directory must not be group- or world-writable")

    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        payload = f"GHOSTBOT_RUNNER_KEY={secrets.token_hex(32)}\n".encode("ascii")
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)
    print(f"Managed bot encryption key created at {path}; key value was not printed.")


if __name__ == "__main__":
    provision()
