"""Запускает одновременно Telegram-бота и FastAPI-сервер."""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

import uvicorn
from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage

import config
import db
from bot import handlers as bot_handlers
from bot import payments as bot_payments
from web.api import create_app


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("shop_bot.main")


async def main() -> None:
    missing_ = config.missing()
    if missing_:
        log.error("Missing config: %s. Создай .env на основе .env.example", ", ".join(missing_))
        sys.exit(1)

    db.init()
    log.info("shop.db: %s", config.SHOP_DB_PATH)
    log.info("gc.db:   %s", config.GC_DB_PATH)

    bot = Bot(
        token=config.BOT_TOKEN,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(bot_payments.router)
    dp.include_router(bot_handlers.router)

    # FastAPI
    app = create_app(bot)
    uv_config = uvicorn.Config(
        app,
        host=config.WEB_HOST,
        port=config.WEB_PORT,
        log_level="info",
        access_log=False,
        proxy_headers=True,
        forwarded_allow_ips="*",
        timeout_keep_alive=10,
    )
    server = uvicorn.Server(uv_config)

    try:
        await bot.delete_webhook(drop_pending_updates=True)
        me = await bot.get_me()
    except Exception as _e:
        log.warning('Telegram unreachable at startup: %s', _e)
        me = type('Me', (), {'username': '?', 'id': '?'})()
    log.info("Bot: @%s (id=%s)", me.username, me.id)
    log.info("Web: http://%s:%s", config.WEB_HOST, config.WEB_PORT)
    log.info("Public: %s", config.PUBLIC_URL)
    log.info("Owner: %s, access=%s", config.OWNER_TG_ID, config.ACCESS_MODE)

    stop_event = asyncio.Event()

    def _shutdown() -> None:
        log.info("Shutdown requested")
        stop_event.set()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except NotImplementedError:
            # Windows
            pass

    # Запускаем оба процесса параллельно.
    async def run_web() -> None:
        await server.serve()

    async def run_bot() -> None:
        try:
            await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
        finally:
            await bot.session.close()

    web_task = asyncio.create_task(run_web(), name="web")
    bot_task = asyncio.create_task(run_bot(), name="bot")
    stop_task = asyncio.create_task(stop_event.wait(), name="stop")

    done, _ = await asyncio.wait(
        {web_task, bot_task, stop_task},
        return_when=asyncio.FIRST_COMPLETED,
    )

    # Корректная остановка
    log.info("Stopping...")
    server.should_exit = True
    for t in (web_task, bot_task):
        if not t.done():
            t.cancel()
    await asyncio.gather(*(web_task, bot_task), return_exceptions=True)
    log.info("Bye.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
