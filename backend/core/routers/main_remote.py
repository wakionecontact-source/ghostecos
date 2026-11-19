"""
GhostChat relay-сервер v2.0: единая БД, aiosqlite, JWT, Argon2,
DDoS-защита с bypass-токеном, метаданные только в RAM.
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
from starlette.requests import Request as _StarletteRequest

import config
import database as db
import security
from ws.manager import manager
from ws.handlers import handle_packet
from routers import auth, users, channels, files, shop, support, admin

# ── Логирование ───────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("gc")

# ── Время жизни приложения ──────────────────────────────────────────────

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


def _positive_cap(name: str, default: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        value = default
    return max(1, min(value, maximum))


_WS_MAX_ACTIVE_PER_IP = _positive_cap("GC_WS_MAX_ACTIVE_PER_IP", 20, 1000)
_WS_MAX_ACTIVE_TOTAL = _positive_cap("GC_WS_MAX_ACTIVE_TOTAL", 2000, 100_000)
_WS_ACTIVE_BY_IP: dict[str, int] = {}
_WS_ACTIVE_TOTAL = 0
_WS_ACTIVE_LOCK = asyncio.Lock()


def _ws_ip(ws: WebSocket) -> str:
    try:
        return security._get_ip(_StarletteRequest(ws.scope))
    except Exception:
        return ws.client.host if ws.client else "unknown"


async def _reserve_ws_slot(ip: str) -> bool:
    global _WS_ACTIVE_TOTAL
    async with _WS_ACTIVE_LOCK:
        if (_WS_ACTIVE_TOTAL >= _WS_MAX_ACTIVE_TOTAL or
                _WS_ACTIVE_BY_IP.get(ip, 0) >= _WS_MAX_ACTIVE_PER_IP):
            return False
        _WS_ACTIVE_BY_IP[ip] = _WS_ACTIVE_BY_IP.get(ip, 0) + 1
        _WS_ACTIVE_TOTAL += 1
        return True


async def _release_ws_slot(ip: str) -> None:
    global _WS_ACTIVE_TOTAL
    async with _WS_ACTIVE_LOCK:
        current = _WS_ACTIVE_BY_IP.get(ip, 0)
        if current <= 1:
            _WS_ACTIVE_BY_IP.pop(ip, None)
        else:
            _WS_ACTIVE_BY_IP[ip] = current - 1
        _WS_ACTIVE_TOTAL = max(0, _WS_ACTIVE_TOTAL - 1)


async def _background_loop():
    """Фоновая задача: heartbeat + очистка файлов + ежесуточная очистка БД."""
    from routers.files import cleanup_expired_files
    import time as _time
    global _last_deep_cleanup
    while True:
        await asyncio.sleep(10)
        # ── Пульс ──────────────────────────────────────────────────────────
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

# ── Приложение ──────────────────────────────────────────────────────────

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
        origin.strip()
        for origin in os.getenv("GC_CORS_ORIGINS", "https://ghostchat.app").split(",")
        if origin.strip()
    ],
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type",
                   "X-Admin-Token", "X-Internal-Key", "X-Ghost-Bypass"],
)

# ── Защита от DDoS ───────────────────────────────────────────────────────

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
    # Проверяем bypass (для разработчика/сервисов)
    bypass = request.headers.get("X-Ghost-Bypass", "")
    if bypass and config.BYPASS_TOKEN and security.safe_equal(bypass, config.BYPASS_TOKEN):
        return await call_next(request)
    # Глобальный лимит по IP (очень мягкий — защита от flood)
    ip = security._get_ip(request)
    try:
        security.check_global_rate(ip)
    except Exception:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=429, content={"detail": "Too many requests"})
    return await call_next(request)


@app.middleware("http")
async def request_size_guard(request: Request, call_next):
    """Отбрасывает oversized JSON до того, как FastAPI/Pydantic развернёт его."""
    raw_length = request.headers.get("content-length")
    if raw_length:
        try:
            length = int(raw_length)
        except ValueError:
            length = 2 * 1024 * 1024 + 1
        content_type = (request.headers.get("content-type") or "").lower()
        limit = 65 * 1024 * 1024 if "multipart/form-data" in content_type else 2 * 1024 * 1024
        if length > limit:
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=413, content={"detail": "Request body is too large"})
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
    ws_ip = _ws_ip(ws)
    try:
        if not security.check_ws_rate(_StarletteRequest(ws.scope)):
            await ws.close(code=1013)
            return
    except Exception:
        await ws.close(code=1013)
        return

    if not await _reserve_ws_slot(ws_ip):
        await ws.close(code=1013)
        return

    conn = None
    try:
        conn = await manager.connect(ws)
        # Авто-аутентификация если токен передан в query-параметре (?token=...)
        # Nginx убирает креды из query в приватные заголовки, чтобы JWT не попадали в access-логи.
        token_qp = ws.headers.get("x-gc-token", "") or ws.query_params.get("token", "")
        device_qp = ws.headers.get("x-gc-device-id", "") or ws.query_params.get("device_id", "")
        if token_qp:
            # Шлём синтетический auth-пакет через handle_packet
            import json as _json
            await handle_packet(conn, _json.dumps({
                "type": "auth",
                "token": token_qp,
                "device_id": device_qp,
            }))

        while True:
            raw = await ws.receive_text()
            await handle_packet(conn, raw)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.debug(f"ws error: {e}")
    finally:
        went_offline = await manager.disconnect(conn) if conn is not None else False
        await _release_ws_slot(ws_ip)
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

@app.get("/terms", include_in_schema=False)
async def terms():
    p = os.path.join(_SITE_DIR, "terms.html")
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

# Статика (JS/CSS/изображения) если есть
_STATIC_DIR = os.path.join(_SITE_DIR, "static")
if os.path.isdir(_STATIC_DIR):
    app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")

# ── Проверка состояния ──────────────────────────────────────────────────────────

@app.get("/health", include_in_schema=False)
async def health():
    return {"ok": True, **manager.stats()}
