"""GhostRep: накопительная репутация аккаунта внутри домена сервиса."""
import sqlite3
import time
from typing import Any, Optional

# ── Константы шкалы ───────────────────────────────────────────────

START_SCORE = 1000.0
DAY_GAIN_CAP = 30.0
WEEK_GAIN_CAP = 100.0

DRIFT_SHARE = 0.05
DRIFT_STEP_CAP = 10.0
DRIFT_INTERVAL = 86400
ACTIVE_WINDOW = 7 * 86400

NEW_ACCOUNT_AGE = 7 * 86400
MIN_ACTOR_ACTIONS = 5
PAIR_DAY_CAP = 10.0

# Порог, код, название, вес голоса, постов в сутки, права
LEVELS = (
    {
        "min": 0, "key": "limited", "title": "Ограниченный", "weight": 0.5, "posts": 10,
        "rights": {
            "images": False, "groups": False, "links": False, "links_per_post": 0,
            "monetization": False, "moderation_vote": False, "themes": False,
            "priority": False,
        },
    },
    {
        "min": 1000, "key": "novice", "title": "Новичок", "weight": 1.0, "posts": 25,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": False, "moderation_vote": False, "themes": False,
            "priority": False,
        },
    },
    {
        "min": 1300, "key": "member", "title": "Участник", "weight": 1.5, "posts": 50,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": False, "moderation_vote": False, "themes": False,
            "priority": False,
        },
    },
    {
        "min": 1600, "key": "verified", "title": "Проверенный", "weight": 2.0, "posts": 100,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": False, "moderation_vote": False, "themes": False,
            "priority": False,
        },
    },
    {
        "min": 2000, "key": "reliable", "title": "Надёжный", "weight": 2.5, "posts": 200,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": True, "moderation_vote": False, "themes": False,
            "priority": False,
        },
    },
    {
        "min": 2500, "key": "trusted", "title": "Доверенный", "weight": 3.0, "posts": 300,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": True, "moderation_vote": True, "themes": True,
            "priority": False,
        },
    },
    {
        "min": 3000, "key": "elite", "title": "Элита", "weight": 3.5, "posts": None,
        "rights": {
            "images": True, "groups": True, "links": True, "links_per_post": 2,
            "monetization": True, "moderation_vote": True, "themes": True,
            "priority": True,
        },
    },
)


# ── Уровни ────────────────────────────────────────────────────────

def level_for(score: float) -> dict:
    """Уровень по очкам."""
    current = LEVELS[0]
    for item in LEVELS:
        if score >= item["min"]:
            current = item
    return dict(current)


def next_level(score: float) -> Optional[dict]:
    """Следующий уровень или None для элиты."""
    for item in LEVELS:
        if item["min"] > score:
            return dict(item)
    return None


def public_levels() -> list:
    """Пороги и права для фронта без хардкода."""
    return [dict(item) for item in LEVELS]


# ── Схема ─────────────────────────────────────────────────────────

def ensure_schema(c: sqlite3.Connection) -> None:
    """Создаёт таблицы GhostRep; вызывается из init() соцсети."""
    c.executescript("""
        CREATE TABLE IF NOT EXISTS rep_scores (
            user_id     INTEGER NOT NULL,
            domain      TEXT    NOT NULL,
            score       REAL    NOT NULL DEFAULT 1000,
            drift_at    INTEGER NOT NULL DEFAULT 0,
            day_gain    REAL    NOT NULL DEFAULT 0,
            day_key     TEXT    NOT NULL DEFAULT '',
            week_gain   REAL    NOT NULL DEFAULT 0,
            week_key    TEXT    NOT NULL DEFAULT '',
            updated_at  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (user_id, domain)
        );
        CREATE TABLE IF NOT EXISTS rep_events (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     INTEGER NOT NULL,
            domain      TEXT    NOT NULL,
            kind        TEXT    NOT NULL,
            delta       REAL    NOT NULL,
            actor_id    INTEGER,
            ref_type    TEXT,
            ref_id      INTEGER,
            reason      TEXT,
            created_at  INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rep_anomalies (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id     INTEGER NOT NULL,
            domain      TEXT    NOT NULL,
            kind        TEXT    NOT NULL,
            score_at    REAL    NOT NULL,
            detail      TEXT,
            created_at  INTEGER NOT NULL,
            resolved    INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_rep_events_user
            ON rep_events(user_id, domain, id DESC);
        CREATE INDEX IF NOT EXISTS idx_rep_events_actor
            ON rep_events(actor_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_rep_anomalies_open
            ON rep_anomalies(resolved, created_at);
    """)


# ── Счёт ──────────────────────────────────────────────────────────

