"""
OKey — интерактивная консоль.

Работает напрямую с okey.db (та же база, что использует bot.py) —
никакого aiogram тут нет, только sqlite и простые HTTP-запросы к
Telegram Bot API (для рассылки).

Можно запускать отдельно (python console.py) — тогда это просто
инструмент статистики без управления ботом. Обычно же её открывает
main.py вместе с ботом.
"""
import json
import os
import sqlite3
import time
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).parent
DB_PATH = BASE_DIR / "okey.db"
BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
PROXY_URL = os.getenv("PROXY_URL", "").strip() or None


def db() -> sqlite3.Connection:
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c


# ── Статистика ───────────────────────────────────────────────────────────────
def stats() -> None:
    with db() as c:
        total = c.execute("SELECT COUNT(*) FROM users WHERE name IS NOT NULL").fetchone()[0]
        by_gender = c.execute(
            "SELECT gender, COUNT(*) FROM users WHERE name IS NOT NULL GROUP BY gender"
        ).fetchall()
        likes_total = c.execute("SELECT COUNT(*) FROM likes WHERE action='like'").fetchone()[0]
        skips_total = c.execute("SELECT COUNT(*) FROM likes WHERE action='skip'").fetchone()[0]
        # Матч = взаимный лайк. Считаем каждую пару один раз (from_id < to_id).
        matches = c.execute(
            """SELECT COUNT(*) FROM likes a
               JOIN likes b ON a.from_id = b.to_id AND a.to_id = b.from_id
               WHERE a.action = 'like' AND b.action = 'like' AND a.from_id < a.to_id"""
        ).fetchone()[0]
        day_ago = int(time.time()) - 86400
        new_24h = c.execute(
            "SELECT COUNT(*) FROM users WHERE name IS NOT NULL AND created_at >= ?",
            (day_ago,),
        ).fetchone()[0]

    print("\n📊  СТАТИСТИКА OKey")
    print("─" * 40)
    print(f"👥 Всего анкет:        {total}")
    gender_labels = {"m": "👨 Парни", "f": "👩 Девушки"}
    for g, n in by_gender:
        print(f"   {gender_labels.get(g, '❓ Без пола')}: {n}")
    print(f"💚 Лайков поставлено:  {likes_total}")
    print(f"👎 Скипов:             {skips_total}")
    print(f"🎉 Матчей:             {matches}")
    print(f"🆕 Новых за 24ч:       {new_24h}")
    print("─" * 40)


def list_recent(n: int = 10) -> None:
    with db() as c:
        rows = c.execute(
            """SELECT tg_id, username, name, age, gender, created_at FROM users
               WHERE name IS NOT NULL ORDER BY created_at DESC LIMIT ?""",
            (n,),
        ).fetchall()
    print(f"\n👥 Последние {len(rows)} анкет:")
    print("─" * 60)
    for r in rows:
        dt = datetime.fromtimestamp(r["created_at"]).strftime("%d.%m %H:%M")
        uname = f"@{r['username']}" if r["username"] else "—"
        age = r["age"] if r["age"] is not None else "?"
        print(f"  {dt}  {r['name']:<15} {age!s:<3} {uname}")
    print("─" * 60)


def find_user() -> None:
    q = input("Введи tg_id или username (без @): ").strip().lstrip("@")
    with db() as c:
        if q.isdigit():
            r = c.execute("SELECT * FROM users WHERE tg_id=?", (int(q),)).fetchone()
        else:
            r = c.execute("SELECT * FROM users WHERE username=?", (q,)).fetchone()
    if not r:
        print("❌ Не найден.")
        return
    print("\n" + "─" * 40)
    for k in r.keys():
        print(f"  {k}: {r[k]}")
    print("─" * 40)


