"""Сейф паролей GhostID.

Пароль аккаунта сохраняется при входе и выдаётся сервису только по scope
`password`, зашифрованным на секрет конкретного запроса входа: ключ выводится
из PKCE code_verifier, который знает лишь клиент. Открытого пароля не видит
ни база, ни журналы.
"""

import base64
import os
import sqlite3
import time
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# ── Параметры сейфа ──────────────────────────────
_WRAP_SALT = "ghostid-vault-token-v1"
_NONCE_BYTES = 12
_KEY_BYTES = 32
_AAD_PREFIX = "ghostid/vault"
_DB_PATH = "/opt/ghostecos-core/private/service_sso.sqlite3"
_KEY_PATH = "/opt/ghostecos-core/private/vault.key"


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _db_path() -> Path:
    return Path(os.getenv("GE_SSO_DB_PATH", _DB_PATH))


def _master_key() -> bytes:
    """Ключ сейфа: GE_VAULT_KEY (base64, 32 байта) или файл рядом с БД."""
    raw = os.getenv("GE_VAULT_KEY", "").strip()
    if raw:
        key = base64.b64decode(raw)
        if len(key) != _KEY_BYTES:
            raise ValueError("GE_VAULT_KEY должен содержать 32 байта в base64")
        return key
    path = Path(os.getenv("GE_VAULT_KEY_FILE", _KEY_PATH))
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(os.urandom(_KEY_BYTES))
        os.chmod(path, 0o600)
    key = path.read_bytes()
    if len(key) != _KEY_BYTES:
        raise ValueError("Файл ключа сейфа повреждён")
    return key


def _aad(user_id: int, client_id: str) -> bytes:
    return f"{_AAD_PREFIX}/{int(user_id)}/{client_id}".encode("utf-8")


def _connect() -> sqlite3.Connection:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("""
        CREATE TABLE IF NOT EXISTS vault (
            user_id INTEGER PRIMARY KEY, sealed TEXT NOT NULL, updated_at INTEGER NOT NULL
        )
    """)
    return connection


def save_password(user_id: int, password: str) -> bool:
    """Кладёт пароль в сейф после успешного входа; пустой пароль не пишем."""
    if not password:
        return False
    nonce = os.urandom(_NONCE_BYTES)
    sealed = AESGCM(_master_key()).encrypt(nonce, password.encode("utf-8"), _aad(user_id, ""))
    connection = _connect()
    try:
        connection.execute(
            "INSERT INTO vault VALUES (?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET sealed=excluded.sealed, updated_at=excluded.updated_at",
            (int(user_id), _b64(nonce) + ":" + _b64(sealed), int(time.time())),
        )
        connection.commit()
        return True
    finally:
        connection.close()


def forget_password(user_id: int) -> None:
    connection = _connect()
    try:
        connection.execute("DELETE FROM vault WHERE user_id=?", (int(user_id),))
        connection.commit()
    finally:
        connection.close()


def read_password(user_id: int) -> str | None:
    connection = _connect()
    try:
        row = connection.execute("SELECT sealed FROM vault WHERE user_id=?", (int(user_id),)).fetchone()
    finally:
        connection.close()
    if not row:
        return None
    try:
        nonce_b64, sealed_b64 = row["sealed"].split(":", 1)
        plain = AESGCM(_master_key()).decrypt(base64.b64decode(nonce_b64),
                                              base64.b64decode(sealed_b64), _aad(user_id, ""))
    except (ValueError, KeyError):
        return None
    return plain.decode("utf-8")


def seal_for_client(password: str, code_verifier: str, client_id: str, user_id: int) -> dict:
    """Шифрует пароль на ключ PKCE-проверки: расшифровать может только клиент входа."""
    key = HKDF(algorithm=hashes.SHA256(), length=_KEY_BYTES, salt=_WRAP_SALT.encode("ascii"),
               info=f"{client_id}:{int(user_id)}".encode("utf-8")).derive(code_verifier.encode("ascii"))
    nonce = os.urandom(_NONCE_BYTES)
    sealed = AESGCM(key).encrypt(nonce, password.encode("utf-8"), _aad(user_id, client_id))
    return {
        "alg": "AES-256-GCM",
        "kdf": {"name": "HKDF-SHA256", "salt": _WRAP_SALT, "info": f"{client_id}:{int(user_id)}",
                "secret": "code_verifier"},
        "nonce": _b64(nonce),
        "ciphertext": _b64(sealed),
    }
