"""SSO GhostEcos (GhostChat/GhostSocial) → GhoGem + привязка Telegram-аккаунта.

Почему так: сайт GhoGem (/ghogem/) живёт на том же домене, что соцсеть
(/social), а соцсеть при логине кладёт свой токен и в localStorage, и в cookie
`gs_token` (path=/). Значит вошедшего юзера можно опознать без своего логина —
ровно так же это делает магазин (/opt/shop_bot/web/api.py): токен → строка в
общей таблице soc_tokens базы ghostchat.db. Свои пароли GhoGem не хранит и не
проверяет: форма входа на сайте бьёт напрямую в /api/soc/login соцсети.

Namespace uid (папка users/<uid>/chats и ключ во всех таблицах бота):
    telegram id                — Telegram-бот, как было
    GS_UID_OFFSET + gs_user_id — аккаунт GhostEcos, не привязанный к Telegram
    telegram id                — аккаунт GhostEcos, ПРИВЯЗАННЫЙ к Telegram
                                 (чаты/файлы/память бота и сайта — общие)

Оффсет 10**12 берём с запасом: telegram id сейчас ~10^9–10^10, так что
пересечься с ним GhostEcos-id (обычный автоинкремент) не может.
"""
from __future__ import annotations

import hashlib
import logging
import os
import random
import secrets
import shutil
import sqlite3
import time
from typing import Optional

import db as bot_db
import core_auth_client

log = logging.getLogger("ghogem_sso")

# База GhostEcos — только читаем (users + soc_tokens + user_devices).
GS_DB_PATH = os.getenv("SOCIAL_DB_PATH", "/opt/ghostchat/ghostchat.db")
# Привязки и профиль пользователя используют одну SQLite-базу бота.
LINK_DB_PATH = bot_db.DB_PATH

GS_UID_OFFSET = 1_000_000_000_000
GUEST_USER_ID = 1

TOKEN_CACHE_TTL = 60          # сек, положительный кэш резолва токена
TOKEN_CACHE_TTL_MISS = 15     # сек, отрицательный (чтобы мусорный токен не долбил БД)
LINK_CODE_TTL = 15 * 60       # сек, жизнь кода привязки из браузера
WEBAPP_LOGIN_CODE_TTL = 2 * 60 # сек, окно для передачи одноразового кода в Telegram

_token_cache: dict[str, tuple[float, Optional[dict]]] = {}


def gs_namespace_uid(gs_user_id: int) -> int:
    return GS_UID_OFFSET + int(gs_user_id)


def is_gs_namespace(uid: int) -> bool:
    return int(uid) >= GS_UID_OFFSET


# ── База GhostEcos: токен → аккаунт ───────────────────────────────────────────

def _gs_db():
    raise RuntimeError("GhostEcos identity must be read through Core API")


def resolve_gs_token(token: Optional[str], use_cache: bool = True) -> Optional[dict]:
    """Resolve a real GhostEcos account through the restricted Core API."""
    token = (token or "").strip()
    if not token or token.startswith("guest_") or not 8 <= len(token) <= 4096:
        return None
    now = time.time()
    if use_cache:
        hit = _token_cache.get(token)
        if hit and hit[0] > now:
            return hit[1]
    try:
        row = core_auth_client.resolve_token(token)
    except core_auth_client.CoreUnavailable:
        log.warning("GhostEcos identity service is unavailable")
        return None
    user = None
    if row and int(row.get("id") or 0) > 0:
        user = {"id": int(row["id"]), "username": row.get("username"),
                "display_name": row.get("display_name") or row.get("username"),
                "avatar_url": row.get("avatar_url")}
    _token_cache[token] = (now + (TOKEN_CACHE_TTL if user else TOKEN_CACHE_TTL_MISS), user)
    if len(_token_cache) > 5000:
        for key, (expires, _) in list(_token_cache.items()):
            if expires <= now:
                _token_cache.pop(key, None)
    return user


def forget_token(token: Optional[str]) -> None:
    if token:
        _token_cache.pop(token.strip(), None)


