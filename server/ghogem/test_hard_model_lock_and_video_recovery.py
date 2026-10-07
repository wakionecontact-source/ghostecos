import asyncio
import os
import tempfile
from types import SimpleNamespace

import ai


def completion(text="", tool_calls=None, finish_reason="stop"):
    return SimpleNamespace(
        choices=[SimpleNamespace(
            finish_reason=finish_reason,
            message=SimpleNamespace(
                content=text,
                tool_calls=tool_calls or [],
                reasoning_content=None,
                reasoning=None,
                thinking=None,
                reasoning_details=[],
            ),
        )],
        usage=None,
    )


class SequenceCompletions:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = 0

    async def create(self, **kwargs):
        self.calls += 1
        if not self.responses:
            raise AssertionError("unexpected extra model call")
        item = self.responses.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item


class FakeClient:
    def __init__(self, responses):
        self.chat = SimpleNamespace(completions=SequenceCompletions(responses))


class Http503(Exception):
    status_code = 503


async def with_common_patches(fake, fn):
    old_users = ai.USERS_DIR
    old_clients = dict(ai._CLIENTS)
    old_groq = list(ai.groq_clients)
    old_premium = ai.user_has_premium
    old_tutorial = ai.db.get_tutorial_state
    old_user_key = ai.db.get_user_key_any
    old_pool = ai.db.get_active_keys
    old_video = ai.video_render.generate_video
    try:
        with tempfile.TemporaryDirectory() as root:
            ai.USERS_DIR = root
            ai._CLIENTS["groq"] = fake
            ai.groq_clients[:] = [fake]
            ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
            ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

            async def premium(_uid):
                return False

            async def tutorial_state(_uid):
                return {"is_new_user": False, "age_seconds": 0, "topics": {}}

            async def no_key(_uid, _provider):
                return None

            async def no_pool(_provider):
                return []

            ai.user_has_premium = premium
            ai.db.get_tutorial_state = tutorial_state
            ai.db.get_user_key_any = no_key
            ai.db.get_active_keys = no_pool
            await fn(root, old_video)
    finally:
        ai.USERS_DIR = old_users
        ai._CLIENTS.clear()
        ai._CLIENTS.update(old_clients)
        ai.groq_clients[:] = old_groq
        ai.user_has_premium = old_premium
        ai.db.get_tutorial_state = old_tutorial
        ai.db.get_user_key_any = old_user_key
        ai.db.get_active_keys = old_pool
        ai.video_render.generate_video = old_video
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()


async def test_timeout_no_switch():
    fake = FakeClient([asyncio.TimeoutError(), asyncio.TimeoutError()])

    async def run(_root, _old_video):
        holder = [ai.DEFAULT_MODEL_KEY]
        reply = await ai.ask_ai(
            991101,
            "привет",
            ai.DEFAULT_MODEL_KEY,
            "",
            1,
            model_holder=holder,
            allow_model_fallback=False,
            allow_rate_limit_fallback=False,
        )
        assert holder == [ai.DEFAULT_MODEL_KEY], holder
        assert "не ответила вовремя" in reply.lower() or "не ответил" in reply.lower(), reply

    await with_common_patches(fake, run)
    print("PASS timeout respects hard model lock")


async def test_503_no_switch():
    fake = FakeClient([Http503("503 unavailable"), Http503("503 unavailable")])

    async def run(_root, _old_video):
        holder = [ai.DEFAULT_MODEL_KEY]
        try:
            await ai.ask_ai(
                991102,
                "привет",
                ai.DEFAULT_MODEL_KEY,
                "",
                1,
                model_holder=holder,
                allow_model_fallback=False,
                allow_rate_limit_fallback=False,
            )
        except ai.ProviderRateLimitError:
            pass
        assert holder == [ai.DEFAULT_MODEL_KEY], holder

    await with_common_patches(fake, run)
    print("PASS provider failure respects hard model lock")


async def test_video_recovery_same_model():
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360">'
        '<rect x="0" y="180" width="640" height="180" fill="#333"/>'
        '<rect x="80" y="100" width="100" height="100" fill="#777"/>'
        '</svg>'
    )
    plan = (
        '{"mode":"animated","duration":3,"width":640,"height":360,"fps":12,'
        '"background":"#87CEEB","camera":{"shake":1},'
        '"layers":['
        '{"name":"city","z":1,"svg":' + __import__("json").dumps(svg) + ','
        '"motion":{"velocity_x":-80,"repeat_x":true}},'
        '{"name":"road","z":2,"svg":' + __import__("json").dumps(svg) + ','
        '"motion":{"velocity_x":-180,"repeat_x":true}}]}'
    )
    # two mandatory retries, then the server-side JSON recovery pass
    fake = FakeClient([
        completion("Я не могу сделать видео."),
        completion("Не могу создать видео этим способом."),
        completion("Видео недоступно."),
        completion(plan),
    ])

    async def run(_root, _old_video):
        calls = []

        def fake_generate(_ai, user_id, chat_id, **kwargs):
            calls.append(kwargs)
            assert kwargs["mode"] == "animated"
            assert len(kwargs["layers"]) == 2
            return {
                "name": "recovered.mp4",
                "source_name": "recovered.video.json",
                "source_warning": "",
                "size": 4096,
                "width": 640,
                "height": 360,
                "fps": 12,
                "duration": 3.0,
                "mode": "animated",
                "layers": 2,
                "scenes": 0,
            }

        ai.video_render.generate_video = fake_generate
        holder = [ai.DEFAULT_MODEL_KEY]
        reply = await ai.ask_ai(
            991103,
            "сделай видео как будто еду по городу",
            ai.DEFAULT_MODEL_KEY,
            "",
            1,
            model_holder=holder,
            allow_model_fallback=False,
            allow_rate_limit_fallback=False,
        )
        assert holder == [ai.DEFAULT_MODEL_KEY], holder
        assert calls, "server video renderer was not called"
        assert "VIDEO_TO_SEND:recovered.mp4" in reply, reply

    await with_common_patches(fake, run)
    print("PASS tool-less selected model recovers into real video without model switch")


async def main():
    await test_timeout_no_switch()
    await test_503_no_switch()
    await test_video_recovery_same_model()


asyncio.run(main())
