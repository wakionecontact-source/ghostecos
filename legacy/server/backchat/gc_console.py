#!/usr/bin/env python3
"""
GhostChat Console Client
Полнофункциональный консольный клиент для тестирования сервера.
Поддерживает несколько юзеров одновременно с живыми WebSocket соединениями.

Запуск: python gc_console.py [--server http://155.212.166.221]
"""

import asyncio
import json
import os
import sys
import time
import uuid
import threading
import requests
import websockets
from datetime import datetime
from typing import Optional, Dict, Any

# Windows: нужен SelectorEventLoop для websockets
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

# ── Настройки ──────────────────────────────────────────────────────────────
DEFAULT_SERVER = "http://155.212.166.221"
WS_URL_TMPL    = "ws://{host}/ws"

# ── Цвета ──────────────────────────────────────────────────────────────────
R  = "\033[0m"
B  = "\033[1m"
DIM= "\033[2m"
C  = {
    "cyan":    "\033[96m",
    "green":   "\033[92m",
    "yellow":  "\033[93m",
    "red":     "\033[91m",
    "magenta": "\033[95m",
    "blue":    "\033[94m",
    "gray":    "\033[90m",
}

def color(text, c="cyan"): return f"{C[c]}{text}{R}"
def bold(text):             return f"{B}{text}{R}"
def dim(text):              return f"{DIM}{text}{R}"
def ok(text):               print(color(f"  ✓ {text}", "green"))
def err(text):              print(color(f"  ✗ {text}", "red"))
def info(text):             print(color(f"  • {text}", "cyan"))
def warn(text):             print(color(f"  ! {text}", "yellow"))

def ts():
    return datetime.now().strftime("%H:%M:%S")

def sep(title=""):
    w = 60
    if title:
        pad = (w - len(title) - 2) // 2
        print(color("─" * pad + f" {title} " + "─" * pad, "blue"))
    else:
        print(color("─" * w, "blue"))


