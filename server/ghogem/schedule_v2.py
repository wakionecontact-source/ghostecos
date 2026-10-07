"""Fully configurable Moscow-time trigger calendars for one reminder card.

Frequency presets are convenience filters only. The canonical schedule is
validated server-side; the LLM never writes SQL or arbitrary cron expressions.
"""
from __future__ import annotations
import calendar
from datetime import datetime, date, time, timedelta
import re
from zoneinfo import ZoneInfo

MOSCOW = ZoneInfo("Europe/Moscow")
DEFAULT_TIMEZONE = "Europe/Moscow"
MODES = {"dates", "daily", "weekdays", "weekly", "monthly", "custom", "occurrences", "next_days"}


def _zone(timezone_name: str | None = None) -> ZoneInfo:
    try:
        return ZoneInfo(str(timezone_name or DEFAULT_TIMEZONE))
    except Exception:
        return MOSCOW
MAX_DATE_COUNT = 366
MAX_TIMES_PER_DAY = 24
MAX_OCCURRENCES = 5000

def _date(value: str) -> date:
    try:
        text = str(value or "").strip()
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            raise ValueError()
        return date.fromisoformat(text)
    except (ValueError, TypeError) as error:
        raise ValueError("Дата должна быть в формате ГГГГ-ММ-ДД.") from error

def _clock(value: str) -> str:
    raw = str(value or "").strip()
    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", raw):
        raise ValueError("Время указывай как ЧЧ:ММ (например 15:00).")
    return raw

