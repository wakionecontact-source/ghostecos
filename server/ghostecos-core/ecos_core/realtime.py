"""In-process websocket hub shared by routers in one API process.

This preserves the current single-process notification behavior. Separate API
processes still need a cross-process event bus before traffic is split.
"""
import asyncio
from collections import defaultdict
from fastapi import WebSocket


class _WSHub:
    def __init__(self):
        self._by_uid: dict = defaultdict(set)
        self._crypto: dict = {}
        self._lock = asyncio.Lock()
        # Главный event loop — фиксируем при первом register (где есть running loop).
        # КРИТИЧНО: FastAPI выполняет `def` (sync) ручки в threadpool, у этих потоков
        # СВОЙ asyncio loop НЕ существует. asyncio.get_event_loop() из них бросает
        # RuntimeError → старый код silently возвращал и broadcast не работал.
        # Теперь сохраняем main loop здесь и шлём корутины через run_coroutine_threadsafe.
        self._loop = None

    async def register(self, uid: int, ws: WebSocket):
        try:
            running = asyncio.get_running_loop()
            # TestClient creates a fresh loop per portal; production normally
            # has one long-lived loop. Refreshing a closed loop keeps sync HTTP
            # handlers able to notify sockets in both environments.
            if self._loop is None or self._loop.is_closed():
                self._loop = running
        except RuntimeError:
            pass
        async with self._lock:
            self._by_uid[uid].add(ws)

    async def unregister(self, uid: int, ws: WebSocket):
        async with self._lock:
            self._by_uid[uid].discard(ws)
            if not self._by_uid[uid]:
                self._by_uid.pop(uid, None)
            self._crypto.pop(ws, None)

    def set_crypto(self, ws: WebSocket, aesgcm):
        """Зарегистрировать AES-GCM ключ для исходящих сообщений на этом сокете.
        Вызывается после успешного cs.hello handshake."""
        self._crypto[ws] = aesgcm

    async def _send(self, ws: WebSocket, payload: dict):
        try:
            aesgcm = self._crypto.get(ws)
            if aesgcm is not None:
                import os as _os, json as _json, base64 as _b64
                pt = _json.dumps(payload).encode('utf-8')
                iv = _os.urandom(12)
                ct = aesgcm.encrypt(iv, pt, None)
                payload = {"type": "cs.enc", "data": _b64.b64encode(iv + ct).decode()}
            await ws.send_json(payload)
        except Exception as _e:
            import logging as _lg
            _lg.getLogger('gc.ws').warning('ws_send failed: %s', _e)

    def _schedule(self, coro):
        """Безопасно запустить корутину независимо от того, в каком потоке
        мы находимся (async ручка → main loop running, sync ручка → threadpool)."""
        loop = self._loop
        if loop is None:
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                coro.close()
                return
        if loop.is_running():
            try:
                # send_to is also called from async WS handlers. Avoid the
                # cross-thread Future bridge in that case; create_task is
                # cheaper and lets the notification start in the same tick.
                try:
                    running = asyncio.get_running_loop()
                except RuntimeError:
                    running = None
                if running is loop:
                    loop.create_task(coro)
                else:
                    asyncio.run_coroutine_threadsafe(coro, loop)
            except Exception:
                try: coro.close()
                except Exception: pass
        else:
            try: coro.close()
            except Exception: pass

    _PUBLIC_BROADCAST = {"post.new", "post.edit", "post.delete", "post.react",
                          "post.comment", "post.vote", "presence"}

    def broadcast(self, ev_type: str, data: dict):
        """Послать событие подключённым. Приватные (notif.*, chat.*) — только залогиненным.
        Гости (uid=0) получают только публичные события из _PUBLIC_BROADCAST."""
        payload = {"type": ev_type, "data": data}
        is_public = ev_type in self._PUBLIC_BROADCAST
        for uid, sockets in list(self._by_uid.items()):
            if uid == 0 and not is_public:
                continue  # гостям приватные события не показываем
            for ws in list(sockets):
                self._schedule(self._send(ws, payload))

    def send_to(self, uid: int, ev_type: str, data: dict):
        """Послать конкретному юзеру (всем его открытым вкладкам/устройствам).
        Работает из любого потока: async ручки И sync ручки (FastAPI threadpool)."""
        if uid is None or uid <= 0:
            return
        payload = {"type": ev_type, "data": data}
        for ws in list(self._by_uid.get(uid, ())):
            self._schedule(self._send(ws, payload))

ws_hub = _WSHub()
