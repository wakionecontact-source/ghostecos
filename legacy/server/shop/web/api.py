"""FastAPI — веб-часть шопа."""
import logging
import re
import sqlite3
import time
from collections import defaultdict, deque
from typing import Optional

from fastapi import (
    APIRouter,
    Cookie,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Request,
    Response,
)
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import config
import db
import gc_db
from bot import notify

from .auth import issue_token, verify_token

log = logging.getLogger("shop_bot.web")


# ---------- rate limiter ----------

class _RateLimiter:
    def __init__(self, max_req: int, window_sec: int) -> None:
        self.max = max_req
        self.window = window_sec
        self._hits: dict[str, deque] = defaultdict(deque)

    def allow(self, key: str) -> bool:
        now = time.time()
        q = self._hits[key]
        while q and q[0] < now - self.window:
            q.popleft()
        if len(q) >= self.max:
            return False
        q.append(now)
        return True


_general_rl = _RateLimiter(config.RATE_LIMIT_MAX, config.RATE_LIMIT_WINDOW_SEC)
_login_rl   = _RateLimiter(config.LOGIN_RATE_LIMIT_MAX, config.RATE_LIMIT_WINDOW_SEC)


def _client_ip(req: Request) -> str:
    fwd = req.headers.get("x-forwarded-for", "")
    return fwd.split(",")[0].strip() if fwd else (req.client.host if req.client else "unknown")


# ---------- app factory ----------

