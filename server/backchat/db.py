"""
SQLite database layer for GhostChat relay server.
"""
import os
import sqlite3
import threading
import time
from typing import Optional, List

_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghostchat_server.db")
_lock = threading.RLock()

_SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA secure_delete = ON;

CREATE TABLE IF NOT EXISTS users (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    username     TEXT    NOT NULL UNIQUE,
    display_name TEXT    NOT NULL DEFAULT '',
    about        TEXT    NOT NULL DEFAULT '',
    argon2_hash  TEXT    NOT NULL,
    x25519_pub   TEXT    NOT NULL DEFAULT '',
    ed25519_pub  TEXT    NOT NULL DEFAULT '',
    screen_block INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    from_username   TEXT    NOT NULL,
    to_username     TEXT    NOT NULL,
    enc_body        TEXT    NOT NULL,
    msg_id          TEXT    NOT NULL UNIQUE,
    sent_at         INTEGER NOT NULL,
    delivered       INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    forwarded_from  TEXT    NOT NULL DEFAULT '',
    reply_to_msg_id TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_messages_to
    ON messages (to_username, delivered);

CREATE TABLE IF NOT EXISTS message_receipts (
    msg_id       TEXT    NOT NULL PRIMARY KEY,
    from_user    TEXT    NOT NULL,
    to_user      TEXT    NOT NULL,
    sent_at      INTEGER NOT NULL DEFAULT 0,
    delivered_at INTEGER NOT NULL DEFAULT 0,
    seen_at      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS offline_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    to_username TEXT   NOT NULL,
    type       TEXT   NOT NULL,
    msg_id     TEXT   NOT NULL,
    enc_body   TEXT   NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_to
    ON offline_events (to_username);

CREATE TABLE IF NOT EXISTS contacts (
    user_a     TEXT    NOT NULL,
    user_b     TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_a, user_b)
);

CREATE TABLE IF NOT EXISTS channels (
    id          TEXT    PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    tag         TEXT    NOT NULL UNIQUE DEFAULT '',
    description TEXT    NOT NULL DEFAULT '',
    type        TEXT    NOT NULL DEFAULT 'group',
    is_private  INTEGER NOT NULL DEFAULT 0,
    creator     TEXT    NOT NULL,
    created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_keys (
    channel_id  TEXT NOT NULL,
    username    TEXT NOT NULL,
    wrapped_key TEXT NOT NULL,
    PRIMARY KEY (channel_id, username)
);

CREATE TABLE IF NOT EXISTS channel_join_requests (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id  TEXT    NOT NULL,
    username    TEXT    NOT NULL,
    status      TEXT    NOT NULL DEFAULT 'pending',
    created_at  INTEGER NOT NULL,
    UNIQUE(channel_id, username)
);

CREATE TABLE IF NOT EXISTS channel_members (
    channel_id  TEXT    NOT NULL,
    username    TEXT    NOT NULL,
    role        TEXT    NOT NULL DEFAULT 'member',
    joined_at   INTEGER NOT NULL,
    PRIMARY KEY (channel_id, username)
);

CREATE TABLE IF NOT EXISTS channel_messages (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id    TEXT    NOT NULL,
    from_username TEXT    NOT NULL,
    display_name  TEXT    NOT NULL DEFAULT '',
    body          TEXT    NOT NULL,
    msg_id        TEXT    NOT NULL UNIQUE,
    sent_at       INTEGER NOT NULL,
    created_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_channel_msgs
    ON channel_messages (channel_id, sent_at);

CREATE TABLE IF NOT EXISTS pending_files (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id       TEXT    NOT NULL UNIQUE,
    from_username TEXT    NOT NULL,
    to_username   TEXT    NOT NULL,
    filename      TEXT    NOT NULL,
    mime_type     TEXT    NOT NULL DEFAULT '',
    file_size     INTEGER NOT NULL DEFAULT 0,
    file_path     TEXT    NOT NULL,
    enc_key       TEXT    NOT NULL DEFAULT '',
    msg_id        TEXT    NOT NULL,
    status        TEXT    NOT NULL DEFAULT 'uploaded',
    sha256        TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    expires_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS file_requests (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id       TEXT    NOT NULL,
    from_username TEXT    NOT NULL,
    to_username   TEXT    NOT NULL,
    filename      TEXT    NOT NULL,
    msg_id        TEXT    NOT NULL,
    status        TEXT    NOT NULL DEFAULT 'pending',
    created_at    INTEGER NOT NULL
);
"""

_conn: Optional[sqlite3.Connection] = None


def get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(_DB_PATH, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.executescript(_SCHEMA)
        # Migrate: add columns/tables if missing (idempotent)
        for col_sql in [
            "ALTER TABLE messages ADD COLUMN forwarded_from TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE messages ADD COLUMN reply_to_msg_id TEXT NOT NULL DEFAULT ''",
            # offline_events table (created via _SCHEMA on new installs, migrate here for existing DBs)
            """CREATE TABLE IF NOT EXISTS offline_events (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                to_username TEXT    NOT NULL,
                type        TEXT    NOT NULL,
                msg_id      TEXT    NOT NULL,
                enc_body    TEXT    NOT NULL DEFAULT '',
                created_at  INTEGER NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS idx_events_to ON offline_events (to_username)",
            # channels
            """CREATE TABLE IF NOT EXISTS channels (
                id          TEXT    PRIMARY KEY,
                name        TEXT    NOT NULL UNIQUE,
                tag         TEXT    NOT NULL UNIQUE DEFAULT '',
                description TEXT    NOT NULL DEFAULT '',
                type        TEXT    NOT NULL DEFAULT 'group',
                is_private  INTEGER NOT NULL DEFAULT 0,
                creator     TEXT    NOT NULL,
                created_at  INTEGER NOT NULL
            )""",
            "ALTER TABLE channels ADD COLUMN tag TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE channels ADD COLUMN is_private INTEGER NOT NULL DEFAULT 0",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_tag ON channels (tag)",
            """CREATE TABLE IF NOT EXISTS channel_keys (
                channel_id  TEXT NOT NULL,
                username    TEXT NOT NULL,
                wrapped_key TEXT NOT NULL,
                PRIMARY KEY (channel_id, username)
            )""",
            """CREATE TABLE IF NOT EXISTS channel_join_requests (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                channel_id  TEXT    NOT NULL,
                username    TEXT    NOT NULL,
                status      TEXT    NOT NULL DEFAULT 'pending',
                created_at  INTEGER NOT NULL,
                UNIQUE(channel_id, username)
            )""",
            """CREATE TABLE IF NOT EXISTS channel_members (
                channel_id  TEXT    NOT NULL,
                username    TEXT    NOT NULL,
                role        TEXT    NOT NULL DEFAULT 'member',
                joined_at   INTEGER NOT NULL,
                PRIMARY KEY (channel_id, username)
            )""",
            """CREATE TABLE IF NOT EXISTS channel_messages (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                channel_id    TEXT    NOT NULL,
                from_username TEXT    NOT NULL,
                display_name  TEXT    NOT NULL DEFAULT '',
                body          TEXT    NOT NULL,
                msg_id        TEXT    NOT NULL UNIQUE,
                sent_at       INTEGER NOT NULL,
                created_at    INTEGER NOT NULL
            )""",
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs ON channel_messages (channel_id, sent_at)",
        ]:
            try:
                _conn.execute(col_sql)
                _conn.commit()
            except Exception:
                pass  # already exists
        init_support_table()
        init_files_tables()
        # Migrate pending_files: add channel_id column
        try:
            _conn.execute("ALTER TABLE pending_files ADD COLUMN channel_id TEXT NOT NULL DEFAULT ''")
            _conn.commit()
        except Exception:
            pass
        # Migrate users: add screen_block column
        try:
            _conn.execute("ALTER TABLE users ADD COLUMN screen_block INTEGER NOT NULL DEFAULT 0")
            _conn.commit()
        except Exception:
            pass
    return _conn


# ── Users ─────────────────────────────────────────────────────────────────

def user_exists(username: str) -> bool:
    with _lock:
        return get_conn().execute(
            "SELECT 1 FROM users WHERE username = ?", (username,)
        ).fetchone() is not None


def create_user(username: str, display_name: str, argon2_hash: str,
                x25519_pub: str, ed25519_pub: str) -> int:
    with _lock:
        cur = get_conn().execute(
            "INSERT INTO users (username, display_name, argon2_hash, x25519_pub, ed25519_pub, created_at)"
            " VALUES (?,?,?,?,?,?)",
            (username, display_name, argon2_hash, x25519_pub, ed25519_pub, int(time.time())),
        )
        get_conn().commit()
        return cur.lastrowid


def get_user(username: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM users WHERE username = ?", (username,)
        ).fetchone()


def set_screen_block(username: str, enabled: bool) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE users SET screen_block = ? WHERE username = ?",
            (1 if enabled else 0, username),
        )
        get_conn().commit()


_ALLOWED_USER_COLS = {"display_name", "about", "x25519_pub", "ed25519_pub"}

def update_user(username: str, **kwargs):
    if not kwargs:
        return
    # Whitelist column names to prevent SQL injection
    bad = set(kwargs) - _ALLOWED_USER_COLS
    if bad:
        raise ValueError(f"update_user: disallowed columns: {bad}")
    with _lock:
        cols = ", ".join(f"{k} = ?" for k in kwargs)
        get_conn().execute(
            f"UPDATE users SET {cols} WHERE username = ?",
            (*kwargs.values(), username),
        )
        get_conn().commit()


# ── Offline messages ───────────────────────────────────────────────────────

def save_offline_message(from_username: str, to_username: str,
                          enc_body: str, msg_id: str, sent_at: int,
                          forwarded_from: str = '',
                          reply_to_msg_id: str = '') -> None:
    with _lock:
        try:
            get_conn().execute(
                "INSERT INTO messages (from_username, to_username, enc_body, msg_id, sent_at, created_at, forwarded_from, reply_to_msg_id)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (from_username, to_username, enc_body, msg_id, sent_at, int(time.time()), forwarded_from, reply_to_msg_id),
            )
            get_conn().commit()
        except sqlite3.IntegrityError:
            pass  # duplicate msg_id — ignore


def get_pending_messages(to_username: str) -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT id, from_username, to_username, enc_body, msg_id, sent_at, forwarded_from, reply_to_msg_id"
            " FROM messages WHERE to_username = ? AND delivered = 0 ORDER BY sent_at ASC",
            (to_username,),
        ).fetchall()


def mark_delivered(msg_id: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE messages SET delivered = 1 WHERE msg_id = ?", (msg_id,)
        )
        get_conn().execute(
            "UPDATE message_receipts SET delivered_at=? WHERE msg_id=? AND delivered_at=0",
            (int(time.time()), msg_id)
        )
        get_conn().commit()


# ── Message receipts (delivery/seen tracking) ──────────────────────────────

def record_msg_received(msg_id: str, from_user: str, to_user: str, sent_at: int) -> None:
    """Called when server receives relay_message from sender."""
    with _lock:
        try:
            get_conn().execute(
                "INSERT OR IGNORE INTO message_receipts (msg_id, from_user, to_user, sent_at)"
                " VALUES (?,?,?,?)",
                (msg_id, from_user, to_user, sent_at)
            )
            get_conn().commit()
        except Exception:
            pass


def record_msg_seen(msg_ids: list, from_user: str) -> None:
    """Called when relay_seen received — marks messages as seen."""
    now = int(time.time())
    with _lock:
        for mid in msg_ids:
            get_conn().execute(
                "UPDATE message_receipts SET seen_at=? WHERE msg_id=? AND to_user=? AND seen_at=0",
                (now, mid, from_user)
            )
        get_conn().commit()


def get_msg_statuses(msg_ids: list, owner: str) -> dict:
    """Return {msg_id: {received, delivered, seen}} for each requested id."""
    result = {}
    with _lock:
        conn = get_conn()
        for mid in msg_ids:
            row = conn.execute(
                "SELECT delivered_at, seen_at FROM message_receipts WHERE msg_id=? AND from_user=?",
                (mid, owner)
            ).fetchone()
            if row:
                result[mid] = {
                    "received":  True,
                    "delivered": row["delivered_at"] > 0,
                    "seen":      row["seen_at"] > 0,
                }
            else:
                # Check if it's still in offline queue
                q = conn.execute(
                    "SELECT id FROM messages WHERE msg_id=? AND delivered=0",
                    (mid,)
                ).fetchone()
                if q:
                    result[mid] = {"received": True, "delivered": False, "seen": False}
                else:
                    result[mid] = {"received": False, "delivered": False, "seen": False}
    return result


# ── Contacts ───────────────────────────────────────────────────────────────

def add_contact(user_a: str, user_b: str) -> None:
    """Add contact relationship in both directions."""
    with _lock:
        t = int(time.time())
        get_conn().execute(
            "INSERT OR IGNORE INTO contacts (user_a, user_b, created_at) VALUES (?,?,?)",
            (user_a, user_b, t),
        )
        get_conn().execute(
            "INSERT OR IGNORE INTO contacts (user_a, user_b, created_at) VALUES (?,?,?)",
            (user_b, user_a, t),
        )
        get_conn().commit()


def get_contacts(username: str) -> List[str]:
    with _lock:
        rows = get_conn().execute(
            "SELECT user_b FROM contacts WHERE user_a = ?", (username,)
        ).fetchall()
        return [r["user_b"] for r in rows]


def are_contacts(user_a: str, user_b: str) -> bool:
    """True if user_b is in user_a's contact list (symmetric rows are stored)."""
    with _lock:
        row = get_conn().execute(
            "SELECT 1 FROM contacts WHERE user_a=? AND user_b=?",
            (user_a, user_b),
        ).fetchone()
        return row is not None


def save_offline_event(to_username: str, event_type: str,
                        msg_id: str, enc_body: str = '') -> None:
    with _lock:
        get_conn().execute(
            "INSERT INTO offline_events (to_username, type, msg_id, enc_body, created_at)"
            " VALUES (?,?,?,?,?)",
            (to_username, event_type, msg_id, enc_body, int(time.time())),
        )
        get_conn().commit()


def get_pending_events(to_username: str) -> List[sqlite3.Row]:
    with _lock:
        rows = get_conn().execute(
            "SELECT id, type, msg_id, enc_body FROM offline_events"
            " WHERE to_username = ? ORDER BY id ASC",
            (to_username,),
        ).fetchall()
        return rows


def clear_pending_events(to_username: str) -> None:
    with _lock:
        get_conn().execute(
            "DELETE FROM offline_events WHERE to_username = ?", (to_username,)
        )
        get_conn().commit()


def cleanup_old_messages(days: int = 7) -> None:
    cutoff = int(time.time()) - days * 86400
    with _lock:
        get_conn().execute(
            "DELETE FROM messages WHERE created_at < ? OR delivered = 1", (cutoff,)
        )
        get_conn().execute(
            "DELETE FROM offline_events WHERE created_at < ?", (cutoff,)
        )
        get_conn().commit()


# ── Channels ───────────────────────────────────────────────────────────────

def create_channel(channel_id: str, name: str, tag: str, description: str,
                   channel_type: str, creator: str, is_private: bool = False) -> None:
    with _lock:
        get_conn().execute(
            "INSERT INTO channels (id, name, tag, description, type, is_private, creator, created_at)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (channel_id, name, tag, description, channel_type, int(is_private), creator, int(time.time())),
        )
        get_conn().execute(
            "INSERT INTO channel_members (channel_id, username, role, joined_at)"
            " VALUES (?,?,?,?)",
            (channel_id, creator, "admin", int(time.time())),
        )
        get_conn().commit()


def get_channel(channel_id: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM channels WHERE id = ?", (channel_id,)
        ).fetchone()


def update_channel(channel_id: str, **kwargs) -> None:
    allowed = {'name', 'description', 'is_private', 'tag'}
    bad = set(kwargs) - allowed
    if bad:
        raise ValueError(f"update_channel: disallowed: {bad}")
    if not kwargs:
        return
    with _lock:
        cols = ", ".join(f"{k} = ?" for k in kwargs)
        get_conn().execute(
            f"UPDATE channels SET {cols} WHERE id = ?",
            (*kwargs.values(), channel_id),
        )
        get_conn().commit()


# channel_keys ─────────────────────────────────────────────────────────────────

def set_channel_key(channel_id: str, username: str, wrapped_key: str) -> None:
    with _lock:
        get_conn().execute(
            "INSERT OR REPLACE INTO channel_keys (channel_id, username, wrapped_key)"
            " VALUES (?,?,?)",
            (channel_id, username, wrapped_key),
        )
        get_conn().commit()


def get_channel_key(channel_id: str, username: str) -> Optional[str]:
    with _lock:
        row = get_conn().execute(
            "SELECT wrapped_key FROM channel_keys WHERE channel_id = ? AND username = ?",
            (channel_id, username),
        ).fetchone()
        return row["wrapped_key"] if row else None


# join_requests ────────────────────────────────────────────────────────────────

def create_join_request(channel_id: str, username: str) -> None:
    with _lock:
        get_conn().execute(
            "INSERT OR IGNORE INTO channel_join_requests (channel_id, username, created_at)"
            " VALUES (?,?,?)",
            (channel_id, username, int(time.time())),
        )
        get_conn().commit()


def get_join_requests(channel_id: str, status: str = 'pending') -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT r.*, u.display_name FROM channel_join_requests r"
            " LEFT JOIN users u ON u.username = r.username"
            " WHERE r.channel_id = ? AND r.status = ? ORDER BY r.created_at ASC",
            (channel_id, status),
        ).fetchall()


def get_join_request(channel_id: str, username: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM channel_join_requests WHERE channel_id = ? AND username = ?",
            (channel_id, username),
        ).fetchone()


def update_join_request(channel_id: str, username: str, status: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE channel_join_requests SET status = ? WHERE channel_id = ? AND username = ?",
            (status, channel_id, username),
        )
        get_conn().commit()


def delete_channel_message(channel_id: str, msg_id: str) -> bool:
    with _lock:
        cur = get_conn().execute(
            "DELETE FROM channel_messages WHERE channel_id = ? AND msg_id = ?",
            (channel_id, msg_id),
        )
        get_conn().commit()
        return cur.rowcount > 0


def get_all_channels(query: str = '') -> List[sqlite3.Row]:
    with _lock:
        if query:
            q_like = f'%{query.lower()}%'
            q_exact = query.lower().lstrip('@')
            # Public channels: fuzzy match; private channels: exact tag only
            return get_conn().execute(
                "SELECT c.*, (SELECT COUNT(*) FROM channel_members m WHERE m.channel_id = c.id)"
                " AS member_count FROM channels c"
                " WHERE (c.is_private = 0 AND (lower(c.name) LIKE ? OR lower(c.tag) LIKE ? OR lower(c.description) LIKE ?))"
                "    OR (c.is_private = 1 AND lower(c.tag) = ?)"
                " ORDER BY c.created_at DESC",
                (q_like, q_like, q_like, q_exact),
            ).fetchall()
        # No query: return only public channels
        return get_conn().execute(
            "SELECT c.*, (SELECT COUNT(*) FROM channel_members m WHERE m.channel_id = c.id)"
            " AS member_count FROM channels c WHERE c.is_private = 0 ORDER BY c.created_at DESC"
        ).fetchall()


def get_user_channels(username: str) -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT c.*, cm.role,"
            " (SELECT COUNT(*) FROM channel_members m WHERE m.channel_id = c.id) AS member_count"
            " FROM channels c JOIN channel_members cm ON c.id = cm.channel_id"
            " WHERE cm.username = ? ORDER BY c.created_at DESC",
            (username,),
        ).fetchall()


