"""Deterministic reminder-mode commands that work even if all AI providers fail.

The strict parser handles only clear direct requests to switch existing
reminders to plain text. Any ambiguity is surfaced to the user instead of
silently creating a new reminder.
"""
from __future__ import annotations
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo
import re

import reminders

MOSCOW=ZoneInfo("Europe/Moscow")

def is_text_mode_command(prompt: str) -> bool:
    text=" ".join(str(prompt or "").casefold().split())
    if len(text)>1400:
        return False
    # User must be asking to CHANGE a reminder, not simply discuss the feature.
    if not re.search(r"(?:напомин|напоминал|задан|режим|пром[пт]|обоим|обоих)",text):
        return False
    if not re.search(
        r"(?:измени|изменить|поменяй|поменять|переведи|переключи|"
        r"поставь|сделай|настрой|преврати|замени)",text
    ):
        return False
    if not re.search(
        r"(?:текстов|тектов|режим[аы]?\s+текст|обычн\w*\s+сообщен|"
        r"без\s+ии|не\s+на\s+пром[пт])",text
    ):
        return False
    if re.search(r"(?:не\s+(?:меняй|изменяй|переключай)|"
                 r"отмени\s+(?:изменени|переключени))",text):
        return False
    return True

def _literal_text(task: dict) -> str:
    title=(task.get("title") or "Задание").casefold()
    if "сервер" in title or "оплат" in title:
        return "💳 Проверь оплату серверов: если ещё не оплатил, оплати и проверь платёж."
    if "дз" in title or "домашн" in title or "урок" in title:
        return "📚 Пора делать домашнее задание! Посмотри задания на завтра и приступай."
    return f"🔔 Напоминание: {str(task.get('title') or 'Проверь своё задание')[:100]}"

def _selected_tasks(tasks: list[dict], prompt: str) -> list[dict]:
    text=prompt.casefold()
    # Existing confirmed schedules only. Never edit an unconfirmed draft.
    active=[task for task in tasks if task.get("status")=="scheduled"]
    names={
        "homework":re.search(r"\bдз\b|домашн|урок",text),
        "servers":re.search(r"сервер|оплат",text),
    }
    if any(names.values()):
        chosen=[]
        for task in active:
            title=(task.get("title") or "").casefold()
            if names["homework"] and any(x in title for x in ("дз","домашн","урок")):
                chosen.append(task)
            elif names["servers"] and any(x in title for x in ("сервер","оплат")):
                chosen.append(task)
        if chosen:
            return chosen
        return []
    # Users saying 'обоим' often refer to the two confirmed recurring tasks.
    # When the target is not explicit, do not mutate an arbitrary long list.
    if len(active)<=2:
        return active
    return []

async def handle_text_mode_request(uid: int, prompt: str, *, on_updated=None) -> str | None:
    if not is_text_mode_command(prompt):
        return None
    current=await reminders.list_owned(uid,limit=100)
    selected=_selected_tasks(current,prompt)
    if not selected:
        return ("⚠️ Не могу однозначно выбрать напоминания для изменения. "
                "Напиши их названия или открой /reminders. Новых карточек не создавал.")
    updated=[]
    unchanged=[]
    errors=[]
    for task in selected:
        if task.get("execution_mode")=="text":
            unchanged.append(task)
            continue
        target_text=_literal_text(task)
        result=await reminders.change_existing(
            uid,task["id"],expected_updated_at=task["updated_at"],
            execution_mode="text",instruction=target_text,
        )
        if result["ok"]:
            updated.append(result["task"])
        else:
            errors.append((task.get("title") or task["id"],result["reason"]))
    lines=["✅ Проверил существующие напоминания прямо в базе, без вызова ИИ."]
    for task in updated+unchanged:
        due=datetime.fromtimestamp(int(task["run_at"]),MOSCOW)
        lines.append(
            f"• {task['title']}: 💬 текстовый режим; "
            f"ближайшее {due.strftime('%d.%m.%Y в %H:%M')} МСК.\n"
            f"  Сообщение: {task['instruction']}"
        )
    if updated:
        lines.append(f"Изменено карточек: {len(updated)}.")
    if unchanged:
        lines.append(f"Уже были текстовыми: {len(unchanged)}.")
    if errors:
        lines.append("Не удалось изменить: "+", ".join(f"{name} ({reason})" for name,reason in errors))
    lines.append("Даты, повторения и ID сохранены. Ничего нового не создавал.")
    return "\n".join(lines)
