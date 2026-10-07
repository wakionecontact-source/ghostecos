"""Context splitter regression tests; no live provider calls."""
import asyncio
from types import SimpleNamespace
import ai

class FakeCompletions:
    def __init__(self):
        self.calls=[]
    async def create(self,**kwargs):
        self.calls.append(kwargs)
        text=kwargs["messages"][-1]["content"]
        content="NOTES\n"+text[:180]+"\n...\n"+text[-180:]
        msg=SimpleNamespace(content=content,tool_calls=[])
        return SimpleNamespace(choices=[SimpleNamespace(message=msg)])

class FakeClient:
    def __init__(self):
        self.chat=SimpleNamespace(completions=FakeCompletions())

async def main():
    short="короткий запрос"
    client=FakeClient()
    packed,split=await ai._compress_large_prompt_for_model(
        short,model_key="groq:gpt-oss-20b",provider="groq",
        model_id="fake",client=client,
    )
    assert not split and packed==short and not client.chat.completions.calls

    huge="НАЧАЛО-ТОЧНО\n"+("важный блок 12345 abcdef\n"*900)+"КОНЕЦ-ТОЧНО"
    packed,split=await ai._compress_large_prompt_for_model(
        huge,model_key="groq:gpt-oss-20b",provider="groq",
        model_id="fake",client=client,
    )
    assert split and len(client.chat.completions.calls)>1
    assert len(packed)<len(huge)
    assert "НАЧАЛО-ТОЧНО" in packed and "КОНЕЦ-ТОЧНО" in packed
    chunks=ai._split_context_text(huge,4800)
    assert len(chunks)>1
    assert all(len(c)<=4800 for c in chunks)
    assert "".join(chunks)==huge, "splitter must not drop whitespace or code chars"

    class ContextError(Exception):
        status_code=400
    assert ai.is_context_limit_error(
        ContextError("maximum context length exceeded: too many tokens")
    )
    print("ALL CONTEXT SPLITTER TESTS PASS")

asyncio.run(main())