def delete_user() -> None:
    q = input("tg_id юзера для удаления: ").strip()
    if not q.isdigit():
        print("❌ Нужен числовой tg_id.")
        return
    tg_id = int(q)
    with db() as c:
        r = c.execute("SELECT name FROM users WHERE tg_id=?", (tg_id,)).fetchone()
        if not r:
            print("❌ Юзер не найден.")
            return
        confirm = input(f"Точно удалить «{r['name']}» (tg_id={tg_id})? (да/нет): ").strip().lower()
        if confirm not in ("да", "yes", "y"):
            print("Отменено.")
            return
        c.execute("DELETE FROM users WHERE tg_id=?", (tg_id,))
        c.execute("DELETE FROM likes WHERE from_id=? OR to_id=?", (tg_id, tg_id))
    print("✅ Удалено.")


# ── Рассылка через Telegram Bot API (без aiogram, простой HTTP-запрос) ──────
def _tg_call(method: str, params: dict) -> dict:
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(url, data=data)
    if PROXY_URL and PROXY_URL.startswith("http"):
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": PROXY_URL, "http": PROXY_URL})
        )
    else:
        opener = urllib.request.build_opener()
    with opener.open(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


def broadcast() -> None:
    if not BOT_TOKEN:
        print("❌ BOT_TOKEN не найден в .env.")
        return
    if PROXY_URL and not PROXY_URL.startswith("http"):
        print("⚠️  В .env указан SOCKS-прокси — рассылка из консоли (urllib)")
        print("   умеет только HTTP(S)-прокси. Если у тебя включен системный")
        print("   VPN в TUN-режиме — не страшно, просто жми дальше, сработает.")
    text = input("Текст рассылки:\n> ").strip()
    if not text:
        print("Пусто, отменено.")
        return
    with db() as c:
        ids = [r[0] for r in c.execute(
            "SELECT tg_id FROM users WHERE name IS NOT NULL"
        ).fetchall()]
    confirm = input(f"Разослать {len(ids)} юзерам? (да/нет): ").strip().lower()
    if confirm not in ("да", "yes", "y"):
        print("Отменено.")
        return
    ok, fail = 0, 0
    for tg_id in ids:
        try:
            _tg_call("sendMessage", {"chat_id": tg_id, "text": text})
            ok += 1
        except Exception:
            fail += 1
        time.sleep(0.05)  # не долбить Telegram rate-limit
    print(f"✅ Отправлено: {ok}, ❌ Ошибок (юзер забанил бота и т.п.): {fail}")


# ── Меню ──────────────────────────────────────────────────────────────────────
MENU = """
╔══════════════════════════════════════╗
║           OKey — консоль              ║
╠══════════════════════════════════════╣
║ 1. 📊 Статистика                      ║
║ 2. 👥 Последние анкеты                ║
║ 3. 🔍 Найти юзера                     ║
║ 4. 🗑  Удалить юзера                  ║
║ 5. 📢 Рассылка всем                   ║
║ 6. ⏹  Остановить бота и выйти         ║
║ 0. 🚪 Выйти (бот продолжит работать)  ║
╚══════════════════════════════════════╝
"""


def run(bot_proc=None) -> None:
    """
    bot_proc — subprocess.Popen объект бота, если консоль запущена из main.py.
    Нужен только для пункта 6 (остановить бота). Если консоль запущена сама
    по себе (python console.py), bot_proc=None и пункт 6 просто выходит.
    """
    while True:
        print(MENU)
        choice = input("Выбери пункт: ").strip()
        if choice == "1":
            stats()
        elif choice == "2":
            n = input("Сколько показать (Enter = 10): ").strip()
            list_recent(int(n) if n.isdigit() else 10)
        elif choice == "3":
            find_user()
        elif choice == "4":
            delete_user()
        elif choice == "5":
            broadcast()
        elif choice == "6":
            if bot_proc:
                print("⏹ Останавливаю бота...")
                bot_proc.terminate()
            else:
                print("(бот не был запущен из этой консоли — нечего останавливать)")
            print("👋 Пока!")
            break
        elif choice == "0":
            print("👋 Консоль закрыта. Бот (если был запущен) продолжает работать.")
            break
        else:
            print("❓ Не понял выбор, попробуй ещё раз.")
            continue
        input("\nEnter чтобы вернуться в меню...")


if __name__ == "__main__":
    if not DB_PATH.exists():
        print(f"⚠️  БД {DB_PATH} ещё не создана — запусти бота хотя бы раз.")
    run(bot_proc=None)
