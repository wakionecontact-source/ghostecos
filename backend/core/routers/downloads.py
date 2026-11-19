from __future__ import annotations

import os
import secrets
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

import bot_check
import config


router = APIRouter(prefix="/download", tags=["download"])

_VERSION_FILES = {
    "1.2.1": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.2.1ob.apk",
        "filename": "GhostChat_V1.2.1ob.apk",
        "title": 'Открытая бета',
        "notes": 'Звонки, группы и каналы, боты (до 10 активных ботов на пользователя), баннеры и музыка в профилях, контакты, улучшения E2EE V2 и стабильности.',
    },
    "1.1.27": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.1.27ob.apk",
        "filename": "GhostChat_V1.1.27ob.apk",
        "title": "Открытая бета",
        "notes": "Исправлена работа ключей шифрования V2, добавлен точный таймер сообщений, улучшены регистрация и шапка чата.",
    },
    "1.1.26": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.1.26ob.apk",
        "filename": "GhostChat_V1.1.26ob.apk",
        "title": "Открытая бета",
        "notes": "Исправлены проблемы с шифрованием, добавлен видеоплеер в чат и просмотр сообщений в реальном времени.",
    },
    "1.1.25": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.1.25ob.apk",
        "filename": "GhostChat_V1.1.25ob.apk",
        "title": "Открытая бета",
        "notes": "Сначала в текущем GhostChat сохраните ключ на сервере через Настройки → Ключи шифрования → Зашифровать ключ на сервере. Только после этого скачивайте v1.1.25.",
    },
    "1.1.24": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.1.24ob.apk",
        "filename": "GhostChat_V1.1.24ob.apk",
        "title": "Открытая бета",
        "notes": "Обновление GhostChat с исправлениями чата, медиа и переключения аккаунтов.",
    },
    "1.1.23": {
        "path": "/opt/ghostchat/apk/GhostChat_V1.1.23ob.apk",
        "filename": "GhostChat_V1.1.23ob.apk",
        "title": "Открытая бета",
        "notes": "Первая публичная версия открытой беты GhostChat.",
    },
}

_GATE_TTL = 20 * 60
_TICKET_TTL = 5 * 60
_HIGH_LOAD_ACTIVE = max(1, min(int(os.getenv("GC_DOWNLOAD_HIGH_LOAD_ACTIVE", "4")), 1000))
try:
    _HIGH_LOAD_RATIO = max(0.5, min(float(os.getenv("GC_DOWNLOAD_HIGH_LOAD_RATIO", "1.25")), 10.0))
except (TypeError, ValueError):
    _HIGH_LOAD_RATIO = 1.25

_state_lock = threading.Lock()
_gates: dict[str, dict] = {}
_tickets: dict[str, dict] = {}
_active_streams = 0


class PrepareBody(BaseModel):
    version: str = Field(min_length=1, max_length=32)


class ClaimBody(BaseModel):
    gate_id: str = Field(min_length=1, max_length=128)
    version: str = Field(min_length=1, max_length=32)
    bot_token: Optional[str] = Field(default=None, max_length=2048)


class UpdateBody(BaseModel):
    version: str = Field(min_length=1, max_length=32)


def _client_ip(request: Request) -> str:
    return (
        request.headers.get("x-real-ip")
        or (request.client.host if request.client else "unknown")
    )[:128]


def _release_at() -> datetime:
    try:
        value = datetime.fromisoformat(config.BETA_RELEASE_AT)
        return value.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return datetime.max.replace(tzinfo=timezone.utc)


def _release_open() -> bool:
    return datetime.now(timezone.utc) >= _release_at()


def _cleanup_locked(now: float) -> None:
    for store in (_gates, _tickets):
        for key, item in list(store.items()):
            if item["expires_at"] <= now:
                store.pop(key, None)
    while len(_gates) > 20_000:
        _gates.pop(next(iter(_gates)))
    while len(_tickets) > 20_000:
        _tickets.pop(next(iter(_tickets)))


def _high_load() -> bool:
    forced = os.getenv("GC_DOWNLOAD_FORCE_HIGH_LOAD", "").strip().lower()
    if forced in {"1", "true", "yes", "on"}:
        return True
    with _state_lock:
        active = _active_streams
    if active >= _HIGH_LOAD_ACTIVE:
        return True
    try:
        load = os.getloadavg()[0]
        cpus = max(1, os.cpu_count() or 1)
        return load / cpus >= _HIGH_LOAD_RATIO
    except (AttributeError, OSError):
        return False


def _version_item(version: str) -> dict:
    item = _VERSION_FILES.get(version)
    if not item or not Path(item["path"]).is_file():
        raise HTTPException(404, "Версия APK не найдена")
    return item


