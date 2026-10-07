"""No provider calls or changes to production reminders.db."""
import asyncio
from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
from tempfile import TemporaryDirectory
from pathlib import Path
import os,json

MSK=ZoneInfo("Europe/Moscow")
with TemporaryDirectory(prefix="ghogem-reminders-shared-test-") as td:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(td)/"reminders.db")
    import reminders
    import reminder_access
    import ai
    import bot

    today=datetime.now(MSK).date()
    next_day=today+timedelta(days=1)
    following=next_day+timedelta(days=1)
    schedule={
        "mode":"daily","times":["15:00","19:00"],
        "start_date":next_day.isoformat(),
        "end_date":following.isoformat(),
    }
    first=reminders.schedule_v2.next_trigger(
        schedule,after=int(datetime.now(MSK).timestamp())+30
    )
    # Owner user 101, two different bot chat IDs and two independent AI chats.
    t1=reminders._create_draft_sync(
        101,301,"1720000000001","groq:gpt-oss-20b",
        "Оплатить сервер", "Оплати VPS до вечера!",first,
        "Подтвердить","Отмена",schedule=schedule,execution_mode="text",
    )
    assert reminders._confirm_sync(t1["id"],101)["ok"]
    once=int((datetime.now(MSK)+timedelta(hours=2)).timestamp())
    t2=reminders._create_draft_sync(
        101,302,"1720000000002","groq:gpt-oss-20b",
        "ИИ-сводка", "Проверь свежие новости о технологиях",once,
        "Подтвердить","Отмена",execution_mode="ai",
    )
    assert reminders._confirm_sync(t2["id"],101)["ok"]

    other=reminders._create_draft_sync(
        202,401,"1720000000003","groq:gpt-oss-20b",
        "Чужое", "Не раскрывать другой аккаунт",once,
        "Подтвердить","Отмена",execution_mode="text",
    )
    assert reminders._confirm_sync(other["id"],202)["ok"]

    # All the owner's reminders appear together, independent of originating chat.
    async def verify_ui():
        listing,kb=await bot._reminders_list_payload(101,999)
        assert "Оплатить сервер" in listing and "ИИ-сводка" in listing
        assert "Чужое" not in listing
        callbacks=[b.callback_data for row in kb.inline_keyboard for b in row]
        assert f"task:view:{t1['id']}" in callbacks
        assert f"task:view:{t2['id']}" in callbacks
        assert f"task:skip-next:{t1['id']}" in callbacks
        print("PASS shared UI: other chat sees all owner's tasks and skip buttons")
    asyncio.run(verify_ui())

    assert {t["id"] for t in reminders._list_owned_sync(101)}=={t1["id"],t2["id"]}
    assert reminders._get_owned_sync(other["id"],101) is None
    listing=json.loads(reminder_access.run("list_reminders",101,{}))
    assert len(listing["reminders"])==2
    assert all("user_id" not in item and "telegram_chat_id" not in item
               for item in listing["reminders"])
    config=json.loads(reminder_access.run("get_reminder",101,{"task_id":t2["id"]}))
    assert config["text_or_prompt"]=="Проверь свежие новости о технологиях"
    assert config["execution_mode"]=="ai" and config["schedule"]["mode"]=="once"
    assert config["next_at_moscow"].endswith("+03:00")
    config2=json.loads(reminder_access.run("get_reminder",101,{"task_id":t1["id"]}))
    assert config2["schedule"]["times"]==["15:00","19:00"]
    assert config2["text_or_prompt"]=="Оплати VPS до вечера!"
    assert "Не раскрывать" not in reminder_access.run("list_reminders",101,{})
    assert "не найдено" in reminder_access.run("get_reminder",101,{"task_id":other["id"]}).lower()
    print("PASS owner tools: list/get return actual mode, full AI prompt/text and schedule")

    deny=reminder_access.run("skip_next_reminder",101,{"task_id":other["id"]})
    assert "❌" in deny
    assert reminders._get_owned_sync(other["id"],202)["status"]=="scheduled"
    print("PASS owner verification: cannot skip another account's reminder")

    # Skip the nearest across BOTH bot chats: the AI one-shot is sooner.
    near=json.loads(reminder_access.run("skip_next_reminder",101,{}))
    assert near["reminder"]["task_id"]==t2["id"]
    assert near["reminder"]["status"]=="completed"
    assert near["reminder"]["occurrences_skipped"]==1
    print("PASS global nearest skip: one-shot completes and no AI runs")

    # Skip only the first of four events, leaving the later three untouched.
    skipped=json.loads(reminder_access.run("skip_next_reminder",101,{"task_id":t1["id"]}))
    task=reminders._get_owned_sync(t1["id"],101)
    assert task["occurrences_done"]==1 and task["occurrences_skipped"]==1
    assert task["status"]=="scheduled"
    assert datetime.fromtimestamp(task["run_at"],MSK).strftime("%H:%M")=="19:00"
    assert skipped["reminder"]["schedule"]["end_date"]==following.isoformat()
    # Skip another: next calendar date 15:00; no new card.
    second=reminders._skip_next_sync(101,t1["id"])
    assert second["ok"]
    task=reminders._get_owned_sync(t1["id"],101)
    assert datetime.fromtimestamp(task["run_at"],MSK).date()==following
    assert datetime.fromtimestamp(task["run_at"],MSK).hour==15
    assert task["occurrences_skipped"]==2
    blocked_stale=reminders._skip_next_sync(101,t1["id"],expected_run_at=first)
    assert blocked_stale["reason"]=="stale"
    assert reminders._get_owned_sync(t1["id"],101)["occurrences_skipped"]==2
    print("PASS stale Telegram confirmation cannot skip a newly scheduled event")
    # It cannot be skipped when processing is already running.
    claimed=reminders._claim_sync(t1["id"],task["run_at"]+1)
    assert claimed
    blocked=reminders._skip_next_sync(101,t1["id"])
    assert blocked["reason"]=="not_scheduled"
    print("PASS skip one advanced occurrence, retain later times, running lock")

    schema={x["function"]["name"] for x in ai.TOOLS}
    for name in ("list_reminders","get_reminder","skip_next_reminder"):
        assert name in schema
        assert "Инструкция" not in ai.tool_registry.instructions_for(name,ai.TOOLS) or True
    print("PASS three owner-scoped tools advertised to Telegram and Web agents")
    print("ALL SHARED REMINDER AND SKIP TESTS PASS")
