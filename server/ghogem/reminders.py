"""Persistent, explicitly confirmed one-shot tasks for the GhoGem Telegram bot."""
from __future__ import annotations

import asyncio
import calendar
import os
import sqlite3
import time
import uuid
import re
import json
import schedule_v2
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

DB_PATH = os.getenv("GHOGEM_REMINDERS_DB") or os.path.join(os.path.dirname(__file__), "reminders.db")
MOSCOW = ZoneInfo("Europe/Moscow")
DEFAULT_TIMEZONE = "Europe/Moscow"
MIN_LEAD_SECONDS = 30


def timezone_obj(timezone_name: str | None = None) -> ZoneInfo:
    try:
        return ZoneInfo(str(timezone_name or DEFAULT_TIMEZONE))
    except Exception:
        return MOSCOW


def timezone_label(
    timezone_name: str | None = None,
    moment: datetime | None = None,
) -> str:
    name = str(timezone_name or DEFAULT_TIMEZONE)
    if name == "Europe/Moscow":
        return "МСК"
    zone = timezone_obj(name)
    current = moment.astimezone(zone) if moment is not None else datetime.now(zone)
    return current.tzname() or name


MAX_LEAD_SECONDS = 366 * 86400
DRAFT_TTL_SECONDS = 30 * 60


def parse_run_at(value: str, timezone_name: str = DEFAULT_TIMEZONE) -> int:
    text = str(value or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone_obj(timezone_name))
    return int(parsed.timestamp())


def format_run_at(timestamp: int, timezone_name: str = DEFAULT_TIMEZONE) -> str:
    local = datetime.fromtimestamp(int(timestamp), timezone_obj(timezone_name))
    label = timezone_label(timezone_name, local)
    return local.strftime("%d.%m.%Y в %H:%M") + f" {label}"


RECURRENCE_LABELS = {
    "once": "Одноразово",
    "daily": "Каждый день",
    "weekdays": "Пн–Пт",
    "weekly": "Еженедельно",
    "monthly": "Ежемесячно",
    "advanced": "Свой график",
}
_WEEKDAY_NAMES = ("Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс")
_WEEKDAY_ALIASES = {
    "пн": 1, "понедельник": 1, "mon": 1, "monday": 1,
    "вт": 2, "вторник": 2, "tue": 2, "tuesday": 2,
    "ср": 3, "среда": 3, "wed": 3, "wednesday": 3,
    "чт": 4, "четверг": 4, "thu": 4, "thursday": 4,
    "пт": 5, "пятница": 5, "fri": 5, "friday": 5,
    "сб": 6, "суббота": 6, "sat": 6, "saturday": 6,
    "вс": 7, "воскресенье": 7, "sun": 7, "sunday": 7,
}


class ReminderLimitError(ValueError):
    pass


def parse_weekdays(value) -> list[int]:
    if value is None:
        return []
    if isinstance(value, str):
        raw = [part for part in re.split(r"[,;\s]+", value.strip().lower()) if part]
    elif isinstance(value, (list, tuple, set)):
        raw = list(value)
    else:
        raise ValueError("Пришли дни недели, например: Пн, Ср, Пт.")
    days = set()
    for part in raw:
        if isinstance(part, bool):
            raise ValueError("Дни недели: числа от 1 (Пн) до 7 (Вс).")
        if isinstance(part, int) or str(part).strip().isdigit():
            day = int(part)
        else:
            day = _WEEKDAY_ALIASES.get(str(part).strip().lower(), 0)
        if day < 1 or day > 7:
            raise ValueError("Не распознал день недели. Используй Пн, Вт, Ср, Чт, Пт, Сб или Вс.")
        days.add(day)
    return sorted(days)


def normalize_recurrence(recurrence="once", weekdays=None) -> tuple[str, str]:
    aliases = {
        "one_time": "once", "once": "once", "разово": "once", "одноразово": "once",
        "daily": "daily", "ежедневно": "daily", "каждый день": "daily",
        "weekdays": "weekdays", "пн-пт": "weekdays", "будни": "weekdays",
        "weekly": "weekly", "еженедельно": "weekly", "каждую неделю": "weekly",
        "monthly": "monthly", "ежемесячно": "monthly", "каждый месяц": "monthly",
        "custom": "custom", "selected_days": "custom",
    }
    raw = str(recurrence or "once").strip().lower()
    value = aliases.get(raw, raw)
    if value not in {"once", "daily", "weekdays", "weekly", "monthly", "custom", "advanced"}:
        raise ValueError("Неизвестный режим повтора задания.")
    if value == "custom":
        days = parse_weekdays(weekdays)
        if not days:
            raise ValueError("Для повтора по выбранным дням укажи хотя бы один день недели.")
        return value, ",".join(str(day) for day in days)
    return value, ""


def recurrence_label(recurrence="once", weekdays="") -> str:
    value, days = normalize_recurrence(recurrence, weekdays if recurrence == "custom" else None)
    if value == "custom":
        return "Каждую неделю: " + ", ".join(_WEEKDAY_NAMES[int(day) - 1] for day in days.split(","))
    return RECURRENCE_LABELS[value]


