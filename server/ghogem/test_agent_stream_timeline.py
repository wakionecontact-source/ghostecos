"""Mock SSE deltas: provider thought -> tool call -> provider thought -> visible final."""
import asyncio
from types import SimpleNamespace as N
import agent_stream
import bot


def ch(*,content=None,reasoning=None,finish=None,tools=None,usage=None):
    delta=N(content=content,reasoning_content=reasoning,tool_calls=tools or [])
    return N(choices=[N(delta=delta,finish_reason=finish)],usage=usage)

def tc(index,tid=None,name=None,args=None):
    return N(index=index,id=tid,function=N(name=name,arguments=args))

class Stream:
    def __init__(self,pieces):
        self.pieces=pieces
        self.closed=False
    async def __aiter__(self):
        for item in self.pieces:
            yield item
            await asyncio.sleep(0)
    async def close(self):
        self.closed=True

async def check():
    thought=[]
    answer=[]
    used=[]
    async def on_reasoning(delta):
        thought.append(delta)
        bot.append_agent_reasoning(used,delta)
    async def on_content(full):
        answer.append(full)
    def action(kind,text):
        used.append((kind,text))

    action("action","🔍 Начат поиск")
    source=Stream([
        ch(reasoning="Проверяю"),
        ch(reasoning=" запрос."),
        ch(tools=[tc(0,"call_01","web_search",'{"q":"')]),
        ch(tools=[tc(0,None,None,'latest AI"}')]),
        ch(finish="tool_calls"),
    ])
    async def create(**kw):
        assert kw["stream"] is True
        return source
    result=await agent_stream.collect_completion(create,{"model":"test"},on_reasoning=on_reasoning,on_content=on_content)
    assert source.closed
    assert result.choices[0].message.tool_calls[0].function.arguments=='{"q":"latest AI"}'
    assert result.choices[0].message.tool_calls[0].function.name=="web_search"
    action("done","🔍 Поиск завершён")
    later=Stream([ch(reasoning="Формирую ответ."),ch(content="Найдено"),ch(content=" 2 новости"),ch(finish="stop")])
    async def again(**kw):return later
    result2=await agent_stream.collect_completion(again,{"model":"test"},on_reasoning=on_reasoning,on_content=on_content)
    assert result2.choices[0].message.content=="Найдено 2 новости"
    assert answer==["Найдено","Найдено 2 новости"],answer
    assert used==[
        ("action","🔍 Начат поиск"),
        ("reasoning","Проверяю запрос."),
        ("done","🔍 Поиск завершён"),
        ("reasoning","Формирую ответ."),
    ],used
    timeline=bot.format_agent_timeline(used)
    assert timeline.index("Проверяю запрос")<timeline.index("Поиск завершён")<timeline.index("Формирую ответ")
    assert timeline.count("💭")==2 and "Отдельные размышления" not in timeline
    print("PASS: streamed public reasoning interleaved with tool result and final tokens")
    print("PASS: fragmented tool-call arguments reconstructed and stream closed")
    tagstream=Stream([ch(content="<think>Ду"),ch(content="маю</think>"),ch(content="Ответ"),ch(finish="stop")])
    seen=[]
    preview=[]
    async def create_tag(**kw):return tagstream
    r=await agent_stream.collect_completion(create_tag,{},on_reasoning=lambda x:seen.append(x),on_content=lambda x:preview.append(x))
    assert ''.join(seen)=="Думаю",seen
    assert preview[-1]=="Ответ",preview
    print("PASS: <think> tags streamed to timeline, not leaked into answer preview")

asyncio.run(check())