def get_channel_member(channel_id: str, username: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM channel_members WHERE channel_id = ? AND username = ?",
            (channel_id, username),
        ).fetchone()


def get_channel_members(channel_id: str) -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT cm.username, cm.role, u.display_name FROM channel_members cm"
            " LEFT JOIN users u ON u.username = cm.username"
            " WHERE cm.channel_id = ? ORDER BY cm.role DESC, cm.joined_at ASC",
            (channel_id,),
        ).fetchall()


def get_channel_member_count(channel_id: str) -> int:
    with _lock:
        row = get_conn().execute(
            "SELECT COUNT(*) AS cnt FROM channel_members WHERE channel_id = ?",
            (channel_id,),
        ).fetchone()
        return row["cnt"] if row else 0


def add_channel_member(channel_id: str, username: str, role: str = "member") -> None:
    with _lock:
        get_conn().execute(
            "INSERT OR IGNORE INTO channel_members (channel_id, username, role, joined_at)"
            " VALUES (?,?,?,?)",
            (channel_id, username, role, int(time.time())),
        )
        get_conn().commit()


def remove_channel_member(channel_id: str, username: str) -> None:
    with _lock:
        get_conn().execute(
            "DELETE FROM channel_members WHERE channel_id = ? AND username = ?",
            (channel_id, username),
        )
        get_conn().commit()