def next_occurrence(
    run_at: int,
    recurrence="once",
    weekdays="",
    *,
    after_timestamp=None,
    recurrence_day=None,
    timezone_name: str = DEFAULT_TIMEZONE,
) -> int | None:
    value, days = normalize_recurrence(recurrence, weekdays if recurrence == "custom" else None)
    if value == "once":
        return None
    zone = timezone_obj(timezone_name)
    scheduled = datetime.fromtimestamp(int(run_at), zone)
    after = datetime.fromtimestamp(int(after_timestamp), zone) if after_timestamp is not None else scheduled
    anchor = max(scheduled.date(), after.date())
    clock = scheduled.time().replace(tzinfo=None)

    if value in {"daily", "weekdays", "custom"}:
        day = anchor + timedelta(days=1)
        chosen = {int(item) for item in days.split(",")} if value == "custom" else None
        while True:
            candidate = datetime.combine(day, clock, tzinfo=zone)
            if value == "daily" or (value == "weekdays" and day.weekday() < 5) or (
                value == "custom" and day.isoweekday() in chosen
            ):
                timestamp = int(candidate.timestamp())
                if timestamp > int(after_timestamp or run_at):
                    return timestamp
            day += timedelta(days=1)

    if value == "weekly":
        day = scheduled.date() + timedelta(days=7)
        while True:
            candidate = datetime.combine(day, clock, tzinfo=zone)
            timestamp = int(candidate.timestamp())
            if timestamp > int(after_timestamp or run_at):
                return timestamp
            day += timedelta(days=7)

    year, month = scheduled.year, scheduled.month
    month_day = max(1, min(31, int(recurrence_day or scheduled.day)))
    while True:
        month += 1
        if month > 12:
            year += 1
            month = 1
        day = min(month_day, calendar.monthrange(year, month)[1])
        candidate = datetime(year, month, day, scheduled.hour, scheduled.minute, scheduled.second, tzinfo=zone)
        timestamp = int(candidate.timestamp())
        if timestamp > int(after_timestamp or run_at):
            return timestamp


def _connect():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=15000")
    return conn


