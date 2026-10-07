"""No live account access; all writes are in a temporary reminders DB."""
import asyncio
from datetime import datetime,timedelta
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from zoneinfo import ZoneInfo

with TemporaryDirectory(prefix="ghogem-direct-convert-") as td:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(td)/"reminders.db")
    import reminders,reminder_access,bot
    uid=88346
    now=datetime.now(ZoneInfo("Europe/Moscow"))
    sch={
        "mode":"daily",
        "start_date":(now+timedelta(days=1)).date().isoformat(),
        "end_date":(now+timedelta(days=3)).date().isoformat(),
        "times":["15:00","19:00"]
    }
    future=int((now+timedelta(days=1)).timestamp())
    def create(name,instruction,owner=uid,schedule=None):
        draft=reminders._create_draft_sync(
            owner,owner,"1740000000000","groq:gpt-oss-20b",
            name,instruction,future,
            "Подтвердить","Отменить",
            schedule=schedule,execution_mode="ai",
        )
        return reminders._confirm_sync(draft["id"],owner)["task"]

    payment=create("Оплата в 15:00 и проверка в 19:00",
                   "Напомни оплатить сервер",schedule=sch)
    homework=create("Сделать домашнее задание",
                    "Напомни пользователю waki сделать домашнее задание")
    foreign=create("Оплатить чужой сервер","Не раскрывать",owner=29485)
    sample1="вот им обоим поставь режимы текста, ну и собствено текст напиши для напоминалки"
    sample2="да емае, измени уже не на промты ии, а на тектовый ответ напоминалки, я все исправил в коде, давай"
    assert reminder_access.is_direct_text_conversion_request(sample1)
    assert reminder_access.is_direct_text_conversion_request(sample2)
    assert not reminder_access.is_direct_text_conversion_request("покажи мне напоминания, и даты")
    assert not reminder_access.is_direct_text_conversion_request("сделай сайт с текстовым режимом")
    assert not reminder_access.is_direct_text_conversion_request("поставь напоминалку завтра в 15:00 в текстовом режиме")
    print("PASS: correctly recognizes both real user messages, ignores unrelated/new")

    response=reminder_access.change_existing_to_text_direct(uid,sample1)
    assert response is not None and len(response["changed_ids"])==2,response
    assert len(reminders._list_owned_sync(uid))==2
    for old in (payment,homework):
        task=reminders._get_owned_sync(old["id"],uid)
        assert task["execution_mode"]=="text"
        assert task["instruction"] and "Напомни пользователю" not in task["instruction"]
        assert task["run_at"]==old["run_at"]
        assert task["schedule_json"]==old["schedule_json"]
    assert reminders._get_owned_sync(foreign["id"],29485)["execution_mode"]=="ai"
    print("PASS: converts exactly two existing owner tasks, preserves IDs and schedules")

    repeated=reminder_access.change_existing_to_text_direct(uid,sample2)
    assert repeated is not None and repeated["changed_ids"]==[],repeated
    assert "Уже работают без ИИ" in repeated["message"]
    assert len(reminders._list_owned_sync(uid))==2
    print("PASS: already completed action gives factual no-op instead of model error")

    # Direct command must bypass model/queue even if selected model is offline.
    received=[]
    previous={
        "touch":bot.db.touch_user,
        "pending":bot.try_handle_pending_api_key,
        "edit":bot.handle_reminder_edit_message,
        "refresh":bot.refresh_reminder_card,
        "submit":bot.submit_prompt,
    }
    class StubMessage:
        text=sample2
        from_user=SimpleNamespace(id=uid)
        async def answer(self,text,**kwargs):
            received.append(text)
    async def ignored(*args,**kwargs):
        return False
    async def touch(uid):
        return None
    async def refresh(*args,**kwargs):
        return None
    async def never_model(*args,**kwargs):
        raise AssertionError("LLM or agent must not run for direct text mode switch")
    async def run():
        bot.db.touch_user=touch
        bot.try_handle_pending_api_key=ignored
        bot.handle_reminder_edit_message=ignored
        bot.refresh_reminder_card=refresh
        bot.submit_prompt=never_model
        try:
            await bot.handle_message(StubMessage())
        finally:
            bot.db.touch_user=previous["touch"]
            bot.try_handle_pending_api_key=previous["pending"]
            bot.handle_reminder_edit_message=previous["edit"]
            bot.refresh_reminder_card=previous["refresh"]
            bot.submit_prompt=previous["submit"]
    asyncio.run(run())
    assert received and "Уже работают без ИИ" in received[0]
    print("PASS: real Telegram text handler bypasses silent LLM and returns result")

    other=create("Серверы снова","Напомни про серверы")
    assert reminder_access.change_existing_to_text_direct(
        uid,sample1)["changed_ids"]==[], "more than 2 active should ask clarification"
    assert reminders._get_owned_sync(other["id"],uid)["execution_mode"]=="ai"
    print("PASS: ambiguous 3+ tasks refused without modifying database")
    print("ALL DIRECT TEXT FALLBACK TESTS PASS")
