"""Долгоживущий Ed25519-ключ сервера. Используется для подписи cs.hello
эфемерных server_pub'ов → клиент может детектить MITM (атакующего, который
подменяет server_pub в handshake чтобы читать WS-трафик после).

Ключ генерируется один раз и хранится в файле. Pub раздаётся через
GET /api/chat/v2/server-identity — клиент кэширует его при первом
подключении (TOFU) и сверяет подпись на каждом handshake.

При компрометации priv — удалить файл, перезапустить — сгенерируется
новый. Все клиенты тогда увидят mismatch identity и должны будут
заново принять (как с self-signed TLS cert).
"""
import os
import stat
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey, Ed25519PublicKey,
)
from cryptography.hazmat.primitives import serialization

_KEY_PATH = "/opt/ghostchat/server_identity.ed25519"

_priv = None
_pub_bytes = None


def _load_or_create():
    global _priv, _pub_bytes
    if _priv is not None:
        return
    if os.path.islink(_KEY_PATH):
        raise RuntimeError(f"{_KEY_PATH}: symlink is not allowed for server identity")
    if os.path.exists(_KEY_PATH):
        st = os.stat(_KEY_PATH, follow_symlinks=False)
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f"{_KEY_PATH}: expected a regular file")
        if stat.S_IMODE(st.st_mode) & 0o077:
            raise RuntimeError(f"{_KEY_PATH}: permissions must be 0600 or stricter")
        with open(_KEY_PATH, "rb") as f:
            raw = f.read()
        if len(raw) != 32:
            raise RuntimeError(f"{_KEY_PATH}: ожидается 32 байта raw priv, получено {len(raw)}")
        _priv = Ed25519PrivateKey.from_private_bytes(raw)
    else:
        _priv = Ed25519PrivateKey.generate()
        raw = _priv.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        # Create atomically and refuse a concurrent replacement. The service
        # must never silently overwrite an existing server identity key.
        try:
            fd = os.open(
                _KEY_PATH,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
        except FileExistsError:
            return _load_or_create()
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(_KEY_PATH, 0o600)
        except Exception:
            try:
                os.unlink(_KEY_PATH)
            except OSError:
                pass
            raise
    _pub_bytes = _priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )


def server_identity_pub_bytes() -> bytes:
    _load_or_create()
    return _pub_bytes


def sign_handshake(data: bytes) -> bytes:
    """Подписать произвольные данные (handshake material) долгоживущим ключом."""
    _load_or_create()
    return _priv.sign(data)
