"""Simulates every trigger of one real SQLite reminder, without Telegram/API."""
from datetime import datetime, timedelta
from pathlib import Path
import os
import tempfile
from zoneinfo import ZoneInfo

import schedule_v2

MSK=ZoneInfo("Europe/Moscow")
def stamp(y,m,d,h=0):
    return int(datetime(y,m,d,h,0,tzinfo=MSK).timestamp())

def test_calendar():
    policy={"mode":"daily","start_date":"2026-09-30","end_date":"2026-10-02",
            "times":["15:00","19:00"]}
    cursor=stamp(2026,9,29,15)
    received=[]
    for count in range(6):
        cursor=schedule_v2.next_trigger(policy,after=cursor,completed=count)
        assert cursor is not None
        received.append(datetime.fromtimestamp(cursor,MSK).strftime("%d.%m %H:%M"))
    assert received==[
        "30.09 15:00","30.09 19:00","01.10 15:00",
        "01.10 19:00","02.10 15:00","02.10 19:00",
    ],received
    assert schedule_v2.next_trigger(policy,after=cursor,completed=6) is None
    assert "19:00" in schedule_v2.describe(policy)
    print("PASS 1: 3 calendar days x 2 hours = 6 future triggers on one policy")
    # Date exclusion and custom weekdays with finite schedule
    p={"mode":"custom","start_date":"2026-09-28","end_date":"2026-10-08",
       "times":["09:00","18:00"],"weekdays":[1,3,5],
       "exclude_dates":["2026-09-30"]}
    day=schedule_v2.next_trigger(p,after=stamp(2026,9,28,9))
    assert datetime.fromtimestamp(day,MSK).strftime("%Y-%m-%d %H:%M")=="2026-09-28 18:00"
    day=schedule_v2.next_trigger(p,after=stamp(2026,9,28,18))
    assert datetime.fromtimestamp(day,MSK).strftime("%Y-%m-%d %H:%M")=="2026-10-02 09:00"
    print("PASS 2: weekdays, exclusions, multiple times")
    p={"mode":"dates","dates":["2026-10-07","2026-10-02"],"times":["15:00","19:00"],"count":3}
    first=schedule_v2.next_trigger(p,after=stamp(2026,9,29))
    assert first==stamp(2026,10,2,15)
    assert schedule_v2.next_trigger(p,after=stamp(2026,10,2,19),completed=3) is None
    print("PASS 3: explicit unordered dates and count")
    for bad in (
        {"mode":"daily","start_date":"2026-09-30","end_date":"2026-09-29","times":["15:00"]},
        {"mode":"daily","start_date":"2026-09-30","times":["15:00","15:00"]},
        {"mode":"custom","start_date":"2026-09-30","times":["15:00"]},
        {"mode":"daily","start_date":"2026-09-30","times":["29:00"]},
    ):
        try:schedule_v2.normalize_schedule(bad)
        except ValueError:pass
        else:raise AssertionError(f"Invalid calendar accepted {bad}")
    print("PASS 4: invalid calendars rejected")

def test_sqlite():
    with tempfile.TemporaryDirectory() as folder:
        os.environ["GHOGEM_REMINDERS_DB"]=str(Path(folder)/"reminders.db")
        import reminders
        now=datetime.now(MSK)
        future=(now+timedelta(days=1)).date()
        last=future+timedelta(days=2)
        policy={"mode":"daily","start_date":future.isoformat(),
                "end_date":last.isoformat(),"times":["15:00","19:00"]}
        # use dates at least one day ahead
        task=reminders._create_draft_sync(
            user_id=945,telegram_chat_id=945,ai_chat_id="1740000000001",
            model_key="test",title="Оплата серверов",
            instruction="Напомнить про оплату серверов",
            run_at=0,confirm_button="Подтвердить",cancel_button="Отменить",
            schedule=policy
        )
        assert task["recurrence"]=="advanced" and task["status"]=="pending"
        assert task["schedule_json"]
        confirmed=reminders._confirm_sync(task["id"],945)
        assert confirmed["ok"],confirmed
        first=confirmed["task"]["run_at"]
        triggers=[]
        for i in range(6):
            current=reminders._get_sync(task["id"])
            assert current["status"]=="scheduled",current
            triggers.append(datetime.fromtimestamp(current["run_at"],MSK).strftime("%Y-%m-%d %H:%M"))
            claimed=reminders._claim_sync(task["id"],current["run_at"]+1)
            assert claimed and claimed["status"]=="running",claimed
            done=reminders._complete_sync(task["id"])
            assert done["ok"]
            assert done["task"]["occurrences_done"]==i+1
        assert triggers == [
            (future+timedelta(days=i)).isoformat()+f" {h}:00"
            for i in range(3) for h in ("15","19")
        ],triggers
        assert reminders._get_sync(task["id"])["status"]=="completed"
        assert reminders._list_active_sync(945)==[]
        print("PASS 5: ONE SQLite task/card -> six executions -> automatic completion")
        # Legacy recurrence still works, unchanged.
        later=int((now+timedelta(days=1)).timestamp())
        legacy=reminders._create_draft_sync(
            945,945,"1740000000001","test","Legacy",
            "Legacy","%s"%later,"Подтвердить","Отменить",
            recurrence="daily")
        assert legacy["recurrence"]=="daily" and not legacy["schedule_json"]
        print("PASS 6: legacy daily reminders remain compatible")

if __name__=="__main__":
    test_calendar()
    test_sqlite()
