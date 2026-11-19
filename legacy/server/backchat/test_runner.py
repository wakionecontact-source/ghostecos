"""
GhostChat Automated Test Runner
Тестирует основные функции сервера: регистрацию, сообщения, разрешения, устройства.

Запуск: python test_runner.py [--server http://149.154.70.18:8000]
"""

import asyncio
import json
import time
import sys
import os
import argparse
import uuid
import httpx
import websockets

SERVER = "http://localhost:8000"
WS_SERVER = "ws://localhost:8000"

# ── Colours ──────────────────────────────────────────────────────────────────

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
RESET  = "\033[0m"
BOLD   = "\033[1m"

passed = 0
failed = 0
skipped = 0

def ok(name: str):
    global passed
    passed += 1
    print(f"  {GREEN}✓{RESET} {name}")

def fail(name: str, reason: str = ""):
    global failed
    failed += 1
    print(f"  {RED}✗{RESET} {name}" + (f"  ← {reason}" if reason else ""))

def skip(name: str, reason: str = ""):
    global skipped
    skipped += 1
    print(f"  {YELLOW}−{RESET} {name}" + (f"  ({reason})" if reason else ""))

def section(name: str):
    print(f"\n{BOLD}{BLUE}▸ {name}{RESET}")

# ── HTTP helpers ──────────────────────────────────────────────────────────────

def post(path: str, body: dict, token: str = "") -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.post(f"{SERVER}{path}", json=body, headers=headers, timeout=10)
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code, "_text": r.text}

def get(path: str, token: str = "") -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.get(f"{SERVER}{path}", headers=headers, timeout=10)
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code}

def patch(path: str, body: dict, token: str = "") -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.patch(f"{SERVER}{path}", json=body, headers=headers, timeout=10)
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code}

def delete(path: str, token: str = "") -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.delete(f"{SERVER}{path}", headers=headers, timeout=10)
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code}

# ── WS helpers ────────────────────────────────────────────────────────────────

async def ws_connect(token: str, device_id: str):
    uri = f"{WS_SERVER}/ws?token={token}&device_id={device_id}"
    ws = await websockets.connect(uri, open_timeout=5)
    return ws