# ── GhostChat Client ────────────────────────────────────────────────────────
class GCClient:
    def __init__(self, server: str, slot: int):
        self.server   = server.rstrip("/")
        self.slot     = slot          # 1 или 2 (номер юзера)
        self.username : Optional[str] = None
        self.token    : Optional[str] = None
        self.device_id: str           = str(uuid.uuid4())
        self.ws_task  : Optional[asyncio.Task] = None
        self.ws       = None
        self.inbox    : list          = []   # входящие сообщения
        self.loop     : Optional[asyncio.AbstractEventLoop] = None
        self.ws_ready = threading.Event()

    # ── HTTP helpers ─────────────────────────────────────────────────────
    def _h(self):
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def _url(self, path): return f"{self.server}{path}"

    def get(self, path, **kw):
        return requests.get(self._url(path), headers=self._h(), timeout=10, **kw)

    def post(self, path, data=None, **kw):
        return requests.post(self._url(path), json=data, headers=self._h(), timeout=10, **kw)

    def delete(self, path, **kw):
        return requests.delete(self._url(path), headers=self._h(), timeout=10, **kw)

    # ── Auth ─────────────────────────────────────────────────────────────
    def register(self, username, password, display_name=""):
        r = self.post("/api/register", {
            "username":     username,
            "password":     password,
            "display_name": display_name or username,
            "x25519_pub":   "CONSOLE_TEST_KEY_X25519",
            "ed25519_pub":  "CONSOLE_TEST_KEY_ED25519",
        })
        return r.json(), r.status_code

    def login(self, username, password):
        r = self.post("/api/login", {
            "username":    username,
            "password":    password,
            "device_id":   self.device_id,
            "device_name": f"GC Console #{self.slot}",
        })
        data = r.json()
        if r.status_code == 200 and data.get("status") == "ok":
            self.token    = data["token"]
            self.username = username
        return data, r.status_code

    # ── Profile ───────────────────────────────────────────────────────────
    def get_user(self, username):
        return self.get(f"/api/user/{username}").json()

    def update_profile(self, **fields):
        return self.post("/api/profile", fields).json()

    # ── Contacts ──────────────────────────────────────────────────────────
    def add_contact(self, username):
        return self.post("/api/contacts", {"username": username}).json()

    def get_contacts(self):
        return self.get("/api/contacts").json()

    # ── Files ─────────────────────────────────────────────────────────────
    def upload_file(self, filepath, to_username):
        with open(filepath, "rb") as f:
            content = f.read()
        filename = os.path.basename(filepath)
        mime     = "application/octet-stream"
        msg_id   = str(uuid.uuid4())
        r = requests.post(
            self._url("/api/files/upload"),
            headers={"Authorization": f"Bearer {self.token}"},
            files={"file": (filename, content, mime)},
            data={
                "to_username": to_username,
                "filename":    filename,
                "mime_type":   mime,
                "msg_id":      msg_id,
            },
            timeout=60,
        )
        return r.json(), r.status_code

    def download_file(self, file_id, save_path):
        r = self.get(f"/api/files/{file_id}")
        if r.status_code == 200:
            with open(save_path, "wb") as f:
                f.write(r.content)
            return True, len(r.content)
        return False, r.text

    # ── Channels ──────────────────────────────────────────────────────────
    def create_channel(self, name, tag, description="", ch_type="group"):
        return self.post("/api/channels", {
            "name": name, "tag": tag,
            "description": description, "type": ch_type,
        }).json()

    def get_channels(self):
        return self.get("/api/channels").json()

    def get_my_channels(self):
        return self.get("/api/channels/my").json()

    def join_channel(self, channel_id):
        return self.post(f"/api/channels/{channel_id}/join").json()

    def leave_channel(self, channel_id):
        return self.post(f"/api/channels/{channel_id}/leave").json()

    def get_channel_messages(self, channel_id):
        return self.get(f"/api/channels/{channel_id}/messages").json()

    def get_channel_members(self, channel_id):
        return self.get(f"/api/channels/{channel_id}/members").json()

    # ── Admin ─────────────────────────────────────────────────────────────
    def set_premium(self, username: str, enabled: bool, admin_token: str, until: int = 0):
        r = requests.post(
            self._url("/api/admin/premium"),
            json={"username": username, "enabled": enabled, "until": until},
            headers={"X-Admin-Key": admin_token},
            timeout=10,
        )
        return r.json(), r.status_code

    # ── Devices ───────────────────────────────────────────────────────────
    def get_devices(self):
        return self.get("/api/devices").json()

    # ── Support ───────────────────────────────────────────────────────────
    def get_support_messages(self):
        return self.get("/api/support/messages").json()

    # ── WebSocket ─────────────────────────────────────────────────────────
    async def _ws_loop(self):
        host = self.server.replace("http://", "").replace("https://", "")
        url  = f"ws://{host}/ws"
        self.ws_ready.clear()
        try:
            async with websockets.connect(url) as ws:
                self.ws = ws
                # Auth
                await ws.send(json.dumps({
                    "type":      "auth",
                    "token":     self.token,
                    "device_id": self.device_id,
                }))
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                if msg.get("type") == "auth_ok":
                    self.ws_ready.set()
                    print(f"\n  {color('WS', 'green')} [{color(self.username,'magenta')}] подключён")
                else:
                    err(f"WS auth fail: {msg}")
                    return

                # Ping loop + receive
                async def pinger():
                    while True:
                        await asyncio.sleep(30)
                        try:
                            await ws.send(json.dumps({"type": "ping"}))
                        except Exception:
                            break

                asyncio.ensure_future(pinger())

                async for raw in ws:
                    pkt = json.loads(raw)
                    t   = pkt.get("type", "")

                    if t == "relay_message":
                        frm  = pkt.get("from_username", "?")
                        body = pkt.get("enc_body", "")
                        mid  = pkt.get("msg_id", "")
                        self.inbox.append(pkt)
                        print(f"\n  [{ts()}] {color('📨 ' + frm,'magenta')} → [{color(self.username,'cyan')}]: {bold(body)}")
                        # relay_ack обратно
                        await ws.send(json.dumps({
                            "type":        "relay_ack",
                            "to_username": frm,
                            "msg_id":      mid,
                        }))

                    elif t == "relay_ack":
                        print(f"  [{ts()}] {color('✓ доставлено','green')} msg_id={pkt.get('msg_id','')[:8]}")

                    elif t == "relay_seen":
                        print(f"  [{ts()}] {color('✓✓ прочитано','cyan')}")

                    elif t == "file_incoming":
                        frm = pkt.get("from_username","?")
                        fn  = pkt.get("filename","?")
                        fid = pkt.get("file_id","")
                        self.inbox.append(pkt)
                        print(f"\n  [{ts()}] {color('📎 файл от ' + frm,'yellow')}: {fn} (id={fid[:8]})")

                    elif t == "peer_online":
                        print(f"  [{ts()}] {color('🟢 онлайн','green')}: {pkt.get('username')}")

                    elif t == "peer_offline":
                        print(f"  [{ts()}] {color('⚫ офлайн','gray')}: {pkt.get('username')}")

                    elif t == "channel_message":
                        ch  = pkt.get("channel_id","?")[:8]
                        frm = pkt.get("from_username","?")
                        body= pkt.get("body","")
                        print(f"\n  [{ts()}] {color('#'+ch,'blue')} {color(frm,'magenta')}: {body}")

                    elif t in ("pong", "auth_ok"):
                        pass

                    else:
                        print(f"  [{ts()}] {dim('WS:')} {dim(json.dumps(pkt)[:120])}")

        except Exception as e:
            print(f"\n  {color('WS disconnect','red')} [{self.username}]: {e}")
        finally:
            self.ws = None
            self.ws_ready.clear()

    def connect_ws(self, loop):
        self.loop = loop
        if self.ws_task and not self.ws_task.done():
            return
        future = asyncio.run_coroutine_threadsafe(self._ws_loop(), loop)
        self.ws_task = future

    def disconnect_ws(self):
        if self.ws_task:
            self.ws_task.cancel(msg="disconnect") if hasattr(self.ws_task, "cancel") else None
        self.ws = None

    async def send_ws(self, pkt: dict):
        if self.ws:
            await self.ws.send(json.dumps(pkt))
        else:
            err("WS не подключён")

    def send_message(self, to: str, body: str):
        """Отправить сообщение через WS (синхронный вызов из главного потока)"""
        if not self.loop or not self.ws:
            err("Нет WS соединения")
            return
        mid = str(uuid.uuid4())
        asyncio.run_coroutine_threadsafe(
            self.send_ws({
                "type":        "relay_message",
                "to_username": to,
                "enc_body":    body,
                "msg_id":      mid,
                "sent_at":     int(time.time() * 1000),
            }),
            self.loop
        ).result(timeout=5)
        return mid

    def send_channel_message(self, channel_id: str, body: str):
        if not self.loop or not self.ws:
            err("Нет WS соединения")
            return
        mid = str(uuid.uuid4())
        asyncio.run_coroutine_threadsafe(
            self.send_ws({
                "type":       "channel_message",
                "channel_id": channel_id,
                "body":       body,
                "msg_id":     mid,
                "sent_at":    int(time.time() * 1000),
            }),
            self.loop
        ).result(timeout=5)
        return mid

    def peer_status(self, username: str):
        if not self.loop or not self.ws:
            err("Нет WS соединения")
            return
        asyncio.run_coroutine_threadsafe(
            self.send_ws({"type": "peer_status_req", "username": username}),
            self.loop
        ).result(timeout=5)


