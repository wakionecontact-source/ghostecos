"""Core API GhostEcos для доверенных сервисов: один воркер, внутренние вызовы по HMAC."""
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict, deque
from html.parser import HTMLParser
from fastapi import FastAPI, HTTPException, Query, Request
from starlette.concurrency import run_in_threadpool

from ecos_core.identity import auth, db as identity_db
from ecos_core.economy import award_gost as core_award_gost
from ecos_core.account_delete import DeleteAccountBody, delete_my_account as core_delete_account
from ecos_core.account_access import (
    PasswordChallengeBody, SeedRecoveryBody, SeedRegenBody,
    password_v2_challenge as core_password_challenge,
    password_v2_verify as core_password_verify,
    recovery_seed as core_recovery_seed, regen_seed as core_regen_seed,
)
from ecos_core.login import (
    ChallengeProofBody, LoginBody, LoginChallengeBody, LoginFinishBody,
    login as core_login, login_v2_challenge, login_v2_finish,
)
from ecos_core.realtime import ws_hub
from ecos_core.registration import RegisterBody, RegisterV2Body, register as core_register
from ecos_core.service_auth import verify_internal_request
from ecos_core.sessions import list_for_token, logout_for_token, revoke_for_token
from ecos_core.shared import _is_admin_user
from ecos_core.sso import sso_issue_jwt as core_issue_sso_jwt
from ecos_core.service_sso import install as install_service_sso
from ecos_core.service_auth_v2 import install as install_auth_v2
from ecos_core.legacy_redirect import install as install_legacy_redirect
from ecos_core.api_keys import install as install_api_keys

from waki_private_apk import router as waki_private_apk_router
from waki_private_banner import router as waki_private_banner_router

app = FastAPI(title="GhostEcos Core API", docs_url=None, redoc_url=None, openapi_url=None)
install_service_sso(app)
install_auth_v2(app)
install_legacy_redirect(app)
from ecos_core.partner_oauth import router as partner_oauth_router
app.include_router(partner_oauth_router)
install_api_keys(app)
app.include_router(waki_private_apk_router)
app.include_router(waki_private_banner_router)
_EVENT_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")


@app.get("/health")
def health():
    return {"ok": True, "service": "ghostecos-core"}


async def _internal_payload(request: Request) -> tuple[str, dict]:
    service, raw = await verify_internal_request(request)
    try:
        payload = json.loads(raw)
    except (TypeError, ValueError):
        raise HTTPException(400, "Invalid JSON body")
    if not isinstance(payload, dict):
        raise HTTPException(400, "JSON object required")
    return service, payload


@app.post("/internal/v1/identity/resolve")
async def resolve_identity(request: Request):
    service, payload = await _internal_payload(request)
    token = payload.get("token")
    if not isinstance(token, str) or not token or len(token) > 4096:
        raise HTTPException(422, "Token is required")
    user = await run_in_threadpool(auth, "Bearer " + token)
    public = {
        "id": int(user.get("id") or 0),
        "username": str(user.get("username") or ""),
        "display_name": str(user.get("display_name") or ""),
        "avatar_url": user.get("avatar_url"),
    }
    if service == "ghogem":
        return public
    return {
        **public, "about": str(user.get("about") or ""),
        "is_guest": bool(user.get("is_guest")), "is_admin": _is_admin_user(user),
        "is_moderator": bool(user.get("is_moderator")),
        "is_app_device": bool(user.get("_device_pk") and user.get("_did")),
    }


@app.post("/internal/v1/identity/verify-password")
async def verify_identity_password(request: Request):
    _service, payload = await _internal_payload(request)
    token = payload.get("token")
    password = payload.get("password")
    if not isinstance(token, str) or not token or len(token) > 4096:
        raise HTTPException(422, "Token is required")
    if not isinstance(password, str) or not password or len(password) > 1024:
        raise HTTPException(422, "Password is required")
    user = await run_in_threadpool(auth, "Bearer " + token)
    if user.get("is_guest"):
        return {"valid": False}
    from ecos_core.credentials import verify_user_password
    from ecos_core.shared import _rate_limit
    _rate_limit(f"core-password-check:{user['id']}", limit=10, window=600)
    return {"valid": await run_in_threadpool(verify_user_password, password, user)}


