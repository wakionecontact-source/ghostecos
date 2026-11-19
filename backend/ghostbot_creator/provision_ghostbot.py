"""Одноразовый провижининг системного бота @ghostbot (аналог BotFather).
В отличие от обычных ботов у него нет владельца-человека — сам себе owner.
Запускать один раз на сервере: python3 provision_ghostbot.py
"""
import sys
import time
import secrets

sys.path.insert(0, "/opt/ghostchat")
from social_router import db, hash_argon2  # noqa: E402

USERNAME = "ghostbot"
DISPLAY_NAME = "GhostBot"


def main():
    c = db()
    existing = c.execute("SELECT id FROM users WHERE username=?", (USERNAME,)).fetchone()
    if existing:
        print(f"@{USERNAME} уже существует (id={existing['id']}) — провижининг пропущен.")
        print("Если нужно перевыпустить токен — используй POST /api/bots/{id}/regenerate от имени владельца,")
        print("либо вручную обнови bots.token_hash.")
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
        (uid, uid, hash_argon2(token), now),  # owner_id = сам себе (системный бот)
    )
    c.commit()
    c.close()

    secrets_path = "/opt/ghostchat/ghostbot_creator/ghostbot_secrets.env"
    with open(secrets_path, "w") as f:
        f.write(f"GHOSTBOT_TOKEN={token}\n")
    import os
    os.chmod(secrets_path, 0o600)
    print(f"@{USERNAME} создан (id={uid}). Токен сохранён в {secrets_path} (chmod 600).")


if __name__ == "__main__":
    main()
