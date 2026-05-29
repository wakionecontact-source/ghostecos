"""
GhostChat Relay Server  v2.0
============================

Полностью переписан: единая БД, aiosqlite, JWT, Argon2,
DDoS-защита с bypass-токеном, метаданные только в RAM.

Запуск:
    uvicorn main_remote:app --host 127.0.0.1 --port 8000
"""
from __future__ import annotations

import asyncio
import glob as _glob
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import config
import database as db
from ws.manager import manager
from ws.handlers import handle_packet
from routers import auth, users, channels, files, shop, support, admin

# ── Логирование ───────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("gc")

# ── Lifespan ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.migrate()
    log.info("DB migrated OK")
    task = asyncio.create_task(_background_loop())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

_last_deep_cleanup = 0.0

async def _background_loop():
    """Фоновая задача: heartbeat + очистка файлов + ежесуточная очистка БД."""
    from routers.files import cleanup_expired_files
    import time as _time
    global _last_deep_cleanup
    while True:
        await asyncio.sleep(10)
        # ── Heartbeat ──────────────────────────────────────────────────────────
        try:
            went_offline = await manager.check_heartbeats()
            for username in went_offline:
                await _notify_presence(username, online=False)
        except Exception as e:
            log.error(f"heartbeat error: {e}")
        # ── Очистка истёкших файлов (каждые 10 сек) ───────────────────────────
        try:
            await cleanup_expired_files()
        except Exception as e:
            log.error(f"file cleanup error: {e}")
        # ── Глубокая очистка БД (раз в сутки) ────────────────────────────────
        now = _time.monotonic()
        if now - _last_deep_cleanup > 86400:
            _last_deep_cleanup = now
            try:
                import security as _sec
                _sec.cleanup_rate_limiters()
                stats = await db.cleanup_old_data()
                log.info(f"daily cleanup: {stats}")
            except Exception as e:
                log.error(f"daily cleanup error: {e}")


async def _notify_presence(username: str, online: bool):
    """Разослать peer_online/peer_offline контактам пользователя."""
    contacts = await db.fetchall(
        "SELECT user_b FROM contacts WHERE user_a = ?", (username,)
    )
    evt_type = "peer_online" if online else "peer_offline"
    await manager.broadcast(
        [c["user_b"] for c in contacts],
        {"type": evt_type, "username": username},
        exclude_user=None,
    )

# ── App ───────────────────────────────────────────────────────────────────────

_enable_docs = os.environ.get("GHOSTCHAT_ENABLE_DOCS", "").lower() in ("1", "true", "yes")

app = FastAPI(
    title="GhostChat Relay Server",
    version="2.0.0",
    docs_url="/docs"        if _enable_docs else None,
    redoc_url="/redoc"      if _enable_docs else None,
    openapi_url="/openapi.json" if _enable_docs else None,
    lifespan=lifespan,
)

if _enable_docs:
    log.warning("OpenAPI /docs ENABLED — отключи в проде (GHOSTCHAT_ENABLE_DOCS)")

# ── CORS ──────────────────────────────────────────────────────────────────────

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://155.212.166.221",
        "https://ghostchat.app",
        "http://localhost",
    ],
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type",
                   "X-Admin-Token", "X-Internal-Key", "X-Ghost-Bypass"],
)

# ── DDoS middleware ───────────────────────────────────────────────────────────

@app.middleware("http")
async def security_headers(request: Request, call_next):
    """Добавляет security headers ко всем ответам."""
    response = await call_next(request)
    response.headers["X-Content-Type-Options"]  = "nosniff"
    response.headers["X-Frame-Options"]          = "DENY"
    response.headers["X-XSS-Protection"]         = "1; mode=block"
    response.headers["Referrer-Policy"]           = "no-referrer"
    response.headers["Permissions-Policy"]        = "geolocation=(), camera=(), microphone=()"
    response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdnjs.cloudflare.com; font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com; script-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'"
    # HSTS только для HTTPS
    if request.url.scheme == "https":
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


