"""Offline regression: old DB migration, text/AI draft, edit, direct dispatch."""
import asyncio
import os
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from zoneinfo import ZoneInfo

with TemporaryDirectory(prefix="ghogem-reminder-modes-") as tmp:
    database=str(Path(tmp)/"r.db")
    # Simulate an existing DB that predates the mode column.
    connection=sqlite3.connect(database)
    connection.execute(
        """CREATE TABLE reminders(
            id TEXT PRIMARY KEY,user_id INTEGER NOT NULL,
            telegram_chat_id INTEGER NOT NULL,ai_chat_id TEXT NOT NULL,
            model_key TEXT NOT NULL,title TEXT NOT NULL,instruction TEXT NOT NULL,
            run_at INTEGER NOT NULL,status TEXT NOT NULL,
            created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,config_message_id INTEGER,
            confirm_button TEXT NOT NULL,cancel_button TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,last_error TEXT,
            recurrence TEXT NOT NULL DEFAULT 'once',weekdays TEXT NOT NULL DEFAULT '',
            recurrence_day INTEGER,retry_at INTEGER,replaces_id TEXT,
            schedule_json TEXT NOT NULL DEFAULT '',
            occurrences_done INTEGER NOT NULL DEFAULT 0
        )"""
    )
    now=int(datetime.now(ZoneInfo("Europe/Moscow")).timestamp())
    old_run=now+7200
    connection.execute(
        "INSERT INTO reminders (id,user_id,telegram_chat_id,ai_chat_id,model_key,title,instruction,run_at,status,created_at,updated_at,expires_at,confirm_button,cancel_button) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("old-ai",901,901,"1740000000000","groq:gpt-oss-20b","Старое","Проверить",old_run,"scheduled",now,now,now+3600,"ОК","Нет"))
    connection.commit()
    connection.close()
    os.environ["GHOGEM_REMINDERS_DB"]=database
    import reminders
    assert reminders._get_sync("old-ai")["execution_mode"]=="ai"
    assert reminders.normalize_execution_mode("text")=="text"
    try:
        reminders.normalize_execution_mode("shell")
        raise AssertionError("unsafe mode")
    except ValueError:
        pass
    print("PASS: old tasks migrate to AI and disallow unsupported modes")

    sch={"mode":"next_days","days_count":3,"include_today":False,
         "times":["15:00","19:00"]}
    draft=reminders._create_draft_sync(
        901,901,"1740000000000","groq:gpt-oss-20b","Оплата серверов",
        "Оплати серверы!",0,"Да","Нет",schedule=sch,execution_mode="text")
    assert draft["execution_mode"]=="text"
    assert draft["recurrence"]=="advanced"
    assert reminders._update_draft_sync(draft["id"],902,execution_mode="ai") is None
    updated=reminders._update_draft_sync(draft["id"],901,execution_mode="ai")
    assert updated["execution_mode"]=="ai"
    updated=reminders._update_draft_sync(draft["id"],901,execution_mode="text")
    assert updated["execution_mode"]=="text"
    assert reminders._confirm_sync(draft["id"],901)["ok"]
    edit=reminders._create_edit_draft_sync(draft["id"],901,max_active=10)
    assert edit["execution_mode"]=="text"
    print("PASS: one card N-days with mode choice, owner-only editing and inherited mode")

    import bot
    sent=[]
    completed=[]
    class FakeBot:
        async def send_message(self,chat_id,text,**kwargs):
            sent.append((chat_id,text,kwargs))
            return SimpleNamespace(message_id=300)
    original_bot=bot.bot
    original_complete=bot.reminders.complete
    original_ai=bot.ai.ask_ai
    async def no_ai(*args,**kwargs):
        raise AssertionError("AI must never run for text reminders")
    async def complete(task_id):
        completed.append(task_id)
        return reminders._complete_sync(task_id)
    async def verify():
        try:
            bot.bot=FakeBot()
            bot.ai.ask_ai=no_ai
            bot.reminders.complete=complete
            claimed=reminders._claim_sync(draft["id"],draft["run_at"]+2)
            # Draft is in editing state; confirm the edit draft first to
            # atomically replace it as the active one.
            if not claimed:
                final=reminders._confirm_sync(edit["id"],901)
                assert final["ok"],final
                task=reminders._claim_sync(edit["id"],final["task"]["run_at"]+1)
            else:
                task=claimed
            assert task and task["execution_mode"]=="text"
            await bot.execute_plain_text_reminder(task)
            assert sent==[(901,"Оплати серверы!",{})]
            assert completed==[task["id"]]
            state=reminders._get_sync(task["id"])
            assert state["status"]=="scheduled" and state["occurrences_done"]==1
            print("PASS: text executes literally without LLM, no HTML parse mode, next event scheduled")

            card=bot.reminder_card_text(task)
            assert "💬 Обычное сообщение · без ИИ" in card and "Текст сообщения" in card
            keyboard=bot.reminder_keyboard(task)
            assert any("mode-menu" in button.callback_data for row in keyboard.inline_keyboard for button in row)
            print("PASS: mode switch button visible in rich/classic reminder card")
        finally:
            bot.bot=original_bot
            bot.ai.ask_ai=original_ai
            bot.reminders.complete=original_complete

    asyncio.run(verify())
print("ALL REMINDER MODES TESTS PASS")
