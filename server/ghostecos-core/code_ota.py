"""GhostChat's retained Dart Code OTA and signed asset OTA handlers.

Production uses ``runtime_router`` so Dart-patch routes stay disabled unless
explicitly enabled. Asset routes remain available independently. Publishing
routes require a dedicated bearer token and store artifacts outside the web
root. Device identifiers sent by upstream clients are ignored and never
persisted.
"""

from __future__ import annotations

import hashlib
import hmac
import base64
import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.routing import APIRoute
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import UploadFile


router = APIRouter(tags=["GhostChat Code OTA"])

_ASSET_OTA_ROUTE_NAMES = frozenset(
    {
        "create_code_ota_asset_release",
        "activate_code_ota_asset_release",
        "check_code_ota_assets",
        "download_code_ota_asset",
        "upload_code_ota_artifact",
    }
)


def dart_code_ota_enabled() -> bool:
    """Dart patch delivery is opt-in; signed asset OTA remains available."""
    return os.environ.get("GC_DART_CODE_OTA_ENABLED", "0").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def runtime_router() -> APIRouter:
    """Return production routes with Dart code OTA disabled by default."""
    if dart_code_ota_enabled():
        return router

    assets_router = APIRouter(tags=["GhostChat Asset OTA"])
    assets_router.routes.extend(
        route
        for route in router.routes
        if isinstance(route, APIRoute) and route.name in _ASSET_OTA_ROUTE_NAMES
    )
    return assets_router

_APP_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$")
_ARCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
_ENGINE_REVISION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_TOOLCHAIN_FILES = {
    "aot-tools.dill",
    "patch-darwin-arm64.zip",
    "patch-darwin-x64.zip",
    "patch-linux-x64.zip",
    "patch-windows-x64.zip",
}
_ASSET_PATH_RE = re.compile(r"^assets/[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")
_PLATFORMS = {"android", "ios", "macos", "windows", "linux"}
_DEFAULT_MAX_ARTIFACT_BYTES = 256 * 1024 * 1024


class PatchCheckBody(BaseModel):
    model_config = ConfigDict(extra="ignore")

    app_id: str = Field(min_length=1, max_length=128)
    channel: str = Field(default="stable", min_length=1, max_length=64)
    release_version: str = Field(min_length=1, max_length=64)
    platform: str = Field(min_length=1, max_length=16)
    arch: str = Field(min_length=1, max_length=32)
    current_patch_number: int | None = Field(default=None, ge=1)
    # Kept for compatibility with older updater clients.
    patch_number: int | None = Field(default=None, ge=1)


def _data_dir() -> Path:
    return Path(os.environ.get("GC_CODE_OTA_DIR", "/opt/ghostchat/code_ota"))


def _db_path() -> Path:
    configured = os.environ.get("GC_CODE_OTA_DB_PATH")
    if configured:
        return Path(configured)
    return _data_dir() / "code_ota.sqlite3"