@app.middleware("http")
async def ddos_guard(request: Request, call_next):
    """Глобальная защита: bypass-токен позволяет обойти rate limit."""
    import security
    # Проверяем bypass (для разработчика/сервисов)
    bypass = request.headers.get("X-Ghost-Bypass", "")
    if bypass and config.BYPASS_TOKEN and security.safe_equal(bypass, config.BYPASS_TOKEN):
        return await call_next(request)
    # Глобальный IP rate limit (очень мягкий — просто защита от flood)
    ip = request.client.host if request.client else "unknown"
    try:
        security.check_global_rate(ip)
    except Exception:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=429, content={"detail": "Too many requests"})
    return await call_next(request)

# ── Роутеры ───────────────────────────────────────────────────────────────────

app.include_router(auth.router)
app.include_router(users.router)
app.include_router(channels.router)
app.include_router(files.router)
app.include_router(shop.router)
app.include_router(support.router)
app.include_router(admin.router)

# ── WebSocket ─────────────────────────────────────────────────────────────────

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    import json as _json
    from ws.crypto import ServerSession

    conn = await manager.connect(ws)

    # ── Ephemeral session per WS connection ───────────────────────────────────
    # Эфемерный X25519 ключ на каждое соединение → AES-256-GCM для всех пакетов
    session = ServerSession()
    conn.session = session

    # Отправить hello с pub-ключом (без шифрования — сессия ещё не установлена)
    await ws.send_text(_json.dumps({"type": "hello", "pub": session.pub_b64}))

    # ── Авто-аутентификация из query-params (обратная совместимость) ──────────
    # Клиенты, передающие ?token=..., аутентифицируются без key_exchange.
    # Их пакеты остаются незашифрованными на WS-слое (TLS поверх всё равно есть).
    token_qp  = ws.query_params.get("token", "")
    device_qp = ws.query_params.get("device_id", "")
    if token_qp:
        await handle_packet(conn, _json.dumps({
            "type":      "auth",
            "token":     token_qp,
            "device_id": device_qp,
        }))

    try:
        while True:
            raw = await ws.receive_text()
            await handle_packet(conn, raw)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.debug(f"ws error: {e}")
    finally:
        went_offline = await manager.disconnect(conn)
        if went_offline and conn.username:
            await _notify_presence(conn.username, online=False)

# ── Версия приложения ─────────────────────────────────────────────────────────

@app.get("/api/version")
async def get_version():
    return {"latest": config.LATEST_VERSION}

# ── Статические файлы / сайт ──────────────────────────────────────────────────

_SITE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")

@app.get("/", include_in_schema=False)
async def landing():
    idx = os.path.join(_SITE_DIR, "index.html")
    if os.path.exists(idx):
        return FileResponse(idx)
    return {"status": "GhostChat server running"}

@app.get("/privacy", include_in_schema=False)
async def privacy():
    p = os.path.join(_SITE_DIR, "privacy.html")
    if os.path.exists(p):
        return FileResponse(p)
    return {"error": "not found"}

@app.get("/api/download/latest", include_in_schema=False)
async def download_latest():
    apks = sorted(
        _glob.glob(os.path.join(_SITE_DIR, "GhostChat-v*.apk")),
        key=lambda f: os.path.getmtime(f),
        reverse=True,
    )
    if not apks:
        from fastapi import HTTPException
        raise HTTPException(404, "No APK available")
    return FileResponse(
        apks[0],
        media_type="application/vnd.android.package-archive",
        filename=os.path.basename(apks[0]),
    )

# Статика (JS/CSS/images) если есть
_STATIC_DIR = os.path.join(_SITE_DIR, "static")
if os.path.isdir(_STATIC_DIR):
    app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")

# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health", include_in_schema=False)
async def health():
    return {"ok": True, **manager.stats()}