def delete_channel(channel_id: str) -> None:
    with _lock:
        get_conn().execute("DELETE FROM channel_messages WHERE channel_id = ?", (channel_id,))
        get_conn().execute("DELETE FROM channel_members WHERE channel_id = ?", (channel_id,))
        get_conn().execute("DELETE FROM channels WHERE id = ?", (channel_id,))
        get_conn().commit()


def save_channel_message(channel_id: str, from_username: str, display_name: str,
                         body: str, msg_id: str, sent_at: int) -> None:
    with _lock:
        try:
            get_conn().execute(
                "INSERT INTO channel_messages"
                " (channel_id, from_username, display_name, body, msg_id, sent_at, created_at)"
                " VALUES (?,?,?,?,?,?,?)",
                (channel_id, from_username, display_name, body, msg_id, sent_at, int(time.time())),
            )
            get_conn().commit()
        except sqlite3.IntegrityError:
            pass  # duplicate msg_id


def get_channel_messages(channel_id: str, limit: int = 50,
                          before_id: int = 0) -> List[sqlite3.Row]:
    with _lock:
        if before_id > 0:
            return get_conn().execute(
                "SELECT id, from_username, display_name, body, msg_id, sent_at"
                " FROM channel_messages WHERE channel_id = ? AND id < ?"
                " ORDER BY sent_at DESC LIMIT ?",
                (channel_id, before_id, limit),
            ).fetchall()[::-1]
        return get_conn().execute(
            "SELECT id, from_username, display_name, body, msg_id, sent_at"
            " FROM channel_messages WHERE channel_id = ?"
            " ORDER BY sent_at DESC LIMIT ?",
            (channel_id, limit),
        ).fetchall()[::-1]


