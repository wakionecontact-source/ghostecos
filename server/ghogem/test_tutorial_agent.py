import asyncio
import json
import os
import tempfile
from types import SimpleNamespace as NS

import db
import tutorial
import ai


def tool_response(name,args,idx):
    msg=NS(content="",tool_calls=[NS(id=f"t{idx}",function=NS(name=name,arguments=json.dumps(args)))])
    return NS(choices=[NS(message=msg,finish_reason="tool_calls")])


def text_response(text):
    return NS(choices=[NS(message=NS(content=text,tool_calls=[]),finish_reason="stop")])


def test_db_progress():
    old_path=db.DB_PATH
    fd,path=tempfile.mkstemp(prefix="ghogem-tutorial-",suffix=".db")
    os.close(fd)
    os.unlink(path)
    try:
        db.DB_PATH=path
        db._init_db()
        uid=99112233
        db._touch_user_sync(uid)
        state=db._get_tutorial_state_sync(uid)
        assert state["is_new_user"] is True,state
        assert state["topics"]=={},state
        state=db._mark_tutorial_topic_sync(uid,"reminders")
        assert state["topics"]["reminders"]["count"]==1,state
        state=db._mark_tutorial_topic_sync(uid,"reminders")
        assert state["topics"]["reminders"]["count"]==2,state
        print("PASS tutorial DB progress")
    finally:
        db.DB_PATH=old_path
        try: os.unlink(path)
        except FileNotFoundError: pass


async def test_agent():
    old={name:getattr(ai,name) for name in (
        "get_client","_request_with_single_retry","user_has_premium",
        "get_current_chat","load_history","save_history","list_files","read_memory",
        "is_model_available",
    )}
    old_get=ai.db.get_tutorial_state
    old_mark=ai.db.mark_tutorial_topic
    steps=[]; marks=[]; saved=[]

    class Client:
        def __init__(self): self.chat=NS(completions=NS(create=self.create))
        def create(self,**kwargs):
            steps.append(kwargs)
            idx=len(steps)
            visible={t["function"]["name"] for t in kwargs.get("tools",[])}
            system=next(m["content"] for m in kwargs["messages"] if m.get("role")=="system")
            assert "TUTORIAL STATE" in system
            assert "new_user=yes" in system
            if idx==1:
                assert visible=={"list_tools","get_tool_instructions"},visible
                return tool_response("get_tool_instructions",{"tool_name":"get_tutorial_instructions"},idx)
            if idx==2:
                assert "get_tutorial_instructions" in visible,visible
                return tool_response("get_tutorial_instructions",{"topic":"reminders"},idx)
            if idx==3:
                return tool_response("get_tool_instructions",{"tool_name":"mark_tutorial_explained"},idx)
            if idx==4:
                assert "mark_tutorial_explained" in visible,visible
                return tool_response("mark_tutorial_explained",{"topic":"reminders"},idx)
            return text_response("Напоминания объяснены по актуальной справке.")

    client=Client()
    async def no_premium(uid): return False
    async def request(factory,**kwargs):
        value=factory()
        return await value if asyncio.iscoroutine(value) else value
    async def fake_state(uid):
        return {"is_new_user":True,"age_seconds":120,"topics":{}}
    async def fake_mark(uid,topic):
        marks.append((uid,topic))
        return {
            "is_new_user":True,"age_seconds":120,
            "topics":{topic:{"explained_at":1,"count":1}},
        }

    try:
        ai.get_client=lambda provider:client
        ai._request_with_single_retry=request
        ai.user_has_premium=no_premium
        ai.get_current_chat=lambda uid:"tutorial-test"
        ai.load_history=lambda *args:[]
        ai.save_history=lambda *args:saved.append(args[2])
        ai.list_files=lambda *args:[]
        ai.read_memory=lambda *args:""
        ai.is_model_available=lambda key:True
        ai.db.get_tutorial_state=fake_state
        ai.db.mark_tutorial_topic=fake_mark
        answer=await ai.ask_ai(
            77112233,"как пользоваться напоминаниями?",
            "groq:gpt-oss-20b","Ты тестовый агент.",12,
        )
        assert answer=="Напоминания объяснены по актуальной справке.",answer
        assert marks==[(77112233,"reminders")],marks
        assert len(steps)==5,len(steps)
        print("PASS tutorial agent handshake + progress mark")
    finally:
        for name,value in old.items(): setattr(ai,name,value)
        ai.db.get_tutorial_state=old_get
        ai.db.mark_tutorial_topic=old_mark


def test_catalog():
    assert tutorial.resolve_topic("напоминания")=="reminders"
    assert tutorial.resolve_topic("музыка")=="ghosou"
    assert tutorial.resolve_topic("смена модели через ии")=="model_switch"
    payload=tutorial.instructions("варианты ответа")
    assert payload["ok"] and payload["topic"]=="choices",payload
    ctx=tutorial.system_context({"is_new_user":True,"age_seconds":3600,"topics":{"overview":{"count":1}}})
    assert "new_user=yes" in ctx and "overview" in ctx
    print("PASS tutorial catalog + system context")


async def main():
    test_db_progress()
    test_catalog()
    await test_agent()
    print("ALL TUTORIAL TESTS PASS")

asyncio.run(main())
