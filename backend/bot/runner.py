"""
Долгоживущий процесс бота GhostChat: держит WS-коннект к /api/soc/ws,
на входящие chat.new — расшифровывает, зовёт qa_bot.answer(), шифрует
ответ обратно, шлёт через POST /api/chat/send + ack.

Деплой: systemd unit ghostbot.service (см. ghostbot.service рядом).
"""
import asyncio
import base64
import json
import logging
import os
import sys
import time

import requests
import websockets

sys.path.insert(0, os.environ.get("QA_BOT_DIR", "/opt/ghostchat/bot/qa_bot"))

from crypto_p256 import encrypt_for, decrypt_from  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("ghostbot")

API_BASE = "http://127.0.0.1:8002"
WS_URL = "ws://127.0.0.1:8002/api/soc/ws"
SECRETS_PATH = os.path.join(os.path.dirname(__file__), "bot_secrets.env")


def load_secrets() -> dict:
    d = {}
    with open(SECRETS_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            d[k] = v
    return d


class Bot:
    def __init__(self):
        secrets = load_secrets()
        self.username = secrets["BOT_USERNAME"]
        self.password = secrets["BOT_PASSWORD"]
        self.token = secrets["BOT_TOKEN"]
        self.priv_raw = base64.b64decode(secrets["BOT_PRIV_KEY_B64"])
        self._pub_cache: dict[str, bytes] = {}
        self._executor_loop = asyncio.get_event_loop
        self.model = None
        self.cfg = None
        self.tok = None

    def load_qa_bot(self):
        from ask import load_model, answer  # type: ignore
        from tokenizers import Tokenizer  # type: ignore
        import ask as ask_module  # type: ignore

        log.info("loading qa_bot model...")
        self.model, self.cfg = load_model()
        self.tok = Tokenizer.from_file(ask_module.TOKENIZER_FILE)
        self._answer_fn = answer
        log.info("qa_bot model loaded.")

    def relogin(self):
        r = requests.post(
            f"{API_BASE}/api/soc/login",
            json={
                "username": self.username,
                "password": self.password,
                "device_id": "ghostbot-runner",
                "device_name": "GhostBot Runner",
            },
            timeout=15,
        )
        r.raise_for_status()
        self.token = r.json()["token"]
        log.info("re-logged in, fresh token acquired.")

    def get_peer_pub(self, username: str) -> bytes:
        cached = self._pub_cache.get(username)
        if cached is not None:
            return cached
        r = requests.get(
            f"{API_BASE}/api/chat/keys/{username}",
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=15,
        )
        r.raise_for_status()
        pub_b64 = r.json()["x25519_pub"]
        pub_raw = base64.b64decode(pub_b64)
        self._pub_cache[username] = pub_raw
        return pub_raw

    def send_reply(self, to_username: str, text: str):
        pub = self.get_peer_pub(to_username)
        payload = json.dumps({"type": "msg", "text": text})
        ciphertext = encrypt_for(self.priv_raw, pub, payload)
        r = requests.post(
            f"{API_BASE}/api/chat/send",
            json={"to_username": to_username, "ciphertext": ciphertext},
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=15,
        )
        r.raise_for_status()

    def ack(self, msg_id: int):
        try:
            requests.post(
                f"{API_BASE}/api/chat/ack",
                json={"ids": [msg_id]},
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "X-Device-Id": "ghostbot-runner",
                },
                timeout=15,
            )
        except Exception as e:
            log.warning("ack failed: %s", e)

    async def handle_chat_new(self, data: dict):
        from_username = data.get("from_username")
        msg_id = data.get("id")
        ciphertext = data.get("ciphertext")
        if not from_username or not ciphertext:
            return
        try:
            pub = self.get_peer_pub(from_username)
            plain = decrypt_from(self.priv_raw, pub, ciphertext)
            obj = json.loads(plain)
        except Exception as e:
            log.warning("decrypt failed from=%s: %s", from_username, e)
            return
        if obj.get("type") != "msg":
            return  # edit/delete/file/voice — бот пока отвечает только на текст
        question = (obj.get("text") or "").strip()
        if not question:
            return
        log.info("Q from @%s: %s", from_username, question[:120])
        if msg_id is not None:
            self.ack(msg_id)
        loop = asyncio.get_running_loop()
        try:
            text, _n_sources = await loop.run_in_executor(
                None, self._answer_fn, self.model, self.cfg, self.tok, question
            )
        except Exception as e:
            log.exception("answer() failed")
            text = "Извини, у меня внутренняя ошибка — попробуй переформулировать."
        try:
            await loop.run_in_executor(None, self.send_reply, from_username, text)
            log.info("A to @%s: %s", from_username, text[:120])
        except Exception as e:
            log.warning("send_reply failed: %s", e)

    async def run(self):
        self.load_qa_bot()
        backoff = 2
        while True:
            try:
                await self._connect_once()
                backoff = 2  # успешная сессия — сброс backoff
            except Exception as e:
                log.warning("ws session ended: %s", e)
            log.info("reconnecting in %ss...", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60)

    async def _connect_once(self):
        url = f"{WS_URL}?token={self.token}"
        async with websockets.connect(url, ping_interval=None) as ws:
            log.info("ws connected as @%s", self.username)
            last_ping = time.monotonic()
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=30)
                except asyncio.TimeoutError:
                    msg = None
                now = time.monotonic()
                if now - last_ping > 45:
                    await ws.send("ping")
                    last_ping = now
                if msg is None:
                    continue
                if msg in ("pong", "hello"):
                    continue
                if not msg or msg[0] != "{":
                    continue
                try:
                    ev = json.loads(msg)
                except Exception:
                    continue
                t = ev.get("type")
                if t == "auth_fail" or t == "unauthorized":
                    log.warning("token rejected, re-logging in")
                    self.relogin()
                    return
                if t == "chat.new":
                    await self.handle_chat_new(ev.get("data") or {})
                # chat.echo/hello/peer_online/etc — игнорируем


def main():
    bot = Bot()
    asyncio.run(bot.run())


if __name__ == "__main__":
    main()
