"""Награды кошелька идут через доверенный Core API и идемпотентны."""
import os
import sqlite3


def test_social_wallet_reward_is_issued_by_core(reg_user):
    from social_router import award_gost

    user = reg_user(username="core_wallet_reward")
    first = award_gost(user["id"], "post", ref_type="post", ref_id=50001)
    again = award_gost(user["id"], "post", ref_type="post", ref_id=50001)
    assert first["credited"] == 5
    assert again["credited"] == 0
    with sqlite3.connect(os.environ["SOCIAL_DB_PATH"]) as conn:
        balance = conn.execute(
            "SELECT gost FROM soc_wallets WHERE user_id=?", (user["id"],),
        ).fetchone()[0]
    assert balance == 105