def get_gs_profile_by_id(gs_user_id: int) -> Optional[dict]:
    """Read only the public profile of the linked GhostEcos account."""
    try:
        return core_auth_client.profile_by_id(int(gs_user_id))
    except core_auth_client.CoreUnavailable:
        log.warning("GhostEcos public profile service is unavailable")
        return None


def get_gs_account_created_at(gs_user_id: int) -> Optional[int]:
    """Unix timestamp регистрации GhostEcos-аккаунта, если он доступен."""
    profile = get_gs_profile_by_id(gs_user_id)
    if not profile:
        return None
    try:
        value = profile.get("created_at_ts")
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


# ── Привязки Telegram ↔ GhostEcos ─────────────────────────────────────────────

def _link_db() -> sqlite3.Connection:
    c = sqlite3.connect(LINK_DB_PATH, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    return c


def _init_link_db() -> None:
    c = _link_db()
    # Обычно users создаёт db.py; повторяем безопасную миграцию здесь, чтобы
    # SSO-тесты и отдельный импорт модуля тоже имели единую схему.
    c.execute(
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
    user_columns = {row[1] for row in c.execute("PRAGMA table_info(users)").fetchall()}
    for column, sql_type in (
        ("gs_user_id", "INTEGER"),
        ("gs_username", "TEXT"),
        ("gs_linked_at", "INTEGER"),
    ):
        if column not in user_columns:
            c.execute(f"ALTER TABLE users ADD COLUMN {column} {sql_type}")
    c.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_gs_user_id "
        "ON users(gs_user_id) WHERE gs_user_id IS NOT NULL"
    )
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS gs_links (
            gs_user_id  INTEGER PRIMARY KEY,
            gs_username TEXT,
            tg_id       INTEGER UNIQUE NOT NULL,
            created_at  INTEGER NOT NULL
        )
        """
    )
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS gs_link_codes (
            code        TEXT PRIMARY KEY,
            gs_user_id  INTEGER NOT NULL,
            gs_username TEXT,
            created_at  INTEGER NOT NULL,
            used_at     INTEGER
        )
        """
    )
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS gs_webapp_login_codes (
            code_hash   TEXT PRIMARY KEY,
            client_id   TEXT NOT NULL DEFAULT 'ghogem_bot',
            gs_user_id  INTEGER NOT NULL,
            gs_username TEXT,
            tg_id       INTEGER NOT NULL,
            created_at  INTEGER NOT NULL,
            expires_at  INTEGER NOT NULL,
            used_at     INTEGER
        )
        """
    )
    webapp_columns = {row[1] for row in c.execute("PRAGMA table_info(gs_webapp_login_codes)").fetchall()}
    if "client_id" not in webapp_columns:
        c.execute("ALTER TABLE gs_webapp_login_codes ADD COLUMN client_id TEXT NOT NULL DEFAULT 'ghogem_bot'")
    if "terms_version" not in webapp_columns:
        c.execute("ALTER TABLE gs_webapp_login_codes ADD COLUMN terms_version TEXT NOT NULL DEFAULT ''")
    if "privacy_version" not in webapp_columns:
        c.execute("ALTER TABLE gs_webapp_login_codes ADD COLUMN privacy_version TEXT NOT NULL DEFAULT ''")
    c.execute(
        """
        CREATE TABLE IF NOT EXISTS sso_service_consents (
            gs_user_id    INTEGER NOT NULL,
            tg_id         INTEGER NOT NULL,
            client_id     TEXT NOT NULL,
            terms_version TEXT NOT NULL,
            privacy_version TEXT NOT NULL,
            accepted_at   INTEGER NOT NULL,
            PRIMARY KEY (gs_user_id, tg_id, client_id, terms_version, privacy_version)
        )
        """
    )
    c.execute(
        "CREATE INDEX IF NOT EXISTS idx_gs_webapp_login_codes_expiry "
        "ON gs_webapp_login_codes(expires_at)"
    )
    # Переносим прежние SSO-привязки в строку пользователя бота.
    for row in c.execute(
        "SELECT gs_user_id, gs_username, tg_id, created_at FROM gs_links"
    ).fetchall():
        c.execute(
            "INSERT INTO users "
            "(user_id, first_seen, last_seen, gs_user_id, gs_username, gs_linked_at) "
            "VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(user_id) DO UPDATE SET "
            "gs_user_id=excluded.gs_user_id, gs_username=excluded.gs_username, "
            "gs_linked_at=excluded.gs_linked_at",
            (int(row["tg_id"]), int(row["created_at"]), int(row["created_at"]),
             int(row["gs_user_id"]), row["gs_username"], int(row["created_at"])),
        )
    c.commit()
    c.close()


_init_link_db()


def record_service_consent(
    gs_user_id: int, tg_id: int, client_id: str, terms_version: str, privacy_version: str
) -> None:
    """Store the user's service-scoped acceptance of the current legal documents."""
    values = (client_id, terms_version, privacy_version)
    if any(not isinstance(value, str) or not value.strip() or len(value) > 80 for value in values):
        raise ValueError("invalid SSO consent metadata")
    c = _link_db()
    try:
        c.execute(
            "INSERT INTO sso_service_consents "
            "(gs_user_id, tg_id, client_id, terms_version, privacy_version, accepted_at) "
            "VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(gs_user_id, tg_id, client_id, terms_version, privacy_version) "
            "DO UPDATE SET accepted_at=excluded.accepted_at",
            (int(gs_user_id), int(tg_id), client_id, terms_version, privacy_version, int(time.time())),
        )
        c.commit()
    finally:
        c.close()


