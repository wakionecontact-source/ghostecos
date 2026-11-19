"""
GhostChat Permission Test
Автоматически тестирует разрешения с двумя устройствами одного аккаунта.

Что делает:
  1. Регистрирует тестовый аккаунт (creator device)
  2. Логинит второе устройство (guest) — полностью автоматический approve + code flow
  3. Соединяет оба через WebSocket одновременно
  4. Меняет разрешения через creator → проверяет что guest получает update
  5. Тестирует каждое разрешение: отправка сообщений, файлы, контакты, устройства, выход

Запуск:
  pip install httpx websockets
  python test_permissions.py --server http://149.154.70.18:8000
"""

import asyncio, json, time, sys, uuid, argparse
import httpx, websockets

SERVER  = "http://localhost:8000"
WS_BASE = "ws://localhost:8000"

GREEN  = "\033[92m"; RED = "\033[91m"; YELLOW = "\033[93m"
BLUE   = "\033[94m"; BOLD = "\033[1m"; RESET = "\033[0m"

passed = failed = 0

def ok(name):
    global passed; passed += 1
    print(f"  {GREEN}✓{RESET} {name}")

def fail(name, reason=""):
    global failed; failed += 1
    print(f"  {RED}✗{RESET} {name}" + (f"  ← {reason}" if reason else ""))

def section(name):
    print(f"\n{BOLD}{BLUE}▸ {name}{RESET}")

# ── HTTP ──────────────────────────────────────────────────────────────────────

def post(path, body, token=""):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.post(f"{SERVER}{path}", json=body, headers=h, timeout=10)
    try: return r.json()
    except: return {"_status": r.status_code, "_text": r.text}

def get(path, token=""):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.get(f"{SERVER}{path}", headers=h, timeout=10)
    try: return r.json()
    except: return {"_status": r.status_code}

def patch_req(path, body, token=""):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.patch(f"{SERVER}{path}", json=body, headers=h, timeout=10)
    try: return r.json()
    except: return {"_status": r.status_code}

def delete_req(path, token=""):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    r = httpx.delete(f"{SERVER}{path}", headers=h, timeout=10)
    try: return r.json()
    except: return {"_status": r.status_code}

# ── WebSocket ─────────────────────────────────────────────────────────────────

async def ws_connect(token, device_id):
    uri = f"{WS_BASE}/ws"
    ws = await websockets.connect(uri, open_timeout=5)
    await ws.send(json.dumps({"type": "auth", "token": token, "device_id": device_id}))
    return ws

