"""
GhostNation — бэкенд общего мира (мультиплеер).

Переиспользует аккаунты GhostEcos: верифицирует JWT тем же GC_JWT_SECRET
(HS256, username в claim "sub"), как ghostchat (см. server/backchat/auth.py).

Эндпоинты:
  GET  /api/nation/world?minlat&minlng&maxlat&maxlng  — ПУБЛИЧНО: страны в bbox (границы+названия+центр)
  GET  /api/nation/mine        — (auth) моя страна + начисленный доход (налоги с населения)
  POST /api/nation/claim       — (auth) застолбить/переобвести границу (анти-overlap с чужими, стоит gost ∝ площади)
  PUT  /api/nation/mine        — (auth) сохранить состояние страны (объекты только внутри границы, стоит gost за новые)

Запуск:  uvicorn server:app --host 127.0.0.1 --port 8010
Деплой:  systemd + nginx location /api/nation/ → 127.0.0.1:8010 (как /api/soc → 8005).
"""
import os, json, math, time, sqlite3, hmac, ipaddress, asyncio
from collections import defaultdict, deque
from typing import Optional
from fastapi import FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import jwt

JWT_SECRET = os.getenv("GC_JWT_SECRET", "")
JWT_ALG = "HS256"
DB_PATH = os.getenv("NATION_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "nation.db"))

if len(JWT_SECRET) < 32:
    raise RuntimeError("GC_JWT_SECRET must be configured with at least 32 random characters")

# ── Экономика (gost) — решено: налоги с населения + старт-бонус, всё стоит gost ──
START_BONUS         = 1500      # gost при создании страны
CLAIM_COST_PER_KM2  = 300       # gost за км² застолблённой территории
COST_BUILD          = {"house": 40, "shop": 70, "tree": 4}
COST_ROAD_PER_M     = 0.6       # дорога/переулок/жд
RESIDENTS_PER_HOUSE = 4         # население = дома × это (ограничено рабочими местами)
JOBS_PER_SHOP       = 12
TAX_PER_CITIZEN_HR  = 2.0       # gost в час с жителя

MAX_BORDER_POINTS = 512
MAX_BUILDINGS = 5000
MAX_ROADS = 2000
MAX_ROAD_POINTS = 512
MAX_TOTAL_ROAD_POINTS = 50000

app = FastAPI(title="GhostNation API", docs_url=None, redoc_url=None, openapi_url=None)
_MAX_JSON_BODY = 12 * 1024 * 1024
_MAX_STATE_BYTES = 8 * 1024 * 1024
_MAX_WORLD_COUNTRIES = 5000
_RL_LIMIT = 240
_RL_WINDOW = 60
_RL_BUCKETS: dict[str, deque] = defaultdict(deque)


@app.middleware("http")
async def request_size_guard(request: Request, call_next):
    raw_length = request.headers.get("content-length")
    if raw_length:
        try:
            length = int(raw_length)
        except ValueError:
            return JSONResponse({"detail": "Invalid Content-Length"}, status_code=400)
        if length < 0 or length > _MAX_JSON_BODY:
            return JSONResponse({"detail": "Request body too large"}, status_code=413)
    return await call_next(request)


def _client_ip(request: Request) -> str:
    """Trust the proxy-provided address only from the local reverse proxy."""
    peer = request.client.host if request.client else "unknown"
    try:
        peer_ip = ipaddress.ip_address(peer)
    except ValueError:
        peer_ip = None
    forwarded = (request.headers.get("x-real-ip") or "").strip()
    try:
        forwarded_ip = ipaddress.ip_address(forwarded) if forwarded else None
    except ValueError:
        forwarded_ip = None
    if forwarded_ip and peer_ip and (peer_ip.is_loopback or forwarded_ip == peer_ip):
        return str(forwarded_ip)
    return str(peer_ip) if peer_ip else "unknown"


@app.middleware("http")
async def rate_limit(request: Request, call_next):
    key = _client_ip(request)
    now = time.monotonic()
    bucket = _RL_BUCKETS[key]
    while bucket and now - bucket[0] > _RL_WINDOW:
        bucket.popleft()
    if len(bucket) >= _RL_LIMIT:
        return JSONResponse(
            {"detail": "Too many requests"},
            status_code=429,
            headers={"Retry-After": str(_RL_WINDOW)},
        )
    bucket.append(now)
    if len(_RL_BUCKETS) > 10_000:
        stale_before = now - (_RL_WINDOW * 2)
        for stale_key, stale_bucket in list(_RL_BUCKETS.items())[:2_000]:
            if not stale_bucket or stale_bucket[-1] < stale_before:
                _RL_BUCKETS.pop(stale_key, None)
    return await call_next(request)


def _db():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.execute("""CREATE TABLE IF NOT EXISTS country(
        owner TEXT PRIMARY KEY, name TEXT, color TEXT,
        border TEXT, state TEXT, balance REAL DEFAULT 0, built_value REAL DEFAULT 0,
        cx REAL, cy REAL, minlat REAL, minlng REAL, maxlat REAL, maxlng REAL,
        created INTEGER, updated INTEGER, last_income INTEGER)""")
    # Архивация: страна остаётся видимой на карте, но без владельца (когда аккаунт удалён)
    for col, ddl in (("archived", "INTEGER NOT NULL DEFAULT 0"),
                     ("archived_at", "INTEGER"),
                     ("prev_owner", "TEXT")):
        try: con.execute(f"ALTER TABLE country ADD COLUMN {col} {ddl}")
        except Exception: pass
    return con


def _user(authorization: Optional[str]) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Authorization required")
    token = authorization[7:]
    if not token or len(token) > 4096:
        raise HTTPException(401, "Invalid token")
    try:
        payload = jwt.decode(
            token,
            JWT_SECRET,
            algorithms=[JWT_ALG],
            options={"require": ["sub", "iat", "exp"]},
        )
    except Exception:
        raise HTTPException(401, "Invalid token")
    sub = payload.get("sub")
    if not isinstance(sub, str) or not (1 <= len(sub) <= 64):
        raise HTTPException(401, "Invalid token")
    return sub


# ── Общий мир в реальном времени (WS) ──
_WS_MAX_BUILDINGS = 1500      # потолок построек на страну в одном сообщении
_WS_ANON_PER_IP = 8           # анонимных соединений с одного IP
_WS_MAX_MSG = 8192            # байт в одном клиентском сообщении


class WorldHub:
    """Подписки на bbox: кто что видит, тому и push."""

    def __init__(self):
        self.clients: dict[WebSocket, tuple[float, float, float, float]] = {}
        self.info: dict[WebSocket, dict] = {}
        self.anon_ips: defaultdict[str, int] = defaultdict(int)

    def add(self, ws: WebSocket, bbox: tuple[float, float, float, float],
            ip: str = "", anon: bool = False) -> None:
        self.clients[ws] = bbox
        self.info[ws] = {"ip": ip, "anon": anon}
        if anon:
            self.anon_ips[ip] += 1

    def drop(self, ws: WebSocket) -> None:
        info = self.info.pop(ws, None)
        if info and info.get("anon"):
            ip = info.get("ip") or ""
            self.anon_ips[ip] = max(0, self.anon_ips[ip] - 1)
            if not self.anon_ips[ip]:
                self.anon_ips.pop(ip, None)
        self.clients.pop(ws, None)

    def anon_count(self, ip: str) -> int:
        return self.anon_ips.get(ip, 0)

    async def push(self, ws: WebSocket, payload: dict) -> None:
        try:
            await ws.send_json(payload)
        except Exception:
            self.drop(ws)

    async def broadcast(self, area, payload: dict) -> int:
        sent = 0
        for ws, bbox in list(self.clients.items()):
            if _bbox_hits(bbox, area):
                await self.push(ws, payload)
                sent += 1
        return sent


_hub = WorldHub()


def _bbox_hits(a, b) -> bool:
    return not (a[2] < b[0] or a[0] > b[2] or a[3] < b[1] or a[1] > b[3])


def _norm_bbox(msg: dict):
    try:
        box = tuple(float(msg[k]) for k in ("minlat", "minlng", "maxlat", "maxlng"))
    except (KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(v) for v in box):
        return None
    if not (-90 <= box[0] <= box[2] <= 90 and -180 <= box[1] <= box[3] <= 180):
        return None
    return box


def _country_payload(row, bbox=None) -> dict:
    """Страна для мира: границы + постройки (обрезанные по bbox)."""
    state = json.loads(row["state"] or "{}")
    buildings = []
    for b in state.get("buildings", [])[:MAX_BUILDINGS]:
        if not isinstance(b, dict):
            continue
        try:
            lat, lng = float(b.get("lat")), float(b.get("lng"))
        except (TypeError, ValueError):
            continue
        if bbox and not (bbox[0] <= lat <= bbox[2] and bbox[1] <= lng <= bbox[3]):
            continue
        item = {"type": b.get("type") or "house", "lat": round(lat, 6), "lng": round(lng, 6)}
        if b.get("type") == "tree":
            item["r"] = round(float(b.get("r") or 3.5), 2)
        else:
            item["w"] = round(float(b.get("w") or 13), 1)
            item["h"] = round(float(b.get("h") or 10), 1)
            item["rot"] = round(float(b.get("rot") or 0), 1)
        buildings.append(item)
        if len(buildings) >= _WS_MAX_BUILDINGS:
            break
    return {"owner": row["owner"], "name": row["name"], "color": row["color"],
            "border": json.loads(row["border"]), "cx": row["cx"], "cy": row["cy"],
            "buildings": buildings, "updated": row["updated"]}


def _country_row(owner: str):
    con = _db()
    r = con.execute("SELECT * FROM country WHERE owner=? AND archived=0", (owner,)).fetchone()
    con.close()
    return r


async def _broadcast_country(owner: str) -> None:
    r = _country_row(owner)
    if not r:
        return
    await _hub.broadcast((r["minlat"], r["minlng"], r["maxlat"], r["maxlng"]),
                         {"type": "country", "country": _country_payload(r)})


# ── Геометрия ──
def _bbox(b):
    la = [p[0] for p in b]; ln = [p[1] for p in b]
    return min(la), min(ln), max(la), max(ln)


def _validate_point(point, label: str) -> None:
    if not isinstance(point, (list, tuple)) or len(point) != 2:
        raise HTTPException(400, f"{label}: point must be [lat, lng]")
    lat, lng = point
    if (isinstance(lat, bool) or isinstance(lng, bool) or
            not isinstance(lat, (int, float)) or not isinstance(lng, (int, float))):
        raise HTTPException(400, f"{label}: coordinates must be numbers")
    try:
        lat_f, lng_f = float(lat), float(lng)
    except (TypeError, ValueError):
        raise HTTPException(400, f"{label}: coordinates must be numbers")
    if not math.isfinite(lat_f) or not math.isfinite(lng_f):
        raise HTTPException(400, f"{label}: coordinates must be finite")
    if not -90 <= lat_f <= 90 or not -180 <= lng_f <= 180:
        raise HTTPException(400, f"{label}: coordinates out of range")


def _validate_border(border) -> None:
    if not isinstance(border, list) or len(border) < 3:
        raise HTTPException(400, "Border needs >=3 points")
    if len(border) > MAX_BORDER_POINTS:
        raise HTTPException(413, f"Border has too many points (max {MAX_BORDER_POINTS})")
    for i, point in enumerate(border):
        _validate_point(point, f"border[{i}]")


def _validate_state(state: dict) -> None:
    if not isinstance(state, dict):
        raise HTTPException(400, "state must be an object")
    buildings = state.get("buildings", [])
    if not isinstance(buildings, list) or len(buildings) > MAX_BUILDINGS:
        raise HTTPException(413, f"Too many buildings (max {MAX_BUILDINGS})")
    for i, building in enumerate(buildings):
        if not isinstance(building, dict):
            raise HTTPException(400, f"buildings[{i}] must be an object")
        if building.get("lat") is not None or building.get("lng") is not None:
            _validate_point([building.get("lat"), building.get("lng")], f"buildings[{i}]")
    for key in ("roads", "alleys"):
        lines = state.get(key, [])
        if not isinstance(lines, list) or len(lines) > MAX_ROADS:
            raise HTTPException(413, f"Too many {key} (max {MAX_ROADS})")
        for i, line in enumerate(lines):
            if not isinstance(line, list) or len(line) < 2 or len(line) > MAX_ROAD_POINTS:
                raise HTTPException(400, f"{key}[{i}] has an invalid number of points")
            for j, point in enumerate(line):
                _validate_point(point, f"{key}[{i}][{j}]")
    total_points = sum(len(line) for key in ("roads", "alleys") for line in state.get(key, []))
    if total_points > MAX_TOTAL_ROAD_POINTS:
        raise HTTPException(413, f"Too many road points (max {MAX_TOTAL_ROAD_POINTS})")


def _centroid(b):
    n = len(b); return sum(p[0] for p in b) / n, sum(p[1] for p in b) / n


def _area_km2(b):
    if len(b) < 3: return 0.0
    R = 111320.0; mlng = R * math.cos(math.radians(b[0][0])); a = 0.0
    for i in range(len(b)):
        j = (i + 1) % len(b)
        a += (b[i][1] * mlng) * (b[j][0] * R) - (b[j][1] * mlng) * (b[i][0] * R)
    return abs(a) / 2 / 1e6


def _road_len_m(roads):
    t = 0.0
    for r in roads or []:
        for i in range(1, len(r)):
            dy = (r[i][0] - r[i - 1][0]) * 111320
            dx = (r[i][1] - r[i - 1][1]) * 111320 * math.cos(math.radians(r[i][0]))
            t += math.hypot(dx, dy)
    return t


def _seg_x(a, b, c, d):
    def ccw(p, q, r): return (r[0] - p[0]) * (q[1] - p[1]) - (q[0] - p[0]) * (r[1] - p[1])
    return ccw(a, c, d) * ccw(b, c, d) < 0 and ccw(a, b, c) * ccw(a, b, d) < 0


def _in_poly(pt, poly):
    x, y = pt[1], pt[0]; inside = False; n = len(poly); j = n - 1
    for i in range(n):
        xi, yi = poly[i][1], poly[i][0]; xj, yj = poly[j][1], poly[j][0]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-15) + xi:
            inside = not inside
        j = i
    return inside


