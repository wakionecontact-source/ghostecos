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
        # Универсальные защитные заголовки
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
        # Не выдаём версию сервера
        if "server" in response.headers:
            del response.headers["server"]
        # Приватные данные не должны кэшироваться прокси/CDN
        path = request.url.path
        if any(path.startswith(p) for p in _PRIVATE_PATH_PREFIXES):
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
            response.headers["Pragma"] = "no-cache"
        return response

app.add_middleware(_SecHeadersMiddleware)

# CORS: явный whitelist наших доменов.
# Раньше было allow_origins=["*"] + allow_credentials=True — это нарушение спеки CORS
# (браузеры это игнорируют, но это сигнал что safety не продумана).
# Теперь только наш домен — нет ни одного легитимного origin кроме самого сайта.
_ALLOWED_ORIGINS = [
    "https://ghostecos.duckdns.org",
    # Локальные dev-серверы для разработки (на проде nginx всё равно режет посторонние)
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

# Создаем папку для медиафайлов, если её нет
os.makedirs("/opt/ghostchat/media", exist_ok=True)
# Раздаем медиа-файлы станично по адресу /media
app.mount("/media", StaticFiles(directory="/opt/ghostchat/media"), name="media")

# Подключаем роуты GhostSocial
app.include_router(social_router)
# Подключаем роуты GhostChat (ЛС)
app.include_router(chat_router)

@app.get("/api/soc/health")
def health_check():
    return {"status": "working", "service": "GhostSocial Standalone"}
