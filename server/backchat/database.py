"""
GhostChat — слой базы данных.

Единая асинхронная SQLite БД (aiosqlite + WAL mode).
Объединяет: пользователей, сообщения, каналы, файлы, реакции, premium/shop.

Политика метаданных:
- IP адреса НЕ хранятся нигде.
- Офлайн-сообщения удаляются сразу после доставки.
- Логи маршрутизации — только в памяти процесса.
"""
from __future__ import annotations

import asyncio
import time
import os
from contextlib import asynccontextmanager
from typing import Any, Optional

import aiosqlite

import config

# Единственный путь к БД
_DB_PATH = config.DB_PATH

# ── Инициализация ─────────────────────────────────────────────────────────────

async def _configure(db: aiosqlite.Connection):
    """Настройки SQLite для максимальной производительности и надёжности."""
    await db.execute("PRAGMA journal_mode = WAL")       # лучший concurrent read
    await db.execute("PRAGMA synchronous   = NORMAL")   # баланс скорость/надёжность
    await db.execute("PRAGMA foreign_keys  = ON")
    await db.execute("PRAGMA cache_size    = -65536")   # 64 MB кэш
    await db.execute("PRAGMA temp_store    = MEMORY")
    await db.execute("PRAGMA mmap_size     = 134217728") # 128 MB mmap
    db.row_factory = aiosqlite.Row

@asynccontextmanager
async def get_db():
    """Контекстный менеджер для получения соединения с БД."""
    os.makedirs(os.path.dirname(_DB_PATH), exist_ok=True)
    async with aiosqlite.connect(_DB_PATH) as db:
        await _configure(db)
        yield db

# ── Миграции ──────────────────────────────────────────────────────────────────

async def migrate():
    """Создаёт/обновляет схему БД. Вызывать при старте сервера."""
    async with get_db() as db:
        await _create_schema(db)
        await _run_migrations(db)
        await db.commit()

