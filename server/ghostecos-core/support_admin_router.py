# Панель поддержки (support_admin.html локально на ПК у Waki) — список
# диалогов с системным аккаунтом @support + переписка + ответ.
# Тот же паттерн auth, что у /admin/stats в social_router.py: обычный JWT
# (Authorization: Bearer ...) + _is_admin_user() — никакого отдельного
# X-Admin-Key (тот механизм в dependencies.py существует, но никогда не был
# подключён ни к одному роуту и ADMIN_TOKEN даже не сконфигурирован).
from typing import Optional
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ecos_core.identity import db
from ecos_core.client import auth_member
from ecos_core.shared import _is_admin_user
from chat_router import _deliver_message

router = APIRouter(prefix="/api/support-admin", tags=["support-admin"])

SUPPORT_USERNAME = "support"


def _support_row(c):
    row = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (SUPPORT_USERNAME,)).fetchone()
    if not row:
        raise HTTPException(500, "Аккаунт @support не провижинен")
    return row


def _require_admin(authorization: Optional[str]):
    user = auth_member(authorization)
    if not _is_admin_user(user):
        raise HTTPException(403, "Только для администратора")
    return user


@router.get("/threads")
def list_threads(authorization: Optional[str] = Header(None)):
    """Все, кто хоть раз писал @support ИЛИ кому @support писал — с последним
    сообщением и непрочитанными (сообщения ОТ юзера К support, is_read=0)."""
    _require_admin(authorization)
    c = db()
    support = _support_row(c)
    sid = support["id"]
    rows = c.execute(
        """
        SELECT u.username, u.display_name,
               (SELECT text FROM chat_dm
                 WHERE (sender_id=u.id AND receiver_id=?) OR (sender_id=? AND receiver_id=u.id)
                 ORDER BY id DESC LIMIT 1) AS last_text,
               (SELECT created_at FROM chat_dm
                 WHERE (sender_id=u.id AND receiver_id=?) OR (sender_id=? AND receiver_id=u.id)
                 ORDER BY id DESC LIMIT 1) AS last_at,
               (SELECT COUNT(*) FROM chat_dm WHERE sender_id=u.id AND receiver_id=? AND is_read=0) AS unread
          FROM users u
         WHERE u.id IN (
                SELECT sender_id FROM chat_dm WHERE receiver_id=?
                UNION
                SELECT receiver_id FROM chat_dm WHERE sender_id=?
               )
         ORDER BY last_at DESC LIMIT 500
        """,
        (sid, sid, sid, sid, sid, sid, sid),
    ).fetchall()
    c.close()
    return {
        "threads": [
            {
                "username": r["username"],
                "display_name": r["display_name"] or r["username"],
                "last_text": r["last_text"],
                "last_at": r["last_at"],
                "unread": r["unread"],
            }
            for r in rows
        ]
    }


@router.get("/thread/{username}")
def get_thread(username: str, authorization: Optional[str] = Header(None)):
    _require_admin(authorization)
    c = db()
    support = _support_row(c)
    sid = support["id"]
    peer = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (username.lower(),)).fetchone()
    if not peer:
        c.close()
        raise HTTPException(404, "Пользователь не найден")
    rows = c.execute(
        """
        SELECT id, sender_id, text, created_at FROM chat_dm
         WHERE (sender_id=? AND receiver_id=?) OR (sender_id=? AND receiver_id=?)
         ORDER BY id ASC LIMIT 2000
        """,
        (peer["id"], sid, sid, peer["id"]),
    ).fetchall()
    # Отметить прочитанным то, что юзер прислал нам.
    c.execute("UPDATE chat_dm SET is_read=1 WHERE sender_id=? AND receiver_id=? AND is_read=0", (peer["id"], sid))
    c.commit()
    c.close()
    return {
        "peer": {"username": peer["username"], "display_name": peer["display_name"] or peer["username"]},
        "messages": [
            {
                "id": r["id"],
                "from_support": r["sender_id"] == sid,
                "text": r["text"],
                "created_at": r["created_at"],
            }
            for r in rows
        ],
    }


class ReplyBody(BaseModel):
    to_username: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=4000)


@router.post("/reply")
def reply(body: ReplyBody, authorization: Optional[str] = Header(None)):
    _require_admin(authorization)
    text = body.text.strip()
    if not text:
        raise HTTPException(422, "Пустой текст")
    c = db()
    support = _support_row(c)
    peer = c.execute("SELECT id, username, display_name FROM users WHERE username=?", (body.to_username.lower(),)).fetchone()
    if not peer:
        c.close()
        raise HTTPException(404, "Пользователь не найден")
    result = _deliver_message(c, dict(support), dict(peer), ciphertext=None, plain_text=text)
    c.close()
    return result
