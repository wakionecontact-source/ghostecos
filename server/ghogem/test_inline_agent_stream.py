"""Offline streaming tests: fragmented tools/reasoning and same-block timeline."""
import asyncio
from types import SimpleNamespace as N
from unittest.mock import patch

import agent_stream
import ai
import bot


def chunk(*,content=None,reason=None,tools=(),end=None):
    return N(choices=[N(
        finish_reason=end,
        delta=N(content=content,reasoning_content=reason,
                tool_calls=list(tools)),
    )],usage=None)


class Stream:
    def __init__(self,chunks):
        self.chunks=list(chunks)
        self.closed=False
    async def __aiter__(self):
        for item in self.chunks:
            await asyncio.sleep(0)
            yield item
    async def close(self):
        self.closed=True


class Provider:
    def __init__(self,all_chats):
        self.responses=list(all_chats)
        self.calls=[]
        self.open_streams=[]
        self.chat=N(completions=N(create=self.create))
    async def create(self,**params):
        self.calls.append(params)
        assert params.get("stream") is True, "Agent must request a streamed response"
        stream=Stream(self.responses.pop(0))
        self.open_streams.append(stream)
        return stream


async def test_stream_aggregation():
    events=[]
    stream=Stream([
        chunk(reason="Сначала изучу"),
        chunk(reason=" данные."),
        chunk(content="Приступаю."),
        chunk(tools=[N(index=0,id="call_",function=N(name="list_",arguments="{"))]),
        chunk(tools=[N(index=0,id="001",function=N(name="tools",arguments='"limit":3}'))],end="tool_calls"),
    ])
    async def creator(**kwargs):
        assert kwargs["stream"] is True
        return stream
    async def reasoning(s):
        events.append(("reasoning",s))
    async def content(s):
        events.append(("content",s))
    response=await agent_stream.collect_completion(
        creator,{"model":"fake","messages":[]},
        on_reasoning=reasoning,on_content=content
    )
    msg=response.choices[0].message
    assert msg.content=="Приступаю."
    assert msg.tool_calls[0].id=="call_001"
    assert msg.tool_calls[0].function.name=="list_tools"
    assert msg.tool_calls[0].function.arguments=='{"limit":3}'
    assert events==[
        ("reasoning","Сначала изучу"),
        ("reasoning"," данные."),
        ("content","Приступаю."),
    ],events
    assert response.choices[0].finish_reason=="tool_calls"
    assert response._reasoning_streamed is True
    assert stream.closed
    print("PASS provider API delta reasoning, visible content, fragmented tool calls")

async def test_text_tags():
    visible=[];thought=[]
    chunks=[
        chunk(content="<thi"),
        chunk(content="nk>Считаю"),
        chunk(content=" значение"),
        chunk(content="</think>\nОтвет"),
    ]
    async def creator(**_):
        return Stream(chunks)
    r=await agent_stream.collect_completion(
        creator,{},on_reasoning=lambda v: thought.append(v) or asyncio.sleep(0),
        on_content=lambda v: visible.append(v) or asyncio.sleep(0),
    )
    assert "".join(thought)=="Считаю значение",thought
    assert visible and visible[-1].endswith("Ответ"),visible
    assert all("Считаю" not in entry for entry in visible)
    assert "<think>" in r.choices[0].message.content
    print("PASS streamed literal <think> is routed inline, never leaked in answer preview")

async def test_stream_cancel():
    raised=asyncio.Event()
    closed=asyncio.Event()
    class SlowStream:
        def __aiter__(self):return self
        async def __anext__(self):
            raised.set()
            await asyncio.sleep(60)
        async def close(self):closed.set()
    async def creator(**_):return SlowStream()
    runner=asyncio.create_task(agent_stream.collect_completion(creator,{}))
    await asyncio.wait_for(raised.wait(),timeout=2)
    runner.cancel()
    outcome=await asyncio.gather(runner,return_exceptions=True)
    assert isinstance(outcome[0],asyncio.CancelledError)
    assert closed.is_set()
    print("PASS streaming HTTP stream closes immediately on stop/cancel")

async def test_agent_loop_stream_interleaving():
    provider=Provider([
        [
            chunk(reason="Выбираю инструмент."),
            chunk(tools=[N(index=0,id="call_1",function=N(
                name="list_tools",arguments="{}"))],end="tool_calls"),
        ],
        [
            chunk(reason="Список инструментов получен."),
            chunk(content="Готово"),
            chunk(content="!"),
            chunk(end="stop"),
        ],
    ])
    timeline=[]
    previews=[]
    async def record_action(value,kind="action"):
        timeline.append((kind,value))
    async def record_thought(value):
        timeline.append(("reasoning",value))
    async def record_preview(value):
        previews.append(value)
    async def no_premium(_):return False
    with (
        patch.object(ai,"user_has_premium",no_premium),
        patch.object(ai,"get_client",lambda p:provider),
        patch.object(ai,"load_history",lambda *a:[]),
        patch.object(ai,"save_history",lambda *a:None),
        patch.object(ai,"get_current_chat",lambda _:"unit-chat"),
        patch.object(ai,"list_files",lambda *a:[]),
        patch.object(ai,"read_memory",lambda *a:""),
        patch.object(ai,"execute_file_commands",lambda answer,*_:answer),
    ):
        response=await asyncio.wait_for(ai.ask_ai(
            8877,"Ответь Готово!","groq:gpt-oss-20b","Тест",5,
            chat_id_override="unit-chat",
            on_action=record_action,on_reasoning=record_thought,
            on_text_chunk=record_preview,allow_model_fallback=False,
        ),timeout=15)
    assert response=="Готово!",repr(response)
    first_reason=next(i for i,e in enumerate(timeline) if e[0]=="reasoning")
    tool_start=next(i for i,e in enumerate(timeline) if "list_tools" in e[1] and e[0]=="action")
    tool_done=next(i for i,e in enumerate(timeline) if "list_tools" in e[1] and e[0]=="done")
    second_reason=next(i for i,e in enumerate(timeline) if e[0]=="reasoning" and "получен" in e[1])
    assert first_reason<tool_start<=tool_done<second_reason,timeline
    assert previews[-1]=="Готово!"
    assert len(provider.calls)==2
    assert all(s.closed for s in provider.open_streams)
    print("PASS agent tool handshake and interleaved reasoning streamed in chronological order")


