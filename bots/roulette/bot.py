"""
GhostRoulette — каркас бота с интегрированной admin-панелью.

Запуск: start.bat (Windows) или python bot.py.

Архитектура:
- aiogram 3 для бота, через SOCKS5/HTTP прокси к Telegram (V2RayTun)
- FastAPI на отдельном порту для admin-приложения (HTML/JS UI в браузере)
- WebSocket для real-time стрима логов и статистики в UI
- Внутренний registry команд: всё что можно вызвать из консоли и кнопок UI

Этот файл — скелет. Бизнес-логика рулетки добавляется в roulette/* (TODO).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
import webbrowser
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional

# ── .env ──────────────────────────────────────────────────────────────────────
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
PROXY_URL = os.getenv("PROXY_URL", "").strip() or None
ADMIN_PORT = int(os.getenv("ADMIN_PORT", "8088"))
ADMIN_OPEN_BROWSER = os.getenv("ADMIN_OPEN_BROWSER", "1") == "1"
ADMIN_USER_ID = int(os.getenv("ADMIN_USER_ID", "0") or "0")

if not BOT_TOKEN:
    print("[ОШИБКА] BOT_TOKEN не задан в .env. Получи у @BotFather и впиши.")
    sys.exit(1)

# ── Логирование: в stdout + в очередь для WS-стрима в UI ──────────────────────
log_queue: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=2000)
log_buffer: List[dict] = []  # последние N логов для свежеподключившегося UI
LOG_BUFFER_MAX = 500


class UILogHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        entry = {
            "ts": time.time(),
            "level": record.levelname,
            "name": record.name,
            "msg": self.format(record),
        }
        log_buffer.append(entry)
        if len(log_buffer) > LOG_BUFFER_MAX:
            del log_buffer[: len(log_buffer) - LOG_BUFFER_MAX]
        try:
            log_queue.put_nowait(entry)
        except asyncio.QueueFull:
            pass  # UI отстаёт — дропаем


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
    datefmt="%H:%M:%S",
)
logging.getLogger().addHandler(UILogHandler())
log = logging.getLogger("roulette")

# ── Bot setup ─────────────────────────────────────────────────────────────────
from aiogram import Bot, Dispatcher, F
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.filters import CommandStart, Command
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import Message

import db as okeydb
from handlers import profile as profile_handlers

if PROXY_URL:
    log.info("Использую прокси к Telegram: %s", PROXY_URL)
    session = AiohttpSession(proxy=PROXY_URL)
else:
    log.info("Без прокси (бот ходит напрямую через систему / TUN VPN)")
    session = AiohttpSession()

bot = Bot(token=BOT_TOKEN, session=session)
dp = Dispatcher(storage=MemoryStorage())
dp.include_router(profile_handlers.router)

# Инициализация БД при импорте — таблицы создаются один раз
okeydb.init_db()
log.info("БД: %s", okeydb.DB_PATH)

# ── Stats (in-memory; для перезапуск-стойких — потом перенесём в SQLite) ──────
stats: Dict[str, Any] = {
    "started_at": time.time(),
    "users_seen": set(),          # уникальные user_id за сессию
    "messages_total": 0,
    "commands_total": 0,
}


def stats_snapshot() -> Dict[str, Any]:
    # Базовая сессионная статистика
    out = {
        "uptime_sec": int(time.time() - stats["started_at"]),
        "session_users_seen": len(stats["users_seen"]),
        "messages_total": stats["messages_total"],
        "commands_total": stats["commands_total"],
        "proxy": PROXY_URL or "(direct / TUN VPN)",
        "bot_token_tail": BOT_TOKEN[-6:] if len(BOT_TOKEN) >= 6 else "",
    }
    # БД-статы (всё время, не только эта сессия)
    try:
        import db as _db
        out.update(_db.stats_overview())
    except Exception as e:
        out["db_error"] = str(e)
    return out


# ── Bot handlers (минимальный набор; рулетка добавится отдельно) ──────────────
@dp.message(CommandStart())
async def cmd_start(m: Message):
    stats["users_seen"].add(m.from_user.id)
    stats["commands_total"] += 1
    okeydb.touch_user(m.from_user.id, m.from_user.username)
    log.info("/start от @%s (id=%s)", m.from_user.username, m.from_user.id)
    existing = okeydb.get_profile(m.from_user.id)
    if existing:
        await m.answer(
            f"С возвращением, {existing['name']}!\n\n"
            "/profile — твоя анкета\n"
            "/edit — изменить\n"
            "(скоро) /search — смотреть других\n"
            "(скоро) /roulette — случайный собеседник"
        )
    else:
        await m.answer(
            "Привет! Это <b>OKey</b> — знакомства в Telegram.\n\n"
            "Здесь можно:\n"
            "• Заполнить анкету и смотреть других\n"
            "• Лайкать и получать match-уведомления\n"
            "• Болтать случайным образом в чат-рулетке\n\n"
            "Поехали? Жми /fill — заполним твою анкету.\n"
            "Помощь: /help · Твой ID: /id",
            parse_mode="HTML",
        )


@dp.message(Command("help"))
async def cmd_help(m: Message):
    stats["commands_total"] += 1
    await m.answer(
        "<b>Команды OKey:</b>\n\n"
        "/fill — заполнить анкету\n"
        "/profile — посмотреть свою анкету\n"
        "/edit — изменить анкету\n"
        "/cancel — прервать заполнение\n"
        "/id — узнать свой Telegram ID\n"
        "/ping — проверка что бот живой\n\n"
        "<i>Скоро:</i> /search, /roulette",
        parse_mode="HTML",
    )


@dp.message(Command("id"))
async def cmd_id(m: Message):
    stats["commands_total"] += 1
    await m.answer(f"Твой ID: <code>{m.from_user.id}</code>", parse_mode="HTML")


@dp.message(Command("ping"))
async def cmd_ping(m: Message):
    stats["commands_total"] += 1
    await m.answer("pong")


# Fallback на любой текст — но НЕ во время FSM (profile-router забирает раньше)
@dp.message(F.text)
async def any_text(m: Message):
    stats["users_seen"].add(m.from_user.id)
    stats["messages_total"] += 1
    okeydb.touch_user(m.from_user.id, m.from_user.username)
    await m.answer("Не понял команду. /help — список доступных.")


# ── Admin command registry ────────────────────────────────────────────────────
# Каждая команда: имя → (описание, async функция(args:list) → str)
CommandFn = Callable[[List[str]], Awaitable[str]]
admin_commands: Dict[str, Dict[str, Any]] = {}


def admin_command(name: str, desc: str, button: bool = True):
    """Декоратор: регистрирует команду доступную из UI-консоли и (если button=True)
    как кнопку в меню."""
    def wrap(fn: CommandFn):
        admin_commands[name] = {"desc": desc, "fn": fn, "button": button}
        return fn
    return wrap


@admin_command("stats", "Показать текущие статы")
async def cmd_admin_stats(args: List[str]) -> str:
    s = stats_snapshot()
    return json.dumps(s, indent=2, ensure_ascii=False)


@admin_command("ping", "Пинг Telegram API через бот")
async def cmd_admin_ping(args: List[str]) -> str:
    t0 = time.time()
    try:
        me = await bot.get_me()
        dt = (time.time() - t0) * 1000
        return f"ok · {me.username} · {dt:.0f} ms"
    except Exception as e:
        return f"FAIL: {e}"


@admin_command("scanports", "Найти на каких портах слушает прокси (V2RayTun)")
async def cmd_admin_scanports(args: List[str]) -> str:
    import socket
    candidates = [10808, 10809, 1080, 1081, 2080, 7890, 7891, 8080, 8081, 8118]
    found = []
    for port in candidates:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.3)
        try:
            s.connect(("127.0.0.1", port))
            found.append(port)
        except Exception:
            pass
        finally:
            s.close()
    if not found:
        return ("Открытых прокси-портов не нашёл (проверил " + ", ".join(map(str, candidates)) +
                ").\nВключи V2RayTun и проверь Settings → Inbounds.")
    return "Слушают порты: " + ", ".join(map(str, found)) + (
        "\n\nОбычно SOCKS=10808, HTTP=10809.\n"
        "Попробуй в .env:\n"
        "  PROXY_URL=socks5://127.0.0.1:10808\n"
        "  или\n"
        "  PROXY_URL=http://127.0.0.1:10809"
    )


@admin_command("broadcast", "broadcast <текст> — отправить всем виденным юзерам")
async def cmd_admin_broadcast(args: List[str]) -> str:
    if not args:
        return "usage: broadcast <текст>"
    text = " ".join(args)
    sent, failed = 0, 0
    for uid in list(stats["users_seen"]):
        try:
            await bot.send_message(uid, text)
            sent += 1
        except Exception:
            failed += 1
        await asyncio.sleep(0.05)  # ~20 msg/sec, чтобы не словить flood limit
    return f"Отправлено: {sent}, не доставлено: {failed}"


@admin_command("profiles", "Последние 10 заполненных анкет")
async def cmd_admin_profiles(args: List[str]) -> str:
    with okeydb.conn() as c:
        rows = c.execute("""
            SELECT p.name, p.age, p.gender, p.looking_for, p.city, p.completed_at,
                   u.username, u.tg_id
            FROM profiles p JOIN users u ON u.tg_id = p.tg_id
            ORDER BY p.completed_at DESC LIMIT 10
        """).fetchall()
    if not rows:
        return "Анкет пока нет."
    out = []
    for r in rows:
        ago = int(time.time() - r["completed_at"])
        ago_str = f"{ago//3600}ч" if ago >= 3600 else f"{ago//60}мин"
        out.append(f"  @{r['username'] or '—':20s} {r['name']:15s} {r['age']:2d} {r['gender']}→{r['looking_for']:3s} {r['city'] or '—':12s} ({ago_str} назад)")
    return "Последние анкеты:\n" + "\n".join(out)


@admin_command("clearlogs", "Очистить буфер логов в UI", button=True)
async def cmd_admin_clearlogs(args: List[str]) -> str:
    log_buffer.clear()
    return "Логи очищены"


@admin_command("help", "Список всех команд")
async def cmd_admin_help(args: List[str]) -> str:
    lines = [f"  {name:12s} — {meta['desc']}" for name, meta in sorted(admin_commands.items())]
    return "Команды:\n" + "\n".join(lines)


@admin_command("stop", "Завершить бот (закрыть процесс)", button=True)
async def cmd_admin_stop(args: List[str]) -> str:
    log.warning("Stop по запросу admin UI")
    # Дать UI получить ответ, потом kill
    asyncio.get_event_loop().call_later(0.5, lambda: os._exit(0))
    return "Останавливаюсь..."


async def run_command(line: str) -> str:
    """Выполнить команду из UI-консоли. Формат: 'name arg1 arg2 ...'"""
    line = line.strip()
    if not line:
        return ""
    parts = line.split()
    name, args = parts[0], parts[1:]
    meta = admin_commands.get(name)
    if not meta:
        return f"Неизвестная команда: {name}. /help"
    try:
        return await meta["fn"](args)
    except Exception as e:
        log.exception("Команда %s упала", name)
        return f"Ошибка: {e}"


# ── Admin web app (FastAPI) ───────────────────────────────────────────────────
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

ADMIN_DIR = Path(__file__).parent / "admin"


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Admin UI: http://127.0.0.1:%s", ADMIN_PORT)
    yield


admin_app = FastAPI(lifespan=lifespan, title="GhostRoulette admin")


@admin_app.get("/")
async def admin_index():
    return FileResponse(ADMIN_DIR / "index.html")


@admin_app.get("/api/stats")
async def api_stats():
    return stats_snapshot()


@admin_app.get("/api/commands")
async def api_commands():
    return [
        {"name": n, "desc": m["desc"], "button": m["button"]}
        for n, m in sorted(admin_commands.items())
    ]


@admin_app.post("/api/exec")
async def api_exec(body: dict):
    line = (body or {}).get("line", "")
    out = await run_command(line)
    return {"output": out}


@admin_app.websocket("/ws/logs")
async def ws_logs(ws: WebSocket):
    await ws.accept()
    # Отправляем буфер прошлых логов
    for entry in list(log_buffer):
        await ws.send_json(entry)
    # Потом стримим новые
    while True:
        try:
            entry = await log_queue.get()
            await ws.send_json(entry)
        except WebSocketDisconnect:
            return
        except Exception:
            return


# ── main ──────────────────────────────────────────────────────────────────────
async def main():
    import uvicorn

    config = uvicorn.Config(
        admin_app,
        host="127.0.0.1",
        port=ADMIN_PORT,
        log_level="warning",  # uvicorn-логи отдельно, чтоб не дублировались
    )
    server = uvicorn.Server(config)
    server_task = asyncio.create_task(server.serve())

    # Открыть браузер с админкой
    if ADMIN_OPEN_BROWSER:
        await asyncio.sleep(0.5)
        try:
            webbrowser.open(f"http://127.0.0.1:{ADMIN_PORT}/")
        except Exception:
            pass

    # Polling — в фоне, с retry. Если упадёт — UI продолжит работать,
    # юзер увидит ошибку в логах и сможет починить .env / V2RayTun.
    async def polling_loop():
        backoff = 3
        while True:
            try:
                me = await bot.get_me()
                log.info("Бот @%s (id=%s) — поехали", me.username, me.id)
                backoff = 3  # reset
                await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
                # start_polling выходит только на graceful stop
                log.info("Polling завершён")
                break
            except Exception as e:
                log.error("Telegram недоступен: %s", e)
                log.error("Проверь V2RayTun (порт %s) и BOT_TOKEN. Retry через %ds...",
                          PROXY_URL or "—", backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)  # 3 → 6 → 12 → 24 → 48 → 60

    polling_task = asyncio.create_task(polling_loop())

    # Главный loop — uvicorn. Он держит UI до Ctrl+C
    try:
        await server_task
    finally:
        polling_task.cancel()
        try: await polling_task
        except: pass
        await bot.session.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nЗакрыто.")