def _init_db():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = _connect()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS reminders (
            id TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            telegram_chat_id INTEGER NOT NULL,
            ai_chat_id TEXT NOT NULL,
            model_key TEXT NOT NULL,
            title TEXT NOT NULL,
            instruction TEXT NOT NULL,
            run_at INTEGER NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            config_message_id INTEGER,
            confirm_button TEXT NOT NULL,
            cancel_button TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            recurrence TEXT NOT NULL DEFAULT 'once',
            weekdays TEXT NOT NULL DEFAULT '',
            recurrence_day INTEGER,
            retry_at INTEGER,
            replaces_id TEXT,
            schedule_json TEXT NOT NULL DEFAULT '',
            occurrences_done INTEGER NOT NULL DEFAULT 0,
            execution_mode TEXT NOT NULL DEFAULT 'ai',
            occurrences_skipped INTEGER NOT NULL DEFAULT 0,
            timezone_name TEXT NOT NULL DEFAULT 'Europe/Moscow',
            legacy_ui INTEGER NOT NULL DEFAULT 0
        )
    """)
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(reminders)")}
    migrations = {
        "recurrence": "TEXT NOT NULL DEFAULT 'once'",
        "weekdays": "TEXT NOT NULL DEFAULT ''",
        "recurrence_day": "INTEGER",
        "retry_at": "INTEGER",
        "replaces_id": "TEXT",
        "schedule_json": "TEXT NOT NULL DEFAULT ''",
        "occurrences_done": "INTEGER NOT NULL DEFAULT 0",
        "execution_mode": "TEXT NOT NULL DEFAULT 'ai'",
        "occurrences_skipped": "INTEGER NOT NULL DEFAULT 0",
        "timezone_name": "TEXT NOT NULL DEFAULT 'Europe/Moscow'",
        "legacy_ui": "INTEGER NOT NULL DEFAULT 0",
    }
    for name, declaration in migrations.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE reminders ADD COLUMN {name} {declaration}")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status, run_at)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_reminders_owner ON reminders(user_id, status, run_at)"
    )
    conn.commit()
    conn.close()


_init_db()


def normalize_execution_mode(value: str) -> str:
    mode = str(value or "ai").strip().lower()
    if mode not in ("ai", "text"):
        raise ValueError("Режим задания должен быть «Текст» или «Промпт ИИ».")
    return mode


def _to_dict(row):
    return dict(row) if row else None


def _create_draft_sync(user_id, telegram_chat_id, ai_chat_id, model_key,
                       title, instruction, run_at, confirm_button, cancel_button,
                       recurrence="once", weekdays=None, max_active=10,
                       replaces_id=None, allow_soon=False, recurrence_day=None,
                       schedule=None, occurrences_done=0, execution_mode="ai",
                       timezone_name=DEFAULT_TIMEZONE, legacy_ui=0):
    now = int(time.time())
    execution_mode = normalize_execution_mode(execution_mode)
    timezone_name = str(timezone_name or DEFAULT_TIMEZONE)
    try:
        zone = ZoneInfo(timezone_name)
    except Exception as error:
        raise ValueError("Неизвестный часовой пояс.") from error
    schedule_json = ""
    if schedule is not None:
        canonical = schedule_v2.normalize_schedule(
            schedule, timezone_name=timezone_name
        )
        schedule_json = json.dumps(canonical,ensure_ascii=False,sort_keys=True)
        next_at = schedule_v2.next_trigger(
            canonical,
            after=now + (0 if allow_soon else MIN_LEAD_SECONDS)-1,
            completed=int(occurrences_done),
            timezone_name=timezone_name,
        )
        if next_at is None:
            raise ValueError("Не найдено будущих срабатываний в расписании.")
        run_at = next_at
        recurrence,weekdays = "advanced",""
    else:
        run_at = int(run_at)
        recurrence,weekdays = normalize_recurrence(recurrence,weekdays)
    if not allow_soon and run_at < now + MIN_LEAD_SECONDS:
        raise ValueError("Время задания должно быть минимум на 30 секунд в будущем.")
    maximum_ahead = (3660*86400 if schedule_json else MAX_LEAD_SECONDS)
    if run_at > now + maximum_ahead:
        raise ValueError("Слишком отдалённая дата начала расписания.")
    title = str(title or "").strip()[:120]
    instruction = str(instruction or "").strip()[:3000]
    if not title or not instruction:
        raise ValueError("Нужны название и инструкция задания.")
    task_id = uuid.uuid4().hex
    user_id = int(user_id)
    max_active = max(1, int(max_active))
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        if replaces_id:
            cur = conn.execute(
                """UPDATE reminders SET status='editing', updated_at=?
                   WHERE id=? AND user_id=? AND status='scheduled'""",
                (now, str(replaces_id), user_id),
            )
            if cur.rowcount != 1:
                raise ValueError("Это задание уже запущено, отменено или изменяется.")
        count = conn.execute(
            """SELECT COUNT(*) FROM reminders
               WHERE user_id=? AND status IN ('pending','scheduled','running')""",
            (user_id,),
        ).fetchone()[0]
        if int(count) >= max_active:
            raise ReminderLimitError(
                f"Достигнут лимит активных заданий ({max_active}). "
                "Отмени ненужное через /reminders или освободи место."
            )
        conn.execute(
            """INSERT INTO reminders
            (id,user_id,telegram_chat_id,ai_chat_id,model_key,title,instruction,
             run_at,status,created_at,updated_at,expires_at,confirm_button,cancel_button,
             recurrence,weekdays,retry_at,replaces_id,recurrence_day,
             schedule_json,occurrences_done,execution_mode,timezone_name,legacy_ui)
            VALUES (?,?,?,?,?,?,?,?,'pending',?,?,?,?,?,?,?,NULL,?,?,?,?,?,?,?)""",
            (task_id, user_id, int(telegram_chat_id), str(ai_chat_id),
             str(model_key), title, instruction, run_at, now, now,
             now + DRAFT_TTL_SECONDS, str(confirm_button or "✅ Подтвердить")[:48],
             str(cancel_button or "❌ Отменить")[:48], recurrence, weekdays,
             str(replaces_id) if replaces_id else None,
             int(recurrence_day or datetime.fromtimestamp(run_at, zone).day),
             schedule_json,int(occurrences_done),execution_mode,timezone_name,
             1 if legacy_ui else 0),
        )
        row = conn.execute("SELECT * FROM reminders WHERE id=?", (task_id,)).fetchone()
        conn.commit()
        return _to_dict(row)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _create_edit_draft_sync(task_id, user_id, max_active=10):
    source = _get_sync(task_id)
    if not source or int(source["user_id"]) != int(user_id):
        raise ValueError("Задание не найдено.")
    if source["status"] != "scheduled":
        raise ValueError("Изменять можно только активное подтверждённое задание.")
    return _create_draft_sync(
        user_id=source["user_id"],
        telegram_chat_id=source["telegram_chat_id"],
        ai_chat_id=source["ai_chat_id"],
        model_key=source["model_key"],
        title=source["title"],
        instruction=source["instruction"],
        run_at=source["run_at"],
        confirm_button=source["confirm_button"],
        cancel_button=source["cancel_button"],
        recurrence=source.get("recurrence", "once"),
        weekdays=source.get("weekdays", ""),
        max_active=max_active,
        replaces_id=source["id"],
        allow_soon=True,
        recurrence_day=source.get("recurrence_day"),
        schedule=json.loads(source["schedule_json"]) if source.get("schedule_json") else None,
        occurrences_done=int(source.get("occurrences_done") or 0),
        execution_mode=source.get("execution_mode") or "ai",
        timezone_name=source.get("timezone_name") or DEFAULT_TIMEZONE,
        legacy_ui=int(source.get("legacy_ui") or 0),
    )


def _get_sync(task_id):
    conn = _connect()
    row = conn.execute("SELECT * FROM reminders WHERE id=?", (str(task_id),)).fetchone()
    conn.close()
    return _to_dict(row)


def _set_config_message_sync(task_id, user_id, message_id):
    conn = _connect()
    cur = conn.execute(
        """UPDATE reminders SET config_message_id=?, updated_at=?
           WHERE id=? AND user_id=? AND status='pending'""",
        (int(message_id), int(time.time()), str(task_id), int(user_id)),
    )
    conn.commit()
    conn.close()
    return cur.rowcount == 1


def _set_legacy_ui_sync(task_id, user_id, enabled=True):
    conn = _connect()
    try:
        cur = conn.execute(
            """UPDATE reminders SET legacy_ui=?, updated_at=?
               WHERE id=? AND user_id=?""",
            (
                1 if enabled else 0,
                int(time.time()),
                str(task_id),
                int(user_id),
            ),
        )
        conn.commit()
        return cur.rowcount == 1
    finally:
        conn.close()


def _update_draft_sync(task_id, user_id, *, title=None, instruction=None, run_at=None,
                       recurrence=None, weekdays=None, schedule=None, execution_mode=None):
    now = int(time.time())
    current = _get_sync(task_id)
    timezone_name = (
        str(current.get("timezone_name") or DEFAULT_TIMEZONE)
        if current else DEFAULT_TIMEZONE
    )
    zone = timezone_obj(timezone_name)
    changes, values = [], []
    if execution_mode is not None:
        changes.append("execution_mode=?")
        values.append(normalize_execution_mode(execution_mode))
    if title is not None:
        clean = str(title).strip()[:120]
        if not clean:
            raise ValueError("Название не может быть пустым.")
        changes.append("title=?")
        values.append(clean)
    if instruction is not None:
        clean = str(instruction).strip()[:3000]
        if not clean:
            raise ValueError("Инструкция не может быть пустой.")
        changes.append("instruction=?")
        values.append(clean)
    if schedule is not None:
        normalized = schedule_v2.normalize_schedule(
            schedule, timezone_name=timezone_name
        )
        run_at = schedule_v2.next_trigger(
            normalized,
            after=now + MIN_LEAD_SECONDS-1,
            timezone_name=timezone_name,
        )
        if run_at is None:
            raise ValueError("В расписании нет будущих дат.")
        changes.extend(["schedule_json=?","occurrences_done=?",
                        "recurrence=?","weekdays=?"])
        values.extend([json.dumps(normalized,ensure_ascii=False,sort_keys=True),
                       0,"advanced",""])
    elif run_at is not None or recurrence is not None or weekdays is not None:
        # A new single date must not leave recurrence='advanced' behind:
        # otherwise next_occurrence would accidentally interpret it as monthly.
        changes.append("schedule_json=?")
        values.append("")
        if run_at is not None and recurrence is None and weekdays is None:
            changes.extend(["recurrence=?","weekdays=?"])
            values.extend(["once",""])
    if run_at is not None:
        run_at = int(run_at)
        if run_at < now + MIN_LEAD_SECONDS:
            raise ValueError("Выбери время минимум на 30 секунд в будущем.")
        if run_at > now + (3660*86400 if schedule is not None else MAX_LEAD_SECONDS):
            raise ValueError("Дата выходит за допустимый диапазон.")
        changes.extend(["run_at=?", "retry_at=NULL", "recurrence_day=?"])
        values.extend([run_at, datetime.fromtimestamp(run_at, zone).day])
    if recurrence is not None and schedule is None:
        recurrence, normalized_days = normalize_recurrence(recurrence, weekdays)
        changes.extend(["recurrence=?", "weekdays=?"])
        values.extend([recurrence, normalized_days])
    elif weekdays is not None and schedule is None:
        recurrence, normalized_days = normalize_recurrence("custom", weekdays)
        changes.extend(["recurrence=?", "weekdays=?"])
        values.extend([recurrence, normalized_days])
    if not changes:
        return _get_sync(task_id)
    changes.append("updated_at=?")
    values.append(now)
    values.extend([str(task_id), int(user_id)])
    conn = _connect()
    try:
        cur = conn.execute(
            f"UPDATE reminders SET {', '.join(changes)} "
            "WHERE id=? AND user_id=? AND status='pending'",
            values,
        )
        conn.commit()
        row = conn.execute("SELECT * FROM reminders WHERE id=?", (str(task_id),)).fetchone()
        return _to_dict(row) if cur.rowcount == 1 else None
    finally:
        conn.close()


def _confirm_sync(task_id, user_id):
    now = int(time.time())
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        if not row or row["status"] != "pending":
            conn.commit()
            return {"ok": False, "reason": "not_pending", "task": _to_dict(row)}
        if row["expires_at"] <= now:
            if row["replaces_id"]:
                conn.execute(
                    """UPDATE reminders SET status='scheduled', updated_at=?
                       WHERE id=? AND user_id=? AND status='editing'""",
                    (now, row["replaces_id"], int(user_id)),
                )
            conn.execute(
                "UPDATE reminders SET status='expired', updated_at=? WHERE id=? AND status='pending'",
                (now, str(task_id)),
            )
            conn.commit()
            return {"ok": False, "reason": "expired", "task": _to_dict(row)}
        if row["run_at"] < now + MIN_LEAD_SECONDS:
            conn.commit()
            return {"ok": False, "reason": "time_passed", "task": _to_dict(row)}
        if row["replaces_id"]:
            original = conn.execute(
                "SELECT id FROM reminders WHERE id=? AND user_id=? AND status='editing'",
                (row["replaces_id"], int(user_id)),
            ).fetchone()
            if not original:
                conn.commit()
                return {"ok": False, "reason": "replacement_missing", "task": _to_dict(row)}
            conn.execute(
                """UPDATE reminders SET status='cancelled', updated_at=?
                   WHERE id=? AND user_id=? AND status='editing'""",
                (now, row["replaces_id"], int(user_id)),
            )
        conn.execute(
            """UPDATE reminders SET status='scheduled', retry_at=NULL, updated_at=?
               WHERE id=? AND status='pending'""",
            (now, str(task_id)),
        )
        updated = conn.execute("SELECT * FROM reminders WHERE id=?", (str(task_id),)).fetchone()
        conn.commit()
        return {"ok": True, "reason": "confirmed", "task": _to_dict(updated)}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _cancel_sync(task_id, user_id):
    now = int(time.time())
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        if not row or row["status"] not in ("pending", "scheduled"):
            conn.commit()
            return False, _to_dict(row)
        cur = conn.execute(
            """UPDATE reminders SET status='cancelled', updated_at=?
               WHERE id=? AND user_id=? AND status IN ('pending','scheduled')""",
            (now, str(task_id), int(user_id)),
        )
        if cur.rowcount == 1 and row["replaces_id"]:
            conn.execute(
                """UPDATE reminders SET status='scheduled', updated_at=?
                   WHERE id=? AND user_id=? AND status='editing'""",
                (now, row["replaces_id"], int(user_id)),
            )
        updated = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        conn.commit()
        return cur.rowcount == 1, _to_dict(updated)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _list_active_sync(user_id, limit=50):
    conn = _connect()
    rows = conn.execute(
        """SELECT * FROM reminders WHERE user_id=? AND status IN ('pending','scheduled')
           ORDER BY COALESCE(retry_at, run_at) ASC LIMIT ?""",
        (int(user_id), max(1, min(int(limit), 50))),
    ).fetchall()
    conn.close()
    return [_to_dict(row) for row in rows]


def _get_owned_sync(task_id: str, user_id: int):
    """Read one task only from this authenticated user's collection."""
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        return _to_dict(row)
    finally:
        conn.close()


