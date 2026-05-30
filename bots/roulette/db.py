"""
SQLite-обёртка для OKey-бота.

Все таблицы создаются автоматически при первом старте.
SQL запросы простые — не используем ORM (зачем для одной таблицы).
"""
from __future__ import annotations

import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

DB_PATH = Path(__file__).parent / "data" / "okey.db"


def init_db() -> None:
    """Создать таблицы если их ещё нет. Вызывается при старте."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with conn() as c:
        c.executescript("""
        -- Все пользователи бота (даже до анкеты)
        CREATE TABLE IF NOT EXISTS users (
            tg_id        INTEGER PRIMARY KEY,
            username     TEXT,
            first_seen   INTEGER NOT NULL,
            last_seen    INTEGER NOT NULL,
            banned       INTEGER NOT NULL DEFAULT 0
        );

        -- Заполненная анкета юзера. У одного юзера — одна анкета.
        CREATE TABLE IF NOT EXISTS profiles (
            tg_id           INTEGER PRIMARY KEY REFERENCES users(tg_id) ON DELETE CASCADE,
            name            TEXT NOT NULL,
            age             INTEGER NOT NULL,
            gender          TEXT NOT NULL,          -- 'm' | 'f'
            looking_for     TEXT NOT NULL,          -- 'm' | 'f' | 'any'
            city            TEXT,
            bio             TEXT,
            photo_file_id   TEXT,                   -- Telegram file_id
            completed_at    INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_profiles_gender ON profiles(gender);
        CREATE INDEX IF NOT EXISTS idx_profiles_age ON profiles(age);

        -- (фаза 2) Лайки/дизлайки. Для поиска "interesting" анкет.
        CREATE TABLE IF NOT EXISTS likes (
            from_id     INTEGER NOT NULL,
            to_id       INTEGER NOT NULL,
            kind        TEXT NOT NULL,    -- 'like' | 'dislike'
            created_at  INTEGER NOT NULL,
            PRIMARY KEY (from_id, to_id)
        );
        CREATE INDEX IF NOT EXISTS idx_likes_to ON likes(to_id);

        -- (фаза 2) Matches — взаимные лайки
        CREATE TABLE IF NOT EXISTS matches (
            user_a      INTEGER NOT NULL,
            user_b      INTEGER NOT NULL,
            created_at  INTEGER NOT NULL,
            PRIMARY KEY (user_a, user_b)
        );

        -- (фаза 3) Очередь рулетки
        CREATE TABLE IF NOT EXISTS roulette_queue (
            tg_id           INTEGER PRIMARY KEY,
            joined_at       INTEGER NOT NULL,
            filter_gender   TEXT NOT NULL DEFAULT 'any'
        );

        -- (фаза 3-4) Активные диалоги (рулетка + матчи)
        CREATE TABLE IF NOT EXISTS dialogs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_a      INTEGER NOT NULL,
            user_b      INTEGER NOT NULL,
            kind        TEXT NOT NULL,            -- 'roulette' | 'match'
            started_at  INTEGER NOT NULL,
            ended_at    INTEGER,
            ended_by    INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_dialogs_a ON dialogs(user_a) WHERE ended_at IS NULL;
        CREATE INDEX IF NOT EXISTS idx_dialogs_b ON dialogs(user_b) WHERE ended_at IS NULL;

        -- (фаза 5) Жалобы
        CREATE TABLE IF NOT EXISTS reports (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            from_id     INTEGER NOT NULL,
            on_id       INTEGER NOT NULL,
            reason      TEXT,
            dialog_id   INTEGER,
            created_at  INTEGER NOT NULL,
            handled     INTEGER NOT NULL DEFAULT 0
        );
        """)


@contextmanager
def conn():
    """Контекст-менеджер для соединения с авто-commit/rollback."""
    c = sqlite3.connect(DB_PATH, isolation_level=None)  # autocommit
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA busy_timeout=5000")
    try:
        yield c
    finally:
        c.close()


# ── User tracking ────────────────────────────────────────────────────────────
def touch_user(tg_id: int, username: Optional[str]) -> None:
    """Запомнить юзера, обновить last_seen. Вызывать в любом handler."""
    now = int(time.time())
    with conn() as c:
        c.execute("""
            INSERT INTO users (tg_id, username, first_seen, last_seen)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tg_id) DO UPDATE SET
                username = excluded.username,
                last_seen = excluded.last_seen
        """, (tg_id, username, now, now))


def is_banned(tg_id: int) -> bool:
    with conn() as c:
        r = c.execute("SELECT banned FROM users WHERE tg_id=?", (tg_id,)).fetchone()
        return bool(r and r["banned"])


# ── Profiles ─────────────────────────────────────────────────────────────────
def get_profile(tg_id: int) -> Optional[dict]:
    with conn() as c:
        r = c.execute("SELECT * FROM profiles WHERE tg_id=?", (tg_id,)).fetchone()
        return dict(r) if r else None


def save_profile(
    tg_id: int,
    name: str,
    age: int,
    gender: str,
    looking_for: str,
    city: Optional[str],
    bio: Optional[str],
    photo_file_id: Optional[str],
) -> None:
    now = int(time.time())
    with conn() as c:
        # Insert или update
        existing = c.execute("SELECT tg_id FROM profiles WHERE tg_id=?", (tg_id,)).fetchone()
        if existing:
            c.execute("""
                UPDATE profiles SET
                    name=?, age=?, gender=?, looking_for=?,
                    city=?, bio=?, photo_file_id=?, updated_at=?
                WHERE tg_id=?
            """, (name, age, gender, looking_for, city, bio, photo_file_id, now, tg_id))
        else:
            c.execute("""
                INSERT INTO profiles (tg_id, name, age, gender, looking_for, city, bio, photo_file_id, completed_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (tg_id, name, age, gender, looking_for, city, bio, photo_file_id, now, now))


def delete_profile(tg_id: int) -> None:
    with conn() as c:
        c.execute("DELETE FROM profiles WHERE tg_id=?", (tg_id,))


# ── Stats для admin-UI ────────────────────────────────────────────────────────
def stats_overview() -> dict:
    with conn() as c:
        users = c.execute("SELECT COUNT(*) as n FROM users").fetchone()["n"]
        profiles = c.execute("SELECT COUNT(*) as n FROM profiles").fetchone()["n"]
        banned = c.execute("SELECT COUNT(*) as n FROM users WHERE banned=1").fetchone()["n"]
        # активные за 24ч
        day_ago = int(time.time()) - 86400
        active = c.execute("SELECT COUNT(*) as n FROM users WHERE last_seen >= ?", (day_ago,)).fetchone()["n"]
        # По полу
        males = c.execute("SELECT COUNT(*) as n FROM profiles WHERE gender='m'").fetchone()["n"]
        females = c.execute("SELECT COUNT(*) as n FROM profiles WHERE gender='f'").fetchone()["n"]
        return {
            "users_total": users,
            "profiles_total": profiles,
            "users_active_24h": active,
            "users_banned": banned,
            "profiles_male": males,
            "profiles_female": females,
        }