def _overlap(p1, p2):
    for i in range(len(p1)):
        for j in range(len(p2)):
            if _seg_x(p1[i], p1[(i + 1) % len(p1)], p2[j], p2[(j + 1) % len(p2)]):
                return True
    return _in_poly(p1[0], p2) or _in_poly(p2[0], p1)


def _population(state):
    houses = sum(1 for b in state.get("buildings", []) if b.get("type") == "house")
    shops = sum(1 for b in state.get("buildings", []) if b.get("type") == "shop")
    return min(houses * RESIDENTS_PER_HOUSE, shops * JOBS_PER_SHOP + houses)  # ограничено работой


def _state_value(state):
    v = 0.0
    for b in state.get("buildings", []):
        v += COST_BUILD.get(b.get("type"), 0)
    v += _road_len_m(state.get("roads", [])) * COST_ROAD_PER_M
    v += _road_len_m(state.get("alleys", [])) * COST_ROAD_PER_M
    return v


class ClaimReq(BaseModel):
    name: str = Field("", max_length=80)
    color: str = Field("#D97757", max_length=32)
    border: list


class SaveReq(BaseModel):
    state: dict


@app.get("/api/nation/world")
def world(minlat: float = Query(...), minlng: float = Query(...),
          maxlat: float = Query(...), maxlng: float = Query(...)):
    bbox = (minlat, minlng, maxlat, maxlng)
    if any(not math.isfinite(v) for v in bbox):
        raise HTTPException(400, "Bounding box must be finite")
    if not (-90 <= minlat <= maxlat <= 90 and -180 <= minlng <= maxlng <= 180):
        raise HTTPException(400, "Bounding box is out of range")
    con = _db()
    rows = con.execute(
        "SELECT owner,name,color,border,cx,cy FROM country "
        "WHERE NOT (maxlat<? OR minlat>? OR maxlng<? OR minlng>?) "
        "ORDER BY updated DESC LIMIT ?",
        (minlat, maxlat, minlng, maxlng, _MAX_WORLD_COUNTRIES)).fetchall()
    con.close()
    return {"countries": [
        {"owner": r["owner"], "name": r["name"], "color": r["color"],
         "border": json.loads(r["border"]), "cx": r["cx"], "cy": r["cy"]}
        for r in rows]}


