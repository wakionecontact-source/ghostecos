"""Shared GhostEcos validation, profile metadata and rate-limit helpers.

This module has no dependency on social_router so standalone product APIs can
reuse the contracts without importing the Social API application.
"""
import json
import math
import os
import re
import sqlite3
import time
from collections import defaultdict
from typing import Optional

from fastapi import HTTPException
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

_ph = PasswordHasher()


_NAME_MIN, _NAME_MAX = 2, 100

_USER_MIN, _USER_MAX, _USER_TOTAL = 3, 60, 64

_RESERVED = {
    'admin','administrator','root','system','ghost','ghostchat','ghostsocial',
    'ghostecos','support','help','mod','moderator','staff','team','official',
    'api','www','mail','test',
}

def _ctrl(cp: int) -> bool:
    return cp < 0x20 or (0x7F <= cp <= 0x9F)

def _invis(cp: int) -> bool:
    return (cp in (0x00AD, 0x034F, 0xFEFF, 0x180E) or
            0x200B <= cp <= 0x200F or 0x202A <= cp <= 0x202E or
            0x2060 <= cp <= 0x2064 or 0x2066 <= cp <= 0x206F or
            0xFFF9 <= cp <= 0xFFFB)

def _comb(cp: int) -> bool:
    return (0x0300 <= cp <= 0x036F or 0x0483 <= cp <= 0x0489 or
            0x0591 <= cp <= 0x05BD or
            cp in (0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7) or
            0x0610 <= cp <= 0x061A or 0x064B <= cp <= 0x065F or cp == 0x0670 or
            0x06D6 <= cp <= 0x06DC or 0x06DF <= cp <= 0x06E4 or
            0x06E7 <= cp <= 0x06E8 or 0x06EA <= cp <= 0x06ED or
            0x0900 <= cp <= 0x0903 or 0x093A <= cp <= 0x094F or
            0x0951 <= cp <= 0x0957 or 0x1AB0 <= cp <= 0x1AFF or
            0x1DC0 <= cp <= 0x1DFF or 0x20D0 <= cp <= 0x20FF or
            0xFE20 <= cp <= 0xFE2F)

def _val_name(raw: str) -> str:
    v = raw.strip()
    runes = list(v)
    if not runes:
        raise HTTPException(422, "Введите имя")
    if len(runes) < _NAME_MIN:
        raise HTTPException(422, f"Имя слишком короткое (минимум {_NAME_MIN})")
    if len(runes) > _NAME_MAX:
        raise HTTPException(422, f"Имя слишком длинное (максимум {_NAME_MAX})")
    for c in runes:
        cp = ord(c)
        if _ctrl(cp) or _invis(cp) or _comb(cp):
            raise HTTPException(422, "Имя содержит недопустимые символы")
    return v

def _val_username(raw: str) -> str:
    v = raw.strip().lower()
    if not v:
        raise HTTPException(422, "Введите имя пользователя")
    if len(v) > _USER_TOTAL:
        raise HTTPException(422, "Имя пользователя слишком длинное")
    for c in v:
        cp = ord(c)
        if not (0x61 <= cp <= 0x7A or 0x30 <= cp <= 0x39 or cp in (0x5F, 0x2E)):
            raise HTTPException(422, "Только латиница, цифры, _ и точка")
    nd = v.replace('.', '')
    if len(nd) < _USER_MIN:
        raise HTTPException(422, f"Минимум {_USER_MIN} символа (точки не в счёт)")
    if len(nd) > _USER_MAX:
        raise HTTPException(422, f"Максимум {_USER_MAX} символов (точки не в счёт)")
    if v in _RESERVED:
        raise HTTPException(422, "Это имя пользователя зарезервировано")
    return v

def _claim_public_handle(c, handle: str, owner_type: str, owner_id: int) -> str:
    """Reserve a globally unique public username.

    Usernames used to be protected only by ``users.username`` and the legacy
    channel table had its own unique index.  That made a user and a channel
    able to claim the same public name.  New channels and all user mutations
    go through this small registry instead; the old group implementation is
    deliberately not coupled to it.
    """
    normalized = _val_username(handle)
    if owner_type not in {"user", "channel", "legacy_channel"}:
        raise ValueError(f"unsupported public handle owner type: {owner_type}")
    try:
        c.execute(
            "INSERT INTO gc_public_handles (handle, owner_type, owner_id) "
            "VALUES (?, ?, ?)",
            (normalized, owner_type, owner_id),
        )
    except sqlite3.IntegrityError:
        row = c.execute(
            "SELECT owner_type, owner_id FROM gc_public_handles WHERE handle=?",
            (normalized,),
        ).fetchone()
        if row and row["owner_type"] == owner_type and int(row["owner_id"]) == int(owner_id):
            return normalized
        raise HTTPException(409, "Имя пользователя уже занято")
    return normalized

_BANNER_COLOR_RE = re.compile(r"^#?[0-9a-fA-F]{6}$")