def _max_artifact_bytes() -> int:
    try:
        value = int(os.environ.get("GC_CODE_OTA_MAX_ARTIFACT_BYTES", str(_DEFAULT_MAX_ARTIFACT_BYTES)))
    except ValueError:
        value = _DEFAULT_MAX_ARTIFACT_BYTES
    return max(1, min(value, 2 * 1024 * 1024 * 1024))


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    try:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS code_ota_apps (
                app_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS code_ota_releases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL REFERENCES code_ota_apps(app_id),
                version TEXT NOT NULL,
                flutter_revision TEXT NOT NULL,
                flutter_version TEXT,
                display_name TEXT,
                platform_statuses TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(app_id, version)
            );
            CREATE TABLE IF NOT EXISTS code_ota_channels (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL REFERENCES code_ota_apps(app_id),
                name TEXT NOT NULL,
                UNIQUE(app_id, name)
            );
            CREATE TABLE IF NOT EXISTS code_ota_patches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL REFERENCES code_ota_apps(app_id),
                release_id INTEGER NOT NULL REFERENCES code_ota_releases(id),
                number INTEGER NOT NULL,
                metadata TEXT NOT NULL DEFAULT '{}',
                channel TEXT,
                is_rolled_back INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(release_id, number)
            );
            CREATE TABLE IF NOT EXISTS code_ota_artifacts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL REFERENCES code_ota_apps(app_id),
                release_id INTEGER NOT NULL REFERENCES code_ota_releases(id),
                patch_id INTEGER REFERENCES code_ota_patches(id),
                kind TEXT NOT NULL CHECK(kind IN ('release', 'patch')),
                arch TEXT NOT NULL,
                platform TEXT NOT NULL,
                hash TEXT NOT NULL,
                size INTEGER NOT NULL,
                hash_signature TEXT,
                podfile_lock_hash TEXT,
                can_sideload INTEGER NOT NULL DEFAULT 0,
                upload_token TEXT NOT NULL UNIQUE,
                storage_name TEXT NOT NULL UNIQUE,
                uploaded INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                UNIQUE(kind, release_id, patch_id, platform, arch)
            );
            CREATE TABLE IF NOT EXISTS code_ota_toolchain_artifacts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                engine_revision TEXT NOT NULL,
                filename TEXT NOT NULL,
                hash TEXT NOT NULL,
                size INTEGER NOT NULL,
                upload_token TEXT NOT NULL UNIQUE,
                storage_name TEXT NOT NULL UNIQUE,
                uploaded INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                UNIQUE(engine_revision, filename)
            );
            CREATE TABLE IF NOT EXISTS code_ota_asset_releases (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL REFERENCES code_ota_apps(app_id),
                version TEXT NOT NULL,
                manifest_json TEXT,
                signature TEXT,
                active INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                UNIQUE(app_id, version)
            );
            CREATE TABLE IF NOT EXISTS code_ota_asset_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                release_id INTEGER NOT NULL REFERENCES code_ota_asset_releases(id),
                asset_path TEXT NOT NULL,
                hash TEXT NOT NULL,
                size INTEGER NOT NULL,
                upload_token TEXT NOT NULL UNIQUE,
                storage_name TEXT NOT NULL UNIQUE,
                uploaded INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                UNIQUE(release_id, asset_path)
            );
            CREATE INDEX IF NOT EXISTS code_ota_release_lookup
                ON code_ota_releases(app_id, version, updated_at);
            CREATE INDEX IF NOT EXISTS code_ota_patch_lookup
                ON code_ota_patches(release_id, channel, is_rolled_back, number);
            CREATE INDEX IF NOT EXISTS code_ota_artifact_lookup
                ON code_ota_artifacts(release_id, patch_id, platform, arch, uploaded);
            CREATE INDEX IF NOT EXISTS code_ota_asset_active
                ON code_ota_asset_releases(app_id, active, id);
            """
        )
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _now() -> int:
    return int(time.time())


def _iso(timestamp: int) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def _public_base_url() -> str:
    value = os.environ.get("GC_CODE_OTA_PUBLIC_URL", "https://ghostecos.duckdns.org").strip().rstrip("/")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise HTTPException(503, "Code OTA public HTTPS URL is not configured")
    return value


def require_admin(request: Request) -> None:
    expected = os.environ.get("GC_CODE_OTA_ADMIN_TOKEN", "")
    if not expected:
        raise HTTPException(503, "Code OTA publishing is not configured")
    authorization = request.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(token, expected):
        raise HTTPException(401, "Invalid Code OTA credentials")


def _ensure_app(connection: sqlite3.Connection, app_id: str, display_name: str = "GhostChat") -> sqlite3.Row:
    if not _APP_ID_RE.fullmatch(app_id):
        raise HTTPException(400, "Invalid app id")
    now = _now()
    connection.execute(
        "INSERT OR IGNORE INTO code_ota_apps(app_id, display_name, created_at, updated_at) VALUES (?, ?, ?, ?)",
        (app_id, display_name[:100] or "GhostChat", now, now),
    )
    app = connection.execute("SELECT * FROM code_ota_apps WHERE app_id = ?", (app_id,)).fetchone()
    connection.execute(
        "INSERT OR IGNORE INTO code_ota_channels(app_id, name) VALUES (?, 'stable')", (app_id,)
    )
    return app


def _app_json(connection: sqlite3.Connection, app: sqlite3.Row) -> dict[str, Any]:
    release = connection.execute(
        "SELECT version FROM code_ota_releases WHERE app_id = ? ORDER BY updated_at DESC, id DESC LIMIT 1",
        (app["app_id"],),
    ).fetchone()
    platforms = [
        row["platform"]
        for row in connection.execute(
            "SELECT DISTINCT platform FROM code_ota_artifacts WHERE app_id = ? AND kind = 'release' AND uploaded = 1 ORDER BY platform",
            (app["app_id"],),
        ).fetchall()
    ]
    patch = connection.execute(
        "SELECT MAX(number) AS number FROM code_ota_patches WHERE app_id = ?",
        (app["app_id"],),
    ).fetchone()
    return {
        "app_id": app["app_id"],
        "display_name": app["display_name"],
        "created_at": _iso(app["created_at"]),
        "updated_at": _iso(app["updated_at"]),
        "latest_release_version": release["version"] if release else None,
        "latest_patch_number": patch["number"] if patch else None,
        "platforms": platforms,
    }


def _release_json(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "app_id": row["app_id"],
        "version": row["version"],
        "flutter_revision": row["flutter_revision"],
        "flutter_version": row["flutter_version"],
        "display_name": row["display_name"],
        "platform_statuses": json.loads(row["platform_statuses"]),
        "created_at": _iso(row["created_at"]),
        "updated_at": _iso(row["updated_at"]),
    }


def _storage_path(storage_name: str) -> Path:
    root = (_data_dir() / "artifacts").resolve()
    path = (root / storage_name).resolve()
    if path.parent != root or not re.fullmatch(r"[0-9a-f]{32}\.bin", storage_name):
        raise HTTPException(500, "Invalid artifact storage key")
    return path


def _artifact_url(request: Request, artifact_id: int) -> str:
    del request  # Host headers are not trusted for constructing downloadable URLs.
    return f"{_public_base_url()}/api/v1/code-ota/artifacts/{artifact_id}"


def _artifact_json(connection: sqlite3.Connection, row: sqlite3.Row, request: Request) -> dict[str, Any]:
    return {
        "id": row["id"],
        "release_id": row["release_id"],
        "patch_id": row["patch_id"],
        "arch": row["arch"],
        "platform": row["platform"],
        "hash": row["hash"],
        "size": row["size"],
        "url": _artifact_url(request, row["id"]),
        "podfile_lock_hash": row["podfile_lock_hash"],
        "can_sideload": bool(row["can_sideload"]),
    }


def _form_text(form: Any, key: str, *, required: bool = True) -> str | None:
    value = form.get(key)
    if value is None:
        if required:
            raise HTTPException(400, f"Missing field: {key}")
        return None
    value = str(value).strip()
    if required and not value:
        raise HTTPException(400, f"Missing field: {key}")
    return value or None


def _validate_artifact_fields(form: Any) -> tuple[str, str, str, int]:
    arch = _form_text(form, "arch") or ""
    platform = _form_text(form, "platform") or ""
    digest = (_form_text(form, "hash") or "").lower()
    try:
        size = int(_form_text(form, "size") or "")
    except ValueError:
        raise HTTPException(400, "Invalid artifact size")
    if not _ARCH_RE.fullmatch(arch) or platform not in _PLATFORMS:
        raise HTTPException(400, "Invalid artifact platform or architecture")
    if not _HASH_RE.fullmatch(digest):
        raise HTTPException(400, "Invalid artifact SHA-256")
    if not 0 < size <= _max_artifact_bytes():
        raise HTTPException(413, "Artifact size is outside the allowed range")
    return arch, platform, digest, size


def _register_artifact(
    connection: sqlite3.Connection,
    *,
    app_id: str,
    release_id: int,
    patch_id: int | None,
    kind: str,
    arch: str,
    platform: str,
    digest: str,
    size: int,
    signature: str | None,
    podfile_lock_hash: str | None,
    can_sideload: bool,
) -> tuple[sqlite3.Row, str]:
    if kind == "patch" and os.environ.get("GC_CODE_OTA_REQUIRE_SIGNATURE", "1") != "0" and not signature:
        raise HTTPException(400, "Patch signatures are required")
    token = secrets.token_urlsafe(32)
    storage_name = f"{secrets.token_hex(16)}.bin"
    try:
        cursor = connection.execute(
            """INSERT INTO code_ota_artifacts
               (app_id, release_id, patch_id, kind, arch, platform, hash, size,
                hash_signature, podfile_lock_hash, can_sideload, upload_token,
                storage_name, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                app_id,
                release_id,
                patch_id,
                kind,
                arch,
                platform,
                digest,
                size,
                signature,
                podfile_lock_hash,
                int(can_sideload),
                token,
                storage_name,
                _now(),
            ),
        )
    except sqlite3.IntegrityError as error:
        raise HTTPException(409, "An artifact already exists for this release/patch target") from error
    row = connection.execute("SELECT * FROM code_ota_artifacts WHERE id = ?", (cursor.lastrowid,)).fetchone()
    return row, token