def cleanup_channel_messages(days: int = 1) -> None:
    cutoff = int(time.time()) - days * 86400
    with _lock:
        get_conn().execute(
            "DELETE FROM channel_messages WHERE created_at < ?", (cutoff,)
        )
        get_conn().commit()


# ── Support messages ────────────────────────────────────────────────────────────

def init_support_table() -> None:
    with _lock:
        get_conn().executescript("""
        CREATE TABLE IF NOT EXISTS support_messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            from_username   TEXT    NOT NULL,
            to_username     TEXT    NOT NULL DEFAULT '',
            body            TEXT    NOT NULL,
            msg_id          TEXT    NOT NULL UNIQUE,
            sent_at         INTEGER NOT NULL,
            reply_to_msg_id TEXT    NOT NULL DEFAULT '',
            direction       TEXT    NOT NULL DEFAULT 'in',
            created_at      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_support_from ON support_messages (from_username);
        """)
        get_conn().commit()


def save_support_message(from_username: str, body: str, msg_id: str, sent_at: int,
                          to_username: str = '', reply_to_msg_id: str = '',
                          direction: str = 'in') -> None:
    with _lock:
        try:
            get_conn().execute(
                "INSERT INTO support_messages"
                " (from_username, to_username, body, msg_id, sent_at, reply_to_msg_id, direction, created_at)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (from_username, to_username, body, msg_id, sent_at,
                 reply_to_msg_id, direction, int(time.time())),
            )
            get_conn().commit()
        except Exception:
            pass