# ── App ─────────────────────────────────────────────────────────────────────
class App:
    def __init__(self, server: str):
        self.server  = server
        self.users   : Dict[int, GCClient] = {}  # slot → client
        self.current : int = 1
        self.loop    : Optional[asyncio.AbstractEventLoop] = None

    def _start_loop(self):
        """Запускает asyncio loop в фоновом потоке"""
        if self.loop and self.loop.is_running():
            return
        if sys.platform == "win32":
            self.loop = asyncio.SelectorEventLoop()
        else:
            self.loop = asyncio.new_event_loop()
        t = threading.Thread(target=self.loop.run_forever, daemon=True)
        t.start()

    def cur(self) -> Optional[GCClient]:
        return self.users.get(self.current)

    def prompt(self) -> str:
        u = self.cur()
        name = u.username or "не залогинен" if u else "нет юзера"
        ws   = color("●WS","green") if (u and u.ws) else color("○","gray")
        return f"\n{ws} [{color(f'U{self.current}','magenta')}:{color(name,'cyan')}] > "

    def run(self):
        self._start_loop()
        sep("GhostChat Console Client")
        print(f"  Сервер: {color(self.server,'yellow')}")
        print(f"  Команды: {dim('help')}")
        sep()

        # Создать 2 слота сразу
        self.users[1] = GCClient(self.server, 1)
        self.users[2] = GCClient(self.server, 2)

        while True:
            try:
                raw = input(self.prompt()).strip()
                if not raw:
                    continue
                parts = raw.split(None, 2)
                cmd   = parts[0].lower()
                args  = parts[1:]
                self.dispatch(cmd, args)
            except (KeyboardInterrupt, EOFError):
                print("\nВыход")
                break

    def dispatch(self, cmd: str, args: list):
        u = self.cur()

        # ── Переключение юзера ────────────────────────────────────────
        if cmd in ("u1", "u2", "user"):
            slot = int(cmd[-1]) if cmd in ("u1","u2") else int(args[0]) if args else 1
            if slot in self.users:
                self.current = slot
                ok(f"Переключён на U{slot}: {self.users[slot].username or 'не залогинен'}")
            else:
                err("Нет такого слота")
            return

        # ── Помощь ────────────────────────────────────────────────────
        if cmd == "help":
            self.print_help()
            return

        # ── Оба юзера ─────────────────────────────────────────────────
        if cmd == "status":
            self.print_status()
            return

        # ── Регистрация ───────────────────────────────────────────────
        if cmd == "reg":
            # reg <username> <password> [display_name]
            if len(args) < 2:
                err("reg <username> <password> [display_name]"); return
            data, code = u.register(args[0], args[1], args[2] if len(args)>2 else "")
            if code in (200, 201):
                ok(f"Зарегистрирован: {args[0]}")
            else:
                err(f"{code}: {data}")
            return

        # ── Логин ─────────────────────────────────────────────────────
        if cmd == "login":
            if len(args) < 2:
                err("login <username> <password>"); return
            data, code = u.login(args[0], args[1])
            if u.token:
                ok(f"Залогинен как {color(args[0],'magenta')}")
                # Автоподключить WS
                u.connect_ws(self.loop)
                u.ws_ready.wait(timeout=5)
            else:
                err(f"{code}: {data}")
            return

        # ── Быстрый старт: создать 2 юзера ───────────────────────────
        if cmd == "quickstart":
            self._quickstart()
            return

        # Дальше — нужен авторизованный юзер
        if not u or not u.token:
            err("Сначала залогинься: login <user> <pass>")
            return

        # ── WS ────────────────────────────────────────────────────────
        if cmd == "ws":
            u.connect_ws(self.loop)
            u.ws_ready.wait(timeout=5)
            return

        if cmd == "wsdis":
            u.disconnect_ws()
            ok("WS отключён")
            return

        # ── Профиль ───────────────────────────────────────────────────
        if cmd == "me":
            data = u.get_user(u.username)
            sep(f"Профиль: {u.username}")
            for k,v in data.items():
                print(f"  {dim(k+':'):20} {v}")
            return

        if cmd == "setname":
            if not args: err("setname <имя>"); return
            data = u.update_profile(display_name=" ".join(args))
            ok(f"Имя обновлено") if data.get("ok") else err(str(data))
            return

        if cmd == "setabout":
            if not args: err("setabout <текст>"); return
            data = u.update_profile(about=" ".join(args))
            ok(f"About обновлён") if data.get("ok") else err(str(data))
            return

        # ── Просмотр юзера ────────────────────────────────────────────
        if cmd == "user":
            if not args: err("user <username>"); return
            data = u.get_user(args[0])
            sep(f"Юзер: {args[0]}")
            for k,v in data.items():
                print(f"  {dim(k+':'):20} {v}")
            return

        # ── Контакты ──────────────────────────────────────────────────
        if cmd == "addcontact":
            if not args: err("addcontact <username>"); return
            data = u.add_contact(args[0])
            ok(f"Контакт добавлен") if data.get("ok") else err(str(data))
            return

        if cmd == "contacts":
            data = u.get_contacts()
            contacts = data.get("contacts", [])
            sep(f"Контакты [{u.username}] ({len(contacts)})")
            for c in contacts:
                print(f"  {color(c.get('username','?'),'magenta'):30} {c.get('display_name','')}")
            if not contacts: info("Пусто")
            return

        # ── Сообщения ─────────────────────────────────────────────────
        if cmd == "msg":
            # msg <to> <текст>
            if len(args) < 2: err("msg <username> <текст>"); return
            mid = u.send_message(args[0], " ".join(args[1:]))
            if mid:
                ok(f"Отправлено → {args[0]}  id={mid[:8]}")
            return

        if cmd == "inbox":
            sep(f"Входящие [{u.username}] ({len(u.inbox)})")
            for m in u.inbox[-10:]:
                t = m.get("type","?")
                if t == "relay_message":
                    print(f"  {color(m.get('from_username','?'),'magenta')}: {m.get('enc_body','')}")
                elif t == "file_incoming":
                    print(f"  {color('FILE','yellow')} от {m.get('from_username','?')}: {m.get('filename','')} id={m.get('file_id','')[:8]}")
            if not u.inbox: info("Пусто")
            return

        if cmd == "seen":
            # seen <to> <msg_id>
            if len(args) < 2: err("seen <to> <msg_id>"); return
            asyncio.run_coroutine_threadsafe(
                u.send_ws({"type":"relay_seen","to_username":args[0],"msg_ids":[args[1]]}),
                self.loop
            ).result(timeout=5)
            ok("Seen отправлен")
            return

        if cmd == "online":
            if not args: err("online <username>"); return
            u.peer_status(args[0])
            return

        # ── Файлы ─────────────────────────────────────────────────────
        if cmd == "upload":
            if len(args) < 2: err("upload <файл> <to_username>"); return
            if not os.path.exists(args[0]): err(f"Файл не найден: {args[0]}"); return
            info(f"Загружаю {args[0]} → {args[1]}...")
            data, code = u.upload_file(args[0], args[1])
            ok(f"Загружен, file_id={data.get('file_id','?')[:16]}") if code==200 else err(f"{code}: {data}")
            return

        if cmd == "download":
            if len(args) < 2: err("download <file_id> <путь_сохранения>"); return
            ok2, result = u.download_file(args[0], args[1])
            ok(f"Скачан: {result} байт → {args[1]}") if ok2 else err(str(result))
            return

        # ── Каналы ────────────────────────────────────────────────────
        if cmd == "createch":
            # createch <name> <tag> [описание]
            if len(args) < 2: err("createch <name> <tag> [описание]"); return
            # args[1] may contain "tag description" merged (split limit=2 at top)
            tag_parts = args[1].split(None, 1)
            tag  = tag_parts[0]
            desc = tag_parts[1] if len(tag_parts) > 1 else (args[2] if len(args) > 2 else "")
            data = u.create_channel(args[0], tag, desc)
            ch = data.get("channel", {})
            ok(f"Канал создан: {ch.get('name')} id={ch.get('id','?')[:8]}") if ch else err(str(data))
            return

        if cmd == "channels":
            data = u.get_channels()
            chs  = data.get("channels", [])
            sep(f"Все каналы ({len(chs)})")
            for c in chs:
                print(f"  {color(c.get('id','?')[:8],'gray')} {color(c.get('name','?'),'cyan'):25} @{c.get('tag','?')} [{c.get('type','?')}]")
            if not chs: info("Пусто")
            return

        if cmd == "mych":
            data = u.get_my_channels()
            chs  = data.get("channels", [])
            sep(f"Мои каналы ({len(chs)})")
            for c in chs:
                print(f"  {color(c.get('id','?')[:8],'gray')} {color(c.get('name','?'),'cyan'):25} @{c.get('tag','?')}")
            if not chs: info("Пусто")
            return

        if cmd == "joinch":
            if not args: err("joinch <channel_id>"); return
            data = u.join_channel(args[0])
            ok("Вступил") if data.get("ok") else info(str(data))
            return

        if cmd == "leavech":
            if not args: err("leavech <channel_id>"); return
            data = u.leave_channel(args[0])
            ok("Вышел") if data.get("ok") else err(str(data))
            return

        if cmd == "chmsg":
            # chmsg <channel_id> <текст>
            if len(args) < 2: err("chmsg <channel_id> <текст>"); return
            mid = u.send_channel_message(args[0], " ".join(args[1:]))
            if mid: ok(f"Отправлено в канал id={mid[:8]}")
            return

        if cmd == "chhist":
            if not args: err("chhist <channel_id>"); return
            data = u.get_channel_messages(args[0])
            msgs = data.get("messages", [])
            sep(f"История канала ({len(msgs)})")
            for m in msgs[-10:]:
                print(f"  {color(m.get('from_username','?'),'magenta')}: {m.get('body','')}")
            return

        if cmd == "chmembers":
            if not args: err("chmembers <channel_id>"); return
            data = u.get_channel_members(args[0])
            members = data.get("members", [])
            sep(f"Участники ({len(members)})")
            for m in members:
                role = color(m.get("role","?"), "yellow")
                print(f"  {color(m.get('username','?'),'magenta'):25} {role}")
            return

        # ── Админ ─────────────────────────────────────────────────────
        if cmd == "setpremium":
            # setpremium <username> <1|0> <admin_token>
            if len(args) < 3: err("setpremium <username> <1|0> <admin_token>"); return
            enabled = args[1] in ("1", "true", "yes", "on")
            data, code = u.set_premium(args[0], enabled, args[2])
            if code == 200:
                state = color("выдана ✓", "green") if enabled else color("снята", "yellow")
                ok(f"Премиум {state} для {color(args[0], 'magenta')}")
            else:
                err(f"{code}: {data}")
            return

        # ── Устройства ────────────────────────────────────────────────
        if cmd == "devices":
            data = u.get_devices()
            devs = data.get("devices", [])
            sep(f"Устройства [{u.username}] ({len(devs)})")
            for d in devs:
                cur = " ← этот" if d.get("device_id") == u.device_id else ""
                print(f"  {color(d.get('device_id','?')[:8],'gray')} {d.get('device_name','?'):25} {dim(d.get('trust_type','?'))}{cur}")
            return

        # ── Поддержка ─────────────────────────────────────────────────
        if cmd == "support":
            data = u.get_support_messages()
            msgs = data.get("messages", [])
            sep(f"Поддержка ({len(msgs)})")
            for m in msgs[-10:]:
                frm = color(m.get("from_username","?"), "magenta")
                print(f"  {frm}: {m.get('body','')}")
            if not msgs: info("Пусто")
            return

        # ── Тест: два юзера ───────────────────────────────────────────
        if cmd == "chat":
            self._chat_mode()
            return

        err(f"Неизвестная команда: {cmd}. Введи 'help'")

    # ── Быстрый старт ────────────────────────────────────────────────────
    def _quickstart(self):
        sep("Quickstart: создаю 2 тестовых юзера")
        ts_s = str(int(time.time()))[-4:]
        for slot in (1, 2):
            u   = self.users[slot]
            usr = f"testuser{slot}_{ts_s}"
            pwd = "testpass123"
            info(f"Регистрирую U{slot}: {usr}")
            data, code = u.register(usr, pwd, f"Test User {slot}")
            if code in (200, 201):
                ok(f"Зарегистрирован")
            elif code == 409:
                warn("Уже существует")
            else:
                err(f"{code}: {data}"); continue

            info(f"Логиню U{slot}: {usr}")
            data, code = u.login(usr, pwd)
            if u.token:
                ok(f"Залогинен")
                u.connect_ws(self.loop)
            else:
                err(f"{code}: {data}"); continue

        # Ждём WS
        for slot in (1,2):
            self.users[slot].ws_ready.wait(timeout=5)

        # Добавляем друг друга в контакты
        u1 = self.users[1]
        u2 = self.users[2]
        if u1.token and u2.token:
            info(f"Добавляю {u2.username} → контакты U1")
            u1.add_contact(u2.username)
            info(f"Добавляю {u1.username} → контакты U2")
            u2.add_contact(u1.username)
            ok("Контакты добавлены")

        sep()
        ok("Quickstart готов!")
        info(f"U1: {self.users[1].username}")
        info(f"U2: {self.users[2].username}")
        info("Переключайся: u1 / u2")
        info("Сообщение: msg <username> <текст>")
        info("Чат-режим: chat")

    # ── Чат-режим ────────────────────────────────────────────────────────
    def _chat_mode(self):
        u1 = self.users[1]
        u2 = self.users[2]
        if not u1.token or not u2.token:
            err("Оба юзера должны быть залогинены. Используй 'quickstart'")
            return
        sep(f"Чат-режим: {u1.username} ↔ {u2.username}")
        print(f"  {dim('Формат:')} {color('1','magenta')} или {color('2','magenta')} для выбора отправителя, затем текст")
        print(f"  {dim('Выход:')} {color('exit','red')}")
        sep()
        sender_slot = 1
        while True:
            try:
                prompt = f"[{color('U'+str(sender_slot),'magenta')}] "
                raw = input(prompt).strip()
                if not raw: continue
                if raw.lower() == "exit": break
                if raw in ("1","2"):
                    sender_slot = int(raw)
                    ok(f"Отправитель: U{sender_slot}")
                    continue
                sender = self.users[sender_slot]
                target = self.users[3 - sender_slot]  # 1→2, 2→1
                mid = sender.send_message(target.username, raw)
                if mid:
                    print(f"  {dim('→')} {color(sender.username,'magenta')}: {raw}")
            except (KeyboardInterrupt, EOFError):
                break
        sep("Выход из чат-режима")

    # ── Статус ───────────────────────────────────────────────────────────
    def print_status(self):
        sep("Статус")
        for slot, u in self.users.items():
            ws_s = color("● WS", "green") if u.ws else color("○", "gray")
            name = u.username or dim("не залогинен")
            print(f"  U{slot}: {color(name,'magenta'):30} {ws_s}")

    # ── Помощь ───────────────────────────────────────────────────────────
    def print_help(self):
        sep("Команды")
        cmds = [
            ("u1 / u2",              "Переключить активного юзера"),
            ("status",               "Статус обоих юзеров"),
            ("quickstart",           "🚀 Создать 2 юзера, залогинить, WS, контакты"),
            ("─ Auth ─",             ""),
            ("reg <user> <pass>",    "Регистрация"),
            ("login <user> <pass>",  "Логин + WS"),
            ("ws / wsdis",           "Подключить / отключить WebSocket"),
            ("─ Профиль ─",          ""),
            ("me",                   "Мой профиль"),
            ("user <username>",      "Профиль другого юзера"),
            ("setname <имя>",        "Изменить display_name"),
            ("setabout <текст>",     "Изменить about"),
            ("─ Контакты ─",         ""),
            ("addcontact <user>",    "Добавить контакт"),
            ("contacts",             "Список контактов"),
            ("─ Сообщения ─",        ""),
            ("msg <to> <текст>",     "Отправить сообщение (WS)"),
            ("inbox",                "Входящие сообщения"),
            ("online <user>",        "Проверить онлайн-статус"),
            ("chat",                 "💬 Интерактивный чат U1↔U2"),
            ("─ Файлы ─",            ""),
            ("upload <файл> <to>",   "Загрузить файл"),
            ("download <id> <путь>", "Скачать файл"),
            ("─ Каналы ─",           ""),
            ("createch <name> <tag>","Создать канал"),
            ("channels",             "Все каналы"),
            ("mych",                 "Мои каналы"),
            ("joinch <id>",          "Вступить в канал"),
            ("leavech <id>",         "Покинуть канал"),
            ("chmsg <id> <текст>",   "Отправить в канал"),
            ("chhist <id>",          "История канала"),
            ("chmembers <id>",       "Участники канала"),
            ("─ Админ ─",             ""),
            ("setpremium <u> <1|0> <token>", "Выдать / снять премиум"),
            ("─ Прочее ─",           ""),
            ("devices",              "Мои устройства"),
            ("support",              "История поддержки"),
            ("help",                 "Эта справка"),
        ]
        for cmd, desc in cmds:
            if desc == "":
                print(f"\n  {color(cmd,'blue')}")
            else:
                print(f"  {color(cmd,'cyan'):30} {dim(desc)}")
        sep()


# ── Точка входа ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    server = DEFAULT_SERVER
    if len(sys.argv) > 1:
        for i, arg in enumerate(sys.argv):
            if arg == "--server" and i+1 < len(sys.argv):
                server = sys.argv[i+1]

    app = App(server)
    app.run()