@app.websocket("/api/nation/ws")
async def world_ws(ws: WebSocket, token: str = Query("")):
    """Общий мир в реальном времени: клиент подписывается на bbox и получает
    снимок, дальше — push при claim/save любой страны в этом bbox.

    Данные мира публичные (как и REST /world), поэтому токен не обязателен:
    без него соединение работает в режиме просмотра, с лимитом на IP.
    """
    user = None
    if token:
        try:
            user = _user("Bearer " + token)
        except HTTPException:
            user = None
    ip = ws.client.host if ws.client else "unknown"
    anon = user is None
    if anon and _hub.anon_count(ip) >= _WS_ANON_PER_IP:
        await ws.close(code=4429)
        return
    await ws.accept()
    try:
        while True:
            raw = await ws.receive_text()
            if len(raw) > _WS_MAX_MSG:
                await ws.close(code=4400)
                break
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            if not isinstance(msg, dict):
                continue
            kind = msg.get("type")
            if kind == "ping":
                await ws.send_json({"type": "pong"})
                continue
            if kind != "sub":
                continue
            bbox = _norm_bbox(msg)
            if not bbox:
                continue
            _hub.add(ws, bbox, ip, anon)
            con = _db()
            rows = con.execute(
                "SELECT * FROM country WHERE archived=0 "
                "AND NOT (maxlat<? OR minlat>? OR maxlng<? OR minlng>?) "
                "ORDER BY updated DESC LIMIT ?",
                (bbox[0], bbox[2], bbox[1], bbox[3], _MAX_WORLD_COUNTRIES)).fetchall()
            con.close()
            await ws.send_json({"type": "snapshot",
                                "countries": [_country_payload(r, bbox) for r in rows]})
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        _hub.drop(ws)