def normalize_schedule(
    raw: dict,
    *,
    now: datetime | None = None,
    timezone_name: str = DEFAULT_TIMEZONE,
) -> dict:
    zone = _zone(timezone_name)
    if not isinstance(raw, dict):
        raise ValueError("Расписание должно быть объектом.")
    mode = str(raw.get("mode") or ("next_days" if raw.get("days_count") and not raw.get("start_date") else
                                    "occurrences" if raw.get("occurrences") else
                                    "dates" if raw.get("dates") else "daily")).lower()
    if mode == "next_days":
        # Freeze relative "today" into real Moscow dates at draft creation.
        # Do not treat an elapsed today as one of the requested N days.
        quantity = raw.get("days_count")
        if type(quantity) is not int or not 1 <= quantity <= 3660:
            raise ValueError("Число дней должно быть целым от 1 до 3660.")
        include_today = raw.get("include_today", True)
        if type(include_today) is not bool:
            raise ValueError("include_today должен быть true или false.")
        clocks = raw.get("times")
        if not isinstance(clocks, list) or not clocks or len(clocks) > MAX_TIMES_PER_DAY:
            raise ValueError("Укажи от 1 до 24 времён в times.")
        times = sorted(_clock(value) for value in clocks)
        if len(set(times)) != len(times):
            raise ValueError("Не повторяй одно и то же время.")
        current = (now or datetime.now(zone)).astimezone(zone)
        today = current.date()
        can_start_today = False
        if include_today:
            for value in times:
                h, m = (int(x) for x in value.split(":"))
                trigger = datetime(today.year, today.month, today.day, h, m, tzinfo=zone)
                if (trigger - current).total_seconds() >= 30:
                    can_start_today = True
                    break
        begin = today if can_start_today else today + timedelta(days=1)
        end = begin + timedelta(days=quantity - 1)
        # Preserve presentation metadata. Execution sees a resolved, finite
        # daily calendar and never needs to reinterpret "today" tomorrow.
        raw = {
            "mode": "daily", "start_date": begin.isoformat(),
            "end_date": end.isoformat(), "times": times,
            "days_count": quantity, "include_today": include_today,
            "relative_filter": "next_days",
        }
        mode = "daily"
    if mode not in MODES:
        raise ValueError("Неизвестный режим календаря.")
    if mode=="occurrences":
        items=raw.get("occurrences") or []
        if not isinstance(items,list) or not 1<=len(items)<=MAX_OCCURRENCES:
            raise ValueError("Укажи от 1 до 5000 точных срабатываний.")
        normalized=[]
        for item in items:
            try:
                event=datetime.fromisoformat(str(item).replace("Z","+00:00"))
                if event.tzinfo is None:
                    event=event.replace(tzinfo=zone)
                event=event.astimezone(zone)
                if event.second or event.microsecond:
                    raise ValueError("Точное время должно задаваться до минуты.")
                normalized.append(event.isoformat(timespec="minutes"))
            except (ValueError,TypeError) as error:
                raise ValueError("Точные срабатывания должны быть ISO 8601 с датой и временем.") from error
        entries=sorted(set(normalized))
        first,last=datetime.fromisoformat(entries[0]),datetime.fromisoformat(entries[-1])
        if (last-first).days>366*10:
            raise ValueError("Расписание длиннее десяти лет.")
        return {
            "mode":"occurrences","occurrences":entries,
            "times":[],"dates":[],"start_date":first.date().isoformat(),
            "end_date":last.date().isoformat(),
            "weekdays":[],"exclude_dates":[],
            "interval_days":1,"interval_weeks":1,"interval_months":1,
            "count":len(entries),
        }
    clocks = raw.get("times")
    if not isinstance(clocks, list) or not clocks or len(clocks) > MAX_TIMES_PER_DAY:
        raise ValueError("Укажи от 1 до 24 времён в times.")
    times = sorted({_clock(x) for x in clocks})
    if len(times) != len(clocks):
        raise ValueError("Повторяющиеся часы в расписании недопустимы.")
    dates = raw.get("dates") or []
    if not isinstance(dates, list) or len(dates) > MAX_DATE_COUNT:
        raise ValueError("Слишком много дат в расписании.")
    dates = sorted({_date(x).isoformat() for x in dates})
    if mode == "dates" and not dates:
        raise ValueError("Для режима dates укажи dates с конкретными датами.")
    start = _date(raw.get("start_date") or (
        dates[0] if dates else datetime.now(zone).date().isoformat()
    ))
    end_raw = raw.get("end_date")
    end = _date(end_raw) if end_raw else None
    if end and end < start:
        raise ValueError("Дата окончания раньше даты начала.")
    if end and (end-start).days > 366*10:
        raise ValueError("Расписание длиннее десяти лет.")
    if dates and (min(dates)<start.isoformat() or
                  (end and max(dates)>end.isoformat())):
        raise ValueError("Точные даты должны лежать внутри диапазона.")
    excluded = raw.get("exclude_dates") or []
    if not isinstance(excluded,list) or len(excluded)>366:
        raise ValueError("Неверный список исключённых дат.")
    excluded = sorted({_date(x).isoformat() for x in excluded})
    weekdays = raw.get("weekdays") or []
    if not isinstance(weekdays,list):
        raise ValueError("weekdays должен быть списком ISO-дней недели.")
    try:
        weekdays = sorted({int(day) for day in weekdays})
    except (TypeError,ValueError) as error:
        raise ValueError("Дни недели: числа от 1 до 7.") from error
    if any(d<1 or d>7 for d in weekdays):
        raise ValueError("Дни недели: числа от 1 до 7.")
    if mode=="custom" and not weekdays:
        raise ValueError("Для custom выбери weekdays.")
    for field in ("interval_days","interval_weeks","interval_months"):
        if field in raw and (not isinstance(raw[field],int) or
                             isinstance(raw[field],bool) or
                             not 1 <= raw[field] <= 366):
            raise ValueError(f"{field} должен быть числом от 1 до 366.")
    count = raw.get("count")
    if count is not None and (
        not isinstance(count,int) or isinstance(count,bool)
        or count<1 or count>MAX_OCCURRENCES
    ):
        raise ValueError("count: число срабатываний от 1 до 5000.")
    return {
        "mode":mode,"times":times,"dates":dates,
        "start_date":start.isoformat(),
        "end_date":end.isoformat() if end else None,
        "weekdays":weekdays,"exclude_dates":excluded,
        "interval_days":int(raw.get("interval_days") or 1),
        "interval_weeks":int(raw.get("interval_weeks") or 1),
        "interval_months":int(raw.get("interval_months") or 1),
        "count":count,
        **({
            "days_count": raw["days_count"],
            "include_today": raw["include_today"],
            "relative_filter": "next_days",
        } if raw.get("relative_filter") == "next_days" else {}),
    }