def get_score(c: sqlite3.Connection, user_id: int, domain: str) -> float:
    """Счёт домена; при первом обращении создаёт запись."""
    row = c.execute(
        "SELECT score FROM rep_scores WHERE user_id=? AND domain=?", (user_id, domain)
    ).fetchone()
    if row:
        return float(row["score"])
    base = _legacy_base(c, user_id, domain)
    c.execute(
        "INSERT OR IGNORE INTO rep_scores (user_id, domain, score, updated_at) VALUES (?,?,?,?)",
        (user_id, domain, base, int(time.time())),
    )
    return base


def _legacy_base(c: sqlite3.Connection, user_id: int, domain: str) -> float:
    """Старая шкала 0–100 переводится в 1000 + (score − 100) × 10."""
    if domain != "social":
        return START_SCORE
    try:
        row = c.execute("SELECT reputation_score FROM users WHERE id=?", (user_id,)).fetchone()
    except sqlite3.OperationalError:
        return START_SCORE
    if not row or row["reputation_score"] is None:
        return START_SCORE
    return max(0.0, 1000.0 + (float(row["reputation_score"]) - 100.0) * 10.0)


def apply_rep_event(
    c: sqlite3.Connection,
    user_id: int,
    domain: str,
    kind: str,
    delta: float,
    actor_id: Optional[int] = None,
    ref_type: Optional[str] = None,
    ref_id: Optional[int] = None,
    reason: Optional[str] = None,
) -> float:
    """Начисляет очки и пишет событие. Транзакцию закрывает вызывающий."""
    get_score(c, user_id, domain)
    now = int(time.time())
    row = c.execute(
        "SELECT score, day_gain, day_key, week_gain, week_key FROM rep_scores "
        "WHERE user_id=? AND domain=?",
        (user_id, domain),
    ).fetchone()
    score = float(row["score"])
    day_key = _day_key(now)
    week_key = _week_key(now)
    day_gain = float(row["day_gain"]) if row["day_key"] == day_key else 0.0
    week_gain = float(row["week_gain"]) if row["week_key"] == week_key else 0.0

    applied = float(delta)
    if applied > 0:
        applied = min(applied, DAY_GAIN_CAP - day_gain, WEEK_GAIN_CAP - week_gain)
        applied = max(0.0, applied)
    applied = round(applied, 2)
    new_score = max(0.0, round(score + applied, 2))

    c.execute(
        "INSERT INTO rep_events "
        "(user_id, domain, kind, delta, actor_id, ref_type, ref_id, reason, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (user_id, domain, kind, applied, actor_id, ref_type, ref_id, reason, now),
    )
    c.execute(
        "UPDATE rep_scores SET score=?, day_gain=?, day_key=?, week_gain=?, week_key=?, "
        "updated_at=? WHERE user_id=? AND domain=?",
        (
            new_score,
            day_gain + max(0.0, applied),
            day_key,
            week_gain + max(0.0, applied),
            week_key,
            now,
            user_id,
            domain,
        ),
    )
    _sync_users_score(c, user_id, domain, new_score, now)
    return new_score


def _sync_users_score(
    c: sqlite3.Connection, user_id: int, domain: str, score: float, now: int
) -> None:
    """Кэш для старого профиля; общий для соцсети и чата, поэтому только social."""
    if domain != "social":
        return
    try:
        c.execute(
            "UPDATE users SET reputation_score=?, reputation_updated_at=? WHERE id=?",
            (int(round(score)), now, user_id),
        )
    except sqlite3.OperationalError:
        # Колонка updated_at появляется отдельной миграцией, кэш важнее
        try:
            c.execute(
                "UPDATE users SET reputation_score=? WHERE id=?",
                (int(round(score)), user_id),
            )
        except sqlite3.OperationalError:
            pass


# ── Дрейф к общему рейтингу ───────────────────────────────────────

def drift_if_due(
    c: sqlite3.Connection, user_id: int, domain: str, global_score: float
) -> float:
    """Подтягивает счёт к общему рейтингу не чаще раза в сутки."""
    score = get_score(c, user_id, domain)
    now = int(time.time())
    row = c.execute(
        "SELECT drift_at FROM rep_scores WHERE user_id=? AND domain=?", (user_id, domain)
    ).fetchone()
    drift_at = int(row["drift_at"] or 0) if row else 0
    if now - drift_at < DRIFT_INTERVAL:
        return score

    if not _active_recently(c, user_id, domain, now):
        c.execute(
            "UPDATE rep_scores SET drift_at=? WHERE user_id=? AND domain=?",
            (now, user_id, domain),
        )
        return score

    delta = (float(global_score) - score) * DRIFT_SHARE
    delta = max(-DRIFT_STEP_CAP, min(DRIFT_STEP_CAP, delta))
    delta = round(delta, 2)
    if abs(delta) < 0.01:
        c.execute(
            "UPDATE rep_scores SET drift_at=? WHERE user_id=? AND domain=?",
            (now, user_id, domain),
        )
        return score

    new_score = max(0.0, round(score + delta, 2))
    c.execute(
        "UPDATE rep_scores SET score=?, drift_at=?, updated_at=? "
        "WHERE user_id=? AND domain=?",
        (new_score, now, now, user_id, domain),
    )
    c.execute(
        "INSERT INTO rep_events "
        "(user_id, domain, kind, delta, actor_id, ref_type, ref_id, reason, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (user_id, domain, "drift", delta, None, None, None, None, now),
    )
    _sync_users_score(c, user_id, domain, new_score, now)
    return new_score


