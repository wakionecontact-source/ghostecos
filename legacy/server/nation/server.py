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
import os, json, math, time, sqlite3
from typing import Optional
from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel
import jwt

JWT_SECRET = os.getenv("GC_JWT_SECRET", "")
JWT_ALG = "HS256"
DB_PATH = os.getenv("NATION_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "nation.db"))

# ── Экономика (gost) — решено: налоги с населения + старт-бонус, всё стоит gost ──
START_BONUS         = 1500      # gost при создании страны
CLAIM_COST_PER_KM2  = 300       # gost за км² застолблённой территории
COST_BUILD          = {"house": 40, "shop": 70, "tree": 4}
COST_ROAD_PER_M     = 0.6       # дорога/переулок/жд
RESIDENTS_PER_HOUSE = 4         # население = дома × это (ограничено рабочими местами)
JOBS_PER_SHOP       = 12
TAX_PER_CITIZEN_HR  = 2.0       # gost в час с жителя

app = FastAPI(title="GhostNation API", docs_url=None, redoc_url=None, openapi_url=None)


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
    try:
        payload = jwt.decode(authorization[7:], JWT_SECRET, algorithms=[JWT_ALG])
    except Exception:
        raise HTTPException(401, "Invalid token")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(401, "Invalid token")
    return sub


# ── Геометрия ──
def _bbox(b):
    la = [p[0] for p in b]; ln = [p[1] for p in b]
    return min(la), min(ln), max(la), max(ln)


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
    name: str = ""
    color: str = "#D97757"
    border: list


class SaveReq(BaseModel):
    state: dict


@app.get("/api/nation/world")
def world(minlat: float = Query(...), minlng: float = Query(...),
          maxlat: float = Query(...), maxlng: float = Query(...)):
    con = _db()
    rows = con.execute(
        "SELECT owner,name,color,border,cx,cy FROM country "
        "WHERE NOT (maxlat<? OR minlat>? OR maxlng<? OR minlng>?)",
        (minlat, maxlat, minlng, maxlng)).fetchall()
    con.close()
    return {"countries": [
        {"owner": r["owner"], "name": r["name"], "color": r["color"],
         "border": json.loads(r["border"]), "cx": r["cx"], "cy": r["cy"]}
        for r in rows]}


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
def claim(req: ClaimReq, authorization: Optional[str] = Header(None)):
    user = _user(authorization)
    if len(req.border) < 3:
        raise HTTPException(400, "Border needs >=3 points")
    area = _area_km2(req.border)
    cost = area * CLAIM_COST_PER_KM2
    con = _db()
    for o in con.execute("SELECT owner,border FROM country WHERE owner!=?", (user,)).fetchall():
        if _overlap(req.border, json.loads(o["border"])):
            con.close(); raise HTTPException(409, f"Граница пересекает территорию игрока {o['owner']}")
    now = int(time.time())
    bb = _bbox(req.border); cx, cy = _centroid(req.border)
    ex = con.execute("SELECT balance FROM country WHERE owner=?", (user,)).fetchone()
    if ex:
        cost = 0   # перерисовка границы существующей страной — БЕСПЛАТНО (gost берётся только за первичный claim)
        con.execute("UPDATE country SET name=?,color=?,border=?,cx=?,cy=?,"
                    "minlat=?,minlng=?,maxlat=?,maxlng=?,updated=? WHERE owner=?",
                    (req.name, req.color, json.dumps(req.border), cx, cy,
                     bb[0], bb[1], bb[2], bb[3], now, user))
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
    return {"ok": True, "balance": round(bal, 1), "area_km2": round(area, 4), "cost": round(cost, 1)}


@app.put("/api/nation/mine")
def save_mine(req: SaveReq, authorization: Optional[str] = Header(None)):
    user = _user(authorization)
    con = _db()
    r = con.execute("SELECT border,state,balance,built_value FROM country WHERE owner=?", (user,)).fetchone()
    if not r:
        con.close(); raise HTTPException(404, "Сначала застолби территорию (claim)")
    border = json.loads(r["border"])
    st = req.state or {}
    # объекты только ВНУТРИ границы (анти-вылезание)
    st["buildings"] = [b for b in st.get("buildings", [])
                       if b.get("lat") is not None and _in_poly([b["lat"], b["lng"]], border)]
    # стоимость = прирост «стоимости застройки» над ранее оплаченным пиком (built_value ратчетится)
    val = _state_value(st)
    spend = max(0.0, val - (r["built_value"] or 0))
    if spend > r["balance"]:
        con.close(); raise HTTPException(402, f"Недостаточно gost (нужно {round(spend)})")
    now = int(time.time())
    con.execute("UPDATE country SET state=?,balance=balance-?,built_value=?,updated=? WHERE owner=?",
                (json.dumps(st), spend, max(r["built_value"] or 0, val), now, user))
    con.commit()
    bal = con.execute("SELECT balance FROM country WHERE owner=?", (user,)).fetchone()["balance"]
    con.close()
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
    if not _NATION_INTERNAL_TOKEN or x_internal_token != _NATION_INTERNAL_TOKEN:
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
def archive_country(username: str, x_internal_token: Optional[str] = Header(None)):
    """Архивирует страну юзера (постройки остаются на карте, но без владельца).
    Защищено внутренним токеном — вызывается из social_router при DELETE /me/account.
    """
    if not _NATION_INTERNAL_TOKEN or x_internal_token != _NATION_INTERNAL_TOKEN:
        raise HTTPException(403, "Forbidden")
    uname = username.strip().lower()
    if not uname:
        raise HTTPException(400, "Empty username")
    con = _db()
    r = con.execute("SELECT owner FROM country WHERE owner=?", (uname,)).fetchone()
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
    return {"ok": True, "archived": True, "username": uname}
