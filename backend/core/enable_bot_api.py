#!/usr/bin/env python3
"""Одноразовый установщик роутера ботов GhostSocial с откатом."""

from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


ROOT = Path("/opt/ghostchat")
APP = ROOT / "social_app.py"
BOT_API = ROOT / "bot_api.py"
INCOMING = ROOT / "bot_api.py.incoming"
NGINX = Path("/etc/nginx/sites-enabled/ghostchat_live.conf")
DB = ROOT / "ghostchat.db"
BACKUP = Path("/root/ghostecos-backups") / (
    "bots_" + datetime.now().strftime("%Y%m%d_%H%M%S")
)


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}): {detail[:500]}")
    return result


def atomic_write(path: Path, data: bytes) -> None:
    temp = path.with_name(path.name + ".codex-tmp")
    temp.write_bytes(data)
    os.chmod(temp, path.stat().st_mode & 0o777)
    os.replace(temp, path)


def insert_once(data: bytes, marker: bytes, replacement: bytes, already: bytes, name: str) -> bytes:
    if already in data:
        return data
    if marker not in data:
        raise RuntimeError(f"Cannot safely patch {name}: expected marker not found")
    return data.replace(marker, replacement, 1)


def make_app_patch(data: bytes) -> bytes:
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    data = insert_once(
        data,
        b"from chat_router import router as chat_router",
        b"from chat_router import router as chat_router"
        + newline
        + b"from bot_api import router as bot_api_router",
        b"from bot_api import router as bot_api_router",
        "social_app.py bot import",
    )
    data = insert_once(
        data,
        b"app.include_router(chat_router)",
        b"app.include_router(chat_router)"
        + newline
        + b"app.include_router(bot_api_router)",
        b"app.include_router(bot_api_router)",
        "social_app.py router registration",
    )
    if b'"/api/bots"' not in data:
        cache_marker = b'"/api/chat/unread", "/api/chat/contacts",'
        if cache_marker not in data:
            raise RuntimeError("Cannot safely patch social_app.py private cache paths")
        data = data.replace(
            cache_marker,
            cache_marker + newline + b'    "/api/bots",',
            1,
        )
    return data


def make_nginx_patch(data: bytes) -> bytes:
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    if b"location = /api/bots/ws" in data:
        return data
    marker = b"    location /api/bots/ {"
    if marker not in data:
        raise RuntimeError("Cannot safely patch Nginx: existing /api/bots/ route not found")
    block = newline.join(
        [
            b"    location = /api/bots/ws {",
            b"        proxy_pass http://127.0.0.1:8005;",
            b"        proxy_http_version 1.1;",
            b'        proxy_set_header Upgrade $http_upgrade;',
            b'        proxy_set_header Connection "upgrade";',
            b"        proxy_set_header Host $host;",
            b"        proxy_set_header X-Real-IP $remote_addr;",
            b"        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            b"        proxy_read_timeout 86400;",
            b"        proxy_send_timeout 86400;",
            b"    }",
            b"",
            marker,
        ]
    )
    return data.replace(marker, block, 1)


def backup_database() -> None:
    if not DB.is_file():
        raise RuntimeError(f"Production database not found: {DB}")
    destination = sqlite3.connect(str(BACKUP / "ghostchat.db"))
    try:
        source = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        try:
            tables = {
                row[0]
                for row in source.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            required = {"users", "bots", "gc_public_handles"}
            if not required.issubset(tables):
                raise RuntimeError("Production DB is missing a required bot schema table")
            source.backup(destination)
        finally:
            source.close()
    finally:
        destination.close()
    os.chmod(BACKUP / "ghostchat.db", 0o600)


def rollback() -> None:
    shutil.copy2(BACKUP / "social_app.py", APP)
    shutil.copy2(BACKUP / "bot_api.py", BOT_API)
    shutil.copy2(BACKUP / "ghostchat_live.conf", NGINX)
    run(["nginx", "-t"], check=False)
    run(["systemctl", "reload", "nginx"], check=False)
    run(["systemctl", "restart", "ghostsocial"], check=False)


def http_status(url: str) -> str:
    result = run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "--max-time",
            "8",
            url,
        ],
        check=False,
    )
    return result.stdout.strip()


def websocket_status() -> str:
    result = run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "--max-time",
            "8",
            "--http1.1",
            "-H",
            "Connection: Upgrade",
            "-H",
            "Upgrade: websocket",
            "-H",
            "Sec-WebSocket-Version: 13",
            "-H",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "-H",
            "Authorization: Bot invalid-deploy-probe",
            "https://ghostecos.duckdns.org/api/bots/ws",
        ],
        check=False,
    )
    return result.stdout.strip()


def main() -> int:
    if os.geteuid() != 0:
        raise RuntimeError("Run as root on the production host")
    if not INCOMING.is_file():
        raise RuntimeError(f"Upload the new router first: {INCOMING}")
    if run(["systemctl", "is-active", "ghostsocial"], check=False).stdout.strip() != "active":
        raise RuntimeError("ghostsocial must be active before deployment")

    app_data = APP.read_bytes()
    bot_data = INCOMING.read_bytes()
    nginx_data = NGINX.read_bytes()
    patched_app = make_app_patch(app_data)
    patched_nginx = make_nginx_patch(nginx_data)
    compile(bot_data, str(BOT_API), "exec")
    compile(patched_app, str(APP), "exec")

    BACKUP.mkdir(mode=0o700)
    os.chmod(BACKUP, 0o700)
    shutil.copy2(APP, BACKUP / "social_app.py")
    shutil.copy2(BOT_API, BACKUP / "bot_api.py")
    shutil.copy2(NGINX, BACKUP / "ghostchat_live.conf")
    backup_database()

    changed = False
    try:
        changed = True
        os.replace(INCOMING, BOT_API)
        os.chmod(BOT_API, 0o644)
        atomic_write(APP, patched_app)
        atomic_write(NGINX, patched_nginx)

        run(["nginx", "-t"])
        run(["systemctl", "restart", "ghostsocial"])
        for _ in range(90):
            active = run(["systemctl", "is-active", "ghostsocial"], check=False).stdout.strip()
            if active == "active" and http_status("http://127.0.0.1:8005/api/bots/mine") == "401":
                break
            time.sleep(1)
        else:
            raise RuntimeError("ghostsocial did not pass the local bot API probe after restart")

        run(["systemctl", "reload", "nginx"])
        response = ""
        for _ in range(15):
            response = http_status("https://ghostecos.duckdns.org/api/bots/mine")
            if response == "401":
                break
            time.sleep(1)
        if response != "401":
            raise RuntimeError(f"Expected unauthenticated bot API to return 401, got {response}")
        ws_response = websocket_status()
        if ws_response != "403":
            raise RuntimeError(f"Expected invalid WebSocket token to be rejected with 403, got {ws_response}")
    except Exception:
        if changed:
            rollback()
        raise

    print(f"BOT_API_DEPLOYED backup={BACKUP}")
    print("HTTP probe: /api/bots/mine returns 401 without credentials (expected)")
    print("WebSocket probe: invalid bot token is rejected during the Upgrade handshake (expected 403)")
    print("Database backup created with SQLite online-backup API; existing bot identities and token hashes were preserved")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"BOT_API_DEPLOY_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
