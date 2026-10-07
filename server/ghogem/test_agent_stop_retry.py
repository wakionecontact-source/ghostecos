"""Offline checks: retry all empty outputs, optional API reasoning, Stop button."""
import asyncio
from types import SimpleNamespace
from unittest.mock import patch
import ai
import bot


def reply(text, *, reasoning=None, reasoning_tokens=0):
    msg=SimpleNamespace(content=text,tool_calls=[],reasoning_content=reasoning)
    usage=SimpleNamespace(
        completion_tokens=len(text),
        completion_tokens_details=SimpleNamespace(reasoning_tokens=reasoning_tokens),
    )
    return SimpleNamespace(
        choices=[SimpleNamespace(finish_reason="stop",message=msg)],
        usage=usage,
    )


class FakeClient:
    def __init__(self, replies):
        self.replies=list(replies)
        self.calls=[]
        self.started=asyncio.Event()
        self.chat=SimpleNamespace(completions=SimpleNamespace(create=self.create))
    async def create(self,**kwargs):
        self.calls.append(kwargs)
        self.started.set()
        return self.replies.pop(0) if self.replies else reply("")


async def stub_premium(_):
    return False


async def try_agent(fake_client,on_reasoning=None):
    action_messages=[]
    async def action(text,kind=None):
        action_messages.append((text,kind))
    with (
        patch.object(ai,"user_has_premium",stub_premium),
        patch.object(ai,"get_client",lambda p: fake_client),
        patch.object(ai,"load_history",lambda *a: []),
        patch.object(ai,"save_history",lambda *a: None),
        patch.object(ai,"get_current_chat",lambda uid: "test-chat"),
        patch.object(ai,"list_files",lambda *a: []),
        patch.object(ai,"read_memory",lambda *a: ""),
        patch.object(ai,"execute_file_commands",lambda text,*a: text),
    ):
        result=await ai.ask_ai(
            1234,"Скажи ОК","groq:gpt-oss-20b","Тест",4,
            chat_id_override="test-chat",on_action=action,
            on_reasoning=on_reasoning,allow_model_fallback=False,
        )
    return result,action_messages


async def case_retry_until_visible():
    # Current reliability policy: one unchanged retry for an empty completion,
    # then fallback/error instead of an unbounded empty-response loop.
    fake=FakeClient([
        reply(""),
        reply("Готово!",reasoning="Рассуждение, полученное от провайдера."),
    ])
    delivered=[]
    async def reasoning(text):delivered.append(text)
    result,actions=await asyncio.wait_for(
        try_agent(fake,on_reasoning=reasoning),timeout=18
    )
    assert result=="Готово!",result
    assert len(fake.calls)==2
    assert any("Повторяю" in text or "повторяю" in text for text,_ in actions)
    assert fake.calls[0]["model"]==fake.calls[-1]["model"]
    assert delivered==["Рассуждение, полученное от провайдера."]
    print("PASS: one empty response is retried once; reasoning captured")


async def case_reasoning_only_then_answer():
    fake=FakeClient([reply("<think>Проверяю данные.</think>"),reply("Готово!")])
    delivered=[]
    async def reasoning(text):delivered.append(text)
    result,_=await asyncio.wait_for(
        try_agent(fake,on_reasoning=reasoning),timeout=10
    )
    assert result=="Готово!",result
    assert len(fake.calls)==2
    assert delivered==["Проверяю данные."],delivered
    print("PASS: thinking-only payload is retried; provider text displayed when exposed")


async def case_cancel_in_backoff():
    fake=FakeClient([])
    runner=asyncio.create_task(try_agent(fake))
    await fake.started.wait()
    await asyncio.sleep(0.03)
    runner.cancel()
    result=await asyncio.gather(runner,return_exceptions=True)
    assert isinstance(result[0],asyncio.CancelledError),result
    calls=len(fake.calls)
    await asyncio.sleep(0.08)
    assert len(fake.calls)==calls
    print("PASS: empty-output retry stops immediately on asyncio cancellation")


