import asyncio
from types import SimpleNamespace as NS

import ai


async def main():
    names = (
        "get_client", "user_has_premium", "get_current_chat",
        "load_history", "save_history", "list_files",
        "read_memory", "is_model_available",
    )
    old = {name: getattr(ai, name) for name in names}
    calls = []

    class Client:
        def __init__(self):
            self.chat = NS(completions=NS(create=self.create))

        def create(self, **kwargs):
            calls.append(kwargs)
            msg = NS(content="ok", tool_calls=[])
            return NS(choices=[NS(message=msg, finish_reason="stop")])

    async def free(_uid):
        return False
    try:
        client = Client()
        ai.get_client = lambda _provider: client
        ai.user_has_premium = free
        ai.get_current_chat = lambda _uid: "1234567890123"
        ai.load_history = lambda *_args: []
        ai.save_history = lambda *_args: None
        ai.list_files = lambda *_args: ["FILE_CTX_MARKER.txt"]
        ai.read_memory = lambda *_args: "MEM_CTX_MARKER"
        ai.is_model_available = lambda _key: True

        answer = await ai.ask_ai(
            424242,
            "CURRENT_REQUEST_MARKER",
            "groq:gpt-oss-20b",
            "BASE_SYSTEM_MARKER",
            12,
            custom_prompt="CUSTOM_CTX_MARKER",
        )
        assert answer == "ok"
        messages = calls[0]["messages"]
        system = "\n".join(
            str(m.get("content") or "") for m in messages
            if m.get("role") == "system"
        )
        user = "\n".join(
            str(m.get("content") or "") for m in messages
            if m.get("role") == "user"
        )

        for marker in (
            "CUSTOM_CTX_MARKER", "MEM_CTX_MARKER",
            "FILE_CTX_MARKER.txt",
        ):
            assert marker not in system, (marker, system)
            assert marker in user, (marker, user)

        assert "CURRENT_REQUEST_MARKER" in user
        assert "ПРАВИЛА ДОВЕРИЯ" in system
        print("PASS: dynamic user context stays outside system role")
    finally:
        for name, value in old.items():
            setattr(ai, name, value)


asyncio.run(main())
