"""Self-hosted visual CAPTCHA and short-lived capability tokens.

This is a deliberately small transition CAPTCHA. The challenge image is
generated on the server, the answer never leaves the server in plaintext, and
successful verification produces a capability token scoped to one audience
(``auth``, ``ghogem`` or ``download``). It can later be replaced without changing the
protected API contract.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import io
import os
import secrets
import threading
import time
from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:  # fail closed if the production image dependency is missing
    Image = ImageDraw = ImageFilter = ImageFont = None


router = APIRouter(prefix="/bot-check", tags=["bot-check"])

_CHALLENGE_TTL = 5 * 60
_CAPABILITY_TTL = 15 * 60
_CODE_LENGTH = 5
_MAX_ATTEMPTS = 5
_MAX_ENTRIES = 20_000
_ALLOWED_PURPOSES = frozenset(("auth", "ghogem", "download"))
_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
_lock = threading.Lock()
_pending: dict[str, tuple[str, str, int, int]] = {}
_used_capabilities: dict[str, int] = {}
_rate: dict[tuple[str, str], list[float]] = {}
_font_path: Optional[str] = None


class VerifyBody(BaseModel):
    challenge_id: str = Field(min_length=1, max_length=128)
    solution: str = Field(min_length=1, max_length=32)


def _secret(name: str) -> str:
    value = os.getenv(name, "").strip()
    if len(value) < 32:
        raise HTTPException(503, "Captcha is not configured")
    return value


def _now() -> int:
    return int(time.time())


def _required() -> bool:
    """Allow a staged rollout while old clients are still in the wild."""
    return os.getenv("GC_BOT_CHECK_REQUIRED", "1").strip().lower() not in {
        "0", "false", "no", "off",
    }


def _b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64d(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _client_ip(request: Request) -> str:
    # Nginx overwrites X-Real-IP in this deployment; do not trust arbitrary
    # X-Forwarded-For values from the public client.
    return (request.headers.get("x-real-ip") or
            (request.client.host if request.client else "unknown"))[:128]


def _rate_limit(request: Request, action: str, limit: int = 30) -> None:
    key = (_client_ip(request), action)
    now = time.time()
    with _lock:
        values = [at for at in _rate.get(key, []) if now - at < 600]
        if len(values) >= limit:
            _rate[key] = values
            raise HTTPException(429, "Too many captcha attempts")
        values.append(now)
        _rate[key] = values
        if len(_rate) > _MAX_ENTRIES:
            cutoff = now - 1200
            for old_key, old_values in list(_rate.items()):
                if not old_values or old_values[-1] < cutoff:
                    _rate.pop(old_key, None)


def _cleanup_locked(now: int) -> None:
    for key, item in list(_pending.items()):
        if item[2] <= now:
            _pending.pop(key, None)
    for key, expires in list(_used_capabilities.items()):
        if expires <= now:
            _used_capabilities.pop(key, None)
    while len(_pending) > _MAX_ENTRIES:
        _pending.pop(next(iter(_pending)))
    while len(_used_capabilities) > _MAX_ENTRIES:
        _used_capabilities.pop(next(iter(_used_capabilities)))


def _font() -> ImageFont.FreeTypeFont:
    global _font_path
    if ImageFont is None:
        raise HTTPException(503, "Captcha image renderer is not configured")
    if _font_path:
        return ImageFont.truetype(_font_path, 48)
    candidates = (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
        "C:/Windows/Fonts/arialbd.ttf",
    )
    for candidate in candidates:
        if os.path.exists(candidate):
            _font_path = candidate
            return ImageFont.truetype(candidate, 48)
    raise HTTPException(503, "Captcha font is not configured")


def _render_image(code: str) -> str:
    """Render a raster image so the answer is not exposed as SVG/text."""
    if Image is None or ImageDraw is None or ImageFilter is None:
        raise HTTPException(503, "Captcha image renderer is not configured")
    width, height = 300, 100
    image = Image.new("RGB", (width, height), (245, 242, 255))
    draw = ImageDraw.Draw(image)

    for _ in range(9):
        color = tuple(secrets.randbelow(100) + 90 for _ in range(3))
        points = [
            (secrets.randbelow(width), secrets.randbelow(height)),
            (secrets.randbelow(width), secrets.randbelow(height)),
        ]
        draw.line(points, fill=color, width=secrets.choice((1, 2, 3)))
    for _ in range(180):
        x = secrets.randbelow(width)
        y = secrets.randbelow(height)
        color = tuple(secrets.randbelow(90) + 120 for _ in range(3))
        draw.point((x, y), fill=color)

    font = _font()
    slot = width // len(code)
    for index, char in enumerate(code):
        layer = Image.new("RGBA", (slot + 24, height), (0, 0, 0, 0))
        layer_draw = ImageDraw.Draw(layer)
        layer_draw.text(
            (10, 19 + secrets.randbelow(10) - 5),
            char,
            font=font,
            fill=(35, 20, 85, 255),
            stroke_width=1,
            stroke_fill=(70, 45, 125, 255),
        )
        layer = layer.rotate(
            secrets.randbelow(25) - 12,
            resample=Image.Resampling.BICUBIC,
            expand=False,
        )
        image.paste(layer, (index * slot - 2, 0), layer)

    image = image.filter(ImageFilter.GaussianBlur(radius=0.15))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")


def _code_digest(challenge_id: str, solution: str) -> str:
    normalized = "".join(solution.upper().split())
    return hmac.new(
        _secret("GC_BOT_CHECK_SECRET").encode(),
        f"{challenge_id}:{normalized}".encode(),
        hashlib.sha256,
    ).hexdigest()


def _make_capability(purpose: str) -> tuple[str, int]:
    now = _now()
    expires = now + _CAPABILITY_TTL
    payload = f"1|{purpose}|{secrets.token_urlsafe(18)}|{now}|{expires}"
    encoded = _b64e(payload.encode())
    signature = hmac.new(
        _secret("GC_BOT_CAP_SECRET").encode(),
        encoded.encode(),
        hashlib.sha256,
    ).digest()
    return encoded + "." + _b64e(signature), expires


def _capability_value(token: str, purpose: str, consume: bool = False) -> str:
    if not token or len(token) > 2048 or token.count(".") != 1:
        raise HTTPException(403, "Captcha required")
    encoded, supplied_sig = token.split(".", 1)
    try:
        expected = hmac.new(
            _secret("GC_BOT_CAP_SECRET").encode(),
            encoded.encode(),
            hashlib.sha256,
        ).digest()
        if not hmac.compare_digest(expected, _b64d(supplied_sig)):
            raise ValueError
        version, audience, jti, issued, expires = _b64d(encoded).decode().split("|")
        if version != "1" or audience != purpose:
            raise ValueError
        int(issued)
        expires = int(expires)
        if expires <= _now():
            raise ValueError
    except (ValueError, TypeError, UnicodeDecodeError):
        raise HTTPException(403, "Captcha required")
    with _lock:
        _cleanup_locked(_now())
        if jti in _used_capabilities:
            raise HTTPException(403, "Captcha token already used")
        if consume:
            _used_capabilities[jti] = expires
    return jti


def require_bot_token(request: Request, purpose: str, *, consume: bool = False) -> str:
    if purpose not in _ALLOWED_PURPOSES:
        raise HTTPException(500, "Invalid captcha audience")
    if not _required():
        return ""
    token = request.headers.get("x-ghost-bot-token", "").strip()
    if not token:
        raise HTTPException(
            status_code=428,
            detail={
                "code": "captcha_required",
                "message": "Сначала пройдите CAPTCHA",
                "challenge_url": f"/bot-check/challenge?purpose={purpose}",
                "verify_url": "/bot-check/verify",
            },
        )
    return _capability_value(token, purpose, consume=consume)


def consume_bot_token(token: str, purpose: str) -> str:
    if not _required():
        return ""
    return _capability_value(token, purpose, consume=True)


@router.get("/challenge")
def challenge(request: Request, purpose: str = "auth"):
    _rate_limit(request, "challenge")
    if purpose not in _ALLOWED_PURPOSES:
        raise HTTPException(400, "Invalid captcha audience")
    if Image is None:
        raise HTTPException(503, "Captcha image renderer is not configured")
    challenge_id = secrets.token_urlsafe(18)
    expires = _now() + _CHALLENGE_TTL
    code = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(_CODE_LENGTH))
    digest = _code_digest(challenge_id, code)
    image = _render_image(code)
    with _lock:
        _cleanup_locked(_now())
        _pending[challenge_id] = (purpose, digest, expires, 0)
    return {
        "challenge_id": challenge_id,
        "purpose": purpose,
        "image": image,
        "length": _CODE_LENGTH,
        "expires_at": expires,
    }


@router.post("/verify")
def verify(body: VerifyBody, request: Request):
    _rate_limit(request, "verify")
    now = _now()
    with _lock:
        _cleanup_locked(now)
        pending = _pending.get(body.challenge_id)
        if not pending or pending[2] <= now:
            raise HTTPException(400, "CAPTCHA истекла или уже использована")
        purpose, expected_digest, expires, attempts = pending
        supplied_digest = _code_digest(body.challenge_id, body.solution)
        if not hmac.compare_digest(expected_digest, supplied_digest):
            attempts += 1
            if attempts >= _MAX_ATTEMPTS:
                _pending.pop(body.challenge_id, None)
            else:
                _pending[body.challenge_id] = (purpose, expected_digest, expires, attempts)
            raise HTTPException(400, "Неверный код CAPTCHA")
        _pending.pop(body.challenge_id, None)
    token, token_expires = _make_capability(purpose)
    return {
        "bot_token": token,
        "purpose": purpose,
        "expires_at": token_expires,
    }
