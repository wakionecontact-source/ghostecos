"""Delete a GhostEcos account and its cross-product data from Core."""
import os
import secrets
import time
from typing import Optional
from fastapi import HTTPException
from pydantic import BaseModel

from ecos_core.credentials import verify_user_password
from ecos_core.identity import auth_member, db
from ecos_core.login import _consume_password_challenge
from ecos_core.shared import _rate_limit

GHOSTECOS_USERNAME = 'ghostecos'


class DeleteAccountBody(BaseModel):
    password: Optional[str] = None  # legacy APK/web confirmation
    challenge_id: Optional[str] = None
    proof: Optional[str] = None


def delete_my_account(body: DeleteAccountBody, authorization: Optional[str]):
    """Полное удаление аккаунта.
    Передаёт wallet-балансы и NFT системному пользователю GhostEcos,
    добавляет username в cooldown на 30 дней, стирает посты/комменты/реакции/follow.
    """
    if not body.challenge_id and not body.proof and not body.password:
        raise HTTPException(422, "Password confirmation is required")
    if bool(body.challenge_id) != bool(body.proof):
        raise HTTPException(422, "Incomplete password proof")
    user = auth_member(authorization)
    _rate_limit(f"delacc:{user['id']}", limit=3, window=3600)
    if body.challenge_id and body.proof:
        c = db()
        try:
            _consume_password_challenge(
                c, body.challenge_id, body.proof, "delete_account", user_id=user["id"],
            )
        finally:
            c.close()
    elif not body.password or not verify_user_password(body.password, user):
        raise HTTPException(401, "Неверный пароль")
    if (user.get("username") or "") == GHOSTECOS_USERNAME:
        raise HTTPException(403, "Системный аккаунт нельзя удалить")

    uid = user["id"]
    uname = (user["username"] or "").lower()
    now = int(time.time())
    c = db()
    try:
        c.execute("BEGIN IMMEDIATE")
        sys_row = c.execute("SELECT id FROM users WHERE username=?", (GHOSTECOS_USERNAME,)).fetchone()
        sys_uid = sys_row["id"] if sys_row else None

        if sys_uid:
            c.execute("UPDATE soc_nfts SET owner_id=? WHERE owner_id=?", (sys_uid, uid))
            c.execute("DELETE FROM soc_nft_listings WHERE seller_id=?", (uid,))
            try:
                w = c.execute("SELECT gost, soul, prem FROM soc_wallets WHERE user_id=?", (uid,)).fetchone()
                if w:
                    gost = int(w["gost"] or 0); soul = int(w["soul"] or 0); prem = int(w["prem"] or 0)
                    if gost or soul or prem:
                        c.execute("UPDATE soc_wallets SET gost=0, soul=0, prem=0 WHERE user_id=?", (uid,))
                        c.execute(
                            "UPDATE soc_wallets SET gost=gost+?, soul=soul+?, prem=prem+? WHERE user_id=?",
                            (gost, soul, prem, sys_uid),
                        )
                        # Логируем для аудита (если есть таблица wallet_tx)
                        try:
                            c.execute(
                                "INSERT INTO soc_wallet_tx (user_id, kind, currency, amount, reason, created_at) "
                                "VALUES (?,?,?,?,?,?)",
                                (uid, 'account_deleted', 'gost', -gost, 'transfer_to_system', now),
                            )
                        except Exception:
                            pass
            except Exception:
                pass

        c.execute(
            "DELETE FROM soc_reactions WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
        )
        c.execute("DELETE FROM soc_reactions WHERE user_id=?", (uid,))
        c.execute("DELETE FROM soc_comments WHERE user_id=?", (uid,))
        c.execute(
            "DELETE FROM soc_comments WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
        )
        try:
            c.execute("DELETE FROM soc_poll_votes WHERE user_id=?", (uid,))
            c.execute(
                "DELETE FROM soc_polls WHERE post_id IN (SELECT id FROM soc_posts WHERE user_id=?)", (uid,)
            )
        except Exception:
            pass
        c.execute("DELETE FROM soc_posts WHERE user_id=?", (uid,))
        c.execute("DELETE FROM soc_follows WHERE follower_id=? OR followee_id=?", (uid, uid))
        try:
            c.execute("DELETE FROM soc_notifications WHERE user_id=? OR actor_id=?", (uid, uid))
        except Exception:
            pass
        try:
            c.execute("DELETE FROM chat_dm WHERE from_id=? OR to_id=?", (uid, uid))
            c.execute("DELETE FROM chat_contacts WHERE user_id=? OR contact_id=?", (uid, uid))
            c.execute("DELETE FROM chat_group_members WHERE user_id=?", (uid,))
            c.execute("DELETE FROM chat_group_acks WHERE user_id=?", (uid,))
            c.execute("DELETE FROM chat_group_join_requests WHERE user_id=?", (uid,))
        except Exception:
            pass
        try:
            c.execute(
                "DELETE FROM chat_dm_call_history WHERE sender_id=? OR receiver_id=?",
                (uid, uid),
            )
        except Exception:
            pass
        try:
            c.execute("DELETE FROM soc_moderator_applications WHERE user_id=?", (uid,))
            c.execute("DELETE FROM soc_overwatch_votes WHERE moderator_id=?", (uid,))
        except Exception:
            pass
        c.execute("DELETE FROM soc_tokens WHERE user_id=?", (uid,))
        c.execute("DELETE FROM soc_auth_challenges WHERE user_id=?", (uid,))

        try:
            owned_unames = [r["username"] for r in c.execute(
                "SELECT username FROM soc_usernames WHERE owner_id=?", (uid,)
            ).fetchall()]
            for un in owned_unames:
                c.execute(
                    "INSERT OR REPLACE INTO soc_username_cooldown (username, released_at, prev_user_id, reason) "
                    "VALUES (?,?,?,?)",
                    (un.lower(), now + 30 * 86400, uid, 'account_deleted'),
                )
            c.execute("DELETE FROM soc_usernames WHERE owner_id=?", (uid,))
        except Exception:
            pass

        if uname:
            c.execute(
                "INSERT OR REPLACE INTO soc_username_cooldown (username, released_at, prev_user_id, reason) "
                "VALUES (?,?,?,?)",
                (uname, now + 30 * 86400, uid, 'account_deleted'),
            )

        try: c.execute("DELETE FROM soc_wallets WHERE user_id=?", (uid,))
        except Exception: pass
        try: c.execute("DELETE FROM gc_public_handles WHERE owner_type='user' AND owner_id=?", (uid,))
        except Exception: pass
        c.execute("DELETE FROM users WHERE id=?", (uid,))

        c.commit()
        _nation_token = os.getenv("NATION_INTERNAL_TOKEN")
        if _nation_token and uname:
            try:
                import urllib.request, urllib.error
                req = urllib.request.Request(
                    f"http://127.0.0.1:8010/api/nation/archive/{uname}",
                    method="POST",
                    headers={"X-Internal-Token": _nation_token},
                )
                urllib.request.urlopen(req, timeout=3).read()
            except Exception:
                pass  # GhostNation может быть offline — не критично, страна останется orphaned
    except Exception as e:
        c.rollback()
        c.close()
        raise HTTPException(500, f"Ошибка удаления: {e}")
    c.close()
    return {"status": "ok", "deleted": True, "username_freed_in_days": 30}
