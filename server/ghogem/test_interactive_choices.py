"""Regression tests for ask_user_choice and Telegram choice state. No live API calls."""
import asyncio
import json
import os
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

_tmp = tempfile.TemporaryDirectory(prefix="ghogem-choice-test-")
os.environ["GHOGEM_INTERACTIVE_CHOICES_DB"] = os.path.join(_tmp.name, "choices.db")

import interactive_choices as choices
choices.DB_PATH = os.environ["GHOGEM_INTERACTIVE_CHOICES_DB"]

import ai
import bot


def test_store():
    card = choices.create(
        101, 202, "chat-A", "Какой режим выбрать?",
        ["Быстрый", "Точный", "Экономный"],
    )
    assert card["status"] == "open"
    assert card["options"] == ["Быстрый", "Точный", "Экономный"]
    choices.attach_message(card["token"], 303)
    reread = choices.get(card["token"])
    assert reread and reread["message_id"] == 303
    assert choices.begin_custom(card["token"], 999) is None
    custom = choices.begin_custom(card["token"], 101)
    assert custom and custom["status"] == "custom"
    assert choices.custom_for_user(101)["token"] == card["token"]
    assert choices.consume(card["token"], 999) is None
    resolved = choices.consume(card["token"], 101, custom_only=True)
    assert resolved and resolved["status"] == "resolved"
    assert choices.consume(card["token"], 101) is None
    print("PASS store: persistent owner-bound custom/consume flow")

    first = choices.create(101, 202, "chat-A", "Первый?", ["A", "B"])
    second = choices.create(101, 202, "chat-A", "Второй?", ["C", "D"])
    assert choices.get(first["token"]) is None
    assert choices.get(first["token"], include_closed=True)["status"] == "superseded"
    assert choices.get(second["token"])["status"] == "open"
    print("PASS store: a newer question safely supersedes the older live card")


def test_ui():
    q = "Как продолжить?"
    opts = ["Сделать быстро", "Сделать подробнее"]
    choose = bot.interactive_choice_text(q, opts, footer="choose")
    custom = bot.interactive_choice_text(q, opts, footer="custom")
    selected = bot.interactive_choice_text(q, opts, footer="selected", selected_index=1)
    # The question/options block must be byte-for-byte identical; only last
    # footer line changes when the user switches interaction state.
    assert choose.rsplit("\n", 1)[0] == custom.rsplit("\n", 1)[0]
    assert choose.rsplit("\n", 1)[0] == selected.rsplit("\n", 1)[0]
    assert "❓ <b>Вопрос</b>" in choose
    assert "1️⃣ <b>Вариант 1</b>" in choose
    assert "2️⃣ <b>Вариант 2</b>" in choose
    assert "Выбери один из вариантов ответа снизу" in choose
    assert "Напиши свой ответ следующим сообщением" in custom

    kb = bot.interactive_choice_keyboard("abc123", 2)
    assert len(kb.inline_keyboard) == 3
    assert kb.inline_keyboard[0][0].callback_data == "choice:pick:abc123:0"
    assert kb.inline_keyboard[1][0].callback_data == "choice:pick:abc123:1"
    assert kb.inline_keyboard[2][0].callback_data == "choice:custom:abc123"
    assert "Написать свой ответ" in kb.inline_keyboard[2][0].text
    print("PASS UI: stable card body + numbered buttons + custom answer")


def test_registry():
    names = {(t.get("function") or {}).get("name") for t in ai.TOOLS}
    assert "ask_user_choice" in names
    instruction = ai.tool_registry.instructions_for("ask_user_choice", ai.TOOLS)
    payload = json.loads(instruction)
    assert payload["ready"] is True
    rules = payload["rules"]
    assert "После успешного вызова НЕ продолжай" in rules
    assert "не является подтверждением" in rules
    background = ai.filter_scheduled_tools(ai.TOOLS, {"ask_user_choice"})
    bg_names = {(t.get("function") or {}).get("name") for t in background}
    assert "ask_user_choice" not in bg_names
    result, pending = ai._run_tool("ask_user_choice", {}, 1, "x")
    assert "только в Telegram" in result and pending is None
    print("PASS registry: detailed lazy instructions + background/web safety boundary")


