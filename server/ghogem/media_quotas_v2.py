"""Atomic, cross-interface quota accounting for GhoGemo V2.

All account identifiers come from server-side identity. Media is counted per
user/file/window, not per analysis tool invocation. A pending claim holds a
short reservation; failed provider requests release it.
"""
from __future__ import annotations
from dataclasses import dataclass
from contextlib import closing
from datetime import datetime
import hashlib
from pathlib import Path
import secrets
import sqlite3
import time
from zoneinfo import ZoneInfo
import storage_v2

MOSCOW = ZoneInfo("Europe/Moscow")

POLICY = {
    "free": {"tts_hour": 5, "audio_hour": 15, "video_day": 3,
             "audio_segment_seconds": 60, "video_seconds": 20},
    "premium": {"tts_hour": 30, "audio_hour": 100, "video_day": 15,
                "audio_segment_seconds": 120, "video_seconds": 60},
}

@dataclass
class Claim:
    ok: bool
    token: str | None
    message: str
    remaining: int
    already_counted: bool = False

def _db_path(root: str, uid: int) -> Path:
    owner = storage_v2.owner_root(root, uid)
    owner.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = owner / "media_usage_v2.sqlite3"
    if path.is_symlink():
        raise storage_v2.StorageError("Некорректное хранилище квот.")
    return path

def _file_key(root: str, uid: int, filepath: str) -> str:
    owner = storage_v2.owner_root(root, uid)
    candidate = Path(filepath).resolve(strict=True)
    if not candidate.is_relative_to(owner):
        raise storage_v2.StorageError("Анализ ограничен собственной песочницей.")
    st = candidate.stat()
    # The same document uploaded again under an old chat filename is a new
    # physical version, so it must not inherit the previous file's quota pass.
    key = f"{candidate.relative_to(owner)}:{st.st_ino}:{st.st_mtime_ns}:{st.st_size}"
    return hashlib.sha256(key.encode()).hexdigest()

def _connection(root: str, uid: int):
    c = sqlite3.connect(str(_db_path(root, uid)), timeout=12)
    c.execute("PRAGMA busy_timeout=12000")
    c.execute(
        "CREATE TABLE IF NOT EXISTS events ("
        "token TEXT PRIMARY KEY, kind TEXT NOT NULL, file_key TEXT NOT NULL, "
        "created REAL NOT NULL, period TEXT NOT NULL, "
        "state TEXT NOT NULL, lease_until REAL NOT NULL)"
    )
    c.execute("CREATE INDEX IF NOT EXISTS media_events_kind_created ON events(kind,created)")
    return c

def _period(kind: str, now: float) -> tuple[str, float]:
    if kind == "video":
        period = datetime.fromtimestamp(now, MOSCOW).strftime("%Y-%m-%d")
        return period, 0
    return "hour", now - 3600

def reserve(root: str, uid: int, kind: str, premium: bool, filepath: str = "") -> Claim:
    """Reserve one slot, safe across concurrent Telegram and Web requests.

    Returns already_counted=True for a previously completed analysis of this
    file during the same window; repeated analysis is free.
    """
    if kind not in ("tts", "audio", "video"):
        return Claim(False,None,"❌ Неизвестный лимит.",0)
    if kind in ("audio", "video") and not filepath:
        return Claim(False,None,"❌ Не указан файл.",0)
    key = _file_key(root, uid, filepath) if filepath else secrets.token_hex(12)
    now = time.time()
    tier = "premium" if premium else "free"
    limit = POLICY[tier][{"tts":"tts_hour","audio":"audio_hour","video":"video_day"}[kind]]
    period, cutoff = _period(kind, now)
    with closing(_connection(root, uid)) as c, c:
        c.execute("BEGIN IMMEDIATE")
        # Release abandoned claims and keep the log compact. 24 hours for
        # video history; a little longer for hourly requests.
        c.execute("DELETE FROM events WHERE state='pending' AND lease_until < ?", (now,))
        c.execute("DELETE FROM events WHERE created < ?", (now - 20 * 86400,))
        if kind == "video":
            condition, values = "kind=? AND period=?", (kind,period)
        else:
            condition, values = "kind=? AND created>=?", (kind,cutoff)
        rows = c.execute(
            f"SELECT file_key,state FROM events WHERE {condition}",
            values,
        ).fetchall()
        if kind != "tts" and any(k == key and state == "done" for k,state in rows):
            return Claim(True,None,"✅ Повторный анализ этого файла не расходует квоту.",
                         max(0, limit-len(rows)), already_counted=True)
        if kind != "tts" and any(k == key and state == "pending" for k,state in rows):
            return Claim(False,None,"⏳ Этот файл уже обрабатывается в другом запросе.",
                         max(0,limit-len(rows)))
        if len(rows) >= limit:
            message = ("видео за сутки (МСК)" if kind == "video" else
                       "аудио за последние 60 минут" if kind == "audio"
                       else "озвучиваний за последние 60 минут")
            return Claim(False,None,f"⛔ Лимит {limit} {message} исчерпан.",
                         0)
        token = secrets.token_urlsafe(18)
        c.execute(
            "INSERT INTO events VALUES (?,?,?,?,?,?,?)",
            (token,kind,key,now,period,"pending",now+1800),
        )
        return Claim(True,token,"✅ Квота зарезервирована.",limit-len(rows)-1)

def finish(root: str, uid: int, token: str | None, success: bool) -> None:
    if token is None:
        return
    with closing(_connection(root,uid)) as c, c:
        c.execute("BEGIN IMMEDIATE")
        if success:
            c.execute("UPDATE events SET state='done' WHERE token=? AND state='pending'", (token,))
        else:
            c.execute("DELETE FROM events WHERE token=? AND state='pending'", (token,))

def usage(root: str, uid: int, premium: bool) -> dict:
    now = time.time()
    tier = POLICY["premium" if premium else "free"]
    out = {}
    with closing(_connection(root, uid)) as c:
        for kind, label, limit_key in (
            ("tts","tts","tts_hour"),("audio","audio","audio_hour"),("video","video","video_day")
        ):
            period,cutoff=_period(kind,now)
            if kind=="video":
                count=c.execute(
                    "SELECT COUNT(*) FROM events WHERE kind=? AND period=? AND "
                    "(state='done' OR lease_until>=?)",(kind,period,now)).fetchone()[0]
            else:
                count=c.execute(
                    "SELECT COUNT(*) FROM events WHERE kind=? AND created>=? AND "
                    "(state='done' OR lease_until>=?)",(kind,cutoff,now)).fetchone()[0]
            out[label]={"used":count,"limit":tier[limit_key],
                        "remaining":max(0,tier[limit_key]-count)}
    return out
