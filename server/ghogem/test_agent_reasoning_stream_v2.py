"""Offline integration of streamed tool/reasoning/message chronology."""
import asyncio
import json
from types import SimpleNamespace as NS
from unittest.mock import patch

import agent_stream
import ai
import bot


def delta(*,content=None,reasoning_content=None,tools=None,reasoning_details=None):
    return NS(choices=[NS(
        finish_reason=None,
        delta=NS(content=content,reasoning_content=reasoning_content,
                 reasoning_details=reasoning_details,tool_calls=tools or []),
    )],usage=None)


def tools_delta(index,name=None,args=None,tid=None):
    return NS(
        index=index,id=tid,
        function=NS(name=name,arguments=args),
    )


class FakeStream:
    def __init__(self,chunks):
        self.chunks=chunks
        self.closed=False
    def __aiter__(self):
        self.index=0
        return self
    async def __anext__(self):
        if self.index>=len(self.chunks):
            raise StopAsyncIteration
        data=self.chunks[self.index]
        self.index+=1
        await asyncio.sleep(0)
        return data
    async def close(self):
        self.closed=True


async def case_streamed_openai_delta():
    stream=FakeStream([
        delta(reasoning_content="Сначала "),
        delta(reasoning_content="проверю."),
        delta(tools=[tools_delta(0,name="read_",tid="call_")]),
        delta(tools=[tools_delta(0,name="file",args='{"filename":')]),
        delta(tools=[tools_delta(0,args='"a.txt"}')]),
        delta(content="Гото"),
        delta(content="во"),
        NS(choices=[NS(finish_reason="tool_calls",delta=NS(content=None,tool_calls=[]))],usage=None),
    ])
    received=[]
    async def create(**kwargs):
        assert kwargs["stream"] is True
        return stream
    async def on_reasoning(chunk):
        received.append(("reasoning",chunk))
    async def on_content(text):
        received.append(("preview",text))
    out=await agent_stream.collect_completion(
        create,{"model":"test","messages":[]},
        on_reasoning=on_reasoning,on_content=on_content
    )
    assert stream.closed
    assert out._reasoning_streamed
    assert out.choices[0].finish_reason=="tool_calls"
    assert out.choices[0].message.content=="Готово"
    assert len(out.choices[0].message.tool_calls)==1
    call=out.choices[0].message.tool_calls[0]
    assert call.id=="call_" and call.function.name=="read_file"
    assert json.loads(call.function.arguments)=={"filename":"a.txt"}
    assert received==[
        ("reasoning","Сначала "),
        ("reasoning","проверю."),
        ("preview","Гото"),("preview","Готово"),
    ],received
    print("PASS: streamed reasoning + final text + fragmented tool JSON assembled")


async def case_partial_think_tag():
    stream=FakeStream([
        delta(content="<thi"),
        delta(content="nk>Первая"),
        delta(content=" часть</think>"),
        delta(content="Ответ "),
        delta(content="<think>Вторая"),
        delta(content=" мысль</think>"),
        delta(content="готов."),
        NS(choices=[NS(finish_reason="stop",delta=NS(content=None,tool_calls=[]))],usage=None),
    ])
    got=[]
    async def create(**kwargs):
        return stream
    async def reason(text):
        got.append(("reasoning",text))
    async def answer(text):
        got.append(("answer",text))
    result=await agent_stream.collect_completion(
        create,{"model":"test","messages":[]},
        on_reasoning=reason,on_content=answer
    )
    thought="".join(text for kind,text in got if kind=="reasoning")
    assert thought=="Первая частьВторая мысль",got
    visible=[text for kind,text in got if kind=="answer"]
    assert visible and visible[-1]=="Ответ готов.",visible
    assert not any("<think" in text or "<thi" in text for text in visible)
    assert result.choices[0].message.content.startswith("<think>")
    assert stream.closed
    print("PASS: partial <think> delimiters do not leak into answer preview")


