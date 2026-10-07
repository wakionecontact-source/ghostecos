"""Regression: attachments require a real analyzer before a user-facing answer."""
import asyncio
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch
import ai

def response(content="", tool=None, arguments=None):
    calls = [] if not tool else [
        NS(id="c1", function=NS(name=tool, arguments=json.dumps(arguments or {})))
    ]
    return NS(choices=[NS(message=NS(content=content, tool_calls=calls),
                          finish_reason="tool_calls" if calls else "stop")])

async def scenario(*, model_uses_tool):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "attachment.png"
        path.write_bytes(b"fake-image-bytes")
        steps, analyses, histories = [], [], []
        async def no_premium(_):
            return False
        async def analyzer(**kwargs):
            analyses.append(kwargs["filename"])
            return "[анализатор изображения: mock]\nНа фото изображён кот."
        class Client:
            def __init__(self):
                self.chat = NS(completions=NS(create=self.create))
            def create(self, **kwargs):
                steps.append(kwargs)
                count = len(steps)
                if model_uses_tool:
                    if count == 1:
                        assert "analyze_file" not in {
                            t["function"]["name"] for t in kwargs.get("tools", [])}
                        return response(tool="get_tool_instructions",
                                        arguments={"tool_name":"analyze_file"})
                    if count == 2:
                        assert "analyze_file" in {
                            t["function"]["name"] for t in kwargs.get("tools", [])}
                        return response(tool="analyze_file",
                                        arguments={"filename":"attachment.png",
                                                   "task":"Посмотри фото"})
                elif count < 4:
                    return response("Не могу увидеть вложение.")
                return response("На фото кот.")
        async def passthrough(factory, **_):
            value = factory()
            return await value if asyncio.iscoroutine(value) else value
        client = Client()
        patches = [
            patch.object(ai, "get_client", lambda _: client),
            patch.object(ai, "_request_with_single_retry", passthrough),
            patch.object(ai, "user_has_premium", no_premium),
            patch.object(ai, "get_current_chat", lambda _: "1234567890123"),
            patch.object(ai, "load_history", lambda *_: []),
            patch.object(ai, "save_history", lambda *args: histories.append(args[2])),
            patch.object(ai, "list_files", lambda *_: []),
            patch.object(ai, "read_memory", lambda *_: ""),
            patch.object(ai, "is_model_available", lambda _: True),
            patch.object(ai, "resolve_user_upload", lambda *_: str(path)),
            patch.object(ai.media_services_v2, "analyze_with_quota", analyzer),
        ]
        try:
            for p in patches:
                p.start()
            answer = await ai.ask_ai(
                987654319, "Смотри, что на фото?", "groq:gpt-oss-20b",
                "Ты тестовый агент.", 12,
                required_media_filename="attachment.png",
            )
            assert answer == "На фото кот.", answer
            assert analyses == ["attachment.png"], analyses
            assert any("ПРИКРЕПЛЁННЫЕ МЕДИА" in str(c["messages"])
                       or "ОБЯЗАТЕЛЬНО вызови" in str(c["messages"])
                       for c in steps)
            assert histories[-1][-1]["content"] == answer
            print("PASS:", "model tool path" if model_uses_tool
                  else "weak-model enforced analysis fallback",
                  "in", len(steps), "requests")
        finally:
            for p in reversed(patches):
                p.stop()

async def test_telegram_photo_route():
    from io import BytesIO
    import bot
    seen = []
    message = NS(
        from_user=NS(id=987654319), chat=NS(id=987654319),
        photo=[NS(file_id="photo-test")],
        caption="смотри, что тут изображено", message_id=15,
    )
    async def fake_get_file(fid):
        assert fid == "photo-test"
        return NS(file_path="/mock/file")
    async def fake_download(_):
        return BytesIO(b"mock-image-bytes")
    async def fake_store(uid, filename, data):
        assert uid == 987654319 and filename.endswith(".jpg")
        assert data == b"mock-image-bytes"
        return "/tmp/owner-media/" + filename, "saved"
    async def fake_submit(uid, cid, prompt, **kwargs):
        seen.append((uid, cid, prompt, kwargs["attachment_name"]))
    async def noop(*args, **kwargs):
        return None
    with (patch.object(bot.ai, "get_current_chat", lambda _: "1234567890123"),
          patch.object(bot.bot, "get_file", fake_get_file),
          patch.object(bot.bot, "download_file", fake_download),
          patch.object(bot, "_save_bytes_to_chat", fake_store),
          patch.object(bot, "safe_react", noop),
          patch.object(bot, "submit_prompt", fake_submit)):
        await bot.handle_photo(message)
    assert len(seen) == 1 and seen[0][3].endswith(".jpg")
    assert "смотри, что тут изображено" in seen[0][2]
    print("PASS: Telegram photo and caption reach attachment-mandatory runner")

async def main():
    await scenario(model_uses_tool=True)
    await scenario(model_uses_tool=False)
    await test_telegram_photo_route()
    print("ALL MANDATORY ATTACHMENT TESTS PASS")

if __name__ == "__main__":
    asyncio.run(main())