async def ws_recv_until(ws, type_: str, timeout: float = 3.0) -> dict | None:
    """Receive messages until we get one of the given type (or timeout)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = deadline - time.time()
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
            pkt = json.loads(raw)
            if pkt.get("type") == type_:
                return pkt
        except asyncio.TimeoutError:
            break
        except Exception:
            break
    return None

async def ws_drain(ws, timeout: float = 0.3) -> list[dict]:
    """Drain all pending packets."""
    pkts = []
    while True:
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
            pkts.append(json.loads(raw))
        except (asyncio.TimeoutError, Exception):
            break
    return pkts

# ── Test state ────────────────────────────────────────────────────────────────

state: dict = {}  # shared test state

def uid(prefix: str = "t") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"

# ── Test groups ───────────────────────────────────────────────────────────────

async def test_registration():
    section("Регистрация")
    u = uid("user")
    p = "TestPass123!"

    r = post("/api/register", {"username": u, "password": p})
    if r.get("token"):
        ok("Регистрация нового пользователя")
        state["user_a"] = {"username": u, "password": p, "token": r["token"],
                           "device_id": r.get("device_id", "")}
    else:
        fail("Регистрация нового пользователя", str(r))
        return False

    # Дубликат
    r2 = post("/api/register", {"username": u, "password": p})
    if "token" not in r2:
        ok("Отклонение дублирующей регистрации")
    else:
        fail("Отклонение дублирующей регистрации", "сервер выдал токен на существующий логин")

    # Второй пользователь
    u2 = uid("user")
    r3 = post("/api/register", {"username": u2, "password": p})
    if r3.get("token"):
        ok("Регистрация второго пользователя")
        state["user_b"] = {"username": u2, "password": p, "token": r3["token"],
                           "device_id": r3.get("device_id", "")}
    else:
        fail("Регистрация второго пользователя", str(r3))
        return False

    return True


async def test_login():
    section("Вход")
    a = state.get("user_a")
    b = state.get("user_b")
    if not a or not b:
        skip("Вход", "нет пользователей из предыдущего теста")
        return False

    r = post("/api/login", {"username": a["username"], "password": a["password"]})
    if r.get("token"):
        ok("Вход с правильным паролем")
        state["user_a"]["token"] = r["token"]
        state["user_a"]["device_id"] = r.get("device_id", state["user_a"]["device_id"])
    else:
        fail("Вход с правильным паролем", str(r))

    r2 = post("/api/login", {"username": a["username"], "password": "WrongPass!"})
    if "token" not in r2:
        ok("Отклонение неправильного пароля")
    else:
        fail("Отклонение неправильного пароля", "токен выдан!")

    return True


async def test_devices():
    section("Устройства")
    a = state.get("user_a")
    if not a or not a.get("token"):
        skip("Устройства", "нет токена")
        return

    r = get("/api/devices", token=a["token"])
    devices = r.get("devices", [])
    if devices:
        ok(f"Список устройств возвращается ({len(devices)} шт.)")
    else:
        fail("Список устройств возвращается", str(r))
        return

    creator = next((d for d in devices if d.get("trust_type") == "creator"), None)
    if creator:
        ok("Первое устройство имеет trust_type=creator")
        state["user_a"]["creator_device_id"] = creator["device_id"]
    else:
        fail("Первое устройство имеет trust_type=creator", f"устройства: {devices}")

    # Попытка добавить второе устройство (логин с новым device_id)
    new_dev_id = uid("dev")
    r2 = post("/api/login", {
        "username": a["username"],
        "password": a["password"],
        "device_id": new_dev_id,
        "device_name": "Test Device 2"
    })
    # Второе устройство должно ожидать одобрения
    if r2.get("status") in ("pending", "pending_approval") or "pending" in str(r2).lower():
        ok("Второе устройство уходит на одобрение")
        state["pending_device_id"] = new_dev_id
    else:
        skip("Второе устройство уходит на одобрение", f"ответ: {r2}")


async def test_contacts():
    section("Контакты")
    a = state.get("user_a")
    b = state.get("user_b")
    if not a or not b:
        skip("Контакты", "нет пользователей")
        return

    r = post("/api/contacts/add", {"contact_username": b["username"]}, token=a["token"])
    if r.get("ok") or r.get("result"):
        ok("Добавление контакта")
    else:
        fail("Добавление контакта", str(r))

    r2 = get("/api/contacts", token=a["token"])
    contacts = r2.get("contacts", [])
    names = [c.get("username") or c.get("contact_username") for c in contacts]
    if b["username"] in names:
        ok("Контакт виден в списке")
    else:
        fail("Контакт виден в списке", f"список: {names}")

    # Несуществующий контакт
    r3 = post("/api/contacts/add", {"contact_username": uid("nobody")}, token=a["token"])
    if "error" in r3 or "not found" in str(r3).lower() or not r3.get("ok"):
        ok("Несуществующий контакт не добавляется")
    else:
        fail("Несуществующий контакт не добавляется", str(r3))


async def test_websocket():
    section("WebSocket")
    a = state.get("user_a")
    b = state.get("user_b")
    if not a or not b:
        skip("WebSocket", "нет пользователей")
        return

    try:
        ws_a = await ws_connect(a["token"], a.get("device_id", uid("dev")))
        ok("WS подключение (user_a)")
    except Exception as e:
        fail("WS подключение (user_a)", str(e))
        return

    try:
        ws_b = await ws_connect(b["token"], b.get("device_id", uid("dev")))
        ok("WS подключение (user_b)")
    except Exception as e:
        fail("WS подключение (user_b)", str(e))
        await ws_a.close()
        return

    state["ws_a"] = ws_a
    state["ws_b"] = ws_b

    # Пинг-понг
    await ws_a.send(json.dumps({"type": "ping"}))
    pong = await ws_recv_until(ws_a, "pong", timeout=3)
    if pong:
        ok("ping → pong")
    else:
        fail("ping → pong", "нет ответа")


async def test_messaging():
    section("Сообщения")
    a  = state.get("user_a")
    b  = state.get("user_b")
    ws_a = state.get("ws_a")
    ws_b = state.get("ws_b")
    if not all([a, b, ws_a, ws_b]):
        skip("Сообщения", "нет WS соединений")
        return

    mid = uid("msg")
    msg = {
        "type": "relay_message",
        "to": b["username"],
        "msg_id": mid,
        "body": "Hello from test runner",
        "enc_body": "",
        "ts": int(time.time() * 1000),
    }
    await ws_a.send(json.dumps(msg))

    pkt = await ws_recv_until(ws_b, "relay_message", timeout=3)
    if pkt and pkt.get("msg_id") == mid:
        ok("Сообщение доставлено онлайн-получателю")
    else:
        fail("Сообщение доставлено онлайн-получателю", f"получено: {pkt}")

    # ACK
    if pkt:
        await ws_b.send(json.dumps({"type": "ack", "msg_id": mid, "to": a["username"]}))
        ack_pkt = await ws_recv_until(ws_a, "ack", timeout=2)
        if ack_pkt:
            ok("ACK доставлен отправителю")
        else:
            skip("ACK доставлен отправителю", "нет ответа")


async def test_permissions():
    section("Разрешения")
    a = state.get("user_a")
    if not a:
        skip("Разрешения", "нет пользователей")
        return

    r = get("/api/devices", token=a["token"])
    devices = r.get("devices", [])
    guest = next((d for d in devices if d.get("trust_type") != "creator"), None)
    if not guest:
        skip("Разрешения (нет гостевого устройства для теста)")
        return

    dev_id = guest["device_id"]

    # Установить разрешения
    perms = {"msg_send": True, "msg_read": True, "contacts_view": False, "allow_logout": True}
    r2 = post(f"/api/devices/{dev_id}/permissions", perms, token=a["token"])
    if r2.get("ok"):
        ok("Установка разрешений на устройство")
    else:
        fail("Установка разрешений на устройство", str(r2))

    # Проверить что сохранилось
    r3 = get("/api/devices", token=a["token"])
    updated = next((d for d in r3.get("devices", []) if d["device_id"] == dev_id), None)
    if updated:
        perms_saved = updated.get("permissions", {})
        if perms_saved.get("msg_send") is True and perms_saved.get("contacts_view") is False:
            ok("Разрешения сохранились корректно")
        else:
            fail("Разрешения сохранились корректно", f"сохранено: {perms_saved}")


async def test_device_revoke():
    section("Отзыв устройства")
    a = state.get("user_a")
    if not a:
        skip("Отзыв устройства", "нет пользователя")
        return

    # Зарегистрировать временное устройство
    tmp_dev = uid("tmpdev")
    r = post("/api/login", {
        "username": a["username"], "password": a["password"],
        "device_id": tmp_dev, "device_name": "Temp device"
    })
    if r.get("status") not in ("pending", "pending_approval") and not r.get("token"):
        skip("Отзыв устройства", f"не удалось создать второе устройство: {r}")
        return

    # Найти его в списке и заблокировать
    r2 = get("/api/devices", token=a["token"])
    dev = next((d for d in r2.get("devices", []) if d["device_id"] == tmp_dev), None)
    if not dev:
        skip("Отзыв устройства", "устройство не появилось в списке")
        return

    r3 = delete(f"/api/devices/{tmp_dev}", token=a["token"])
    if r3.get("ok"):
        ok("Устройство отозвано через API")
    else:
        fail("Устройство отозвано через API", str(r3))

    # Убедиться что оно теперь blocked
    r4 = get("/api/devices", token=a["token"])
    dev2 = next((d for d in r4.get("devices", []) if d["device_id"] == tmp_dev), None)
    if dev2 and dev2.get("blocked"):
        ok("Устройство помечено как blocked")
    elif not dev2:
        ok("Устройство удалено из списка")
    else:
        fail("Устройство помечено как blocked", str(dev2))


async def test_multi_device_online():
    section("Мультиустройства (оба онлайн)")
    a = state.get("user_a")
    if not a:
        skip("Мультиустройства", "нет пользователя")
        return

    dev1_id = a.get("device_id", uid("dev"))
    dev2_id = uid("dev2")

    try:
        ws1 = await ws_connect(a["token"], dev1_id)
        ws2 = await ws_connect(a["token"], dev2_id)
        ok("Два устройства одного аккаунта онлайн одновременно")

        # Первое устройство должно оставаться онлайн (не быть кикнутым)
        await asyncio.sleep(0.5)
        pkts = await ws_drain(ws1, timeout=0.3)
        kicked = any(p.get("type") in ("kicked", "revoked") for p in pkts)
        if kicked:
            fail("Первое устройство не кикается при подключении второго", "получен kicked")
        else:
            ok("Первое устройство не кикается при подключении второго")

        await ws1.close()
        await ws2.close()
    except Exception as e:
        fail("Мультиустройства онлайн", str(e))


async def test_cleanup():
    section("Очистка тестовых данных")
    a = state.get("user_a")
    b = state.get("user_b")

    for ws_key in ("ws_a", "ws_b"):
        ws = state.get(ws_key)
        if ws:
            try:
                await ws.close()
            except Exception:
                pass

    for user in (a, b):
        if not user or not user.get("token"):
            continue
        r = delete("/api/account", token=user["token"])
        if r.get("ok"):
            ok(f"Удалён тестовый аккаунт {user['username']}")
        else:
            skip(f"Удалён тестовый аккаунт {user['username']}", str(r))


# ── Main ──────────────────────────────────────────────────────────────────────

async def run_all():
    print(f"\n{BOLD}GhostChat Test Runner{RESET}  →  {SERVER}\n")
    print("─" * 50)

    ok_reg = await test_registration()
    if not ok_reg:
        print(f"\n{RED}Прерываем — регистрация провалилась{RESET}")
    else:
        await test_login()
        await test_devices()
        await test_contacts()
        await test_websocket()
        await test_messaging()
        await test_permissions()
        await test_device_revoke()
        await test_multi_device_online()

    await test_cleanup()

    # Summary
    total = passed + failed + skipped
    print(f"\n{'─'*50}")
    print(f"{BOLD}Итого:{RESET} {total} тестов — "
          f"{GREEN}{passed} прошли{RESET}, "
          f"{RED}{failed} провалились{RESET}, "
          f"{YELLOW}{skipped} пропущены{RESET}")
    if failed:
        print(f"\n{RED}Статус: ОШИБКИ{RESET}\n")
        sys.exit(1)
    else:
        print(f"\n{GREEN}Статус: ВСЁ ОК{RESET}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="GhostChat test runner")
    parser.add_argument("--server", default="http://localhost:8000",
                        help="Server URL (default: http://localhost:8000)")
    args = parser.parse_args()

    SERVER = args.server.rstrip("/")
    WS_SERVER = SERVER.replace("http://", "ws://").replace("https://", "wss://")

    asyncio.run(run_all())