def _active_recently(c: sqlite3.Connection, user_id: int, domain: str, now: int) -> bool:
    row = c.execute(
        "SELECT 1 FROM rep_events WHERE user_id=? AND domain=? AND kind!='drift' "
        "AND created_at>=? LIMIT 1",
        (user_id, domain, now - ACTIVE_WINDOW),
    ).fetchone()
    return bool(row)


# ── Вес голоса и антинакрутка ─────────────────────────────────────

def reaction_weight(
    c: sqlite3.Connection,
    actor_id: int,
    target_id: int,
    domain: str = "social",
    actor_actions: Optional[int] = None,
) -> float:
    """Вес голоса: уровень, зрелость аккаунта и суточный вклад в пару."""
    if not actor_id or actor_id == target_id:
        return 0.0
    if _is_young(c, actor_id):
        return 0.0
    if _pair_gain_today(c, actor_id, target_id, domain) >= PAIR_DAY_CAP:
        return 0.0
    actions = actor_actions if actor_actions is not None else actor_actions_count(c, actor_id, domain)
    if actions < MIN_ACTOR_ACTIONS:
        return 0.0
    return float(level_for(get_score(c, actor_id, domain))["weight"])


def actor_actions_count(
    c: sqlite3.Connection, user_id: int, domain: str = "social"
) -> int:
    """Число реальных действий аккаунта в домене."""
    if domain != "social":
        row = c.execute(
            "SELECT COUNT(*) FROM rep_events WHERE actor_id=? AND domain=?", (user_id, domain)
        ).fetchone()
        return int(row[0] if row else 0)
    total = 0
    for table in ("soc_posts", "soc_comments", "soc_reactions"):
        try:
            row = c.execute(
                f"SELECT COUNT(*) FROM {table} WHERE user_id=?", (user_id,)
            ).fetchone()
            total += int(row[0] if row else 0)
        except sqlite3.OperationalError:
            continue
    return total


def _is_young(c: sqlite3.Connection, user_id: int) -> bool:
    try:
        row = c.execute("SELECT created_at FROM users WHERE id=?", (user_id,)).fetchone()
    except sqlite3.OperationalError:
        return False
    if not row or row["created_at"] is None:
        return False
    try:
        created = int(row["created_at"])
    except (TypeError, ValueError):
        return False
    return (int(time.time()) - created) < NEW_ACCOUNT_AGE


def _pair_gain_today(
    c: sqlite3.Connection, actor_id: int, target_id: int, domain: str
) -> float:
    row = c.execute(
        "SELECT COALESCE(SUM(delta), 0) FROM rep_events "
        "WHERE user_id=? AND actor_id=? AND domain=? AND delta>0 AND created_at>=?",
        (target_id, actor_id, domain, _day_start(int(time.time()))),
    ).fetchone()
    return float(row[0] if row else 0)


# ── Выборки ───────────────────────────────────────────────────────

def history(
    c: sqlite3.Connection, user_id: int, domain: str, limit: int = 20
) -> list:
    rows = c.execute(
        "SELECT kind, delta, actor_id, ref_type, ref_id, reason, created_at "
        "FROM rep_events WHERE user_id=? AND domain=? ORDER BY id DESC LIMIT ?",
        (user_id, domain, limit),
    ).fetchall()
    return [dict(row) for row in rows]


def leaderboard(
    c: sqlite3.Connection, domain: str, period: str = "all", limit: int = 50
) -> list:
    if period == "30d":
        start = int(time.time()) - 30 * 86400
        rows = c.execute(
            "SELECT user_id, SUM(delta) AS score FROM rep_events "
            "WHERE domain=? AND created_at>=? GROUP BY user_id "
            "HAVING score>0 ORDER BY score DESC LIMIT ?",
            (domain, start, limit),
        ).fetchall()
    else:
        rows = c.execute(
            "SELECT user_id, score FROM rep_scores WHERE domain=? "
            "ORDER BY score DESC LIMIT ?",
            (domain, limit),
        ).fetchall()
    return [dict(row) for row in rows]


# ── Время ─────────────────────────────────────────────────────────

def _day_start(now: int) -> int:
    return now - (now % 86400)


def _day_key(now: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(now))


def _week_key(now: int) -> str:
    return time.strftime("%Y-W%W", time.gmtime(now))
