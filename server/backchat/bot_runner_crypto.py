"""At-rest encryption for managed bot credentials.

The independent bot runner needs a bot token to authenticate with the existing
GhostAPI SDK. Tokens are encrypted with a separately provisioned 256-bit key;
the plaintext is never written to the database or logged.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_AAD_PREFIX = b"ghostchat-managed-bot-token-v1:"


class BotRunnerKeyUnavailable(RuntimeError):
    pass


def _key() -> bytes:
    raw = os.environ.get("GHOSTBOT_RUNNER_KEY", "").strip()
    try:
        key = bytes.fromhex(raw)
    except ValueError as exc:
        raise BotRunnerKeyUnavailable("GHOSTBOT_RUNNER_KEY must be 64 hex characters") from exc
    if len(key) != 32:
        raise BotRunnerKeyUnavailable("GHOSTBOT_RUNNER_KEY must be 64 hex characters")
    return key


def encrypt_runner_token(token: str, bot_id: int) -> str:
    if not isinstance(token, str) or not token or type(bot_id) is not int or bot_id <= 0:
        raise ValueError("token and positive bot_id are required")
    nonce = secrets.token_bytes(12)
    ciphertext = AESGCM(_key()).encrypt(
        nonce,
        token.encode("utf-8"),
        _AAD_PREFIX + str(bot_id).encode("ascii"),
    )
    return "v1:" + base64.urlsafe_b64encode(nonce + ciphertext).decode("ascii").rstrip("=")


def decrypt_runner_token(value: str, bot_id: int) -> str:
    if not isinstance(value, str) or not value.startswith("v1:"):
        raise ValueError("unsupported managed bot credential format")
    if type(bot_id) is not int or bot_id <= 0:
        raise ValueError("positive bot_id is required")
    encoded = value[3:]
    padded = encoded + "=" * (-len(encoded) % 4)
    try:
        payload = base64.b64decode(padded, altchars=b"-_", validate=True)
        if len(payload) < 12 + 16:
            raise ValueError("encrypted credential is truncated")
        token = AESGCM(_key()).decrypt(
            payload[:12],
            payload[12:],
            _AAD_PREFIX + str(bot_id).encode("ascii"),
        )
        return token.decode("utf-8")
    except Exception as exc:
        raise ValueError("managed bot credential could not be decrypted") from exc


def runner_control_token() -> str:
    """Derive an internal API credential without transmitting the AES key."""
    return hmac.new(
        _key(),
        b"ghostchat-managed-runner-control-v1",
        hashlib.sha256,
    ).hexdigest()


def verify_runner_control_token(value: str | None) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        expected = runner_control_token()
    except BotRunnerKeyUnavailable:
        return False
    return hmac.compare_digest(value, expected)
