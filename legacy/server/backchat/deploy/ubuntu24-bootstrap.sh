#!/usr/bin/env bash
# Запускать НА сервере (Ubuntu 24.04), один раз: bash ubuntu24-bootstrap.sh
set -euo pipefail

sudo apt-get update
sudo apt-get install -y python3.12-venv python3-pip nginx curl

echo "OK: python3-venv, nginx установлены."
echo "Дальше вручную:"
echo "  1) Положи код сервера (например /opt/ghostchat/server)"
echo "  2) cd туда → python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"
echo "  3) sudo cp ../nginx-ghostchat.example.conf в /etc/nginx/… и добавь limit_* зоны в http{} — см. комментарии в файле"
echo "  4) sudo nano /etc/ghostchat.env — GHOSTCHAT_DISABLE_DOCS=1, GHOSTCHAT_ADMIN_KEY=…, GHOSTCHAT_SUPPORT_PASSWORD=…"
echo "  5) sudo cp ghostchat.service.example /etc/systemd/system/ghostchat.service — поправь пути и User"
echo "  6) sudo systemctl daemon-reload && sudo systemctl enable --now ghostchat && sudo nginx -t && sudo systemctl reload nginx"
