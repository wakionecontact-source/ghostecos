import asyncio
import json
from types import SimpleNamespace

import ai


class Http503(Exception):
    status_code = 503


def completion(text="", tool_calls=None):
    return SimpleNamespace(
        choices=[
            SimpleNamespace(
                finish_reason="tool_calls" if tool_calls else "stop",
                message=SimpleNamespace(
                    content=text,
                    tool_calls=tool_calls or [],
                    reasoning_content=None,
                    reasoning=None,
                    thinking=None,
                    reasoning_details=[],
                ),
            )
        ],
        usage=None,
    )


class FailingCompletions:
    def __init__(self, exc):
        self.exc = exc
        self.calls = 0
    async def create(self, **kwargs):
        self.calls += 1
        raise self.exc


class CaptureCompletions:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
    async def create(self, **kwargs):
        self.calls.append(kwargs)
        if not self.responses:
            raise AssertionError("unexpected extra model call")
        value = self.responses.pop(0)
        if isinstance(value, BaseException):
            raise value
        return value


class FakeClient:
    def __init__(self, completions):
        self.chat = SimpleNamespace(completions=completions)


class Patch:
    def __init__(self):
        self.saved = {}
    def set(self, obj, name, value):
        key = (id(obj), name)
        if key not in self.saved:
            self.saved[key] = (obj, getattr(obj, name))
        setattr(obj, name, value)
    def restore(self):
        for obj, old in reversed(list(self.saved.values())):
            setattr(obj, obj if False else "", old)


async def with_common_patches():
    pass


async def test_no_auto_switch_on_timeout():
    model = "mistral:ministral-8b"
    provider = ai.AVAILABLE_MODELS[model]["provider"]
    fail = FailingCompletions(asyncio.TimeoutError())
    client = FakeClient(fail)

    originals = {
        "get_client": ai.get_client,
        "user_has_premium": ai.user_has_premium,
        "load_history": ai.load_history,
        "save_history": ai.save_history,
        "get_current_chat": ai.get_current_chat,
        "list_files": ai.list_files,
        "read_memory": ai.read_memory,
        "pick_fallback_model": ai.pick_fallback_model,
        "db_tutorial": ai.db.get_tutorial_state,
        "db_key": ai.db.get_user_key_any,
    }
    fallback_called = False

    async def premium(_uid): return False
    async def tutorial(_uid): return {"is_new_user": False, "age_seconds": 0, "topics": {}}
    async def no_key(_uid, _provider): return None
    def pick(*args, **kwargs):
        nonlocal fallback_called
        fallback_called = True
        return "openrouter:space-bunny-alpha"

    try:
        ai.get_client = lambda p: client if p == provider else None
        ai.user_has_premium = premium
        ai.db.get_tutorial_state = tutorial
        ai.db.get_user_key_any = no_key
        ai.load_history = lambda uid, cid: []
        ai.save_history = lambda uid, cid, history: None
        ai.get_current_chat = lambda uid: "test"
        ai.list_files = lambda uid, cid: []
        ai.read_memory = lambda uid, cid=None: ""
        ai.pick_fallback_model = pick
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

        holder = [model]
        result = await ai.ask_ai(
            991100,
            "привет",
            model,
            "",
            8,
            model_holder=holder,
            allow_model_fallback=False,
            allow_rate_limit_fallback=False,
        )
        assert holder == [model], holder
        assert not fallback_called, "fallback picker must not run"
        assert "не ответила вовремя" in result.lower(), result
        print("PASS no auto model switch on timeout")
    finally:
        ai.get_client = originals["get_client"]
        ai.user_has_premium = originals["user_has_premium"]
        ai.load_history = originals["load_history"]
        ai.save_history = originals["save_history"]
        ai.get_current_chat = originals["get_current_chat"]
        ai.list_files = originals["list_files"]
        ai.read_memory = originals["read_memory"]
        ai.pick_fallback_model = originals["pick_fallback_model"]
        ai.db.get_tutorial_state = originals["db_tutorial"]
        ai.db.get_user_key_any = originals["db_key"]
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()