def get_support_messages_for_user(username: str, limit: int = 50) -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM support_messages"
            " WHERE (direction = 'in' AND from_username = ?)"
            "    OR (direction = 'out' AND to_username = ?)"
            "    OR (direction = 'out' AND to_username = 'all')"
            " ORDER BY sent_at DESC LIMIT ?",
            (username, username, limit),
        ).fetchall()[::-1]


def get_all_support_messages(limit: int = 100) -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM support_messages ORDER BY sent_at DESC LIMIT ?",
            (limit,),
        ).fetchall()[::-1]


def get_support_message_by_id(msg_id: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM support_messages WHERE msg_id = ?", (msg_id,)
        ).fetchone()


# ── Pending files (30-min relay) ───────────────────────────────────────────────

def init_files_tables() -> None:
    with _lock:
        get_conn().executescript("""
        CREATE TABLE IF NOT EXISTS pending_files (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id       TEXT    NOT NULL UNIQUE,
            from_username TEXT    NOT NULL,
            to_username   TEXT    NOT NULL,
            filename      TEXT    NOT NULL,
            mime_type     TEXT    NOT NULL DEFAULT '',
            file_size     INTEGER NOT NULL DEFAULT 0,
            file_path     TEXT    NOT NULL,
            enc_key       TEXT    NOT NULL DEFAULT '',
            msg_id        TEXT    NOT NULL,
            status        TEXT    NOT NULL DEFAULT 'uploaded',
            sha256        TEXT    NOT NULL DEFAULT '',
            created_at    INTEGER NOT NULL,
            expires_at    INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS file_requests (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id       TEXT    NOT NULL,
            from_username TEXT    NOT NULL,
            to_username   TEXT    NOT NULL,
            filename      TEXT    NOT NULL,
            msg_id        TEXT    NOT NULL,
            status        TEXT    NOT NULL DEFAULT 'pending',
            created_at    INTEGER NOT NULL
        );
        """)
        get_conn().commit()