@router.get("/catalog")
def catalog():
    versions = []
    for version, item in _VERSION_FILES.items():
        if not Path(item["path"]).is_file():
            continue
        versions.append({
            "version": version,
            "filename": item["filename"],
            "title": item["title"],
            "notes": item["notes"],
            "is_latest": version == config.LATEST_VERSION,
            "size": Path(item["path"]).stat().st_size,
        })
    return {
        "latest": config.LATEST_VERSION,
        "release_at": _release_at().isoformat(),
        "available": _release_open(),
        "versions": versions,
    }


@router.post("/prepare")
def prepare(body: PrepareBody, request: Request):
    item = _version_item(body.version)
    release_at = _release_at()
    if datetime.now(timezone.utc) < release_at:
        return {
            "available": False,
            "release_at": release_at.isoformat(),
            "version": body.version,
        }

    # Каждое скачивание проходит CAPTCHA после десятисекундной подготовки.
    captcha_required = True
    wait_seconds = 10
    gate_id = secrets.token_urlsafe(24)
    now = time.monotonic()
    with _state_lock:
        _cleanup_locked(now)
        _gates[gate_id] = {
            "version": body.version,
            "ip": _client_ip(request),
            "created_at": now,
            "wait_seconds": wait_seconds,
            "captcha_required": captcha_required,
            "expires_at": now + _GATE_TTL,
        }
    return {
        "available": True,
        "gate_id": gate_id,
        "version": body.version,
        "wait_seconds": wait_seconds,
        "captcha_required": captcha_required,
        "captcha_purpose": "download" if captcha_required else None,
    }


@router.post("/claim")
def claim(body: ClaimBody, request: Request):
    now = time.monotonic()
    ip = _client_ip(request)
    with _state_lock:
        _cleanup_locked(now)
        gate = _gates.get(body.gate_id)
        if not gate:
            raise HTTPException(410, "Сессия скачивания истекла")
        if gate["version"] != body.version or gate["ip"] != ip:
            raise HTTPException(403, "Недействительная сессия скачивания")
        remaining = gate["wait_seconds"] - (now - gate["created_at"])
        if remaining > 0:
            raise HTTPException(
                425,
                detail={
                    "code": "download_wait",
                    "remaining": round(remaining, 1),
                },
            )
        captcha_required = gate["captcha_required"]

    if captcha_required:
        token = (body.bot_token or request.headers.get("x-ghost-bot-token", "")).strip()
        bot_check.consume_bot_token(token, "download")

    item = _version_item(body.version)
    with _state_lock:
        _cleanup_locked(time.monotonic())
        gate = _gates.pop(body.gate_id, None)
        if not gate:
            raise HTTPException(410, "Сессия скачивания уже использована")
        ticket = secrets.token_urlsafe(26)
        _tickets[ticket] = {
            "version": body.version,
            "ip": ip,
            "path": item["path"],
            "filename": item["filename"],
            "expires_at": time.monotonic() + _TICKET_TTL,
        }
    return {
        "download_url": "/api/download/file/" + ticket,
        "expires_in": _TICKET_TTL,
    }


@router.post("/update", include_in_schema=False)
def update(body: UpdateBody, request: Request):
    """Прямая раздача обновления в приложении: CAPTCHA, затем APK без ожиданий."""
    if body.version != config.LATEST_VERSION:
        raise HTTPException(409, "Доступна другая версия обновления")
    item = _version_item(body.version)
    if not _release_open():
        raise HTTPException(410, "Обновление ещё не опубликовано")
    token = request.headers.get("x-ghost-bot-token", "").strip()
    bot_check.consume_bot_token(token, "download")
    return FileResponse(
        item["path"],
        media_type="application/vnd.android.package-archive",
        filename=item["filename"],
        headers={"Cache-Control": "no-store"},
    )


def _release_stream() -> None:
    global _active_streams
    with _state_lock:
        _active_streams = max(0, _active_streams - 1)


@router.get("/file/{ticket}", include_in_schema=False)
def file(ticket: str, request: Request):
    global _active_streams
    ip = _client_ip(request)
    with _state_lock:
        _cleanup_locked(time.monotonic())
        item = _tickets.get(ticket)
        if not item:
            raise HTTPException(404, "Ссылка на скачивание истекла")
        if item["ip"] != ip:
            raise HTTPException(403, "Ссылка на скачивание привязана к другому клиенту")
        _tickets.pop(ticket, None)
        _active_streams += 1
    return FileResponse(
        item["path"],
        media_type="application/vnd.android.package-archive",
        filename=item["filename"],
        headers={"Cache-Control": "no-store"},
        background=BackgroundTask(_release_stream),
    )