@app.get("/api/nation/mine")
def get_mine(authorization: Optional[str] = Header(None)):
    user = _user(authorization)
    con = _db()
    r = con.execute("SELECT * FROM country WHERE owner=? AND archived=0", (user,)).fetchone()
    if not r:
        con.close(); return {"country": None}
    state = json.loads(r["state"] or "{}")
    pop = _population(state)
    now = int(time.time())
    hrs = max(0.0, (now - (r["last_income"] or now)) / 3600.0)
    bal = r["balance"] + pop * TAX_PER_CITIZEN_HR * hrs
    con.execute("UPDATE country SET balance=?, last_income=? WHERE owner=?", (bal, now, user))
    con.commit()
    res = {"owner": r["owner"], "name": r["name"], "color": r["color"],
           "border": json.loads(r["border"]), "state": state,
           "balance": round(bal, 1), "population": pop}
    con.close()
    return {"country": res}


@app.post("/api/nation/claim")
async def claim(req: ClaimReq, authorization: Optional[str] = Header(None)):
    user = _user(authorization)
    _validate_border(req.border)
    area = _area_km2(req.border)
    cost = area * CLAIM_COST_PER_KM2
    con = _db()
    # Serialize overlap check and country creation/update. Otherwise two
    # simultaneous claims could validate against the same stale map.
    con.execute("BEGIN IMMEDIATE")
    for o in con.execute("SELECT owner,border FROM country WHERE owner!=?", (user,)).fetchall():
        if _overlap(req.border, json.loads(o["border"])):
            con.rollback(); con.close()
            raise HTTPException(409, f"Граница пересекает территорию игрока {o['owner']}")
    now = int(time.time())
    bb = _bbox(req.border); cx, cy = _centroid(req.border)
    ex = con.execute("SELECT balance,border FROM country WHERE owner=?", (user,)).fetchone()
    if ex:
        # Расширение стоит gost по приросту площади; сжатие и перерисовка в
        # прежних границах — бесплатно.
        try: old_area = _area_km2(json.loads(ex["border"]))
        except Exception: old_area = 0.0
        cost = max(0.0, area - old_area) * CLAIM_COST_PER_KM2
        if cost > (ex["balance"] or 0):
            con.rollback(); con.close()
            raise HTTPException(402, f"Недостаточно gost для расширения (нужно {round(cost)} gost)")
        con.execute("UPDATE country SET name=?,color=?,border=?,cx=?,cy=?,"
                    "minlat=?,minlng=?,maxlat=?,maxlng=?,updated=?,balance=balance-? WHERE owner=?",
                    (req.name, req.color, json.dumps(req.border), cx, cy,
                     bb[0], bb[1], bb[2], bb[3], now, cost, user))
    else:
        cost = min(cost, START_BONUS)  # новичку хватает на стартовый участок
        con.execute("INSERT INTO country(owner,name,color,border,state,balance,built_value,"
                    "cx,cy,minlat,minlng,maxlat,maxlng,created,updated,last_income) "
                    "VALUES(?,?,?,?,'{}',?,0,?,?,?,?,?,?,?,?,?)",
                    (user, req.name, req.color, json.dumps(req.border), START_BONUS - cost,
                     cx, cy, bb[0], bb[1], bb[2], bb[3], now, now, now))
    con.commit()
    bal = con.execute("SELECT balance FROM country WHERE owner=?", (user,)).fetchone()["balance"]
    con.close()
    await _broadcast_country(user)          # мир видит новую границу сразу
    return {"ok": True, "balance": round(bal, 1), "area_km2": round(area, 4), "cost": round(cost, 1)}


