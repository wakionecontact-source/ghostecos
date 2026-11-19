"""JWT сессии для веб-клиента (sub = gc_username)."""
import base64
import hashlib
import hmac
import json
import time
from typing import Optional

import config


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def issue_token(gc_username: str, ttl_days: int = 30) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "sub": gc_username,
        "iat": int(time.time()),
        "exp": int(time.time()) + ttl_days * 86400,
    }
    h = _b64url(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(config.JWT_SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64url(sig)}"


def verify_token(token: str) -> Optional[str]:
    """Возвращает gc_username или None."""
    try:
        h, p, s = token.split(".")
    except ValueError:
        return None
    expected = hmac.new(
        config.JWT_SECRET.encode(), f"{h}.{p}".encode(), hashlib.sha256
    ).digest()
    try:
        actual = _b64url_decode(s)
    except Exception:
        return None
    if not hmac.compare_digest(expected, actual):
        return None
    try:
        payload = json.loads(_b64url_decode(p))
    except Exception:
        return None
    if int(payload.get("exp", 0)) < int(time.time()):
        return None
    sub = payload.get("sub")
    if not isinstance(sub, str) or not sub:
        return None
    return sub
