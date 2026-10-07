"""
P-256 ECDH + HKDF-SHA256 + AES-256-GCM — bit-for-bit совместимо с
lib/services/crypto_service.dart (encryptFor/decryptFrom) в _ghost_app.

Схема:
  ECDH(my_priv, their_pub) -> shared secret (32 bytes, X-coordinate)
  HKDF-SHA256(shared, salt=zeros(32), info=b"ghostchat-msg-v1") -> 32-byte AES key
  AES-256-GCM(key, iv=12 random bytes) -> ciphertext + 16-byte tag
  wire = base64(iv(12) || ciphertext || tag(16))

Приватный ключ — сырые 32 байта (D-координата).
Публичный ключ — 65 байт uncompressed point (0x04 || X(32) || Y(32)).
"""
import base64
import os

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_CURVE = ec.SECP256R1()
_HKDF_INFO = b"ghostchat-msg-v1"
_HKDF_SALT = b"\x00" * 32


def generate_keypair() -> tuple[bytes, bytes]:
    """-> (priv_d_32bytes, pub_raw_65bytes)"""
    priv = ec.generate_private_key(_CURVE)
    d = priv.private_numbers().private_value
    priv_raw = d.to_bytes(32, "big")
    pub_raw = priv.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    return priv_raw, pub_raw


def _load_priv(priv_raw: bytes) -> ec.EllipticCurvePrivateKey:
    d = int.from_bytes(priv_raw, "big")
    return ec.derive_private_key(d, _CURVE)


def _load_pub(pub_raw: bytes) -> ec.EllipticCurvePublicKey:
    return ec.EllipticCurvePublicKey.from_encoded_point(_CURVE, pub_raw)


def derive_aes_key(my_priv_raw: bytes, their_pub_raw: bytes) -> bytes:
    priv = _load_priv(my_priv_raw)
    pub = _load_pub(their_pub_raw)
    shared = priv.exchange(ec.ECDH(), pub)
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=_HKDF_SALT, info=_HKDF_INFO).derive(shared)


def encrypt_for(my_priv_raw: bytes, their_pub_raw: bytes, plaintext: str) -> str:
    key = derive_aes_key(my_priv_raw, their_pub_raw)
    iv = os.urandom(12)
    ct = AESGCM(key).encrypt(iv, plaintext.encode("utf-8"), None)
    return base64.b64encode(iv + ct).decode()


def decrypt_from(my_priv_raw: bytes, their_pub_raw: bytes, envelope_b64: str) -> str:
    key = derive_aes_key(my_priv_raw, their_pub_raw)
    raw = base64.b64decode(envelope_b64)
    if len(raw) < 12 + 16:
        raise ValueError("envelope too short")
    iv, ct = raw[:12], raw[12:]
    pt = AESGCM(key).decrypt(iv, ct, None)
    return pt.decode("utf-8")