class FakeCompletions:
    def __init__(self):
        self.calls = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        number = len(self.calls)
        if number == 1:
            call = SimpleNamespace(
                id="t1",
                function=SimpleNamespace(
                    name="get_tool_instructions",
                    arguments=json.dumps({"tool_name": "ask_user_choice"}, ensure_ascii=False),
                ),
            )
            msg = SimpleNamespace(content="", tool_calls=[call])
            return SimpleNamespace(
                choices=[SimpleNamespace(message=msg, finish_reason="tool_calls")],
                usage=None,
            )
        if number == 2:
            call = SimpleNamespace(
                id="t2",
                function=SimpleNamespace(
                    name="ask_user_choice",
                    arguments=json.dumps({
                        "question": "Как продолжить проект?",
                        "options": ["Сначала дизайн", "Сначала backend"],
                    }, ensure_ascii=False),
                ),
            )
            msg = SimpleNamespace(content="", tool_calls=[call])
            return SimpleNamespace(
                choices=[SimpleNamespace(message=msg, finish_reason="tool_calls")],
                usage=None,
            )
        raise AssertionError("Model was called again after terminal ask_user_choice")


async def test_terminal_agent():
    fake_completions = FakeCompletions()
    fake_client = SimpleNamespace(
        chat=SimpleNamespace(completions=fake_completions)
    )
    saved = []
    old = {
        "get_client": ai.get_client,
        "load_history": ai.load_history,
        "save_history": ai.save_history,
        "list_files": ai.list_files,
        "read_memory": ai.read_memory,
        "get_current_chat": ai.get_current_chat,
        "user_has_premium": ai.user_has_premium,
    }
    ai.get_client = lambda provider: fake_client
    ai.load_history = lambda uid, cid: []
    ai.save_history = lambda uid, cid, messages: saved.extend(messages)
    ai.list_files = lambda uid, cid: []
    ai.read_memory = lambda uid, cid=None: ""
    ai.get_current_chat = lambda uid: "choice-agent-test"

    async def premium(uid):
        return True
    ai.user_has_premium = premium

    proposed = []

    async def on_choice(args, model_key, chat_id):
        proposed.append((args, model_key, chat_id))
        return json.dumps({
            "status": "awaiting_user_choice",
            "token": "deadbeef",
            "message_id": 77,
        }, ensure_ascii=False)

    try:
        result = await ai.ask_ai(
            987654,
            "Помоги выбрать, с чего начать",
            "groq:gpt-oss-20b",
            bot.SYSTEM_PROMPT,
            20,
            on_choice_proposed=on_choice,
            chat_id_override="choice-agent-test",
        )
    finally:
        for name, value in old.items():
            setattr(ai, name, value)

    assert result == "__GHOGEM_AWAITING_USER_CHOICE__"
    assert len(fake_completions.calls) == 2
    assert proposed and proposed[0][0]["question"] == "Как продолжить проект?"
    assistant_texts = [
        m.get("content", "") for m in saved if m.get("role") == "assistant"
    ]
    assert any("Интерактивный вопрос пользователю" in text for text in assistant_texts)
    assert not any("__GHOGEM_AWAITING_USER_CHOICE__" in text for text in assistant_texts)
    print("PASS agent: ask_user_choice is terminal and raw sentinel is not persisted")


