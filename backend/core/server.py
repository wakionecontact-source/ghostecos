from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
import json
import sqlite3
import os
import random
import re
from typing import Dict, Set

app = FastAPI()

_CORS_ORIGINS = [
    origin.strip()
    for origin in os.getenv(
        "GC_CORS_ORIGINS",
        "https://ghostecos.duckdns.org,https://ghostchat.app,http://localhost,http://127.0.0.1",
    ).split(",")
    if origin.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

# post_id → набор подключённых WebSocket
theater_connections: Dict[str, Set[WebSocket]] = {}


def _bounded_int(name: str, default: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        value = default
    return max(1, min(value, maximum))


_THEATER_MAX_PER_POST = _bounded_int("GC_THEATER_MAX_PER_POST", 100, 1000)
_THEATER_MAX_TOTAL = _bounded_int("GC_THEATER_MAX_TOTAL", 2000, 10000)
_THEATER_POST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _theater_active_total() -> int:
    """Считаем живые сокеты без счётчика, который может разойтись при ошибках."""
    return sum(len(sockets) for sockets in theater_connections.values())


def get_db():
    db = sqlite3.connect("ghostsocial.db")
    db.row_factory = sqlite3.Row
    return db


def init_db():
    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS posts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            ghost_id    TEXT    NOT NULL,
            content     TEXT,
            media_url   TEXT,
            media_type  TEXT    DEFAULT 'image',
            likes       INTEGER DEFAULT 0,
            comments    INTEGER DEFAULT 0,
            hashtags    TEXT,
            gradient    TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    if db.execute("SELECT COUNT(*) FROM posts").fetchone()[0] == 0:
        sample = [
            ("ghost_4f2a", "Ночной город глазами призрака",    None, "image", 1203,  89,   "#город #ночь #призрак",       "linear-gradient(160deg,#0a0020 0%,#2d0050 100%)"),
            ("ghost_9c1b", "Когда понял что сервер лежит уже 6 часов, а ты его сам и выключил", None, "image", 4521, 234, "#dev #боль #программирование", "linear-gradient(160deg,#001a10 0%,#003d1a 100%)"),
            ("ghost_7e3d", "Абсолютная тишина в 3 ночи",       None, "image",  892,  45,   "#ночь #тишина #атмосфера",    "linear-gradient(160deg,#1a0000 0%,#3d0010 100%)"),
            ("ghost_2a8f", "Новая арт-работа готова",           None, "image", 7834, 512,  "#арт #творчество #digital",   "linear-gradient(160deg,#001a2c 0%,#003d5c 100%)"),
            ("ghost_5b6c", "Почему все мессенджеры сливают ваши данные — и что с этим делать", None, "image", 15203, 1089, "#приватность #безопасность #ghostchat", "linear-gradient(160deg,#1a1000 0%,#3d2000 100%)"),
            ("ghost_3e9a", "Нашёл старую кассету с записями 2008 года", None, "image", 3210, 178, "#ностальгия #воспоминания", "linear-gradient(160deg,#0a0a1a 0%,#1a1a3d 100%)"),
            ("ghost_8b2c", "Сделал детектор лжи на Python за вечер 💀", None, "image", 9870, 654, "#python #проекты #dev", "linear-gradient(160deg,#001010 0%,#003030 100%)"),
        ]
        db.executemany(
            "INSERT INTO posts (ghost_id, content, media_url, media_type, likes, comments, hashtags, gradient) VALUES (?,?,?,?,?,?,?,?)",
            sample
        )
        db.commit()
    db.close()


init_db()


@app.get("/api/feed")
def get_feed(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0, le=1_000_000),
):
    db = get_db()
    rows = db.execute(
        "SELECT * FROM posts ORDER BY id DESC LIMIT ? OFFSET ?", (limit, offset)
    ).fetchall()
    db.close()
    return [dict(r) for r in rows]


@app.post("/api/posts/{post_id}/like")
def like_post(post_id: int):
    db = get_db()
    db.execute("UPDATE posts SET likes = likes + 1 WHERE id = ?", (post_id,))
    db.commit()
    row = db.execute("SELECT likes FROM posts WHERE id = ?", (post_id,)).fetchone()
    db.close()
    return {"likes": row["likes"]}


@app.websocket("/ws/theater/{post_id}")
async def theater_ws(websocket: WebSocket, post_id: str):
    # Канал публичный, но нельзя создавать неограниченное число ключей комнат.
    # Иначе атакующий исчерпает память и лимит соединений.
    if not _THEATER_POST_ID_RE.fullmatch(post_id or ""):
        await websocket.close(code=1008)
        return

    room = theater_connections.setdefault(post_id, set())
    if (len(room) >= _THEATER_MAX_PER_POST
            or _theater_active_total() >= _THEATER_MAX_TOTAL):
        theater_connections.pop(post_id, None) if not room else None
        await websocket.close(code=1013)
        return

    # Резервируем место до первого await: иначе параллельные handshake обойдут лимиты.
    room.add(websocket)

    async def remove_socket() -> None:
        room = theater_connections.get(post_id)
        if room is None:
            return
        room.discard(websocket)
        if not room:
            theater_connections.pop(post_id, None)

    async def broadcast():
        count = len(theater_connections.get(post_id, set()))
        dead = set()
        for ws in list(theater_connections.get(post_id, set())):
            try:
                await ws.send_json({"type": "viewer_count", "count": count})
            except Exception:
                dead.add(ws)
        room = theater_connections.get(post_id)
        if room is not None:
            room.difference_update(dead)
            if not room:
                theater_connections.pop(post_id, None)

    try:
        await websocket.accept()
        await broadcast()

        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await remove_socket()
        await broadcast()


app.mount("/", StaticFiles(directory="static", html=True), name="static")