def _normalize_banner_config(raw: dict) -> dict:
    """Validate the small public banner contract before persisting JSON."""
    if not isinstance(raw, dict):
        raise HTTPException(422, "Некорректный конфиг баннера")
    banner_type = raw.get("type", "solid")
    if banner_type not in {"solid", "linear", "lights"}:
        raise HTTPException(422, "Тип баннера должен быть solid, linear или lights")
    raw_colors = raw.get("colors")
    if not isinstance(raw_colors, list):
        raise HTTPException(422, "Баннер должен содержать цвета")
    min_colors = 2 if banner_type == "linear" else 1
    if not min_colors <= len(raw_colors) <= 10:
        raise HTTPException(422, "Баннер должен содержать от 1 до 10 цветов")
    colors = []
    for value in raw_colors:
        color = str(value).strip()
        if not _BANNER_COLOR_RE.fullmatch(color):
            raise HTTPException(422, "Цвет баннера должен быть в формате #RRGGBB")
        colors.append("#" + color.lstrip("#").upper())

    raw_background = raw.get("background_color", raw.get("background"))
    if raw_background is None:
        background_color = "#020617"
    else:
        background_color = str(raw_background).strip()
        if not _BANNER_COLOR_RE.fullmatch(background_color):
            raise HTTPException(422, "Цвет фона баннера должен быть в формате #RRGGBB")
        background_color = "#" + background_color.lstrip("#").upper()

    if banner_type in {"solid", "lights"}:
        stops = [0.0]
    else:
        raw_stops = raw.get("stops")
        if not isinstance(raw_stops, list) or len(raw_stops) != len(colors):
            raise HTTPException(422, "Для каждого цвета нужна позиция градиента")
        stops = []
        previous = 0.0
        for value in raw_stops:
            try:
                stop = float(value)
            except (TypeError, ValueError):
                raise HTTPException(422, "Позиция градиента должна быть числом")
            if not 0.0 <= stop <= 1.0 or stop < previous:
                raise HTTPException(422, "Позиции градиента должны идти по порядку от 0 до 1")
            stops.append(round(stop, 4))
            previous = stop

    if banner_type == "lights":
        angle = 0.0
    else:
        try:
            angle = float(raw.get("angle", 135.0))
        except (TypeError, ValueError):
            raise HTTPException(422, "Направление градиента должно быть числом")
        if not -360.0 <= angle <= 360.0:
            raise HTTPException(422, "Направление градиента должно быть от -360 до 360")
    def _point(value, label):
        if value is None:
            return None
        if not isinstance(value, list) or len(value) != 2:
            raise HTTPException(422, f"{label} must be a point [x, y]")
        try:
            x = float(value[0])
            y = float(value[1])
        except (TypeError, ValueError):
            raise HTTPException(422, f"{label} must contain numbers")
        if not 0.0 <= x <= 1.0 or not 0.0 <= y <= 1.0:
            raise HTTPException(422, f"{label} must be within 0..1")
        return [round(x, 4), round(y, 4)]

    def _edge_point(value, label):
        point = _point(value, label)
        if point is None:
            return None
        x, y = point
        distances = [y, 1.0 - x, 1.0 - y, x]
        nearest = min(range(4), key=distances.__getitem__)
        if distances[nearest] > 0.0002:
            raise HTTPException(422, f"{label} must be on the banner edge")
        if nearest == 0:
            return [x, 0.0]
        if nearest == 1:
            return [1.0, y]
        if nearest == 2:
            return [x, 1.0]
        return [0.0, y]

    lights = None
    raw_lights = raw.get("lights")
    if banner_type == "lights" and not isinstance(raw_lights, list):
        raise HTTPException(422, "lights must contain one item for each color")
    if raw_lights is not None:
        if not isinstance(raw_lights, list) or len(raw_lights) > 10:
            raise HTTPException(422, "lights must contain from 0 to 10 items")
        if banner_type == "lights" and len(raw_lights) != len(colors):
            raise HTTPException(422, "lights must contain one item for each color")
        lights = []
        for index, value in enumerate(raw_lights):
            if not isinstance(value, dict):
                raise HTTPException(422, "each light must be an object")
            color_index = value.get("color_index", 0)
            if not isinstance(color_index, int) or isinstance(color_index, bool):
                raise HTTPException(422, "light color_index must be an integer")
            if not 0 <= color_index < len(colors):
                raise HTTPException(422, "light color_index is out of range")
            if banner_type == "lights" and color_index != index:
                raise HTTPException(422, "lights must follow the colors order")
            position = (
                _edge_point(value.get("position"), "light position")
                if banner_type == "lights"
                else _point(value.get("position"), "light position")
            )
            if position is None:
                raise HTTPException(422, "light position is required")
            try:
                strength = float(value.get("strength", 0.65))
                direction = (
                    float(value.get("direction", 0.0))
                    if banner_type != "lights"
                    else None
                )
            except (TypeError, ValueError):
                raise HTTPException(422, "light strength must be a number")
            if direction is not None and (
                not math.isfinite(direction) or not -360.0 <= direction <= 360.0
            ):
                raise HTTPException(422, "light direction must be within -360..360")
            if not math.isfinite(strength) or not 0.0 <= strength <= 1.0:
                raise HTTPException(422, "light strength must be within 0..1")
            normalized_light = {
                "color_index": color_index,
                "position": position,
                "strength": round(strength, 4),
            }
            if direction is not None:
                normalized_light["direction"] = round(direction, 2)
            lights.append(normalized_light)

    result = {"type": banner_type, "colors": colors}
    if banner_type == "lights" or raw_background is not None:
        result["background_color"] = background_color
    if banner_type != "lights":
        result["stops"] = stops
        result["angle"] = round(angle, 2)
    if lights is not None:
        result["lights"] = lights
    elif banner_type != "lights":
        light = _point(raw.get("light"), "light")
        light_target = _point(raw.get("light_target"), "light_target")
        if (light is None) != (light_target is None):
            raise HTTPException(422, "light and light_target must be provided together")
        if light is not None:
            result["light"] = light
            result["light_target"] = light_target
    if len(json.dumps(result, separators=(",", ":"))) > 4096:
        raise HTTPException(413, "Конфиг баннера слишком большой")
    return result

