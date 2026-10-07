import asyncio
import os
import tempfile
import time

import ai
import bot
import media_services_v2
import reminders


def tool_names(tools):
    return {
        (item.get("function") or {}).get("name")
        for item in tools
    }


async def test_next_due_minimal():
    fd, path = tempfile.mkstemp(prefix="ghogem-reminders-", suffix=".db")
    os.close(fd)
    os.unlink(path)
    original = reminders.DB_PATH
    reminders.DB_PATH = path
    try:
        reminders._init_db()
        draft = await reminders.create_draft(
            991001, 991001, "chat-test", "groq:gpt-oss-20b",
            "Тест таймера", "Проверка", int(time.time()) + 90,
            "✅", "❌", execution_mode="text",
        )
        confirmed = await reminders.confirm(draft["id"], 991001)
        assert confirmed["ok"]
        nearest = await reminders.next_due()
        assert set(nearest) == {"task_id", "due_at"}, nearest
        assert nearest["task_id"] == draft["id"]
        full = await reminders.get_task(nearest["task_id"])
        assert full["instruction"] == "Проверка"
        print("PASS scheduler stores only task_id + due_at before fire")
    finally:
        reminders.DB_PATH = original
        try:
            os.unlink(path)
        except OSError:
            pass


async def test_media_queue():
    await media_services_v2.acquire_media_slot()
    entered = asyncio.Event()

    async def second_job():
        await media_services_v2.acquire_media_slot()
        entered.set()
        media_services_v2.release_media_slot()

    job = asyncio.create_task(second_job())
    await asyncio.sleep(0.05)
    assert not entered.is_set(), "second heavy media job ran in parallel"
    status = media_services_v2.media_queue_status()
    assert status["workers"] == 1 and status["waiting"] >= 1, status
    media_services_v2.release_media_slot()
    await asyncio.wait_for(job, timeout=1)
    print("PASS heavy media queue serializes work to one worker")


def test_scheduled_permissions():
    safe = tool_names(ai.filter_scheduled_tools(ai.TOOLS, set()))
    assert "web_search" in safe
    assert "open_url" in safe
    assert "read_file" in safe
    for name in ("write_file", "edit_file", "delete_file", "cleanup_storage",
                 "write_memory", "git_restore", "update_reminder"):
        assert name not in safe, name

    allowed = bot.scheduled_side_effect_allowlist(
        "Найди свежие данные и сохрани итоговый отчет в файл."
    )
    writable = tool_names(ai.filter_scheduled_tools(ai.TOOLS, allowed))
    assert "write_file" in writable and "edit_file" not in writable
    editable_allowed = bot.scheduled_side_effect_allowlist(
        "Обнови существующий файл отчета."
    )
    editable = tool_names(ai.filter_scheduled_tools(ai.TOOLS, editable_allowed))
    assert "write_file" in editable and "edit_file" in editable
    assert "delete_file" not in writable and "cleanup_storage" not in writable
    assert "delete_file" not in editable and "cleanup_storage" not in editable
    print("PASS scheduled tasks cannot widen side effects from web content")


async def main():
    await test_next_due_minimal()
    await test_media_queue()
    test_scheduled_permissions()
    print("ALL SCHEDULER/MEDIA/SECURITY TESTS PASS")


if __name__ == "__main__":
    asyncio.run(main())
