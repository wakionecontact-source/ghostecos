"""Общие помощники видимости профиля для API GhostEcos."""
import sqlite3
from .shared import _decode_banner_config, _get_privacy_flags


def _profile_music(c, user_id: int) -> list:
    """Возвращает плейлист профиля по порядку, не более двадцати треков."""
    base = ("SELECT source, track_id, slug, url, name, artist, album, "
            "cover_url, duration_ms")
    tail = (" FROM soc_profile_music_tracks WHERE user_id=? "
            "ORDER BY position ASC, id ASC LIMIT 20")
    has_source_post = True
    try:
        rows = c.execute(base + ", source_post_id" + tail, (user_id,)).fetchall()
    except sqlite3.OperationalError:
        has_source_post = False
        try:
            rows = c.execute(base + tail, (user_id,)).fetchall()
        except sqlite3.OperationalError:
            rows = []
    return [
        {
            "source": row["source"],
            "track_id": row["track_id"],
            "slug": row["slug"],
            "url": row["url"],
            "name": row["name"],
            "artist": row["artist"],
            "album": row["album"],
            "cover_url": row["cover_url"],
            "duration_ms": row["duration_ms"],
            "source_post_id": (row["source_post_id"] if has_source_post else None),
        }
        for row in rows
    ]

def _is_contact(c, owner_id: int, contact_id: int) -> bool:
    return c.execute(
        "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
        (owner_id, contact_id),
    ).fetchone() is not None

def _profile_is_private(c, target_id: int, viewer_id: int) -> bool:
    """Скрытый юзернейм закрывает профиль целиком для всех, кроме владельца."""
    if int(target_id) == int(viewer_id):
        return False
    return _get_privacy_flags(c, int(target_id)).get("username_visibility") == "nobody"


def _profile_visibility(c, target: dict, viewer_id: int) -> dict:
    """Применяет видимость профиля перед отправкой клиенту."""
    if int(target["id"]) == int(viewer_id):
        return {
            "username": target.get("username"),
            "display_name": target.get("display_name"),
            "about": target.get("about"),
            "avatar_url": target.get("avatar_url"),
            "banner": _decode_banner_config(target.get("banner_config")),
            "profile_music": _profile_music(c, int(target["id"])),
            "created_at": (
                None
                if _get_privacy_flags(c, int(target["id"])).get("created_visibility") == "nobody"
                else target.get("created_at")
            ),
            "profile_hidden": False,
            "display_name_hidden": False,
            "profile_private": False,
        }
    flags = _get_privacy_flags(c, int(target["id"]))
    if flags.get("username_visibility") == "nobody":
        # Скрытый ник = закрытый профиль: не отдаём ни имени, ни аватара, ни постов
        return {
            "username": None,
            "display_name": None,
            "about": None,
            "avatar_url": None,
            "banner": None,
            "profile_music": None,
            "created_at": None,
            "profile_hidden": True,
            "display_name_hidden": True,
            "profile_private": True,
        }
    connected = _is_contact(c, int(target["id"]), int(viewer_id))

    def allowed(field: str) -> bool:
        audience = flags.get(field, "all")
        return audience == "all" or (audience == "contacts" and connected)

    visible = {
        "username": allowed("username_visibility"),
        "display_name": allowed("display_name_visibility"),
        "about": allowed("about_visibility"),
        "avatar_url": allowed("avatar_visibility"),
        "banner": allowed("banner_visibility"),
        "music": allowed("music_visibility"),
    }
    if not any(visible.values()):
        # Это зарезервированный клиентом анонимный стиль, а не имя, заданное юзером.
        return {
            "username": None,
            "display_name": "Скрыто",
            "about": None,
            "avatar_url": None,
            "banner": None,
            "profile_music": None,
            "created_at": None,
            "profile_hidden": True,
            "display_name_hidden": True,
        }
    return {
        "username": target.get("username") if visible["username"] else None,
        "display_name": target.get("display_name") if visible["display_name"] else "Скрыто",
        "about": target.get("about") if visible["about"] else None,
        "avatar_url": target.get("avatar_url") if visible["avatar_url"] else None,
        "banner": _decode_banner_config(target.get("banner_config")) if visible["banner"] else None,
        "profile_music": _profile_music(c, int(target["id"])) if visible["music"] else None,
        "created_at": target.get("created_at") if allowed("created_visibility") else None,
        "profile_hidden": False,
        "display_name_hidden": not visible["display_name"],
        "profile_private": False,
    }