def _upsert_bot_user_link(
    c: sqlite3.Connection, tg_id: int, gs_user_id: int, gs_username: str, linked_at: int
) -> None:
    c.execute(
        "INSERT INTO users "
        "(user_id, first_seen, last_seen, gs_user_id, gs_username, gs_linked_at) "
        "VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(user_id) DO UPDATE SET "
        "gs_user_id=excluded.gs_user_id, gs_username=excluded.gs_username, "
        "gs_linked_at=excluded.gs_linked_at",
        (int(tg_id), int(linked_at), int(linked_at), int(gs_user_id),
         (gs_username or "").strip() or None, int(linked_at)),
    )


def link_by_gs(gs_user_id: int) -> Optional[dict]:
    c = _link_db()
    row = c.execute("SELECT * FROM gs_links WHERE gs_user_id=?", (int(gs_user_id),)).fetchone()
    c.close()
    return dict(row) if row else None


def link_by_tg(tg_id: int) -> Optional[dict]:
    c = _link_db()
    row = c.execute("SELECT * FROM gs_links WHERE tg_id=?", (int(tg_id),)).fetchone()
    c.close()
    return dict(row) if row else None


def link_create(gs_user_id: int, gs_username: str, tg_id: int) -> tuple[bool, str, int]:
    """Связать GhostEcos и Telegram, атомарно обновив SSO и профиль бота."""
    gs_user_id, tg_id = int(gs_user_id), int(tg_id)
    now = int(time.time())
    c = _link_db()
    try:
        c.execute("BEGIN IMMEDIATE")
        existing_gs = c.execute(
            "SELECT * FROM gs_links WHERE gs_user_id=?", (gs_user_id,)
        ).fetchone()
        existing_tg = c.execute(
            "SELECT * FROM gs_links WHERE tg_id=?", (tg_id,)
        ).fetchone()

        if existing_gs and int(existing_gs["tg_id"]) == tg_id:
            _upsert_bot_user_link(
                c, tg_id, gs_user_id, existing_gs["gs_username"] or gs_username,
                int(existing_gs["created_at"]),
            )
            c.commit()
            return True, "Аккаунты уже связаны.", 0
        if existing_gs:
            c.rollback()
            return False, "Этот аккаунт GhostEcos уже привязан к другому Telegram. Сначала отвяжи его.", 0
        if existing_tg:
            c.rollback()
            return False, "Этот Telegram уже привязан к аккаунту @%s. Сначала отвяжи его." % (
                existing_tg["gs_username"] or existing_tg["gs_user_id"],
            ), 0

        c.execute(
            "INSERT INTO gs_links (gs_user_id, gs_username, tg_id, created_at) VALUES (?,?,?,?)",
            (gs_user_id, gs_username, tg_id, now),
        )
        _upsert_bot_user_link(c, tg_id, gs_user_id, gs_username, now)
        c.commit()
    except sqlite3.IntegrityError:
        c.rollback()
        return False, "Не удалось привязать: аккаунт уже занят.", 0
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

    # Чаты, созданные в веб-namespace до привязки, переносим к Telegram-профилю.
    moved = 0
    try:
        moved = merge_user_dir(gs_namespace_uid(gs_user_id), tg_id)
    except Exception:
        log.exception("merge_user_dir failed (gs=%s tg=%s)", gs_user_id, tg_id)
    return True, "Аккаунты связаны.", moved


