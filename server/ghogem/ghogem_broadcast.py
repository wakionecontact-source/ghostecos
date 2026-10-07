"""Send a one-off Telegram announcement to all known GhoGem users.

The command is intentionally opt-in: it refuses to send without ``--send``.
It reads the bot token from the target installation's .env and collects users
from all state tables so users who only have a saved model/subscription are not
missed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sqlite3
from pathlib import Path

import aiohttp
from dotenv import load_dotenv


MESSAGE = """🆕 <b>GhoGem: обновлён каталог бесплатных моделей</b>

Я обновил список free-моделей OpenRouter и добавил новые актуальные варианты.

🚀 <b>Особенно советую попробовать Ox Alpha</b>
<code>stealth/ox-alpha</code>
Модель для reasoning, кода и агентных задач; поддерживает текст, изображения и видео, tools и контекст до 1 млн токенов. Сейчас она доступна бесплатно через OpenRouter, но у free-моделей могут меняться лимиты и доступность.

Откройте <code>/model</code> → <b>OpenRouter</b>, чтобы выбрать её или другую обновлённую free-модель."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/root/ghogem"))
    parser.add_argument("--send", action="store_true", help="actually send the announcement")
    parser.add_argument("--user-id", action="append", type=int, help="send only to this Telegram user; repeatable")
    return parser.parse_args()


def user_ids(db_path: Path) -> list[int]:
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            "SELECT user_id FROM users "
            "UNION SELECT user_id FROM user_state "
            "UNION SELECT user_id FROM subscriptions "
            "ORDER BY user_id"
        ).fetchall()
    finally:
        conn.close()
    return [int(row[0]) for row in rows if int(row[0]) > 0]


async def send_one(session: aiohttp.ClientSession, token: str, user_id: int) -> str:
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": user_id,
        "text": MESSAGE,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    for attempt in range(4):
        try:
            async with session.post(url, json=payload) as response:
                body = await response.json(content_type=None)
                if response.status == 200 and body.get("ok"):
                    return "sent"
                if response.status == 429:
                    retry_after = int((body.get("parameters") or {}).get("retry_after") or 2)
                    await asyncio.sleep(min(retry_after, 30))
                    continue
                if response.status in (400, 403):
                    return f"blocked_or_invalid:{response.status}"
                return f"failed:{response.status}"
        except (aiohttp.ClientError, asyncio.TimeoutError):
            if attempt == 3:
                return "failed:network"
            await asyncio.sleep(2 ** attempt)
    return "failed:retry"


async def main() -> None:
    args = parse_args()
    env_path = args.root / ".env"
    db_path = args.root / "subscriptions.db"
    load_dotenv(env_path)
    token = os.environ.get("TELEGRAM_TOKEN", "").strip()
    if not token:
        raise SystemExit(f"TELEGRAM_TOKEN is missing in {env_path}")
    if not db_path.exists():
        raise SystemExit(f"database is missing: {db_path}")

    ids = args.user_id or user_ids(db_path)
    print(json.dumps({"users": len(ids), "send": args.send}, ensure_ascii=False))
    if not args.send:
        print("Dry run. Re-run with --send to deliver the announcement.")
        return

    timeout = aiohttp.ClientTimeout(total=45)
    counts: dict[str, int] = {}
    async with aiohttp.ClientSession(timeout=timeout) as session:
        for user_id in ids:
            result = await send_one(session, token, user_id)
            counts[result] = counts.get(result, 0) + 1
            # Stay below Telegram's bot broadcast rate without a burst.
            await asyncio.sleep(0.05)
    print(json.dumps({"users": len(ids), "results": counts}, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