def save_pending_file(file_id: str, from_username: str, to_username: str,
                       filename: str, mime_type: str, file_size: int,
                       file_path: str, enc_key: str, msg_id: str,
                       sha256: str, expires_at: int,
                       channel_id: str = '') -> None:
    with _lock:
        get_conn().execute(
            "INSERT OR IGNORE INTO pending_files"
            " (file_id, from_username, to_username, filename, mime_type, file_size,"
            "  file_path, enc_key, msg_id, sha256, created_at, expires_at, channel_id)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (file_id, from_username, to_username, filename, mime_type, file_size,
             file_path, enc_key, msg_id, sha256, int(time.time()), expires_at, channel_id),
        )
        get_conn().commit()


def get_pending_file(file_id: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM pending_files WHERE file_id = ?", (file_id,)
        ).fetchone()


def get_pending_files_to_deliver() -> List[sqlite3.Row]:
    """Files uploaded but not yet notified to recipient."""
    with _lock:
        return get_conn().execute(
            "SELECT * FROM pending_files WHERE status = 'uploaded' ORDER BY created_at ASC"
        ).fetchall()


def get_expired_files(now: int) -> List[sqlite3.Row]:
    """Files past their expiry that haven't been acked."""
    with _lock:
        return get_conn().execute(
            "SELECT * FROM pending_files WHERE expires_at < ? AND status != 'acked'",
            (now,),
        ).fetchall()


def update_pending_file_status(file_id: str, status: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE pending_files SET status = ? WHERE file_id = ?", (status, file_id)
        )
        get_conn().commit()


def delete_pending_file(file_id: str) -> None:
    with _lock:
        get_conn().execute(
            "DELETE FROM pending_files WHERE file_id = ?", (file_id,)
        )
        get_conn().commit()


# ── File re-request ────────────────────────────────────────────────────────────

def save_file_request(file_id: str, from_username: str, to_username: str,
                       filename: str, msg_id: str) -> None:
    with _lock:
        get_conn().execute(
            "INSERT INTO file_requests"
            " (file_id, from_username, to_username, filename, msg_id, created_at)"
            " VALUES (?,?,?,?,?,?)",
            (file_id, from_username, to_username, filename, msg_id, int(time.time())),
        )
        get_conn().commit()


def get_pending_file_requests() -> List[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM file_requests WHERE status = 'pending' ORDER BY created_at ASC"
        ).fetchall()


def mark_file_request_sent(req_id: int) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE file_requests SET status = 'sent' WHERE id = ?", (req_id,)
        )
        get_conn().commit()


def delete_file_request(req_id: int) -> None:
    with _lock:
        get_conn().execute("DELETE FROM file_requests WHERE id = ?", (req_id,))
        get_conn().commit()


def cleanup_old_files() -> None:
    """Remove file_requests older than 7 days."""
    cutoff = int(time.time()) - 7 * 86400
    with _lock:
        get_conn().execute("DELETE FROM file_requests WHERE created_at < ?", (cutoff,))
        get_conn().commit()


# ── Device registry & login approval ─────────────────────────────────────────

# ── Device registry & pending logins ─────────────────────────────────────────
#
# Phases for pending_logins.phase:
#   pending       – waiting for existing devices to respond
#   code_phase    – approved; new device must generate a code
#   verify_phase  – approving device submitted a code; new device must verify
#   success       – code matched; new device can collect token
#   denied        – denied or timed out
#   blocked       – device_id permanently blocked

