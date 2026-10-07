import asyncio
import json
import os
import tempfile
from types import SimpleNamespace as NS
import ai

async def test_case(bypass=False):
    old = {name: getattr(ai, name) for name in (
        "get_client", "_request_with_single_retry", "user_has_premium",
        "get_current_chat", "load_history", "save_history",
        "list_files", "read_memory", "is_model_available", "_read_file",
    )}
    steps, read_count, history = [], [], []
    async def no_premium(uid):
        return False
    class Client:
        def __init__(self):
            self.chat = NS(completions=NS(create=self.create))
        def create(self, **kwargs):
            steps.append(kwargs)
            visible = {t["function"]["name"] for t in kwargs.get("tools", [])}
            idx = len(steps)
            if idx == 1 and not bypass:
                assert visible == {"list_tools", "get_tool_instructions"}, visible
                name, args = "get_tool_instructions", {"tool_name": "read_file"}
            elif idx == 1 and bypass:
                assert "read_file" not in visible
                name, args = "read_file", {"filename": "hello.txt"}
            elif idx == 2 and not bypass:
                assert "read_file" in visible, visible
                name, args = "read_file", {"filename": "hello.txt"}
            else:
                assert not bypass or read_count == [], read_count
                return NS(choices=[NS(message=NS(content="Конец.", tool_calls=[]), finish_reason="stop")])
            msg = NS(content="", tool_calls=[NS(id="t" + str(idx), function=NS(name=name, arguments=json.dumps(args)))])
            return NS(choices=[NS(message=msg, finish_reason="tool_calls")])
    async def request(factory, **kwargs):
        result=factory()
        return await result if asyncio.iscoroutine(result) else result
    def read(*args):
        read_count.append(args)
        return "file content"
    try:
        client = Client()
        ai.get_client = lambda provider: client
        ai._request_with_single_retry = request
        ai.user_has_premium = no_premium
        ai.get_current_chat = lambda uid: "1234567890123"
        ai.load_history = lambda *args: []
        ai.save_history = lambda *args: history.append(args[2])
        ai.list_files = lambda *args: ["hello.txt"]
        ai.read_memory = lambda *args: ""
        ai.is_model_available = lambda key: True
        ai._read_file = read
        ans = await ai.ask_ai(987654319, "Прочитай hello.txt", "groq:gpt-oss-20b", "Ты тестовый агент.", 12)
        assert ans == "Конец.", ans
        assert len(steps) == (2 if bypass else 3)
        assert len(read_count) == (0 if bypass else 1)
        assert history[-1][-1]["content"] == ans
    finally:
        for name, original in old.items():
            setattr(ai, name, original)

async def main():
    await test_case(False)
    print("PASS: first instructions unlock read_file on next round, then result/answer")
    await test_case(True)
    print("PASS: call without instructions is blocked at server boundary")

asyncio.run(main())
