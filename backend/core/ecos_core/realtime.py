"""In-process WS-hub всех роутеров процесса; при разделении процессов нужен межпроцессный шина."""
import asyncio
from collections import defaultdict
from fastapi import WebSocket


class _WSHub:
    def __init__(self):
        self._by_uid: dict = defaultdict(set)
        self._crypto: dict = {}
        self._lock = asyncio.Lock()
        # Main loop фиксируем при первом register: sync-ручки в threadpool без своего
        # loop, get_event_loop() кидал RuntimeError и broadcast молча не работал.
        self._loop = None

    async def register(self, uid: int, ws: WebSocket):
        try:
            running = asyncio.get_running_loop()
            # TestClient создаёт свежий loop на портал; обновление закрытого loop сохраняет notify для sync-ручки.
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
        """Регистрирует AES-GCM ключ сокета после успешного cs.hello handshake."""
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
        """Запускает корутину из любого потока: async ручка → main loop, sync → threadpool."""
        loop = self._loop
        if loop is None:
            try:
                loop = asyncio.get_event_loop()
            except RuntimeError:
                coro.close()
                return
        if loop.is_running():
            try:
                # Из async WS-хендлеров без моста Future: create_task дешевле и стартует в том же тике.
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
        """Шлёт событие всем; приватные (notif.*, chat.*) — только залогиненным."""
        payload = {"type": ev_type, "data": data}
        is_public = ev_type in self._PUBLIC_BROADCAST
        for uid, sockets in list(self._by_uid.items()):
            if uid == 0 and not is_public:
                continue  # гостям приватные события не показываем
            for ws in list(sockets):
                self._schedule(self._send(ws, payload))

    def send_to(self, uid: int, ev_type: str, data: dict):
        """Шлёт юзеру во все его вкладки/устройства; работает из любого потока."""
        if uid is None or uid <= 0:
            return
        payload = {"type": ev_type, "data": data}
        for ws in list(self._by_uid.get(uid, ())):
            self._schedule(self._send(ws, payload))

ws_hub = _WSHub()