async def test_telegram_timeline():
    assert bot.format_agent_timeline([
        ("action","Открываю поиск"),
        ("reasoning","Уточняю <слово>"),
        ("done","Поиск выполнен"),
        ("reasoning","Теперь отвечаю"),
    ])==(
        "• Открываю поиск\n"
        "💭 Модель анализирует запрос…\n"
        "• ✓ Поиск выполнен\n"
        "💭 Модель анализирует запрос…"
    )
    entries=[("action","Начинаю")]
    bot.append_agent_reasoning(entries,"Раз")
    bot.append_agent_reasoning(entries,"мышляю")
    entries.append(("done","Сделано"))
    bot.append_agent_reasoning(entries,"Проверяю")
    assert entries==[
        ("action","Начинаю"),
        ("thought","Модель анализирует запрос…"),
        ("done","Сделано"),
        ("thought","Модель анализирует запрос…"),
    ]
    print("PASS provider trace text is replaced by generic progress markers")


async def test_real_telegram_status_interleaving():
    initial=[]
    edited=[]
    async def mock_answer(*args,**kwargs):
        await kwargs["on_action"]("Сначала читаю поиск",kind="action")
        await kwargs["on_reasoning"]("Анализирую ")
        await kwargs["on_reasoning"]("найденные данные.")
        await kwargs["on_action"]("Поиск завершён",kind="done")
        await kwargs["on_reasoning"]("Теперь готовлю ответ.")
        await kwargs["on_text_chunk"]("Итог:")
        await kwargs["on_text_chunk"]("Итог: работает.")
        return "Итог: работает."
    async def fake_send(cid,content,*args,**kwargs):
        initial.append((cid,content,kwargs))
        return N(message_id=987,chat=N(id=cid))
    async def fake_edit(**kwargs):
        edited.append(kwargs)
        return N(message_id=kwargs["message_id"],chat=N(id=kwargs["chat_id"]))
    async def noop(*args,**kwargs):return None
    async def no_sub(_):return False
    async def model(_):return ai.DEFAULT_MODEL_KEY
    async def forever_typing(_):await asyncio.sleep(60)
    with (
        patch.object(bot.ai,"ask_ai",mock_answer),
        patch.object(bot.ai,"is_model_retired",lambda _:False),
        patch.object(bot.ai,"read_memory",lambda *args:""),
        patch.object(bot.ai,"fish_tts_available",lambda:False),
        patch.object(bot,"get_user_model",model),
        patch.object(bot,"ensure_chat_persisted",noop),
        patch.object(bot.db,"is_subscribed",no_sub),
        patch.object(bot.db,"get_custom_prompt",noop),
        patch.object(bot.bot,"send_message",fake_send),
        patch.object(bot.bot,"edit_message_text",fake_edit),
        patch.object(bot,"safe_react",noop),
        patch.object(bot,"keep_typing",forever_typing),
    ):
        await bot.process_request(9068,9068,"Проверка",None)
    final=edited[-1]["text"]
    assert initial[0][2]["reply_markup"].inline_keyboard[0][0].callback_data=="agent:stop"
    assert "Анализирую найденные данные." not in final,final
    assert "Теперь готовлю ответ." not in final,final
    assert "Размышления модели" not in final,final
    assert final.count("<blockquote expandable>")==1,final
    assert "Поиск завершён" in final,final
    assert final.index("Поиск завершён")<final.index("Итог: работает.")
    assert any(
        "🛠 <b>Ход работы</b>" in edit["text"]
        and "Поиск завершён" in edit["text"]
        for edit in edited[:-1]
    )
    assert all(
        "Анализирую найденные данные." not in edit["text"]
        and "Теперь готовлю ответ." not in edit["text"]
        for edit in edited
    )
    assert all("<blockquote expandable>" not in edit["text"] for edit in edited[:-1])
    assert bot.active_agent_runs.get(9068) is None
    print("PASS actual Telegram status streams reasoning inline and final has ONE chronology block")


async def main():
    await test_stream_aggregation()
    await test_text_tags()
    await test_stream_cancel()
    await test_agent_loop_stream_interleaving()
    await test_telegram_timeline()
    await test_real_telegram_status_interleaving()
    print("ALL INLINE STREAMING TESTS PASS")


asyncio.run(main())