_DEFAULT_BANNER_CONFIG = {
    "type": "lights",
    "colors": ["#7C3AED", "#A855F7"],
    "background_color": "#020617",
    "lights": [
        {
            "color_index": 0,
            "position": [0.24, 0.0],
            "strength": 0.7,
        },
        {
            "color_index": 1,
            "position": [1.0, 0.68],
            "strength": 0.7,
        },
    ],
}

def _decode_banner_config(raw, *, default_if_missing: bool = True) -> Optional[dict]:
    fallback = dict(_DEFAULT_BANNER_CONFIG) if default_if_missing else None
    if not raw:
        return fallback
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
        return value if isinstance(value, dict) else fallback
    except (TypeError, ValueError, json.JSONDecodeError):
        return fallback

def hash_argon2(password: str) -> str:
    return _ph.hash(password)

def verify_argon2(password: str, stored: str) -> bool:
    try:
        return _ph.verify(stored, password)
    except (VerifyMismatchError, InvalidHashError, Exception):
        return False

def _get_privacy_flags(c, user_id: int) -> dict:
    """Return privacy flags with safe defaults for pre-migration accounts."""
    row = c.execute(
        "SELECT * FROM user_privacy WHERE user_id=?",
        (user_id,),
    ).fetchone()
    if not row:
        return {
            "show_online": True,
            "send_read_receipts": True,
            "allow_channel_add": True,
            "allow_group_add": True,
            "message_privacy": "all",
            "username_visibility": "all",
            "display_name_visibility": "all",
            "avatar_visibility": "all",
            "banner_visibility": "all",
            "about_visibility": "all",
            "music_visibility": "all",
        }

    def flag(name: str, fallback: bool = True) -> bool:
        return bool(row[name]) if name in row.keys() and row[name] is not None else fallback

    def choice(name: str, fallback: str = "all") -> str:
        value = row[name] if name in row.keys() else None
        value = str(value or fallback).lower()
        return value if value in {"all", "contacts", "nobody"} else fallback

    return {
        "show_online": flag("show_online"),
        "send_read_receipts": flag("send_read_receipts"),
        "allow_channel_add": flag("allow_channel_add"),
        "allow_group_add": flag("allow_group_add"),
        "message_privacy": choice("message_privacy"),
        "username_visibility": choice("username_visibility"),
        "display_name_visibility": choice("display_name_visibility"),
        "avatar_visibility": choice("avatar_visibility"),
        "banner_visibility": choice("banner_visibility"),
        "about_visibility": choice("about_visibility"),
        "music_visibility": choice("music_visibility"),
    }

_rl_buckets: dict = defaultdict(list)

def _record_dm_direction(c, sender_id: int, receiver_id: int):
    if sender_id != receiver_id:
        c.execute(
            "INSERT OR IGNORE INTO chat_dm_call_history (sender_id, receiver_id) VALUES (?, ?)",
            (sender_id, receiver_id),
        )

_RATE_LIMIT_DISABLED = os.getenv("DISABLE_RATE_LIMIT") == "1"

def _rate_limit(key: str, limit: int, window: int):
    if _RATE_LIMIT_DISABLED:
        return  # для тестов / dev окружения
    now = time.time()
    arr = _rl_buckets[key] = [t for t in _rl_buckets[key] if now - t < window]
    if len(arr) >= limit:
        raise HTTPException(429, "Слишком много попыток, попробуйте позже")
    arr.append(now)

def _is_admin_user(user) -> bool:
    """Owner экосистемы — единственный юзер с is_admin=1 или username из env."""
    if user.get("is_admin"):
        return True
    owner = os.getenv("GE_OWNER_USERNAME", "").strip().lower()
    return bool(owner) and user.get("username", "").lower() == owner