async def test_forced_choice_after_plain_text():
    """A weak model may answer with a list first; server must force the real tool."""
    class StubbornCompletions:
        def __init__(self): self.calls=[]
        async def create(self,**kwargs):
            self.calls.append(kwargs)
            n=len(self.calls)
            if n==1:
                msg=SimpleNamespace(
                    content="Вопрос: Что выбрать? 1. Первое 2. Второе",
                    tool_calls=[],
                )
                return SimpleNamespace(
                    choices=[SimpleNamespace(message=msg,finish_reason="stop")],usage=None
                )
            if n==2:
                call=SimpleNamespace(
                    id="i1",function=SimpleNamespace(
                        name="get_tool_instructions",
                        arguments=json.dumps({"tool_name":"ask_user_choice"}),
                    )
                )
                return SimpleNamespace(
                    choices=[SimpleNamespace(
                        message=SimpleNamespace(content="",tool_calls=[call]),
                        finish_reason="tool_calls",
                    )],usage=None,
                )
            if n==3:
                call=SimpleNamespace(
                    id="i2",function=SimpleNamespace(
                        name="ask_user_choice",
                        arguments=json.dumps({
                            "question":"Что выбрать?",
                            "options":["Первое","Второе"],
                        },ensure_ascii=False),
                    )
                )
                return SimpleNamespace(
                    choices=[SimpleNamespace(
                        message=SimpleNamespace(content="",tool_calls=[call]),
                        finish_reason="tool_calls",
                    )],usage=None,
                )
            raise AssertionError(f"unexpected provider call {n}")

    completions=StubbornCompletions()
    fake_client=SimpleNamespace(chat=SimpleNamespace(completions=completions))
    saved=[]
    old={
        "get_client":ai.get_client,"load_history":ai.load_history,
        "save_history":ai.save_history,"list_files":ai.list_files,
        "read_memory":ai.read_memory,"get_current_chat":ai.get_current_chat,
        "user_has_premium":ai.user_has_premium,
    }
    ai.get_client=lambda provider:fake_client
    ai.load_history=lambda uid,cid:[]
    ai.save_history=lambda uid,cid,messages:saved.extend(messages)
    ai.list_files=lambda uid,cid:[]
    ai.read_memory=lambda uid,cid=None:""
    ai.get_current_chat=lambda uid:"forced-choice"
    async def premium(uid): return True
    ai.user_has_premium=premium
    proposed=[]
    async def on_choice(args,model_key,chat_id):
        proposed.append(args)
        return json.dumps({
            "status":"awaiting_user_choice","token":"forced","message_id":66,
        })
    try:
        result=await ai.ask_ai(
            81111,
            "сделай выбор мне из вопроса, и 2 ответов, рандом",
            "groq:gpt-oss-20b",bot.SYSTEM_PROMPT,20,
            on_choice_proposed=on_choice,
            chat_id_override="forced-choice",
        )
    finally:
        for name,value in old.items(): setattr(ai,name,value)
    assert result=="__GHOGEM_AWAITING_USER_CHOICE__"
    assert len(completions.calls)==3
    assert proposed and proposed[0]["options"]==["Первое","Второе"]
    assert not any(
        "Вопрос: Что выбрать? 1. Первое 2. Второе"==m.get("content")
        for m in saved if m.get("role")=="assistant"
    ),"rejected plain-text imitation must not become the saved final answer"
    print("PASS forced interactive: plain-text imitation is rejected and real tool is required")


