"""Одноразовый провижининг системного бота @support (для чата поддержки).
Сам себе owner, как @ghostbot. Никакого runner'а не нужно — сообщения ему
читает/отвечает Waki через support-панель (не автоматический бот).
Запускать один раз на сервере: python3 provision_support_bot.py
"""
import sys
import time
import secrets

sys.path.insert(0, "/opt/ghostchat")
from social_router import db, hash_argon2  # noqa: E402

USERNAME = "support"
DISPLAY_NAME = "Поддержка GhostChat"


def main():
    c = db()
    existing = c.execute("SELECT id FROM users WHERE username=?", (USERNAME,)).fetchone()
    if existing:
        print(f"@{USERNAME} уже существует (id={existing['id']}) — провижининг пропущен.")
        c.close()
        return

    now = int(time.time())
    c.execute(
        "INSERT INTO users (username, display_name, account_type, in_ghostchat, created_at) VALUES (?,?,?,?,?)",
        (USERNAME, DISPLAY_NAME, "bot", 0, now),
    )
    uid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    token = secrets.token_urlsafe(32)
    c.execute(
        "INSERT INTO bots (user_id, owner_id, token_hash, created_at) VALUES (?,?,?,?)",
        (uid, uid, hash_argon2(token), now),
    )
    c.commit()
    c.close()
    print(f"@{USERNAME} создан (id={uid}). Токен боту не нужен для панели поддержки (отправка идёт напрямую по owner-правам администратора).")


if __name__ == "__main__":
    main()
