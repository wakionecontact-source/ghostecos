import asyncio
import types
import ai

class RateLimitError(Exception):
    status_code = 429

class FakeCompletions:
    async def create(self, **kwargs):
        raise RateLimitError("429 rate limit exceeded")

class FakeClient:
    def __init__(self):
        self.chat = types.SimpleNamespace(completions=FakeCompletions())

async def main():
    model = ai.DEFAULT_MODEL_KEY
    provider = ai.AVAILABLE_MODELS[model]["provider"]
    fake = FakeClient()

    old_client = ai._CLIENTS.get(provider)
    old_groq = list(ai.groq_clients)
    old_premium = ai.user_has_premium
    old_tutorial = ai.db.get_tutorial_state
    old_user_key = ai.db.get_user_key_any
    old_pool = ai.db.get_active_keys

    async def premium(_uid): return False
    async def tutorial(_uid): return {"is_new_user": False, "age_seconds": 0, "topics": {}}
    async def no_key(_uid, _provider): return None
    async def no_pool(_provider): return []

    try:
        ai._CLIENTS[provider] = fake
        if provider == "groq":
            ai.groq_clients[:] = [fake]
        ai.user_has_premium = premium
        ai.db.get_tutorial_state = tutorial
        ai.db.get_user_key_any = no_key
        ai.db.get_active_keys = no_pool
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

        holder=[model]
        try:
            await ai.ask_ai(
                991003,
                "привет",
                model,
                "",
                1,
                model_holder=holder,
                allow_rate_limit_fallback=False,
            )
        except ai.ProviderRateLimitError:
            pass
        else:
            raise AssertionError("Expected ProviderRateLimitError")

        assert holder == [model], holder
        print("PASS live 429 does not switch model when setting is off")
    finally:
        ai._CLIENTS[provider] = old_client
        ai.groq_clients[:] = old_groq
        ai.user_has_premium = old_premium
        ai.db.get_tutorial_state = old_tutorial
        ai.db.get_user_key_any = old_user_key
        ai.db.get_active_keys = old_pool
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

asyncio.run(main())
