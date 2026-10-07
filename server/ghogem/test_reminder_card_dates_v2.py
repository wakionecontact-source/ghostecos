"""Offline date clarity and AI automatic-mode selection schema tests."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

import ai
import bot
import schedule_v2

MSK=ZoneInfo("Europe/Moscow")
def ts(y,m,d,h,mi):
    return int(datetime(y,m,d,h,mi,tzinfo=MSK).timestamp())

def task(**kwargs):
    return {
        "title":"Оплата <серверов>",
        "instruction":"Оплатить серверы!",
        "execution_mode":"text",
        "status":"pending",
        "recurrence":"once",
        "weekdays":"",
        "run_at":ts(2026,9,30,15,0),
        "schedule_json":"",
        "occurrences_done":0,
        **kwargs,
    }

simple=bot.reminder_card_text(task())
assert "Когда" in simple and "Ср, 30 сентября 2026, 15:00 МСК" in simple,simple
assert "Осталось срабатываний" not in simple
assert "Оплата &lt;серверов&gt;" in simple
assert "без ИИ" in simple
print("PASS: one-time reminder shows one explicit local date and raw message mode")

schedule=schedule_v2.normalize_schedule(
    {"mode":"daily","start_date":"2026-09-30",
     "end_date":"2026-10-02","times":["15:00","19:00"]}
)
card=bot.reminder_card_text(task(
    schedule_json=json.dumps(schedule),recurrence="advanced",
))
assert "Ближайшее срабатывание" in card,card
assert "30 сентября 2026 — 2 октября 2026" in card,card
assert "15:00, 19:00 МСК" in card
assert "Осталось срабатываний</b>\n6" in card,card
assert "Каждый день" in card
assert "ждёт подтверждения" in card
print("PASS: six events one card, clear inclusive dates, all clock times and count")

later=bot.reminder_card_text(task(
    run_at=ts(2026,10,1,19,0),
    schedule_json=json.dumps(schedule),recurrence="advanced",
    occurrences_done=3,
    status="scheduled",
))
assert "Осталось срабатываний</b>\n3" in later,later
assert "Часы</b>\n15:00, 19:00" in later
assert "Задание подтверждено" in later
print("PASS: remaining 3 after first 3 executed")

starts_today=schedule_v2.normalize_schedule(
    {"mode":"next_days","days_count":3,"include_today":True,
     "times":["15:00","19:00"]},
    now=datetime(2026,9,29,18,10,tzinfo=MSK),
)
partial=bot.reminder_card_text(task(
    run_at=ts(2026,9,29,19,0),
    schedule_json=json.dumps(starts_today),recurrence="advanced",
))
assert "Осталось срабатываний</b>\n5" in partial,partial
assert "3 календарных дней подряд" in partial
print("PASS: today with missed 15:00 shows 5, no phantom sixth event")

event_list=schedule_v2.normalize_schedule(
    {"mode":"occurrences","occurrences":[
        "2026-09-30T15:00:00+03:00","2026-10-02T19:00:00+03:00"
    ]}
)
exact=bot.reminder_card_text(task(
    run_at=ts(2026,9,30,15,0),schedule_json=json.dumps(event_list),
    recurrence="advanced",
))
assert "30.09 15:00, 02.10 19:00" in exact,exact
assert "Осталось срабатываний</b>\n2" in exact
print("PASS: custom dates display actual pairs, without extra times")

explicit_dates=schedule_v2.normalize_schedule({
    "mode":"dates","dates":["2026-09-30","2026-10-02"],
    "times":["15:00","19:00"],
})
dates_card=bot.reminder_card_text(task(
    schedule_json=json.dumps(explicit_dates),recurrence="advanced",
))
assert "30 сентября 2026 — 2 октября 2026" in dates_card
assert "Осталось срабатываний</b>\n4" in dates_card
assert "без даты окончания" not in dates_card
print("PASS: finite explicit dates show real end and 4 remaining events")

infinite=bot.reminder_card_text(task(recurrence="daily"))
assert "Не установлено" in infinite
print("PASS: recurring indefinitely is labeled without a fictional end date")

name=ai.REMINDER_TOOL
params=name["function"]["parameters"]
assert "execution_mode" in params["required"] and params["properties"]["execution_mode"]["enum"]==["text","ai"]
assert "execution_mode" in ai.REMINDER_SYSTEM_PROMPT
print("PASS: AI must explicitly select a validated text or agent mode")

print("ALL CARD-DATE AND AI-MODE TESTS PASS")