def _login_client_ip(payload: dict) -> str:
    client_ip = payload.get("client_ip")
    if not isinstance(client_ip, str) or not re.fullmatch(r"[A-Za-z0-9.:-]{1,128}", client_ip):
        raise HTTPException(422, "Invalid client IP")
    return client_ip


def _internal_authorization(payload: dict) -> str:
    token = payload.get("token")
    if not isinstance(token, str) or not token or len(token) > 4096:
        raise HTTPException(422, "Token is required")
    return "Bearer " + token


@app.post("/internal/v1/identity/recovery/seed")
async def recover_identity_seed(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(
        core_recovery_seed, SeedRecoveryBody(**payload), _login_client_ip(payload)
    )


@app.post("/internal/v1/identity/regen-seed")
async def regenerate_identity_seed(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(
        core_regen_seed, SeedRegenBody(**payload), _internal_authorization(payload)
    )


@app.post("/internal/v1/identity/password/challenge")
async def challenge_identity_password(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(
        core_password_challenge, PasswordChallengeBody(**payload),
        _internal_authorization(payload),
    )


@app.post("/internal/v1/identity/password/verify")
async def verify_identity_challenge(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(
        core_password_verify, ChallengeProofBody(**payload),
        _internal_authorization(payload),
    )


@app.post("/internal/v1/identity/delete-account")
async def delete_identity_account(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(
        core_delete_account, DeleteAccountBody(**payload), _internal_authorization(payload)
    )


@app.post("/internal/v1/identity/sso/jwt")
async def issue_identity_sso_jwt(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(core_issue_sso_jwt, _internal_authorization(payload))


@app.post("/internal/v1/identity/register")
async def register_identity(request: Request):
    _service, payload = await _internal_payload(request)
    version = payload.get("auth_version")
    if version == 1 and not isinstance(version, bool):
        body = RegisterBody(**payload)
    elif version == 2:
        body = RegisterV2Body(**payload)
    else:
        raise HTTPException(422, "Invalid registration version")
    return await run_in_threadpool(core_register, body, _login_client_ip(payload))


@app.post("/internal/v1/identity/login")
async def login_identity(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(core_login, LoginBody(**payload), _login_client_ip(payload))


@app.post("/internal/v1/identity/login/challenge")
async def login_identity_challenge(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(login_v2_challenge, LoginChallengeBody(**payload), _login_client_ip(payload))


@app.post("/internal/v1/identity/login/finish")
async def login_identity_finish(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(login_v2_finish, LoginFinishBody(**payload), _login_client_ip(payload))


@app.post("/internal/v1/identity/sessions")
async def identity_sessions(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(list_for_token, _internal_authorization(payload))


@app.post("/internal/v1/identity/logout")
async def identity_logout(request: Request):
    _service, payload = await _internal_payload(request)
    return await run_in_threadpool(logout_for_token, _internal_authorization(payload))


@app.post("/internal/v1/identity/sessions/revoke")
async def identity_revoke_session(request: Request):
    _service, payload = await _internal_payload(request)
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128:
        raise HTTPException(422, "Invalid session_id")
    return await run_in_threadpool(
        revoke_for_token, _internal_authorization(payload), session_id
    )


@app.post("/internal/v1/wallet/award")
async def award_wallet_activity(request: Request):
    service, payload = await _internal_payload(request)
    if service not in {"ghostsocial", "ghostecos-core"}:
        raise HTTPException(403, "Service cannot award wallet activity")
    uid, source = payload.get("user_id"), payload.get("source")
    actor_id, ref_id = payload.get("actor_id", 0), payload.get("ref_id", 0)
    ref_type = payload.get("ref_type", "")
    amount = payload.get("amount_override")
    if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in (uid, actor_id, ref_id)):
        raise HTTPException(422, "Invalid wallet activity identifiers")
    if not isinstance(source, str) or len(source) > 40:
        raise HTTPException(422, "Invalid wallet activity source")
    if not isinstance(ref_type, str) or len(ref_type) > 64:
        raise HTTPException(422, "Invalid wallet activity reference")
    if amount is not None and (isinstance(amount, bool) or not isinstance(amount, int) or not 0 < amount <= 10000):
        raise HTTPException(422, "Invalid wallet activity amount")
    return await run_in_threadpool(
        core_award_gost, uid, source, actor_id, ref_type, ref_id, amount
    )


@app.post("/internal/v1/events/send")
async def send_event(request: Request):
    _service, payload = await _internal_payload(request)
    uid = payload.get("user_id")
    event_type = payload.get("type")
    data = payload.get("data")
    if isinstance(uid, bool) or not isinstance(uid, int) or uid <= 0:
        raise HTTPException(422, "Positive user_id is required")
    if not isinstance(event_type, str) or not _EVENT_RE.fullmatch(event_type):
        raise HTTPException(422, "Invalid event type")
    if not isinstance(data, dict):
        raise HTTPException(422, "Event data must be an object")
    ws_hub.send_to(uid, event_type, data)
    return {"ok": True}


@app.post("/internal/v1/events/broadcast")
async def broadcast_event(request: Request):
    _service, payload = await _internal_payload(request)
    event_type = payload.get("type")
    data = payload.get("data")
    if not isinstance(event_type, str) or not _EVENT_RE.fullmatch(event_type):
        raise HTTPException(422, "Invalid event type")
    if not isinstance(data, dict):
        raise HTTPException(422, "Event data must be an object")
    ws_hub.broadcast(event_type, data)
    return {"ok": True}

# Подключаем API GhostChat: lifespan старого ASGI не стартует — миграции и STUN ведёт сервис GhostChat.
import main_remote as _legacy_chat
from fastapi.routing import APIRoute as _APIRoute
from starlette.routing import WebSocketRoute as _WebSocketRoute

for _legacy_router in (
    _legacy_chat.auth,
    _legacy_chat.users,
    _legacy_chat.channels,
    _legacy_chat.files,
    _legacy_chat.shop,
    _legacy_chat.support,
    _legacy_chat.admin,
):
    app.include_router(_legacy_router.router)
app.include_router(_legacy_chat.bot_check.router, prefix="/api")
app.include_router(_legacy_chat.downloads.router, prefix="/api")

# Копируем только публичные /api-роуты и WS чата; старый HTML/static остаётся на 8000.
for _legacy_route in _legacy_chat.app.router.routes:
    if isinstance(_legacy_route, _APIRoute) and _legacy_route.path.startswith("/api/"):
        app.router.routes.append(_legacy_route)
app.add_api_websocket_route("/ws", _legacy_chat.ws_endpoint, name="ghostchat-ws")

import asyncio as _asyncio
import os as _os
from fastapi.responses import JSONResponse as _JSONResponse

_LEGACY_API_EXCLUDED_PREFIXES = (
    "/api/soc/", "/api/chat/", "/api/bots/", "/api/support-admin/",
    "/api/nation/",
)
try:
    _GC_PREAUTH_MAX_INFLIGHT = max(1, min(
        int(_os.getenv("GC_PREAUTH_MAX_INFLIGHT", "100")), 5000
    ))
except (TypeError, ValueError):
    _GC_PREAUTH_MAX_INFLIGHT = 100
_GC_PREAUTH_SLOTS = _asyncio.Semaphore(_GC_PREAUTH_MAX_INFLIGHT)


def _ghostchat_security_headers(request: Request, response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    if request.url.path.startswith("/api/sso/widget/") and response.status_code == 200:
        # Встраивается только инертная кнопка — сохраняем её CSP для клиента.
        return response
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; style-src 'self' 'unsafe-inline' "
        "https://fonts.googleapis.com https://cdnjs.cloudflare.com; "
        "font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com; "
        "script-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        "frame-ancestors 'none'"
    )
    if request.url.scheme == "https":
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


@app.middleware("http")
async def _legacy_ghostchat_api_safeguards(request: Request, call_next):
    path = request.url.path
    if (
        not path.startswith("/api/")
        or any(path.startswith(prefix) for prefix in _LEGACY_API_EXCLUDED_PREFIXES)
    ):
        return await call_next(request)

    bypass = request.headers.get("X-Ghost-Bypass", "")
    rate_bypassed = bool(
        bypass
        and _legacy_chat.config.BYPASS_TOKEN
        and _legacy_chat.security.safe_equal(bypass, _legacy_chat.config.BYPASS_TOKEN)
    )
    if not rate_bypassed:
        try:
            client_ip = _legacy_chat.security._get_ip(request)
            _legacy_chat.security.check_global_rate(client_ip)
        except Exception:
            return _ghostchat_security_headers(
                request, _JSONResponse(status_code=429, content={"detail": "Too many requests"})
            )

    raw_length = request.headers.get("content-length")
    if raw_length:
        try:
            length = int(raw_length)
        except ValueError:
            length = 2 * 1024 * 1024 + 1
        content_type = (request.headers.get("content-type") or "").lower()
        limit = 65 * 1024 * 1024 if "multipart/form-data" in content_type else 2 * 1024 * 1024
        if length > limit:
            return _ghostchat_security_headers(
                request, _JSONResponse(status_code=413, content={"detail": "Request body is too large"})
            )

    needs_preauth_slot = path in {"/api/register", "/api/login"}
    if needs_preauth_slot:
        try:
            await _asyncio.wait_for(_GC_PREAUTH_SLOTS.acquire(), timeout=0.02)
        except _asyncio.TimeoutError:
            return _ghostchat_security_headers(
                request,
                _JSONResponse(
                    {
                        "code": "service_busy",
                        "message": "Сервис под нагрузкой, попробуйте позже",
                    },
                    status_code=503,
                    headers={"Retry-After": "15", "Cache-Control": "no-store"},
                ),
            )

    try:
        response = await call_next(request)
        return _ghostchat_security_headers(request, response)
    finally:
        if needs_preauth_slot:
            _GC_PREAUTH_SLOTS.release()


# GhostNation использует общие JWT и SQLite: грузим API без второго процесса.
import importlib.util as _importlib_util
import sys as _sys

_nation_spec = _importlib_util.spec_from_file_location(
    "ghostnation_core_routes", "/opt/ghostnation/server.py"
)
if _nation_spec is None or _nation_spec.loader is None:
    raise RuntimeError("GhostNation API module is unavailable")
_nation_backend = _importlib_util.module_from_spec(_nation_spec)
_sys.modules[_nation_spec.name] = _nation_backend
_nation_spec.loader.exec_module(_nation_backend)
_NATION_API_ROUTES = [
    route for route in _nation_backend.app.router.routes
    if isinstance(route, _APIRoute) and route.path.startswith("/api/nation/")
]
if not _NATION_API_ROUTES:
    raise RuntimeError("GhostNation API routes were not loaded")
app.router.routes.extend(_NATION_API_ROUTES)


@app.middleware("http")
async def _ghostnation_api_safeguards(request: Request, call_next):
    if not request.url.path.startswith("/api/nation/"):
        return await call_next(request)

    async def _body_limited(req: Request):
        return await _nation_backend.request_size_guard(req, call_next)

    return await _nation_backend.rate_limit(request, _body_limited)


_HOME_SITE_SEARCH_CACHE: OrderedDict[str, tuple[float, list[dict[str, str]]]] = OrderedDict()
_HOME_SITE_SEARCH_CALLS: dict[str, deque[float]] = {}
_HOME_SITE_SEARCH_LOCK = threading.Lock()
_HOME_SITE_SEARCH_CACHE_TTL = 240.0
_HOME_SITE_SEARCH_CACHE_LIMIT = 160


class _HomeSiteSearchBlocked(Exception):
    pass


class _HomeSiteSearchHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.results: list[dict[str, str]] = []
        self._field: str | None = None
        self._href = ""
        self._parts: list[str] = []

    def handle_starttag(self, tag: str, attrs):
        if tag != "a":
            return
        attributes = dict(attrs)
        classes = set((attributes.get("class") or "").split())
        if "result__a" in classes:
            self._field = "name"
            self._href = attributes.get("href") or ""
            self._parts = []
        elif "result__snippet" in classes and self.results:
            self._field = "description"
            self._parts = []

    def handle_data(self, data: str):
        if self._field:
            self._parts.append(data)

    def handle_endtag(self, tag: str):
        if tag != "a" or not self._field:
            return
        value = " ".join(" ".join(self._parts).split())
        if self._field == "name":
            self.results.append(
                {"name": value, "raw_url": self._href, "description": ""}
            )
        elif self.results:
            self.results[-1]["description"] = value
        self._field = None
        self._parts = []


def _home_site_search_check_rate(client_ip: str) -> None:
    now = time.monotonic()
    with _HOME_SITE_SEARCH_LOCK:
        calls = _HOME_SITE_SEARCH_CALLS.setdefault(client_ip or "unknown", deque())
        while calls and now - calls[0] >= 60:
            calls.popleft()
        if len(calls) >= 12:
            raise HTTPException(
                429,
                "Too many site searches. Try again shortly.",
                headers={"Retry-After": "15"},
            )
        calls.append(now)
        if len(_HOME_SITE_SEARCH_CALLS) > 2048:
            for ip in list(_HOME_SITE_SEARCH_CALLS):
                if not _HOME_SITE_SEARCH_CALLS[ip]:
                    _HOME_SITE_SEARCH_CALLS.pop(ip, None)


def _home_site_search_cached(query: str) -> list[dict[str, str]] | None:
    now = time.monotonic()
    with _HOME_SITE_SEARCH_LOCK:
        entry = _HOME_SITE_SEARCH_CACHE.get(query)
        if entry is None:
            return None
        expires, results = entry
        if expires <= now:
            _HOME_SITE_SEARCH_CACHE.pop(query, None)
            return None
        _HOME_SITE_SEARCH_CACHE.move_to_end(query)
        return [dict(item) for item in results]


def _home_site_search_cache_store(query: str, results: list[dict[str, str]]) -> None:
    with _HOME_SITE_SEARCH_LOCK:
        _HOME_SITE_SEARCH_CACHE[query] = (
            time.monotonic() + _HOME_SITE_SEARCH_CACHE_TTL,
            [dict(item) for item in results],
        )
        _HOME_SITE_SEARCH_CACHE.move_to_end(query)
        while len(_HOME_SITE_SEARCH_CACHE) > _HOME_SITE_SEARCH_CACHE_LIMIT:
            _HOME_SITE_SEARCH_CACHE.popitem(last=False)


def _home_site_search_fetch(query: str) -> list[dict[str, str]]:
    params = urllib.parse.urlencode({"q": query, "kl": "ru-ru", "kp": "1"})
    request = urllib.request.Request(
        "https://html.duckduckgo.com/html/?" + params,
        headers={
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Encoding": "identity",
            "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
            "Referer": "https://duckduckgo.com/",
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            ),
        },
    )
    proxy = os.environ.get(
        "GHOSTECOS_SEARCH_PROXY", "http://127.0.0.1:1080"
    ).strip()
    proxy_handler = (
        urllib.request.ProxyHandler({"https": proxy})
        if proxy
        else urllib.request.ProxyHandler({})
    )
    opener = urllib.request.build_opener(proxy_handler)
    with opener.open(request, timeout=8) as response:
        document = response.read(2_000_000).decode(
            response.headers.get_content_charset() or "utf-8", "replace"
        )

    lowered_document = document.lower()
    if "anomaly.js" in lowered_document or 'id="img-form"' in lowered_document:
        raise _HomeSiteSearchBlocked("DuckDuckGo returned an automated traffic challenge.")

    parser = _HomeSiteSearchHTMLParser()
    parser.feed(document)
    results: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in parser.results:
        link = urllib.parse.urljoin("https://duckduckgo.com/", item.get("raw_url", ""))
        parsed = urllib.parse.urlsplit(link)
        if parsed.hostname in ("duckduckgo.com", "www.duckduckgo.com") and parsed.path == "/l/":
            target = urllib.parse.parse_qs(parsed.query).get("uddg", [])
            link = target[0] if target else ""
            parsed = urllib.parse.urlsplit(link)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
        ):
            continue
        url = urllib.parse.urlunsplit(parsed)
        identity = url.rstrip("/").casefold()
        if identity in seen:
            continue
        seen.add(identity)
        name = " ".join(item.get("name", "").split())[:100] or parsed.hostname
        description = " ".join(item.get("description", "").split())[:240]
        results.append(
            {"name": name, "url": url, "description": description}
        )
        if len(results) >= 8:
            break
    return results


@app.get("/api/home/site-search")
async def home_site_search(
    request: Request,
    q: str = Query(..., min_length=2, max_length=120),
):
    query = " ".join(q.split())
    if len(query) < 2:
        raise HTTPException(422, "Enter at least two characters.")
    cached = _home_site_search_cached(query.casefold())
    if cached is not None:
        return {"results": cached, "cached": True}

    client_ip = request.client.host if request.client else "unknown"
    _home_site_search_check_rate(client_ip)
    try:
        results = await run_in_threadpool(_home_site_search_fetch, query)
    except _HomeSiteSearchBlocked:
        raise HTTPException(503, "Global site search is temporarily unavailable.")
    except urllib.error.HTTPError as exc:
        if exc.code in (202, 429, 403, 503):
            raise HTTPException(503, "Global site search is temporarily unavailable.")
        raise HTTPException(502, "Global site search failed.")
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise HTTPException(502, "Global site search failed.")

    _home_site_search_cache_store(query.casefold(), results)
    return {"results": results, "cached": False}


from social_app import app as product_api_app, _start_cleanup


@app.on_event("startup")
async def _start_product_cleanup():
    # Вложенные ASGI-приложения не получают lifespan от родителя.
    await _start_cleanup()




def _ghogem_public_profile(user_id: int):
    c = identity_db()
    try:
        row = c.execute(
            "SELECT id, username, display_name, avatar_url, created_at, "
            "CAST(strftime('%s', created_at) AS INTEGER) AS created_at_ts "
            "FROM users WHERE id=?", (user_id,),
        ).fetchone()
        return dict(row) if row else None
    finally:
        c.close()

def _ghogem_search_public_profiles(term: str, exact: bool = False) -> list[dict]:
    """Только публичные поля identity, без приватных данных профиля."""
    c=identity_db()
    try:
        term=term.lstrip("@").casefold()
        if exact:
            rows=c.execute(
                "SELECT id,username,display_name FROM users "
                "WHERE LOWER(username)=? ORDER BY id DESC LIMIT 20", (term,)
            ).fetchall()
        else:
            # Экранируем спецсимволы LIKE из запроса, чтобы не сломать шаблон поиска.
            quoted=term.replace("\\","\\\\").replace("%","\\%").replace("_","\\_")
            like="%"+quoted+"%"
            rows=c.execute(
                "SELECT id,username,display_name FROM users "
                "WHERE (LOWER(username) LIKE ? ESCAPE '\\' OR "
                "LOWER(display_name) LIKE ? ESCAPE '\\' OR "
                "CAST(id AS TEXT) LIKE ? ESCAPE '\\') "
                "ORDER BY CASE WHEN LOWER(username)=? THEN 0 "
                "WHEN LOWER(username) LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END,"
                " id DESC LIMIT 30", (like,like,like,term,quoted+"%")
            ).fetchall()
        return [
            {"id":int(row["id"]), "username":str(row["username"] or ""),
             "display_name":str(row["display_name"] or "")}
            for row in rows
        ]
    finally:
        c.close()


@app.post("/internal/v1/identity/search-public")
async def ghogem_search_public_profiles(request: Request):
    service, payload=await _internal_payload(request)
    if service!="ghogem":
        raise HTTPException(403,"Service scope denied")
    term=payload.get("q")
    exact=payload.get("exact",False)
    if (not isinstance(term,str) or not 2<=len(term.strip())<=64
            or not isinstance(exact,bool)):
        raise HTTPException(422,"Invalid search query")
    return {"results":await run_in_threadpool(_ghogem_search_public_profiles,term.strip(),exact)}


@app.post("/internal/v1/identity/public-profile")
async def ghogem_public_profile(request: Request):
    service, payload = await _internal_payload(request)
    if service != "ghogem":
        raise HTTPException(403, "Service scope denied")
    user_id = payload.get("user_id")
    if type(user_id) is not int or not 0 < user_id < 2**63:
        raise HTTPException(422, "Invalid user ID")
    return {"user": await run_in_threadpool(_ghogem_public_profile, user_id)}

@app.get("/api/learn/access")
async def authorize_ghostlearn_access(request: Request):
    """Пускать в GhostLearn только владельца GhostEcos (nginx auth_request)."""
    from urllib.parse import unquote

    raw_token = request.cookies.get("gs_token", "")
    if not raw_token or len(raw_token) > 4200:
        raise HTTPException(401, "GhostEcos session required")
    token = unquote(raw_token)
    if not token or len(token) > 4096:
        raise HTTPException(401, "GhostEcos session required")
    user = await run_in_threadpool(auth, "Bearer " + token)
    if type(user.get("id")) is not int or user["id"] != 2:
        raise HTTPException(403, "GhostLearn is private")
    return {"ok": True}


from chat_client_bridge import install as install_chat_client
install_chat_client(app)

app.mount("/", product_api_app, name="ghostecos-product-api")