def link_delete_by_gs(gs_user_id: int) -> bool:
    """Отвязать в SSO и очистить привязку в профиле бота одной транзакцией."""
    c = _link_db()
    try:
        c.execute("BEGIN IMMEDIATE")
        link = c.execute(
            "SELECT tg_id FROM gs_links WHERE gs_user_id=?", (int(gs_user_id),)
        ).fetchone()
        if not link:
            c.rollback()
            return False
        c.execute("DELETE FROM gs_links WHERE gs_user_id=?", (int(gs_user_id),))
        c.execute(
            "UPDATE users SET gs_user_id=NULL, gs_username=NULL, gs_linked_at=NULL "
            "WHERE user_id=?",
            (int(link["tg_id"]),),
        )
        # Any open SSO URL issued for the old Telegram binding must stop working.
        c.execute(
            "DELETE FROM gs_webapp_login_codes WHERE gs_user_id=? AND used_at IS NULL",
            (int(gs_user_id),),
        )
        c.commit()
        return True
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()


# ── Одноразовая авторизация из Telegram Mini App ─────────────────────────────

def webapp_login_code_issue(
    gs_user_id: int,
    gs_username: str,
    tg_id: Optional[int],
    client_id: str = "ghogem_bot",
    terms_version: str = "",
    privacy_version: str = "",
) -> tuple[str, int]:
    """Issue a short-lived, one-time authorization code for a registered client.

    Only the SHA-256 hash is stored. Codes are scoped to the client and the
    GhostEcos account; Telegram binding is enforced at issue time when signed
    Mini App data exists, or atomically at redemption for external browsers.
    Consent metadata travels with the code and is audited against the Telegram
    user that successfully redeems it.
    """
    client_id = (client_id or "").strip().lower()
    if not client_id or len(client_id) > 64 or any(
        char not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for char in client_id
    ):
        raise ValueError("invalid SSO client id")
    terms_version = (terms_version or "").strip()
    privacy_version = (privacy_version or "").strip()
    if len(terms_version) > 80 or len(privacy_version) > 80:
        raise ValueError("invalid SSO consent version")
    now = int(time.time())
    expires_at = now + WEBAPP_LOGIN_CODE_TTL
    code = secrets.token_urlsafe(24)
    code_hash = hashlib.sha256(code.encode("utf-8")).hexdigest()
    c = _link_db()
    try:
        c.execute("BEGIN IMMEDIATE")
        c.execute(
            "DELETE FROM gs_webapp_login_codes "
            "WHERE client_id=? AND used_at IS NULL AND gs_user_id=?",
            (client_id, int(gs_user_id)),
        )
        if tg_id is not None:
            c.execute(
                "DELETE FROM gs_webapp_login_codes "
                "WHERE client_id=? AND used_at IS NULL AND tg_id=?",
                (client_id, int(tg_id)),
            )
        stored_tg_id = int(tg_id) if tg_id is not None else 0
        c.execute(
            "DELETE FROM gs_webapp_login_codes WHERE expires_at < ?",
            (now - 86400,),
        )
        c.execute(
            "INSERT INTO gs_webapp_login_codes "
            "(code_hash, client_id, gs_user_id, gs_username, tg_id, created_at, expires_at, "
            "terms_version, privacy_version) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (code_hash, client_id, int(gs_user_id), (gs_username or "").strip(),
             stored_tg_id, now, expires_at, terms_version, privacy_version),
        )
        c.commit()
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()
    return code, WEBAPP_LOGIN_CODE_TTL


