from datetime import datetime,timedelta
from zoneinfo import ZoneInfo
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import schedule_v2 as s

MSK=ZoneInfo("Europe/Moscow")
def expected_at(hour,minute):
    return datetime(2026,9,29,hour,minute,tzinfo=MSK)

cases=[
    # 18:10, 15 and 19 -> include today with only 19:00 left.
    (expected_at(18,10),True,"2026-09-29","2026-10-01",[
      ("2026-09-29","19:00"),("2026-09-30","15:00"),("2026-09-30","19:00"),
      ("2026-10-01","15:00"),("2026-10-01","19:00"),
    ]),
    # 20:00, both times passed -> tomorrow starts 3 full days.
    (expected_at(20,0),True,"2026-09-30","2026-10-02",[
      (day,t) for day in ("2026-09-30","2026-10-01","2026-10-02") for t in ("15:00","19:00")
    ]),
    (expected_at(10,0),False,"2026-09-30","2026-10-02",[
      (day,t) for day in ("2026-09-30","2026-10-01","2026-10-02") for t in ("15:00","19:00")
    ]),
    # Include at 14:59 exactly 30 secs before 15:00 => both times today.
    (expected_at(14,59),True,"2026-09-29","2026-10-01",[
      (day,t) for day in ("2026-09-29","2026-09-30","2026-10-01") for t in ("15:00","19:00")
    ])
]
for now, include, start, end, expected in cases:
    policy=s.normalize_schedule(
      {"mode":"next_days","days_count":3,"include_today":include,
       "times":["15:00","19:00"]},now=now
    )
    assert (policy["start_date"],policy["end_date"])==(start,end)
    assert policy["days_count"]==3 and policy["relative_filter"]=="next_days"
    found=[];cursor=int(now.timestamp())
    while True:
        next_run=s.next_trigger(policy,after=cursor)
        if next_run is None:
            break
        stamp=datetime.fromtimestamp(next_run,MSK)
        found.append((stamp.date().isoformat(),stamp.strftime("%H:%M")))
        cursor=next_run
    assert found==expected,(now,found,expected)
print("PASS 4: include today if times remain, tomorrow fallback, exclude today, full schedule and auto-end")
actual=s.parse_user_schedule("3; да; 15:00, 19:00")
assert actual["relative_filter"]=="next_days" and actual["days_count"]==3
actual2=s.parse_user_schedule("3 дня; нет; 15:00, 19:00")
assert actual2["include_today"] is False
print("PASS: one-line Telegram input in both formats")
for bad in (
    {"mode":"next_days","days_count":0,"include_today":True,"times":["15:00"]},
    {"mode":"next_days","days_count":3.5,"include_today":True,"times":["15:00"]},
    {"mode":"next_days","days_count":3,"include_today":"no","times":["15:00"]},
    {"mode":"next_days","days_count":3,"include_today":False,"times":["30:00"]},
):
    try:s.normalize_schedule(bad)
    except ValueError:pass
    else:raise AssertionError(bad)
print("PASS: invalid parameters refused")
with TemporaryDirectory(prefix="test-ghogem-next-days-") as temp:
    os.environ["GHOGEM_REMINDERS_DB"]=str(Path(temp)/"reminders.db")
    import reminders
    today=datetime.now(MSK).date()
    test_s=s.normalize_schedule({"mode":"next_days","days_count":3,
                       "include_today":False,"times":["15:00","19:00"]})
    first=s.next_trigger(test_s,after=int(datetime.now(MSK).timestamp())+30)
    assert first
    task=reminders._create_draft_sync(
        1234,1234,"1740000000000","groq:gpt-oss-20b",
        "Оплата серверов","Напомни оплатить серверы",first,
        "Подтвердить","Отменить",schedule=test_s
    )
    assert task["recurrence"]=="advanced"
    assert len(reminders._list_active_sync(1234))==1
    assert reminders._confirm_sync(task["id"],1234)["ok"]
    count=0
    while True:
        current=reminders._get_sync(task["id"])
        if current["status"]=="completed":
            break
        assert reminders._claim_sync(task["id"],current["run_at"]+1)
        updated=reminders._complete_sync(task["id"])
        assert updated["ok"]
        count+=1
        assert count<=6
    assert count==6 and reminders._get_sync(task["id"])["status"]=="completed"
    print("PASS: N days one reminder card, 6 events, automatic stop")
print("ALL NEXT_DAYS FILTER TESTS PASS")
