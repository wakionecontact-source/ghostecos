import asyncio
from datetime import datetime,timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from zoneinfo import ZoneInfo

import bot, reminders

async def test():
    with TemporaryDirectory(prefix="ghogem-merge-test-") as folder:
        previous=reminders.DB_PATH
        reminders.DB_PATH=str(Path(folder)/"test_reminders.db")
        reminders._init_db()
        original=bot.refresh_reminder_card
        async def mock_refresh(*args,**kwargs):
            pass
        bot.refresh_reminder_card=mock_refresh
        try:
            day=datetime.now(ZoneInfo("Europe/Moscow")).date()+timedelta(days=1)
            stamps=[]
            for delta in range(3):
                dt=day+timedelta(days=delta)
                for hour in (15,19):
                    stamps.append(datetime(
                        dt.year,dt.month,dt.day,hour,
                        tzinfo=ZoneInfo("Europe/Moscow")
                    ).isoformat(timespec="minutes"))
            first=reminders._create_draft_sync(
                151515,151515,"1740000000000","groq:gpt-oss-20b",
                "Оплата серверов","Напомни оплатить серверы",
                reminders.parse_run_at(stamps[0]),"Да","Нет"
            )
            for stamp in stamps[1:]:
                result=await bot.merge_reminder_into_one_card(
                    151515,first["id"],{
                        "title":"Оплата серверов",
                        "instruction":"Напомни оплатить серверы",
                        "run_at":stamp,
                    }
                )
                assert result.startswith("✅"),result
            task=reminders._get_sync(first["id"])
            assert task["recurrence"]=="advanced" and task["schedule_json"]
            import json
            policy=json.loads(task["schedule_json"])
            assert policy["mode"]=="occurrences" and len(policy["occurrences"])==6
            active=reminders._list_active_sync(151515)
            assert len(active)==1,len(active)
            print("PASS: six create_reminder attempts MERGE into one pending card, six timestamps")
        finally:
            bot.refresh_reminder_card=original
            reminders.DB_PATH=previous

asyncio.run(test())
