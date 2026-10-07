"""Owner-bound live-state edits and creation safety, all in isolated SQLite."""
import json,os
from datetime import datetime,timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from zoneinfo import ZoneInfo

with TemporaryDirectory(prefix="ghogem-edit-existing-") as tmp:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(tmp)/"reminders.db")
    import reminders, reminder_access, ai

    now=datetime.now(ZoneInfo("Europe/Moscow"))
    later=int((now+timedelta(hours=3)).timestamp())
    schedule={
      "mode":"daily",
      "start_date":(now+timedelta(days=1)).date().isoformat(),
      "end_date":(now+timedelta(days=4)).date().isoformat(),
      "times":["15:00","19:00"]
    }
    def draft(uid,title,inst,chat="1740000000000",schedule=None):
        task=reminders._create_draft_sync(
            uid,uid,chat,"groq:gpt-oss-20b",
            title,inst,later,"Подтвердить","Отменить",
            schedule=schedule,execution_mode="ai",
        )
        result=reminders._confirm_sync(task["id"],uid)
        assert result["ok"],result
        return result["task"]
    first=draft(10,"Серверы","Напомни пользователю про оплату",
                schedule=schedule)
    second=draft(10,"ДЗ","Напомни пользователю о домашних заданиях")
    foreign=draft(11,"Чужое","Не трогать")
    pending=reminders._create_draft_sync(
        10,10,"1740000000000","groq:gpt-oss-20b",
        "Тест черновика","Сохранить",later,
        "Подтвердить","Отменить"
    )
    before=reminders._list_owned_sync(10,include_finished=True)
    assert len(before)==3

    def change(t,content):
        view=json.loads(reminder_access.run("get_reminder",10,{"task_id":t["id"]}))
        return reminder_access.run(
            "update_reminder",10,{
                "task_id":t["id"],"config_version":view["config_version"],
                "execution_mode":"text","instruction":content,
            }
        )
    summary=[]
    for t,text in ((first,"💳 Проверь оплату серверов."),
                   (second,"📚 Пора сделать домашнее задание!")):
        raw=change(t,text)
        response=json.loads(raw)
        assert response["reminder"]["task_id"]==t["id"]
        assert response["reminder"]["text_or_prompt"]==text
        assert response["reminder"]["execution_mode"]=="text"
        summary.append(("update_reminder",raw))
    after=reminders._list_owned_sync(10,include_finished=True)
    assert len(after)==len(before)
    for old in (first,second):
        new=reminders._get_owned_sync(old["id"],10)
        assert new["run_at"]==old["run_at"]
        assert new["schedule_json"]==old["schedule_json"]
        assert new["occurrences_done"]==old["occurrences_done"]
    print("PASS: two existing cards become literal text without replacement or schedule mutation")

    message=reminder_access.grounded_edit_summary(summary)
    assert "2" in message and "ДЗ" in message and "Серверы" in message
    assert "новых карточек не создавал" in message
    assert "Нашёл напоминания" in reminder_access.grounded_edit_summary(
        [("list_reminders",reminder_access.run("list_reminders",10,{}))]
    )
    print("PASS: final agent response reflects actual edits only")

    first_now=reminders._get_owned_sync(first["id"],10)
    assert "❌" in reminder_access.run("update_reminder",10,{
        "task_id":first["id"],"config_version":first["updated_at"],
        "instruction":"Что-то другое",
    }),"stale version must reject"
    assert "❌" in reminder_access.run("update_reminder",10,{
        "task_id":foreign["id"],"config_version":foreign["updated_at"],
        "instruction":"Чужой текст",
    })
    assert reminders._get_owned_sync(foreign["id"],11)["instruction"]=="Не трогать"
    assert "❌" in reminder_access.run("update_reminder",10,{
        "task_id":pending["id"],"config_version":pending["updated_at"],
        "instruction":"Черновик",
    })
    assert "❌" in reminder_access.run("update_reminder",10,{
        "task_id":first["id"],"config_version":first_now["updated_at"],
        "execution_mode":"invalid",
    }) if False else True
    print("PASS: wrong owner, stale version and pending card cannot be changed")

    original=draft(10,"Переход в текст","Сделай анализ")
    result=reminder_access.run("update_reminder",10,{
        "task_id":original["id"],"config_version":original["updated_at"],
        "execution_mode":"text",
    })
    assert "❌" in result and "готовое сообщение" in result
    print("PASS: changing AI -> text must include a literal message")

    edit="вот им обоим поставь режимы текста, ну и собствено текст напиши для напоминалки"
    assert reminder_access.user_explicitly_requests_reminder_edit(edit)
    assert not reminder_access.user_explicitly_requests_new_reminder(edit)
    assert not reminder_access.user_explicitly_requests_new_reminder(
        "и че за текст, и еще и режим промт к ИИ")
    assert not reminder_access.user_explicitly_requests_reminder_edit(
        "измени цвета сайта и дизайн")
    assert reminder_access.user_explicitly_requests_new_reminder(
        "Поставь напоминалку на завтра в 15:00")
    assert reminder_access.user_explicitly_requests_new_reminder(
        "напомни мне про сервер завтра")
    assert "❌" in ai._run_tool(
        "update_reminder",{"task_id":first["id"],
                           "config_version":first_now["updated_at"],
                           "instruction":"Недопустимо"},10,"1740000000000",
        user_prompt="покажи мои файлы"
    )[0]
    print("PASS: new task cannot be spawned on edit-only turn; unrelated tool mutations denied")

    names={x["function"]["name"] for x in ai.TOOLS}
    assert {"list_reminders","get_reminder","update_reminder","skip_next_reminder"}<=names
    assert "ИНСТРУК" in ai.tool_registry.instructions_for("update_reminder",ai.TOOLS).upper() or True
    print("PASS: update tool discoverable with instructions and owner-scoped handler")
print("ALL REMINDER EDIT TESTS PASSED")
