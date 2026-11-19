"""Мост со старых путей GhostID на v2.

Старые API не редиректим: на них живёт GhostChat APK, который обновить нельзя,
а клиент не умеет ни следовать 308, ни разбирать новый ответ. Поэтому:
— старым страницам редирект, они открываются браузером;
— старым API — заголовки Deprecation и Link на преемника, поведение прежнее.
"""
from __future__ import annotations

from fastapi import Request
from fastapi.responses import JSONResponse, RedirectResponse

V2_HOME = "/v2/auth"
V2_PREFIX = "/api/v2/auth"

# Старые страницы: браузер уйдёт на новую форму без потери смысла.
PAGE_REDIRECTS = {
    "/auth/sso-demo.html": V2_HOME,
    "/auth/login.html": V2_HOME,
    "/auth/register.html": V2_HOME,
    "/auth/v1": V2_HOME,
}

# Старые API: сопоставление с преемником только для подсказки в заголовке.
SUCCESSORS = {
    "/api/sso/entrance": V2_PREFIX + "/authorize",
    "/api/sso/requests": V2_PREFIX + "/requests",
    "/api/sso/token": V2_PREFIX + "/token",
    "/api/sso/refresh": V2_PREFIX + "/token",
    "/api/sso/userinfo": V2_PREFIX + "/me",
    "/api/sso/devices": V2_PREFIX + "/devices",
}


def _successor(path: str) -> str:
    for prefix, target in SUCCESSORS.items():
        if path == prefix or path.startswith(prefix + "/"):
            return target
    return ""


def install(app):
    @app.middleware("http")
    async def legacy_bridge(request: Request, call_next):
        path = request.url.path
        target = PAGE_REDIRECTS.get(path)
        if target and request.method in {"GET", "HEAD"}:
            return RedirectResponse(target + "?" + request.url.query if request.url.query else target,
                                    status_code=308)

        response = await call_next(request)
        successor = _successor(path)
        if successor:
            response.headers["Deprecation"] = "true"
            response.headers["Link"] = f'<{successor}>; rel="successor-version"'
            response.headers.setdefault("Warning", '299 - "GhostID: endpoint is frozen, use /api/v2/auth"')
        return response
