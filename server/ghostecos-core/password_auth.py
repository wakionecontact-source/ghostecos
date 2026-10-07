"""Password verifier helpers shared by legacy and challenge-response auth.

The v1 wire protocol deliberately never sends the Argon2 output itself. The
client proves knowledge of it with a nonce-bound HMAC proof; the proof is
single-use and cannot be replayed as a password.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
from typing import Any

from argon2.low_level import Type, hash_secret_raw


_KEY_BYTES = 32
_KDF_NAME = "argon2id"
_PHC_RE = re.compile(
    r"^\$argon2id\$v=(\d+)\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$"
)


def b64e(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def b64d(value: str) -> bytes:
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise ValueError("invalid base64 value")
    padded = value + "=" * ((4 - len(value) % 4) % 4)
    return base64.b64decode(padded, altchars=b"-_", validate=True)


def validate_kdf(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("invalid password KDF")
    name = raw.get("name")
    if name == "argon2id":
        params = {
            "name": "argon2id",
            "version": int(raw.get("version", 19)),
            "iterations": int(raw["iterations"]),
            "memory_kib": int(raw["memory_kib"]),
            "parallelism": int(raw["parallelism"]),
            "hash_len": int(raw.get("hash_len", _KEY_BYTES)),
        }
        if (params["version"] != 19 or not 1 <= params["iterations"] <= 10
                or not 8192 <= params["memory_kib"] <= 262144
                or not 1 <= params["parallelism"] <= 8
                or params["hash_len"] != _KEY_BYTES):
            raise ValueError("unsupported Argon2id parameters")
        return params
    if name == "pbkdf2-sha256":
        params = {
            "name": name,
            "iterations": int(raw["iterations"]),
            "hash_len": int(raw.get("hash_len", _KEY_BYTES)),
        }
        if not 100_000 <= params["iterations"] <= 2_000_000 or params["hash_len"] != _KEY_BYTES:
            raise ValueError("unsupported PBKDF2 parameters")
        return params
    raise ValueError("unsupported password KDF")


def _keys_from_salted_password(salted_password: bytes, salt: bytes, kdf: dict) -> dict:
    if len(salted_password) != _KEY_BYTES or not 16 <= len(salt) <= 64:
        raise ValueError("invalid password verifier material")
    client_key = hmac.new(salted_password, b"GhostChat Client Key v1", hashlib.sha256).digest()
    server_key = hmac.new(salted_password, b"GhostChat Server Key v1", hashlib.sha256).digest()
    return {
        "salt": b64e(salt),
        "kdf": validate_kdf(kdf),
        "stored_key": b64e(hashlib.sha256(client_key).digest()),
        "server_key": b64e(server_key),
    }


def validate_verifier(raw: Any) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("password verifier is required")
    kdf = validate_kdf(raw.get("kdf"))
    salt = b64d(raw.get("salt", ""))
    stored_key = b64d(raw.get("stored_key", ""))
    server_key = b64d(raw.get("server_key", ""))
    if not 16 <= len(salt) <= 64 or len(stored_key) != _KEY_BYTES or len(server_key) != _KEY_BYTES:
        raise ValueError("invalid password verifier")
    return {
        "salt": b64e(salt),
        "kdf": kdf,
        "stored_key": b64e(stored_key),
        "server_key": b64e(server_key),
    }


def verifier_from_password(password: str, salt: bytes, kdf: dict) -> dict:
    params = validate_kdf(kdf)
    if params["name"] == "argon2id":
        salted = hash_secret_raw(
            password.encode("utf-8"), salt,
            time_cost=params["iterations"], memory_cost=params["memory_kib"],
            parallelism=params["parallelism"], hash_len=_KEY_BYTES,
            type=Type.ID, version=params["version"],
        )
    else:
        salted = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt,
            params["iterations"], dklen=_KEY_BYTES,
        )
    return _keys_from_salted_password(salted, salt, params)


def verifier_from_argon2_hash(encoded: str) -> dict:
    match = _PHC_RE.fullmatch(encoded or "")
    if not match:
        raise ValueError("unsupported Argon2 hash")
    version, memory_kib, iterations, parallelism = map(int, match.groups()[:4])
    salt = base64.b64decode(match.group(5) + "=" * ((4 - len(match.group(5)) % 4) % 4))
    digest = base64.b64decode(match.group(6) + "=" * ((4 - len(match.group(6)) % 4) % 4))
    if len(digest) != _KEY_BYTES:
        raise ValueError("unsupported Argon2 hash length")
    kdf = validate_kdf({
        "name": "argon2id", "version": version, "memory_kib": memory_kib,
        "iterations": iterations, "parallelism": parallelism, "hash_len": _KEY_BYTES,
    })
    return _keys_from_salted_password(digest, salt, kdf)


def verifier_from_pbkdf2_hash(encoded: str, iterations: int = 260_000) -> dict:
    salt_hex, key_hex = encoded.split(":", 1)
    salt = bytes.fromhex(salt_hex)
    salted = bytes.fromhex(key_hex)
    if len(salted) != _KEY_BYTES:
        raise ValueError("unsupported PBKDF2 hash length")
    return _keys_from_salted_password(
        salted, salt,
        validate_kdf({"name": "pbkdf2-sha256", "iterations": iterations, "hash_len": _KEY_BYTES}),
    )


def verifier_for_user(user: dict) -> dict:
    if user.get("auth_v1_salt") and user.get("auth_v1_kdf"):
        return validate_verifier({
            "salt": user["auth_v1_salt"],
            "kdf": json.loads(user["auth_v1_kdf"]),
            "stored_key": user["auth_v1_stored_key"],
            "server_key": user["auth_v1_server_key"],
        })
    for field in ("argon2_hash", "password_hash"):
        value = user.get(field)
        if value and value.startswith("$argon2id$"):
            return verifier_from_argon2_hash(value)
    if user.get("pbkdf2_hash"):
        return verifier_from_pbkdf2_hash(user["pbkdf2_hash"])
    legacy = user.get("password_hash")
    if legacy and ":" in legacy:
        return verifier_from_pbkdf2_hash(legacy)
    raise ValueError("no supported password verifier")


def verify_password(password: str, verifier: dict) -> bool:
    try:
        checked = validate_verifier(verifier)
        candidate = verifier_from_password(password, b64d(checked["salt"]), checked["kdf"])
        return hmac.compare_digest(
            b64d(candidate["stored_key"]), b64d(checked["stored_key"])
        )
    except (ValueError, TypeError, KeyError):
        return False


def verifier_db_fields(verifier: dict) -> tuple[str, str, str, str]:
    checked = validate_verifier(verifier)
    return (
        checked["salt"],
        json.dumps(checked["kdf"], sort_keys=True, separators=(",", ":")),
        checked["stored_key"],
        checked["server_key"],
    )


def transcript(purpose: str, username: str, challenge_id: str, client_nonce: str,
               server_nonce: str, context: str = "") -> bytes:
    values = (purpose, username.lower(), challenge_id, client_nonce, server_nonce, context)
    if any("\n" in value or "\r" in value for value in values):
        raise ValueError("invalid challenge transcript")
    return ("ghostchat-password-v1\n" + "\n".join(values)).encode("utf-8")


def verify_client_proof(verifier: dict, message: bytes, encoded_proof: str) -> bool:
    try:
        proof = b64d(encoded_proof)
        stored_key = b64d(verifier["stored_key"])
        if len(proof) != _KEY_BYTES or len(stored_key) != _KEY_BYTES:
            return False
        signature = hmac.new(stored_key, message, hashlib.sha256).digest()
        client_key = bytes(a ^ b for a, b in zip(proof, signature))
        return hmac.compare_digest(hashlib.sha256(client_key).digest(), stored_key)
    except (ValueError, TypeError, KeyError):
        return False


def client_proof_from_password(password: str, verifier: dict, message: bytes) -> str:
    checked = validate_verifier(verifier)
    salt = b64d(checked["salt"])
    params = checked["kdf"]
    if params["name"] == "argon2id":
        salted = hash_secret_raw(
            password.encode("utf-8"), salt,
            time_cost=params["iterations"], memory_cost=params["memory_kib"],
            parallelism=params["parallelism"], hash_len=_KEY_BYTES,
            type=Type.ID, version=params["version"],
        )
    else:
        salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt,
                                    params["iterations"], dklen=_KEY_BYTES)
    client_key = hmac.new(salted, b"GhostChat Client Key v1", hashlib.sha256).digest()
    signature = hmac.new(b64d(checked["stored_key"]), message, hashlib.sha256).digest()
    proof = bytes(a ^ b for a, b in zip(client_key, signature))
    return b64e(proof)


def server_proof(verifier: dict, message: bytes) -> str:
    key = b64d(validate_verifier(verifier)["server_key"])
    return b64e(hmac.new(key, b"GhostChat Server Proof v1\n" + message, hashlib.sha256).digest())


def verify_server_proof(verifier: dict, message: bytes, encoded_proof: str) -> bool:
    try:
        expected = b64d(server_proof(verifier, message))
        actual = b64d(encoded_proof)
        return hmac.compare_digest(expected, actual)
    except (ValueError, TypeError):
        return False


def new_verifier(password: str, salt: bytes | None = None, kdf: dict | None = None) -> dict:
    salt = salt or secrets.token_bytes(16)
    kdf = kdf or {
        "name": "argon2id", "version": 19, "iterations": 3,
        "memory_kib": 65536, "parallelism": 1, "hash_len": _KEY_BYTES,
    }
    return verifier_from_password(password, salt, kdf)
