"""Regression tests for short interactive-choice commands and JSON recovery."""
import asyncio
import json
from types import SimpleNamespace
import ai

assert ai.user_explicitly_requests_interactive_choice("сделай выбор")
assert ai.user_explicitly_requests_interactive_choice("покажи выбор")
assert ai.user_explicitly_requests_interactive_choice("создай вопрос с вариантами")
assert not ai.user_explicitly_requests_interactive_choice("сделай выбор за меня")
assert not ai.user_explicitly_requests_interactive_choice("выбери сам")
print("PASS classifier: short 'сделай выбор' is interactive, choose-for-me is not")

class FakeCompletions:
    def __init__(self):
        self.calls=[]
    async def create(self, **kwargs):
        self.calls.append(kwargs)
        payload={
            "question":"Что сделать с напоминанием «8:36»?",
            "options":["Отключить напоминание","Оставить напоминание"],
        }
        return SimpleNamespace(
            choices=[SimpleNamespace(
                message=SimpleNamespace(content=json.dumps(payload,ensure_ascii=False))
            )]
        )

class FakeClient:
    def __init__(self):
        self.chat=SimpleNamespace(completions=FakeCompletions())

async def main():
    fake=FakeClient()
    old_get=ai.get_client
    old_available=ai.is_model_available
    ai.get_client=lambda provider: fake
    ai.is_model_available=lambda model_key: True
    try:
        payload=await ai._recover_interactive_choice_payload(
            [
                {"role":"assistant","content":"Если напоминание «8:36» лишнее, скажи — отключу."},
                {"role":"user","content":"сделай выбор"},
            ],
            "сделай выбор",
            assistant_hint="Покажу интерактивную карточку.",
            model_key="groq:gpt-oss-20b",
            is_premium=True,
        )
    finally:
        ai.get_client=old_get
        ai.is_model_available=old_available
    assert payload=={
        "question":"Что сделать с напоминанием «8:36»?",
        "options":["Отключить напоминание","Оставить напоминание"],
    },payload
    assert fake.chat.completions.calls
    call=fake.chat.completions.calls[0]
    assert "tools" not in call
    print("PASS recovery: provider text JSON becomes validated choice payload without tools")

asyncio.run(main())

async def integration():
    import bot
    class RefusesToolCompletions:
        def __init__(self):
            self.calls=[]
        async def create(self,**kwargs):
            self.calls.append(kwargs)
            if "tools" not in kwargs:
                payload={
                    "question":"Что сделать с напоминанием «8:36»?",
                    "options":["Отключить напоминание","Оставить напоминание"],
                }
                return SimpleNamespace(choices=[SimpleNamespace(
                    message=SimpleNamespace(
                        content=json.dumps(payload,ensure_ascii=False),
                        tool_calls=[],
                    ),
                    finish_reason="stop",
                )],usage=None)
            return SimpleNamespace(choices=[SimpleNamespace(
                message=SimpleNamespace(
                    content="Сейчас покажу интерактивный выбор.",
                    tool_calls=[],
                ),
                finish_reason="stop",
            )],usage=None)

    completions=RefusesToolCompletions()
    fake=SimpleNamespace(chat=SimpleNamespace(completions=completions))
    saved=[]
    old={
        "get_client":ai.get_client,
        "load_history":ai.load_history,
        "save_history":ai.save_history,
        "list_files":ai.list_files,
        "read_memory":ai.read_memory,
        "get_current_chat":ai.get_current_chat,
        "user_has_premium":ai.user_has_premium,
    }
    ai.get_client=lambda provider: fake
    ai.load_history=lambda uid,cid:[
        {"role":"system","content":"old"},
        {"role":"assistant","content":"Если напоминание «8:36» лишнее, скажи — отключу."},
    ]
    ai.save_history=lambda uid,cid,messages:saved.extend(messages)
    ai.list_files=lambda uid,cid:[]
    ai.read_memory=lambda uid,cid=None:""
    ai.get_current_chat=lambda uid:"choice-recovery-integration"
    async def premium(uid): return True
    ai.user_has_premium=premium
    proposed=[]
    async def on_choice(args,model_key,chat_id):
        proposed.append(args)
        return json.dumps({
            "status":"awaiting_user_choice",
            "token":"recovered",
            "message_id":77,
        })
    try:
        result=await ai.ask_ai(
            82222,
            "сделай выбор",
            "groq:gpt-oss-20b",
            bot.SYSTEM_PROMPT,
            20,
            on_choice_proposed=on_choice,
            chat_id_override="choice-recovery-integration",
        )
    finally:
        for name,value in old.items():
            setattr(ai,name,value)
    assert result=="__GHOGEM_AWAITING_USER_CHOICE__",result
    assert proposed==[{
        "question":"Что сделать с напоминанием «8:36»?",
        "options":["Отключить напоминание","Оставить напоминание"],
    }],proposed
    assert any("tools" not in call for call in completions.calls), "recovery JSON call must be toolless"
    assert any(
        "Интерактивный вопрос пользователю" in str(m.get("content") or "")
        for m in saved if m.get("role")=="assistant"
    )
    print("PASS integration: repeated no-tool progress recovers into a real interactive card")

asyncio.run(integration())