async def test_bot_callbacks():
    recorded_updates = []
    recorded_submits = []
    old_update = bot.update_interactive_choice_card
    old_submit = bot.submit_prompt
    old_touch = bot.db.touch_user

    async def fake_update(card, **kwargs):
        recorded_updates.append((dict(card), dict(kwargs)))

    async def fake_submit(user_id, chat_id, prompt, notify_message, **kwargs):
        recorded_submits.append({
            "user_id": user_id,
            "chat_id": chat_id,
            "prompt": prompt,
            "ai_chat_id_override": kwargs.get("ai_chat_id_override"),
        })

    async def fake_touch(user_id):
        return None

    bot.update_interactive_choice_card = fake_update
    bot.submit_prompt = fake_submit
    bot.db.touch_user = fake_touch

    class FakeQuery:
        def __init__(self, data, uid, chat_id, message_id):
            self.data = data
            self.from_user = SimpleNamespace(id=uid)
            self.message = SimpleNamespace(
                chat=SimpleNamespace(id=chat_id),
                message_id=message_id,
            )
            self.answers = []

        async def answer(self, text=None, **kwargs):
            self.answers.append((text, kwargs))

    class FakeMessage:
        def __init__(self, uid, chat_id, text):
            self.from_user = SimpleNamespace(id=uid)
            self.chat = SimpleNamespace(id=chat_id)
            self.text = text

    try:
        pick = choices.create(501, 601, "ai-choice-1", "Куда идти?", ["Налево", "Направо"])
        choices.attach_message(pick["token"], 701)
        live_waiter = asyncio.get_running_loop().create_future()
        bot.interactive_choice_waiters[pick["token"]] = live_waiter
        q = FakeQuery(f"choice:pick:{pick['token']}:1", 501, 601, 701)
        await bot.cb_interactive_choice_pick(q)
        await asyncio.sleep(0)
        assert choices.get(pick["token"]) is None
        assert recorded_updates[-1][1]["footer"] == "selected"
        assert recorded_updates[-1][1]["selected_index"] == 1
        assert live_waiter.done()
        live_payload = live_waiter.result()
        assert "Вариант 2: Направо" in live_payload["prompt"]
        assert "Вариант 2" in live_payload["timeline"]
        assert not recorded_submits, "live choice must resume same coroutine, not spawn a new turn"
        bot.interactive_choice_waiters.pop(pick["token"], None)
        print("PASS bot callback: button wakes the same live agent turn")

        # After a bot restart there is no in-memory waiter. The persisted card
        # must still continue the exact AI chat as a safe fresh turn.
        restart = choices.create(504, 604, "ai-choice-restart", "Куда?", ["A", "B"])
        choices.attach_message(restart["token"], 704)
        qr = FakeQuery(f"choice:pick:{restart['token']}:0", 504, 604, 704)
        await bot.cb_interactive_choice_pick(qr)
        await asyncio.sleep(0)
        assert recorded_submits[-1]["ai_chat_id_override"] == "ai-choice-restart"
        assert "Вариант 1: A" in recorded_submits[-1]["prompt"]
        print("PASS bot callback: restart fallback resumes persisted AI chat")

        custom = choices.create(502, 602, "ai-choice-2", "Как назвать?", ["Alpha", "Beta"])
        choices.attach_message(custom["token"], 702)
        q2 = FakeQuery(f"choice:custom:{custom['token']}", 502, 602, 702)
        await bot.cb_interactive_choice_custom(q2)
        active = choices.get(custom["token"])
        assert active and active["status"] == "custom"
        assert recorded_updates[-1][1]["footer"] == "custom"
        assert recorded_updates[-1][1]["keep_buttons"] is True

        await bot.handle_message(FakeMessage(502, 602, "Gamma"))
        assert choices.get(custom["token"]) is None
        assert recorded_updates[-1][1]["footer"] == "custom_sent"
        assert recorded_submits[-1]["ai_chat_id_override"] == "ai-choice-2"
        assert "Пользователь написал свой ответ: Gamma" in recorded_submits[-1]["prompt"]
        print("PASS bot custom: footer changes, typed answer resumes exact AI chat")

        foreign = choices.create(503, 603, "ai-choice-3", "Секрет?", ["A", "B"])
        choices.attach_message(foreign["token"], 703)
        q3 = FakeQuery(f"choice:pick:{foreign['token']}:0", 999, 603, 703)
        await bot.cb_interactive_choice_pick(q3)
        assert choices.get(foreign["token"]) is not None
        assert q3.answers and q3.answers[-1][1].get("show_alert") is True
        print("PASS bot security: foreign user cannot consume choice")
    finally:
        bot.update_interactive_choice_card = old_update
        bot.submit_prompt = old_submit
        bot.db.touch_user = old_touch


