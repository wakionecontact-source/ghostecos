"""Offline scheduler regressions when a model never produces any content."""
import asyncio
from unittest.mock import patch

import bot


async def stub_true(*args,**kwargs):
    return True


async def stub_none(*args,**kwargs):
    return None


async def queued_requests_do_not_starve():
    started=asyncio.Event()
    running_ids=[]
    async def fake_process(uid,*args,**kwargs):
        running_ids.append(uid)
        if len(running_ids)>=2:
            started.set()
        await asyncio.sleep(60)
    with (
        patch.object(bot,"process_request",fake_process),
        patch.object(bot,"can_dispatch_now",lambda:True),
        patch.object(bot,"update_queue_statuses",stub_none),
    ):
        bot.pending_requests.clear()
        bot.pending_requests.extend([
            bot.QueuedRequest(101,101,"первый зависший запрос",None,0),
            bot.QueuedRequest(102,102,"второй независимый запрос",None,0),
        ])
        runner=asyncio.create_task(bot.process_pending_loop())
        try:
            await asyncio.wait_for(started.wait(),timeout=3)
            assert running_ids==[101,102],running_ids
            assert len(bot._queue_workers)==2
            print("PASS: stalled first model does not block second user's queued request")
        finally:
            runner.cancel()
            for task in list(bot._queue_workers):
                task.cancel()
            await asyncio.gather(runner,*list(bot._queue_workers),return_exceptions=True)
            bot._queue_workers.clear()
            bot.pending_requests.clear()


async def due_text_reminder_not_starved_by_ai():
    ai_started=asyncio.Event()
    delivered=asyncio.Event()
    due_count=0
    async def due(*args,**kwargs):
        nonlocal due_count
        due_count+=1
        if due_count==1:
            return [{"id":"task-ai","user_id":101,"execution_mode":"ai"}]
        if due_count==2:
            return [{"id":"task-text","user_id":102,"execution_mode":"text"}]
        return []
    async def claim(id):
        if id=="task-ai":
            return {"id":"task-ai","user_id":101,"execution_mode":"ai"}
        return {"id":"task-text","user_id":102,"execution_mode":"text"}
    async def model(*args):
        ai_started.set()
        await asyncio.sleep(60)
    async def literal_text(*args):
        delivered.set()
    with (
        patch.object(bot.reminders,"expire_pending",stub_none),
        patch.object(bot.reminders,"due",due),
        patch.object(bot.reminders,"claim",claim),
        patch.object(bot,"execute_scheduled_reminder",model),
        patch.object(bot,"execute_plain_text_reminder",literal_text),
        patch.object(bot,"can_dispatch_now",lambda:True),
        patch.object(bot,"is_user_busy",lambda *_:False),
        patch.object(bot,"register_dispatch",lambda:None),
    ):
        runner=asyncio.create_task(bot.reminders_loop())
        try:
            await asyncio.wait_for(ai_started.wait(),timeout=2)
            await asyncio.wait_for(delivered.wait(),timeout=7)
            assert len(bot._reminder_workers)==1
            print("PASS: text reminder is delivered while an AI reminder stays stalled")
        finally:
            runner.cancel()
            for task in list(bot._reminder_workers):
                task.cancel()
            await asyncio.gather(runner,*list(bot._reminder_workers),return_exceptions=True)
            bot._reminder_workers.clear()


async def main():
    await queued_requests_do_not_starve()
    await due_text_reminder_not_starved_by_ai()
    print("ALL BACKGROUND FAIRNESS TESTS PASSED")


asyncio.run(main())
