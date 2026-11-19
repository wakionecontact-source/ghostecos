from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware
from social_router import DB as SOCIAL_DB
from social_router import router as social_router
from chat_router import router as chat_router
from bot_api import router as bot_api_router
from channel_router_v2 import router as channel_router_v2
from room_router_v2 import router as room_router_v2
import os
import sqlite3

app = FastAPI(title="GhostSocial Standalone API", docs_url=None, redoc_url=None, openapi_url=None)


def _ensure_about_column() -> None:
    """Досоздаёт колонку профиля в БД от старых релизов."""
    conn = sqlite3.connect(SOCIAL_DB)
    try:
        columns = {
            row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()
        }
        if columns and "about" not in columns:
            conn.execute("ALTER TABLE users ADD COLUMN about TEXT NOT NULL DEFAULT ''")
        if columns and "key_kdf" not in columns:
            conn.execute("ALTER TABLE users ADD COLUMN key_kdf TEXT DEFAULT NULL")
        if columns and "key_format" not in columns:
            conn.execute("ALTER TABLE users ADD COLUMN key_format TEXT DEFAULT NULL")
        if columns and "terms_version" not in columns:
            conn.execute("ALTER TABLE users ADD COLUMN terms_version INTEGER NOT NULL DEFAULT 1")
            conn.commit()
        if columns and ("about" not in columns or "key_kdf" not in columns or "key_format" not in columns):
            conn.commit()
    finally:
        conn.close()


# social_app — продовый вход, он не вызывает database.migrate() из backchat.
# Поэтому старые общие БД защищаем здесь же.
_ensure_about_column()


# ── Заголовки безопасности ──────────────────────────────────────────────
# Защитные HTTP-заголовки на все ответы. HSTS на проде ставит nginx, остальное здесь.
_PRIVATE_PATH_PREFIXES = (
    "/api/soc/me", "/api/soc/notif", "/api/soc/feed", "/api/soc/search",
    "/api/chat/me", "/api/chat/keys/me", "/api/chat/pending",
    "/api/chat/unread", "/api/chat/contacts",
    "/api/bots",
)

class _SecHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        if "server" in response.headers:
            del response.headers["server"]
        path = request.url.path
        if any(path.startswith(p) for p in _PRIVATE_PATH_PREFIXES):
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
            response.headers["Pragma"] = "no-cache"
        return response

app.add_middleware(_SecHeadersMiddleware)


# ── Глобальный лимит частоты запросов ────────────────────────────────────────────
# Дополнительная защита поверх per-endpoint лимитов: общий потолок запросов
# с одного клиента в минуту. Pentest waki (2026-06-20) показал что одна
# DevTools-консоль с for-loop кладёт сервер за секунды, если на конкретном
# endpoint не было лимита. 61 endpoint из 176 ходили без _rate_limit —
# точечно править все долго, поэтому здесь общий "circuit breaker".
import time as _gtime
from collections import deque as _gdq
_RL_BUCKETS: dict = {}   # ключ → deque[timestamps]
_RL_MAX = 600            # запросов (300 не хватало активному юзеру: фид+wallet+notif+counts+newhere)
_RL_WINDOW = 60          # за секунд
_RL_EXCLUDE_PREFIXES = ("/api/soc/ws",)  # WebSocket свой keepalive имеет

def _rl_key(req: Request) -> str:
    a = req.headers.get("authorization") or ""
    if a.startswith("Bearer ") and len(a) > 16:
        return "t:" + a[7:23]  # префикс достаточен для группировки
    # Иначе — по IP. nginx ставит X-Forwarded-For.
    xff = req.headers.get("x-forwarded-for") or ""
    if xff:
        return "ip:" + xff.split(",")[0].strip()
    return "ip:" + (req.client.host if req.client else "?")

class _GlobalRateLimitMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not any(path.startswith(p) for p in _RL_EXCLUDE_PREFIXES):
            key = _rl_key(request)
            now = _gtime.time()
            dq = _RL_BUCKETS.setdefault(key, _gdq())
            while dq and now - dq[0] > _RL_WINDOW:
                dq.popleft()
            if len(dq) >= _RL_MAX:
                from starlette.responses import JSONResponse
                retry_after = int(_RL_WINDOW - (now - dq[0])) + 1
                return JSONResponse(
                    {"detail": "Слишком много запросов, подождите немного"},
                    status_code=429,
                    headers={"Retry-After": str(retry_after)},
                )
            dq.append(now)
            if len(_RL_BUCKETS) > 5000 and len(dq) == 1:
                cutoff = now - _RL_WINDOW * 2
                stale = [k for k, d in _RL_BUCKETS.items() if not d or d[-1] < cutoff]
                for k in stale[:1000]:
                    _RL_BUCKETS.pop(k, None)
        return await call_next(request)

app.add_middleware(_GlobalRateLimitMiddleware)


