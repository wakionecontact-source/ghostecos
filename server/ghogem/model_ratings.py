import os
import secrets
import sqlite3
import time

DB_PATH = os.environ.get(
    "GHOGEM_MODEL_RATINGS_DB",
    "/var/lib/ghogem-app/model_ratings.db",
)


def _connect():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def _init():
    conn = _connect()
    try:
        conn.executescript("""
        CREATE TABLE IF NOT EXISTS model_responses (
            token TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            telegram_chat_id INTEGER NOT NULL,
            telegram_message_id INTEGER,
            ai_chat_id TEXT NOT NULL,
            answer_id TEXT,
            model_key TEXT NOT NULL,
            score INTEGER CHECK(score BETWEEN 1 AND 5),
            required INTEGER NOT NULL DEFAULT 0,
            skipped INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            rated_at INTEGER,
            skipped_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_model_responses_user
            ON model_responses(user_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_model_responses_model
            ON model_responses(model_key, rated_at);
        CREATE INDEX IF NOT EXISTS idx_model_responses_rated_model
            ON model_responses(model_key, score) WHERE score IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_model_responses_pending
            ON model_responses(user_id, required, score, skipped);
        CREATE TABLE IF NOT EXISTS model_rating_votes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            response_token TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            model_key TEXT NOT NULL,
            score INTEGER NOT NULL CHECK(score BETWEEN 1 AND 5),
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_model_rating_votes_model
            ON model_rating_votes(model_key, created_at);
        """)
        conn.commit()
    finally:
        conn.close()


def _token():
    return secrets.token_hex(6)


def create_response(user_id, telegram_chat_id, ai_chat_id, answer_id, model_key, required=False):
    token = _token()
    conn = _connect()
    try:
        conn.execute(
            """INSERT INTO model_responses
               (token,user_id,telegram_chat_id,ai_chat_id,answer_id,model_key,required,created_at)
               VALUES (?,?,?,?,?,?,?,?)""",
            (token, int(user_id), int(telegram_chat_id), str(ai_chat_id),
             str(answer_id or ""), str(model_key), 1 if required else 0, int(time.time())),
        )
        conn.commit()
        return token
    finally:
        conn.close()


def attach_message(token, user_id, message_id):
    conn = _connect()
    try:
        conn.execute(
            "UPDATE model_responses SET telegram_message_id=? WHERE token=? AND user_id=?",
            (int(message_id), str(token), int(user_id)),
        )
        conn.commit()
    finally:
        conn.close()


def get(token, user_id):
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT * FROM model_responses WHERE token=? AND user_id=?",
            (str(token), int(user_id)),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def submit(token, user_id, score):
    score = int(score)
    if score < 1 or score > 5:
        raise ValueError("Оценка должна быть от 1 до 5")
    conn = _connect()
    try:
        now = int(time.time())
        row = conn.execute(
            "SELECT model_key FROM model_responses WHERE token=? AND user_id=?",
            (str(token), int(user_id)),
        ).fetchone()
        if not row:
            return False
        conn.execute(
            """UPDATE model_responses
               SET score=?, rated_at=?, skipped=0, skipped_at=NULL
               WHERE token=? AND user_id=?""",
            (score, now, str(token), int(user_id)),
        )
        conn.execute(
            """INSERT INTO model_rating_votes
               (response_token,user_id,model_key,score,created_at)
               VALUES (?,?,?,?,?)""",
            (str(token), int(user_id), str(row["model_key"]), score, now),
        )
        conn.commit()
        return True
    finally:
        conn.close()


def skip(token, user_id):
    conn = _connect()
    try:
        cur = conn.execute(
            """UPDATE model_responses
               SET skipped=1, skipped_at=?
               WHERE token=? AND user_id=? AND score IS NULL""",
            (int(time.time()), str(token), int(user_id)),
        )
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def pending_required(user_id):
    conn = _connect()
    try:
        row = conn.execute(
            """SELECT * FROM model_responses
               WHERE user_id=? AND required=1 AND score IS NULL AND skipped=0
               ORDER BY created_at DESC LIMIT 1""",
            (int(user_id),),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def user_rating_state(user_id):
    conn = _connect()
    try:
        last = conn.execute(
            """SELECT rated_at,score,model_key FROM model_responses
               WHERE user_id=? AND rated_at IS NOT NULL
               ORDER BY rated_at DESC LIMIT 1""",
            (int(user_id),),
        ).fetchone()
        last_rated = int(last["rated_at"]) if last else 0
        if last_rated:
            since = conn.execute(
                "SELECT COUNT(*) FROM model_responses WHERE user_id=? AND created_at>?",
                (int(user_id), last_rated),
            ).fetchone()[0]
        else:
            since = conn.execute(
                "SELECT COUNT(*) FROM model_responses WHERE user_id=?",
                (int(user_id),),
            ).fetchone()[0]
        last_required = conn.execute(
            "SELECT MAX(created_at) FROM model_responses WHERE user_id=? AND required=1",
            (int(user_id),),
        ).fetchone()[0] or 0
        total_ratings = conn.execute(
            "SELECT COUNT(*) FROM model_responses WHERE user_id=? AND rated_at IS NOT NULL",
            (int(user_id),),
        ).fetchone()[0]
        return {
            "last_rated_at": last_rated,
            "last_score": int(last["score"]) if last else None,
            "last_model_key": str(last["model_key"]) if last else "",
            "responses_since_rating": int(since),
            "last_required_at": int(last_required),
            "total_ratings": int(total_ratings),
        }
    finally:
        conn.close()


def model_stats(model_key):
    conn = _connect()
    try:
        row = conn.execute(
            """SELECT COUNT(score) AS votes, AVG(score) AS average,
                      SUM(CASE WHEN score=1 THEN 1 ELSE 0 END) AS s1,
                      SUM(CASE WHEN score=2 THEN 1 ELSE 0 END) AS s2,
                      SUM(CASE WHEN score=3 THEN 1 ELSE 0 END) AS s3,
                      SUM(CASE WHEN score=4 THEN 1 ELSE 0 END) AS s4,
                      SUM(CASE WHEN score=5 THEN 1 ELSE 0 END) AS s5
               FROM model_responses WHERE model_key=? AND score IS NOT NULL""",
            (str(model_key),),
        ).fetchone()
        return dict(row) if row else {}
    finally:
        conn.close()


def model_ranking():
    """Aggregate the current saved score for each response into a global ranking."""
    conn = _connect()
    try:
        rows = conn.execute(
            """SELECT model_key, COUNT(*) AS votes, AVG(score) AS average,
                      SUM(CASE WHEN score=1 THEN 1 ELSE 0 END) AS s1,
                      SUM(CASE WHEN score=2 THEN 1 ELSE 0 END) AS s2,
                      SUM(CASE WHEN score=3 THEN 1 ELSE 0 END) AS s3,
                      SUM(CASE WHEN score=4 THEN 1 ELSE 0 END) AS s4,
                      SUM(CASE WHEN score=5 THEN 1 ELSE 0 END) AS s5
               FROM model_responses
               WHERE score IS NOT NULL
               GROUP BY model_key
               ORDER BY average DESC, votes DESC, model_key COLLATE NOCASE ASC"""
        ).fetchall()
        result = []
        for rank, row in enumerate(rows, 1):
            item = dict(row)
            item["rank"] = rank
            item["distribution"] = [int(item.get(f"s{i}") or 0) for i in range(1, 6)]
            result.append(item)
        return result
    finally:
        conn.close()


_init()