async def case_full_ai_agent_chronology():
    create_calls=[]
    read_calls=[]
    records=[]

    async def fake_premium(_):
        return False

    class FakeClient:
        def __init__(self):
            self.chat=NS(completions=NS(create=self.create))
        async def create(self,**kwargs):
            index=len(create_calls)
            create_calls.append(kwargs)
            assert kwargs.get("stream") is True
            tools={x["function"]["name"] for x in kwargs.get("tools",[])}
            if index==0:
                assert "get_tool_instructions" in tools
                return FakeStream([
                    delta(reasoning_content="Нужны права на чтение файла."),
                    delta(tools=[tools_delta(0,name="get_tool_instructions",tid="t1",
                                             args='{"tool_name":"read_file"}')]),
                    NS(choices=[NS(finish_reason="tool_calls",delta=NS(content=None,tool_calls=[]))],usage=None),
                ])
            if index==1:
                assert "read_file" in tools
                return FakeStream([
                    delta(reasoning_content="Теперь прочитаю файл."),
                    delta(tools=[tools_delta(0,name="read_file",tid="t2",
                                             args='{"filename":"hello.txt"}')]),
                    NS(choices=[NS(finish_reason="tool_calls",delta=NS(content=None,tool_calls=[]))],usage=None),
                ])
            return FakeStream([
                delta(reasoning_content="Сверяю полученный текст."),
                delta(content="Файл "),
                delta(content="прочитан."),
                NS(choices=[NS(finish_reason="stop",delta=NS(content=None,tool_calls=[]))],usage=None),
            ])

    async def action(value,kind="action"):
        records.append((kind,value))
    async def reasoning(value):
        records.append(("reasoning",value))
    async def content(value):
        records.append(("content",value))
    def read(*args):
        read_calls.append(args)
        return "Содержимое файла."

    with (
        patch.object(ai,"get_client",lambda provider:FakeClient()),
        patch.object(ai,"user_has_premium",fake_premium),
        patch.object(ai,"load_history",lambda *a:[]),
        patch.object(ai,"save_history",lambda *a:None),
        patch.object(ai,"get_current_chat",lambda uid:"1234567890123"),
        patch.object(ai,"list_files",lambda *a:["hello.txt"]),
        patch.object(ai,"read_memory",lambda *a:""),
        patch.object(ai,"_read_file",read),
        patch.object(ai,"execute_file_commands",lambda value,*args:value),
        patch.object(ai,"is_model_available",lambda model:True),
    ):
        response=await ai.ask_ai(
            19910,"Прочитай hello.txt","groq:gpt-oss-20b",
            "Тест",4,on_action=action,on_reasoning=reasoning,
            on_text_chunk=content,allow_model_fallback=False
        )
    assert response=="Файл прочитан.",response
    assert len(create_calls)==3 and len(read_calls)==1,(len(create_calls),read_calls)
    indices=[i for i,(kind,_) in enumerate(records) if kind=="reasoning"]
    action_indices=[i for i,(kind,_) in enumerate(records) if kind=="action"]
    assert len(indices)==3 and len(action_indices)>=2,records
    assert indices[0]<action_indices[0]<indices[1]<action_indices[1]<indices[2],records
    assert records[-1]==("content","Файл прочитан."),records
    timeline=[]
    for kind,value in records:
        if kind in ("reasoning","action","done"):
            if kind=="reasoning":
                bot.append_agent_reasoning(timeline,value)
            else:
                timeline.append((kind,value))
    view=bot.format_agent_timeline(timeline)
    assert view.count("💭")==3
    assert view.count("Модель анализирует запрос…")==3
    assert "Нужны права" not in view and "Сверяю" not in view
    assert any(
        value in view for kind,value in timeline if kind in ("action","done")
    )
    assert "<blockquote" not in view  # wrapper is owned by Telegram
    print("PASS: real agent keeps tool chronology while provider trace text stays hidden")


async def case_telegram_single_interleaved_block():
    # Exercise the real Telegram handler's status edits and final rendering,
    # with no network calls and no actual messages.
    edits=[]
    posted=[]
    uid=495501

    async def get_model(*_):return ai.DEFAULT_MODEL_KEY
    async def noop(*args,**kwargs):return None
    async def premium(*args):return False
    async def idle(*args):
        await asyncio.sleep(60)
    async def passthrough(value,*args,**kwargs):
        return value

    async def send(chat_id,text,**kwargs):
        posted.append((chat_id,text,kwargs))
        return NS(message_id=449,chat=NS(id=chat_id))
    async def edit(**kwargs):
        edits.append(kwargs)
        return NS(message_id=kwargs["message_id"],chat=NS(id=kwargs["chat_id"]))

    async def scripted_agent(*args,**kwargs):
        action=kwargs["on_action"]
        reason=kwargs["on_reasoning"]
        content=kwargs["on_text_chunk"]
        await action("Читаю настройки",kind="action")
        await reason("До вызова проверил данные.")
        await action("Настройки получены",kind="done")
        await action("Читаю расписание",kind="action")
        await reason("После первого результата сопоставил даты.")
        await action("Расписание получено",kind="done")
        await content("Итог")
        return "Итог"

    with (
        patch.object(bot,"get_user_model",get_model),
        patch.object(bot,"ensure_chat_persisted",noop),
        patch.object(bot.ai,"is_model_retired",lambda _:False),
        patch.object(bot.db,"is_subscribed",premium),
        patch.object(bot.db,"get_custom_prompt",noop),
        patch.object(bot.bot,"send_message",send),
        patch.object(bot.bot,"edit_message_text",edit),
        patch.object(bot,"safe_react",noop),
        patch.object(bot,"keep_typing",idle),
        patch.object(bot.ai,"ask_ai",scripted_agent),
        patch.object(bot.ai,"read_memory",lambda uid:""),
        patch.object(bot.ai,"fulfill_fake_speech_calls",passthrough),
        patch.object(bot.ai,"fulfill_fake_file_calls",lambda value,*args:value),
        patch.object(bot.ai,"rescue_code_dumps_to_files",lambda value,*args:value),
        patch.object(bot.ai,"scrub_tool_simulation",lambda value:value),
    ):
        await bot.process_request(uid,uid,"Проверь настройки",None)
    assert len(posted)==1,posted
    assert posted[0][2]["reply_markup"].inline_keyboard[0][0].callback_data=="agent:stop"
    assert edits,edits
    final=edits[-1]["text"]
    assert final.count("🛠 <b>Ход работы</b>")==1,final
    assert "<b>Размышления модели</b>" not in final,final
    assert "<b>Рассуждение, переданное провайдером</b>" not in final,final
    for phrase in ("Настройки получены", "Расписание получено", "Итог"):
        assert phrase in final,(phrase,final)
    for phrase in (
        "До вызова проверил данные.",
        "После первого результата сопоставил даты.",
    ):
        assert phrase not in final,(phrase,final)
    assert (final.index("Настройки получены")
            < final.index("Расписание получено")
            < final.index("Итог")),final
    assert edits[-1]["reply_markup"]!=bot.agent_stop_keyboard()
    assert bot.user_status.get(uid) is None
    print("PASS: Telegram final response keeps tool progress but omits provider trace text")


async def main():
    await case_streamed_openai_delta()
    await case_partial_think_tag()
    await case_full_ai_agent_chronology()
    await case_telegram_single_interleaved_block()
    print("ALL STREAMED AGENT REASONING TESTS PASS")


asyncio.run(main())