@router.get("/api/v1/users/me")
def get_code_ota_user(_: None = Depends(require_admin)):
    return {
        "id": 1,
        "email": "ota-admin@ghostecos.local",
        "display_name": "GhostEcos OTA Admin",
        "has_active_subscription": True,
        "jwt_issuer": "https://ghostecos.duckdns.org",
    }


@router.get("/api/v1/plan")
def get_code_ota_plan(_: None = Depends(require_admin)):
    return {"level": "self_hosted"}


@router.get("/api/v1/apps")
def list_code_ota_apps(_: None = Depends(require_admin)):
    with _connect() as connection:
        configured_app_id = os.environ.get("GC_CODE_OTA_APP_ID", "ghostchat-android").strip()
        if configured_app_id:
            _ensure_app(connection, configured_app_id)
        apps = connection.execute("SELECT * FROM code_ota_apps ORDER BY created_at, app_id").fetchall()
        return {"apps": [_app_json(connection, app) for app in apps]}


@router.get("/api/v1/apps/{app_id}")
def get_code_ota_app(app_id: str, _: None = Depends(require_admin)):
    with _connect() as connection:
        app = connection.execute("SELECT * FROM code_ota_apps WHERE app_id = ?", (app_id,)).fetchone()
        if not app:
            raise HTTPException(404, "App not found")
        return _app_json(connection, app)


@router.get("/api/v1/apps/{app_id}/releases")
def list_code_ota_releases(app_id: str, _: None = Depends(require_admin)):
    with _connect() as connection:
        rows = connection.execute(
            "SELECT * FROM code_ota_releases WHERE app_id = ? ORDER BY updated_at, id", (app_id,)
        ).fetchall()
        return {"releases": [_release_json(row) for row in rows]}


@router.post("/api/v1/apps/{app_id}/releases")
async def create_code_ota_release(app_id: str, request: Request, _: None = Depends(require_admin)):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "Expected a JSON object")
    version = body.get("version")
    flutter_revision = body.get("flutter_revision")
    if not isinstance(version, str) or not _VERSION_RE.fullmatch(version):
        raise HTTPException(400, "Invalid release version")
    if not isinstance(flutter_revision, str) or not 1 <= len(flutter_revision) <= 80:
        raise HTTPException(400, "Invalid Flutter revision")
    if not _APP_ID_RE.fullmatch(app_id):
        raise HTTPException(400, "Invalid app id")
    now = _now()
    with _connect() as connection:
        _ensure_app(connection, app_id)
        try:
            cursor = connection.execute(
                """INSERT INTO code_ota_releases
                   (app_id, version, flutter_revision, flutter_version, display_name,
                    platform_statuses, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, '{}', ?, ?)""",
                (app_id, version, flutter_revision, body.get("flutter_version"), body.get("display_name"), now, now),
            )
        except sqlite3.IntegrityError as error:
            raise HTTPException(409, "Release version already exists") from error
        row = connection.execute("SELECT * FROM code_ota_releases WHERE id = ?", (cursor.lastrowid,)).fetchone()
        return {"release": _release_json(row)}


