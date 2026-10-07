"""
Лёгкое персистентное хранилище подписок, рефералов, пользовательских настроек,
учёта пользователей и состояния (модель, текущий чат).
"""

import asyncio
import sqlite3
import time
import os

DB_PATH = os.path.join(os.path.dirname(__file__), "subscriptions.db")


def _connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def _init_db():
    conn = _connect()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS subscriptions (
            user_id INTEGER PRIMARY KEY,
            expires_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS referrals (
            inviter_id INTEGER,
            invited_id INTEGER PRIMARY KEY,
            date INTEGER,
            bonus_applied INTEGER DEFAULT 0
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS ghostecos_link_rewards (
            tg_user_id INTEGER PRIMARY KEY,
            gs_user_id INTEGER NOT NULL UNIQUE,
            account_created_at INTEGER,
            bonus_days INTEGER NOT NULL,
            awarded_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_settings (
            user_id INTEGER PRIMARY KEY,
            custom_prompt TEXT,
            default_model_key TEXT,
            timezone_name TEXT,
            updated_at INTEGER NOT NULL
        )
        """
    )
    settings_columns = {
        row[1] for row in conn.execute("PRAGMA table_info(user_settings)").fetchall()
    }
    if "default_model_key" not in settings_columns:
        conn.execute("ALTER TABLE user_settings ADD COLUMN default_model_key TEXT")
    if "timezone_name" not in settings_columns:
        conn.execute("ALTER TABLE user_settings ADD COLUMN timezone_name TEXT")
    if "fallback_on_rate_limit" not in settings_columns:
        conn.execute(
            "ALTER TABLE user_settings ADD COLUMN fallback_on_rate_limit INTEGER DEFAULT 1"
        )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS favorite_models (
            user_id INTEGER NOT NULL,
            model_key TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (user_id, model_key)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS tutorial_progress (
            user_id INTEGER NOT NULL,
            topic TEXT NOT NULL,
            explained_at INTEGER NOT NULL,
            explain_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (user_id, topic)
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_tutorial_progress_user "
        "ON tutorial_progress(user_id, explained_at)"
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            user_id INTEGER PRIMARY KEY,
            first_seen INTEGER,
            last_seen INTEGER,
            gs_user_id INTEGER,
            gs_username TEXT,
            gs_linked_at INTEGER
        )
        """
    )
    # Добавляем связь GhostEcos в существующую базу без потери записей пользователей.
    user_columns = {row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    for column, sql_type in (
        ("gs_user_id", "INTEGER"),
        ("gs_username", "TEXT"),
        ("gs_linked_at", "INTEGER"),
    ):
        if column not in user_columns:
            conn.execute(f"ALTER TABLE users ADD COLUMN {column} {sql_type}")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_gs_user_id "
        "ON users(gs_user_id) WHERE gs_user_id IS NOT NULL"
    )
    # Состояние пользователя на диске (модель, чат, страница провайдера)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_state (
            user_id INTEGER PRIMARY KEY,
            model_key TEXT,
            current_chat_id TEXT,
            provider_page INTEGER DEFAULT 0,
            updated_at INTEGER NOT NULL
        )
        """
    )
    conn.commit()
    conn.close()


_init_db()


# ============ Подписки ============

def _set_subscription_sync(user_id: int, expires_at: int):
    conn = _connect()
    conn.execute(
        "INSERT INTO subscriptions (user_id, expires_at, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET expires_at=excluded.expires_at, updated_at=excluded.updated_at",
        (user_id, expires_at, int(time.time())),
    )
    conn.commit()
    conn.close()


def _get_expiry_sync(user_id: int) -> int:
    conn = _connect()
    row = conn.execute(
        "SELECT expires_at FROM subscriptions WHERE user_id = ?", (user_id,)
    ).fetchone()
    conn.close()
    return row[0] if row else 0


def _revoke_subscription_sync(user_id: int):
    conn = _connect()
    conn.execute("DELETE FROM subscriptions WHERE user_id = ?", (user_id,))
    conn.commit()
    conn.close()


def _list_active_subscriptions_sync():
    conn = _connect()
    rows = conn.execute(
        "SELECT user_id, expires_at FROM subscriptions WHERE expires_at > ? ORDER BY expires_at DESC",
        (int(time.time()),)
    ).fetchall()
    conn.close()
    return rows


async def set_subscription(user_id: int, expires_at: int):
    await asyncio.to_thread(_set_subscription_sync, user_id, expires_at)


async def extend_subscription_days(user_id: int, days: int):
    """Продлевает подписку на N дней: если уже активна — от текущего
    expires_at, если нет/истекла — от текущего момента. Используется для
    наград (например, за добавление пользовательского API-ключа)."""
    current_expiry = await get_expiry(user_id)
    base = max(current_expiry, int(time.time()))
    await set_subscription(user_id, base + days * 86400)


def _claim_ghostecos_link_bonus_sync(
    user_id: int,
    gs_user_id: int,
    account_created_at: int | None,
    new_account_window_seconds: int = 86400,
) -> dict:
    """Одноразовый Premium-бонус за первую привязку GhostID.

    +2 дня за саму привязку, ещё +3 дня если GhostEcos-аккаунту не больше
    new_account_window_seconds. Защита от фарма действует и по Telegram id,
    и по GhostID. Вечную подписку не изменяем, но награду считаем использованной.
    """
    user_id, gs_user_id = int(user_id), int(gs_user_id)
    now = int(time.time())
    created = int(account_created_at) if account_created_at else None
    is_new = bool(created and 0 <= now - created <= int(new_account_window_seconds))
    days = 2 + (3 if is_new else 0)

    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        exists = conn.execute(
            "SELECT tg_user_id, gs_user_id, bonus_days, awarded_at "
            "FROM ghostecos_link_rewards WHERE tg_user_id=? OR gs_user_id=? LIMIT 1",
            (user_id, gs_user_id),
        ).fetchone()
        if exists:
            conn.rollback()
            return {"awarded": False, "days": 0, "is_new_account": is_new}

        current_row = conn.execute(
            "SELECT expires_at FROM subscriptions WHERE user_id=?", (user_id,)
        ).fetchone()
        current_expiry = int(current_row[0]) if current_row else 0
        # Anything centuries in the future is effectively permanent Premium.
        permanent = current_expiry >= 253402300799
        if not permanent:
            base = max(current_expiry, now)
            new_expiry = base + days * 86400
            conn.execute(
                "INSERT INTO subscriptions (user_id, expires_at, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(user_id) DO UPDATE SET expires_at=excluded.expires_at, "
                "updated_at=excluded.updated_at",
                (user_id, new_expiry, now),
            )
        else:
            new_expiry = current_expiry

        conn.execute(
            "INSERT INTO ghostecos_link_rewards "
            "(tg_user_id, gs_user_id, account_created_at, bonus_days, awarded_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (user_id, gs_user_id, created, days, now),
        )
        conn.commit()
        return {
            "awarded": not permanent,
            "days": 0 if permanent else days,
            "eligible_days": days,
            "is_new_account": is_new,
            "permanent": permanent,
            "expires_at": new_expiry,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


async def claim_ghostecos_link_bonus(
    user_id: int,
    gs_user_id: int,
    account_created_at: int | None,
    new_account_window_seconds: int = 86400,
) -> dict:
    return await asyncio.to_thread(
        _claim_ghostecos_link_bonus_sync,
        user_id, gs_user_id, account_created_at, new_account_window_seconds,
    )


async def get_expiry(user_id: int) -> int:
    return await asyncio.to_thread(_get_expiry_sync, user_id)


async def is_subscribed(user_id: int) -> bool:
    return await get_expiry(user_id) > time.time()


async def revoke_subscription(user_id: int):
    await asyncio.to_thread(_revoke_subscription_sync, user_id)


async def list_active_subscriptions():
    return await asyncio.to_thread(_list_active_subscriptions_sync)


# ============ Рефералы ============

def _add_referral_sync(inviter_id: int, invited_id: int) -> bool:
    conn = _connect()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO referrals (inviter_id, invited_id, date) VALUES (?, ?, ?)",
            (inviter_id, invited_id, int(time.time()))
        )
        conn.commit()
        return conn.total_changes > 0
    finally:
        conn.close()


def _count_referrals_sync(user_id: int) -> int:
    conn = _connect()
    row = conn.execute(
        "SELECT COUNT(*) FROM referrals WHERE inviter_id = ?", (user_id,)
    ).fetchone()
    conn.close()
    return row[0] if row else 0


def _referral_bonus_for_tier(count: int) -> int:
    """Ставка «за следующего» при текущем числе приглашённых (для UI)."""
    if count < 10:
        return 30 * 60
    elif count < 20:
        return 3 * 3600
    elif count < 50:
        return 3 * 86400
    else:
        return 5 * 86400


def bonus_seconds_for_nth(n: int) -> int:
    """Бонус инвайтеру за n-го приглашённого (1-based)."""
    if n <= 0:
        return 0
    if n <= 9:
        return 30 * 60
    if n <= 19:
        return 3 * 3600
    if n <= 49:
        return 3 * 86400
    return 5 * 86400


def _get_referral_bonus_seconds_sync(user_id: int) -> int:
    """Сумма начисленных бонусов по тирам (1-й…count-й)."""
    count = _count_referrals_sync(user_id)
    if count <= 0:
        return 0
    return sum(bonus_seconds_for_nth(i) for i in range(1, count + 1))


def _mark_referral_bonus_applied_sync(inviter_id: int, invited_id: int):
    conn = _connect()
    conn.execute(
        "UPDATE referrals SET bonus_applied = 1 "
        "WHERE inviter_id = ? AND invited_id = ?",
        (inviter_id, invited_id),
    )
    conn.commit()
    conn.close()


async def add_referral(inviter_id: int, invited_id: int) -> bool:
    return await asyncio.to_thread(_add_referral_sync, inviter_id, invited_id)


async def count_referrals(user_id: int) -> int:
    return await asyncio.to_thread(_count_referrals_sync, user_id)


async def get_referral_bonus_seconds(user_id: int) -> int:
    return await asyncio.to_thread(_get_referral_bonus_seconds_sync, user_id)


async def mark_referral_bonus_applied(inviter_id: int, invited_id: int):
    await asyncio.to_thread(_mark_referral_bonus_applied_sync, inviter_id, invited_id)


# ============ Пользовательские настройки ============

def _set_custom_prompt_sync(user_id: int, prompt: str):
    conn = _connect()
    conn.execute(
        "INSERT INTO user_settings (user_id, custom_prompt, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET custom_prompt=?, updated_at=?",
        (user_id, prompt, int(time.time()), prompt, int(time.time()))
    )
    conn.commit()
    conn.close()


def _get_custom_prompt_sync(user_id: int) -> str | None:
    conn = _connect()
    row = conn.execute("SELECT custom_prompt FROM user_settings WHERE user_id = ?", (user_id,)).fetchone()
    conn.close()
    return row[0] if row else None


def _delete_custom_prompt_sync(user_id: int):
    conn = _connect()
    conn.execute(
        "UPDATE user_settings SET custom_prompt=NULL, updated_at=? WHERE user_id=?",
        (int(time.time()), user_id),
    )
    conn.commit()
    conn.close()


def _set_default_model_sync(user_id: int, model_key: str | None):
    conn = _connect()
    conn.execute(
        "INSERT INTO user_settings (user_id, custom_prompt, default_model_key, updated_at) "
        "VALUES (?, NULL, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET default_model_key=excluded.default_model_key, "
        "updated_at=excluded.updated_at",
        (user_id, model_key, int(time.time())),
    )
    conn.commit()
    conn.close()


def _get_default_model_sync(user_id: int) -> str | None:
    conn = _connect()
    row = conn.execute(
        "SELECT default_model_key FROM user_settings WHERE user_id=?",
        (user_id,),
    ).fetchone()
    conn.close()
    return row[0] if row and row[0] else None


def _set_timezone_sync(user_id: int, timezone_name: str):
    conn = _connect()
    conn.execute(
        "INSERT INTO user_settings (user_id, custom_prompt, timezone_name, updated_at) "
        "VALUES (?, NULL, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET timezone_name=excluded.timezone_name, "
        "updated_at=excluded.updated_at",
        (user_id, str(timezone_name), int(time.time())),
    )
    conn.commit()
    conn.close()


def _get_timezone_sync(user_id: int) -> str:
    conn = _connect()
    row = conn.execute(
        "SELECT timezone_name FROM user_settings WHERE user_id=?",
        (user_id,),
    ).fetchone()
    conn.close()
    return str(row[0]) if row and row[0] else "Europe/Moscow"


def _set_fallback_on_rate_limit_sync(user_id: int, enabled: bool):
    conn = _connect()
    conn.execute(
        "INSERT INTO user_settings (user_id, custom_prompt, fallback_on_rate_limit, updated_at) "
        "VALUES (?, NULL, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET "
        "fallback_on_rate_limit=excluded.fallback_on_rate_limit, "
        "updated_at=excluded.updated_at",
        (user_id, 1 if enabled else 0, int(time.time())),
    )
    conn.commit()
    conn.close()


def _get_fallback_on_rate_limit_sync(user_id: int) -> bool:
    conn = _connect()
    row = conn.execute(
        "SELECT fallback_on_rate_limit FROM user_settings WHERE user_id=?",
        (user_id,),
    ).fetchone()
    conn.close()
    if not row or row[0] is None:
        return True
    return bool(row[0])


def _list_favorite_models_sync(user_id: int) -> list[str]:
    conn = _connect()
    rows = conn.execute(
        "SELECT model_key FROM favorite_models WHERE user_id=? ORDER BY created_at ASC",
        (user_id,),
    ).fetchall()
    conn.close()
    return [str(row[0]) for row in rows]


def _is_model_favorite_sync(user_id: int, model_key: str) -> bool:
    conn = _connect()
    row = conn.execute(
        "SELECT 1 FROM favorite_models WHERE user_id=? AND model_key=? LIMIT 1",
        (user_id, model_key),
    ).fetchone()
    conn.close()
    return bool(row)


def _set_model_favorite_sync(user_id: int, model_key: str, enabled: bool) -> bool:
    conn = _connect()
    if enabled:
        conn.execute(
            "INSERT OR IGNORE INTO favorite_models (user_id, model_key, created_at) VALUES (?, ?, ?)",
            (user_id, model_key, int(time.time())),
        )
    else:
        conn.execute(
            "DELETE FROM favorite_models WHERE user_id=? AND model_key=?",
            (user_id, model_key),
        )
    conn.commit()
    conn.close()
    return enabled


async def set_custom_prompt(user_id: int, prompt: str):
    await asyncio.to_thread(_set_custom_prompt_sync, user_id, prompt)


async def get_custom_prompt(user_id: int) -> str | None:
    return await asyncio.to_thread(_get_custom_prompt_sync, user_id)


async def delete_custom_prompt(user_id: int):
    await asyncio.to_thread(_delete_custom_prompt_sync, user_id)


async def set_default_model(user_id: int, model_key: str | None):
    await asyncio.to_thread(_set_default_model_sync, user_id, model_key)


async def get_default_model(user_id: int) -> str | None:
    return await asyncio.to_thread(_get_default_model_sync, user_id)


async def set_timezone(user_id: int, timezone_name: str):
    await asyncio.to_thread(_set_timezone_sync, user_id, timezone_name)


async def get_timezone(user_id: int) -> str:
    return await asyncio.to_thread(_get_timezone_sync, user_id)


async def set_fallback_on_rate_limit(user_id: int, enabled: bool):
    await asyncio.to_thread(_set_fallback_on_rate_limit_sync, user_id, enabled)


async def get_fallback_on_rate_limit(user_id: int) -> bool:
    return await asyncio.to_thread(_get_fallback_on_rate_limit_sync, user_id)


async def list_favorite_models(user_id: int) -> list[str]:
    return await asyncio.to_thread(_list_favorite_models_sync, user_id)


async def is_model_favorite(user_id: int, model_key: str) -> bool:
    return await asyncio.to_thread(_is_model_favorite_sync, user_id, model_key)


async def set_model_favorite(user_id: int, model_key: str, enabled: bool) -> bool:
    return await asyncio.to_thread(_set_model_favorite_sync, user_id, model_key, enabled)


# ============ Состояние пользователя (модель, чат) ============

def _get_user_state_sync(user_id: int) -> dict:
    conn = _connect()
    row = conn.execute(
        "SELECT model_key, current_chat_id, provider_page FROM user_state WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    conn.close()
    if not row:
        return {}
    return {
        "model_key": row[0],
        "current_chat_id": row[1],
        "provider_page": row[2] or 0,
    }


def _set_user_state_sync(user_id: int, model_key: str | None = None,
                         current_chat_id: str | None = None,
                         provider_page: int | None = None):
    conn = _connect()
    existing = _get_user_state_sync(user_id)
    mk = model_key if model_key is not None else existing.get("model_key")
    cc = current_chat_id if current_chat_id is not None else existing.get("current_chat_id")
    pp = provider_page if provider_page is not None else existing.get("provider_page", 0)
    conn.execute(
        "INSERT INTO user_state (user_id, model_key, current_chat_id, provider_page, updated_at) "
        "VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET "
        "model_key=excluded.model_key, current_chat_id=excluded.current_chat_id, "
        "provider_page=excluded.provider_page, updated_at=excluded.updated_at",
        (user_id, mk, cc, pp, int(time.time())),
    )
    conn.commit()
    conn.close()


async def get_user_state(user_id: int) -> dict:
    return await asyncio.to_thread(_get_user_state_sync, user_id)


async def set_user_model(user_id: int, model_key: str):
    await asyncio.to_thread(_set_user_state_sync, user_id, model_key, None, None)


async def set_user_chat(user_id: int, chat_id: str):
    await asyncio.to_thread(_set_user_state_sync, user_id, None, chat_id, None)


async def set_user_provider_page(user_id: int, page: int):
    await asyncio.to_thread(_set_user_state_sync, user_id, None, None, page)


# ============ Пользователи ============

def _touch_user_sync(user_id: int):
    now = int(time.time())
    conn = _connect()
    conn.execute(
        "INSERT INTO users (user_id, first_seen, last_seen) VALUES (?, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET last_seen = ?",
        (user_id, now, now, now)
    )
    conn.commit()
    conn.close()


async def touch_user(user_id: int):
    await asyncio.to_thread(_touch_user_sync, user_id)


def _get_user_ghostecos_sync(user_id: int) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT gs_user_id, gs_username, gs_linked_at FROM users "
            "WHERE user_id = ? AND gs_user_id IS NOT NULL",
            (int(user_id),),
        ).fetchone()
        if not row:
            return None
        return {"gs_user_id": row[0], "gs_username": row[1], "linked_at": row[2]}
    finally:
        conn.close()


async def get_user_ghostecos(user_id: int) -> dict | None:
    return await asyncio.to_thread(_get_user_ghostecos_sync, user_id)


def _count_users_sync() -> int:
    conn = _connect()
    row = conn.execute("SELECT COUNT(*) FROM users").fetchone()
    conn.close()
    return row[0] if row else 0


async def count_users() -> int:
    return await asyncio.to_thread(_count_users_sync)


# ============ Tutorial progress ============
def _get_tutorial_state_sync(user_id: int) -> dict:
    now=int(time.time())
    conn=_connect()
    try:
        user=conn.execute(
            "SELECT first_seen,last_seen FROM users WHERE user_id=?",
            (int(user_id),),
        ).fetchone()
        rows=conn.execute(
            "SELECT topic,explained_at,explain_count FROM tutorial_progress "
            "WHERE user_id=? ORDER BY explained_at ASC",
            (int(user_id),),
        ).fetchall()
        first_seen=int(user[0] or now) if user else now
        last_seen=int(user[1] or first_seen) if user else first_seen
        topics={
            str(topic):{"explained_at":int(ts),"count":int(count)}
            for topic,ts,count in rows
        }
        age_seconds=max(0,now-first_seen)
        # «Новый» = аккаунт/первое использование не старше недели и обучение
        # ещё не прошло основную часть. Модель также видит точный возраст и topics.
        is_new=(age_seconds <= 7*24*3600 and len(topics) < 6)
        return {
            "first_seen":first_seen,
            "last_seen":last_seen,
            "age_seconds":age_seconds,
            "is_new_user":is_new,
            "topics":topics,
        }
    finally:
        conn.close()


def _mark_tutorial_topic_sync(user_id: int, topic: str) -> dict:
    topic=str(topic or "").strip().lower()
    if not topic:
        raise ValueError("topic is empty")
    now=int(time.time())
    conn=_connect()
    try:
        conn.execute(
            "INSERT INTO tutorial_progress(user_id,topic,explained_at,explain_count) "
            "VALUES(?,?,?,1) ON CONFLICT(user_id,topic) DO UPDATE SET "
            "explained_at=excluded.explained_at, explain_count=explain_count+1",
            (int(user_id),topic,now),
        )
        conn.commit()
    finally:
        conn.close()
    return _get_tutorial_state_sync(int(user_id))


async def get_tutorial_state(user_id: int) -> dict:
    return await asyncio.to_thread(_get_tutorial_state_sync,int(user_id))


async def mark_tutorial_topic(user_id: int, topic: str) -> dict:
    return await asyncio.to_thread(_mark_tutorial_topic_sync,int(user_id),topic)


# ============ Пользовательские API-ключи (общий пул ротации) ============
# Пользователь присылает свой ключ провайдера — он уходит в общий пул и
# используется как запасной, когда наши собственные ключи исчерпали лимит.
# За первый валидный ключ каждого провайдера — разовая награда (премиум-дни),
# начисляется на уровне bot.py; тут только хранение и учёт "было ли уже".
#
# Ключи хранятся зашифрованными (Fernet) — секрет берётся из переменной
# окружения DB_ENCRYPTION_KEY. Сгенерировать новый ключ:
#   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# и положить строку в .env как DB_ENCRYPTION_KEY=... — один раз, менять
# этот ключ ПОСЛЕ того как в базе уже есть записи, нельзя (расшифровка
# сломается для всех существующих ключей).

_fernet = None


def _get_fernet():
    global _fernet
    if _fernet is None:
        from cryptography.fernet import Fernet
        secret = os.environ.get("DB_ENCRYPTION_KEY")
        if not secret:
            raise RuntimeError(
                "DB_ENCRYPTION_KEY не задан в .env — сгенерируй один раз через "
                "python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\" "
                "и добавь в .env как DB_ENCRYPTION_KEY=..."
            )
        _fernet = Fernet(secret.encode() if isinstance(secret, str) else secret)
    return _fernet


def _encrypt_key(plain: str) -> str:
    return _get_fernet().encrypt(plain.encode()).decode()


def _decrypt_key(token: str) -> str:
    return _get_fernet().decrypt(token.encode()).decode()


def _init_api_keys_table():
    conn = _connect()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_api_keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            provider TEXT NOT NULL,
            api_key TEXT NOT NULL,
            is_active INTEGER DEFAULT 1,
            fail_count INTEGER DEFAULT 0,
            added_at INTEGER NOT NULL,
            last_used_at INTEGER,
            use_own_only INTEGER DEFAULT 0,
            UNIQUE(user_id, provider)
        )
        """
    )
    # миграция для баз, созданных до добавления use_own_only
    try:
        conn.execute("ALTER TABLE user_api_keys ADD COLUMN use_own_only INTEGER DEFAULT 0")
        conn.commit()
    except Exception:
        pass  # колонка уже есть
    conn.commit()
    conn.close()


