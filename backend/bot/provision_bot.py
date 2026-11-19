"""
Одноразовый провижининг аккаунта бота. Запускать один раз на сервере:

    python3 provision_bot.py --username ghostbot --display-name "GhostBot"

Генерирует P-256 keypair, регистрирует аккаунт через /api/soc/register,
публикует публичный ключ через /api/chat/keys/upload (storage_mode=local —
приватный ключ бота нигде на сервере в БД не хранится, только в
bot_secrets.env рядом с раннером), сохраняет секреты в bot_secrets.env.

Если username уже занят — считаем, что уже провижинили, просто логинимся и
(пере)публикуем ключ (идемпотентно, безопасно перезапускать).
"""
import argparse
import base64
import json
import os
import secrets
import stat
import sys

import requests

from crypto_p256 import generate_keypair

API_BASE = "http://127.0.0.1:8002"  # локально, co-located — минуя nginx/TLS
SECRETS_PATH = os.path.join(os.path.dirname(__file__), "bot_secrets.env")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--username", required=True)
    ap.add_argument("--display-name", required=True)
    args = ap.parse_args()

    password = secrets.token_urlsafe(32)

    r = requests.post(
        f"{API_BASE}/api/soc/register",
        json={
            "username": args.username,
            "display_name": args.display_name,
            "password": password,
            "age_18_confirm": True,
            "device_id": "ghostbot-runner",
            "device_name": "GhostBot Runner",
            "platform": "linux-server",
        },
        timeout=15,
    )
    if r.status_code == 200:
        token = r.json().get("token")
        print(f"[provision] зарегистрирован новый аккаунт @{args.username}")
    elif r.status_code == 409 or "занят" in r.text.lower() or "taken" in r.text.lower():
        print(f"[provision] @{args.username} уже существует — эта учётка должна быть от предыдущего запуска.")
        print("[provision] пароль для повторного логина неизвестен (не сохранялся вне bot_secrets.env).")
        print("[provision] если bot_secrets.env утерян — удали аккаунт из БД вручную и перезапусти provision.")
        sys.exit(1)
    else:
        print(f"[provision] register FAILED: {r.status_code} {r.text}")
        sys.exit(1)

    priv_raw, pub_raw = generate_keypair()
    pub_b64 = base64.b64encode(pub_raw).decode()

    r2 = requests.post(
        f"{API_BASE}/api/chat/keys/upload",
        json={"x25519_pub": pub_b64, "storage_mode": "local"},
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    if r2.status_code != 200:
        print(f"[provision] keys/upload FAILED: {r2.status_code} {r2.text}")
        sys.exit(1)

    secrets_data = {
        "BOT_USERNAME": args.username,
        "BOT_TOKEN": token,
        "BOT_PASSWORD": password,  # для повторного логина, если токен истечёт
        "BOT_PRIV_KEY_B64": base64.b64encode(priv_raw).decode(),
        "BOT_PUB_KEY_B64": pub_b64,
    }
    with open(SECRETS_PATH, "w") as f:
        for k, v in secrets_data.items():
            f.write(f"{k}={v}\n")
    os.chmod(SECRETS_PATH, stat.S_IRUSR | stat.S_IWUSR)  # 600

    print(f"[provision] OK. Секреты сохранены в {SECRETS_PATH} (chmod 600).")
    print(f"[provision] @{args.username} готов к работе.")


if __name__ == "__main__":
    main()
