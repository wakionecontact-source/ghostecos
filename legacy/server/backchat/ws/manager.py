"""
GhostChat — WebSocket Connection Manager.

Все данные о подключениях — ТОЛЬКО в памяти.
При перезапуске сервера клиенты переподключаются автоматически.

Метаданные (кто подключён, когда, откуда) — не пишутся в БД/логи.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Dict, Optional, Set

from fastapi import WebSocket

log = logging.getLogger("gc.ws")

# ── Инфо о соединении (только в RAM) ──────────────────────────────────────────

class _Conn:
    __slots__ = ("ws", "username", "device_id", "app_version",
                 "last_ping", "is_premium", "authed", "session")

    def __init__(self, ws: WebSocket, username: str = "",
                 device_id: str = "", app_version: str = "",
                 is_premium: bool = False):
        self.ws          = ws
        self.username    = username
        self.device_id   = device_id
        self.app_version = app_version
        self.is_premium  = is_premium
        self.last_ping   = time.monotonic()
        self.authed      = False
        self.session      = None  # Optional[ServerSession] — устанавливается в ws_endpoint


class ConnectionManager:
    """
    Управляет WebSocket соединениями.

    - username → список соединений (мультиустройство)
    - Приоритетная очередь отправки для premium-пользователей
    - Heartbeat timeout: соединение закрывается при молчании > HEARTBEAT_TIMEOUT сек
    """

    def __init__(self, heartbeat_timeout: int = 25):
        # username → list[_Conn]
        self._conns: Dict[str, list[_Conn]] = {}
        # id(ws) → _Conn (для быстрого обратного поиска)
        self._by_id: Dict[int, _Conn] = {}
        # online usernames
        self._online: Set[str] = set()
        self._lock  = asyncio.Lock()
        self._hb_timeout = heartbeat_timeout

    # ── Подключение / отключение ──────────────────────────────────────────────

    async def connect(self, ws: WebSocket) -> _Conn:
        await ws.accept()
        conn = _Conn(ws)
        async with self._lock:
            self._by_id[id(ws)] = conn
        return conn

    async def authenticate(self, conn: _Conn, username: str, device_id: str,
                           app_version: str, is_premium: bool):
        async with self._lock:
            conn.username    = username
            conn.device_id   = device_id
            conn.app_version = app_version
            conn.is_premium  = is_premium
            conn.authed      = True
            if username not in self._conns:
                self._conns[username] = []
            self._conns[username].append(conn)
            was_offline = username not in self._online
            self._online.add(username)
        return was_offline  # True если только что появился онлайн

    async def disconnect(self, conn: _Conn) -> bool:
        """Возвращает True если пользователь полностью офлайн."""
        async with self._lock:
            self._by_id.pop(id(conn.ws), None)
            if conn.username and conn.username in self._conns:
                try:
                    self._conns[conn.username].remove(conn)
                except ValueError:
                    pass
                if not self._conns[conn.username]:
                    del self._conns[conn.username]
                    self._online.discard(conn.username)
                    return True
        return False

    # ── Статус ────────────────────────────────────────────────────────────────

    def is_online(self, username: str) -> bool:
        return username in self._online

    def online_users(self) -> Set[str]:
        return set(self._online)

    def get_connections(self, username: str) -> list[_Conn]:
        return list(self._conns.get(username, []))

    def update_ping(self, conn: _Conn):
        conn.last_ping = time.monotonic()

    # ── Отправка сообщений ────────────────────────────────────────────────────

    async def send(self, conn: _Conn, data: dict) -> bool:
        """
        Отправить JSON одному соединению.
        Если у соединения есть сессионный ключ — шифрует AES-256-GCM.
        False при ошибке.
        """
        try:
            if conn.session is not None and conn.session.key is not None:
                from ws.crypto import encrypt_packet
                payload = encrypt_packet(conn.session.key, data)
                await conn.ws.send_text(json.dumps({"e": payload}, ensure_ascii=False))
            else:
                await conn.ws.send_text(json.dumps(data, ensure_ascii=False))
            return True
        except Exception:
            return False

    async def send_to_user(self, username: str, data: dict,
                           exclude_conn: Optional[_Conn] = None) -> int:
        """
        Отправить всем соединениям пользователя.
        Premium-пользователи получают без задержки.
        Возвращает количество успешных отправок.
        """
        conns = self.get_connections(username)
        if not conns:
            return 0
        sent = 0
        dead = []
        for conn in conns:
            if conn is exclude_conn:
                continue
            ok = await self.send(conn, data)
            if ok:
                sent += 1
            else:
                dead.append(conn)
        for conn in dead:
            await self.disconnect(conn)
        return sent

    async def broadcast(self, usernames: list[str], data: dict,
                        exclude_user: Optional[str] = None):
        """Разослать список пользователей."""
        tasks = []
        for u in usernames:
            if u == exclude_user:
                continue
            if self.is_online(u):
                tasks.append(self.send_to_user(u, data))
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    # ── Heartbeat ─────────────────────────────────────────────────────────────

    async def check_heartbeats(self) -> list[str]:
        """
        Проверяет все соединения на timeout.
        Возвращает список username которые стали офлайн.
        """
        now = time.monotonic()
        to_close: list[_Conn] = []

        async with self._lock:
            for conns in list(self._conns.values()):
                for conn in conns:
                    if now - conn.last_ping > self._hb_timeout:
                        to_close.append(conn)

        went_offline = []
        for conn in to_close:
            try:
                await conn.ws.close()
            except Exception:
                pass
            was_last = await self.disconnect(conn)
            if was_last and conn.username:
                went_offline.append(conn.username)

        return went_offline

    # ── Статистика (без метаданных) ────────────────────────────────────────────

    def stats(self) -> dict:
        return {
            "online_users": len(self._online),
            "total_connections": sum(len(v) for v in self._conns.values()),
        }


# Глобальный менеджер
manager = ConnectionManager(heartbeat_timeout=25)