def webapp_login_code_redeem(
    code: str, tg_id: int, client_id: str = "ghogem_bot"
) -> tuple[bool, str, int, Optional[dict]]:
    """Atomically redeem a one-time authorization code for its registered client."""
    code = (code or "").strip()
    client_id = (client_id or "").strip().lower()
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    if len(code) != 32 or any(char not in allowed for char in code):
        return False, "Ссылка входа недействительна или устарела. Открой /ecos и повтори вход.", 0, None
    if not client_id or len(client_id) > 64 or any(
        char not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for char in client_id
    ):
        return False, "Клиент входа не распознан.", 0, None

    tg_id = int(tg_id)
    now = int(time.time())
    code_hash = hashlib.sha256(code.encode("utf-8")).hexdigest()
    c = _link_db()
    try:
        c.execute("BEGIN IMMEDIATE")
        row = c.execute(
            "SELECT * FROM gs_webapp_login_codes WHERE code_hash=?",
            (code_hash,),
        ).fetchone()
        if not row:
            c.rollback()
            return False, "Ссылка входа устарела или уже отозвана. Вернись на страницу GhostEcos и нажми «Продолжить» заново.", 0, None
        if (row["client_id"] or "ghogem_bot") != client_id:
            c.rollback()
            return False, "Эта ссылка выдана для другого сервиса.", 0, None
        expected_tg_id = int(row["tg_id"] or 0)
        if expected_tg_id and expected_tg_id != tg_id:
            c.rollback()
            return False, "Эта ссылка создана для другого Telegram-аккаунта. Обнови страницу GhostEcos и нажми «Продолжить» заново из нужного Telegram.", 0, None
        if row["used_at"] is not None:
            c.rollback()
            return False, "Ссылка входа уже использована. Вернись на страницу GhostEcos и нажми «Продолжить» заново.", 0, None
        if now > int(row["expires_at"]):
            c.execute(
                "UPDATE gs_webapp_login_codes SET used_at=? WHERE code_hash=?",
                (now, code_hash),
            )
            c.commit()
            return False, "Срок действия ссылки истёк. Вернись на страницу GhostEcos и нажми «Продолжить» заново.", 0, None

        gs_user_id = int(row["gs_user_id"])
        gs_username = (row["gs_username"] or "").strip()
        existing_gs = c.execute(
            "SELECT * FROM gs_links WHERE gs_user_id=?", (gs_user_id,)
        ).fetchone()
        existing_tg = c.execute(
            "SELECT * FROM gs_links WHERE tg_id=?", (tg_id,)
        ).fetchone()
        if existing_gs and int(existing_gs["tg_id"]) != tg_id:
            c.rollback()
            return False, "Этот аккаунт GhostEcos уже связан с другим Telegram. Сначала отвяжи его.", 0, None
        if existing_tg and int(existing_tg["gs_user_id"]) != gs_user_id:
            c.rollback()
            return False, "Этот Telegram уже связан с другим аккаунтом GhostEcos. Сначала отвяжи его.", 0, None

        if not existing_gs:
            c.execute(
                "INSERT INTO gs_links (gs_user_id, gs_username, tg_id, created_at) "
                "VALUES (?, ?, ?, ?)",
                (gs_user_id, gs_username, tg_id, now),
            )
        else:
            gs_username = existing_gs["gs_username"] or gs_username
        _upsert_bot_user_link(c, tg_id, gs_user_id, gs_username, now)
        c.execute(
            "UPDATE gs_webapp_login_codes SET used_at=? "
            "WHERE code_hash=? AND used_at IS NULL",
            (now, code_hash),
        )
        terms_version = (row["terms_version"] or "").strip()
        privacy_version = (row["privacy_version"] or "").strip()
        if terms_version and privacy_version:
            c.execute(
                "INSERT OR IGNORE INTO sso_service_consents "
                "(gs_user_id, tg_id, client_id, terms_version, privacy_version, accepted_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (gs_user_id, tg_id, client_id, terms_version, privacy_version,
                 int(row["created_at"] or now)),
            )
        c.commit()
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

    moved = 0
    try:
        moved = merge_user_dir(gs_namespace_uid(gs_user_id), tg_id)
    except Exception:
        log.exception("merge_user_dir failed after Mini App login (gs=%s tg=%s)", gs_user_id, tg_id)
    account = {"gs_user_id": gs_user_id, "gs_username": gs_username}
    return True, "Вход в аккаунт GhostEcos выполнен успешно.", moved, account


