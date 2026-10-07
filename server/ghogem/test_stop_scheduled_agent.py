"""Offline integration for stopping a running scheduled AI firing."""
import asyncio
import os
from datetime import datetime,timedelta
from tempfile import TemporaryDirectory
from pathlib import Path
from zoneinfo import ZoneInfo
from types import SimpleNamespace
from unittest.mock import patch

with TemporaryDirectory(prefix="ghogem-stop-scheduled-") as temp:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(temp)/"reminders.db")
    import reminders
    import bot
    MSK=ZoneInfo("Europe/Moscow")

    uid=9791
    cid=8791
    today=(datetime.now(MSK)+timedelta(days=1)).date()
    end=today+timedelta(days=1)
    schedule={
        "mode":"daily",
        "start_date":today.isoformat(),
        "end_date":end.isoformat(),
        "times":["15:00","19:00"],
    }
    plan=reminders._create_draft_sync(
        uid,cid,"1740000000000","groq:gpt-oss-20b",
        "ИИ-тест","Проверь новости",0,"Подтвердить","Отмена",
        schedule=schedule,execution_mode="ai"
    )
    assert reminders._confirm_sync(plan["id"],uid)["ok"]
    task=reminders._claim_sync(plan["id"],plan["run_at"]+1)
    assert task and task["status"]=="running"

    class Message:
        message_id=308
        chat=SimpleNamespace(id=cid)

    class Query:
        from_user=SimpleNamespace(id=uid)
        message=Message()
        async def answer(self,text="",**kwargs):
            pass

    starts=asyncio.Event()
    updates=[]
    sent=[]
    async def send(cid,text,**kw):
        sent.append((cid,text,kw))
        return Message()
    async def edit(**kw):
        updates.append(kw)
    async def stay_waiting(*args,**kwargs):
        starts.set()
        await asyncio.sleep(60)
    async def typing(*args,**kwargs):
        await asyncio.sleep(60)
    async def empty_custom(*args,**kw):
        return None

    async def run():
        with (
            patch.object(bot.bot,"send_message",send),
            patch.object(bot.bot,"edit_message_text",edit),
            patch.object(bot,"keep_typing",typing),
            patch.object(bot.db,"get_custom_prompt",empty_custom),
            patch.object(bot.ai,"ask_ai",stay_waiting),
        ):
            runner=asyncio.create_task(bot.execute_scheduled_reminder(task))
            await asyncio.wait_for(starts.wait(),timeout=5)
            assert bot.active_agent_runs[uid]["reminder_id"]==task["id"]
            assert sent[0][2]["reply_markup"].inline_keyboard[0][0].callback_data=="agent:stop"
            await bot.cb_stop_active_agent(Query())
            await asyncio.wait_for(runner,timeout=5)
            assert uid not in bot.user_status
            assert uid not in bot.active_agent_runs
            assert any("Выполнение напоминания остановлено" in update["text"]
                       for update in updates)
    asyncio.run(run())
    current=reminders._get_owned_sync(task["id"],uid)
    assert current["status"]=="scheduled" and current["occurrences_done"]==1
    assert current["occurrences_skipped"]==1
    next_date=datetime.fromtimestamp(current["run_at"],MSK)
    assert next_date.date()==today and next_date.hour==19
    print("PASS: scheduled agent Stop interrupts inference, records one skip, keeps other firings")

    once=reminders._create_draft_sync(
        uid,cid,"1740000000000","groq:gpt-oss-20b",
        "Разово","Проверка",int((datetime.now(MSK)+timedelta(days=1)).timestamp()),
        "ОК","Нет",execution_mode="ai"
    )
    assert reminders._confirm_sync(once["id"],uid)["ok"]
    claimed=reminders._claim_sync(once["id"],once["run_at"]+1)
    result=reminders._skip_running_sync(once["id"],uid)
    assert result["ok"] and result["task"]["status"]=="completed"
    assert result["task"]["occurrences_skipped"]==1
    assert reminders._skip_running_sync(once["id"],uid)["ok"] is False
    print("PASS: stop on one-time AI task completes without retry or duplicate skip")
    print("ALL SCHEDULED STOP TESTS PASSED")
