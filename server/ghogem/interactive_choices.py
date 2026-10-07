"""Persistent interactive multiple-choice questions for the Telegram bot."""
from __future__ import annotations

import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager

DB_PATH = os.getenv(
    "GHOGEM_INTERACTIVE_CHOICES_DB",
    os.path.join(os.path.dirname(__file__), "interactive_choices.db"),
)
DEFAULT_TTL = int(os.getenv("GHOGEM_CHOICE_TTL_SECONDS", "3600"))


def _conn() -> sqlite3.Connection:
    db = sqlite3.connect(DB_PATH, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("""
        CREATE TABLE IF NOT EXISTS interactive_choices (
            token TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            telegram_chat_id INTEGER NOT NULL,
            message_id INTEGER NOT NULL DEFAULT 0,
            ai_chat_id TEXT NOT NULL,
            question TEXT NOT NULL,
            options_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'open',
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )
    """)
    db.execute(
        "CREATE INDEX IF NOT EXISTS idx_choices_user_status "
        "ON interactive_choices(user_id,status,created_at)"
    )
    return db


@contextmanager
def _db():
    db = _conn()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def _row(row) -> dict | None:
    if row is None:
        return None
    item = dict(row)
    try:
        item["options"] = json.loads(item.pop("options_json"))
    except Exception:
        item["options"] = []
    return item


def create(
    user_id: int,
    telegram_chat_id: int,
    ai_chat_id: str,
    question: str,
    options: list[str],
    *,
    ttl: int = DEFAULT_TTL,
) -> dict:
    now = int(time.time())
    expires = now + max(300, int(ttl))
    token = secrets.token_hex(6)
    with _db() as db:
        # Only one live interactive question per user. Old cards become stale,
        # but remain in SQLite for harmless callback diagnostics.
        db.execute(
            "UPDATE interactive_choices SET status='superseded' "
            "WHERE user_id=? AND status IN ('open','custom')",
            (int(user_id),),
        )
        db.execute(
            """
            INSERT INTO interactive_choices(
                token,user_id,telegram_chat_id,message_id,ai_chat_id,
                question,options_json,status,created_at,expires_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            (
                token,int(user_id),int(telegram_chat_id),0,str(ai_chat_id),
                str(question),json.dumps(options,ensure_ascii=False),
                "open",now,expires,
            ),
        )
    return get(token, include_closed=True)


def attach_message(token: str, message_id: int) -> None:
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET message_id=? WHERE token=?",
            (int(message_id),str(token)),
        )


def get(token: str, *, include_closed: bool = False) -> dict | None:
    now = int(time.time())
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET status='expired' "
            "WHERE expires_at<? AND status IN ('open','custom')",
            (now,),
        )
        row = db.execute(
            "SELECT * FROM interactive_choices WHERE token=?",
            (str(token),),
        ).fetchone()
    item = _row(row)
    if not item:
        return None
    if not include_closed and item["status"] not in ("open","custom"):
        return None
    return item


def begin_custom(token: str, user_id: int) -> dict | None:
    now = int(time.time())
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET status='expired' "
            "WHERE expires_at<? AND status IN ('open','custom')",
            (now,),
        )
        changed = db.execute(
            "UPDATE interactive_choices SET status='custom' "
            "WHERE token=? AND user_id=? AND status IN ('open','custom')",
            (str(token),int(user_id)),
        ).rowcount
        if not changed:
            return None
        row = db.execute(
            "SELECT * FROM interactive_choices WHERE token=?",
            (str(token),),
        ).fetchone()
    return _row(row)


def custom_for_user(user_id: int) -> dict | None:
    now = int(time.time())
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET status='expired' "
            "WHERE expires_at<? AND status IN ('open','custom')",
            (now,),
        )
        row = db.execute(
            """
            SELECT * FROM interactive_choices
            WHERE user_id=? AND status='custom'
            ORDER BY created_at DESC LIMIT 1
            """,
            (int(user_id),),
        ).fetchone()
    return _row(row)


def consume(token: str, user_id: int, *, custom_only: bool = False) -> dict | None:
    now = int(time.time())
    allowed = ("custom",) if custom_only else ("open","custom")
    placeholders = ",".join("?" for _ in allowed)
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET status='expired' "
            "WHERE expires_at<? AND status IN ('open','custom')",
            (now,),
        )
        row = db.execute(
            "SELECT * FROM interactive_choices WHERE token=? AND user_id=?",
            (str(token),int(user_id)),
        ).fetchone()
        item = _row(row)
        if not item or item["status"] not in allowed:
            return None
        changed = db.execute(
            f"UPDATE interactive_choices SET status='resolved' "
            f"WHERE token=? AND user_id=? AND status IN ({placeholders})",
            (str(token),int(user_id),*allowed),
        ).rowcount
        if changed != 1:
            return None
    item["status"] = "resolved"
    return item


def expire_user(user_id: int) -> None:
    with _db() as db:
        db.execute(
            "UPDATE interactive_choices SET status='superseded' "
            "WHERE user_id=? AND status IN ('open','custom')",
            (int(user_id),),
        )


def prune(max_age_seconds: int = 7 * 24 * 3600) -> int:
    cutoff = int(time.time()) - max(3600,int(max_age_seconds))
    with _db() as db:
        cur = db.execute(
            "DELETE FROM interactive_choices WHERE created_at<? "
            "AND status NOT IN ('open','custom')",
            (cutoff,),
        )
        return int(cur.rowcount or 0)
