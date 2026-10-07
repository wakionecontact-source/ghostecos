"""Regression: Telegram photo is seen before the text-only writer replies."""
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as N
from unittest.mock import patch

import ai
import bot


async def check_photo_pipeline():
    edits, prompts, analyses = [], [], []
    async def noop(*a, **kw): return None
    async def model(uid): return ai.DEFAULT_MODEL_KEY
    async def free(uid): return False
    async def send(cid, content, **kw):
        return N(message_id=10001, chat=N(id=cid))
    async def edit(**kw):
        edits.append(kw["text"])
        return N(message_id=kw["message_id"], chat=N(id=kw["chat_id"]))
    async def keep_typing(cid): await asyncio.sleep(30)
    async def analyze(*args, **kwargs):
        analyses.append(kwargs)
        return "[анализатор изображения]\nВидна фиолетовая презентация GhoGem 2.0"
    async def writer(uid, prompt, *args, **kwargs):
        prompts.append(prompt)
        return "Вижу презентацию GhoGem 2.0 с фиолетовым оформлением."
    with TemporaryDirectory() as tmp:
        image = Path(tmp) / "photo_test.jpg"
        image.write_bytes(b"fake-image-test-no-upload")
        with (
            patch.object(bot.ai, "ask_ai", writer),
            patch.object(bot.ai, "is_model_retired", lambda _: False),
            patch.object(bot.ai, "read_memory", lambda uid: ""),
            patch.object(bot.ai, "resolve_user_upload",
                         lambda uid, cid, name: str(image)),
            patch.object(bot.ai.media_services_v2, "analyze_with_quota", analyze),
            patch.object(bot, "get_user_model", model),
            patch.object(bot, "ensure_chat_persisted", noop),
            patch.object(bot.db, "is_subscribed", free),
            patch.object(bot.db, "get_custom_prompt", noop),
            patch.object(bot.bot, "send_message", send),
            patch.object(bot.bot, "edit_message_text", edit),
            patch.object(bot, "safe_react", noop),
            patch.object(bot, "keep_typing", keep_typing),
        ):
            await bot.process_request(
                906840, 906840, "Пользователь показал свой дизайн",
                None, photo_name=image.name,
            )
    assert len(analyses) == 1
    assert analyses[0]["path"] == str(image)
    assert prompts and "Видна фиолетовая презентация" in prompts[0]
    assert all("<blockquote" not in item for item in edits[:-1])
    assert edits[-1].count("<blockquote expandable>") == 1
    assert "🖼 Фото проанализировано" in edits[-1]
    assert "Вижу презентацию" in edits[-1]
    assert bot.active_agent_runs.get(906840) is None
    print("PASS: uploaded photo actually analyzed; writer gets visual report")
    print("PASS: quote only in completed answer, not live progress")

asyncio.run(check_photo_pipeline())