@app.put("/api/nation/mine")
async def save_mine(req: SaveReq, authorization: Optional[str] = Header(None)):
    user = _user(authorization)
    con = _db()
    r = con.execute("SELECT border,state,balance,built_value FROM country WHERE owner=?", (user,)).fetchone()
    if not r:
        con.close(); raise HTTPException(404, "Сначала застолби территорию (claim)")
    border = json.loads(r["border"])
    st = req.state or {}
    encoded_state = json.dumps(st, ensure_ascii=False, separators=(",", ":"))
    if len(encoded_state.encode("utf-8")) > _MAX_STATE_BYTES:
        con.close()
        raise HTTPException(413, "Состояние слишком большое")
    try:
        _validate_state(st)
    except HTTPException:
        con.close()
        raise
    # Re-read under the write lock after all CPU-heavy validation.
    con.execute("BEGIN IMMEDIATE")
    r = con.execute("SELECT border,state,balance,built_value FROM country WHERE owner=?", (user,)).fetchone()
    if not r:
        con.rollback()
        con.close()
        raise HTTPException(404, "Сначала застолби территорию (claim)")
    border = json.loads(r["border"])
    # объекты только ВНУТРИ границы (анти-вылезание)
    st["buildings"] = [b for b in st.get("buildings", [])
                       if b.get("lat") is not None and _in_poly([b["lat"], b["lng"]], border)]
    # стоимость = прирост «стоимости застройки» над ранее оплаченным пиком (built_value ратчетится)
    val = _state_value(st)
    spend = max(0.0, val - (r["built_value"] or 0))
    if spend > r["balance"]:
        con.rollback()
        con.close()
        raise HTTPException(402, f"Недостаточно gost (нужно {round(spend)})")
    now = int(time.time())
    changed = con.execute(
        "UPDATE country SET state=?,balance=balance-?,built_value=?,updated=? "
        "WHERE owner=? AND balance>=?",
        (json.dumps(st, ensure_ascii=False, separators=(",", ":")), spend,
         max(r["built_value"] or 0, val), now, user, spend),
    ).rowcount
    if changed != 1:
        con.rollback()
        con.close()
        raise HTTPException(402, f"Недостаточно gost (нужно {round(spend)})")
    con.commit()
    bal = con.execute("SELECT balance FROM country WHERE owner=?", (user,)).fetchone()["balance"]
    con.close()
    await _broadcast_country(user)          # соседи видят новые постройки без перезагрузки
    return {"ok": True, "balance": round(bal, 1), "spent": round(spend, 1),
            "population": _population(st)}


