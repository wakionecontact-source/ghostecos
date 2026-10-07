import asyncio
from types import SimpleNamespace
import ai

class DummyCreate:
    async def create(self, **kwargs):
        raise AssertionError("network should be intercepted")

class DummyClient:
    def __init__(self):
        self.chat = SimpleNamespace(completions=DummyCreate())

async def main():
    old_get = ai.get_client
    old_retry = ai._request_with_single_retry
    seen = {}
    ai.get_client = lambda provider: DummyClient()
    async def fake_retry(factory, *args, **kwargs):
        coro = factory()
        coro.close()
        seen["called"] = True
        msg = SimpleNamespace(content="request")
        return SimpleNamespace(choices=[SimpleNamespace(message=msg)])
    ai._request_with_single_retry = fake_retry
    try:
        result = await ai.decide_rating_request(
            "что такое сила тяжести",
            "Сила тяжести — это...",
            "openrouter:space-bunny-alpha",
            "Последняя оценка: недавно. Тариф: Premium.",
        )
        assert result is True
        assert seen.get("called")
        print("PASS: hidden rating classifier")
    finally:
        ai.get_client = old_get
        ai._request_with_single_retry = old_retry

asyncio.run(main())
