import os
import tempfile
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path
from unittest.mock import patch

import schedule_v2

MSK = ZoneInfo("Europe/Moscow")
dates = [
 "2026-09-30T15:00:00+03:00","2026-09-30T19:00:00+03:00",
 "2026-10-01T15:00:00+03:00","2026-10-01T19:00:00+03:00",
 "2026-10-02T15:00:00+03:00","2026-10-02T19:00:00+03:00",
]
schedule={"mode":"daily","start_date":"2026-09-30",
          "end_date":"2026-10-02","times":["15:00","19:00"]}
before=int(datetime(2026,9,29,15,0,tzinfo=MSK).timestamp())
actual=[]
for i in range(6):
    before=schedule_v2.next_trigger(schedule,after=before,completed=i)
    actual.append(datetime.fromtimestamp(before,MSK).isoformat(timespec="seconds"))
assert actual == dates, actual
assert schedule_v2.next_trigger(schedule,after=before,completed=6) is None
print("PASS: precise 6 occurrences under one finite schedule")

parsed=schedule_v2.parse_user_schedule("30.09.2026–02.10.2026; 15:00, 19:00")
assert parsed["times"]==["15:00","19:00"]
assert parsed["end_date"]=="2026-10-02"
x=schedule_v2.normalize_schedule({"mode":"occurrences","occurrences":dates})
assert len(x["occurrences"])==6
print("PASS: custom UI parse and independent one-card occurrences")
start=datetime.now(MSK)+timedelta(days=1)
day1=start.date();day2=day1+timedelta(days=2)
times=["12:00","18:00"]
sch={"mode":"daily","start_date":day1.isoformat(),
     "end_date":day2.isoformat(),"times":times}
with tempfile.TemporaryDirectory() as temp:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(temp)/"r.db")
    import reminders
    draft=reminders._create_draft_sync(
        123,123,"1740000000000","groq:gpt-oss-20b",
        "Серверы","Напомни про оплату",0,"Да","Нет",schedule=sch)
    assert draft["recurrence"]=="advanced"
    assert draft["schedule_json"] and draft["occurrences_done"]==0
    assert len(reminders._list_active_sync(123))==1
    confirmed=reminders._confirm_sync(draft["id"],123)
    assert confirmed["ok"],confirmed
    assert reminders._claim_sync(draft["id"],confirmed["task"]["run_at"]+1)
    prev=draft["run_at"]
    finished=reminders._complete_sync(draft["id"])
    assert finished["ok"]
    new=finished["task"]
    assert new["status"]=="scheduled" and new["occurrences_done"]==1
    assert new["run_at"]>prev
    n=1
    while new["status"]=="scheduled":
        task=reminders._claim_sync(draft["id"],new["run_at"]+1)
        assert task
        finished=reminders._complete_sync(draft["id"])
        new=finished["task"]
        n+=1
        assert n<=6
    assert new["status"]=="completed" and n==6
    assert new["occurrences_done"]==6
    print("PASS: one confirmed card dispatches 6 times and auto-completes")
    another=reminders._create_draft_sync(
        123,123,"1740000000000","groq:gpt-oss-20b",
        "Разовый тест","Тест",int((datetime.now(MSK)+timedelta(hours=6)).timestamp()),
        "Да","Нет")
    assert another["recurrence"]=="once"
    assert len(reminders._list_active_sync(123))==1
    assert not reminders._confirm_sync(another["id"],124)["ok"]
    print("PASS: legacy one-shot and cross-owner confirmation restriction")
print("ALL REMINDERS TESTS PASS")