@app.get("/api/nation/health")
def health():
    return {"ok": True, "service": "ghostnation"}


# ── Архивирование страны (вызывается из социалки при удалении аккаунта) ──
_NATION_INTERNAL_TOKEN = os.getenv("NATION_INTERNAL_TOKEN")

@app.post("/api/nation/cleanup_archived")
def cleanup_archived(days: int = Query(180), x_internal_token: Optional[str] = Header(None)):
    """Удаляет архивированные страны старше N дней (по умолчанию 180).
    Защищён внутренним токеном. Можно дергать из cron.
    """
    if not _NATION_INTERNAL_TOKEN or not x_internal_token or not hmac.compare_digest(x_internal_token, _NATION_INTERNAL_TOKEN):
        raise HTTPException(403, "Forbidden")
    if days < 1 or days > 3650:
        raise HTTPException(400, "days must be 1..3650")
    cutoff = int(time.time()) - days * 86400
    con = _db()
    rows = con.execute(
        "SELECT owner FROM country WHERE archived=1 AND COALESCE(archived_at,0) < ?",
        (cutoff,),
    ).fetchall()
    deleted = [r["owner"] for r in rows]
    if deleted:
        ph = ",".join("?" * len(deleted))
        con.execute(f"DELETE FROM country WHERE owner IN ({ph})", deleted)
        con.commit()
    con.close()
    return {"ok": True, "deleted": len(deleted), "cutoff_ts": cutoff}


