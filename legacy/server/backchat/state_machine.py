"""
Centralized state tracking for GhostChat server.
Every state change is logged.
"""
import logging
from enum import Enum
from typing import Dict, Optional

log = logging.getLogger("ghostchat.state")


# ── State enums ───────────────────────────────────────────────────────────────

class ClientState(str, Enum):
    """Per-user WebSocket connection state."""
    disconnected = "disconnected"
    authenticating = "authenticating"
    connected = "connected"
    background = "background"  # app in background, still connected


class MsgRelayState(str, Enum):
    """Per-message relay state on server side."""
    received = "received"           # server got relay_message from sender
    stored_offline = "stored_offline"  # recipient offline, saved to DB
    relayed = "relayed"             # forwarded to recipient's WS
    delivered = "delivered"          # recipient sent relay_ack
    seen = "seen"                   # recipient sent relay_seen
    failed = "failed"               # relay error


class FileState(str, Enum):
    """Per-file lifecycle on server."""
    uploaded = "uploaded"            # file received from sender
    notified = "notified"           # recipient notified about file
    downloaded = "downloaded"        # recipient downloaded the file
    acked = "acked"                 # recipient confirmed, file deleted
    expired = "expired"             # TTL passed, file deleted
    rerequest_sent = "rerequest_sent"  # asked sender to re-upload


# ── State holders ─────────────────────────────────────────────────────────────

class StateHolder:
    """Single-value state with logging."""
    def __init__(self, tag: str, name: str, initial):
        self.tag = tag
        self.name = name
        self._value = initial

    @property
    def value(self):
        return self._value

    def set(self, new_value):
        if new_value == self._value:
            return
        prev = self._value
        self._value = new_value
        log.info("[%s] %s: %s → %s", self.tag, self.name, prev, new_value)


class KeyedStateHolder:
    """Per-entity state (per user, per message, per file) with logging."""
    def __init__(self, tag: str, name: str, default):
        self.tag = tag
        self.name = name
        self.default = default
        self._map: Dict[str, object] = {}

    def get(self, key: str):
        return self._map.get(key, self.default)

    def set(self, key: str, new_value):
        prev = self._map.get(key, self.default)
        if new_value == prev:
            return
        self._map[key] = new_value
        short = key[:12] + "…" if len(key) > 12 else key
        log.info("[%s] %s[%s]: %s → %s", self.tag, self.name, short, prev, new_value)

    def remove(self, key: str):
        self._map.pop(key, None)

    def clear(self):
        self._map.clear()


# ── Server state singleton ────────────────────────────────────────────────────

class ServerState:
    def __init__(self):
        # Per-user connection state
        self.client = KeyedStateHolder("ws", "Клиент", ClientState.disconnected)
        # Per-message relay state
        self.msg = KeyedStateHolder("msg", "Сообщение", MsgRelayState.received)
        # Per-file state
        self.file = KeyedStateHolder("file", "Файл", FileState.uploaded)

    def reset_user(self, username: str):
        """Clean up all state for a user on disconnect."""
        self.client.set(username, ClientState.disconnected)


server_state = ServerState()
