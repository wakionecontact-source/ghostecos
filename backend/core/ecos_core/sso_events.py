"""Signed GhostID grant revocations with a durable delivery outbox.

These Security Event Tokens are not login/ID tokens. Delivery is configured
per registered client; no endpoint is guessed or enabled by this module.
"""
from __future__ import annotations

import base64
from contextlib import asynccontextmanager
import hashlib
import http.client
import ipaddress
import json
import logging
import os
from pathlib import Path
import secrets
import socket
import ssl
import tempfile
import threading
import time
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import APIRouter, Request

EVENT = "https://ghostecos.duckdns.org/events/grant-revoked"
router = APIRouter(prefix="/api/sso", tags=["GhostID security events"])
log = logging.getLogger("ghostid.events")


def schema(connection):
    connection.executescript("""
        CREATE TABLE IF NOT EXISTS authorization_grants (
            user_id INTEGER NOT NULL, client_id TEXT NOT NULL,
            grant_id TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL,
            PRIMARY KEY(user_id, client_id)
        );
        CREATE TABLE IF NOT EXISTS revocation_outbox (
            event_id TEXT PRIMARY KEY, client_id TEXT NOT NULL,
            subject TEXT NOT NULL, grant_id TEXT NOT NULL,
            occurred_at INTEGER NOT NULL, reason TEXT NOT NULL,
            endpoint TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NOT NULL DEFAULT 0,
            delivered_at INTEGER, last_error TEXT
        );
        CREATE INDEX IF NOT EXISTS revocation_due
            ON revocation_outbox(delivered_at, next_attempt_at);
    """)
    for table in ("entrances", "access_tokens"):
        columns = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        if "grant_id" not in columns:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN grant_id TEXT")


def ensure_grant(connection, user_id, client_id, now):
    row = connection.execute(
        "SELECT grant_id FROM authorization_grants WHERE user_id=? AND client_id=?",
        (user_id, client_id),
    ).fetchone()
    if row:
        return row["grant_id"]
    grant_id = secrets.token_urlsafe(32)
    connection.execute("INSERT INTO authorization_grants VALUES (?, ?, ?, ?)",
                       (user_id, client_id, grant_id, now))
    return grant_id


