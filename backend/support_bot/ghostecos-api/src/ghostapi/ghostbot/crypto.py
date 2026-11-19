"""Эфемерные X25519/AES-GCM для тест-чатов владельца."""

from __future__ import annotations

import base64
import binascii
import hashlib
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


_HKDF_INFO = b"ghostchat-bot-test-chat-v1"


class BotTestCryptoError(ValueError):
    """Битые ключи тест-чата или конверт шифрованного сообщения."""


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _decode(value: object, *, max_chars: int = 8_000) -> bytes:
    if not isinstance(value, str) or not value or len(value) > max_chars:
        raise BotTestCryptoError("Invalid encrypted test-chat value")
    try:
        padded = value + "=" * (-len(value) % 4)
        return base64.b64decode(padded, altchars=b"-_", validate=True)
    except (ValueError, binascii.Error) as exc:
        raise BotTestCryptoError("Invalid encrypted test-chat value") from exc


class BotTestCrypto:
    """X25519-идентичность процесса и ключи активных тест-сессий."""

    def __init__(self) -> None:
        self._private_key = X25519PrivateKey.generate()
        self._sessions: dict[str, tuple[bytes, bytes]] = {}

    @property
    def public_key(self) -> str:
        raw = self._public_key_bytes
        return _encode(raw)

    @property
    def public_key_fingerprint(self) -> str:
        return hashlib.sha256(self._public_key_bytes).hexdigest()[:24]

    @property
    def _public_key_bytes(self) -> bytes:
        return self._private_key.public_key().public_bytes(
            Encoding.Raw,
            PublicFormat.Raw,
        )

    def open_session(self, session_id: str, client_public_key: str) -> None:
        if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128:
            raise BotTestCryptoError("Invalid test-chat session ID")
        public_bytes = _decode(client_public_key, max_chars=48)
        if len(public_bytes) != 32:
            raise BotTestCryptoError("X25519 public key must be 32 bytes")
        existing = self._sessions.get(session_id)
        if existing:
            if existing[0] != public_bytes:
                raise BotTestCryptoError("Test-chat session key cannot be replaced")
            return
        try:
            peer = X25519PublicKey.from_public_bytes(public_bytes)
            shared_secret = self._private_key.exchange(peer)
        except ValueError as exc:
            raise BotTestCryptoError("Invalid X25519 public key") from exc
        key = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=session_id.encode("utf-8"),
            info=_HKDF_INFO,
        ).derive(shared_secret)
        self._sessions[session_id] = (public_bytes, key)

    def close_session(self, session_id: str) -> None:
        self._sessions.pop(session_id, None)

    def encrypt(self, session_id: str, text: str) -> dict[str, object]:
        if not isinstance(text, str) or not text or len(text) > 4_000:
            raise BotTestCryptoError("Test-chat text must contain 1-4000 characters")
        key = self._session_key(session_id)
        nonce = secrets.token_bytes(12)
        encrypted = AESGCM(key).encrypt(
            nonce,
            text.encode("utf-8"),
            session_id.encode("utf-8"),
        )
        return {
            "v": 1,
            "nonce": _encode(nonce),
            "ciphertext": _encode(encrypted[:-16]),
            "tag": _encode(encrypted[-16:]),
        }

    def decrypt(self, session_id: str, envelope: object) -> str:
        if not isinstance(envelope, dict) or envelope.get("v") != 1:
            raise BotTestCryptoError("Invalid encrypted test-chat envelope")
        nonce = _decode(envelope.get("nonce"), max_chars=16)
        ciphertext = _decode(envelope.get("ciphertext"))
        tag = _decode(envelope.get("tag"), max_chars=24)
        if len(nonce) != 12 or not ciphertext or len(tag) != 16:
            raise BotTestCryptoError("Invalid encrypted test-chat envelope")
        key = self._session_key(session_id)
        try:
            plaintext = AESGCM(key).decrypt(
                nonce,
                ciphertext + tag,
                session_id.encode("utf-8"),
            )
            return plaintext.decode("utf-8")
        except (InvalidTag, UnicodeDecodeError) as exc:
            raise BotTestCryptoError("Test-chat message authentication failed") from exc

    def _session_key(self, session_id: str) -> bytes:
        try:
            return self._sessions[session_id][1]
        except KeyError as exc:
            raise BotTestCryptoError("Test-chat session is not open") from exc


__all__ = ["BotTestCrypto", "BotTestCryptoError"]
