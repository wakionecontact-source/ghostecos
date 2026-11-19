"""Централизованный трекинг состояний сервера GhostChat; каждое изменение логируется."""
import logging
from enum import Enum
from typing import Dict, Optional

log = logging.getLogger("ghostchat.state")


# ── Enum'ы состояний ───────────────────────────────────────────────────────

class ClientState(str, Enum):
    """Состояние WS-соединения пользователя."""
    disconnected = "disconnected"
    authenticating = "authenticating"
    connected = "connected"
    background = "background"  # приложение в фоне, соединение живо


class MsgRelayState(str, Enum):
    """Состояние доставки сообщения на сервере."""
    received = "received"           # сервер принял relay_message
    stored_offline = "stored_offline"  # получатель офлайн, лежит в БД
    relayed = "relayed"             # ушло в WS получателя
    delivered = "delivered"          # получатель прислал relay_ack
    seen = "seen"                   # получатель прислал relay_seen
    failed = "failed"               # ошибка доставки


class FileState(str, Enum):
    """Жизненный цикл файла на сервере."""
    uploaded = "uploaded"            # файл получен от отправителя
    notified = "notified"           # получатель уведомлён
    downloaded = "downloaded"        # получатель скачал файл
    acked = "acked"                 # получатель подтвердил, файл удалён
    expired = "expired"             # истёк TTL, файл удалён
    rerequest_sent = "rerequest_sent"  # запросили переотправку у отправителя


# ── Хранилища состояний ────────────────────────────────────────────────────

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


# ── Синглтон состояния сервера ────────────────────────────────────────────

class ServerState:
    def __init__(self):
        # состояние соединения по пользователям
        self.client = KeyedStateHolder("ws", "Клиент", ClientState.disconnected)
        # состояние доставки по сообщениям
        self.msg = KeyedStateHolder("msg", "Сообщение", MsgRelayState.received)
        # состояние по файлам
        self.file = KeyedStateHolder("file", "Файл", FileState.uploaded)

    def reset_user(self, username: str):
        """Чистим все состояния пользователя при отключении."""
        self.client.set(username, ClientState.disconnected)


server_state = ServerState()
