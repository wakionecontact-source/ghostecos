import asyncio
from types import SimpleNamespace
import bot as b

task={
    "id":"a"*32,
    "user_id":1,
    "telegram_chat_id":123,
    "ai_chat_id":"c",
    "model_key":"openrouter:space-bunny-alpha",
    "title":"Тест",
    "instruction":"Напомни",
    "run_at":1893456000,
    "status":"pending",
    "created_at":1,
    "updated_at":1,
    "expires_at":1893450000,
    "config_message_id":55,
    "confirm_button":"✅ Подтвердить",
    "cancel_button":"❌ Отменить",
    "attempts":0,
    "last_error":None,
    "recurrence":"once",
    "weekdays":"",
    "recurrence_day":1,
    "retry_at":None,
    "replaces_id":None,
    "schedule_json":"",
    "occurrences_done":0,
    "execution_mode":"ai",
    "timezone_name":"Europe/Moscow",
    "legacy_ui":1,
}

class FakeBot:
    def __init__(self):
        self.rich_calls=0
        self.sent=[]
        self.edits=[]
    async def __call__(self,*args,**kwargs):
        self.rich_calls+=1
        raise AssertionError("legacy task must never use rich API")
    async def send_message(self,chat_id,text,**kwargs):
        self.sent.append((chat_id,text,kwargs))
        return SimpleNamespace(message_id=99)
    async def edit_message_text(self,**kwargs):
        self.edits.append(kwargs)
        return SimpleNamespace(message_id=kwargs["message_id"])

async def main():
    original=b.bot
    fake=FakeBot()
    b.bot=fake
    try:
        msg,used_rich=await b.send_reminder_card(123,dict(task))
        assert used_rich is False
        assert msg.message_id==99
        assert fake.rich_calls==0
        scheduled=dict(task,status="scheduled")
        await b.refresh_reminder_card(scheduled,status="✅ Задание подтверждено")
        assert fake.rich_calls==0
        assert fake.edits and fake.edits[-1]["parse_mode"]=="HTML"
        print("PASS legacy reminder never reverts to RichMessage")
    finally:
        b.bot=original

asyncio.run(main())