def init_device_tables() -> None:
    with _lock:
        conn = get_conn()
        conn.executescript("""
        CREATE TABLE IF NOT EXISTS device_registry (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            username      TEXT    NOT NULL,
            device_id     TEXT    NOT NULL,
            device_name   TEXT    NOT NULL DEFAULT '',
            registered_at INTEGER NOT NULL DEFAULT 0,
            blocked       INTEGER NOT NULL DEFAULT 0,
            UNIQUE(username, device_id)
        );
        CREATE TABLE IF NOT EXISTS pending_logins (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id      TEXT    NOT NULL UNIQUE,
            username        TEXT    NOT NULL,
            device_id       TEXT    NOT NULL,
            device_name     TEXT    NOT NULL DEFAULT '',
            client_ip       TEXT    NOT NULL DEFAULT '',
            phase           TEXT    NOT NULL DEFAULT 'pending',
            submitted_code  TEXT    NOT NULL DEFAULT '',
            attempt_count   INTEGER NOT NULL DEFAULT 0,
            notified_at     INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL DEFAULT 0,
            expires_at      INTEGER NOT NULL DEFAULT 0
        );
        """)
        # Migrate old device_registry: add missing columns
        for col, defn in [
            ("blocked",      "INTEGER NOT NULL DEFAULT 0"),
            ("trust_type",   "TEXT    NOT NULL DEFAULT 'guest'"),
            ("trust_level",  "INTEGER NOT NULL DEFAULT 0"),
            ("permissions",  "TEXT    NOT NULL DEFAULT '{}'"),
        ]:
            try:
                conn.execute(f"ALTER TABLE device_registry ADD COLUMN {col} {defn}")
            except Exception:
                pass
        conn.commit()
        # Migrate old pending_logins: add new columns if missing
        for col, defn in [
            ("phase",          "TEXT    NOT NULL DEFAULT 'pending'"),
            ("submitted_code", "TEXT    NOT NULL DEFAULT ''"),
            ("attempt_count",  "INTEGER NOT NULL DEFAULT 0"),
            ("notified_at",    "INTEGER NOT NULL DEFAULT 0"),
        ]:
            try:
                conn.execute(f"ALTER TABLE pending_logins ADD COLUMN {col} {defn}")
            except Exception:
                pass
        conn.commit()


def is_device_registered(username: str, device_id: str) -> bool:
    with _lock:
        row = get_conn().execute(
            "SELECT id FROM device_registry WHERE username=? AND device_id=?",
            (username, device_id)
        ).fetchone()
        return row is not None


def is_device_blocked(username: str, device_id: str) -> bool:
    with _lock:
        row = get_conn().execute(
            "SELECT blocked FROM device_registry WHERE username=? AND device_id=?",
            (username, device_id)
        ).fetchone()
        return bool(row["blocked"]) if row else False


def register_device(username: str, device_id: str, device_name: str,
                    trust_type: str = 'guest') -> None:
    with _lock:
        get_conn().execute(
            "INSERT OR IGNORE INTO device_registry"
            " (username, device_id, device_name, trust_type, registered_at)"
            " VALUES (?,?,?,?,?)",
            (username, device_id, device_name, trust_type, int(time.time()))
        )
        get_conn().commit()


# ── Trust / permissions ────────────────────────────────────────────────────

_ALL_PERMISSIONS = [
    # group permissions
    "messaging", "files", "contacts", "chats", "devices", "profile", "security",
    # messaging
    "msg_read", "msg_send", "msg_edit", "msg_delete_own", "msg_delete_any", "msg_forward",
    # files
    "file_send", "file_receive", "file_download",
    # contacts
    "contacts_view", "contacts_add", "contacts_remove", "contacts_block",
    # chats
    "chats_create", "chats_delete", "chats_clear", "chats_view_history",
    # devices
    "devices_view", "devices_approve", "devices_deny", "devices_block",
    "devices_revoke", "devices_manage_trust", "devices_manage_perms",
    # profile
    "profile_change_name", "profile_change_avatar", "profile_change_password", "profile_delete",
    # security
    "security_view_log", "security_manage_blocked",
]

_CREATOR_PERMISSIONS = {p: True for p in _ALL_PERMISSIONS}
_GUEST_PERMISSIONS   = {p: False for p in _ALL_PERMISSIONS}


def get_device_trust(username: str, device_id: str) -> Optional[dict]:
    with _lock:
        row = get_conn().execute(
            "SELECT trust_type, trust_level, permissions FROM device_registry"
            " WHERE username=? AND device_id=? AND blocked=0",
            (username, device_id)
        ).fetchone()
        if not row:
            return None
        try:
            perms = json.loads(row["permissions"])
        except Exception:
            perms = {}
        return {
            "trust_type":  row["trust_type"],
            "trust_level": row["trust_level"],
            "permissions": perms,
        }


def set_device_trust(username: str, device_id: str,
                     trust_type: str = None, trust_level: int = None,
                     permissions: dict = None) -> bool:
    """Update trust info for a device. Returns False if device not found."""
    with _lock:
        row = get_conn().execute(
            "SELECT trust_type FROM device_registry WHERE username=? AND device_id=? AND blocked=0",
            (username, device_id)
        ).fetchone()
        if not row or row["trust_type"] == "creator":
            return False  # can't modify creator or non-existent
        updates, vals = [], []
        if trust_type is not None:
            updates.append("trust_type=?"); vals.append(trust_type)
        if trust_level is not None:
            updates.append("trust_level=?"); vals.append(trust_level)
        if permissions is not None:
            updates.append("permissions=?"); vals.append(json.dumps(permissions))
        if not updates:
            return True
        vals += [username, device_id]
        get_conn().execute(
            f"UPDATE device_registry SET {', '.join(updates)} WHERE username=? AND device_id=?",
            vals
        )
        get_conn().commit()
        return True


