"""GhostEcos wallet reward rules shared by product routes and account creation."""
import sqlite3
from typing import Optional
from ecos_core.identity import db
from ecos_core.realtime import ws_hub


GOST_REWARDS = {
    'register':  100,   # one-time welcome bonus
    'daily':      10,   # раз в 24ч
    'post':        5,   # за свой пост
    'react':       1,   # автор поста — за чужой лайк
    'comment':     2,   # автор поста — за чужой коммент
    'follow':      5,   # юзер — за нового подписчика
    'refout':     10,   # пригласителю — за приведённого юзера
    'refin':      30,   # приглашённому — welcome bonus сверх register
}


GOST_DAILY_CAP = {
    'post':     25,    # ≈ 5 постов в день максимум засчитано
    'react':    50,    # ≈ 50 лайков на свои посты
    'comment':  60,    # ≈ 30 комментов
    'follow':   25,    # ≈ 5 новых фолловеров
    'refout':   100,   # ≈ 10 рефералов в день засчитано (anti-spam)
}


DAILY_CLAIM_INTERVAL = 24 * 3600


ALLOWED_CURRENCIES = {'gost', 'soul', 'prem'}


def _ensure_wallet(c, user_id: int) -> None:
    """Гарантирует наличие строки wallet (для join'ов и обновлений)."""
    c.execute("INSERT OR IGNORE INTO soc_wallets (user_id) VALUES (?)", (user_id,))


def get_balance(user_id: int) -> dict:
    """Возвращает баланс юзера. Все три валюты — всегда возвращаем (нули если нет записи)."""
    c = db()
    row = c.execute(
        "SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (user_id,)
    ).fetchone()
    c.close()
    return {
        "gost": (row["gost"] if row else 0),
        "soul": (row["soul"] if row else 0),
        "prem": (row["prem"] if row else 0),
    }


def _sum_source_24h(c, user_id: int, source: str) -> int:
    """Сколько начислено за последние 24ч по этому источнику (для cap-чека)."""
    row = c.execute(
        "SELECT COALESCE(SUM(delta), 0) as s FROM soc_wallet_tx "
        "WHERE user_id=? AND source=? AND delta>0 "
        "AND created_at > datetime('now', '-1 day')",
        (user_id, source),
    ).fetchone()
    return row["s"] or 0


def award_gost(
    user_id: int,
    source: str,
    actor_id: int = 0,
    ref_type: str = '',
    ref_id: int = 0,
    amount_override: Optional[int] = None,
) -> dict:
    """Начисляет gost за активность. Атомарно. Возвращает {credited, new_balance, reason}.

    Дедуп: для source ∈ {register, post, react, comment, follow} —
    UNIQUE индекс на (user_id, source, actor_id, ref_type, ref_id) не даст начислить дважды.
    daily — отдельный check по времени.
    Cap per-day по источнику — мягкий cap (выше cap'а просто не начисляется, без ошибки).
    """
    if user_id <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "guest"}
    if source not in GOST_REWARDS and amount_override is None:
        return {"credited": 0, "new_balance": 0, "reason": "unknown_source"}
    amount = amount_override if amount_override is not None else GOST_REWARDS[source]
    if amount <= 0:
        return {"credited": 0, "new_balance": 0, "reason": "zero"}

    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        _ensure_wallet(c, user_id)

        if source == 'daily':
            last = c.execute(
                "SELECT created_at FROM soc_wallet_tx "
                "WHERE user_id=? AND source='daily' "
                "ORDER BY id DESC LIMIT 1",
                (user_id,),
            ).fetchone()
            if last:
                age = c.execute(
                    "SELECT strftime('%s','now') - strftime('%s', ?) as age",
                    (last["created_at"],),
                ).fetchone()["age"]
                if (age or 0) < DAILY_CLAIM_INTERVAL:
                    c.execute("ROLLBACK")
                    c.close()
                    return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "too_soon"}

        if source in GOST_DAILY_CAP:
            already = _sum_source_24h(c, user_id, source)
            if already >= GOST_DAILY_CAP[source]:
                c.execute("ROLLBACK")
                c.close()
                return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "daily_cap"}
            if already + amount > GOST_DAILY_CAP[source]:
                amount = GOST_DAILY_CAP[source] - already

        # Запись tx (UNIQUE index блокирует дубль — IntegrityError)
        try:
            c.execute(
                "INSERT INTO soc_wallet_tx (user_id, currency, delta, source, actor_id, ref_type, ref_id) "
                "VALUES (?, 'gost', ?, ?, ?, ?, ?)",
                (user_id, amount, source, actor_id, ref_type, ref_id),
            )
        except sqlite3.IntegrityError:
            c.execute("ROLLBACK")
            c.close()
            return {"credited": 0, "new_balance": get_balance(user_id)["gost"], "reason": "already_credited"}

        c.execute(
            "UPDATE soc_wallets SET gost = gost + ?, updated_at = CURRENT_TIMESTAMP WHERE user_id=?",
            (amount, user_id),
        )
        new_bal = c.execute("SELECT gost FROM soc_wallets WHERE user_id=?", (user_id,)).fetchone()["gost"]
        c.execute("COMMIT")
    except Exception:
        try: c.execute("ROLLBACK")
        except Exception: pass
        c.close()
        raise
    c.close()
    ws_hub.send_to(user_id, "wallet.credit", {
        "currency": "gost", "delta": amount, "source": source,
        "balance": new_bal,
    })
    return {"credited": amount, "new_balance": new_bal, "reason": "ok"}
