"""Состояния GhostChat: каждое изменение логируется."""
import logging
from enum import Enum
from typing import Dict, Optional

log = logging.getLogger("ghostchat.state")


# ── Перечисления состояний ────────────────────────────────────────────────────

class ClientState(str, Enum):
    """Состояние WS-соединения пользователя."""
    disconnected = "disconnected"
    authenticating = "authenticating"
    connected = "connected"
    background = "background"  # приложение в фоне, но соединение живо


class MsgRelayState(str, Enum):
    """Состояние доставки сообщения на сервере."""
    received = "received"           # сервер получил relay_message
    stored_offline = "stored_offline"  # получатель офлайн, сообщение в БД
    relayed = "relayed"             # передано в WS получателя
    delivered = "delivered"          # получен relay_ack
    seen = "seen"                   # получен relay_seen
    failed = "failed"               # ошибка релея


class FileState(str, Enum):
    """Жизненный цикл файла на сервере."""
    uploaded = "uploaded"            # файл получен от отправителя
    notified = "notified"           # получатель уведомлён о файле
    downloaded = "downloaded"        # получатель скачал файл
    acked = "acked"                 # подтверждение, файл удалён
    expired = "expired"             # истёк TTL, файл удалён
    rerequest_sent = "rerequest_sent"  # запрошена повторная загрузка


# ── Хранилища состояний ───────────────────────────────────────────────────────

class StateHolder:
    """Одиночное значение состояния с логированием."""
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
    """Состояние по каждой сущности (юзер/сообщение/файл) с логированием."""
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


# ── Одиночка состояния сервера ────────────────────────────────────────────────

class ServerState:
    def __init__(self):
        # Состояние соединений пользователей
        self.client = KeyedStateHolder("ws", "Клиент", ClientState.disconnected)
        # Состояние доставки сообщений
        self.msg = KeyedStateHolder("msg", "Сообщение", MsgRelayState.received)
        # Состояние файлов
        self.file = KeyedStateHolder("file", "Файл", FileState.uploaded)

    def reset_user(self, username: str):
        """Чистим все состояния пользователя при отключении."""
        self.client.set(username, ClientState.disconnected)


server_state = ServerState()
