import asyncio
from types import SimpleNamespace
import ai

class DummyClient:
    pass

async def run_case(raw):
    original_get_client = ai.get_client
    original_retry = ai._request_with_single_retry
    try:
        ai.get_client = lambda provider: DummyClient()
        async def fake_retry(factory, *args, **kwargs):
            return SimpleNamespace(
                choices=[SimpleNamespace(
                    message=SimpleNamespace(content=raw)
                )]
            )
        ai._request_with_single_retry = fake_retry
        return await ai.decide_rating_request(
            "что такое сила тяжести",
            "Сила тяжести — это сила притяжения тела к Земле.",
            "openrouter:space-bunny-alpha",
            "Последний раз пользователь голосовал: 1 мин назад. Тариф: Premium.",
        )
    finally:
        ai.get_client = original_get_client
        ai._request_with_single_retry = original_retry

assert asyncio.run(run_case("request")) is True
assert asyncio.run(run_case("none")) is False
assert asyncio.run(run_case("REQUEST\n")) is True
print("PASS: hidden rating judge parses request/none without tools")