_init_api_keys_table()


def _add_user_key_sync(user_id: int, provider: str, api_key: str) -> dict:
    """Сохраняет/заменяет ключ пользователя для провайдера. Возвращает
    {"is_first": bool} — is_first=True значит это первый ЛЮБОЙ ключ этого
    пользователя для этого провайдера (для начисления награды один раз).
    api_key сохраняется зашифрованным (см. _get_fernet)."""
    conn = _connect()
    existing = conn.execute(
        "SELECT id FROM user_api_keys WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    ).fetchone()
    is_first = existing is None
    now = int(time.time())
    encrypted = _encrypt_key(api_key)
    conn.execute(
        "INSERT INTO user_api_keys (user_id, provider, api_key, is_active, fail_count, added_at) "
        "VALUES (?, ?, ?, 1, 0, ?) "
        "ON CONFLICT(user_id, provider) DO UPDATE SET "
        "api_key=excluded.api_key, is_active=1, fail_count=0, added_at=excluded.added_at",
        (user_id, provider, encrypted, now),
    )
    conn.commit()
    conn.close()
    return {"is_first": is_first}


def _get_active_keys_sync(provider: str) -> list[dict]:
    """Все активные ключи пользователей для провайдера, отсортированные по
    давности использования (round-robin: наименее свежий использованный —
    первый в очереди). api_key возвращается уже расшифрованным, готовым
    к прямому использованию в клиенте провайдера."""
    conn = _connect()
    rows = conn.execute(
        "SELECT user_id, api_key, fail_count FROM user_api_keys "
        "WHERE provider = ? AND is_active = 1 AND use_own_only = 0 "
        "ORDER BY last_used_at IS NOT NULL, last_used_at ASC",
        (provider,),
    ).fetchall()
    conn.close()
    result = []
    for r in rows:
        try:
            result.append({"user_id": r[0], "api_key": _decrypt_key(r[1]), "fail_count": r[2]})
        except Exception:
            # ключ не расшифровывается (сменился DB_ENCRYPTION_KEY или
            # запись повреждена) — пропускаем его молча, не роняем пул
            continue
    return result


def _touch_key_used_sync(user_id: int, provider: str):
    conn = _connect()
    conn.execute(
        "UPDATE user_api_keys SET last_used_at = ? WHERE user_id = ? AND provider = ?",
        (int(time.time()), user_id, provider),
    )
    conn.commit()
    conn.close()


def _mark_key_failed_sync(user_id: int, provider: str, deactivate_after: int = 3) -> bool:
    """Увеличивает счётчик неудач ключа (например 401 — ключ отозван).
    После deactivate_after подряд идущих провалов ключ деактивируется.
    Возвращает True если ключ был деактивирован в этом вызове."""
    conn = _connect()
    row = conn.execute(
        "SELECT fail_count FROM user_api_keys WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    ).fetchone()
    if not row:
        conn.close()
        return False
    new_count = (row[0] or 0) + 1
    deactivated = new_count >= deactivate_after
    conn.execute(
        "UPDATE user_api_keys SET fail_count = ?, is_active = ? WHERE user_id = ? AND provider = ?",
        (new_count, 0 if deactivated else 1, user_id, provider),
    )
    conn.commit()
    conn.close()
    return deactivated


def _reset_key_fail_count_sync(user_id: int, provider: str):
    conn = _connect()
    conn.execute(
        "UPDATE user_api_keys SET fail_count = 0 WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    )
    conn.commit()
    conn.close()


def _remove_user_key_sync(user_id: int, provider: str):
    conn = _connect()
    conn.execute(
        "DELETE FROM user_api_keys WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    )
    conn.commit()
    conn.close()


def _list_user_keys_sync(user_id: int) -> list[dict]:
    conn = _connect()
    rows = conn.execute(
        "SELECT provider, is_active, added_at, fail_count, use_own_only, api_key, last_used_at "
        "FROM user_api_keys WHERE user_id = ? ORDER BY added_at DESC",
        (user_id,),
    ).fetchall()
    conn.close()
    result = []
    for r in rows:
        masked = ""
        try:
            plain = _decrypt_key(r[5])
            masked = (plain[:4] + "…" + plain[-4:]) if len(plain) > 10 else "••••"
        except Exception:
            masked = "••••"
        result.append({
            "provider": r[0], "is_active": bool(r[1]), "added_at": r[2],
            "fail_count": r[3], "use_own_only": bool(r[4]), "masked_key": masked,
            "last_used_at": r[6],
        })
    return result


def _get_user_key_sync(user_id: int, provider: str) -> dict | None:
    """Ключ конкретного юзера для конкретного провайдера (для режима
    "использовать только свой ключ" — ai.py дёргает это перед обычным
    пулом, если юзер включил персональный режим для этого провайдера)."""
    conn = _connect()
    row = conn.execute(
        "SELECT api_key, is_active, use_own_only FROM user_api_keys WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    ).fetchone()
    conn.close()
    if not row or not row[1]:
        return None
    try:
        return {"api_key": _decrypt_key(row[0]), "use_own_only": bool(row[2])}
    except Exception:
        return None


def _get_user_key_any_sync(user_id: int, provider: str) -> dict | None:
    conn = _connect()
    row = conn.execute(
        "SELECT api_key, is_active, use_own_only, fail_count, last_used_at "
        "FROM user_api_keys WHERE user_id = ? AND provider = ?",
        (user_id, provider),
    ).fetchone()
    conn.close()
    if not row:
        return None
    try:
        return {
            "api_key": _decrypt_key(row[0]),
            "is_active": bool(row[1]),
            "use_own_only": bool(row[2]),
            "fail_count": int(row[3] or 0),
            "last_used_at": row[4],
        }
    except Exception:
        return None


def _reactivate_user_key_sync(user_id: int, provider: str):
    conn = _connect()
    conn.execute(
        "UPDATE user_api_keys SET is_active=1, fail_count=0 "
        "WHERE user_id=? AND provider=?",
        (user_id, provider),
    )
    conn.commit()
    conn.close()


def _set_use_own_only_sync(user_id: int, provider: str, value: bool):
    conn = _connect()
    conn.execute(
        "UPDATE user_api_keys SET use_own_only = ? WHERE user_id = ? AND provider = ?",
        (1 if value else 0, user_id, provider),
    )
    conn.commit()
    conn.close()


async def get_user_key_any(user_id: int, provider: str) -> dict | None:
    return await asyncio.to_thread(_get_user_key_any_sync, user_id, provider)


async def reactivate_user_key(user_id: int, provider: str):
    await asyncio.to_thread(_reactivate_user_key_sync, user_id, provider)


async def get_user_key(user_id: int, provider: str) -> dict | None:
    return await asyncio.to_thread(_get_user_key_sync, user_id, provider)


async def set_use_own_only(user_id: int, provider: str, value: bool):
    await asyncio.to_thread(_set_use_own_only_sync, user_id, provider, value)


def _count_contributed_providers_sync(user_id: int) -> int:
    """Сколько РАЗНЫХ провайдеров юзер когда-либо снабдил ключом (для
    отображения статистики — не влияет на награду, награда начисляется
    разово в момент is_first в bot.py)."""
    conn = _connect()
    row = conn.execute(
        "SELECT COUNT(DISTINCT provider) FROM user_api_keys WHERE user_id = ?",
        (user_id,),
    ).fetchone()
    conn.close()
    return row[0] if row else 0


async def add_user_key(user_id: int, provider: str, api_key: str) -> dict:
    return await asyncio.to_thread(_add_user_key_sync, user_id, provider, api_key)


async def get_active_keys(provider: str) -> list[dict]:
    return await asyncio.to_thread(_get_active_keys_sync, provider)


async def touch_key_used(user_id: int, provider: str):
    await asyncio.to_thread(_touch_key_used_sync, user_id, provider)


async def mark_key_failed(user_id: int, provider: str, deactivate_after: int = 3) -> bool:
    return await asyncio.to_thread(_mark_key_failed_sync, user_id, provider, deactivate_after)


async def reset_key_fail_count(user_id: int, provider: str):
    await asyncio.to_thread(_reset_key_fail_count_sync, user_id, provider)


async def remove_user_key(user_id: int, provider: str):
    await asyncio.to_thread(_remove_user_key_sync, user_id, provider)


async def list_user_keys(user_id: int) -> list[dict]:
    return await asyncio.to_thread(_list_user_keys_sync, user_id)


async def count_contributed_providers(user_id: int) -> int:
    return await asyncio.to_thread(_count_contributed_providers_sync, user_id)
