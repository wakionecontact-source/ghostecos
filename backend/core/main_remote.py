"""
Сервер релея GhostChat  v2.0
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
from datetime import datetime, timezone

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.requests import Request as _StarletteRequest

import config
import database as db
import security
from ws.manager import manager
from ws.handlers import handle_packet
from stun_udp import start_stun_server
import bot_check
from routers import auth, users, channels, files, shop, support, admin, downloads

# ── Логирование ───────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("gc")

# ── Время жизни ────────────────────────────────────

@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.migrate()
    log.info("DB migrated OK")
    stun_transport = await start_stun_server()
    task = asyncio.create_task(_background_loop())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    stun_transport.close()

_last_deep_cleanup = 0.0

# Ограничения частоты подключений мало: клиент может держать несколько сокетов
# вечно. Ограничиваем и живые соединения, чтобы пустые не отъедали память.
# Счётчики процессные, как in-memory WS manager.
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
    """Тот же proxy-trust, что и в HTTP rate limit."""
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

# ── Приложение ─────────────────────────────────────

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
    # Только HTTPS-origin'ы из окружения. HTTP-IP и localhost в production
    # позволяли открывать API из недоверенного контекста/перехватываемого origin.
    allow_origins=[
        origin.strip()
        for origin in os.getenv("GC_CORS_ORIGINS", "https://ghostchat.app").split(",")
        if origin.strip()
    ],
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type",
                   "X-Admin-Token", "X-Internal-Key", "X-Ghost-Bypass",
                   "X-Ghost-Bot-Token", "X-Altcha"],
)

# ── Middleware DDoS ────────────────────────────────

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
    # Nginx перезаписывает X-Real-IP и хелпер доверяет ему только от локального
    # прокси. request.client.host сгруппировал бы всех под 127.0.0.1.
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


# Ограничиваем параллельную анонимную авторизацию. IP-лимитер считает объём
# за время, а этот кап — всплеск с многих IP: отдаём повторяемый JSON вместо
# очереди неограниченных вычислений Argon2.
_PREAUTH_PATH_PREFIXES = ("/register", "/login")
try:
    _PREAUTH_MAX_INFLIGHT = max(1, min(
        int(os.getenv("GC_PREAUTH_MAX_INFLIGHT", "100")), 5000
    ))
except (TypeError, ValueError):
    _PREAUTH_MAX_INFLIGHT = 100
_PREAUTH_SLOTS = asyncio.Semaphore(_PREAUTH_MAX_INFLIGHT)


@app.middleware("http")
async def preauth_admission(request: Request, call_next):
    if not any(request.url.path.startswith(p) for p in _PREAUTH_PATH_PREFIXES):
        return await call_next(request)
    try:
        await asyncio.wait_for(_PREAUTH_SLOTS.acquire(), timeout=0.02)
    except asyncio.TimeoutError:
        from fastapi.responses import JSONResponse
        return JSONResponse(
            {
                "code": "service_busy",
                "message": "Сервис под нагрузкой, попробуйте позже",
            },
            status_code=503,
            headers={"Retry-After": "15", "Cache-Control": "no-store"},
        )
    try:
        return await call_next(request)
    finally:
        _PREAUTH_SLOTS.release()

# ── Роутеры ───────────────────────────────────────────────────────────────────

app.include_router(auth.router)
app.include_router(bot_check.router, prefix="/api")
app.include_router(users.router)
app.include_router(channels.router)
app.include_router(files.router)
app.include_router(shop.router)
app.include_router(support.router)
app.include_router(admin.router)
app.include_router(downloads.router, prefix="/api")

# ── WebSocket ─────────────────────────────────────────────────────────────────

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    import json as _json
    from ws.crypto import ServerSession

    ws_ip = _ws_ip(ws)
    # WebSocket идёт мимо HTTP middleware, поэтому лимитер соединений
    # применяем до приёма сокета. Иначе злоумышленник откроет бесконечно
    # пустых соединений и исчерпает память.
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

        # ── Эфемерная сессия на WS-соединение ───────────────────────────────
        # Эфемерный X25519 ключ на каждое соединение → AES-256-GCM для всех пакетов
        session = ServerSession()
        conn.session = session

        # Отправить hello с pub-ключом (без шифрования — сессия ещё не установлена)
        await ws.send_text(_json.dumps({"type": "hello", "pub": session.pub_b64}))

        # ── Авто-аутентификация из query-params (обратная совместимость) ──────
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
    info = _VERSION_INFO.get(config.LATEST_VERSION, {})
    return {
        "latest": config.LATEST_VERSION,
        "critical": _version_critical(config.LATEST_VERSION, info),
        "title": info.get("title", "Обновление GhostChat"),
        "release_at": config.BETA_RELEASE_AT,
        "available": _release_open(),
    }


_VERSION_INFO = {
    "1.2.1": {
        "title": 'Открытая бета',
        "critical": False,
        "notes": 'Масштабное обновление GhostChat: звонки, группы и каналы, боты, профили, контакты, E2EE V2 и улучшения стабильности.',
        "whats_new": [
            'Голосовые и видеозвонки с входящими уведомлениями и обработкой одновременных вызовов.',
            'Публичные и приватные группы и каналы с ролями, заявками, приглашениями и настройкой истории.',
            'До 10 активных ботов на один аккаунт; подключение через ghostecos-api.',
            'Настраиваемые баннеры профиля до 10 цветов и музыка в профилях.',
            'Возвращены контакты и добавлены новые настройки приватности, уведомлений, сети и хранилища.',
            'Улучшены E2EE V2, восстановление ключей на новых устройствах, доставка сообщений и офлайн-очередь.',
            'Исправлены регистрация и синхронизация локального состояния.',
        ],
    },
    "1.1.26": {
        "title": "Открытая бета",
        "critical": False,
        "notes": "Исправлены проблемы с шифрованием, добавлен видеоплеер в чат и просмотр сообщений в реальном времени.",
        "whats_new": [
            "Исправлены проблемы с шифрованием.",
            "Добавлен видеоплеер в чат.",
            "Сообщения отмечаются просмотренными в реальном времени, пока чат открыт.",
        ],
    },
    "1.1.25": {
        "title": "Открытая бета",
        "critical": True,
        "notes": "Важно: сначала в текущем GhostChat откройте Настройки → Ключи шифрования → Зашифровать ключ на сервере и дождитесь успешного сохранения. Только после этого скачивайте v1.1.25. Из-за нового ключа подписи установка поверх старой версии может не сработать; удалять старую версию можно только после сохранения ключа.",
        "whats_new": [
            "Видео в чате получили компактный проигрыватель: одна кнопка воспроизведения и таймер длительности в секундах.",
            "Исправлена отправка видео: зашифрованные метаданные укладываются в допустимый формат сервера.",
            "Удалённые чаты больше не возвращают старые сообщения при последующей синхронизации.",
            "Локальный и серверный публичные ключи сравниваются при запуске и входе; добавлен явный вариант «Пропустить» на экранах ключей.",
            "Настройки упорядочены: резервная копия отдельно в «Данные», импорт и экспорт — в «Скоро», «Бета-функции» — внизу.",
        ],
    },
    "1.1.24": {
        "title": "Открытая бета",
        "critical": False,
        "notes": "Исправления отправки медиа и переключения аккаунтов.",
        "whats_new": [
            "Исправлена отправка больших зашифрованных медиафайлов.",
            "Исправлено смешивание аккаунтов после переключения.",
        ],
    },
    "1.1.23": {
        "title": "Открытая бета",
        "critical": False,
        "notes": "Обновление GhostChat с улучшениями стабильности и диагностики.",
        "whats_new": [
            "Понятные ошибки: краткое сообщение, детали и переход к нужной записи лога.",
            "Копирование строк и выделение текста в журнале логов.",
            "Профиль сохраняет доступные данные при временной ошибке загрузки.",
            "Исправлены CAPTCHA-поля и отображение @username.",
        ],
    },
    "1.1.21": {
        "title": "Предыдущая сборка",
        "critical": False,
        "notes": "Стабильная предыдущая сборка GhostChat.",
        "whats_new": [],
    },
}


def _release_open() -> bool:
    try:
        release_at = datetime.fromisoformat(config.BETA_RELEASE_AT).astimezone(timezone.utc)
    except (TypeError, ValueError):
        return False
    return datetime.now(timezone.utc) >= release_at


def _version_critical(version: str, info: dict) -> bool:
    return bool(info.get("critical", False)) or (
        version == config.LATEST_VERSION and config.LATEST_CRITICAL
    )


@app.get("/api/version/{version}")
async def get_version_details(version: str):
    if len(version) > 32 or any(ch not in "0123456789.-" for ch in version):
        raise HTTPException(400, "Некорректная версия")
    info = _VERSION_INFO.get(version)
    if info is None and version != config.LATEST_VERSION:
        raise HTTPException(404, "Версия не найдена")
    info = info or {
        "title": "Обновление GhostChat",
        "critical": False,
        "notes": "Доступна новая версия GhostChat.",
        "whats_new": [],
    }
    return {
        "version": version,
        "latest": config.LATEST_VERSION,
        "is_latest": version == config.LATEST_VERSION,
        "critical": _version_critical(version, info),
        "title": info.get("title", "Обновление GhostChat"),
        "notes": info.get("notes", ""),
        "whats_new": info.get("whats_new", []),
        "release_at": config.BETA_RELEASE_AT,
        "available": _release_open(),
        "download": "/api/download/update",
    }

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

@app.get("/download/latest", include_in_schema=False)
async def public_download_latest():
    return RedirectResponse(
        url=f"/download/v{config.LATEST_VERSION}/",
        status_code=302,
        headers={"Cache-Control": "no-store"},
    )

@app.get("/download/v{version}", include_in_schema=False)
async def public_download_version(version: str):
    if version != config.LATEST_VERSION:
        raise HTTPException(status_code=404, detail="APK version is not available")
    try:
        release_at = datetime.fromisoformat(config.BETA_RELEASE_AT).astimezone(timezone.utc)
    except (TypeError, ValueError):
        release_at = datetime.max.replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) < release_at:
        raise HTTPException(status_code=410, detail="APK download is not open yet")
    apk_path = f"/opt/ghostchat/apk/GhostChat_V{config.LATEST_VERSION}ob.apk"
    if not os.path.isfile(apk_path):
        raise HTTPException(status_code=404, detail="No APK available")
    return FileResponse(
        apk_path,
        media_type="application/vnd.android.package-archive",
        filename=f"GhostChat_V{config.LATEST_VERSION}ob.apk",
        headers={"Cache-Control": "no-store"},
    )

@app.get("/api/download/latest", include_in_schema=False)
async def download_latest():
    return await public_download_version(config.LATEST_VERSION)

# Статика (JS/CSS/images) если есть
_STATIC_DIR = os.path.join(_SITE_DIR, "static")
if os.path.isdir(_STATIC_DIR):
    app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")

# ── Проверка здоровья ──────────────────────────────

@app.get("/health", include_in_schema=False)
async def health():
    return {"ok": True, **manager.stats()}