# ── Код привязки (для браузера, где initData Telegram недоступен) ─────────────

def link_code_issue(gs_user_id: int, gs_username: str) -> str:
    """Выдать одноразовый код. Старые неиспользованные коды этого аккаунта
    гасим, чтобы «висящий» код из прошлой попытки не сработал позже."""
    c = _link_db()
    c.execute(
        "DELETE FROM gs_link_codes WHERE gs_user_id=? AND used_at IS NULL",
        (int(gs_user_id),),
    )
    c.execute("DELETE FROM gs_link_codes WHERE created_at < ?", (int(time.time()) - LINK_CODE_TTL * 4,))
    code = ""
    for _ in range(20):
        candidate = "%06d" % random.randint(0, 999999)
        exists = c.execute("SELECT 1 FROM gs_link_codes WHERE code=?", (candidate,)).fetchone()
        if not exists:
            code = candidate
            break
    if not code:
        c.close()
        raise RuntimeError("не удалось сгенерировать код")
    c.execute(
        "INSERT INTO gs_link_codes (code, gs_user_id, gs_username, created_at) VALUES (?,?,?,?)",
        (code, int(gs_user_id), gs_username, int(time.time())),
    )
    c.commit()
    c.close()
    return code


def link_code_redeem(code: str, tg_id: int) -> tuple[bool, str, int]:
    """Погасить код (вызывается из бота: /link 123456). Код одноразовый и
    живёт LINK_CODE_TTL — иначе подсмотренный код работал бы вечно."""
    code = (code or "").strip()
    if not code.isdigit() or len(code) != 6:
        return False, "Код должен быть из 6 цифр.", 0
    now = int(time.time())
    tg_id = int(tg_id)
    c = _link_db()
    try:
        # Код и связь фиксируем одной транзакцией. BEGIN IMMEDIATE не даёт двум
        # одновременным /link погасить один код для разных Telegram.
        c.execute("BEGIN IMMEDIATE")
        row = c.execute("SELECT * FROM gs_link_codes WHERE code=?", (code,)).fetchone()
        if not row:
            c.rollback()
            return False, "Код не найден. Сгенерируй новый на сайте.", 0
        if row["used_at"]:
            c.rollback()
            return False, "Код уже использован.", 0
        if now - int(row["created_at"]) > LINK_CODE_TTL:
            c.rollback()
            return False, "Код истёк, сгенерируй новый на сайте.", 0

        gs_user_id, gs_username = int(row["gs_user_id"]), row["gs_username"]
        existing_gs = c.execute("SELECT * FROM gs_links WHERE gs_user_id=?", (gs_user_id,)).fetchone()
        existing_tg = c.execute("SELECT * FROM gs_links WHERE tg_id=?", (tg_id,)).fetchone()
        if existing_gs and int(existing_gs["tg_id"]) != tg_id:
            c.rollback()
            return False, "Этот аккаунт GhostEcos уже привязан к другому Telegram. Сначала отвяжи его.", 0
        if existing_tg and int(existing_tg["gs_user_id"]) != gs_user_id:
            c.rollback()
            return False, "Этот Telegram уже привязан к аккаунту @%s. Сначала отвяжи его." % (
                existing_tg["gs_username"] or existing_tg["gs_user_id"],
            ), 0
        if not existing_gs:
            c.execute(
                "INSERT INTO gs_links (gs_user_id, gs_username, tg_id, created_at) VALUES (?,?,?,?)",
                (gs_user_id, gs_username, tg_id, now),
            )
        else:
            gs_username = existing_gs["gs_username"] or gs_username
        _upsert_bot_user_link(c, tg_id, gs_user_id, gs_username, now)
        c.execute("UPDATE gs_link_codes SET used_at=? WHERE code=? AND used_at IS NULL", (now, code))
        c.commit()
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

    moved = 0
    try:
        moved = merge_user_dir(gs_namespace_uid(gs_user_id), tg_id)
    except Exception:
        log.exception("merge_user_dir failed (gs=%s tg=%s)", gs_user_id, tg_id)
    return True, "Аккаунт @%s привязан к этому Telegram." % (gs_username or gs_user_id), moved