def _list_owned_sync(user_id: int, limit: int=50,
                     *, include_finished: bool=False):
    """User-wide task discovery; no dependence on origin chat_id."""
    conn = _connect()
    try:
        limit=max(1,min(100,int(limit)))
        if include_finished:
            rows=conn.execute(
                """SELECT * FROM reminders WHERE user_id=?
                   ORDER BY updated_at DESC LIMIT ?""",
                (int(user_id),limit),
            ).fetchall()
        else:
            rows=conn.execute(
                """SELECT * FROM reminders
                   WHERE user_id=? AND status IN ('pending','scheduled','running','editing')
                   ORDER BY COALESCE(retry_at, run_at) ASC LIMIT ?""",
                (int(user_id),limit),
            ).fetchall()
        return [_to_dict(row) for row in rows]
    finally:
        conn.close()


def _change_existing_sync(user_id: int, task_id: str, *,
                          expected_updated_at: int,
                          execution_mode: str | None = None,
                          instruction: str | None = None):
    """Owner-scoped atomic edit of existing confirmed task's mode/text ONLY.

    No new card, no timing changes, no side effects on other tasks. Caller
    must have retrieved exact config/version first; stale reads are denied.
    """
    if execution_mode is None and instruction is None:
        return {"ok":False,"reason":"no_changes","task":None}
    if expected_updated_at is None or isinstance(expected_updated_at,bool):
        return {"ok":False,"reason":"version_required","task":None}
    try:
        version=int(expected_updated_at)
    except (TypeError,ValueError):
        return {"ok":False,"reason":"version_required","task":None}
    requested_mode=(normalize_execution_mode(execution_mode)
                    if execution_mode is not None else None)
    new_text=None
    if instruction is not None:
        new_text=str(instruction).strip()
        if not new_text or len(new_text)>3000:
            return {"ok":False,"reason":"invalid_text","task":None}
    now=int(time.time())
    conn=_connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row=conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id),int(user_id))
        ).fetchone()
        if not row:
            conn.commit()
            return {"ok":False,"reason":"missing","task":None}
        if row["status"]!="scheduled":
            conn.commit()
            return {"ok":False,"reason":"not_scheduled","task":_to_dict(row)}
        if int(row["updated_at"])!=version:
            conn.commit()
            return {"ok":False,"reason":"stale","task":_to_dict(row)}
        mode=requested_mode or row["execution_mode"]
        text=new_text if new_text is not None else row["instruction"]
        # The old AI instruction is NOT a valid literal reminder text.
        if mode=="text" and row["execution_mode"]!="text" and new_text is None:
            conn.commit()
            return {"ok":False,"reason":"text_required","task":_to_dict(row)}
        if mode==row["execution_mode"] and text==row["instruction"]:
            conn.commit()
            return {"ok":True,"reason":"unchanged","task":_to_dict(row)}
        updated_time=max(now,version+1)
        cur=conn.execute(
            """UPDATE reminders SET execution_mode=?, instruction=?, updated_at=?
               WHERE id=? AND user_id=? AND status='scheduled' AND updated_at=?""",
            (mode,text,updated_time,str(task_id),int(user_id),version)
        )
        if cur.rowcount!=1:
            conn.rollback()
            return {"ok":False,"reason":"stale","task":None}
        updated=conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id),int(user_id))
        ).fetchone()
        conn.commit()
        return {"ok":True,"reason":"updated","task":_to_dict(updated)}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _skip_next_sync(user_id: int, task_id: str | None = None,
                    *, expected_run_at: int | None = None):
    """Atomically consume exactly one next firing without executing its action.

    A task must be confirmed and still 'scheduled'. An already running event
    cannot be retracted. Missing / чужой task is never exposed.
    """
    now=int(time.time())
    conn=_connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        if task_id:
            row=conn.execute(
                """SELECT * FROM reminders
                   WHERE id=? AND user_id=?""",
                (str(task_id),int(user_id)),
            ).fetchone()
        else:
            row=conn.execute(
                """SELECT * FROM reminders WHERE user_id=? AND status='scheduled'
                   ORDER BY COALESCE(retry_at,run_at) ASC LIMIT 1""",
                (int(user_id),),
            ).fetchone()
        if row is None:
            conn.commit()
            return {"ok": False, "reason": "missing", "task": None}
        if row["status"] != "scheduled":
            conn.commit()
            return {"ok": False, "reason": "not_scheduled",
                    "task": _to_dict(row)}
        if (expected_run_at is not None
                and int(row["run_at"]) != int(expected_run_at)):
            conn.commit()
            return {"ok": False, "reason": "stale", "task": _to_dict(row)}
        old_time=int(row["run_at"])
        consumed=int(row["occurrences_done"] or 0)+1
        if row["schedule_json"]:
            next_at=schedule_v2.next_trigger(
                json.loads(row["schedule_json"]),
                after=max(now,old_time), completed=consumed,
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        else:
            next_at=next_occurrence(
                old_time,row["recurrence"],row["weekdays"],
                after_timestamp=max(now,old_time),
                recurrence_day=row["recurrence_day"],
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        if next_at is None:
            conn.execute(
                """UPDATE reminders SET status='completed',retry_at=NULL,
                   occurrences_done=?, occurrences_skipped=occurrences_skipped+1,
                   attempts=0,last_error=NULL,updated_at=?
                   WHERE id=? AND user_id=? AND status='scheduled'""",
                (consumed,now,row["id"],int(user_id)),
            )
        else:
            conn.execute(
                """UPDATE reminders SET run_at=?,retry_at=NULL,
                   occurrences_done=?, occurrences_skipped=occurrences_skipped+1,
                   attempts=0,last_error=NULL,updated_at=?
                   WHERE id=? AND user_id=? AND status='scheduled'""",
                (next_at,consumed,now,row["id"],int(user_id)),
            )
        updated=conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (row["id"],int(user_id)),
        ).fetchone()
        conn.commit()
        return {
            "ok": True, "reason": "skipped",
            "skipped_at":old_time, "task":_to_dict(updated),
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _pause_until_sync(user_id, task_id, resume_from_ts, *, expected_updated_at=None):
    """Skip every scheduled occurrence strictly before resume_from_ts.

    This is a temporary pause, not a cancellation. The same reminder ID,
    text/mode and recurrence are preserved. Skipped firings count as consumed
    occurrences so finite schedules remain internally consistent.
    """
    now = int(time.time())
    resume_from_ts = int(resume_from_ts)
    if resume_from_ts <= now:
        return {"ok": False, "reason": "past", "task": None, "skipped": 0}

    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        if row is None:
            conn.commit()
            return {"ok": False, "reason": "missing", "task": None, "skipped": 0}
        if row["status"] != "scheduled":
            conn.commit()
            return {
                "ok": False, "reason": "not_scheduled",
                "task": _to_dict(row), "skipped": 0,
            }
        if expected_updated_at is not None:
            try:
                expected = int(expected_updated_at)
            except (TypeError, ValueError):
                conn.commit()
                return {
                    "ok": False, "reason": "version_required",
                    "task": _to_dict(row), "skipped": 0,
                }
            if int(row["updated_at"] or 0) != expected:
                conn.commit()
                return {
                    "ok": False, "reason": "stale",
                    "task": _to_dict(row), "skipped": 0,
                }

        current = int(row["run_at"])
        consumed = int(row["occurrences_done"] or 0)
        skipped = 0
        timezone_name = row["timezone_name"] or DEFAULT_TIMEZONE
        schedule = json.loads(row["schedule_json"]) if row["schedule_json"] else None

        # Skip all occurrences that would fire during the pause window.
        while current < resume_from_ts:
            consumed += 1
            skipped += 1
            if schedule is not None:
                next_at = schedule_v2.next_trigger(
                    schedule,
                    after=max(current, now),
                    completed=consumed,
                    timezone_name=timezone_name,
                )
            else:
                next_at = next_occurrence(
                    current,
                    row["recurrence"],
                    row["weekdays"],
                    after_timestamp=max(current, now),
                    recurrence_day=row["recurrence_day"],
                    timezone_name=timezone_name,
                )
            if next_at is None:
                current = None
                break
            next_at = int(next_at)
            if next_at <= int(row["run_at"]) and skipped > 10000:
                raise RuntimeError("Некорректное расписание: пауза не может быть вычислена")
            current = next_at
            if skipped > 10000:
                raise RuntimeError("Слишком много срабатываний в интервале паузы")

        if current is None:
            conn.execute(
                """UPDATE reminders SET status='completed', retry_at=NULL,
                   occurrences_done=?, occurrences_skipped=occurrences_skipped+?,
                   attempts=0, last_error=NULL, updated_at=?
                   WHERE id=? AND user_id=? AND status='scheduled'""",
                (consumed, skipped, now, str(task_id), int(user_id)),
            )
        else:
            conn.execute(
                """UPDATE reminders SET run_at=?, retry_at=NULL,
                   occurrences_done=?, occurrences_skipped=occurrences_skipped+?,
                   attempts=0, last_error=NULL, updated_at=?
                   WHERE id=? AND user_id=? AND status='scheduled'""",
                (current, consumed, skipped, now, str(task_id), int(user_id)),
            )

        updated = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id), int(user_id)),
        ).fetchone()
        conn.commit()
        return {
            "ok": True,
            "reason": "paused",
            "resume_from": resume_from_ts,
            "skipped": skipped,
            "task": _to_dict(updated),
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _due_sync(now, limit=20):
    conn = _connect()
    rows = conn.execute(
        """SELECT id,user_id,run_at,execution_mode FROM reminders
           WHERE status='scheduled' AND COALESCE(retry_at, run_at)<=?
           ORDER BY COALESCE(retry_at, run_at) ASC LIMIT ?""",
        (int(now), max(1, min(int(limit), 50))),
    ).fetchall()
    conn.close()
    return [_to_dict(row) for row in rows]


def _next_due_sync():
    """Return only the next timer target, never the full reminder payload."""
    conn = _connect()
    row = conn.execute(
        """SELECT id, COALESCE(retry_at, run_at) AS due_at
           FROM reminders
           WHERE status='scheduled'
           ORDER BY COALESCE(retry_at, run_at) ASC
           LIMIT 1"""
    ).fetchone()
    conn.close()
    if not row:
        return None
    return {"task_id": str(row["id"]), "due_at": int(row["due_at"])}


def _claim_sync(task_id, now):
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        cur = conn.execute(
            """UPDATE reminders SET status='running', updated_at=?
               WHERE id=? AND status='scheduled' AND COALESCE(retry_at, run_at)<=?""",
            (int(now), str(task_id), int(now)),
        )
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND status='running'",
            (str(task_id),),
        ).fetchone() if cur.rowcount == 1 else None
        conn.commit()
        return _to_dict(row)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _complete_sync(task_id):
    now = int(time.time())
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM reminders WHERE id=? AND status='running'",
            (str(task_id),),
        ).fetchone()
        if not row:
            conn.commit()
            return {"ok": False, "task": None}
        completed = int(row["occurrences_done"] or 0) + 1
        if row["schedule_json"]:
            next_at = schedule_v2.next_trigger(
                json.loads(row["schedule_json"]),
                after=max(int(row["run_at"]), now),
                completed=completed,
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        else:
            next_at = next_occurrence(
                row["run_at"], row["recurrence"], row["weekdays"],
                after_timestamp=now,
                recurrence_day=row["recurrence_day"],
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        if next_at is None:
            conn.execute(
                """UPDATE reminders SET status='completed', retry_at=NULL,
                   occurrences_done=?, updated_at=?, last_error=NULL
                   WHERE id=? AND status='running'""",
                (completed,now,str(task_id)),
            )
        else:
            conn.execute(
                """UPDATE reminders SET status='scheduled', run_at=?, retry_at=NULL,
                   attempts=0, occurrences_done=?, updated_at=?, last_error=NULL
                   WHERE id=? AND status='running'""",
                (next_at,completed,now,str(task_id)),
            )
        updated = conn.execute(
            "SELECT * FROM reminders WHERE id=?",
            (str(task_id),),
        ).fetchone()
        conn.commit()
        return {"ok": True, "task": _to_dict(updated)}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _skip_running_sync(task_id, user_id):
    """Stop a running AI reminder without a retry; skip only this firing.

    This is triggered exclusively by the owner pressing Stop. Future firings
    are retained, and one-time tasks become completed (not failed).
    """
    now=int(time.time())
    conn=_connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row=conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=? AND status='running'",
            (str(task_id),int(user_id)),
        ).fetchone()
        if not row:
            conn.commit()
            return {"ok":False,"task":None}
        consumed=int(row["occurrences_done"] or 0)+1
        if row["schedule_json"]:
            next_at=schedule_v2.next_trigger(
                json.loads(row["schedule_json"]),
                after=max(int(row["run_at"]),now),
                completed=consumed,
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        else:
            next_at=next_occurrence(
                row["run_at"],row["recurrence"],row["weekdays"],
                after_timestamp=max(int(row["run_at"]),now),
                recurrence_day=row["recurrence_day"],
                timezone_name=row["timezone_name"] or DEFAULT_TIMEZONE,
            )
        if next_at is None:
            conn.execute(
                """UPDATE reminders SET status='completed',retry_at=NULL,
                   attempts=0,last_error=NULL,occurrences_done=?,
                   occurrences_skipped=occurrences_skipped+1,updated_at=?
                   WHERE id=? AND user_id=? AND status='running'""",
                (consumed,now,str(task_id),int(user_id)),
            )
        else:
            conn.execute(
                """UPDATE reminders SET status='scheduled',run_at=?,retry_at=NULL,
                   attempts=0,last_error=NULL,occurrences_done=?,
                   occurrences_skipped=occurrences_skipped+1,updated_at=?
                   WHERE id=? AND user_id=? AND status='running'""",
                (int(next_at),consumed,now,str(task_id),int(user_id)),
            )
        updated=conn.execute(
            "SELECT * FROM reminders WHERE id=? AND user_id=?",
            (str(task_id),int(user_id)),
        ).fetchone()
        conn.commit()
        return {"ok":True,"task":_to_dict(updated)}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _retry_sync(task_id, error):
    now = int(time.time())
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT attempts FROM reminders WHERE id=? AND status='running'",
            (str(task_id),),
        ).fetchone()
        if not row:
            conn.commit()
            return "missing"
        attempts = int(row["attempts"] or 0) + 1
        status = "scheduled" if attempts < 3 else "failed"
        retry_at = now + min(900, 300 * attempts) if status == "scheduled" else None
        conn.execute(
            """UPDATE reminders SET status=?,attempts=?,retry_at=?,updated_at=?,last_error=?
               WHERE id=? AND status='running'""",
            (status, attempts, retry_at, now, str(error)[:500], str(task_id)),
        )
        conn.commit()
        return status
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _expire_sync(now):
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        now = int(now)
        conn.execute(
            """UPDATE reminders SET status='scheduled', updated_at=?
               WHERE status='editing' AND id IN (
                   SELECT replaces_id FROM reminders
                   WHERE status='pending' AND expires_at<=? AND replaces_id IS NOT NULL
               )""",
            (now, now),
        )
        cur = conn.execute(
            """UPDATE reminders SET status='expired', updated_at=?
               WHERE status='pending' AND expires_at<=?""",
            (now, now),
        )
        conn.commit()
        return cur.rowcount
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _recover_running_sync(now):
    conn = _connect()
    cur = conn.execute(
        """UPDATE reminders SET status='scheduled', retry_at=?, updated_at=?,
           attempts=attempts+1, last_error='Бот перезапустился во время выполнения'
           WHERE status='running'""",
        (int(now) + 120, int(now)),
    )
    conn.commit()
    count = cur.rowcount
    conn.close()
    return count


async def create_draft(*args, **kwargs):
    return await asyncio.to_thread(_create_draft_sync, *args, **kwargs)


async def create_edit_draft(task_id, user_id, max_active=10):
    return await asyncio.to_thread(_create_edit_draft_sync, task_id, user_id, max_active)


async def get_task(task_id):
    return await asyncio.to_thread(_get_sync, task_id)


async def get_owned(task_id, user_id):
    return await asyncio.to_thread(_get_owned_sync, task_id, user_id)


async def list_owned(user_id, limit=50, include_finished=False):
    return await asyncio.to_thread(
        _list_owned_sync, user_id, limit, include_finished=include_finished
    )


async def change_existing(user_id, task_id, *, expected_updated_at,
                          execution_mode=None, instruction=None):
    return await asyncio.to_thread(
        _change_existing_sync,user_id,task_id,
        expected_updated_at=expected_updated_at,
        execution_mode=execution_mode,instruction=instruction,
    )


async def skip_next(user_id, task_id=None, *, expected_run_at=None):
    return await asyncio.to_thread(
        _skip_next_sync, user_id, task_id, expected_run_at=expected_run_at
    )


async def pause_until(user_id, task_id, resume_from_ts, *, expected_updated_at=None):
    return await asyncio.to_thread(
        _pause_until_sync,
        user_id,
        task_id,
        resume_from_ts,
        expected_updated_at=expected_updated_at,
    )


async def set_config_message(task_id, user_id, message_id):
    return await asyncio.to_thread(_set_config_message_sync, task_id, user_id, message_id)


async def set_legacy_ui(task_id, user_id, enabled=True):
    return await asyncio.to_thread(
        _set_legacy_ui_sync, task_id, user_id, enabled
    )


async def update_draft(task_id, user_id, **kwargs):
    return await asyncio.to_thread(_update_draft_sync, task_id, user_id, **kwargs)


async def confirm(task_id, user_id):
    return await asyncio.to_thread(_confirm_sync, task_id, user_id)


async def cancel(task_id, user_id):
    return await asyncio.to_thread(_cancel_sync, task_id, user_id)


async def list_active(user_id, limit=50):
    return await asyncio.to_thread(_list_active_sync, user_id, limit)


async def due(now=None, limit=20):
    return await asyncio.to_thread(_due_sync, int(now or time.time()), limit)


async def next_due():
    return await asyncio.to_thread(_next_due_sync)


async def claim(task_id, now=None):
    return await asyncio.to_thread(_claim_sync, task_id, int(now or time.time()))


async def complete(task_id):
    return await asyncio.to_thread(_complete_sync, task_id)


async def skip_running(task_id,user_id):
    return await asyncio.to_thread(_skip_running_sync,task_id,user_id)


async def retry(task_id, error):
    return await asyncio.to_thread(_retry_sync, task_id, error)


async def expire_pending(now=None):
    return await asyncio.to_thread(_expire_sync, int(now or time.time()))


async def recover_running(now=None):
    return await asyncio.to_thread(_recover_running_sync, int(now or time.time()))