@app.post("/api/nation/archive/{username}")
async def archive_country(username: str, x_internal_token: Optional[str] = Header(None)):
    """Архивирует страну юзера (постройки остаются на карте, но без владельца).
    Защищено внутренним токеном — вызывается из social_router при DELETE /me/account.
    """
    if not _NATION_INTERNAL_TOKEN or not x_internal_token or not hmac.compare_digest(x_internal_token, _NATION_INTERNAL_TOKEN):
        raise HTTPException(403, "Forbidden")
    uname = username.strip().lower()
    if not uname or len(uname) > 64:
        raise HTTPException(400, "Empty username")
    con = _db()
    r = con.execute("SELECT owner,minlat,minlng,maxlat,maxlng FROM country WHERE owner=?", (uname,)).fetchone()
    if not r:
        con.close()
        return {"ok": True, "archived": False, "reason": "no country"}
    now = int(time.time())
    new_owner = f"__archived__:{uname}"
    # Если такое имя уже занято (повторный архив) — добавим суффикс времени
    if con.execute("SELECT 1 FROM country WHERE owner=?", (new_owner,)).fetchone():
        new_owner = f"__archived__:{uname}:{now}"
    con.execute(
        "UPDATE country SET owner=?, archived=1, archived_at=?, prev_owner=? WHERE owner=?",
        (new_owner, now, uname, uname),
    )
    con.commit(); con.close()
    await _hub.broadcast((r["minlat"], r["minlng"], r["maxlat"], r["maxlng"]),
                         {"type": "remove", "owner": uname})
    return {"ok": True, "archived": True, "username": uname}
