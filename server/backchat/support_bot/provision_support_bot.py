#!/usr/bin/env python3
"""Safely rotate the pre-provisioned @support bot token on production once."""

from __future__ import annotations

import argparse
import grp
import hashlib
import os
import secrets
import sqlite3
import stat
from datetime import datetime
from pathlib import Path

from argon2 import PasswordHasher


SUPPORT_USERNAME = "support"
SERVICE_GROUP = "ghostsupport"


def _backup_database(database: Path, backup_root: Path) -> Path:
    backup_dir = backup_root / (
        "supportbot_" + datetime.now().strftime("%Y%m%d_%H%M%S")
        + "_" + secrets.token_hex(3)
    )
    backup_dir.mkdir(parents=True, mode=0o700)
    os.chmod(backup_dir, 0o700)
    backup_file = backup_dir / "ghostchat.db"
    source = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    destination = sqlite3.connect(backup_file)
    try:
        source.backup(destination)
        destination.commit()
    finally:
        destination.close()
        source.close()
    os.chmod(backup_file, 0o600)
    if backup_file.stat().st_size == 0:
        raise RuntimeError("The production database backup is empty")
    return backup_file


def _prepare_token_directory(path: Path, gid: int) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o750)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0:
        raise RuntimeError("Credential directory must be a root-owned real directory")
    os.chown(path, 0, gid)
    os.chmod(path, 0o750)


def provision(database: Path, token_file: Path, backup_root: Path) -> Path:
    if os.geteuid() != 0:
        raise RuntimeError("Run this one-shot production provisioner as root")
    if not database.is_file():
        raise RuntimeError("Production database was not found")
    if token_file.exists() or token_file.is_symlink():
        raise RuntimeError("Credential file already exists; refusing to overwrite it")

    group = grp.getgrnam(SERVICE_GROUP)
    _prepare_token_directory(token_file.parent, group.gr_gid)
    backup_file = _backup_database(database, backup_root)

    token = secrets.token_urlsafe(32)
    token_hash = PasswordHasher().hash(token)
    token_digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    created_token_file = False

    try:
        fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        created_token_file = True
        try:
            os.fchown(fd, 0, group.gr_gid)
            os.write(fd, (token + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)

        connection = sqlite3.connect(database, timeout=15)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT u.id, u.username, u.account_type, u.is_bot, "
                "b.status, b.is_active FROM users u JOIN bots b ON b.user_id=u.id "
                "WHERE lower(u.username)=? LIMIT 1",
                (SUPPORT_USERNAME,),
            ).fetchone()
            if not row:
                raise RuntimeError("The existing @support bot record was not found")
            if row["username"].lower() != SUPPORT_USERNAME:
                raise RuntimeError("The bot username does not match @support")
            if row["account_type"] != "bot" or int(row["is_bot"] or 0) != 1:
                raise RuntimeError("The existing @support account is not marked as a bot")
            if int(row["is_active"] or 0) != 1:
                raise RuntimeError("The existing @support bot is disabled")
            if row["status"] != "offline":
                raise RuntimeError("The @support bot is not offline; refusing token rotation")

            updated = connection.execute(
                "UPDATE bots SET token_hash=?, token_digest=?, status='offline' "
                "WHERE user_id=? AND is_active=1",
                (token_hash, token_digest, int(row["id"])),
            ).rowcount
            if updated != 1:
                raise RuntimeError("Expected to rotate exactly one active @support bot")
            connection.commit()
        finally:
            connection.close()
    except Exception:
        if created_token_file:
            token_file.unlink(missing_ok=True)
        raise

    return backup_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, default=Path("/opt/ghostchat/ghostchat.db"))
    parser.add_argument("--token-file", type=Path, default=Path("/etc/ghostchat-support/token"))
    parser.add_argument("--backup-root", type=Path, default=Path("/root/ghostecos-backups"))
    args = parser.parse_args()
    backup = provision(args.database, args.token_file, args.backup_root)
    print(f"@support bot token rotated; private backup: {backup}")
    print("The token was not printed.")


if __name__ == "__main__":
    main()
