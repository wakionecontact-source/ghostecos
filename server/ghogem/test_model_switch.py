import asyncio
import json
from types import SimpleNamespace as NS
import ai


def tool_response(name,args,idx):
    msg=NS(content="",tool_calls=[NS(id=f"t{idx}",function=NS(name=name,arguments=json.dumps(args)))])
    return NS(choices=[NS(message=msg,finish_reason="tool_calls")])


def text_response(text):
    return NS(choices=[NS(message=NS(content=text,tool_calls=[]),finish_reason="stop")])


async def run_case(prompt, *, expect_switch):
    old={name:getattr(ai,name) for name in (
        "get_client","get_groq_client","_request_with_single_retry","user_has_premium",
        "get_current_chat","load_history","save_history","list_files","read_memory",
        "is_model_available",
    )}
    groq_calls=[]
    mistral_calls=[]
    saved=[]

    class GroqClient:
        def __init__(self): self.chat=NS(completions=NS(create=self.create))
        def create(self,**kwargs):
            groq_calls.append(kwargs)
            idx=len(groq_calls)
            visible={t["function"]["name"] for t in kwargs.get("tools",[])}
            if idx==1:
                assert visible=={"list_tools","get_tool_instructions"},visible
                return tool_response("get_tool_instructions",{"tool_name":"switch_model"},idx)
            if idx==2:
                assert "switch_model" in visible,visible
                return tool_response("switch_model",{"model":"Ministral 8B"},idx)
            # Unauthorized case continues on the old model after server denial.
            return text_response("Смена отклонена сервером.")

    class MistralClient:
        def __init__(self): self.chat=NS(completions=NS(create=self.create))
        def create(self,**kwargs):
            mistral_calls.append(kwargs)
            system=next(m["content"] for m in kwargs["messages"] if m.get("role")=="system")
            assert "Ministral 3 8B" in system or "mistral:ministral-8b" in system,system[:500]
            return text_response("Готово, теперь отвечаю новой моделью.")

    groq=GroqClient(); mistral=MistralClient()
    def get_client(provider):
        return mistral if provider=="mistral" else groq
    async def no_premium(uid): return False
    async def request(factory,**kwargs):
        result=factory()
        return await result if asyncio.iscoroutine(result) else result

    try:
        ai.get_client=get_client
        ai.get_groq_client=lambda index=0:groq
        ai._request_with_single_retry=request
        ai.user_has_premium=no_premium
        ai.get_current_chat=lambda uid:"switch-test"
        ai.load_history=lambda *args:[]
        ai.save_history=lambda *args:saved.append(args[2])
        ai.list_files=lambda *args:[]
        ai.read_memory=lambda *args:""
        ai.is_model_available=lambda key:True
        holder=["groq:gpt-oss-20b"]
        answer=await ai.ask_ai(
            987650001,prompt,"groq:gpt-oss-20b","Ты тестовый агент.",12,
            model_holder=holder,
        )
        if expect_switch:
            assert holder==["mistral:ministral-8b"],holder
            assert mistral_calls,"new provider/model was never invoked"
            assert answer=="Готово, теперь отвечаю новой моделью.",answer
        else:
            assert holder==["groq:gpt-oss-20b"],holder
            assert not mistral_calls,mistral_calls
            assert answer=="Смена отклонена сервером.",answer
        return len(groq_calls),len(mistral_calls)
    finally:
        for name,value in old.items(): setattr(ai,name,value)


async def main():
    a=await run_case("переключись на Ministral 8B",expect_switch=True)
    print("PASS authorized hot switch",a)
    b=await run_case("расскажи, чем Ministral 8B отличается от других моделей",expect_switch=False)
    print("PASS autonomous switch blocked",b)
    c=await run_case("смени модель на Qwen 3.8 27B",expect_switch=False)
    print("PASS model cannot substitute a different target",c)

asyncio.run(main())
