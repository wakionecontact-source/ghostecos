"""HMAC-аутентификация внутренних вызовов через loopback."""
from __future__ import annotations

import hashlib
import hmac
import os
import re
import threading
import time
from fastapi import HTTPException, Request

_SERVICE_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
_NONCE_RE = re.compile(r"^[A-Fa-f0-9]{32,128}$")
_MAX_BODY_BYTES = 64 * 1024
_MAX_CLOCK_SKEW_SECONDS = 60
_nonce_lock = threading.Lock()
_seen_nonces: dict[tuple[str, str], int] = {}


def _secret_for(service: str) -> bytes | None:
    env_name = "GE_INTERNAL_KEY_" + re.sub(r"[^A-Z0-9]", "_", service.upper())
    value = os.getenv(env_name, "")
    if len(value) < 32:
        return None
    return value.encode("utf-8")


def _claim_nonce(service: str, nonce: str, now: int) -> bool:
    key = (service, nonce)
    with _nonce_lock:
        expired = [item for item, seen_at in _seen_nonces.items() if now - seen_at > _MAX_CLOCK_SKEW_SECONDS * 2]
        for item in expired:
            _seen_nonces.pop(item, None)
        if key in _seen_nonces:
            return False
        _seen_nonces[key] = now
        if len(_seen_nonces) > 10000:
            oldest = sorted(_seen_nonces.items(), key=lambda pair: pair[1])[:2000]
            for item, _ in oldest:
                _seen_nonces.pop(item, None)
        return True


async def verify_internal_request(request: Request) -> tuple[str, bytes]:
    """Возвращает вызывающего и тело запроса либо отклоняет запрос."""
    service = request.headers.get("x-ge-service", "").strip().lower()
    timestamp_text = request.headers.get("x-ge-timestamp", "").strip()
    nonce = request.headers.get("x-ge-nonce", "").strip()
    signature = request.headers.get("x-ge-signature", "").strip().lower()
    if not _SERVICE_RE.fullmatch(service) or not timestamp_text.isdigit() or not _NONCE_RE.fullmatch(nonce):
        raise HTTPException(401, "Invalid internal request")
    try:
        timestamp = int(timestamp_text)
    except ValueError:
        raise HTTPException(401, "Invalid internal request")
    now = int(time.time())
    if abs(now - timestamp) > _MAX_CLOCK_SKEW_SECONDS:
        raise HTTPException(401, "Expired internal request")
    secret = _secret_for(service)
    if secret is None:
        raise HTTPException(401, "Invalid internal request")
    body = await request.body()
    if len(body) > _MAX_BODY_BYTES:
        raise HTTPException(413, "Internal request is too large")
    prefix = f"{timestamp_text}\n{nonce}\n{request.method.upper()}\n{request.url.path}\n".encode("utf-8")
    expected = hmac.new(secret, prefix + body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise HTTPException(401, "Invalid internal request")
    if not _claim_nonce(service, nonce, now):
        raise HTTPException(401, "Replayed internal request")
    if service == "ghogem" and (request.method.upper() != "POST" or request.url.path not in {
        "/internal/v1/identity/resolve", "/internal/v1/identity/public-profile",
        "/internal/v1/identity/search-public",
    }):
        raise HTTPException(403, "Service scope denied")
    return service, body
