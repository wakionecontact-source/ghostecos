"""
GhostBot — системный бот-конструктор ботов, аналог @BotFather в Telegram.
Работает как обычный бот на движке (getUpdates/sendMessage через HTTP,
Authorization: Bot <token>), но создание нового бота делает НАПРЯМУЮ через
БД (тот же процесс/сервер/файл БД, доверенная зона) — без лишнего HTTP-хопа
и без необходимости давать GhostBot чей-то чужой JWT.

Диалог:
  любое сообщение вне сценария -> подсказка "/newbot"
  /newbot -> "как назовём бота?"
  <username> -> валидация, "как отображаемое имя?"
  <display_name> -> создание бота, токен ОДИН РАЗ

Команды — ВСЕГДА приоритет над текущим шагом диалога (как в Telegram: если
у бота есть alias/шаг ожидания ввода, но юзер прислал /start, это команда
/start, а НЕ текст для текущего шага) — см. handle_message ниже.
"""
import logging
import os
import sys
import time

import requests

sys.path.insert(0, "/opt/ghostchat")
from social_router import db, _val_name  # noqa: E402
from bot_api import _create_bot_row, _val_bot_username  # noqa: E402
from fastapi import HTTPException  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("ghostbot")

API_BASE = "http://127.0.0.1:8002"
SECRETS_PATH = os.path.join(os.path.dirname(__file__), "ghostbot_secrets.env")
# Персист offset между рестартами — без этого каждый передеплой сервиса
# заново отвечал на всю историю чата (см. _establish_baseline_offset ниже).
OFFSET_PATH = os.path.join(os.path.dirname(__file__), "ghostbot_offset.txt")

_GREETING = (
    "Привет! Я GhostBot — как @BotFather в Telegram.\n"
    "Напиши /newbot, чтобы завести своего бота."
)

_NEWBOT_PROMPT = (
    'Как назовём бота? Юзернейм должен заканчиваться на "bot" — '
    'можно с подчёркиванием (weather_bot) или без (weatherbot).'
)


def _load_token() -> str:
    with open(SECRETS_PATH) as f:
        for line in f:
            if line.startswith("GHOSTBOT_TOKEN="):
                return line.strip().split("=", 1)[1]
    raise RuntimeError("GHOSTBOT_TOKEN не найден в " + SECRETS_PATH)