@router.patch("/api/v1/apps/{app_id}/releases/{release_id}")
async def update_code_ota_release(app_id: str, release_id: int, request: Request, _: None = Depends(require_admin)):
    body = await request.json()
    platform = body.get("platform") if isinstance(body, dict) else None
    status = body.get("status") if isinstance(body, dict) else None
    if platform not in _PLATFORMS or status not in {"draft", "active"}:
        raise HTTPException(400, "Invalid release platform or status")
    with _connect() as connection:
        row = connection.execute(
            "SELECT * FROM code_ota_releases WHERE id = ? AND app_id = ?", (release_id, app_id)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Release not found")
        statuses = json.loads(row["platform_statuses"])
        if status == "active":
            artifact = connection.execute(
                "SELECT 1 FROM code_ota_artifacts WHERE release_id = ? AND platform = ? AND kind = 'release' AND uploaded = 1 LIMIT 1",
                (release_id, platform),
            ).fetchone()
            if not artifact:
                raise HTTPException(409, "Cannot activate a release without an uploaded platform artifact")
        statuses[platform] = status
        connection.execute(
            "UPDATE code_ota_releases SET platform_statuses = ?, updated_at = ? WHERE id = ?",
            (json.dumps(statuses), _now(), release_id),
        )
        updated = connection.execute("SELECT * FROM code_ota_releases WHERE id = ?", (release_id,)).fetchone()
        return _release_json(updated)


@router.get("/api/v1/apps/{app_id}/releases/{release_id}/artifacts")
def list_code_ota_release_artifacts(
    app_id: str,
    release_id: int,
    request: Request,
    arch: str | None = None,
    platform: str | None = None,
    _: None = Depends(require_admin),
):
    clauses = ["app_id = ?", "release_id = ?", "kind = 'release'", "uploaded = 1"]
    values: list[Any] = [app_id, release_id]
    if arch:
        clauses.append("arch = ?")
        values.append(arch)
    if platform:
        clauses.append("platform = ?")
        values.append(platform)
    with _connect() as connection:
        rows = connection.execute(
            f"SELECT * FROM code_ota_artifacts WHERE {' AND '.join(clauses)} ORDER BY platform, arch", values
        ).fetchall()
        return {"artifacts": [_artifact_json(connection, row, request) for row in rows]}


@router.get("/api/v1/apps/{app_id}/releases/{release_id}/patches")
def list_code_ota_release_patches(
    app_id: str, release_id: int, _: None = Depends(require_admin)
):
    with _connect() as connection:
        release = connection.execute(
            "SELECT 1 FROM code_ota_releases WHERE id = ? AND app_id = ?",
            (release_id, app_id),
        ).fetchone()
        if not release:
            raise HTTPException(404, "Release not found")
        patches = connection.execute(
            "SELECT * FROM code_ota_patches WHERE release_id = ? ORDER BY number",
            (release_id,),
        ).fetchall()
        result = []
        for patch in patches:
            artifacts = connection.execute(
                """SELECT * FROM code_ota_artifacts
                   WHERE patch_id = ? AND uploaded = 1 ORDER BY platform, arch""",
                (patch["id"],),
            ).fetchall()
            result.append(
                {
                    "id": patch["id"],
                    "number": patch["number"],
                    "channel": patch["channel"],
                    "artifacts": [
                        {
                            "id": artifact["id"],
                            "patch_id": patch["id"],
                            "arch": artifact["arch"],
                            "platform": artifact["platform"],
                            "hash": artifact["hash"],
                            "size": artifact["size"],
                            "created_at": _iso(artifact["created_at"]),
                        }
                        for artifact in artifacts
                    ],
                    "is_rolled_back": bool(patch["is_rolled_back"]),
                    "notes": None,
                }
            )
        return {"patches": result}


async def _create_artifact(
    request: Request,
    *,
    app_id: str,
    release_id: int,
    patch_id: int | None,
    kind: str,
    can_sideload: bool,
) -> dict[str, Any]:
    form = await request.form()
    arch, platform, digest, size = _validate_artifact_fields(form)
    signature = _form_text(form, "hash_signature", required=False)
    podfile_lock_hash = _form_text(form, "podfile_lock_hash", required=False)
    with _connect() as connection:
        release = connection.execute(
            "SELECT platform_statuses FROM code_ota_releases WHERE id = ? AND app_id = ?",
            (release_id, app_id),
        ).fetchone()
        if not release:
            raise HTTPException(404, "Release not found")
        if patch_id is not None:
            patch = connection.execute(
                "SELECT 1 FROM code_ota_patches WHERE id = ? AND app_id = ? AND release_id = ?",
                (patch_id, app_id, release_id),
            ).fetchone()
            if not patch:
                raise HTTPException(404, "Patch not found")
            statuses = json.loads(release["platform_statuses"])
            if statuses.get(platform) != "active":
                raise HTTPException(409, "Cannot add a patch for an inactive release platform")
            base_artifact = connection.execute(
                """SELECT 1 FROM code_ota_artifacts
                   WHERE release_id = ? AND kind = 'release' AND platform = ? AND arch = ?
                     AND uploaded = 1 LIMIT 1""",
                (release_id, platform, arch),
            ).fetchone()
            if not base_artifact:
                raise HTTPException(409, "Patch target does not exist in the base release")
        row, token = _register_artifact(
            connection,
            app_id=app_id,
            release_id=release_id,
            patch_id=patch_id,
            kind=kind,
            arch=arch,
            platform=platform,
            digest=digest,
            size=size,
            signature=signature,
            podfile_lock_hash=podfile_lock_hash,
            can_sideload=can_sideload,
        )
        return {
            "id": row["id"],
            "release_id": release_id,
            "patch_id": patch_id,
            "arch": arch,
            "platform": platform,
            "hash": digest,
            "size": size,
            "url": f"{_public_base_url()}/api/v1/code-ota/uploads/{token}",
            "upload_method": "multipart",
        }


@router.post("/api/v1/apps/{app_id}/releases/{release_id}/artifacts")
async def create_code_ota_release_artifact(
    app_id: str, release_id: int, request: Request, _: None = Depends(require_admin)
):
    form = await request.form()
    can_sideload = str(form.get("can_sideload", "false")).lower() in {"true", "1"}
    return await _create_artifact(
        request, app_id=app_id, release_id=release_id, patch_id=None,
        kind="release", can_sideload=can_sideload,
    )


@router.post("/api/v1/apps/{app_id}/patches")
async def create_code_ota_patch(app_id: str, request: Request, _: None = Depends(require_admin)):
    body = await request.json()
    release_id = body.get("release_id") if isinstance(body, dict) else None
    metadata = body.get("metadata", {}) if isinstance(body, dict) else None
    if not isinstance(release_id, int) or isinstance(release_id, bool) or not isinstance(metadata, dict):
        raise HTTPException(400, "Invalid patch request")
    with _connect() as connection:
        release = connection.execute(
            "SELECT * FROM code_ota_releases WHERE id = ? AND app_id = ?", (release_id, app_id)
        ).fetchone()
        if not release:
            raise HTTPException(404, "Release not found")
        if not any(value == "active" for value in json.loads(release["platform_statuses"]).values()):
            raise HTTPException(409, "Cannot patch an inactive release")
        number = connection.execute(
            "SELECT COALESCE(MAX(number), 0) + 1 AS number FROM code_ota_patches WHERE release_id = ?",
            (release_id,),
        ).fetchone()["number"]
        now = _now()
        cursor = connection.execute(
            """INSERT INTO code_ota_patches
               (app_id, release_id, number, metadata, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (app_id, release_id, number, json.dumps(metadata, separators=(",", ":")), now, now),
        )
        return {"id": cursor.lastrowid, "number": number, "notes": None}


@router.post("/api/v1/apps/{app_id}/patches/{patch_id}/artifacts")
async def create_code_ota_patch_artifact(
    app_id: str, patch_id: int, request: Request, _: None = Depends(require_admin)
):
    with _connect() as connection:
        patch = connection.execute(
            "SELECT release_id FROM code_ota_patches WHERE id = ? AND app_id = ?", (patch_id, app_id)
        ).fetchone()
    if not patch:
        raise HTTPException(404, "Patch not found")
    return await _create_artifact(
        request, app_id=app_id, release_id=patch["release_id"], patch_id=patch_id,
        kind="patch", can_sideload=False,
    )


def _upload_url(upload_token: str) -> str:
    return f"{_public_base_url()}/api/v1/code-ota/uploads/{upload_token}"


def _valid_asset_path(value: Any) -> bool:
    if not isinstance(value, str) or not _ASSET_PATH_RE.fullmatch(value):
        return False
    return all(part not in {"", ".", ".."} for part in value.split("/"))


def _sign_asset_manifest(payload: bytes) -> str:
    key_path = os.environ.get("GC_CODE_OTA_ASSET_PRIVATE_KEY", "").strip()
    if not key_path:
        raise HTTPException(503, "Asset OTA signing key is not configured")
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding, rsa

        private_key = serialization.load_pem_private_key(
            Path(key_path).read_bytes(), password=None
        )
        if not isinstance(private_key, rsa.RSAPrivateKey):
            raise ValueError("configured key is not RSA")
        return base64.b64encode(
            private_key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
        ).decode("ascii")
    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(503, "Asset OTA signing key is invalid") from error


@router.post("/api/v1/code-ota/toolchain/{engine_revision}/{filename}")
async def register_code_ota_toolchain_artifact(
    engine_revision: str,
    filename: str,
    request: Request,
    _: None = Depends(require_admin),
):
    if not _ENGINE_REVISION_RE.fullmatch(engine_revision) or filename not in _TOOLCHAIN_FILES:
        raise HTTPException(400, "Invalid toolchain artifact target")
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "Invalid toolchain metadata")
    digest = body.get("hash")
    size = body.get("size")
    if not isinstance(digest, str) or not _HASH_RE.fullmatch(digest):
        raise HTTPException(400, "Invalid toolchain SHA-256")
    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= _max_artifact_bytes():
        raise HTTPException(413, "Toolchain artifact size is outside the allowed range")
    with _connect() as connection:
        existing = connection.execute(
            """SELECT hash, size, upload_token, uploaded FROM code_ota_toolchain_artifacts
               WHERE engine_revision = ? AND filename = ?""",
            (engine_revision, filename),
        ).fetchone()
    if existing:
        if existing["hash"] != digest or existing["size"] != size:
            raise HTTPException(409, "Toolchain target already exists with different contents")
        return {
            "upload_url": _upload_url(existing["upload_token"]),
            "upload_token": existing["upload_token"],
            "uploaded": bool(existing["uploaded"]),
        }
    token = secrets.token_urlsafe(32)
    storage_name = f"{secrets.token_hex(16)}.bin"
    try:
        with _connect() as connection:
            connection.execute(
                """INSERT INTO code_ota_toolchain_artifacts
                   (engine_revision, filename, hash, size, upload_token, storage_name, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (engine_revision, filename, digest, size, token, storage_name, _now()),
            )
    except sqlite3.IntegrityError as error:
        raise HTTPException(409, "Toolchain artifact is already registered") from error
    return {"upload_url": _upload_url(token), "upload_token": token, "uploaded": False}


@router.get("/api/v1/code-ota/toolchain/{engine_revision}/{filename}")
def download_code_ota_toolchain_artifact(engine_revision: str, filename: str):
    if not _ENGINE_REVISION_RE.fullmatch(engine_revision) or filename not in _TOOLCHAIN_FILES:
        raise HTTPException(404, "Toolchain artifact not found")
    with _connect() as connection:
        row = connection.execute(
            """SELECT * FROM code_ota_toolchain_artifacts
               WHERE engine_revision = ? AND filename = ? AND uploaded = 1""",
            (engine_revision, filename),
        ).fetchone()
    if not row:
        raise HTTPException(404, "Toolchain artifact not found")
    path = _storage_path(row["storage_name"])
    if not path.is_file():
        raise HTTPException(404, "Toolchain artifact not found")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=filename,
        headers={
            "Cache-Control": "public, max-age=31536000, immutable",
            "X-Content-Type-Options": "nosniff",
            "X-Checksum-Sha256": row["hash"],
        },
    )


@router.post("/api/v1/apps/{app_id}/asset-releases")
async def create_code_ota_asset_release(
    app_id: str, request: Request, _: None = Depends(require_admin)
):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "Invalid asset release metadata")
    version = body.get("version")
    assets = body.get("assets")
    if not isinstance(version, str) or not _VERSION_RE.fullmatch(version):
        raise HTTPException(400, "Invalid asset release version")
    if not isinstance(assets, list) or len(assets) > 5000:
        raise HTTPException(400, "Assets must be a list containing at most 5000 entries")

    validated: list[tuple[str, str, int]] = []
    paths: set[str] = set()
    total_size = 0
    for item in assets:
        if not isinstance(item, dict):
            raise HTTPException(400, "Invalid asset entry")
        asset_path, digest, size = item.get("path"), item.get("hash"), item.get("size")
        if not _valid_asset_path(asset_path) or asset_path in paths:
            raise HTTPException(400, "Invalid or duplicate asset path")
        if not isinstance(digest, str) or not _HASH_RE.fullmatch(digest):
            raise HTTPException(400, "Invalid asset SHA-256")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= _max_artifact_bytes():
            raise HTTPException(413, "Asset size is outside the allowed range")
        paths.add(asset_path)
        total_size += size
        if total_size > 2 * 1024 * 1024 * 1024:
            raise HTTPException(413, "Asset release is too large")
        validated.append((asset_path, digest, size))

    with _connect() as connection:
        _ensure_app(connection, app_id)
        existing = connection.execute(
            "SELECT id, manifest_json FROM code_ota_asset_releases WHERE app_id = ? AND version = ?",
            (app_id, version),
        ).fetchone()
        if existing:
            if existing["manifest_json"] is not None:
                raise HTTPException(409, "Asset release version has already been activated")
            release_id = existing["id"]
            existing_files = connection.execute(
                "SELECT asset_path, hash, size FROM code_ota_asset_files WHERE release_id = ?",
                (release_id,),
            ).fetchall()
            current = {
                row["asset_path"]: (row["hash"], row["size"])
                for row in existing_files
            }
            requested = {path: (digest, size) for path, digest, size in validated}
            if current != requested:
                raise HTTPException(409, "Asset release version exists with different contents")
            upload_assets = [
                {
                    "path": row["asset_path"],
                    "upload_url": _upload_url(row["upload_token"]),
                    "upload_token": row["upload_token"],
                    "uploaded": bool(row["uploaded"]),
                }
                for row in connection.execute(
                    "SELECT asset_path, upload_token, uploaded FROM code_ota_asset_files WHERE release_id = ? ORDER BY asset_path",
                    (release_id,),
                ).fetchall()
            ]
        else:
            cursor = connection.execute(
                "INSERT INTO code_ota_asset_releases(app_id, version, created_at) VALUES (?, ?, ?)",
                (app_id, version, _now()),
            )
            release_id = cursor.lastrowid
            upload_assets = []
            for asset_path, digest, size in validated:
                token = secrets.token_urlsafe(32)
                connection.execute(
                    """INSERT INTO code_ota_asset_files
                       (release_id, asset_path, hash, size, upload_token, storage_name, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (release_id, asset_path, digest, size, token, f"{secrets.token_hex(16)}.bin", _now()),
                )
                upload_assets.append(
                    {
                        "path": asset_path,
                        "upload_url": _upload_url(token),
                        "upload_token": token,
                        "uploaded": False,
                    }
                )
    return {"id": release_id, "version": version, "assets": upload_assets}


@router.post("/api/v1/apps/{app_id}/asset-releases/{release_id}/activate")
def activate_code_ota_asset_release(
    app_id: str, release_id: int, _: None = Depends(require_admin)
):
    with _connect() as connection:
        release = connection.execute(
            "SELECT * FROM code_ota_asset_releases WHERE id = ? AND app_id = ?",
            (release_id, app_id),
        ).fetchone()
        if not release:
            raise HTTPException(404, "Asset release not found")
        rows = connection.execute(
            "SELECT * FROM code_ota_asset_files WHERE release_id = ? ORDER BY asset_path",
            (release_id,),
        ).fetchall()
        if any(not row["uploaded"] for row in rows):
            raise HTTPException(409, "Every asset must be uploaded before activation")
        public_base = _public_base_url()
        manifest = {
            "protocol": 1,
            "app_id": app_id,
            "release_id": release_id,
            "version": release["version"],
            "created_at": release["created_at"],
            "assets": [
                {
                    "path": row["asset_path"],
                    "hash": row["hash"],
                    "size": row["size"],
                    "url": f"{public_base}/api/v1/code-ota/assets/{row['id']}",
                }
                for row in rows
            ],
        }
        manifest_json = json.dumps(
            manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        signature = _sign_asset_manifest(manifest_json.encode("utf-8"))
        connection.execute(
            "UPDATE code_ota_asset_releases SET active = 0 WHERE app_id = ?", (app_id,)
        )
        connection.execute(
            """UPDATE code_ota_asset_releases SET active = 1, manifest_json = ?, signature = ?
               WHERE id = ?""",
            (manifest_json, signature, release_id),
        )
    return {"id": release_id, "active": True}


@router.post("/api/v1/assets/check")
async def check_code_ota_assets(request: Request):
    raw = await request.body()
    if len(raw) > 1024 * 1024:
        raise HTTPException(413, "Asset check request is too large")
    try:
        body = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise HTTPException(400, "Invalid asset check request")
    if not isinstance(body, dict):
        raise HTTPException(400, "Invalid asset check request")
    app_id = body.get("app_id")
    installed_release_id = body.get("installed_release_id")
    installed_hashes = body.get("installed_hashes", [])
    if not isinstance(app_id, str) or not _APP_ID_RE.fullmatch(app_id):
        raise HTTPException(400, "Invalid app id")
    if installed_release_id is not None and (
        not isinstance(installed_release_id, int) or isinstance(installed_release_id, bool)
    ):
        raise HTTPException(400, "Invalid installed release id")
    if not isinstance(installed_hashes, list) or len(installed_hashes) > 5000:
        raise HTTPException(400, "Invalid installed asset list")
    if any(not isinstance(value, str) or not _HASH_RE.fullmatch(value) for value in installed_hashes):
        raise HTTPException(400, "Invalid installed asset hash")

    with _connect() as connection:
        release = connection.execute(
            """SELECT id, manifest_json, signature FROM code_ota_asset_releases
               WHERE app_id = ? AND active = 1""",
            (app_id,),
        ).fetchone()
        if not release:
            return {"update_available": False, "release_id": None}
        manifest = json.loads(release["manifest_json"])

    installed = set(installed_hashes)
    missing = [asset for asset in manifest["assets"] if asset["hash"] not in installed]
    if release["id"] == installed_release_id and not missing:
        return {"update_available": False, "release_id": release["id"]}
    return {
        "update_available": True,
        "release_id": release["id"],
        "manifest_json": release["manifest_json"],
        "signature": release["signature"],
        "files": missing,
    }


@router.get("/api/v1/code-ota/assets/{asset_file_id}")
def download_code_ota_asset(asset_file_id: int):
    with _connect() as connection:
        row = connection.execute(
            """SELECT f.* FROM code_ota_asset_files f
               JOIN code_ota_asset_releases r ON r.id = f.release_id
               WHERE f.id = ? AND f.uploaded = 1 AND r.manifest_json IS NOT NULL""",
            (asset_file_id,),
        ).fetchone()
    if not row:
        raise HTTPException(404, "Asset not found")
    path = _storage_path(row["storage_name"])
    if not path.is_file():
        raise HTTPException(404, "Asset not found")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=Path(row["asset_path"]).name,
        headers={
            "Cache-Control": "public, max-age=31536000, immutable",
            "X-Content-Type-Options": "nosniff",
            "X-Checksum-Sha256": row["hash"],
        },
    )


@router.post("/api/v1/code-ota/uploads/{upload_token}", status_code=204)
async def upload_code_ota_artifact(
    upload_token: str, request: Request, _: None = Depends(require_admin)
):
    form = await request.form()
    upload = form.get("file")
    if not isinstance(upload, UploadFile):
        raise HTTPException(400, "Missing artifact file")
    allow_code_artifacts = dart_code_ota_enabled()
    table = "code_ota_artifacts" if allow_code_artifacts else "code_ota_asset_files"
    with _connect() as connection:
        if allow_code_artifacts:
            row = connection.execute(
                "SELECT * FROM code_ota_artifacts WHERE upload_token = ?", (upload_token,)
            ).fetchone()
            if not row:
                table = "code_ota_asset_files"
                row = connection.execute(
                    "SELECT * FROM code_ota_asset_files WHERE upload_token = ?", (upload_token,)
                ).fetchone()
            if not row:
                table = "code_ota_toolchain_artifacts"
                row = connection.execute(
                    "SELECT * FROM code_ota_toolchain_artifacts WHERE upload_token = ?", (upload_token,)
                ).fetchone()
        else:
            row = connection.execute(
                "SELECT * FROM code_ota_asset_files WHERE upload_token = ?", (upload_token,)
            ).fetchone()
    if not row:
        raise HTTPException(404, "Upload session not found")

    destination = _storage_path(row["storage_name"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{secrets.token_hex(8)}.tmp")
    digest = hashlib.sha256()
    total = 0
    try:
        with temporary.open("wb") as output:
            while chunk := await upload.read(1024 * 1024):
                total += len(chunk)
                if total > _max_artifact_bytes() or total > row["size"]:
                    raise HTTPException(413, "Artifact exceeds its declared size")
                digest.update(chunk)
                output.write(chunk)
        if total != row["size"] or not hmac.compare_digest(digest.hexdigest(), row["hash"]):
            raise HTTPException(422, "Artifact size or SHA-256 does not match metadata")
        os.replace(temporary, destination)
        with _connect() as connection:
            connection.execute(
                f"UPDATE {table} SET uploaded = 1 WHERE id = ?", (row["id"],)
            )
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    finally:
        await upload.close()
    return Response(status_code=204)


@router.get("/api/v1/code-ota/artifacts/{artifact_id}")
def download_code_ota_artifact(artifact_id: int):
    with _connect() as connection:
        row = connection.execute(
            "SELECT * FROM code_ota_artifacts WHERE id = ? AND uploaded = 1", (artifact_id,)
        ).fetchone()
    if not row:
        raise HTTPException(404, "Artifact not found")
    path = _storage_path(row["storage_name"])
    if not path.is_file():
        raise HTTPException(404, "Artifact not found")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename=f"ghostchat-ota-{artifact_id}.bin",
        headers={
            "Cache-Control": "public, max-age=31536000, immutable",
            "X-Content-Type-Options": "nosniff",
            "X-Checksum-Sha256": row["hash"],
        },
    )


@router.get("/api/v1/apps/{app_id}/channels")
def list_code_ota_channels(app_id: str, _: None = Depends(require_admin)):
    with _connect() as connection:
        app = connection.execute("SELECT 1 FROM code_ota_apps WHERE app_id = ?", (app_id,)).fetchone()
        if not app:
            raise HTTPException(404, "App not found")
        rows = connection.execute(
            "SELECT * FROM code_ota_channels WHERE app_id = ? ORDER BY id", (app_id,)
        ).fetchall()
        return [{"id": row["id"], "app_id": app_id, "name": row["name"]} for row in rows]


@router.post("/api/v1/apps/{app_id}/channels")
async def create_code_ota_channel(app_id: str, request: Request, _: None = Depends(require_admin)):
    body = await request.json()
    name = body.get("channel") if isinstance(body, dict) else None
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
        raise HTTPException(400, "Invalid channel name")
    with _connect() as connection:
        _ensure_app(connection, app_id)
        try:
            cursor = connection.execute(
                "INSERT INTO code_ota_channels(app_id, name) VALUES (?, ?)", (app_id, name)
            )
        except sqlite3.IntegrityError:
            row = connection.execute(
                "SELECT id FROM code_ota_channels WHERE app_id = ? AND name = ?", (app_id, name)
            ).fetchone()
            return {"id": row["id"], "app_id": app_id, "name": name}
        return {"id": cursor.lastrowid, "app_id": app_id, "name": name}


@router.post("/api/v1/apps/{app_id}/patches/promote")
async def promote_code_ota_patch(app_id: str, request: Request, _: None = Depends(require_admin)):
    body = await request.json()
    patch_id = body.get("patch_id") if isinstance(body, dict) else None
    channel_id = body.get("channel_id") if isinstance(body, dict) else None
    if not isinstance(patch_id, int) or not isinstance(channel_id, int):
        raise HTTPException(400, "Invalid promotion request")
    with _connect() as connection:
        channel = connection.execute(
            "SELECT name FROM code_ota_channels WHERE id = ? AND app_id = ?", (channel_id, app_id)
        ).fetchone()
        patch = connection.execute(
            "SELECT * FROM code_ota_patches WHERE id = ? AND app_id = ?", (patch_id, app_id)
        ).fetchone()
        if not channel or not patch:
            raise HTTPException(404, "Channel or patch not found")
        release = connection.execute(
            "SELECT platform_statuses FROM code_ota_releases WHERE id = ?", (patch["release_id"],)
        ).fetchone()
        active_platforms = {
            platform
            for platform, status in json.loads(release["platform_statuses"]).items()
            if status == "active"
        } if release else set()
        if not active_platforms:
            raise HTTPException(409, "Cannot promote a patch for an inactive release")
        base_targets = {
            (row["platform"], row["arch"])
            for row in connection.execute(
                """SELECT platform, arch FROM code_ota_artifacts
                   WHERE release_id = ? AND kind = 'release' AND uploaded = 1""",
                (patch["release_id"],),
            ).fetchall()
            if row["platform"] in active_platforms
        }
        patch_targets = {
            (row["platform"], row["arch"])
            for row in connection.execute(
                """SELECT platform, arch FROM code_ota_artifacts
                   WHERE patch_id = ? AND uploaded = 1""",
                (patch_id,),
            ).fetchall()
        }
        missing_targets = base_targets - patch_targets
        if not base_targets or missing_targets:
            raise HTTPException(
                409,
                "Patch artifacts must cover every architecture of every active release platform",
            )
        connection.execute(
            "UPDATE code_ota_patches SET channel = ?, is_rolled_back = 0, updated_at = ? WHERE id = ?",
            (channel["name"], _now(), patch_id),
        )
    return Response(status_code=204)


@router.post("/api/v1/apps/{app_id}/releases/{release_id}/patches/{patch_id}/rollback")
def rollback_code_ota_patch(
    app_id: str, release_id: int, patch_id: int, _: None = Depends(require_admin)
):
    with _connect() as connection:
        row = connection.execute(
            "SELECT is_rolled_back FROM code_ota_patches WHERE id = ? AND app_id = ? AND release_id = ?",
            (patch_id, app_id, release_id),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Patch not found")
        if row["is_rolled_back"]:
            return Response(status_code=304)
        connection.execute(
            "UPDATE code_ota_patches SET is_rolled_back = 1, updated_at = ? WHERE id = ?",
            (_now(), patch_id),
        )
    return Response(status_code=204)


@router.post("/api/v1/apps/{app_id}/releases/{release_id}/patches/{patch_id}/rollforward")
def rollforward_code_ota_patch(
    app_id: str, release_id: int, patch_id: int, _: None = Depends(require_admin)
):
    with _connect() as connection:
        row = connection.execute(
            "SELECT is_rolled_back FROM code_ota_patches WHERE id = ? AND app_id = ? AND release_id = ?",
            (patch_id, app_id, release_id),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Patch not found")
        if not row["is_rolled_back"]:
            return Response(status_code=304)
        connection.execute(
            "UPDATE code_ota_patches SET is_rolled_back = 0, updated_at = ? WHERE id = ?",
            (_now(), patch_id),
        )
    return Response(status_code=204)


@router.post("/api/v1/patches/check")
def check_code_ota_patch(body: PatchCheckBody, request: Request):
    if (
        not _APP_ID_RE.fullmatch(body.app_id)
        or not _VERSION_RE.fullmatch(body.release_version)
        or not _ARCH_RE.fullmatch(body.arch)
        or body.platform not in _PLATFORMS
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", body.channel)
    ):
        raise HTTPException(400, "Invalid patch check parameters")
    current = body.current_patch_number or body.patch_number
    with _connect() as connection:
        release = connection.execute(
            "SELECT id, platform_statuses FROM code_ota_releases WHERE app_id = ? AND version = ?",
            (body.app_id, body.release_version),
        ).fetchone()
        if not release:
            return {"patch_available": False, "patch": None, "rolled_back_patch_numbers": []}
        rolled_back = [
            row["number"]
            for row in connection.execute(
                "SELECT number FROM code_ota_patches WHERE release_id = ? AND is_rolled_back = 1 ORDER BY number",
                (release["id"],),
            ).fetchall()
        ]
        platform_statuses = json.loads(release["platform_statuses"])
        patch = None
        if platform_statuses.get(body.platform) == "active":
            patch = connection.execute(
                """SELECT p.number, a.id AS artifact_id, a.hash, a.hash_signature
                   FROM code_ota_patches p
                   JOIN code_ota_artifacts a ON a.patch_id = p.id
                   WHERE p.release_id = ? AND p.channel = ? AND p.is_rolled_back = 0
                     AND a.platform = ? AND a.arch = ? AND a.uploaded = 1
                   ORDER BY p.number DESC LIMIT 1""",
                (release["id"], body.channel, body.platform, body.arch),
            ).fetchone()

    patch_payload = None
    if patch and patch["number"] != current:
        patch_payload = {
            "number": patch["number"],
            "hash": patch["hash"],
            "download_url": _artifact_url(request, patch["artifact_id"]),
            "hash_signature": patch["hash_signature"],
        }
    return {
        "patch_available": patch_payload is not None,
        "patch": patch_payload,
        "rolled_back_patch_numbers": rolled_back,
    }


@router.post("/api/v1/patches/events", status_code=204)
async def accept_code_ota_event(request: Request):
    # Upstream event payloads include a per-install random ID. The service does
    # not need it for update delivery, so consume and discard the body.
    body = await request.body()
    if len(body) > 16 * 1024:
        raise HTTPException(413, "Event payload is too large")
    return Response(status_code=204)
