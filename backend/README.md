# GhostChat / GhostSocial — бэкенд и сайт

Серверная часть экосистемы GhostEcos: FastAPI + uvicorn + SQLite (WAL).
В репозитории только код: без баз данных, секретов, бэкапов и собранных APK.

## Состав

- `*.py` в корне — API, авторизация, боты, миграции, утилиты
- `routers/`, `ws/` — HTTP-роутеры и WebSocket-обработчики
- `bot/`, `ghostbot_creator/`, `support_bot/` — боты и их инфраструктура
- `tests/` — тесты
- `site/` — фронтенд сайта (HTML/CSS/JS)

## Запуск

1. `python3 -m venv venv && source venv/bin/activate`
2. `pip install -r requirements.txt`
3. `cp .env.example .env` — заполнить реальные значения (в git `.env` не попадает)
4. `uvicorn main_remote:app --host 127.0.0.1 --port 8000`

Порты и приватные переменные задаются в `.env`; список переменных — в `.env.example`.

## Стиль кода

Комментарии и docstring — по-русски, коротко. Стандарт: `STYLE.md`
(в репозитории `ghost-workspace` и `GE`).

## Лицензия

PolyForm Noncommercial License 1.0.0 — см. `LICENSE`.