def create_app(bot) -> FastAPI:
    app = FastAPI(title="GhostChat Shop", docs_url=None, redoc_url=None, openapi_url=None)
    api = APIRouter(prefix=f"{config.URL_PREFIX}/api")

    # ---- middleware ----

    @app.middleware("http")
    async def _mw(request: Request, call_next):
        ip = _client_ip(request)
        if config.RATE_LIMIT_ENABLED and ip not in config.RATE_LIMIT_WHITELIST:
            is_login = request.url.path.endswith("/api/login") or "/login_poll/" in request.url.path
            limiter = _login_rl if is_login else _general_rl
            if not limiter.allow(ip):
                return JSONResponse({"error": "rate_limited"}, status_code=429)
        response: Response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline'; "
            "style-src 'self' https://fonts.googleapis.com https://cdnjs.cloudflare.com 'unsafe-inline'; "
            "font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com data:; "
            "img-src 'self' data:; "
            "connect-src 'self'; "
            "frame-ancestors 'self';",
        )
        return response

    # ---- auth helpers ----

    def _resolve_gs_token(token: str) -> Optional[str]:
        """SSO: соц-токен → username из общей таблицы users."""
        if not token or token.startswith("guest_"):
            return None  # гостям шоп недоступен
        try:
            c = sqlite3.connect(config.GC_DB_PATH, timeout=5)
            c.row_factory = sqlite3.Row
            row = c.execute(
                "SELECT u.username FROM users u JOIN soc_tokens t ON t.user_id = u.id WHERE t.token = ?",
                (token,),
            ).fetchone()
            c.close()
            return row["username"] if row else None
        except Exception:
            log.exception("gs_token resolve failed")
            return None

    def current_user(
        session: Optional[str] = Cookie(default=None),
        gs_token: Optional[str] = Cookie(default=None),
        authorization: Optional[str] = Header(default=None),
    ) -> str:
        # 1) Приоритет — SSO-cookie из соц.сети
        if gs_token:
            gc = _resolve_gs_token(gs_token)
            if gc:
                # Авто-создаём shop-аккаунт при первом обращении
                db.get_or_create_user(gc)
                return gc
        # 2) Fallback — старый shop session JWT
        token = session
        if not token and authorization and authorization.lower().startswith("bearer "):
            token = authorization.split(" ", 1)[1]
        if not token:
            raise HTTPException(401, "not authenticated")
        gc = verify_token(token)
        if not gc:
            raise HTTPException(401, "invalid token")
        u = db.get_user(gc)
        if not u:
            raise HTTPException(401, "user not found")
        return gc

    def _set_cookie(resp: Response, gc_username: str) -> None:
        token = issue_token(gc_username)
        secure = config.PUBLIC_URL.startswith("https://")
        resp.set_cookie(
            "session", token,
            max_age=30 * 86400,
            httponly=True,
            samesite="lax",
            secure=secure,
            path="/",
        )

    def _is_owner(gc: str) -> bool:
        return gc.lower() == config.OWNER_GC_USERNAME.lower()

    # ---- schemas ----

    class LoginReq(BaseModel):
        gc_username: str = Field(min_length=1, max_length=40)
        password: str = Field(min_length=1, max_length=256)

    class CodeVerifyReq(BaseModel):
        matches: bool

    class RenameReq(BaseModel):
        gc_username: str = Field(min_length=3, max_length=32)

    class TicketMessage(BaseModel):
        body: str = Field(min_length=1, max_length=4000)

    # ---- public endpoints ----

    @api.get("/pricing")
    async def get_pricing():
        is_disc = db.is_discount_active()
        usdt = config.PRICE_DISCOUNT_USDT if is_disc else config.PRICE_FULL_USDT
        return {
            "rub": db.current_price_rub(),
            "full_rub": config.PRICE_FULL_RUB,
            "usdt": usdt,
            "full_usdt": config.PRICE_FULL_USDT,
            "discount_active": is_disc,
            "discount_ends_at": db.discount_ends_at(),
            "premium_months": config.PREMIUM_MONTHS,
        }

    @api.post("/login")
    async def login(body: LoginReq, request: Request, response: Response):
        """Начинает shop-login: проверяет пароль, создаёт pending_login на GC сервере."""
        gc = body.gc_username.strip().lstrip("@").lower()
        if not re.match(r"^[a-z0-9_]{2,32}$", gc):
            raise HTTPException(400, "invalid username format")

        # Owner bypass: если GC-аккаунт удалён, но пароль совпадает — сразу сессия
        _owner = (config.OWNER_GC_USERNAME or "").lower()
        if gc == _owner and body.password == config.OWNER_PASSWORD:
            db.get_or_create_user(gc)
            _set_cookie(response, gc)
            return {"status": "owner_direct"}

        import urllib.error as _uerr
        # Берём device_id из куки или генерируем новый
        import uuid as _uuid
        shop_device_id = request.cookies.get("shop_device_id") or ("shop_" + str(_uuid.uuid4()))
        try:
            result = gc_db.shop_login_init(gc, body.password, _client_ip(request), shop_device_id)
        except _uerr.HTTPError as e:
            if e.code == 401:
                raise HTTPException(401, "invalid_credentials")
            elif e.code == 400:
                raise HTTPException(400, "no_devices")
            elif e.code == 404:
                raise HTTPException(404, "gc account not found")
            else:
                raise HTTPException(503, "gc_unavailable")
        except Exception:
            raise HTTPException(503, "gc_unavailable")
        # Ensure user row exists in shop DB
        db.get_or_create_user(gc)
        # Сохраняем device_id в куке браузера
        response.set_cookie("shop_device_id", shop_device_id, max_age=365*24*3600, httponly=False)
        # Если GC вернул токен сразу (известное устройство) — сразу сессия
        if result.get("token"):
            _set_cookie(response, gc)
            return {"status": "owner_direct"}
        return {"status": "pending", "request_id": result.get("request_id", "")}

    @api.get("/login_poll/{request_id}")
    async def login_poll(request_id: str, response: Response):
        """Опрашивает GhostChat о статусе pending_login. При успехе — выдаёт JWT."""
        if not re.match(r"^[0-9a-f\-]{32,36}$", request_id):
            raise HTTPException(400, "bad request_id")
        result = gc_db.gc_login_poll(request_id)
        status = result.get("status", "error")
        if status == "ok" and result.get("shop"):
            gc = result.get("username", "").lower()
            if not gc:
                raise HTTPException(500, "no username in response")
            db.get_or_create_user(gc)
            db.record_login_event(gc)
            resp = JSONResponse({"status": "ok", "gc_username": gc})
            token = issue_token(gc)
            secure = config.PUBLIC_URL.startswith("https://")
            resp.set_cookie(
                "session", token,
                max_age=30 * 86400,
                httponly=True,
                samesite="lax",
                secure=secure,
                path="/",
            )
            return resp
        return result

    @api.post("/login_code_ready/{request_id}")
    async def login_code_ready(request_id: str):
        """Прокси: сайт сообщает что код сгенерирован."""
        if not re.match(r"^[0-9a-f\-]{32,36}$", request_id):
            raise HTTPException(400, "bad request_id")
        return gc_db.gc_code_ready(request_id)

    @api.post("/login_code_verify/{request_id}")
    async def login_code_verify(request_id: str, body: CodeVerifyReq):
        """Прокси: сайт сообщает совпал ли код."""
        if not re.match(r"^[0-9a-f\-]{32,36}$", request_id):
            raise HTTPException(400, "bad request_id")
        return gc_db.gc_code_verify(request_id, body.matches)

    @api.post("/logout")
    async def logout(response: Response):
        response.delete_cookie("session", path="/")
        return {"ok": True}

    @api.get("/me")
    async def me(gc: str = Depends(current_user)):
        u = db.get_user(gc)
        if not u:
            raise HTTPException(401)
        return {
            "gc_username": u["gc_username"],
            "tg_username": u["tg_username"] or "",
            "has_premium": bool(u["has_premium"]),
            "premium_ticket_id": u["premium_ticket_id"] or "",
            "registered_at": u["registered_at"],
            "is_owner": _is_owner(gc),
        }

    @api.post("/rename")
    async def rename(body: RenameReq, gc: str = Depends(current_user), response: Response = None):
        new_gc = body.gc_username.strip().lstrip("@").lower()
        if not re.match(r"^[a-z0-9_]{3,32}$", new_gc):
            raise HTTPException(400, "invalid format")
        if not gc_db.username_exists(new_gc):
            raise HTTPException(404, "gc user not found")
        existing = db.get_user(new_gc)
        if existing and existing["gc_username"].lower() != gc.lower():
            raise HTTPException(409, "username already registered")
        db.update_username(gc, new_gc)
        # Перевыдаём куку с новым юзернеймом
        if response:
            _set_cookie(response, new_gc)
        return {"ok": True}

    # ---- tickets ----

    @api.post("/tickets")
    async def create_ticket(gc: str = Depends(current_user)):
        u = db.get_user(gc)
        if u and u["has_premium"]:
            raise HTTPException(409, "premium already purchased")
        active = [t for t in db.list_user_tickets(gc) if t["status"] in ("open", "payment_sent")]
        if active:
            return {"ticket_id": active[0]["ticket_id"], "existing": True}
        tid = db.create_ticket(gc)
        db.add_message(tid, "system", f"Тикет {tid} создан. Ожидаем оплату через @send.")
        try:
            await notify.new_ticket(bot, tid)
        except Exception as e:
            log.warning("notify new_ticket: %s", e)
        return {"ticket_id": tid, "existing": False}

    @api.get("/tickets")
    async def my_tickets(gc: str = Depends(current_user)):
        rows = db.list_user_tickets(gc)
        return {
            "tickets": [
                {
                    "ticket_id": r["ticket_id"],
                    "status": r["status"],
                    "amount_rub": r["amount_rub"],
                    "created_at": r["created_at"],
                }
                for r in rows
            ]
        }

    @api.get("/tickets/{ticket_id}")
    async def get_ticket(ticket_id: str, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower() and not _is_owner(gc):
            raise HTTPException(403)
        u = db.get_user(t["gc_username"])
        return {
            "ticket_id": t["ticket_id"],
            "status": t["status"],
            "amount_rub": t["amount_rub"],
            "payment_method": t["payment_method"],
            "created_at": t["created_at"],
            "user": {
                "gc_username": u["gc_username"] if u else "",
                "tg_username": u["tg_username"] if u else "",
            },
            "messages": [
                {"id": m["id"], "sender": m["sender"], "body": m["body"], "sent_at": m["sent_at"]}
                for m in db.list_messages(ticket_id)
            ],
        }

    @api.post("/tickets/{ticket_id}/messages")
    async def post_message(ticket_id: str, body: TicketMessage, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower() and not _is_owner(gc):
            raise HTTPException(403)
        sender = "admin" if _is_owner(gc) else "user"
        mid = db.add_message(ticket_id, sender, body.body)
        if sender == "user":
            try:
                await notify.user_message(bot, ticket_id, body.body)
            except Exception as e:
                log.warning("notify user_message: %s", e)
        return {"id": mid}

    @api.get("/tickets/{ticket_id}/messages")
    async def poll_messages(ticket_id: str, after: int = 0, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower() and not _is_owner(gc):
            raise HTTPException(403)
        return {
            "messages": [
                {"id": m["id"], "sender": m["sender"], "body": m["body"], "sent_at": m["sent_at"]}
                for m in db.list_messages(ticket_id, after_id=after)
            ],
            "status": t["status"],
        }

    def _usdt_for_ticket(t) -> float:
        """Возвращает USDT-эквивалент для тикета (по флагу скидки)."""
        if t["amount_rub"] <= config.PRICE_DISCOUNT_RUB:
            return config.PRICE_DISCOUNT_USDT
        return config.PRICE_FULL_USDT

    @api.post("/tickets/{ticket_id}/pay/send")
    async def pay_send(ticket_id: str, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower():
            raise HTTPException(403)
        if t["status"] == "confirmed":
            raise HTTPException(409, "already paid")
        db.set_payment_method(ticket_id, "send")
        comment = f"Тикет: {ticket_id}\nGC: {gc}"
        return {
            "wallet": config.SEND_WALLET,
            "wallet_link": f"https://t.me/{config.SEND_WALLET}",
            "send_link": config.SEND_URL,
            "amount_usdt": _usdt_for_ticket(t),
            "comment": comment,
        }

    @api.post("/tickets/{ticket_id}/pay/donate")
    async def pay_donate(ticket_id: str, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower():
            raise HTTPException(403)
        if t["status"] == "confirmed":
            raise HTTPException(409, "already paid")
        db.set_payment_method(ticket_id, "donate")
        comment = f"Тикет: {ticket_id}\nGC: {gc}"
        return {
            "donate_url": config.DONATE_URL,
            "amount_rub": t["amount_rub"],
            "comment": comment,
        }

    @api.post("/tickets/{ticket_id}/paid")
    async def mark_paid(ticket_id: str, gc: str = Depends(current_user)):
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower():
            raise HTTPException(403)
        if t["status"] == "confirmed":
            raise HTTPException(409, "already confirmed")
        db.update_ticket_status(ticket_id, "payment_sent")
        db.add_message(ticket_id, "system", "Юзер отметил оплату как отправленную. Ожидаем проверки.")
        try:
            method = t["payment_method"] or "send"
            await notify.payment_sent(bot, ticket_id, method)
        except Exception as e:
            log.warning("notify payment_sent: %s", e)
        return {"ok": True}

    @api.post("/tickets/{ticket_id}/cancel_payment")
    async def cancel_payment(ticket_id: str, gc: str = Depends(current_user)):
        """Отменяет подтверждение 'Я оплатил' — возвращает тикет в open."""
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        if t["gc_username"].lower() != gc.lower():
            raise HTTPException(403)
        if t["status"] not in ("payment_sent", "open"):
            raise HTTPException(409, "cannot cancel in current status")
        db.update_ticket_status(ticket_id, "open")
        db.add_message(ticket_id, "system", "Юзер отменил подтверждение оплаты. Выбери способ оплаты заново.")
        return {"ok": True}

    # ---- owner: admin панель ----

    class AdminVerifyReq(BaseModel):
        password: str = Field(max_length=200)

    @api.post("/admin/verify")
    async def admin_verify(body: AdminVerifyReq, gc: str = Depends(current_user)):
        if not _is_owner(gc):
            raise HTTPException(403)
        if not config.OWNER_PASSWORD:
            return {"ok": True}  # пароль не задан — пропускаем
        if body.password != config.OWNER_PASSWORD:
            raise HTTPException(403, "wrong_password")
        return {"ok": True}

    @api.get("/admin/tickets")
    async def admin_tickets(
        limit: int = 50, offset: int = 0, gc: str = Depends(current_user)
    ):
        if not _is_owner(gc):
            raise HTTPException(403)
        rows = db.list_all_tickets(limit=limit, offset=offset)
        total = db.count_tickets()
        return {
            "total": total,
            "tickets": [
                {
                    "ticket_id": r["ticket_id"],
                    "gc_username": r["gc_username"],
                    "status": r["status"],
                    "payment_method": r["payment_method"],
                    "amount_rub": r["amount_rub"],
                    "created_at": r["created_at"],
                    "updated_at": r["updated_at"],
                }
                for r in rows
            ],
        }

    # ---- owner: подтверждение тикета ----

    @api.post("/tickets/{ticket_id}/confirm")
    async def confirm_ticket(ticket_id: str, gc: str = Depends(current_user)):
        if not _is_owner(gc):
            raise HTTPException(403)
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        db.update_ticket_status(ticket_id, "confirmed")
        db.mark_premium(t["gc_username"], ticket_id)
        db.add_message(ticket_id, "system", "Оплата подтверждена. Premium активирован!")
        # Синкаем в ghostchat DB
        try:
            import sqlite3 as _sq
            _gc = _sq.connect("/opt/ghostchat/ghostchat.db", timeout=5)
            _gc.execute("UPDATE users SET has_premium=1 WHERE username=?", (t["gc_username"].lower(),))
            _gc.commit()
            _gc.close()
        except Exception:
            pass
        return {"ok": True}

    @api.post("/tickets/{ticket_id}/reject")
    async def reject_ticket(ticket_id: str, gc: str = Depends(current_user)):
        if not _is_owner(gc):
            raise HTTPException(403)
        t = db.get_ticket(ticket_id)
        if not t:
            raise HTTPException(404)
        db.update_ticket_status(ticket_id, "rejected")
        db.add_message(ticket_id, "system", "Оплата не подтверждена. Обратись в поддержку.")
        return {"ok": True}

    @api.delete("/account")
    async def delete_account(gc: str = Depends(current_user), response: Response = None):
        db.delete_user(gc)
        if response:
            response.delete_cookie("session", path="/")
        return {"ok": True}

    # ---- site analytics (public) ----

    class VisitReq(BaseModel):
        visitor_id: str = Field(min_length=8, max_length=64)

    class DownloadReq(BaseModel):
        visitor_id: str = Field(min_length=8, max_length=64)
        version:    str = Field(min_length=1, max_length=20)
        is_update:  bool = False

    class SkipReq(BaseModel):
        visitor_id: str = Field(min_length=8, max_length=64)

    @api.post("/stats/visit")
    async def stats_visit(body: VisitReq):
        is_new = db.record_visit(body.visitor_id)
        return {"is_new": is_new}

    @api.post("/stats/download")
    async def stats_download(body: DownloadReq):
        is_update = db.record_download(body.visitor_id, body.version)
        return {"ok": True, "is_update": is_update}

    @api.post("/stats/skip")
    async def stats_skip(body: SkipReq):
        db.record_skip(body.visitor_id)
        return {"ok": True}

    @api.get("/stats/latest_version")
    async def stats_latest_version():
        import urllib.request as _ur, json as _json
        try:
            with _ur.urlopen(f"{config.GC_API_URL.rstrip('/')}/api/version", timeout=3) as r:
                data = _json.loads(r.read())
                ver = data.get("latest_version") or data.get("version", "")
                if ver:
                    return {"version": ver}
        except Exception:
            pass
        # Fallback: read from APK filenames
        import glob as _glob, os.path as _op
        apks = sorted(_glob.glob("/opt/ghostchat/site/GhostChat-v*.apk"),
                      key=_op.getmtime, reverse=True)
        if apks:
            name = _op.basename(apks[0])
            ver = name.replace("GhostChat-v", "").replace(".apk", "")
            return {"version": ver}
        return {"version": ""}

    @api.get("/stats/data")
    async def stats_data():
        data = db.get_site_stats()
        import glob as _glob, os.path as _op, sqlite3 as _sq
        # Текущая версия из APK
        apks = sorted(_glob.glob("/opt/ghostchat/site/GhostChat-v*.apk"),
                      key=_op.getmtime, reverse=True)
        data["latest_version"] = (
            _op.basename(apks[0]).replace("GhostChat-v", "").replace(".apk", "")
            if apks else ""
        )
        # Версии из ghostchat (живые устройства / device_registry) — всегда заменяем
        import urllib.request as _ur, json as _json
        gc_versions = None
        try:
            with _ur.urlopen("http://127.0.0.1:8000/api/app_versions", timeout=3) as _r:
                gc_versions = _json.loads(_r.read()).get("versions")
        except Exception:
            pass
        if gc_versions:
            data["versions"] = gc_versions
        elif apks:
            data["versions"] = [
                {"version": _op.basename(a).replace("GhostChat-v","").replace(".apk",""), "count": 0}
                for a in apks
            ]
        else:
            data["versions"] = []
        return data

    app.include_router(api)

    # ---- static + pages ----

    app.mount(
        f"{config.URL_PREFIX}/static",
        StaticFiles(directory=str(config.STATIC_DIR)),
        name="static",
    )

    _html_cache: dict[str, str] = {}

    def _serve_html(name: str) -> Response:
        if name not in _html_cache:
            raw = (config.STATIC_DIR / name).read_text(encoding="utf-8")
            _html_cache[name] = raw.replace("{{PREFIX}}", config.URL_PREFIX)
        return Response(content=_html_cache[name], media_type="text/html; charset=utf-8")

    @app.get(f"{config.URL_PREFIX}/" if config.URL_PREFIX else "/")
    async def root():
        return _serve_html("premium.html")

    if config.URL_PREFIX:
        @app.get(config.URL_PREFIX)
        async def root_bare():
            return _serve_html("premium.html")

    @app.get(f"{config.URL_PREFIX}/login")
    async def page_login():
        return _serve_html("login.html")

    @app.get(f"{config.URL_PREFIX}/profile")
    async def page_profile():
        return _serve_html("profile.html")

    @app.get(f"{config.URL_PREFIX}/premium")
    async def page_premium():
        return _serve_html("premium.html")

    @app.get(f"{config.URL_PREFIX}/admin")
    async def page_admin():
        return _serve_html("admin.html")

    @app.get(f"{config.URL_PREFIX}/statistics")
    async def page_statistics():
        return _serve_html("statistics.html")

    @app.get(f"{config.URL_PREFIX}/healthz")
    async def healthz():
        return {"ok": True}

    return app
