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

@app.get("/terms", include_in_schema=False)
async def terms():
    p = os.path.join(_SITE_DIR, "terms.html")
    if os.path.exists(p):
        return FileResponse(p)
    return {"error": "not found"}

def _esc_attr(s: str) -> str:
    s = s or ""
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def _serve_og_html(file_path: str, og_title: str, og_desc: str, og_image: str, og_url: str):
    """Подставляет OG meta-теги в HTML файл (заменяет <head>...<title>... блок).
    Краулеры (TG/WA/Twitter) читают meta-теги в первом байте — без JS."""
    from fastapi.responses import HTMLResponse
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            html = f.read()
    except Exception:
        return {"error": "not found"}
    # Собираем блок OG
    og_block = (
        f'<title>{_esc_attr(og_title)}</title>\n'
        f'  <meta name="description" content="{_esc_attr(og_desc)}">\n'
        f'  <meta property="og:title" content="{_esc_attr(og_title)}">\n'
        f'  <meta property="og:description" content="{_esc_attr(og_desc)}">\n'
        f'  <meta property="og:image" content="{_esc_attr(og_image)}">\n'
        f'  <meta property="og:url" content="{_esc_attr(og_url)}">\n'
        f'  <meta property="og:type" content="website">\n'
        f'  <meta name="twitter:card" content="summary_large_image">\n'
        f'  <meta name="twitter:title" content="{_esc_attr(og_title)}">\n'
        f'  <meta name="twitter:description" content="{_esc_attr(og_desc)}">\n'
        f'  <meta name="twitter:image" content="{_esc_attr(og_image)}">'
    )
    # Заменяем существующий <title>...</title> и все meta og:*/twitter:*/description на новый блок
    import re as _re
    # Сначала вырезаем старые
    html = _re.sub(r'<title>[^<]*</title>', '', html, count=1)
    html = _re.sub(r'<meta\s+name="description"[^>]*>', '', html, flags=_re.IGNORECASE)
    html = _re.sub(r'<meta\s+property="og:[^"]+"[^>]*>', '', html, flags=_re.IGNORECASE)
    html = _re.sub(r'<meta\s+name="twitter:[^"]+"[^>]*>', '', html, flags=_re.IGNORECASE)
    # Вставляем новый блок перед </head>
    html = html.replace('</head>', f'  {og_block}\n</head>', 1)
    return HTMLResponse(content=html)


@app.get("/wrapped", include_in_schema=False)
async def wrapped_index():
    return FileResponse(os.path.join(_SITE_DIR, "wrapped.html"))


@app.get("/wrapped/{username}", include_in_schema=False)
async def wrapped(username: str):
    p = os.path.join(_SITE_DIR, "wrapped.html")
    if not os.path.exists(p):
        return {"error": "not found"}
    uname = (username or "").strip().lower().lstrip("@")
    if not uname:
        return FileResponse(p)
    # Дергаем social API на 127.0.0.1:8005 за данными
    import urllib.request, json as _json
    title = f"@{uname} — Wrapped в GhostEcos"
    desc = "Личная статистика, реакции и любимые посты"
    try:
        r = urllib.request.urlopen(
            f"http://127.0.0.1:8005/api/soc/wrapped/{uname}", timeout=3
        )
        d = _json.loads(r.read())
        title = f"{d['display_name']}: год в GhostEcos"
        posts = d.get("posts", 0) + d.get("miniska", 0)
        desc = f"@{d['username']} · {posts} публикаций · {d.get('reactions_received', 0)} реакций · репутация {d.get('reputation', 100)}/100"
    except Exception:
        pass
    base = "https://ghostecos.duckdns.org"
    return _serve_og_html(
        p,
        og_title=title,
        og_desc=desc,
        og_image=f"{base}/api/soc/og/wrapped/{uname}.png",
        og_url=f"{base}/wrapped/{uname}",
    )


@app.get("/p/{post_id}", include_in_schema=False)
async def og_post_page(post_id: int):
    """Публичная shareable страница для поста — отдаёт HTML с OG-meta + редирект в /social."""
    import urllib.request, json as _json
    title = "Пост в GhostSocial"
    desc = "Открыть в приложении"
    try:
        r = urllib.request.urlopen(
            f"http://127.0.0.1:8005/api/soc/post/{post_id}", timeout=3,
        )
        d = _json.loads(r.read())
        if d.get("is_nsfw"):
            title = f"Пост (18+) от {d.get('display_name', '?')}"
            desc = "Контент 18+ — откройте в приложении"
        else:
            content = (d.get("content") or "").strip()
            title = (content[:80] + ("..." if len(content) > 80 else "")) if content else "Пост в GhostSocial"
            desc = f"{d.get('display_name', '?')} (@{d.get('username', '?')})"
    except Exception:
        pass
    base = "https://ghostecos.duckdns.org"
    # Минимальный HTML с OG + JS-редирект в /social
    from fastapi.responses import HTMLResponse
    html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>{_esc_attr(title)}</title>
  <meta name="description" content="{_esc_attr(desc)}">
  <meta property="og:title" content="{_esc_attr(title)}">
  <meta property="og:description" content="{_esc_attr(desc)}">
  <meta property="og:image" content="{base}/api/soc/og/post/{post_id}.png">
  <meta property="og:url" content="{base}/p/{post_id}">
  <meta property="og:type" content="article">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="{base}/api/soc/og/post/{post_id}.png">
  <meta http-equiv="refresh" content="0;url=/social/#p={post_id}">
  <link rel="canonical" href="{base}/social/#p={post_id}">
</head>
<body style="background:#020617;color:#94a3b8;font-family:sans-serif;text-align:center;padding:80px 20px;">
  <p>Открываю пост в GhostSocial...</p>
  <p><a href="/social/#p={post_id}" style="color:#a855f7;">Перейти вручную</a></p>
