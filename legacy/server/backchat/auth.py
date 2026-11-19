"""
Password hashing (Argon2id) and JWT tokens.
"""
import os
import time
import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

_ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4)

# Load or generate JWT secret
_SECRET_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".jwt_secret")

def _load_secret() -> str:
    if os.path.exists(_SECRET_FILE):
        return open(_SECRET_FILE).read().strip()
    secret = os.urandom(32).hex()
    with open(_SECRET_FILE, "w") as f:
        f.write(secret)
    return secret

JWT_SECRET = _load_secret()
JWT_ALG    = "HS256"
JWT_TTL    = 7 * 24 * 3600   # 7 days


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(hash: str, password: str) -> bool:
    try:
        return _ph.verify(hash, password)
    except VerifyMismatchError:
        return False


def make_token(username: str, device_id: str = '') -> str:
    payload = {
        "sub": username,
        "did": device_id,
        "iat": int(time.time()),
        "exp": int(time.time()) + JWT_TTL,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


def decode_token(token: str) -> str:
    """Returns username or raises jwt.InvalidTokenError."""
    payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    return payload["sub"]


def decode_token_full(token: str) -> tuple:
    """Returns (username, device_id) or raises jwt.InvalidTokenError."""
    payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    return payload["sub"], payload.get("did", "")