async def test_fallback_carries_conversation_context():
    first = "mistral:ministral-8b"
    second = "openrouter:space-bunny-alpha"
    first_provider = ai.AVAILABLE_MODELS[first]["provider"]
    second_provider = ai.AVAILABLE_MODELS[second]["provider"]

    failing = FakeClient(FailingCompletions(Http503("provider unavailable")))
    target_completions = CaptureCompletions([completion("Контекст получил, продолжаю.")])
    target = FakeClient(target_completions)

    old = {
        "get_client": ai.get_client,
        "user_has_premium": ai.user_has_premium,
        "load_history": ai.load_history,
        "save_history": ai.save_history,
        "get_current_chat": ai.get_current_chat,
        "list_files": ai.list_files,
        "read_memory": ai.read_memory,
        "pick_fallback_model": ai.pick_fallback_model,
        "budget": ai._model_context_char_budget,
        "db_tutorial": ai.db.get_tutorial_state,
        "db_key": ai.db.get_user_key_any,
    }

    history = [{"role":"system","content":"old system"}]
    for i in range(8):
        history += [
            {"role":"user","content":f"старый вопрос {i} " + ("x"*900)},
            {"role":"assistant","content":f"старый ответ {i} " + ("y"*900)},
        ]
    history += [
        {"role":"user","content":"Запомни кодовое имя: ПРОЕКТ_ФИОЛЕТОВЫЙ_ДРАКОН"},
        {"role":"assistant","content":"Запомнил кодовое имя проекта."},
    ]

    async def premium(_uid): return False
    async def tutorial(_uid): return {"is_new_user": False, "age_seconds": 0, "topics": {}}
    async def no_key(_uid, _provider): return None
    persisted = []
    def capture_history(uid, cid, value):
        persisted[:] = [dict(m) for m in value]

    try:
        ai.get_client = lambda p: failing if p == first_provider else (target if p == second_provider else None)
        ai.user_has_premium = premium
        ai.db.get_tutorial_state = tutorial
        ai.db.get_user_key_any = no_key
        ai.load_history = lambda uid, cid: [dict(m) for m in history]
        ai.save_history = capture_history
        ai.get_current_chat = lambda uid: "test"
        ai.list_files = lambda uid, cid: []
        ai.read_memory = lambda uid, cid=None: ""
        ai.pick_fallback_model = lambda current, tried, allow_premium=False: second
        ai._model_context_char_budget = lambda key, provider=None: 9000
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()

        holder=[first]
        result = await ai.ask_ai(
            991101,
            "продолжи нашу идею, которую обсуждали",
            first,
            "",
            20,
            model_holder=holder,
            allow_model_fallback=True,
            allow_rate_limit_fallback=True,
        )
        assert holder == [second], holder
        assert target_completions.calls, "fallback model was not called"
        sent = "\n".join(
            str(m.get("content") or "")
            for m in target_completions.calls[0].get("messages", [])
        )
        assert "СЛУЖЕБНАЯ ПЕРЕДАЧА КОНТЕКСТА" in sent, sent[-3000:]
        assert "ПРОЕКТ_ФИОЛЕТОВЫЙ_ДРАКОН" in sent, sent[-5000:]
        assert "продолжи нашу идею, которую обсуждали" in sent
        assert result.startswith("Контекст получил"), result
        persisted_text = "\n".join(str(m.get("content") or "") for m in persisted)
        assert "старый вопрос 0" in persisted_text, "provider trimming leaked into durable history"
        assert "ПРОЕКТ_ФИОЛЕТОВЫЙ_ДРАКОН" in persisted_text
        assert "продолжи нашу идею, которую обсуждали" in persisted_text
        print("PASS fallback model receives pinned context and durable history is preserved")
    finally:
        ai.get_client = old["get_client"]
        ai.user_has_premium = old["user_has_premium"]
        ai.load_history = old["load_history"]
        ai.save_history = old["save_history"]
        ai.get_current_chat = old["get_current_chat"]
        ai.list_files = old["list_files"]
        ai.read_memory = old["read_memory"]
        ai.pick_fallback_model = old["pick_fallback_model"]
        ai._model_context_char_budget = old["budget"]
        ai.db.get_tutorial_state = old["db_tutorial"]
        ai.db.get_user_key_any = old["db_key"]
        ai._RUNTIME_MODEL_COOLDOWN_UNTIL.clear()
        ai._RUNTIME_PROVIDER_COOLDOWN_UNTIL.clear()


