"""
GhostChat — WS session encryption.

Дополнительный слой шифрования поверх TLS:
- Ephemeral X25519 key exchange при каждом подключении
- AES-256-GCM для каждого пакета
- Сессионный ключ живёт только в RAM (_Conn.session_key)
- После отключения ключ уничтожается → forward secrecy

Сервер расшифровывает пакет только в RAM для маршрутизации.
Логи, БД, дампы — видят только зашифрованные байты.
"""
from __future__ import annotations

import json
import os
import base64
from typing import Optional

from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey
)
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_HKDF_INFO = b"ghostchat-ws-session-v2"
_NONCE_LEN  = 12  # GCM nonce


# ── Key exchange ──────────────────────────────────────────────────────────────

class ServerSession:
    """Эфемерная сессия на одно WS-соединение."""

    def __init__(self):
        self._priv   = X25519PrivateKey.generate()
        self._pub    = self._priv.public_key()
        self.key: Optional[bytes] = None  # AES session key, None до обмена

    @property
    def pub_b64(self) -> str:
        return base64.b64encode(
            self._pub.public_bytes_raw()
        ).decode()

    def derive(self, client_pub_b64: str) -> bytes:
        """Принять публичный ключ клиента → вывести сессионный ключ."""
        raw = base64.b64decode(client_pub_b64)
        client_pub = X25519PublicKey.from_public_bytes(raw)
        shared     = self._priv.exchange(client_pub)
        self.key   = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=_HKDF_INFO,
        ).derive(shared)
        # Сразу затираем приватный ключ — больше не нужен
        del self._priv
        return self.key


# ── Шифрование / дешифрование пакетов ────────────────────────────────────────

def encrypt_packet(key: bytes, data: dict) -> str:
    """
    dict → base64(nonce + AES-GCM ciphertext).
    Каждый пакет имеет уникальный nonce.
    """
    nonce     = os.urandom(_NONCE_LEN)
    plaintext = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()
    ct        = AESGCM(key).encrypt(nonce, plaintext, None)
    return base64.b64encode(nonce + ct).decode()


def decrypt_packet(key: bytes, payload: str) -> Optional[dict]:
    """
    base64(nonce + ciphertext) → dict.
    Возвращает None при ошибке (неверный ключ / повреждён).
    """
    try:
        raw      = base64.b64decode(payload)
        nonce    = raw[:_NONCE_LEN]
        ct       = raw[_NONCE_LEN:]
        pt_bytes = AESGCM(key).decrypt(nonce, ct, None)
        return json.loads(pt_bytes.decode())
    except Exception:
        return None