</body>
</html>"""
    return HTMLResponse(content=html)


def _og_redirect_page(title: str, desc: str, og_image: str, og_url: str,
                      redirect_url: str, og_type: str = "website") -> "HTMLResponse":
    """Минимальная HTML-страница с OG-meta + JS-редирект в приложение."""
    from fastapi.responses import HTMLResponse
    html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>{_esc_attr(title)}</title>
  <meta name="description" content="{_esc_attr(desc)}">
  <meta property="og:title" content="{_esc_attr(title)}">
  <meta property="og:description" content="{_esc_attr(desc)}">
  <meta property="og:image" content="{_esc_attr(og_image)}">
  <meta property="og:url" content="{_esc_attr(og_url)}">
  <meta property="og:type" content="{og_type}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="{_esc_attr(og_image)}">
  <meta http-equiv="refresh" content="0;url={_esc_attr(redirect_url)}">
  <link rel="canonical" href="{_esc_attr(og_url)}">
</head>
<body style="background:#020617;color:#94a3b8;font-family:sans-serif;text-align:center;padding:80px 20px;">
  <p>Открываю...</p>
  <p><a href="{_esc_attr(redirect_url)}" style="color:#a855f7;">Перейти вручную</a></p>
</body>
</html>"""
    return HTMLResponse(content=html)


@app.get("/g/{group_id}", include_in_schema=False)
async def og_group_page(group_id: int):
    """Публичная shareable страница для группы/канала по id."""
    import urllib.request, json as _json
    base = "https://ghostecos.duckdns.org"
    title, desc = f"Группа в GhostChat", "Открыть"
    redirect = f"/chat/?group={group_id}"
    try:
        # Берём из социалки (там есть chat_groups таблица)
        r = urllib.request.urlopen(f"http://127.0.0.1:8005/api/soc/og/group/{group_id}.png", timeout=3)
        r.read()  # прогреем кэш PNG
        # title не вытащить из PNG; обращаемся к public-эндпоинту если есть, иначе общий title
    except Exception:
        pass
    return _og_redirect_page(
        title=title, desc=desc,
        og_image=f"{base}/api/soc/og/group/{group_id}.png",
        og_url=f"{base}/g/{group_id}",
        redirect_url=redirect,
    )


@app.get("/c/{username}", include_in_schema=False)
async def og_channel_page(username: str):
    uname = (username or "").strip().lower().lstrip("@")
    base = "https://ghostecos.duckdns.org"
    return _og_redirect_page(
        title=f"@{uname} — канал в GhostChat", desc="Открыть канал",
        og_image=f"{base}/api/soc/og/channel/{uname}.png",
        og_url=f"{base}/c/{uname}",
        redirect_url=f"/chat/?channel={uname}",
    )


@app.get("/m/{post_id}", include_in_schema=False)
async def og_miniska_page(post_id: int):
    base = "https://ghostecos.duckdns.org"
    return _og_redirect_page(
        title=f"Миниска в GhostSocial", desc="Короткое видео · 48 ч",
        og_image=f"{base}/api/soc/og/miniska/{post_id}.png",
        og_url=f"{base}/m/{post_id}",
        redirect_url=f"/social/?msk={post_id}",
        og_type="video.other",
    )


@app.get("/nft/{nft_id}", include_in_schema=False)
async def og_nft_page(nft_id: int):
    base = "https://ghostecos.duckdns.org"
    return _og_redirect_page(
        title=f"NFT #{nft_id} в GhostBank", desc="Цифровой объект в коллекции",
        og_image=f"{base}/api/soc/og/nft/{nft_id}.png",
        og_url=f"{base}/nft/{nft_id}",
        redirect_url=f"/bank/?nft={nft_id}",
    )


@app.get("/u/{username}", include_in_schema=False)
async def og_user_page(username: str):
    """Публичная shareable страница для профиля — HTML с OG + редирект в /social."""
    import urllib.request, json as _json
    uname = (username or "").strip().lower().lstrip("@")
    title = f"@{uname} в GhostEcos"
    desc = "Открыть профиль"
    try:
        r = urllib.request.urlopen(
            f"http://127.0.0.1:8005/api/soc/prof/{uname}",
            timeout=3,
            # Без авторизации сработает как guest — отдаст public-инфу
        )
        d = _json.loads(r.read())
        title = f"{d.get('display_name', uname)} в GhostEcos"
        rep = d.get("reputation_score", 100)
        desc = f"@{d.get('username', uname)} · {d.get('posts_count', 0)} постов · {d.get('followers_count', 0)} подписчиков · репутация {rep}/100"
    except Exception:
        pass
    base = "https://ghostecos.duckdns.org"
    from fastapi.responses import HTMLResponse
    html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <title>{_esc_attr(title)}</title>
  <meta name="description" content="{_esc_attr(desc)}">
  <meta property="og:title" content="{_esc_attr(title)}">
  <meta property="og:description" content="{_esc_attr(desc)}">
  <meta property="og:image" content="{base}/api/soc/og/user/{uname}.png">
  <meta property="og:url" content="{base}/u/{uname}">
  <meta property="og:type" content="profile">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="{base}/api/soc/og/user/{uname}.png">
  <meta http-equiv="refresh" content="0;url=/social/#u={uname}">
  <link rel="canonical" href="{base}/social/#u={uname}">
</head>
<body style="background:#020617;color:#94a3b8;font-family:sans-serif;text-align:center;padding:80px 20px;">
  <p>Открываю профиль...</p>
  <p><a href="/social/#u={uname}" style="color:#a855f7;">Перейти вручную</a></p>
</body>
</html>"""
    return HTMLResponse(content=html)

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