async def _create_schema(db: aiosqlite.Connection):
    # ── Пользователи ─────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            username        TEXT    NOT NULL UNIQUE,
            display_name    TEXT    NOT NULL DEFAULT '',
            about           TEXT    NOT NULL DEFAULT '',
            argon2_hash     TEXT    NOT NULL DEFAULT '',
            x25519_pub      TEXT    NOT NULL DEFAULT '',
            ed25519_pub     TEXT    NOT NULL DEFAULT '',
            screen_block    INTEGER NOT NULL DEFAULT 0,
            is_premium      INTEGER NOT NULL DEFAULT 0,
            glow_color      TEXT    NOT NULL DEFAULT '',
            avatar_bg_color TEXT    NOT NULL DEFAULT '',
            pinned_channel_tag TEXT NOT NULL DEFAULT '',
            ghost_score     INTEGER NOT NULL DEFAULT 0,
            token_min_iat   INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL
        )
    """)

    # ── Устройства ────────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS device_registry (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            username     TEXT    NOT NULL,
            device_id    TEXT    NOT NULL,
            device_name  TEXT    NOT NULL DEFAULT '',
            registered_at INTEGER NOT NULL,
            blocked      INTEGER NOT NULL DEFAULT 0,
            trust_type   TEXT    NOT NULL DEFAULT 'numeric',
            trust_level  INTEGER NOT NULL DEFAULT 0,
            permissions  TEXT    NOT NULL DEFAULT '{}',
            UNIQUE (username, device_id)
        )
    """)

    # ── Ожидающие логины (multi-device) ──────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS pending_logins (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id    TEXT    NOT NULL UNIQUE,
            username      TEXT    NOT NULL,
            device_id     TEXT    NOT NULL,
            device_name   TEXT    NOT NULL DEFAULT '',
            phase         TEXT    NOT NULL DEFAULT 'pending',
            submitted_code TEXT   NOT NULL DEFAULT '',
            attempt_count INTEGER NOT NULL DEFAULT 0,
            notified_at   INTEGER NOT NULL DEFAULT 0,
            created_at    INTEGER NOT NULL,
            expires_at    INTEGER NOT NULL
        )
    """)

    # ── Контакты ─────────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS contacts (
            user_a     TEXT NOT NULL,
            user_b     TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (user_a, user_b)
        )
    """)

    # ── Офлайн-сообщения (удаляются сразу после доставки) ────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            from_username  TEXT    NOT NULL,
            to_username    TEXT    NOT NULL,
            enc_body       TEXT    NOT NULL,
            msg_id         TEXT    NOT NULL UNIQUE,
            sent_at        INTEGER NOT NULL,
            delivered      INTEGER NOT NULL DEFAULT 0,
            forwarded_from TEXT    NOT NULL DEFAULT '',
            reply_to_msg_id TEXT   NOT NULL DEFAULT ''
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_msgs_to ON messages (to_username, delivered)"
    )

    # ── Доставка и прочтение ──────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS message_receipts (
            msg_id       TEXT    PRIMARY KEY,
            from_user    TEXT    NOT NULL,
            to_user      TEXT    NOT NULL,
            sent_at      INTEGER NOT NULL,
            delivered_at INTEGER NOT NULL DEFAULT 0,
            seen_at      INTEGER NOT NULL DEFAULT 0
        )
    """)

    # ── Офлайн-события (удалить/редактировать для офлайн-юзера) ──────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS offline_events (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            to_username  TEXT    NOT NULL,
            type         TEXT    NOT NULL,
            msg_id       TEXT    NOT NULL,
            enc_body     TEXT    NOT NULL DEFAULT '',
            created_at   INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_events_to ON offline_events (to_username)"
    )

    # ── Каналы / группы ──────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS channels (
            id          TEXT    PRIMARY KEY,
            name        TEXT    NOT NULL UNIQUE,
            tag         TEXT    NOT NULL UNIQUE,
            description TEXT    NOT NULL DEFAULT '',
            type        TEXT    NOT NULL DEFAULT 'group',
            is_private  INTEGER NOT NULL DEFAULT 0,
            creator     TEXT    NOT NULL,
            created_at  INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_channels_tag ON channels (tag)"
    )

    await db.execute("""
        CREATE TABLE IF NOT EXISTS channel_members (
            channel_id TEXT NOT NULL,
            username   TEXT NOT NULL,
            role       TEXT NOT NULL DEFAULT 'member',
            joined_at  INTEGER NOT NULL,
            PRIMARY KEY (channel_id, username)
        )
    """)

    await db.execute("""
        CREATE TABLE IF NOT EXISTS channel_messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            channel_id      TEXT    NOT NULL,
            from_username   TEXT    NOT NULL,
            display_name    TEXT    NOT NULL DEFAULT '',
            body            TEXT    NOT NULL DEFAULT '',
            msg_id          TEXT    NOT NULL UNIQUE,
            sent_at         INTEGER NOT NULL,
            deleted         INTEGER NOT NULL DEFAULT 0,
            reply_to_msg_id TEXT    NOT NULL DEFAULT '',
            reply_body      TEXT    NOT NULL DEFAULT '',
            reply_from      TEXT    NOT NULL DEFAULT ''
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_chmsg ON channel_messages (channel_id, sent_at)"
    )

    await db.execute("""
        CREATE TABLE IF NOT EXISTS channel_keys (
            channel_id  TEXT NOT NULL,
            username    TEXT NOT NULL,
            wrapped_key TEXT NOT NULL,
            PRIMARY KEY (channel_id, username)
        )
    """)

    await db.execute("""
        CREATE TABLE IF NOT EXISTS channel_join_requests (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            channel_id TEXT    NOT NULL,
            username   TEXT    NOT NULL,
            status     TEXT    NOT NULL DEFAULT 'pending',
            created_at INTEGER NOT NULL,
            UNIQUE (channel_id, username)
        )
    """)

    # ── Реакции ───────────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS reactions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            msg_id     TEXT    NOT NULL,
            username   TEXT    NOT NULL,
            emoji      TEXT    NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE (msg_id, username, emoji)
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_reactions_msg ON reactions (msg_id)"
    )

    # ── Файлы (временные, удаляются после доставки) ───────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS pending_files (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id      TEXT    NOT NULL UNIQUE,
            from_username TEXT   NOT NULL,
            to_username  TEXT    NOT NULL DEFAULT '',
            channel_id   TEXT    NOT NULL DEFAULT '',
            filename     TEXT    NOT NULL DEFAULT '',
            mime_type    TEXT    NOT NULL DEFAULT '',
            file_size    INTEGER NOT NULL DEFAULT 0,
            file_path    TEXT    NOT NULL,
            enc_key      TEXT    NOT NULL DEFAULT '',
            msg_id       TEXT    NOT NULL DEFAULT '',
            sha256       TEXT    NOT NULL DEFAULT '',
            status       TEXT    NOT NULL DEFAULT 'uploaded',
            created_at   INTEGER NOT NULL,
            expires_at   INTEGER NOT NULL
        )
    """)

    await db.execute("""
        CREATE TABLE IF NOT EXISTS file_requests (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id      TEXT    NOT NULL,
            from_username TEXT   NOT NULL,
            to_username  TEXT    NOT NULL,
            filename     TEXT    NOT NULL DEFAULT '',
            msg_id       TEXT    NOT NULL DEFAULT '',
            status       TEXT    NOT NULL DEFAULT 'pending',
            created_at   INTEGER NOT NULL
        )
    """)

    # ── Поддержка ─────────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS support_messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            from_username   TEXT    NOT NULL,
            to_username     TEXT    NOT NULL DEFAULT 'support',
            body            TEXT    NOT NULL,
            msg_id          TEXT    NOT NULL UNIQUE,
            sent_at         INTEGER NOT NULL,
            reply_to_msg_id TEXT    NOT NULL DEFAULT '',
            direction       TEXT    NOT NULL DEFAULT 'in',
            created_at      INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_support ON support_messages (from_username)"
    )

    # ── Premium / Shop ────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS shop_tickets (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_id      TEXT    NOT NULL UNIQUE,
            gc_username    TEXT    NOT NULL,
            status         TEXT    NOT NULL DEFAULT 'open',
            payment_method TEXT    NOT NULL DEFAULT '',
            amount_rub     INTEGER NOT NULL DEFAULT 0,
            created_at     INTEGER NOT NULL,
            updated_at     INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_tickets_user ON shop_tickets (gc_username)"
    )
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_tickets_status ON shop_tickets (status)"
    )

    await db.execute("""
        CREATE TABLE IF NOT EXISTS shop_ticket_messages (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_id TEXT    NOT NULL,
            sender    TEXT    NOT NULL,
            body      TEXT    NOT NULL,
            sent_at   INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_tmsg ON shop_ticket_messages (ticket_id, sent_at)"
    )

    await db.execute("""
        CREATE TABLE IF NOT EXISTS shop_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL DEFAULT ''
        )
    """)

    # ── Статистика сайта (без хранения IP!) ──────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS site_visitors (
            visitor_id         TEXT    PRIMARY KEY,
            first_seen_at      INTEGER NOT NULL,
            downloaded_at      INTEGER NOT NULL DEFAULT 0,
            downloaded_version TEXT    NOT NULL DEFAULT '',
            is_update          INTEGER NOT NULL DEFAULT 0,
            skipped            INTEGER NOT NULL DEFAULT 0
        )
    """)

    await db.execute("""
        CREATE TABLE IF NOT EXISTS site_login_log (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            gc_username  TEXT    NOT NULL,
            logged_in_at INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_loginlog ON site_login_log (gc_username)"
    )

    # ── Отозванные JWT (logout / компрометация) ──────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS revoked_tokens (
            jti        TEXT    PRIMARY KEY,
            username   TEXT    NOT NULL,
            revoked_at INTEGER NOT NULL
        )
    """)
    await db.execute(
        "CREATE INDEX IF NOT EXISTS idx_revoked_at ON revoked_tokens (revoked_at)"
    )

    # ── Версия схемы ──────────────────────────────────────────────────────────
    await db.execute("""
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY
        )
    """)


async def _get_schema_version(db: aiosqlite.Connection) -> int:
    row = await db.execute_fetchall("SELECT MAX(version) FROM schema_version")
    v = row[0][0] if row else None
    return v or 0


async def _set_schema_version(db: aiosqlite.Connection, v: int):
    await db.execute(
        "INSERT OR REPLACE INTO schema_version (version) VALUES (?)", (v,)
    )


async def _run_migrations(db: aiosqlite.Connection):
    v = await _get_schema_version(db)

    if v < 1:
        # Добавить поля если уже есть старая БД
        for stmt in [
            "ALTER TABLE users ADD COLUMN is_premium      INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE users ADD COLUMN glow_color      TEXT    NOT NULL DEFAULT ''",
            "ALTER TABLE users ADD COLUMN avatar_bg_color TEXT    NOT NULL DEFAULT ''",
            "ALTER TABLE users ADD COLUMN pinned_channel_tag TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE users ADD COLUMN ghost_score     INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE channel_messages ADD COLUMN deleted  INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE channel_messages ADD COLUMN reply_to_msg_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE channel_messages ADD COLUMN reply_body TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE channel_messages ADD COLUMN reply_from TEXT NOT NULL DEFAULT ''",
        ]:
            try:
                await db.execute(stmt)
            except Exception:
                pass  # Колонка уже существует
        await _set_schema_version(db, 1)

    if v < 2:
        for stmt in [
            "ALTER TABLE users ADD COLUMN token_min_iat INTEGER NOT NULL DEFAULT 0",
        ]:
            try:
                await db.execute(stmt)
            except Exception:
                pass
        # Security hardening: reply_body/reply_from больше не хранятся
        # Обнуляем старые данные чтобы не утекали plaintext цитаты
        for stmt in [
            "UPDATE channel_messages SET reply_body = '', reply_from = ''",
        ]:
            try:
                await db.execute(stmt)
            except Exception:
                pass
        await _set_schema_version(db, 2)

    if v < 3:
        # SECURITY (C2/C3): серверный хэш 6-значного кода подтверждения устройства.
        for stmt in [
            "ALTER TABLE pending_logins ADD COLUMN code_hash TEXT NOT NULL DEFAULT ''",
        ]:
            try:
                await db.execute(stmt)
            except Exception:
                pass
        await _set_schema_version(db, 3)

# ── Вспомогательные функции ───────────────────────────────────────────────────

async def fetchone(sql: str, params: tuple = ()) -> Optional[dict]:
    async with get_db() as db:
        cur = await db.execute(sql, params)
        row = await cur.fetchone()
        return dict(row) if row else None

async def fetchall(sql: str, params: tuple = ()) -> list[dict]:
    async with get_db() as db:
        cur = await db.execute(sql, params)
        rows = await cur.fetchall()
        return [dict(r) for r in rows]

async def execute(sql: str, params: tuple = ()) -> int:
    """Выполнить INSERT/UPDATE/DELETE. Возвращает lastrowid."""
    async with get_db() as db:
        cur = await db.execute(sql, params)
        await db.commit()
        return cur.lastrowid

async def executemany(sql: str, params_list: list) -> None:
    async with get_db() as db:
        await db.executemany(sql, params_list)
        await db.commit()

def now() -> int:
    """Текущее время в секундах (Unix timestamp)."""
    return int(time.time())

def now_ms() -> int:
    """Текущее время в миллисекундах."""
    return int(time.time() * 1000)

# ── JWT Revocation ────────────────────────────────────────────────────────────

async def is_jti_revoked(jti: str) -> bool:
    """Проверить, отозван ли токен по JTI."""
    if not jti:
        return False
    row = await fetchone("SELECT 1 FROM revoked_tokens WHERE jti = ?", (jti,))
    return row is not None

async def revoke_jti(jti: str, username: str) -> None:
    """Отозвать токен (logout / компрометация)."""
    await execute(
        "INSERT OR IGNORE INTO revoked_tokens (jti, username, revoked_at) VALUES (?,?,?)",
        (jti, username, now())
    )

async def revoke_all_user_tokens(username: str) -> None:
    """Отозвать все токены пользователя — делается через мин. iat в users (быстро)."""
    await execute(
        "UPDATE users SET token_min_iat = ? WHERE username = ?",
        (now(), username)
    )

async def cleanup_revoked_tokens(older_than_days: int = 90) -> None:
    """Удалить устаревшие записи (старше срока жизни токена)."""
    cutoff = now() - older_than_days * 86400
    await execute("DELETE FROM revoked_tokens WHERE revoked_at < ?", (cutoff,))

# ── Очистка старых данных ─────────────────────────────────────────────────────

async def cleanup_old_data() -> dict:
    """
    Удалить устаревшие данные. Вызывать раз в сутки.
    Возвращает статистику удалённых записей.
    """
    n = now()
    stats = {}

    # Pending logins: удалить истёкшие > 10 минут назад
    r = await execute("DELETE FROM pending_logins WHERE expires_at < ?", (n - 600,))
    stats["pending_logins"] = r

    # Offline messages: удалить > 7 дней
    r = await execute(
        "DELETE FROM messages WHERE delivered = 0 AND sent_at < ?",
        (n - 7 * 86400,)
    )
    stats["offline_messages"] = r

    # Delivered messages удаляются сразу при доставке (в handlers.py)
    # Здесь подчищаем только если что-то осталось старше 1 часа (на случай сбоя)
    r = await execute(
        "DELETE FROM messages WHERE delivered = 1 AND sent_at < ?",
        (n - 3600,)
    )
    stats["delivered_messages_cleanup"] = r

    # message_receipts: > 30 дней
    r = await execute(
        "DELETE FROM message_receipts WHERE sent_at < ?",
        (n - 30 * 86400,)
    )
    stats["receipts"] = r

    # offline_events: > 3 дней
    r = await execute(
        "DELETE FROM offline_events WHERE created_at < ?",
        (n - 3 * 86400,)
    )
    stats["offline_events"] = r

    # channel_messages: > 90 дней (настраивается в config)
    r = await execute(
        "DELETE FROM channel_messages WHERE sent_at < ? AND deleted = 0",
        ((n - 90 * 86400) * 1000,)  # sent_at в миллисекундах
    )
    stats["channel_messages"] = r

    # support_messages: > 180 дней
    r = await execute(
        "DELETE FROM support_messages WHERE created_at < ?",
        (n - 180 * 86400,)
    )
    stats["support_messages"] = r

    # JWT revocation: > 90 дней
    await cleanup_revoked_tokens(90)

    return stats