async def test_same_turn_pause_resume():
    uid=88001
    chat_id=88001
    ai_chat_id="same-turn-choice"
    sent=[]
    edited=[]
    ask_calls=[]

    class FakeQuery:
        def __init__(self,data,message_id):
            self.data=data
            self.from_user=SimpleNamespace(id=uid)
            self.message=SimpleNamespace(chat=SimpleNamespace(id=chat_id),message_id=message_id)
        async def answer(self,*args,**kwargs):
            return None

    async def fake_send(cid,text,*args,**kwargs):
        mid=1000+len(sent)+1
        msg=SimpleNamespace(message_id=mid,chat=SimpleNamespace(id=cid),text=text)
        sent.append((cid,text,kwargs,msg))
        if "❓ <b>Вопрос</b>" in str(text):
            markup=kwargs.get("reply_markup")
            data=markup.inline_keyboard[1][0].callback_data
            async def click_when_waiting():
                token=data.split(":")[2]
                for _ in range(100):
                    if token in bot.interactive_choice_waiters:
                        await bot.cb_interactive_choice_pick(FakeQuery(data,mid))
                        return
                    await asyncio.sleep(0.01)
                raise AssertionError("interactive waiter was never registered")
            asyncio.create_task(click_when_waiting())
        return msg

    async def fake_edit(**kwargs):
        edited.append(dict(kwargs))
        return SimpleNamespace(
            message_id=kwargs["message_id"],chat=SimpleNamespace(id=kwargs["chat_id"])
        )

    async def fake_ask(user_id,prompt,model_key,system_prompt,max_history_turns,**kwargs):
        ask_calls.append(prompt)
        if len(ask_calls)==1:
            await kwargs["on_action"]("🧠 Учитываю исходный контекст",kind="thought")
            await kwargs["on_action"]("🧩 Готовлю интерактивный вопрос",kind="action")
            result=await kwargs["on_choice_proposed"](
                {"question":"Что выбрать?","options":["Первое","Второе"]},
                model_key,ai_chat_id,
            )
            assert json.loads(result)["status"]=="awaiting_user_choice"
            await kwargs["on_action"]("❓ Жду выбора пользователя",kind="done")
            return "__GHOGEM_AWAITING_USER_CHOICE__"
        assert "Вариант 2: Второе" in prompt
        await kwargs["on_action"]("▶️ Продолжаю после выбора",kind="action")
        return "Готово после выбора."

    async def noop(*args,**kwargs): return None
    async def false(*args,**kwargs): return False
    async def model(_): return ai.DEFAULT_MODEL_KEY
    async def timezone(_): return "Europe/Moscow"
    async def title(*args,**kwargs): return "Тест выбора"
    async def forever_typing(_): await asyncio.sleep(60)

    with (
        patch.object(bot.ai,"ask_ai",fake_ask),
        patch.object(bot.ai,"is_model_retired",lambda _:False),
        patch.object(bot.ai,"read_memory",lambda *args:""),
        patch.object(bot.ai,"fish_tts_available",lambda:False),
        patch.object(bot.ai,"ensure_chat_title",title),
        patch.object(bot.ai,"tag_latest_assistant_answer",lambda *args:"ans-choice"),
        patch.object(bot,"get_user_model",model),
        patch.object(bot,"ensure_chat_persisted",noop),
        patch.object(bot.db,"is_subscribed",false),
        patch.object(bot.db,"get_custom_prompt",noop),
        patch.object(bot.db,"get_timezone",timezone),
        patch.object(bot.db,"is_model_favorite",false),
        patch.object(bot.bot,"send_message",fake_send),
        patch.object(bot.bot,"edit_message_text",fake_edit),
        patch.object(bot,"safe_react",noop),
        patch.object(bot,"keep_typing",forever_typing),
    ):
        await bot.process_request(
            uid,chat_id,"сделай интерактивный выбор",None,
            ai_chat_id_override=ai_chat_id,
        )

    assert len(ask_calls)==2,ask_calls
    question_messages=[row for row in sent if "❓ <b>Вопрос</b>" in str(row[1])]
    assert len(question_messages)==1
    question_mid=question_messages[0][3].message_id
    main_mid=sent[0][3].message_id
    assert question_mid!=main_mid,"question must be a separate Telegram message"
    assert any(
        edit.get("message_id")==main_mid and "ждёт ответа" in str(edit.get("text"))
        for edit in edited
    ),"main work card must visibly wait for the user"
    final=[e for e in edited if e.get("message_id")==main_mid][-1]["text"]
    assert "Готово после выбора." in final
    assert "Учитываю исходный контекст" in final
    assert "Жду выбора пользователя" in final
    assert "Пользователь выбрал Вариант 2: Второе" in final
    assert bot.active_agent_runs.get(uid) is None
    print("PASS full Telegram flow: separate question + same-turn wait/resume + preserved timeline")


async def main():
    test_store()
    test_ui()
    test_registry()
    await test_terminal_agent()
    await test_forced_choice_after_plain_text()
    await test_bot_callbacks()
    await test_same_turn_pause_resume()
    print("ALL INTERACTIVE CHOICE TESTS PASS")


asyncio.run(main())
_tmp.cleanup()