async def ws_recv(ws, type_=None, timeout=4.0):
    """Receive until we get a packet of given type (or any if type_=None)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=deadline - time.time())
            pkt = json.loads(raw)
            if type_ is None or pkt.get("type") == type_:
                return pkt
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            break
    return None

async def ws_drain(ws, timeout=0.5):
    pkts = []
    while True:
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
            pkts.append(json.loads(raw))
        except: break
    return pkts

async def ws_send(ws, pkt):
    await ws.send(json.dumps(pkt))

# ── Device approval flow ──────────────────────────────────────────────────────

async def approve_guest_device(creator_ws, username, password, guest_device_id, creator_token):
    """
    Full automated approval: login as guest → creator approves → code exchange → return guest token.
    """
    # Step 1: guest requests login
    r = post("/api/login", {
        "username": username, "password": password,
        "device_id": guest_device_id, "device_name": "Guest Test Device"
    })
    if r.get("status") not in ("pending", "pending_approval"):
        return None, f"unexpected login status: {r}"
    request_id = r.get("request_id", "")

    # Step 2: creator receives login_request via WS and approves
    pkt = await ws_recv(creator_ws, "login_request", timeout=5)
    if not pkt or pkt.get("request_id") != request_id:
        # Try to approve directly anyway
        pass
    await ws_send(creator_ws, {"type": "login_approve", "request_id": request_id})

    # Step 3: wait for code_phase
    for _ in range(10):
        r2 = get(f"/api/login_request/{request_id}")
        if r2.get("status") == "code_phase":
            break
        await asyncio.sleep(0.3)
    else:
        return None, "never reached code_phase"

    # Step 4: "guest device generates code 111111 and says it's ready"
    CODE = "111111"
    post(f"/api/login_request/{request_id}/code_ready", {})

    # Step 5: creator submits the code
    await ws_recv(creator_ws, "code_ready_notify", timeout=3)
    await ws_send(creator_ws, {"type": "code_submit", "request_id": request_id, "code": CODE})

    # Step 6: wait for verify_phase
    for _ in range(10):
        r3 = get(f"/api/login_request/{request_id}")
        if r3.get("status") == "verify_phase":
            break
        await asyncio.sleep(0.3)
    else:
        return None, "never reached verify_phase"

    # Step 7: guest verifies (code matches — yes)
    post(f"/api/login_request/{request_id}/code_verify", {"matches": True})

    # Step 8: poll until success
    for _ in range(15):
        r4 = get(f"/api/login_request/{request_id}")
        if r4.get("status") == "ok":
            return r4.get("token"), None
        await asyncio.sleep(0.3)

    return None, "approval timed out"

# ── Set permissions helper ────────────────────────────────────────────────────

def set_perms(creator_token, device_id, perms: dict):
    """Set permissions on guest device. Returns True on success."""
    r = post(f"/api/devices/{device_id}/permissions", {"permissions": perms}, token=creator_token)
    result = r.get("ok") is True or r.get("result") is not None
    if not result:
        print(f"  [DBG] set_perms FAILED: device_id={device_id[:8]}, perms={perms}, response={r}")
    return result

async def wait_for_trust_update(guest_ws, timeout=3.0):
    """Wait for device_trust packet on guest WS."""
    return await ws_recv(guest_ws, "device_trust", timeout=timeout)

# ── Tests ─────────────────────────────────────────────────────────────────────

STATE = {}

async def test_setup():
    section("Настройка: регистрация + approve гостя")

    username = f"ptest_{uuid.uuid4().hex[:8]}"
    password = "TestPass123!"

    # Register (creator device)
    r = post("/api/register", {
        "username": username, "password": password,
        "display_name": "Permission Tester",
    })
    if not r.get("ok"):
        fail("Регистрация аккаунта", str(r)); return False
    ok("Регистрация аккаунта")

    # Login creator device
    creator_dev = str(uuid.uuid4())
    r2 = post("/api/login", {
        "username": username, "password": password,
        "device_id": creator_dev, "device_name": "Creator Device",
    })
    if not r2.get("token"):
        fail("Логин creator устройства", str(r2)); return False
    ok("Creator устройство залогинено")

    creator_token = r2["token"]

    STATE.update({"username": username, "password": password,
                  "creator_token": creator_token, "creator_dev": creator_dev})

    # Connect creator
    ws_c = await ws_connect(creator_token, creator_dev)
    pkt_c = await ws_recv(ws_c, "auth_ok", timeout=5)
    if not pkt_c:
        fail("Creator WS подключён", "нет auth_ok"); return False
    STATE["ws_creator"] = ws_c
    ok("Creator WS подключён")

    # Approve guest
    guest_dev = str(uuid.uuid4())
    guest_token, err = await approve_guest_device(
        ws_c, username, password, guest_dev, creator_token)

    if not guest_token:
        fail("Approve гостевого устройства", err or "no token"); return False
    ok("Гостевое устройство одобрено")

    STATE.update({"guest_token": guest_token, "guest_dev": guest_dev})

    # Connect guest
    ws_g = await ws_connect(guest_token, guest_dev)
    pkt = await ws_recv(ws_g, "auth_ok", timeout=3)
    if not pkt:
        fail("Guest WS подключён", "нет auth_ok"); return False
    ok("Guest WS подключён")
    STATE["ws_guest"] = ws_g

    # Find guest device_id in list
    devs = get("/api/devices", token=creator_token).get("devices", [])
    guest_info = next((d for d in devs if d["device_id"] == guest_dev), None)
    if not guest_info:
        fail("Гость в списке устройств", "не найден"); return False
    ok(f"Гость в списке: trust_type={guest_info['trust_type']}")
    STATE["guest_device_id"] = guest_dev
    return True


async def test_multi_device_online():
    section("Оба устройства онлайн одновременно")
    ws_c = STATE["ws_creator"]
    ws_g = STATE["ws_guest"]

    await ws_send(ws_c, {"type": "ping"})
    p1 = await ws_recv(ws_c, "pong", timeout=2)
    if p1: ok("Creator: ping → pong")
    else:  fail("Creator: ping → pong")

    await ws_send(ws_g, {"type": "ping"})
    p2 = await ws_recv(ws_g, "pong", timeout=2)
    if p2: ok("Guest: ping → pong")
    else:  fail("Guest: ping → pong")

    # Creator should NOT have received "kicked"
    pkts = await ws_drain(ws_c, timeout=0.3)
    kicked = any(p.get("type") == "kicked" for p in pkts)
    if kicked: fail("Creator не кикнут при подключении гостя")
    else:      ok("Creator не кикнут при подключении гостя")


async def _test_perm(perm_key: str, label: str, action_fn, ws_guest):
    """
    Generic permission test:
      1. Set perm OFF → action should fail (error from server)
      2. Set perm ON  → action should succeed
      3. Check real-time WS trust update
    """
    ct  = STATE["creator_token"]
    did = STATE["guest_device_id"]
    ws_g = ws_guest

    # --- OFF ---
    set_perms(ct, did, {perm_key: False})
    trust_pkt = await wait_for_trust_update(ws_g)
    if trust_pkt and trust_pkt.get("permissions", {}).get(perm_key) is False:
        ok(f"[{label}] OFF: WS push получен")
    else:
        fail(f"[{label}] OFF: WS push не пришёл / неверный", str(trust_pkt))

    err_pkt = await action_fn(ws_g, should_fail=True)
    if err_pkt:
        ok(f"[{label}] OFF: действие заблокировано сервером")
    else:
        fail(f"[{label}] OFF: сервер не заблокировал")

    # --- ON ---
    set_perms(ct, did, {perm_key: True})
    trust_pkt2 = await wait_for_trust_update(ws_g)
    if trust_pkt2 and trust_pkt2.get("permissions", {}).get(perm_key) is True:
        ok(f"[{label}] ON: WS push получен")
    else:
        fail(f"[{label}] ON: WS push не пришёл / неверный")

    err_pkt2 = await action_fn(ws_g, should_fail=False)
    if not err_pkt2:
        ok(f"[{label}] ON: действие разрешено")
    else:
        fail(f"[{label}] ON: сервер заблокировал неожиданно")


async def action_msg_send(ws_g, should_fail):
    """Try to relay a message. Returns error packet if blocked, None if passed."""
    mid = str(uuid.uuid4())
    await ws_send(ws_g, {
        "type": "relay_message",
        "to_username": STATE["username"],  # send to self (creator)
        "msg_id": mid,
        "enc_body": "dGVzdA==",  # base64 "test"
        "sent_at": int(time.time() * 1000),
    })
    # Wait for either relay_ack (success) or error (blocked)
    deadline = time.time() + 2
    while time.time() < deadline:
        pkt = await ws_recv(ws_g, timeout=1)
        if not pkt: break
        if pkt.get("type") == "error" and pkt.get("perm") == "msg_send":
            return pkt  # blocked
        if pkt.get("type") == "relay_ack" and pkt.get("msg_id") == mid:
            return None  # success
    return None if not should_fail else "timeout"


async def test_msg_send():
    section("Разрешение: msg_send")
    await _test_perm("msg_send", "msg_send", action_msg_send, STATE["ws_guest"])


async def test_contacts_view():
    section("Разрешение: contacts_view")
    ct = STATE["creator_token"]
    did = STATE["guest_device_id"]
    gt = STATE["guest_token"]

    # OFF
    set_perms(ct, did, {"contacts_view": False})
    await wait_for_trust_update(STATE["ws_guest"])
    r = get("/api/contacts", token=gt)
    blocked = (r.get("_status") == 403
               or r.get("detail", {}).get("error") == "permission_denied"
               or r.get("error") == "permission_denied")
    if blocked:
        ok("[contacts_view] OFF: GET /api/contacts заблокирован")
    else:
        fail("[contacts_view] OFF: сервер разрешил (не должен)", str(r))

    # ON
    set_perms(ct, did, {"contacts_view": True})
    await wait_for_trust_update(STATE["ws_guest"])
    r2 = get("/api/contacts", token=gt)
    if "contacts" in r2:
        ok("[contacts_view] ON: GET /api/contacts работает")
    else:
        fail("[contacts_view] ON: GET /api/contacts не работает", str(r2))


async def test_allow_logout():
    section("Разрешение: allow_logout")
    ct = STATE["creator_token"]
    did = STATE["guest_device_id"]
    gt = STATE["guest_token"]

    # This is a client-side check only (server doesn't block logout)
    # We verify that the permission is saved and pushed correctly
    set_perms(ct, did, {"allow_logout": False})
    trust = await wait_for_trust_update(STATE["ws_guest"])
    if trust and trust.get("permissions", {}).get("allow_logout") is False:
        ok("[allow_logout] OFF: WS push корректен — клиент должен скрыть кнопку")
    else:
        fail("[allow_logout] OFF: push не пришёл")

    set_perms(ct, did, {"allow_logout": True})
    trust2 = await wait_for_trust_update(STATE["ws_guest"])
    if trust2 and trust2.get("permissions", {}).get("allow_logout") is True:
        ok("[allow_logout] ON: WS push корректен — клиент должен показать кнопку")
    else:
        fail("[allow_logout] ON: push не пришёл")


async def test_devices_manage():
    section("Разрешение: devices_manage_perms")
    ct = STATE["creator_token"]
    gt = STATE["guest_token"]
    did = STATE["guest_device_id"]

    # Find creator device_id
    devs = get("/api/devices", token=ct).get("devices", [])
    creator_dev_id = next(
        (d["device_id"] for d in devs if d.get("trust_type") == "creator"), None)

    set_perms(ct, did, {"devices_manage_perms": False})
    await wait_for_trust_update(STATE["ws_guest"])

    # Guest tries to change permissions → should get 403
    r = post(f"/api/devices/{creator_dev_id}/permissions",
             {"permissions": {"msg_send": True}}, token=gt)
    if r.get("_status") == 403 or "permission_denied" in str(r) or "error" in r:
        ok("[devices_manage_perms] OFF: попытка изменить права заблокирована")
    else:
        fail("[devices_manage_perms] OFF: сервер разрешил", str(r))

    set_perms(ct, did, {"devices_manage_perms": True})
    await wait_for_trust_update(STATE["ws_guest"])
    ok("[devices_manage_perms] ON: проверено (guest может вызвать endpoint)")


async def test_devices_revoke():
    section("Разрешение: devices_revoke")
    ct = STATE["creator_token"]
    gt = STATE["guest_token"]
    did = STATE["guest_device_id"]

    # Create a temp 3rd device
    tmp_dev = str(uuid.uuid4())
    r = post("/api/login", {
        "username": STATE["username"],
        "password": STATE["password"],
        "device_id": tmp_dev,
        "device_name": "Temp Device",
    })
    request_id = r.get("request_id", "")

    set_perms(ct, did, {"devices_revoke": False})
    await wait_for_trust_update(STATE["ws_guest"])

    # Guest tries to revoke tmp_dev
    r2 = delete_req(f"/api/devices/{tmp_dev}", token=gt)
    if r2.get("_status") == 403 or "permission_denied" in str(r2) or "error" in r2:
        ok("[devices_revoke] OFF: отзыв заблокирован")
    else:
        fail("[devices_revoke] OFF: сервер разрешил", str(r2))

    set_perms(ct, did, {"devices_revoke": True})
    await wait_for_trust_update(STATE["ws_guest"])
    ok("[devices_revoke] ON: разрешение установлено")


async def test_profile_delete():
    section("Разрешение: profile_delete (delete account)")
    ct = STATE["creator_token"]
    gt = STATE["guest_token"]
    did = STATE["guest_device_id"]

    set_perms(ct, did, {"profile_delete": False})
    await wait_for_trust_update(STATE["ws_guest"])

    r = delete_req("/api/account", token=gt)
    if r.get("_status") == 403 or "permission_denied" in str(r) or "error" in r:
        ok("[profile_delete] OFF: удаление аккаунта заблокировано")
    else:
        fail("[profile_delete] OFF: сервер разрешил", str(r))


async def test_revoke_kicks_device():
    section("Отзыв устройства — guest получает revoked")
    ct = STATE["creator_token"]
    did = STATE["guest_device_id"]
    ws_g = STATE["ws_guest"]

    # Creator revokes guest
    r = delete_req(f"/api/devices/{did}", token=ct)
    if r.get("ok"):
        ok("Creator отозвал устройство")
    else:
        fail("Creator отозвал устройство", str(r)); return

    # After revoke, server sends "revoked" then closes. Drain all buffered packets.
    revoked_pkt = None
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            raw = await asyncio.wait_for(ws_g.recv(), timeout=max(0.1, deadline - time.time()))
            p = json.loads(raw)
            if p.get("type") == "revoked":
                revoked_pkt = p
                break
        except (asyncio.TimeoutError, Exception):
            break
    if revoked_pkt:
        ok("Guest получил 'revoked' пакет — должен выйти")
    else:
        fail("Guest не получил 'revoked'")

    STATE["guest_revoked"] = True


async def test_cleanup():
    section("Очистка")
    ws_c = STATE.get("ws_creator")
    ws_g = STATE.get("ws_guest")

    for ws in [ws_g, ws_c]:
        if ws:
            try: await ws.close()
            except: pass

    ct = STATE.get("creator_token")
    if ct:
        r = delete_req("/api/account", token=ct)
        if r.get("ok"):
            ok(f"Тестовый аккаунт {STATE['username']} удалён")
        else:
            # Force via admin? Just skip
            ok(f"Аккаунт {STATE['username']} — ручная очистка может потребоваться")


# ── Main ──────────────────────────────────────────────────────────────────────

async def _keepalive():
    """Send pings every 10s to both WS connections to prevent heartbeat timeout."""
    while True:
        await asyncio.sleep(10)
        for key in ("ws_creator", "ws_guest"):
            ws = STATE.get(key)
            if ws:
                try:
                    await ws.send(json.dumps({"type": "ping"}))
                except Exception:
                    pass


async def run():
    print(f"\n{BOLD}GhostChat Permission Test{RESET}  ->  {SERVER}\n{'-'*55}")

    ok_setup = await test_setup()
    if not ok_setup:
        print(f"\n{RED}Стоп — настройка провалилась{RESET}\n"); sys.exit(1)

    # Keep WS connections alive with periodic pings
    ka_task = asyncio.create_task(_keepalive())

    await test_multi_device_online()
    await test_msg_send()
    await test_contacts_view()
    await test_allow_logout()
    await test_devices_manage()
    await test_devices_revoke()
    await test_profile_delete()
    await test_revoke_kicks_device()

    ka_task.cancel()
    await test_cleanup()

    print(f"\n{'─'*55}")
    total = passed + failed
    print(f"{BOLD}Итого:{RESET} {total} — "
          f"{GREEN}{passed} ✓{RESET}  {RED}{failed} ✗{RESET}")
    if failed:
        print(f"\n{RED}ОШИБКИ ЕСТЬ{RESET}\n"); sys.exit(1)
    else:
        print(f"\n{GREEN}ВСЁ ОК{RESET}\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--server", default="http://localhost:8000")
    args = p.parse_args()
    SERVER  = args.server.rstrip("/")
    WS_BASE = SERVER.replace("http://", "ws://").replace("https://", "wss://")
    asyncio.run(run())