def _month_distance(start: date, current: date) -> int:
    return (current.year-start.year)*12+(current.month-start.month)

def _selected(day: date, policy: dict) -> bool:
    if day.isoformat() in policy["exclude_dates"]:
        return False
    if policy["dates"]:
        return day.isoformat() in policy["dates"]
    mode=policy["mode"]
    start=_date(policy["start_date"])
    elapsed=(day-start).days
    if mode=="dates":
        return False
    if mode in ("daily","weekdays","custom"):
        if elapsed%policy["interval_days"]:
            return False
        if mode=="weekdays" and day.weekday()>=5:
            return False
        if (mode=="custom" or policy["weekdays"]) and day.isoweekday() not in policy["weekdays"]:
            return False
        return True
    if mode=="weekly":
        if (elapsed//7)%policy["interval_weeks"]:
            return False
        desired=policy["weekdays"] or [start.isoweekday()]
        return day.isoweekday() in desired
    if mode=="monthly":
        elapsed_months=_month_distance(start,day)
        if elapsed_months%policy["interval_months"]:
            return False
        target=min(start.day,calendar.monthrange(day.year,day.month)[1])
        return day.day==target
    return False

def next_trigger(
    schedule: dict,
    *,
    after: int,
    completed: int = 0,
    timezone_name: str = DEFAULT_TIMEZONE,
) -> int | None:
    zone = _zone(timezone_name)
    policy=normalize_schedule(schedule, timezone_name=timezone_name)
    count=policy["count"]
    if count is not None and completed>=count:
        return None
    if policy["mode"]=="occurrences":
        for event in policy["occurrences"]:
            stamp=int(datetime.fromisoformat(event).timestamp())
            if stamp>after:
                return stamp
        return None
    start=_date(policy["start_date"])
    after_date=datetime.fromtimestamp(int(after),zone).date()
    day=max(start,after_date)
    if policy["dates"]:
        candidate_days=[_date(x) for x in policy["dates"] if _date(x)>=day]
    else:
        end=_date(policy["end_date"]) if policy["end_date"] else day+timedelta(days=366*10)
        if end<day:
            return None
        candidate_days=(day+timedelta(days=i) for i in range(min((end-day).days+1,366*10+1)))
    end=_date(policy["end_date"]) if policy["end_date"] else None
    for current in candidate_days:
        if end and current>end:
            break
        if current<start or not _selected(current,policy):
            continue
        for text in policy["times"]:
            hour,minute=(int(x) for x in text.split(":"))
            candidate=datetime(current.year,current.month,current.day,
                               hour,minute,tzinfo=zone)
            stamp=int(candidate.timestamp())
            if stamp>after:
                return stamp
    return None

def describe(schedule: dict, *, timezone_name: str = DEFAULT_TIMEZONE) -> str:
    cfg=normalize_schedule(schedule, timezone_name=timezone_name)
    if cfg["mode"]=="occurrences":
        events=cfg["occurrences"]
        shown=", ".join(datetime.fromisoformat(item).strftime("%d.%m %H:%M")
                        for item in events[:8])
        return f"Точные срабатывания ({len(events)}): {shown}" + (
            " …" if len(events)>8 else ""
        ) + f" · {timezone_name}"
    start=datetime.strptime(cfg["start_date"],"%Y-%m-%d").strftime("%d.%m.%Y")
    finish=(datetime.strptime(cfg["end_date"],"%Y-%m-%d").strftime("%d.%m.%Y")
            if cfg["end_date"] else "без даты окончания")
    day_text=", ".join(datetime.strptime(d,"%Y-%m-%d").strftime("%d.%m")
                       for d in cfg["dates"][:8])
    names=("Пн","Вт","Ср","Чт","Пт","Сб","Вс")
    weekdays=", ".join(names[x-1] for x in cfg["weekdays"])
    if cfg["mode"]=="dates":
        period="Даты: "+day_text+("…" if len(cfg["dates"])>8 else "")
    elif cfg.get("relative_filter") == "next_days":
        period = f"{cfg['days_count']} календарных дн.: {start} — {finish}"
    else:
        preset={"daily":"Каждый день","weekdays":"Пн–Пт",
                "weekly":"Еженедельно","monthly":"Ежемесячно",
                "custom":"Выбранные дни"}.get(cfg["mode"],cfg["mode"])
        period=f"{preset}: {start} — {finish}"
        if weekdays:
            period+=f"; дни: {weekdays}"
    if cfg["exclude_dates"]:
        period+=f"; исключений: {len(cfg['exclude_dates'])}"
    if cfg["count"]:
        period+=f"; максимум {cfg['count']} срабатываний"
    return period+"; в "+", ".join(cfg["times"])+f" · {timezone_name}"


def parse_user_schedule(value: str, *, timezone_name: str = DEFAULT_TIMEZONE) -> dict:
    """Human-friendly range plus times, or complete JSON for advanced fields.

    Examples:
       30.09.2026–02.10.2026; 15:00, 19:00
       {"mode":"custom",...}
    """
    import json
    raw = str(value or "").strip()
    if raw.startswith("{"):
        return normalize_schedule(json.loads(raw), timezone_name=timezone_name)
    # Quick filter: "3; да; 15:00, 19:00" or "3 дня; нет; 15:00, 19:00".
    short = re.fullmatch(
        r"\s*(\d{1,4})\s*(?:дней|дня|день|дн\.)?\s*[;,]\s*"
        r"(да|нет|включая|не включая|сегодня|завтра|true|false)\s*[;,]\s*"
        r"((?:\d{2}:\d{2}\s*,?\s*)+)\s*",
        raw, flags=re.IGNORECASE,
    )
    if short:
        include = short.group(2).lower() in ("да", "включая", "сегодня", "true")
        return normalize_schedule({
            "mode": "next_days", "days_count": int(short.group(1)),
            "include_today": include,
            "times": [t.strip() for t in short.group(3).split(",") if t.strip()],
        }, timezone_name=timezone_name)
    # A bounded range, inclusive, in Russian or ISO date notation.
    expression = re.fullmatch(
        r"\s*(\d{2}\.\d{2}\.\d{4}|\d{4}-\d{2}-\d{2})\s*"
        r"(?:\.\.|—|–|до|-)\s*"
        r"(\d{2}\.\d{2}\.\d{4}|\d{4}-\d{2}-\d{2})\s*"
        r"[;,]\s*(.+)\s*", raw, flags=re.IGNORECASE
    )
    if not expression:
        raise ValueError(
            "Формат: 3; да; 15:00, 19:00 (включить сегодняшний день) "
            "или 3; нет; 15:00, 19:00, или "
            "30.09.2026–02.10.2026; 15:00, 19:00. "
            "Для сложного графика можно прислать JSON."
        )
    def date_iso(x):
        return (datetime.strptime(x,"%d.%m.%Y").date().isoformat()
                if "." in x else _date(x).isoformat())
    start,end=date_iso(expression.group(1)),date_iso(expression.group(2))
    times=[v.strip() for v in expression.group(3).split(",") if v.strip()]
    return normalize_schedule({
        "mode":"daily","start_date":start,"end_date":end,"times":times,
    }, timezone_name=timezone_name)