async def test_video_request_forces_generate_video():
    model = "mistral:ministral-8b"
    provider = ai.AVAILABLE_MODELS[model]["provider"]

    args = {
        "mode":"animated",
        "layers":[
            {
                "name":"city",
                "svg":'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180"><rect width="320" height="180" fill="#222"/></svg>',
                "z":1,
                "motion":{"velocity_x":-50,"repeat_x":True},
            }
        ],
        "duration":1,
        "width":320,
        "height":180,
        "fps":12,
        "camera":{"shake":1},
        "background":"#111111",
    }
    tool_call = SimpleNamespace(
        id="video_1",
        function=SimpleNamespace(
            name="generate_video",
            arguments=json.dumps(args, ensure_ascii=False),
        ),
    )
    comps = CaptureCompletions([
        completion("Я не умею генерировать видео."),
        completion("", [tool_call]),
        completion("Готово, сделал анимированное видео."),
    ])
    client = FakeClient(comps)

    old = {
        "get_client": ai.get_client,
        "user_has_premium": ai.user_has_premium,
        "load_history": ai.load_history,
        "save_history": ai.save_history,
        "get_current_chat": ai.get_current_chat,
        "list_files": ai.list_files,
        "read_memory": ai.read_memory,
        "video": ai.video_render.generate_video,
        "db_tutorial": ai.db.get_tutorial_state,
        "db_key": ai.db.get_user_key_any,
    }

    async def premium(_uid): return False
    async def tutorial(_uid): return {"is_new_user": False, "age_seconds": 0, "topics": {}}
    async def no_key(_uid, _provider): return None

    try:
        ai.get_client = lambda p: client if p == provider else None
        ai.user_has_premium = premium
        ai.db.get_tutorial_state = tutorial
        ai.db.get_user_key_any = no_key
        ai.load_history = lambda uid, cid: []
        ai.save_history = lambda uid, cid, h: None
        ai.get_current_chat = lambda uid: "test"
        ai.list_files = lambda uid, cid: []
        ai.read_memory = lambda uid, cid=None: ""
        ai.video_render.generate_video = lambda *a, **kw: {
            "name":"forced_video.mp4",
            "source_name":"forced_video.video.json",
            "source_warning":"",
            "size":2048,
            "width":320,
            "height":180,
            "fps":12,
            "duration":1.0,
            "mode":"animated",
            "layers":1,
            "scenes":0,
        }

        result = await ai.ask_ai(
            991102,
            "сделай видео как будто еду по городу",
            model,
            "",
            8,
            allow_model_fallback=False,
            allow_rate_limit_fallback=False,
        )
        assert len(comps.calls) == 3, len(comps.calls)
        second_messages = "\n".join(
            str(m.get("content") or "") for m in comps.calls[1].get("messages", [])
        )
        assert "generate_video" in second_messages
        tool_names = {
            t["function"]["name"]
            for t in comps.calls[0].get("tools", [])
            if isinstance(t, dict) and t.get("function")
        }
        assert "generate_video" in tool_names, tool_names
        assert "VIDEO_TO_SEND:forced_video.mp4" in result, result
        print("PASS explicit video request forces preloaded generate_video tool")
    finally:
        ai.get_client = old["get_client"]
        ai.user_has_premium = old["user_has_premium"]
        ai.load_history = old["load_history"]
        ai.save_history = old["save_history"]
        ai.get_current_chat = old["get_current_chat"]
        ai.list_files = old["list_files"]
        ai.read_memory = old["read_memory"]
        ai.video_render.generate_video = old["video"]
        ai.db.get_tutorial_state = old["db_tutorial"]
        ai.db.get_user_key_any = old["db_key"]


async def main():
    await test_no_auto_switch_on_timeout()
    await test_fallback_carries_conversation_context()
    await test_video_request_forces_generate_video()


asyncio.run(main())