# Обязательная проверка ежедневного статуса — только на сервере.
# Иначе расширения и прямые вызовы обойдут модалку.
# Исключения: авторизация и чтение/управление статусом, чтобы пользователь
# мог себя разблокировать.
class _DailyStatusGateMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if not path.startswith("/api/soc/"):
            return await call_next(request)
        suffix = path[len("/api/soc"):]
        allowed_exact = {
            "/login", "/register", "/register/v2", "/auth/login", "/auth/register",
            "/status/my", "/status/set", "/status/eternal", "/status/eternal/delete",
        }
        if suffix in allowed_exact or suffix.startswith("/auth/"):
            return await call_next(request)
        authorization = request.headers.get("authorization")
        if not authorization:
            # Для анонимных эндпоинтов оставляем обычную авторизацию:
            # сам эндпоинт решит, нужна ли она.
            return await call_next(request)
        from social_router import auth_member, db, _resolve_status
        try:
            user = auth_member(authorization)
        except Exception:
            # Недействительная, истёкшая или гостевая сессия: эндпоинт сам ответит 401/403.
            # Маскировка под 503 ломала публичные эндпоинты (поиск пользователей) при старом токене.
            return await call_next(request)
        try:
            conn = db()
            row = conn.execute(
                "SELECT daily_status_text, daily_status_set_at, daily_status_mood, "
                "eternal_status_text, eternal_status_mood, eternal_status_purchased_at "
                "FROM users WHERE id=?", (user["id"],)
            ).fetchone()
            conn.close()
        except Exception:
            # Отказываем только если не удалось прочитать сам статус.
            from starlette.responses import JSONResponse
            return JSONResponse(
                {"detail": "Не удалось проверить ежедневный статус из-за ошибки сервера. Повторите попытку позже.", "code": "DAILY_STATUS_CHECK_FAILED", "status_required": True},
                status_code=503,
                headers={"Cache-Control": "no-store"},
            )
        if _resolve_status(row):
            return await call_next(request)
        from starlette.responses import JSONResponse
        return JSONResponse(
            {"detail": "Статус не установлен. Установите ежедневный статус, чтобы загрузить GhostSocial и пользоваться всеми разделами." , "code": "DAILY_STATUS_REQUIRED", "status_required": True},
            status_code=403,
            headers={"Cache-Control": "no-store"},
        )

app.add_middleware(_DailyStatusGateMiddleware)

_ALLOWED_ORIGINS = [
    "https://ghostecos.duckdns.org",
    "http://localhost:8005",
    "http://127.0.0.1:8005",
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

os.makedirs("/opt/ghostchat/media", exist_ok=True)
app.mount("/media", StaticFiles(directory="/opt/ghostchat/media"), name="media")

app.include_router(social_router)
# Явная регистрация маршрутов для совместимости с развёрнутыми вложенными роутерами.
from social_router import set_media_banner as _set_media_banner, clear_media_banner as _clear_media_banner
app.add_api_route("/api/soc/media-banner", _set_media_banner, methods=["POST"], include_in_schema=False)
app.add_api_route("/api/soc/media-banner", _clear_media_banner, methods=["DELETE"], include_in_schema=False)
app.include_router(chat_router)
app.include_router(bot_api_router)
app.include_router(channel_router_v2)
app.include_router(room_router_v2)
try:
    from chat_router_v2 import router as chat_router_v2
    app.include_router(chat_router_v2)
except Exception as _e:
    import logging as _lg
    _lg.getLogger('gc').warning('chat_router_v2 not registered: %s', _e)


# ── TTL cleanup: удаляет доставленные сообщения старше 24ч ──
# Multi-device delivery: сообщение живёт после первого ack пока не пройдёт
# _DELIVERY_TTL_SECONDS — это окно для других устройств того же юзера.
import asyncio as _aio_cleanup
import sqlite3 as _sqlite_cleanup
import time as _time_cleanup
import logging as _log_cleanup
from chat_router import _DELIVERY_TTL_SECONDS

async def _delivery_cleanup_loop():
    log = _log_cleanup.getLogger('gc.cleanup')
    while True:
        try:
            await _aio_cleanup.sleep(3600)
            cutoff = int(_time_cleanup.time()) - _DELIVERY_TTL_SECONDS
            conn = _sqlite_cleanup.connect('/opt/ghostchat/ghostchat.db')
            total = 0
            for tbl in ('chat_dm', 'chat_dm_sealed', 'chat_group_messages'):
                cur = conn.execute(
                    f"DELETE FROM {tbl} WHERE last_delivery_at IS NOT NULL AND last_delivery_at < ?",
                    (cutoff,)
                )
                total += cur.rowcount
            # v2: per-device envelopes. Здесь нет last_delivery_at — каждый envelope
            # это конкретное устройство; чистим по created_at старше 24ч (устройство
            # которое не подключалось — потеряло сообщение, нормально для sealed).
            try:
                cur = conn.execute(
                    "DELETE FROM chat_dm_v2 WHERE created_at < ?",
                    (cutoff,)
                )
                total += cur.rowcount
            except _sqlite_cleanup.OperationalError:
                pass  # таблица может не существовать на старом проде
            conn.execute(
                "DELETE FROM chat_group_acks WHERE msg_id NOT IN (SELECT id FROM chat_group_messages)"
            )
            conn.commit(); conn.close()
            if total:
                log.info(f"[delivery-cleanup] purged {total} delivered>24h messages")
        except Exception as e:
            log.warning(f"[delivery-cleanup] err: {e}")

@app.on_event("startup")
async def _start_cleanup():
    _aio_cleanup.create_task(_delivery_cleanup_loop())


@app.get("/api/soc/health")
def health_check():
    return {"status": "working", "service": "GhostSocial Standalone"}


@app.get("/api/chat/server-identity")
def server_identity():
    """Долгоживущий Ed25519 pub-ключ сервера. Клиент кэширует при первом
    подключении (TOFU) и сверяет подпись эфемерных server_pub в cs.hello.ok
    при каждом WS handshake — защита от MITM."""
    import base64 as _b64
    try:
        from server_identity import server_identity_pub_bytes
        return {"server_identity_pub": _b64.b64encode(server_identity_pub_bytes()).decode()}
    except Exception as e:
        import logging as _lg
        _lg.getLogger("gc").error("server_identity error: %s", e)
        return {"server_identity_pub": None}
