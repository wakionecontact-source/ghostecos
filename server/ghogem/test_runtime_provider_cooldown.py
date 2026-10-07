"""Offline regression for runtime 429/timeout routing cooldowns."""
import asyncio
import time
import ai

class RateLimitError(Exception):
    status_code=429

async def main():
    ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
    ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()
    try:
        err=RateLimitError("429 Too Many Requests")
        await ai._notify_provider_failure(
            err,"mistral","mistral:medium",notify_admin=False
        )
        assert not ai.is_model_available("mistral:medium")
        # Provider cooldown must keep automatic fallback from hopping to a
        # second Mistral model on the same exhausted account/key.
        other="mistral:ministral-3b"
        if other in ai.AVAILABLE_MODELS and not ai.is_model_retired(other):
            assert not ai.is_model_available(other)
        fallback=ai.pick_fallback_model(
            "mistral:medium",{"mistral:medium"},allow_premium=True
        )
        assert fallback is None or ai.AVAILABLE_MODELS[fallback]["provider"]!="mistral"

        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()
        ai._mark_runtime_model_cooldown("sambanova:deepseek-v3.2",90,"timeout")
        assert not ai.is_model_available("sambanova:deepseek-v3.2")
        # Other SambaNova models remain routable because timeout cooldown is
        # model-only, unlike account/provider 429 cooldown.
        candidate="sambanova:llama-3.3-70b"
        if candidate in ai.AVAILABLE_MODELS and not ai.is_model_retired(candidate):
            assert ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.get("sambanova",0)<=time.time()
        print("ALL RUNTIME PROVIDER COOLDOWN TESTS PASS")
    finally:
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

asyncio.run(main())