class StubMessage:
    def __init__(self,message_id,chat_id):
        self.message_id=message_id
        self.chat=SimpleNamespace(id=chat_id)
    async def edit_text(self,*args,**kwargs):
        raise AssertionError("not expected")


class StubQuery:
    def __init__(self,uid,cid,mid):
        self.from_user=SimpleNamespace(id=uid)
        self.message=StubMessage(mid,cid)
        self.notices=[]
    async def answer(self,text="",**kwargs):
        self.notices.append(text)


async def case_callback_owner_only():
    task=asyncio.create_task(asyncio.sleep(60))
    bot.active_agent_runs[135]={"task":task,"chat_id":9,"message_id":71}
    try:
        wrong=StubQuery(136,9,71)
        await bot.cb_stop_active_agent(wrong)
        assert not task.cancelled()
        stale=StubQuery(135,9,72)
        await bot.cb_stop_active_agent(stale)
        assert not task.cancelled()
        authorized=StubQuery(135,9,71)
        await bot.cb_stop_active_agent(authorized)
        await asyncio.gather(task,return_exceptions=True)
        assert task.cancelled()
        assert "Останавливаю" in authorized.notices[0]
    finally:
        bot.active_agent_runs.clear()
    print("PASS: Stop button rejects other owners/old messages, cancels correct task")


async def case_complete_active_stop():
    requests=[]
    started=asyncio.Event()
    all_edits=[]

    async def pending_model(*args,**kwargs):
        on_action=kwargs.get("on_action")
        if on_action:
            await on_action("Тестовый шаг до остановки",kind="action")
            await on_action("Тестовый шаг завершён",kind="done")
        started.set()
        await asyncio.sleep(60)
        raise AssertionError("Model must be cancelled")

    async def send_message(cid,body,*args,**kwargs):
        requests.append((cid,body,kwargs))
        return StubMessage(303,cid)

    async def edit_message_text(**kwargs):
        all_edits.append(kwargs)
        return StubMessage(kwargs["message_id"],kwargs["chat_id"])

    async def idle_typing(*args):
        await asyncio.sleep(60)

    async def no_status(*args):
        return False

    async def model_key(*args):
        return ai.DEFAULT_MODEL_KEY

    async def noop(*args,**kwargs):
        return None

    with (
        patch.object(bot.ai,"ask_ai",pending_model),
        patch.object(bot.ai,"read_memory",lambda *args: ""),
        patch.object(bot,"get_user_model",model_key),
        patch.object(bot,"ensure_chat_persisted",noop),
        patch.object(bot.ai,"is_model_retired",lambda _:False),
        patch.object(bot.db,"is_subscribed",no_status),
        patch.object(bot.db,"get_custom_prompt",noop),
        patch.object(bot.bot,"send_message",send_message),
        patch.object(bot.bot,"edit_message_text",edit_message_text),
        patch.object(bot,"keep_typing",idle_typing),
    ):
        runner=asyncio.create_task(bot.process_request(233,233,"Привет",None))
        await asyncio.wait_for(started.wait(),timeout=5)
        assert len(requests)==1
        assert requests[0][2]["reply_markup"].inline_keyboard[0][0].callback_data=="agent:stop"
        await bot.cb_stop_active_agent(StubQuery(233,233,303))
        await asyncio.wait_for(runner,timeout=5)
        assert bot.user_status.get(233) is None
        assert 233 not in bot.active_agent_runs
        assert len(requests)==1
        stopped=[event["text"] for event in all_edits if "Генерация остановлена" in event["text"]]
        assert stopped
        assert "Ход работы" in stopped[-1]
        assert "Тестовый шаг завершён" in stopped[-1]
    print("PASS: Stop preserves completed work timeline and cleans state")


async def main():
    await case_retry_until_visible()
    await case_reasoning_only_then_answer()
    await case_cancel_in_backoff()
    await case_callback_owner_only()
    await case_complete_active_stop()
    print("ALL STOP/EMPTY RESPONSE TESTS PASSED")

asyncio.run(main())
