"""Проверка контейнеров зашифрованных бэкапов ключей GhostChat."""

from __future__ import annotations

import base64
import binascii
import re
from typing import Optional


KEY_KDF_ARGON2ID = "argon2id-v1-m65536-t3-p1"
KEY_KDF_PBKDF2 = "pbkdf2-sha256-v1-i260000"
KEY_FORMAT_V2 = "p256-pkcs8-aesgcm-v2"
IDENTITY_KDF_PBKDF2 = "pbkdf2-sha256-v1-i260000"

_B64_RE = re.compile(r"^[A-Za-z0-9+/]*={0,2}$")
_MAX_B64_CHARS = 4096
_MIN_GCM_BYTES = 12 + 16
_MAX_BACKUP_BYTES = 512


def _decode(value: object, *, field: str, exact_len: Optional[int] = None,
            min_len: Optional[int] = None, max_len: Optional[int] = None) -> bytes:
    if not isinstance(value, str) or not value or len(value) > _MAX_B64_CHARS:
        raise ValueError(f"{field}: invalid base64")
    if not _B64_RE.fullmatch(value) or len(value) % 4 != 0:
        raise ValueError(f"{field}: invalid base64")
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError(f"{field}: invalid base64") from None
    if base64.b64encode(raw).decode("ascii") != value:
        raise ValueError(f"{field}: non-canonical base64")
    if exact_len is not None and len(raw) != exact_len:
        raise ValueError(f"{field}: invalid length")
    if min_len is not None and len(raw) < min_len:
        raise ValueError(f"{field}: too short")
    if max_len is not None and len(raw) > max_len:
        raise ValueError(f"{field}: too long")
    return raw


def validate_key_upload(*, public_key: object, encrypted_private_key: object = None,
                        key_salt: object = None, key_kdf: object = None,
                        key_format: object = None, storage_mode: object = None) -> dict:
    raw_pub = _decode(public_key, field="x25519_pub")
    if len(raw_pub) not in (32, 65):
        raise ValueError("x25519_pub: expected 32 or 65 bytes")
    if not isinstance(storage_mode, str) or storage_mode.strip().lower() not in ("server", "local"):
        raise ValueError("storage_mode: expected 'server' or 'local'")
    mode = storage_mode.strip().lower()
    if key_kdf is not None and not isinstance(key_kdf, str):
        raise ValueError("key_kdf: invalid")
    if key_format is not None and not isinstance(key_format, str):
        raise ValueError("key_format: invalid")
    kdf = key_kdf.strip() if isinstance(key_kdf, str) else None
    fmt = key_format.strip() if isinstance(key_format, str) else None

    if mode == "local":
        if any(value not in (None, "") for value in
               (encrypted_private_key, key_salt, key_kdf, key_format)):
            raise ValueError("local mode cannot include a server key backup")
        return {
            "public_key": public_key,
            "encrypted_private_key": None,
            "key_salt": None,
            "key_kdf": None,
            "key_format": None,
            "storage_mode": mode,
        }

    if not encrypted_private_key or not key_salt:
        raise ValueError("server mode requires encrypted_private_key and key_salt")
    _decode(encrypted_private_key, field="encrypted_private_key",
            min_len=_MIN_GCM_BYTES, max_len=_MAX_BACKUP_BYTES)
    _decode(key_salt, field="key_salt", exact_len=16)

    # Мобильные клиенты задают обе части Argon2id; старые контейнеры оставляем читаемыми.
    if kdf is None and fmt is None:
        pass
    elif kdf == KEY_KDF_ARGON2ID and fmt == KEY_FORMAT_V2:
        pass
    elif kdf == KEY_KDF_PBKDF2 and fmt is None:
        pass
    else:
        raise ValueError("unsupported or incomplete key container metadata")

    return {
        "public_key": public_key,
        "encrypted_private_key": encrypted_private_key,
        "key_salt": key_salt,
        "key_kdf": kdf,
        "key_format": fmt,
        "storage_mode": mode,
    }


def validate_identity_backup(*, encrypted_private_key: object = None,
                            key_salt: object = None,
                            key_kdf: object = None) -> dict:
    """Проверяет пару V2-резерва как единое целое."""
    if encrypted_private_key is None and key_salt is None and key_kdf is None:
        return {"encrypted": None, "salt": None, "kdf": None}
    if not encrypted_private_key or not key_salt:
        raise ValueError("identity backup requires encrypted payload and salt")
    _decode(encrypted_private_key, field="identity_priv_encrypted",
            min_len=_MIN_GCM_BYTES, max_len=_MAX_BACKUP_BYTES)
    _decode(key_salt, field="identity_salt", exact_len=16)
    if key_kdf is not None and key_kdf != IDENTITY_KDF_PBKDF2:
        raise ValueError("identity_kdf: unsupported")
    return {
        "encrypted": encrypted_private_key,
        "salt": key_salt,
        "kdf": key_kdf or IDENTITY_KDF_PBKDF2,
    }