def queue_revocation(connection, config, user_id, grant_id, reason="user_revoked"):
    connection.execute("""INSERT INTO revocation_outbox
        (event_id,client_id,subject,grant_id,occurred_at,reason,endpoint)
        VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (secrets.token_urlsafe(32), config["client_id"], str(user_id), grant_id,
         int(time.time()), reason, config.get("revocation_uri", "")))


def revoke_client_grants(connection, config):
    rows = connection.execute(
        "SELECT user_id,grant_id FROM authorization_grants WHERE client_id=?",
        (config["client_id"],),
    ).fetchall()
    for row in rows:
        queue_revocation(connection, config, row["user_id"], row["grant_id"],
                         "client_configuration_changed")
    connection.execute("DELETE FROM authorization_grants WHERE client_id=?",
                       (config["client_id"],))


def _base64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _key():
    path = Path(os.getenv("GE_SSO_EVENT_KEY_PATH",
                          "/opt/ghostecos-core/private/sso-event-signing.key"))
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        private = Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
            serialization.NoEncryption())
        fd, temporary = tempfile.mkstemp(prefix=".event-key-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(private)
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(temporary, path)
            except FileExistsError:
                pass
        finally:
            os.unlink(temporary)
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise RuntimeError("Signing key must be a private regular file")
    private = Ed25519PrivateKey.from_private_bytes(path.read_bytes())
    public = private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    kid = _base64(hashlib.sha256(public).digest()[:16])
    return private, {"kty": "OKP", "crv": "Ed25519", "x": _base64(public),
                     "kid": kid, "use": "sig", "alg": "EdDSA"}


@router.get("/revocation-keys")
def public_keys(request: Request):
    from ecos_core import service_sso as sso
    sso._limit(request, "revocation-keys", 120)
    return {"keys": [_key()[1]]}


def signed_event(row):
    from ecos_core import service_sso as sso
    key, jwk = _key()
    now = int(time.time())
    header = {"alg": "EdDSA", "kid": jwk["kid"], "typ": "secevent+jwt"}
    payload = {"iss": sso._issuer(), "aud": [row["client_id"]],
               "sub": row["subject"], "jti": row["event_id"],
               "iat": now, "exp": now + 300,
               "events": {EVENT: {"grant_id": row["grant_id"],
                                  "occurred_at": row["occurred_at"],
                                  "reason": row["reason"]}}}
    encoded = ".".join(_base64(json.dumps(part, separators=(",", ":")).encode())
                       for part in (header, payload))
    return encoded + "." + _base64(key.sign(encoded.encode("ascii")))


class _PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, address, port):
        super().__init__(host, port=port, timeout=5, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, self.port), timeout=self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def push(endpoint, token):
    """HTTPS only, no redirects/proxies, public DNS addresses pinned for TLS."""
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.fragment):
        raise ValueError("Invalid delivery endpoint")
    addresses = list(dict.fromkeys(info[4][0] for info in
        socket.getaddrinfo(parsed.hostname, parsed.port or 443, type=socket.SOCK_STREAM)))
    if not addresses or any(not ipaddress.ip_address(address).is_global
                            for address in addresses):
        raise ValueError("Delivery requires public addresses")
    target = parsed.path or "/"
    if parsed.query:
        target += "?" + parsed.query
    for address in addresses[:2]:
        connection = _PinnedHTTPS(parsed.hostname, address, parsed.port or 443)
        try:
            connection.request("POST", target, body=token.encode("ascii"), headers={
                "Content-Type": "application/secevent+jwt", "Accept": "application/json"})
            response = connection.getresponse()
            response.read(1024)
            return response.status
        except OSError:
            continue
        finally:
            connection.close()
    raise OSError("Delivery unavailable")


def deliver_batch(send=push, limit=10):
    from ecos_core import service_sso as sso
    now = int(time.time())
    claimed = []
    with sso._db() as connection:
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute("""SELECT * FROM revocation_outbox
            WHERE delivered_at IS NULL AND next_attempt_at<=?
            ORDER BY occurred_at,event_id LIMIT ?""", (now, limit)).fetchall()
        for item in rows:
            row = dict(item)
            config_row = connection.execute("SELECT config FROM clients WHERE client_id=?",
                                            (row["client_id"],)).fetchone()
            config = json.loads(config_row["config"]) if config_row else {}
            endpoint = row["endpoint"] or config.get("revocation_uri", "")
            if not endpoint:
                connection.execute("UPDATE revocation_outbox SET next_attempt_at=? WHERE event_id=?",
                                   (now + 30, row["event_id"]))
                continue
            row["endpoint"] = endpoint
            connection.execute("""UPDATE revocation_outbox
                SET attempts=attempts+1,next_attempt_at=? WHERE event_id=?""",
                (now + 120, row["event_id"]))
            claimed.append(row)
    delivered = 0
    for row in claimed:
        result = "delivery_failed"
        try:
            success = send(row["endpoint"], signed_event(row)) == 202
            if success:
                result = None
        except Exception:
            success = False
        with sso._db() as connection:
            connection.execute("""UPDATE revocation_outbox
                SET delivered_at=?,last_error=?,next_attempt_at=? WHERE event_id=?""",
                (int(time.time()) if success else None, result,
                 int(time.time()) + min(3600, 5 * 2 ** min(row["attempts"], 9)), row["event_id"]))
        delivered += int(success)
    return delivered


def install(app):
    app.include_router(router)
    stop = threading.Event()

    def worker():
        while not stop.is_set():
            try:
                deliver_batch()
            except Exception:
                log.warning("GhostID event delivery unavailable")
            stop.wait(2)

    def start():
        if os.getenv("GE_SSO_EVENT_DELIVERY", "1") == "1":
            from ecos_core import service_sso as sso
            with sso._db():
                pass
            _key()
            app.state.ghostid_event_thread = threading.Thread(
                target=worker, name="ghostid-events", daemon=True)
            app.state.ghostid_event_thread.start()

    def shutdown():
        stop.set()
        thread = getattr(app.state, "ghostid_event_thread", None)
        if thread:
            thread.join(timeout=1)

    previous_lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(application):
        async with previous_lifespan(application) as state:
            start()
            try:
                yield state
            finally:
                shutdown()

    app.router.lifespan_context = lifespan
