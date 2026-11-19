from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware
from social_router import router as social_router
from chat_router import router as chat_router
import os

app = FastAPI(title="GhostSocial Standalone API", docs_url=None, redoc_url=None, openapi_url=None)


# ── Security headers middleware ──────────────────────────────────────────────
# Защитные HTTP-заголовки на все ответы. HSTS на проде ставит nginx, остальное здесь.
_PRIVATE_PATH_PREFIXES = (
    "/api/soc/me", "/api/soc/notif", "/api/soc/feed",
    "/api/chat/me", "/api/chat/keys/me", "/api/chat/pending",
    "/api/chat/unread", "/api/chat/contacts",
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


# ── Global rate-limit middleware ────────────────────────────────────────────
# Дополнительная защита поверх per-endpoint лимитов: общий потолок запросов
# с одного клиента в минуту. Pentest waki (2026-06-20) показал что одна
# DevTools-консоль с for-loop кладёт сервер за секунды, если на конкретном
# endpoint не было лимита. 61 endpoint из 176 ходили без _rate_limit —
# точечно править все долго, поэтому здесь общий "circuit breaker".
import time as _gtime
from collections import deque as _gdq
_RL_BUCKETS: dict = {}   # key → deque[timestamps]
_RL_MAX = 300            # запросов
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
app.include_router(chat_router)

@app.get("/api/soc/health")
def health_check():
    return {"status": "working", "service": "GhostSocial Standalone"}