def get_all_devices(username: str) -> list:
    """Return all non-blocked devices with trust info."""
    import json as _json
    with _lock:
        rows = get_conn().execute(
            "SELECT device_id, device_name, trust_type, trust_level, permissions, registered_at"
            " FROM device_registry WHERE username=? AND blocked=0 ORDER BY registered_at ASC",
            (username,)
        ).fetchall()
        result = []
        for r in rows:
            try:
                perms = _json.loads(r["permissions"])
            except Exception:
                perms = {}
            result.append({
                "device_id":    r["device_id"],
                "device_name":  r["device_name"],
                "trust_type":   r["trust_type"],
                "trust_level":  r["trust_level"],
                "permissions":  perms,
                "registered_at": r["registered_at"],
            })
        return result


def block_device(username: str, device_id: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE device_registry SET blocked=1 WHERE username=? AND device_id=?",
            (username, device_id)
        )
        # Also insert a blocked record if device was never registered
        get_conn().execute(
            "INSERT OR IGNORE INTO device_registry (username, device_id, blocked, registered_at) VALUES (?,?,1,?)",
            (username, device_id, int(time.time()))
        )
        get_conn().commit()


def get_user_devices(username: str) -> list:
    """Return all registered (non-blocked) device_ids for a user."""
    with _lock:
        return list(get_conn().execute(
            "SELECT device_id, device_name FROM device_registry WHERE username=? AND blocked=0",
            (username,)
        ).fetchall())


def get_user_device_count(username: str) -> int:
    with _lock:
        row = get_conn().execute(
            "SELECT COUNT(*) as cnt FROM device_registry WHERE username=? AND blocked=0", (username,)
        ).fetchone()
        return row["cnt"] if row else 0


def cancel_pending_for_device(username: str, device_id: str) -> None:
    """Remove active pending logins for this user+device before creating a new one."""
    with _lock:
        get_conn().execute(
            "DELETE FROM pending_logins WHERE username=? AND device_id=? AND phase IN ('pending','code_phase','verify_phase')",
            (username, device_id)
        )
        get_conn().commit()


def create_pending_login(request_id: str, username: str, device_id: str,
                          device_name: str, client_ip: str) -> None:
    now = int(time.time())
    with _lock:
        get_conn().execute(
            """INSERT OR REPLACE INTO pending_logins
               (request_id, username, device_id, device_name, client_ip,
                phase, submitted_code, attempt_count, notified_at, created_at, expires_at)
               VALUES (?,?,?,?,?, 'pending','',0,0,?,?)""",
            (request_id, username, device_id, device_name, client_ip, now, now + 600)
        )
        get_conn().commit()


def get_pending_login(request_id: str) -> Optional[sqlite3.Row]:
    with _lock:
        return get_conn().execute(
            "SELECT * FROM pending_logins WHERE request_id=?", (request_id,)
        ).fetchone()


def get_my_pending_logins(username: str):
    """Return all active pending logins for a user (for approving device polling)."""
    with _lock:
        return get_conn().execute(
            "SELECT * FROM pending_logins WHERE username=? AND phase NOT IN ('denied','blocked','success') ORDER BY created_at DESC",
            (username,)
        ).fetchall()


def set_pending_notified(request_id: str) -> None:
    """Mark timer start — called when first device receives the request."""
    now = int(time.time())
    with _lock:
        get_conn().execute(
            "UPDATE pending_logins SET notified_at=?, expires_at=? WHERE request_id=? AND notified_at=0",
            (now, now + 600, request_id)
        )
        get_conn().commit()


def set_pending_phase(request_id: str, phase: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE pending_logins SET phase=? WHERE request_id=?",
            (phase, request_id)
        )
        get_conn().commit()


def set_submitted_code(request_id: str, code: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE pending_logins SET submitted_code=?, phase='verify_phase' WHERE request_id=?",
            (code, request_id)
        )
        get_conn().commit()


def increment_attempt(request_id: str) -> int:
    """Increment attempt_count, return new count."""
    with _lock:
        get_conn().execute(
            "UPDATE pending_logins SET attempt_count=attempt_count+1 WHERE request_id=?",
            (request_id,)
        )
        get_conn().commit()
        row = get_conn().execute(
            "SELECT attempt_count FROM pending_logins WHERE request_id=?", (request_id,)
        ).fetchone()
        return row["attempt_count"] if row else 0


def deny_pending_login(request_id: str) -> None:
    with _lock:
        get_conn().execute(
            "UPDATE pending_logins SET phase='denied' WHERE request_id=?",
            (request_id,)
        )
        get_conn().commit()


def delete_pending_login(request_id: str) -> None:
    with _lock:
        get_conn().execute("DELETE FROM pending_logins WHERE request_id=?", (request_id,))
        get_conn().commit()


def cleanup_expired_logins() -> None:
    now = int(time.time())
    with _lock:
        get_conn().execute("DELETE FROM pending_logins WHERE expires_at > 0 AND expires_at < ?", (now,))
        get_conn().commit()