class GhostBot:
    def __init__(self):
        self.token = _load_token()
        self.state: dict[str, dict] = {}  # from_username -> {"step":..., "username":...}

    def send(self, to_username: str, text: str):
        try:
            r = requests.post(
                f"{API_BASE}/api/bots/sendMessage",
                json={"to_username": to_username, "text": text},
                headers={"Authorization": f"Bot {self.token}"},
                timeout=15,
            )
            r.raise_for_status()
        except Exception as e:
            log.warning("send to @%s failed: %s", to_username, e)

    def _resolve_owner_id(self, username: str) -> int | None:
        c = db()
        try:
            row = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
            return row["id"] if row else None
        finally:
            c.close()

    def _start_newbot(self, from_username: str):
        self.state[from_username] = {"step": "await_username"}
        self.send(from_username, _NEWBOT_PROMPT)

    def _handle_command(self, from_username: str, text: str) -> bool:
        """Слэш-команда — всегда приоритет над шагом диалога. Возвращает
        True, если это была команда (обработана или явно отклонена как
        неизвестная), False если text не начинается с '/' вообще."""
        if not text.startswith("/"):
            return False
        # Команда = от слэша до пробела/переноса — аргументы после не парсим,
        # GhostBot ими не пользуется.
        cmd = text.split()[0].lower() if text.split() else text.lower()
        if cmd in ("/start", "/help"):
            self.state.pop(from_username, None)
            self.send(from_username, _GREETING)
            return True
        if cmd == "/newbot":
            self._start_newbot(from_username)
            return True
        if cmd == "/cancel":
            had_state = from_username in self.state
            self.state.pop(from_username, None)
            self.send(from_username, "Отменено." if had_state else _GREETING)
            return True
        # Неизвестная команда посреди сценария — НЕ трактуем как ответ на
        # текущий шаг (иначе "/start" во время await_username пытался бы
        # провалидироваться как юзернейм бота и падал с непонятной ошибкой).
        self.send(from_username, f"Не знаю команду {cmd}. Напиши /newbot, чтобы завести бота.")
        return True

    def handle_message(self, from_username: str, text: str):
        text = (text or "").strip()

        # Legacy-алиасы для /newbot (текстом, не командой) — оставляем как
        # было, но САМА команда /newbot (и другие команды) теперь всегда
        # проверяется первой, до состояния диалога.
        if text.lower() in ("newbot", "начать", "создать бота"):
            self._start_newbot(from_username)
            return
        if self._handle_command(from_username, text):
            return

        st = self.state.get(from_username)

        if st and st["step"] == "await_username":
            raw = text.lower().lstrip("@")
            try:
                username = _val_bot_username(raw)
            except HTTPException as e:
                self.send(from_username, f"Не годится: {e.detail}. Попробуй другой юзернейм.")
                return
            c = db()
            try:
                exists = c.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
            finally:
                c.close()
            if exists:
                self.send(from_username, f"@{username} уже занят, попробуй другой.")
                return
            self.state[from_username] = {"step": "await_display_name", "username": username}
            self.send(from_username, "Отображаемое имя бота?")
            return

        if st and st["step"] == "await_display_name":
            try:
                display_name = _val_name(text)
            except HTTPException as e:
                self.send(from_username, f"Не годится: {e.detail}. Попробуй ещё раз.")
                return
            owner_id = self._resolve_owner_id(from_username)
            if owner_id is None:
                self.send(from_username, "Не нашёл твой аккаунт, странно — напиши /newbot заново.")
                self.state.pop(from_username, None)
                return
            username = st["username"]
            c = db()
            try:
                username, token = _create_bot_row(c, owner_id, username, display_name)
            except HTTPException as e:
                self.send(from_username, f"Не получилось: {e.detail}")
                self.state.pop(from_username, None)
                return
            finally:
                c.close()
            self.state.pop(from_username, None)
            self.send(
                from_username,
                f"Готово! @{username} создан.\n\n"
                f"Токен (сохрани СЕЙЧАС, больше не покажу):\n{token}\n\n"
                f"Управлять ботом (переименовать/перевыпустить токен) можно в "
                f"Настройки → Боты в приложении.",
            )
            return

        self.send(from_username, _GREETING)

    def _load_offset(self):
        """None = офсета ещё никогда не было (самый первый запуск когда-либо).
        Отличаем от 0, чтобы не путать с "офсет реально 0"."""
        try:
            with open(OFFSET_PATH) as f:
                return int(f.read().strip())
        except (FileNotFoundError, ValueError):
            return None

    def _save_offset(self, offset: int):
        try:
            with open(OFFSET_PATH, "w") as f:
                f.write(str(offset))
        except Exception as e:
            log.warning("failed to save offset: %s", e)

    def _establish_baseline_offset(self) -> int:
        """Первый запуск ЗА ВСЁ ВРЕМЯ (нет файла офсета) — узнаём текущий
        max update_id ОДНИМ запросом с timeout=0 (не блокирует, просто
        отдаёт что уже накопилось) и стартуем с него, НЕ обрабатывая
        накопленный бэклог (иначе бот при каждом передеплое/рестарте
        сервиса заново отвечал бы на всю историю чата — реальный баг,
        пойманный на проде 2026-07-20)."""
        try:
            r = requests.get(
                f"{API_BASE}/api/bots/getUpdates",
                params={"offset": 0, "timeout": 0},
                headers={"Authorization": f"Bot {self.token}"},
                timeout=10,
            )
            r.raise_for_status()
            updates = r.json().get("updates", [])
            offset = max((u["update_id"] for u in updates), default=0)
        except Exception as e:
            log.warning("baseline offset probe failed, starting from 0: %s", e)
            offset = 0
        self._save_offset(offset)
        log.info("First run ever — baseline offset=%d (skipped %d backlog updates)", offset, 0)
        return offset

    def run(self):
        offset = self._load_offset()
        if offset is None:
            offset = self._establish_baseline_offset()
        else:
            log.info("Resuming from saved offset=%d", offset)
        backoff = 2
        log.info("GhostBot started")
        while True:
            try:
                r = requests.get(
                    f"{API_BASE}/api/bots/getUpdates",
                    params={"offset": offset, "timeout": 25},
                    headers={"Authorization": f"Bot {self.token}"},
                    timeout=35,
                )
                r.raise_for_status()
                updates = r.json().get("updates", [])
                for u in updates:
                    offset = max(offset, u["update_id"])
                    try:
                        self.handle_message(u["from_username"], u.get("text", ""))
                    except Exception:
                        log.exception("handle_message failed for update %s", u.get("update_id"))
                if updates:
                    self._save_offset(offset)
                backoff = 2
            except Exception as e:
                log.warning("getUpdates failed: %s", e)
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)


if __name__ == "__main__":
    GhostBot().run()