def link_code_status(gs_user_id: int) -> Optional[dict]:
    """Активный (непогашенный и не истёкший) код аккаунта — чтобы сайт после
    перезагрузки показал тот же код, а не сыпал новыми."""
    c = _link_db()
    row = c.execute(
        "SELECT * FROM gs_link_codes WHERE gs_user_id=? AND used_at IS NULL "
        "ORDER BY created_at DESC LIMIT 1",
        (int(gs_user_id),),
    ).fetchone()
    c.close()
    if not row:
        return None
    left = LINK_CODE_TTL - (int(time.time()) - int(row["created_at"]))
    if left <= 0:
        return None
    return {"code": row["code"], "expires_in": left}


# ── Перенос данных между namespace ────────────────────────────────────────────

def _users_dir() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "users")


def merge_user_dir(src_uid: int, dst_uid: int) -> int:
    """Перенести чаты (и память) из одного namespace в другой. Возвращает
    количество перенесённых чатов. Ничего не удаляет у получателя."""
    if int(src_uid) == int(dst_uid):
        return 0
    base = _users_dir()
    src_root = os.path.join(base, str(src_uid))
    dst_root = os.path.join(base, str(dst_uid))
    if not os.path.isdir(src_root):
        return 0

    src_chats = os.path.join(src_root, "chats")
    dst_chats = os.path.join(dst_root, "chats")
    moved = 0
    if os.path.isdir(src_chats):
        os.makedirs(dst_chats, exist_ok=True)
        for name in sorted(os.listdir(src_chats)):
            s = os.path.join(src_chats, name)
            if not os.path.isdir(s):
                continue
            target = name
            # chat_id = ms-timestamp, и ai.list_user_chats парсит его как число —
            # при коллизии сдвигаем на миллисекунду, а не приписываем суффикс.
            while os.path.exists(os.path.join(dst_chats, target)):
                try:
                    target = str(int(target) + 1)
                except ValueError:
                    target = target + "_moved"
            try:
                shutil.move(s, os.path.join(dst_chats, target))
                moved += 1
            except Exception:
                log.exception("не смог перенести чат %s (%s → %s)", name, src_uid, dst_uid)

    # memory.md — user-level: если у получателя своей нет, забираем; если есть,
    # дописываем в конец (терять то, что ИИ запомнил на сайте, не хочется).
    src_mem = os.path.join(src_root, "memory.md")
    dst_mem = os.path.join(dst_root, "memory.md")
    if os.path.isfile(src_mem):
        try:
            os.makedirs(dst_root, exist_ok=True)
            if not os.path.isfile(dst_mem):
                shutil.move(src_mem, dst_mem)
            else:
                with open(src_mem, "r", encoding="utf-8", errors="replace") as f:
                    extra = f.read().strip()
                if extra:
                    with open(dst_mem, "a", encoding="utf-8") as f:
                        f.write("\n\n<!-- перенесено с веб-аккаунта -->\n" + extra + "\n")
                os.remove(src_mem)
        except Exception:
            log.exception("не смог перенести memory.md (%s → %s)", src_uid, dst_uid)

    # Пустой каталог-источник убираем, непустой — оставляем как есть.
    try:
        if os.path.isdir(src_chats) and not os.listdir(src_chats):
            os.rmdir(src_chats)
        if os.path.isdir(src_root) and not os.listdir(src_root):
            os.rmdir(src_root)
    except Exception:
        pass
    return moved
