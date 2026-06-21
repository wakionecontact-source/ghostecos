"""SQLite для shop_bot — пользователи, тикеты, сообщения."""
import secrets
import sqlite3
import threading
import time
from typing import Optional

import config


_lock = threading.RLock()


_SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
    gc_username        TEXT    PRIMARY KEY,
    tg_id              INTEGER UNIQUE DEFAULT NULL,
    tg_username        TEXT    NOT NULL DEFAULT '',
    has_premium        INTEGER NOT NULL DEFAULT 0,
    premium_ticket_id  TEXT    NOT NULL DEFAULT '',
    registered_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tickets (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ticket_id        TEXT    NOT NULL UNIQUE,
    gc_username      TEXT    NOT NULL,
    status           TEXT    NOT NULL DEFAULT 'open',
    payment_method   TEXT    NOT NULL DEFAULT 'send',
    amount_rub       INTEGER NOT NULL DEFAULT 0,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    FOREIGN KEY (gc_username) REFERENCES users (gc_username) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tickets_gc ON tickets (gc_username);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets (status);

CREATE TABLE IF NOT EXISTS ticket_messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ticket_id   TEXT    NOT NULL,
    sender      TEXT    NOT NULL,
    body        TEXT    NOT NULL,
    sent_at     INTEGER NOT NULL,
    FOREIGN KEY (ticket_id) REFERENCES tickets (ticket_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tmsg_ticket ON ticket_messages (ticket_id, sent_at);

CREATE TABLE IF NOT EXISTS settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS site_visitors (
    visitor_id         TEXT    PRIMARY KEY,
    first_seen_at      INTEGER NOT NULL,
    downloaded_at      INTEGER,
    downloaded_version TEXT,
    is_update          INTEGER NOT NULL DEFAULT 0,
    skipped            INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS site_login_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    gc_username  TEXT    NOT NULL,
    logged_in_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_loginlog_user ON site_login_log (gc_username, logged_in_at);
"""


def _conn() -> sqlite3.Connection:
    c = sqlite3.connect(config.SHOP_DB_PATH, timeout=10, isolation_level=None)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    return c


def init() -> None:
    with _lock, _conn() as c:
        c.executescript(_SCHEMA)
        row = c.execute("SELECT value FROM settings WHERE key='launch_ts'").fetchone()
        if not row:
            c.execute(
                "INSERT INTO settings (key, value) VALUES ('launch_ts', ?)",
                (str(int(time.time())),),
            )


# ---------- settings ----------

def get_launch_ts() -> int:
    with _lock, _conn() as c:
        row = c.execute("SELECT value FROM settings WHERE key='launch_ts'").fetchone()
        return int(row["value"]) if row else int(time.time())


def is_discount_active() -> bool:
    return (int(time.time()) - get_launch_ts()) < config.DISCOUNT_HOURS * 3600


def discount_ends_at() -> int:
    return get_launch_ts() + config.DISCOUNT_HOURS * 3600


def current_price_rub() -> int:
    return config.PRICE_DISCOUNT_RUB if is_discount_active() else config.PRICE_FULL_RUB


# ---------- users ----------

def get_user(gc_username: str) -> Optional[sqlite3.Row]:
    with _lock, _conn() as c:
        return c.execute(
            "SELECT * FROM users WHERE LOWER(gc_username)=LOWER(?)", (gc_username,)
        ).fetchone()


def get_user_by_tg(tg_id: int) -> Optional[sqlite3.Row]:
    with _lock, _conn() as c:
        return c.execute("SELECT * FROM users WHERE tg_id=?", (tg_id,)).fetchone()


def get_or_create_user(gc_username: str) -> sqlite3.Row:
    """Создаёт пользователя если его нет (вход через сайт)."""
    with _lock, _conn() as c:
        row = c.execute(
            "SELECT * FROM users WHERE LOWER(gc_username)=LOWER(?)", (gc_username,)
        ).fetchone()
        if row:
            return row
        c.execute(
            "INSERT INTO users (gc_username, registered_at) VALUES (?, ?)",
            (gc_username.lower(), int(time.time())),
        )
        return c.execute(
            "SELECT * FROM users WHERE LOWER(gc_username)=LOWER(?)", (gc_username,)
        ).fetchone()


def link_tg(gc_username: str, tg_id: int, tg_username: str = "") -> None:
    """Привязывает Telegram к аккаунту (при взаимодействии с ботом)."""
    with _lock, _conn() as c:
        c.execute(
            "UPDATE users SET tg_id=?, tg_username=? WHERE LOWER(gc_username)=LOWER(?)",
            (tg_id, tg_username or "", gc_username),
        )


def update_username(gc_username: str, new_gc_username: str) -> None:
    with _lock, _conn() as c:
        c.execute(
            "UPDATE users SET gc_username=? WHERE LOWER(gc_username)=LOWER(?)",
            (new_gc_username.lower(), gc_username),
        )


def delete_user(gc_username: str) -> None:
    with _lock, _conn() as c:
        c.execute("DELETE FROM users WHERE LOWER(gc_username)=LOWER(?)", (gc_username,))


def mark_premium(gc_username: str, ticket_id: str) -> None:
    with _lock, _conn() as c:
        c.execute(
            "UPDATE users SET has_premium=1, premium_ticket_id=? WHERE LOWER(gc_username)=LOWER(?)",
            (ticket_id, gc_username),
        )


# ---------- tickets ----------

def _new_ticket_id() -> str:
    n = secrets.randbelow(10**8)
    return f"GP-{n:08d}"


def create_ticket(gc_username: str) -> str:
    now = int(time.time())
    ticket_id = _new_ticket_id()
    rub = current_price_rub()
    with _lock, _conn() as c:
        while c.execute("SELECT 1 FROM tickets WHERE ticket_id=?", (ticket_id,)).fetchone():
            ticket_id = _new_ticket_id()
        c.execute(
            """INSERT INTO tickets (ticket_id, gc_username, status, amount_rub,
                                    created_at, updated_at)
               VALUES (?, ?, 'open', ?, ?, ?)""",
            (ticket_id, gc_username.lower(), rub, now, now),
        )
    return ticket_id


def get_ticket(ticket_id: str) -> Optional[sqlite3.Row]:
    with _lock, _conn() as c:
        return c.execute(
            "SELECT * FROM tickets WHERE ticket_id=?", (ticket_id,)
        ).fetchone()


def list_user_tickets(gc_username: str) -> list:
    with _lock, _conn() as c:
        return list(
            c.execute(
                "SELECT * FROM tickets WHERE LOWER(gc_username)=LOWER(?) ORDER BY created_at DESC",
                (gc_username,),
            ).fetchall()
        )


def list_all_tickets(limit: int = 50, offset: int = 0) -> list:
    with _lock, _conn() as c:
        return list(
            c.execute(
                "SELECT * FROM tickets ORDER BY created_at ASC LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
        )


def count_tickets() -> int:
    with _lock, _conn() as c:
        row = c.execute("SELECT COUNT(*) AS n FROM tickets").fetchone()
        return int(row["n"]) if row else 0


def update_ticket_status(ticket_id: str, status: str) -> None:
    with _lock, _conn() as c:
        c.execute(
            "UPDATE tickets SET status=?, updated_at=? WHERE ticket_id=?",
            (status, int(time.time()), ticket_id),
        )


def set_payment_method(ticket_id: str, method: str) -> None:
    with _lock, _conn() as c:
        c.execute(
            "UPDATE tickets SET payment_method=?, updated_at=? WHERE ticket_id=?",
            (method, int(time.time()), ticket_id),
        )


# ---------- messages ----------

def add_message(ticket_id: str, sender: str, body: str) -> int:
    assert sender in ("user", "admin", "system")
    with _lock, _conn() as c:
        cur = c.execute(
            """INSERT INTO ticket_messages (ticket_id, sender, body, sent_at)
               VALUES (?, ?, ?, ?)""",
            (ticket_id, sender, body, int(time.time())),
        )
        return int(cur.lastrowid or 0)


def list_messages(ticket_id: str, after_id: int = 0) -> list:
    with _lock, _conn() as c:
        return list(
            c.execute(
                """SELECT * FROM ticket_messages
                   WHERE ticket_id=? AND id > ?
                   ORDER BY id ASC""",
                (ticket_id, after_id),
            ).fetchall()
        )


# ---------- site analytics ----------

def record_visit(visitor_id: str) -> bool:
    """Регистрирует посетителя. Возвращает True если новый."""
    now = int(time.time())
    with _lock, _conn() as c:
        existing = c.execute(
            "SELECT visitor_id FROM site_visitors WHERE visitor_id=?", (visitor_id,)
        ).fetchone()
        if existing:
            return False
        c.execute(
            "INSERT INTO site_visitors (visitor_id, first_seen_at) VALUES (?, ?)",
            (visitor_id, now),
        )
        return True


def record_download(visitor_id: str, version: str) -> bool:
    """Отмечает скачивание. Возвращает True если это обновление (не первый раз)."""
    now = int(time.time())
    with _lock, _conn() as c:
        row = c.execute(
            "SELECT downloaded_version FROM site_visitors WHERE visitor_id=?", (visitor_id,)
        ).fetchone()
        is_update = bool(row and row["downloaded_version"])
        if row:
            c.execute(
                """UPDATE site_visitors
                   SET downloaded_at=?, downloaded_version=?, is_update=?, skipped=0
                   WHERE visitor_id=?""",
                (now, version, 1 if is_update else 0, visitor_id),
            )
        else:
            c.execute(
                """INSERT INTO site_visitors (visitor_id, first_seen_at, downloaded_at, downloaded_version, is_update)
                   VALUES (?, ?, ?, ?, 0)""",
                (visitor_id, now, now, version),
            )
        return is_update


def record_skip(visitor_id: str) -> None:
    """Новый посетитель не стал скачивать."""
    with _lock, _conn() as c:
        c.execute(
            "UPDATE site_visitors SET skipped=1 WHERE visitor_id=? AND downloaded_at IS NULL",
            (visitor_id,),
        )


def record_login_event(gc_username: str) -> bool:
    """Записывает вход. Возвращает True если засчитан (не дубль за 2ч)."""
    now = int(time.time())
    cutoff = now - 7200  # 2 часа
    with _lock, _conn() as c:
        recent = c.execute(
            "SELECT id FROM site_login_log WHERE gc_username=? AND logged_in_at > ?",
            (gc_username.lower(), cutoff),
        ).fetchone()
        if recent:
            return False
        c.execute(
            "INSERT INTO site_login_log (gc_username, logged_in_at) VALUES (?, ?)",
            (gc_username.lower(), now),
        )
        return True


def get_site_stats() -> dict:
    """Возвращает расширенную сводную статистику сайта (без миграций БД)."""
    now      = int(time.time())
    day_ago  = now - 86400
    week_ago = now - 7 * 86400
    with _lock, _conn() as c:
        def n(sql, params=()):
            return c.execute(sql, params).fetchone()[0]

        # ── Визиты / скачивания ──
        total_visitors   = n("SELECT COUNT(*) FROM site_visitors")
        visitors_24h     = n("SELECT COUNT(*) FROM site_visitors WHERE first_seen_at>=?", (day_ago,))
        visitors_7d      = n("SELECT COUNT(*) FROM site_visitors WHERE first_seen_at>=?", (week_ago,))
        downloaded_total = n("SELECT COUNT(*) FROM site_visitors WHERE downloaded_at IS NOT NULL")
        new_downloads    = n("SELECT COUNT(*) FROM site_visitors WHERE downloaded_at IS NOT NULL AND is_update=0")
        updates          = n("SELECT COUNT(*) FROM site_visitors WHERE is_update=1")
        downloads_7d     = n("SELECT COUNT(*) FROM site_visitors WHERE downloaded_at>=?", (week_ago,))
        no_download      = n("SELECT COUNT(*) FROM site_visitors WHERE downloaded_at IS NULL AND skipped=1")

        # ── Входы ──
        total_logins  = n("SELECT COUNT(*) FROM site_login_log")
        unique_logins = n("SELECT COUNT(DISTINCT gc_username) FROM site_login_log")
        logins_7d     = n("SELECT COUNT(*) FROM site_login_log WHERE logged_in_at>=?", (week_ago,))
        active_7d     = n("SELECT COUNT(DISTINCT gc_username) FROM site_login_log WHERE logged_in_at>=?", (week_ago,))

        # ── Аккаунты ──
        total_users   = n("SELECT COUNT(*) FROM users")
        premium_users = n("SELECT COUNT(*) FROM users WHERE has_premium=1")
        new_users_7d  = n("SELECT COUNT(*) FROM users WHERE registered_at>=?", (week_ago,))

        # ── Тикеты / доход ──
        open_tickets      = n("SELECT COUNT(*) FROM tickets WHERE status='open'")
        paid_tickets      = n("SELECT COUNT(*) FROM tickets WHERE status='payment_sent'")
        confirmed_tickets = n("SELECT COUNT(*) FROM tickets WHERE status='confirmed'")
        total_tickets     = n("SELECT COUNT(*) FROM tickets")
        revenue_confirmed = n("SELECT COALESCE(SUM(amount_rub),0) FROM tickets WHERE status='confirmed'")

        # ── Мета ──
        launch_row   = c.execute("SELECT value FROM settings WHERE key='launch_ts'").fetchone()
        launch_ts    = int(launch_row[0]) if launch_row else now
        days_running = max(0, (now - launch_ts) // 86400)

        ver_rows = c.execute(
            """SELECT downloaded_version, COUNT(*) as cnt
               FROM site_visitors WHERE downloaded_version IS NOT NULL
               GROUP BY downloaded_version ORDER BY cnt DESC"""
        ).fetchall()

    def pct(part, whole):
        return round(part / whole * 100, 1) if whole else 0.0

    return {
        # объём аудитории
        "total_visitors":      total_visitors,
        "visitors_24h":        visitors_24h,
        "visitors_7d":         visitors_7d,
        # скачивания
        "new_downloads":       new_downloads,
        "updates":             updates,
        "total_downloads":     new_downloads + updates,
        "downloaded_total":    downloaded_total,
        "downloads_7d":        downloads_7d,
        "no_download":         no_download,
        "conversion_pct":      pct(downloaded_total, total_visitors),
        "skip_pct":            pct(no_download, total_visitors),
        # входы
        "total_logins":        total_logins,
        "unique_logins":       unique_logins,
        "logins_7d":           logins_7d,
        "active_7d":           active_7d,
        "avg_logins_per_user": round(total_logins / unique_logins, 1) if unique_logins else 0.0,
        # аккаунты
        "total_users":         total_users,
        "premium_users":       premium_users,
        "premium_pct":         pct(premium_users, total_users),
        "new_users_7d":        new_users_7d,
        # покупки / доход
        "open_tickets":        open_tickets,
        "paid_tickets":        paid_tickets,
        "confirmed_tickets":   confirmed_tickets,
        "total_tickets":       total_tickets,
        "revenue_confirmed":   revenue_confirmed,
        # мета
        "days_running":        days_running,
        "versions":            [{"version": r["downloaded_version"], "count": r["cnt"]} for r in ver_rows],
    }
