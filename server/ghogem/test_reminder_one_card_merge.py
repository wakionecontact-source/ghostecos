import asyncio
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from zoneinfo import ZoneInfo

import bot
import reminders
import schedule_v2

MSK=ZoneInfo("Europe/Moscow")

async def main():
    with TemporaryDirectory(prefix="ghogem-reminder-card-test-") as td:
        original=reminders.DB_PATH
        original_refresh=bot.refresh_reminder_card
        reminders.DB_PATH=str(Path(td)/"isolated.db")
        reminders._init_db()
        edits=[]
        async def fake_refresh(task,status=None):
            edits.append((task["id"],status))
        bot.refresh_reminder_card=fake_refresh
        try:
            cases=[
                datetime(2026,9,30,15,tzinfo=MSK),
                datetime(2026,9,30,19,tzinfo=MSK),
                datetime(2026,10,1,15,tzinfo=MSK),
                datetime(2026,10,1,19,tzinfo=MSK),
                datetime(2026,10,2,15,tzinfo=MSK),
                datetime(2026,10,2,19,tzinfo=MSK),
            ]
            task=reminders._create_draft_sync(
                1000001,1000001,"1740000000000","test",
                "Оплата серверов","Напомнить про оплату серверов",
                int(cases[0].timestamp()),"✅ Подтвердить","❌ Отменить",
                recurrence="once"
            )
            for dt in cases[1:]:
                msg=await bot.merge_reminder_into_one_card(
                    1000001,task["id"],
                    {"title":"Оплата серверов",
                     "instruction":"Напомнить про оплату серверов",
                     "run_at":dt.isoformat()}
                )
                assert "Добавлено в ту же карточку" in msg,msg
            rows=reminders._list_active_sync(1000001)
            assert len(rows)==1,rows
            t=rows[0]
            assert t["schedule_json"] and t["status"]=="pending"
            cfg=__import__("json").loads(t["schedule_json"])
            assert cfg["mode"]=="occurrences"
            assert len(cfg["occurrences"])==6
            assert len(edits)==5
            confirmation=reminders._confirm_sync(task["id"],1000001)
            assert confirmation["ok"]
            times=[]
            for _ in range(6):
                task=reminders._get_sync(task["id"])
                times.append(task["run_at"])
                assert reminders._claim_sync(task["id"],task["run_at"]+1)
                assert reminders._complete_sync(task["id"])["ok"]
            assert times==[int(dt.timestamp()) for dt in cases]
            assert reminders._get_sync(task["id"])["status"]=="completed"
            print("PASS one-card fallback: six create_reminder requests merged into ONE pending card")
            print("PASS six exact triggers, all delivered by scheduler, auto completed")
            # Other owner's try cannot mutate
            task2=reminders._create_draft_sync(
                1000002,1000002,"1740000000000","test","Other","Different",
                int(cases[0].timestamp()),"Confirm","Cancel",recurrence="once"
            )
            failed=await bot.merge_reminder_into_one_card(
                1000001,task2["id"],
                {"instruction":"Different","run_at":cases[1].isoformat()}
            )
            assert "недоступен" in failed
            print("PASS no cross-user mutation")
        finally:
            reminders.DB_PATH=original
            bot.refresh_reminder_card=original_refresh

asyncio.run(main())
