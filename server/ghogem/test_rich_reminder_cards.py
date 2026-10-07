"""Offline rich-message / fallback tests: no Telegram messages sent."""
import asyncio
import os
import re
from types import SimpleNamespace
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import bot as b
from aiogram.methods import SendRichMessage, EditMessageText
MSK=ZoneInfo("Europe/Moscow")
template = {
    "id":"abcdef0123456789abcdef0123456789",
    "title":"Оплатить <сервер> & хостинг",
    "instruction":"Оплата серверов GhostEcos",
    "run_at":int((datetime.now(MSK)+timedelta(days=1)).timestamp()),
    "recurrence":"daily",
    "weekdays":"",
    "confirm_button":"✅ Подтвердить",
    "cancel_button":"❌ Отменить",
    "telegram_chat_id":1234,
    "config_message_id":400,
    "status":"pending",
    "schedule_json":'{"mode":"next_days","days_count":3,"include_today":false,"times":["15:00","19:00"]}',
}
# Need normalized schedule for cards, since the bot stores a canonical schedule.
template["schedule_json"]=__import__('json').dumps(
    b.reminders.schedule_v2.normalize_schedule(
        {"mode":"next_days","days_count":3,"include_today":False,"times":["15:00","19:00"]})
)
card=b.rich_reminder_card(template)
assert 'type="callback_data"' not in card.html
assert '<tg-button' not in card.html
assert 'task:confirm:' not in card.html
assert 'task:cancel:' not in card.html
assert "Оплатить &lt;сервер&gt; &amp; хостинг" in card.html
assert len(b.rich_reminder_keyboard(template).inline_keyboard)==7
print("PASS: rich HTML has no in-message buttons; regular reply_markup is preserved")

calls=[]
class FakeBot:
    async def __call__(self, method):
        calls.append(method)
        if isinstance(method,SendRichMessage) and os.getenv("ACCEPT_RICH_BUT_UNPARSEABLE")=="1":
            raise RuntimeError(
                "Failed to deserialize object\n"
                "Content: {'ok': True, 'result': {'message_id': 9999, 'rich_message': {'blocks': [{'type':'buttons'}]}}}"
            )
        if isinstance(method,EditMessageText) and os.getenv("ACCEPT_RICH_BUT_UNPARSEABLE")=="1":
            raise RuntimeError(
                "Failed to deserialize object\n"
                "Content: {'ok': True, 'result': {'message_id': 9999, 'rich_message': {'blocks': [{'type':'buttons'}]}}}"
            )
        if isinstance(method,SendRichMessage) and os.getenv("REJECT_RICH")=="1":
            raise RuntimeError("unsupported")
        if isinstance(method,EditMessageText) and os.getenv("REJECT_EDIT")=="1":
            raise RuntimeError("cannot edit rich")
        return SimpleNamespace(message_id=777)
    async def send_message(self,*args,**kwargs):
        calls.append(("send_message",args,kwargs))
        return SimpleNamespace(message_id=778)
    async def edit_message_text(self,**kwargs):
        calls.append(("edit_message_text",kwargs))
        return True

async def main():
    original=b.bot
    b.bot=FakeBot()
    try:
        got,used_rich=await b.send_reminder_card(1234,template)
        assert got.message_id==777 and used_rich is True
        assert isinstance(calls[-1],SendRichMessage)
        assert calls[-1].rich_message.html==card.html
        assert '<tg-button' not in calls[-1].rich_message.html
        print("PASS: sends RichMessage without in-message buttons")

        finished={**template,"status":"scheduled"}
        await b.refresh_reminder_card(finished,status="Подтверждено")
        assert isinstance(calls[-1],EditMessageText)
        assert "tg-button" not in calls[-1].rich_message.html
        print("PASS: removes in-body confirmation buttons after approval")

        os.environ["REJECT_RICH"]="1"
        got,used_rich=await b.send_reminder_card(1234,template)
        assert got.message_id==778 and used_rich is False
        assert calls[-1][0]=="send_message"
        print("PASS: falls back to classic inline keyboard if rich unsupported")

        os.environ["REJECT_EDIT"]="1"
        await b.refresh_reminder_card(finished,status="Подтверждено")
        assert calls[-1][0]=="edit_message_text"
        print("PASS: fallback edit for legacy messages")

        os.environ.pop("REJECT_RICH",None)
        os.environ.pop("REJECT_EDIT",None)
        os.environ["ACCEPT_RICH_BUT_UNPARSEABLE"]="1"
        sent_before=len([x for x in calls if isinstance(x,tuple) and x[0]=="send_message"])
        got,used_rich=await b.send_reminder_card(1234,template)
        assert got.message_id==9999 and used_rich is True
        assert len([x for x in calls if isinstance(x,tuple) and x[0]=="send_message"])==sent_before
        print("PASS: accepted Telegram Rich response does not send a duplicate")
        edit_before=len([x for x in calls if isinstance(x,tuple) and x[0]=="edit_message_text"])
        await b.refresh_reminder_card(finished,status="Подтверждено")
        assert len([x for x in calls if isinstance(x,tuple) and x[0]=="edit_message_text"])==edit_before
        print("PASS: accepted edit with unknown rich blocks does not overwrite via fallback")
    finally:
        os.environ.pop("ACCEPT_RICH_BUT_UNPARSEABLE",None)
        b.bot=original
        os.environ.pop("REJECT_RICH",None)
        os.environ.pop("REJECT_EDIT",None)

asyncio.run(main())
print("ALL RICH REMINDER TESTS PASS")
