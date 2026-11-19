"""Проверка юзернеймов GhostChat через HTTP API сервера."""
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

import config

log = logging.getLogger(__name__)


def _gc_internal_post(path: str, payload: dict, timeout: int = 8) -> dict:
    """POST к GhostChat internal API. Бросает исключение при ошибке."""
    if not config.GC_API_URL:
        raise RuntimeError("GC_API_URL not set")
    url = f"{config.GC_API_URL.rstrip('/')}{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                  headers={"Content-Type": "application/json",
                                           "X-Internal-Key": config.GC_INTERNAL_KEY})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def shop_login_init(username: str, password: str, client_ip: str = "", device_id: str = "") -> dict:
    """Логин через /api/login GhostChat сервера."""
    import uuid as _uuid
    username = (username or "").strip().lstrip("@").lower()
    payload = {
        "username": username,
        "password": password,
        "device_id": "shop_" + str(_uuid.uuid4()),
        "device_name": "GhostChat Shop",
    }
    return _gc_internal_post("/api/login", payload)


def gc_login_poll(request_id: str) -> dict:
    """Опрашивает статус pending_login на GhostChat сервере."""
    if not config.GC_API_URL:
        return {"status": "error"}
    url = f"{config.GC_API_URL.rstrip('/')}/api/login_request/{urllib.parse.quote(request_id)}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception as e:
        log.error("gc_login_poll error: %s", e)
        return {"status": "error"}


def gc_code_ready(request_id: str) -> dict:
    """Сообщает GhostChat серверу что код сгенерирован."""
    try:
        return _gc_internal_post(f"/api/login_request/{urllib.parse.quote(request_id)}/code_ready", {})
    except Exception as e:
        log.error("gc_code_ready error: %s", e)
        return {"ok": False}


def gc_code_verify(request_id: str, matches: bool) -> dict:
    """Сообщает GhostChat серверу результат проверки кода."""
    try:
        return _gc_internal_post(
            f"/api/login_request/{urllib.parse.quote(request_id)}/code_verify",
            {"matches": matches}
        )
    except Exception as e:
        log.error("gc_code_verify error: %s", e)
        return {"ok": False}


def username_exists(username: str) -> bool:
    """True если такой юзер есть в GhostChat.
    Если GC_API_URL не задан — пропускаем проверку (локальный тест).
    Если API недоступен или отвечает ошибкой — БЛОКИРУЕМ (fail closed)."""
    username = (username or "").strip().lstrip("@")
    if not username:
        return False

    if not config.GC_API_URL:
        log.warning("GC_API_URL не задан — пропускаем проверку юзернейма")
        return True  # только локальная разработка

    params = urllib.parse.urlencode({
        "username": username,
        "key": config.GC_INTERNAL_KEY,
    })
    url = f"{config.GC_API_URL.rstrip('/')}/internal/check_user?{params}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
            return bool(data.get("exists", False))
    except urllib.error.HTTPError as e:
        log.error("GC API HTTP %s для '%s' — блокируем вход", e.code, username)
        return False  # fail closed: любая HTTP ошибка = не пускаем
    except Exception as e:
        log.error("GC API недоступен (%s) — блокируем вход для '%s'", e, username)
        return False  # fail closed: сеть упала = не пускаем
