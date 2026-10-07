"""Shared account-profile visibility helpers used by GhostEcos APIs."""
import sqlite3
from .shared import _decode_banner_config, _get_privacy_flags


def _profile_music(c, user_id: int) -> list:
    """Return the ordered profile playlist (maximum three tracks)."""
    try:
        rows = c.execute(
            "SELECT source, track_id, slug, url, name, artist, album, "
            "cover_url, duration_ms FROM soc_profile_music_tracks "
            "WHERE user_id=? ORDER BY position ASC, id ASC LIMIT 3",
            (user_id,),
        ).fetchall()
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
        }
        for row in rows
    ]

def _is_contact(c, owner_id: int, contact_id: int) -> bool:
    return c.execute(
        "SELECT 1 FROM chat_contacts WHERE owner_id=? AND contact_id=? LIMIT 1",
        (owner_id, contact_id),
    ).fetchone() is not None

def _profile_visibility(c, target: dict, viewer_id: int) -> dict:
    """Apply account profile visibility before a profile leaves the server."""
    if int(target["id"]) == int(viewer_id):
        return {
            "username": target.get("username"),
            "display_name": target.get("display_name"),
            "about": target.get("about"),
            "avatar_url": target.get("avatar_url"),
            "banner": _decode_banner_config(target.get("banner_config")),
            "profile_music": _profile_music(c, int(target["id"])),
            "profile_hidden": False,
            "display_name_hidden": False,
        }
    flags = _get_privacy_flags(c, int(target["id"]))
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
        # This marker is interpreted by the client as a reserved anonymous
        # profile style; it is not a user-controlled display-name format.
        return {
            "username": None,
            "display_name": "Скрыто",
            "about": None,
            "avatar_url": None,
            "banner": None,
            "profile_music": None,
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
        "profile_hidden": False,
        "display_name_hidden": not visible["display_name"],
    }
