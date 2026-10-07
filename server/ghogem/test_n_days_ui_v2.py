"""Three-step N-days Telegram filter in an isolated reminders database."""
import asyncio
from datetime import datetime,timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS

import bot
import reminders
import schedule_v2

class TestMessage:
    def __init__(self,uid,content,chat):
        self.text=content
        self.from_user=NS(id=uid)
        self.chat=NS(id=chat)
        self.replies=[]
    async def reply(self,text,**kwargs):
        self.replies.append((text,kwargs))
class TestCallback:
    def __init__(self,uid,id_,chat):
        self.data=f"task:days-include:{id_}"
        self.from_user=NS(id=uid)
        self.message=NS(chat=NS(id=chat),message_id=1)
        self.answers=[]
    async def answer(self,*args,**kwargs):
        self.answers.append((args,kwargs))

async def run():
    with TemporaryDirectory(prefix="ghogem-days-ui-") as directory:
        previous_db=reminders.DB_PATH
        previous_refresh=bot.refresh_reminder_card
        previous_send=bot.bot.send_message
        uid=82827112
        reminders.DB_PATH=str(Path(directory)/"reminders.db")
        reminders._init_db()
        try:
            now=datetime.now(reminders.MOSCOW)
            future=int((now+timedelta(days=1)).timestamp())
            task=reminders._create_draft_sync(
                uid,uid,"1740000000000","test",
                "Оплата серверов","Напомнить оплатить серверы",
                future,"Подтвердить","Отменить"
            )
            async def fake_refresh(*args,**kwargs):
                return None
            outbound=[]
            async def fake_send(*args,**kwargs):
                outbound.append((args,kwargs))
                return NS(message_id=100)
            bot.refresh_reminder_card=fake_refresh
            bot.bot.send_message=fake_send
            bot.reminder_edits[uid]={"task_id":task["id"],
                                      "field":"days_count","chat_id":uid}
            first=TestMessage(uid,"3",uid)
            handled=await bot.handle_reminder_edit_message(first)
            assert handled and bot.reminder_edits[uid]["field"]=="days_inclusion"
            keyboard=first.replies[-1][1]["reply_markup"]
            assert len(keyboard.inline_keyboard)==2
            print("PASS UI step1: day count -> yes/no include-today buttons")
            query=TestCallback(uid,task["id"],uid)
            await bot.handle_reminder_callback(query)
            state=bot.reminder_edits[uid]
            assert state["field"]=="days_times" and state["include_today"] is True
            assert outbound and "укажи время" in str(outbound[-1]).lower()
            print("PASS UI step2: today inclusion -> prompt for times")
            message=TestMessage(uid,"15:00, 19:00",uid)
            handled=await bot.handle_reminder_edit_message(message)
            assert handled and uid not in bot.reminder_edits
            updated=reminders._get_sync(task["id"])
            assert updated["recurrence"]=="advanced" and updated["schedule_json"]
            import json
            cfg=json.loads(updated["schedule_json"])
            assert cfg["relative_filter"]=="next_days" and cfg["days_count"]==3
            assert cfg["times"]==["15:00","19:00"]
            print("PASS UI step3: one draft updated with 3-day twice-daily schedule")
            assert len(reminders._list_active_sync(uid))==1
            print("PASS no extra cards/tasks created")
        finally:
            bot.refresh_reminder_card=previous_refresh
            bot.bot.send_message=previous_send
            bot.reminder_edits.pop(uid,None)
            reminders.DB_PATH=previous_db

asyncio.run(run())
