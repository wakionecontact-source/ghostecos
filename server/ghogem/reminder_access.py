"""User-wide reminder inspection and single-occurrence skipping for GhoGemo agents.

All database access is owner-scoped using server-authenticated uid. The model
never supplies another uid or an origin chat ID for authorization.
"""
from __future__ import annotations

from datetime import datetime, timedelta
import json
import re
from zoneinfo import ZoneInfo
import reminders

MSK=ZoneInfo("Europe/Moscow")
ACTIVE={"pending","scheduled","running","editing"}
def serialize(task: dict, *, full: bool=True) -> dict:
    timezone_name = str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
    zone = reminders.timezone_obj(timezone_name)
    payload={
        "task_id":task["id"],
        "title":task["title"],
        "status":task["status"],
        "execution_mode":task.get("execution_mode") or "ai",
        "timezone_name":timezone_name,
        "next_at_local":datetime.fromtimestamp(int(task["run_at"]),zone).isoformat(timespec="minutes"),
        "next_at_moscow":datetime.fromtimestamp(int(task["run_at"]),MSK).isoformat(timespec="minutes"),
        "recurrence":task.get("recurrence") or "once",
        "weekdays":task.get("weekdays") or "",
        "occurrences_done":int(task.get("occurrences_done") or 0),
        "occurrences_skipped":int(task.get("occurrences_skipped") or 0),
        "config_version":int(task.get("updated_at") or 0),
        "text_or_prompt":str(task.get("instruction") or "") if full else str(task.get("instruction") or "")[:170],
    }
    if task.get("schedule_json"):
        try:
            payload["schedule"]=json.loads(task["schedule_json"])
        except (TypeError,ValueError):
            payload["schedule"]={"error":"Некорректное сохранённое расписание"}
    else:
        payload["schedule"]={"mode":payload["recurrence"],
                             "weekdays":payload["weekdays"],
                             "time_local":datetime.fromtimestamp(int(task["run_at"]),zone).strftime("%H:%M"),
                             "time_moscow":datetime.fromtimestamp(int(task["run_at"]),MSK).strftime("%H:%M")}
    return payload


def run(tool: str, uid: int, args: dict) -> str:
    """Tools are only called AFTER server-side instruction-unlock checks."""
    uid=int(uid)
    if tool=="list_reminders":
        limit=max(1,min(int(args.get("limit") or 20),50))
        include_finished=bool(args.get("include_finished",False))
        items=reminders._list_owned_sync(uid,limit,include_finished=include_finished)
        if not include_finished:
            items=[x for x in items if x["status"] in ACTIVE]
        return json.dumps({"reminders":[serialize(x,full=False) for x in items],
                           "count":len(items)},ensure_ascii=False)
    if tool=="get_reminder":
        task_id=str(args.get("task_id") or "").strip()
        if not task_id:
            return "❌ Укажи task_id из list_reminders."
        task=reminders._get_owned_sync(task_id,uid)
        return (json.dumps(serialize(task),ensure_ascii=False)
                if task else "❌ Задание не найдено в твоём списке.")
    if tool=="update_reminder":
        task_id=str(args.get("task_id") or "").strip()
        if not task_id:
            return "❌ Сначала узнай task_id через list_reminders, затем get_reminder."
        # The model cannot choose an arbitrary owner, only request a change to
        # a task belonging to the authenticated server-side current user.
        result=reminders._change_existing_sync(
            uid,task_id,
            expected_updated_at=args.get("config_version"),
            execution_mode=args.get("execution_mode"),
            instruction=args.get("instruction"),
        )
        if not result["ok"]:
            errors={
                "missing":"Задание не найдено в твоём аккаунте.",
                "not_scheduled":"Изменять можно только подтверждённое ожидающее задание.",
                "stale":"Карточка изменилась после просмотра. Вызови get_reminder снова.",
                "version_required":"Сначала получи config_version через get_reminder.",
                "text_required":"Для перехода с ИИ на текст укажи готовое сообщение instruction.",
                "invalid_text":"Нужно непустое сообщение длиной до 3000 символов.",
                "no_changes":"Укажи instruction или execution_mode.",
            }
            return "❌ "+errors.get(result["reason"],"Не удалось изменить.")
        payload={
            "result":"Настройки существующей карточки изменены."
                     if result["reason"]=="updated" else "Настройки уже совпадают.",
            "reminder":serialize(result["task"]),
            "note":"Расписание, даты, часы и идентификатор остались прежними. "
                   "Новая карточка НЕ создана.",
        }
        return json.dumps(payload,ensure_ascii=False)
    if tool=="pause_reminder":
        task_id=str(args.get("task_id") or "").strip()
        if not task_id:
            return "❌ Укажи task_id из list_reminders/get_reminder."
        task=reminders._get_owned_sync(task_id,uid)
        if not task:
            return "❌ Задание не найдено в твоём списке."
        expected=args.get("config_version")
        try:
            expected=int(expected)
        except (TypeError,ValueError):
            return "❌ Сначала вызови get_reminder и передай точный config_version."
        if int(task.get("updated_at") or 0)!=expected:
            return "❌ Карточка изменилась после просмотра. Вызови get_reminder снова."
        resume_raw=str(args.get("resume_from") or "").strip()
        if not resume_raw:
            return "❌ Укажи resume_from: дату YYYY-MM-DD или локальный ISO datetime."
        zone=reminders.timezone_obj(
            str(task.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
        )
        try:
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}",resume_raw):
                resume_dt=datetime.fromisoformat(resume_raw).replace(tzinfo=zone)
            else:
                resume_dt=datetime.fromisoformat(resume_raw)
                if resume_dt.tzinfo is None:
                    resume_dt=resume_dt.replace(tzinfo=zone)
                else:
                    resume_dt=resume_dt.astimezone(zone)
            resume_ts=int(resume_dt.timestamp())
        except (TypeError,ValueError):
            return "❌ resume_from должен быть YYYY-MM-DD или корректным ISO datetime."
        outcome=reminders._pause_until_sync(
            uid,task_id,resume_ts,expected_updated_at=expected
        )
        if not outcome["ok"]:
            errors={
                "missing":"Задание не найдено в твоём аккаунте.",
                "not_scheduled":"Поставить на паузу можно только активное ожидающее напоминание.",
                "stale":"Карточка изменилась после просмотра. Вызови get_reminder снова.",
                "version_required":"Сначала получи config_version через get_reminder.",
                "past":"Дата возобновления уже прошла.",
            }
            return "❌ "+errors.get(outcome["reason"],"Не удалось поставить напоминание на паузу.")
        updated=outcome["task"]
        return json.dumps({
            "result":"Напоминание временно приостановлено",
            "resume_from_local":resume_dt.isoformat(timespec="minutes"),
            "skipped_occurrences":int(outcome.get("skipped") or 0),
            "reminder":serialize(updated),
            "note":"После указанной даты сохранённое расписание продолжится автоматически. Карточка не отменена.",
        },ensure_ascii=False)

    if tool=="disable_reminder":
        task_id=str(args.get("task_id") or "").strip()
        if not task_id:
            return "❌ Укажи task_id из list_reminders/get_reminder."
        task=reminders._get_owned_sync(task_id,uid)
        if not task:
            return "❌ Задание не найдено в твоём списке."
        expected=args.get("config_version")
        try:
            expected=int(expected)
        except (TypeError,ValueError):
            return "❌ Сначала вызови get_reminder и передай точный config_version."
        if int(task.get("updated_at") or 0)!=expected:
            return "❌ Карточка изменилась после просмотра. Вызови get_reminder снова."
        ok, updated=reminders._cancel_sync(task_id,uid)
        if not ok:
            return "❌ Это напоминание уже не активно или не может быть отключено."
        return json.dumps({
            "result":"Напоминание полностью отключено по запросу пользователя",
            "reminder":serialize(updated),
            "note":"Будущих срабатываний не будет.",
        },ensure_ascii=False)
    if tool=="skip_next_reminder":
        task_id=str(args.get("task_id") or "").strip() or None
        outcome=reminders._skip_next_sync(uid,task_id)
        if not outcome["ok"]:
            if outcome["reason"]=="not_scheduled":
                return "❌ Это задание не ожидает отправки (возможно, уже выполняется или не подтверждено)."
            return "❌ Нет доступного подтверждённого задания этого пользователя."
        timezone_name = str(
            outcome["task"].get("timezone_name") or reminders.DEFAULT_TIMEZONE
        )
        zone = reminders.timezone_obj(timezone_name)
        data={
            "result":"Одно ближайшее срабатывание пропущено по запросу пользователя",
            "timezone_name":timezone_name,
            "skipped_at_local":datetime.fromtimestamp(
                outcome["skipped_at"], zone
            ).isoformat(timespec="minutes"),
            "skipped_at_moscow":datetime.fromtimestamp(outcome["skipped_at"],MSK).isoformat(timespec="minutes"),
            "reminder":serialize(outcome["task"]),
            "note":"Последующие срабатывания сохранены" if outcome["task"]["status"]=="scheduled"
                   else "Это было последнее срабатывание — задание завершено",
        }
        return json.dumps(data,ensure_ascii=False)
    raise ValueError("Неизвестный инструмент напоминаний")



def user_explicitly_requests_new_reminder(message: str) -> bool:
    """Conservative action authorization for the create_reminder tool.

    A model that hallucinates instructions from older chats/tool descriptions
    must not be able to create reminders on read/edit/error-recovery turns.
    For ambiguous requests, we prefer asking the user to rephrase.
    """
    text=" ".join(str(message or "").casefold().split())
    if not text:
        return False
    # A fresh, explicit creation command overrides contextual discussion;
    # otherwise edit/read turns cannot silently create new tasks.
    explicit=re.search(
        r"(?:создай|создать|сделай|сделать|поставь|поставить|"
        r"установи|установить|добавь|добавить|запланируй|запланировать)"
        r"(?:.{0,55})(?:напоминан|напоминалк|задан|напом)",
        text,
    )
    remind=re.search(
        r"\b(?:напомни|напоминай|напомнить|напоминать|remind me)\b",
        text,
    )
    if re.search(r"(?:не|нет)\s+(?:создавай|создавать|поставь|ставь|напоминай)",text):
        return False
    # Editing commands can mention "создай" as a tool name: avoid it.
    if re.search(r"(?:обоим|обоих|их оба|существующ|уже создан|"
                 r"поменяй|измени|изменить|исправь|переведи|"
                 r"поставь.{0,24}режим|отредактируй)",text):
        if not re.search(r"(?:создай|добавь|сделай).{0,25}"
                         r"(?:ново[еую]|ещ[её])",text):
            return False
    return bool(explicit or remind)



def user_explicitly_requests_reminder_edit(message: str) -> bool:
    """Restrict model-triggered mutation to actual user edit requests."""
    text=" ".join(str(message or "").casefold().split())
    if not text or re.search(r"(?:не|нет)\s+(?:меняй|изменяй|редактируй)",text):
        return False
    # Do not allow file/theme editing requests to alter reminders.
    if not re.search(
        r"(?:напомин|задан|обоим|обоих|режим[аы]?\s+текст|"
        r"режим\s+промпт|существующ.{0,25}карточ)",
        text
    ):
        return False
    return bool(re.search(
        r"(?:измени|изменить|поменяй|поменять|исправь|исправить|"
        r"отредактируй|отредактировать|переведи|переключи|"
        r"поставь.{0,40}режим|замени.{0,35}текст|"
        r"(?:обоим|обоих).{0,40}(?:текст|режим)|"
        r"(?:режим|текст).{0,32}(?:напоминалк|напоминан))",
        text,
    ))



def user_explicitly_requests_reminder_pause(message: str) -> bool:
    """True for an explicit *temporary* suspension of an existing reminder."""
    text=" ".join(str(message or "").casefold().split())
    if not text:
        return False
    reminder_ref=bool(re.search(r"напомин|напом|задан",text))
    action=bool(re.search(
        r"(?:отключ|выключ|выруб|приостанов|постав.{0,12}пауз|"
        r"не\s+напоминай|не\s+присылай|пропуст)",
        text,
    ))
    temporary=bool(re.search(
        r"(?:\bвременно\b|\bна\s+время\b|"
        r"на\s+(?:эти\s+)?выходн|"
        r"(?:эту|следующ|последующ)\w*\s+недел|"
        r"на\s+\d+\s*(?:дн|день|дня|дней|недел)|"
        r"до\s+(?:конца\s+)?(?:недел|выходн|каникул|отпуск)|"
        r"до\s+\d{1,2}[./-]\d{1,2}(?:[./-]\d{2,4})?|"
        r"пока\s+(?:каникул|отпуск|не\s+законч))",
        text,
    ))
    return reminder_ref and action and temporary


def user_explicitly_requests_reminder_disable(message: str) -> bool:
    """True only for an explicit request to turn a reminder off completely."""
    text=" ".join(str(message or "").casefold().split())
    if not text:
        return False
    # A time-bounded request always wins over verbs like «отключи».
    if user_explicitly_requests_reminder_pause(text):
        return False
    if re.search(r"(?:не|нет)\s+(?:отключай|выключай|вырубай|отменяй|убирай)",text):
        return False
    reminder_ref=bool(re.search(r"напомин|напом|задан",text))
    disable=bool(re.search(
        r"(?:отключ|выключ|выруб|отмен|удал|убер|убрат|"
        r"больше\s+не\s+напомин|перестан\w*\s+напомин)",text
    ))
    return reminder_ref and disable


def _pause_resume_timestamp(message: str, timezone_name: str) -> int | None:
    """Parse only high-confidence temporary ranges for deterministic handling."""
    text=" ".join(str(message or "").casefold().split())
    try:
        zone=ZoneInfo(str(timezone_name or reminders.DEFAULT_TIMEZONE))
    except Exception:
        zone=ZoneInfo(reminders.DEFAULT_TIMEZONE)
    now=datetime.now(zone)
    today=now.date()
    monday=today-timedelta(days=today.weekday())

    # «эти выходные и всю следующую/последующую неделю» or simply
    # «следующую неделю» => resume on the Monday after that week.
    if re.search(r"(?:следующ|последующ)\w*\s+недел",text):
        resume_date=monday+timedelta(days=14)
        return int(datetime.combine(resume_date,datetime.min.time(),tzinfo=zone).timestamp())

    # «эти выходные» / «эту неделю» => resume next Monday.
    if re.search(r"(?:эти\s+выходн|эту\w*\s+недел)",text):
        resume_date=monday+timedelta(days=7)
        return int(datetime.combine(resume_date,datetime.min.time(),tzinfo=zone).timestamp())

    # Explicit N-day / N-week pause. Preserve current local clock time:
    # an occurrence exactly before the boundary is skipped; later ones survive.
    m=re.search(r"на\s+(\d{1,3})\s*(дн|день|дня|дней|недел)",text)
    if m:
        count=max(1,min(int(m.group(1)),365))
        days=count*(7 if m.group(2).startswith("недел") else 1)
        return int((now+timedelta(days=days)).timestamp())
    if re.search(r"на\s+(?:одну\s+)?недел",text):
        return int((now+timedelta(days=7)).timestamp())
    return None


def pause_existing_direct(uid: int, message: str, timezone_name: str) -> dict | None:
    """Reliable direct path for a clearly bounded pause of an existing reminder."""
    if not user_explicitly_requests_reminder_pause(message):
        return None
    resume_from=_pause_resume_timestamp(message,timezone_name)
    if resume_from is None:
        # Let the agent resolve dates like «до конца каникул» instead of guessing.
        return None

    tasks=[task for task in reminders._list_owned_sync(int(uid),limit=100)
           if task["status"]=="scheduled"]
    if not tasks:
        return None

    text=" ".join(str(message or "").casefold().split())
    mentions_payment=bool(re.search(r"оплат|сервер|хостинг|vps",text))
    mentions_homework=bool(re.search(r"домаш|домашк|(^|\W)дз($|\W)",text))
    selected=[]
    if mentions_payment != mentions_homework:
        subject_re=(r"оплат|сервер|хостинг|vps" if mentions_payment
                    else r"домаш|домашк|(^|\W)дз($|\W)")
        selected=[task for task in tasks if re.search(
            subject_re,
            (str(task.get("title") or "")+" "+str(task.get("instruction") or "")).casefold()
        )]
    elif len(tasks)==1:
        selected=tasks

    if len(selected)!=1:
        return None

    task=selected[0]
    outcome=reminders._pause_until_sync(
        int(uid),str(task["id"]),resume_from,
        expected_updated_at=int(task.get("updated_at") or 0),
    )
    if not outcome["ok"]:
        return None
    updated=outcome["task"]
    zone=reminders.timezone_obj(
        str(updated.get("timezone_name") or reminders.DEFAULT_TIMEZONE)
    )
    resume_label=datetime.fromtimestamp(resume_from,zone).strftime("%d.%m.%Y")
    next_label=(
        datetime.fromtimestamp(int(updated["run_at"]),zone).strftime("%d.%m.%Y %H:%M")
        if updated.get("status")=="scheduled" else "больше нет срабатываний"
    )
    return {
        "message":(
            f"⏸ Напоминание «{updated.get('title','Напоминание')}» временно приостановлено "
            f"до {resume_label}. Пропущено срабатываний: {int(outcome.get('skipped') or 0)}. "
            f"Следующее: {next_label}."
        ),
        "paused_ids":[str(updated["id"])],
        "resume_from":resume_from,
    }


def disable_existing_direct(uid: int, message: str) -> dict | None:
    """Deterministic path for explicit full reminder disable requests."""
    if not user_explicitly_requests_reminder_disable(message):
        return None
    tasks=[task for task in reminders._list_owned_sync(int(uid),limit=100)
           if task["status"]=="scheduled"]
    if not tasks:
        return {"message":"🗓 У тебя нет активных напоминаний.","cancelled_ids":[]}

    text=" ".join(str(message or "").casefold().split())
    wants_all=bool(re.search(r"(?:все|всё|вообще\s+все).{0,20}напомин",text))
    if wants_all:
        selected=tasks
    else:
        mentions_payment=bool(re.search(r"оплат|сервер|хостинг|vps",text))
        mentions_homework=bool(re.search(r"домаш|домашк|(^|\W)дз($|\W)",text))
        if mentions_payment != mentions_homework:
            subject_re=(r"оплат|сервер|хостинг|vps" if mentions_payment
                        else r"домаш|домашк|(^|\W)дз($|\W)")
            selected=[task for task in tasks if re.search(
                subject_re,
                (str(task.get("title") or "")+" "+str(task.get("instruction") or "")).casefold()
            )]
            if len(selected)==1:
                pass
            else:
                selected=[]
        else:
            selected=[]
        if not selected:
            stop={"напоминание","напоминания","напоминалку","напоминалка","напоминие",
                  "задание","задания","отключи","отключить","выключи","выключить",
                  "выруби","вырубить","отмени","отменить","убери","убрать","вообще",
                  "пожалуйста","говорю","про","это","этот","эту","мне","больше"}
            words=[w for w in re.findall(r"[a-zа-яё0-9]+",text) if len(w)>=4 and w not in stop]
            scored=[]
            for task in tasks:
                hay=(str(task.get("title") or "")+" "+str(task.get("instruction") or "")).casefold()
                score=sum(1 for w in words if w in hay)
                scored.append((score,task))
            best=max((score for score,_ in scored),default=0)
            selected=[task for score,task in scored if score==best and best>0]
            if len(selected)!=1:
                selected=(tasks if len(tasks)==1 and not (mentions_payment or mentions_homework)
                          else [])

    if not selected:
        names=", ".join(str(t.get("title") or "Напоминание") for t in tasks[:6])
        return {"message":f"🗓 Уточни, какое напоминание отключить: {names}.","cancelled_ids":[]}

    cancelled=[]
    for task in selected:
        ok, updated=reminders._cancel_sync(str(task["id"]),int(uid))
        if ok:
            cancelled.append(updated)
    if not cancelled:
        return {"message":"⚠️ Не удалось отключить напоминание — оно уже изменилось.","cancelled_ids":[]}
    if len(cancelled)==1:
        msg=f"✅ Напоминание «{cancelled[0]['title']}» полностью отключено. Больше срабатывать не будет."
    else:
        msg=f"✅ Полностью отключено напоминаний: {len(cancelled)}."
    return {"message":msg,"cancelled_ids":[str(t["id"]) for t in cancelled]}


def grounded_disable_summary(tool_results: list[tuple[str,str]]) -> str:
    """Only a successful disable_reminder tool result may claim full disable."""
    for name,body in reversed(tool_results):
        if name!="disable_reminder":
            continue
        try:
            payload=json.loads(body)
            task=payload.get("reminder") or {}
            if payload.get("result") and task.get("task_id"):
                return (f"✅ Напоминание «{task.get('title','Напоминание')}» полностью отключено. "
                        "Будущих срабатываний не будет.")
        except (TypeError,ValueError):
            pass
        if str(body or "").startswith(("❌","⚠️")):
            return str(body)
    return "⚠️ Напоминание не отключено: подтверждённого результата disable_reminder нет."


def grounded_edit_summary(tool_results: list[tuple[str,str]]) -> str:
    """Only successful update tool records justify a claimed edit."""
    updated=[]
    errors=[]
    for name,body in tool_results:
        if name != "update_reminder":
            continue
        try:
            payload=json.loads(body)
            task=payload.get("reminder") or {}
            if task.get("task_id"):
                updated.append(task)
            else:
                errors.append("Не удалось подтвердить изменение карточки.")
        except (TypeError,ValueError):
            errors.append(str(body or "")[:240])
    if updated:
        result=[f"✅ Изменено существующих напоминаний: {len(updated)}."]
        for task in updated:
            text=str(task.get("text_or_prompt") or "")
            mode="обычный текст без ИИ" if task.get("execution_mode")=="text" else "промпт ИИ"
            result.append(
                f"• {task.get('title','Напоминание')} — {mode}. "
                f"Сообщение/промпт: {text[:350]}"
            )
        result.append("Даты и расписания прежние, новых карточек не создавал.")
        if errors:
            result.append(
                f"⚠️ Некоторые изменения не удалось выполнить: {len(errors)}. "
                "Проверь остальные карточки."
            )
        return "\n".join(result)
    if errors:
        return ("❌ Настройки напоминаний не изменены. "
                "Ошибка редактирования: "+"; ".join(errors[:2]))
    return (
        "⚠️ Нашёл напоминания, но не изменил их: модель не вызвала "
        "update_reminder. Попробуй ещё раз или используй ручную "
        "кнопку «Изменить» в /reminders."
    )


def _plain_reminder_message(task: dict) -> str | None:
    """Conservative, user-facing wording for known reminder subjects only."""
    title=str(task.get("title") or "").casefold()
    if re.search(r"домашн|домашк|(^|\W)дз($|\W)",title):
        return "📚 Пора сделать домашнее задание! Проверь, что задано, и начинай с самого важного."
    if re.search(r"сервер|оплат|хостинг|vps",title):
        return ("💳 Проверь оплату серверов GhostEcos: если ещё не оплатил — "
                "оплати, а если оплатил — убедись, что платёж прошёл.")
    return None


def is_direct_text_conversion_request(message: str) -> bool:
    """Explicit text-mode switch intent; do NOT intercept general chat or creation."""
    text=" ".join(str(message or "").casefold().split())
    if not text:
        return False
    if re.search(r"(?:не|нет)\s+(?:меняй|переводи|переключай|поставь)",text):
        return False
    if not re.search(r"напомин|задан",text):
        return False
    if not re.search(r"текстов\w*|тектов\w*|режим\w*\s+текст\w*|"
                     r"на\s+текст\w*\s+ответ",text):
        return False
    if not re.search(r"измени|изменить|поменяй|поменять|переведи|перевести|"
                     r"переключи|переключить|поставь|сделай|сделать|замени|"
                     r"заменить",text):
        return False
    # New reminders must use the regular planner with a date/time, not
    # silently mutate existing tasks because the new card says "text".
    if user_explicitly_requests_new_reminder(text):
        return False
    return True


def change_existing_to_text_direct(uid: int, message: str) -> dict | None:
    """Reliable direct path when an unreliable model fails to invoke tools.

    Returns None for unrelated requests, or a result with a plain reply and
    changed task IDs. Must be called with the authenticated Telegram uid.
    """
    if not is_direct_text_conversion_request(message):
        return None
    tasks=[task for task in reminders._list_owned_sync(uid,limit=100)
           if task["status"]=="scheduled"]
    if not tasks:
        return {"message":"🗓 У тебя сейчас нет активных подтверждённых напоминаний.",
                "changed_ids":[]}

    text=" ".join(str(message).casefold().split())
    wants_all=bool(re.search(r"обоим|обоих|оба|все\s+напомин|всем\s+напомин",text))
    mentions_homework=bool(re.search(r"домаш|домашк|(^|\W)дз($|\W)",text))
    mentions_payment=bool(re.search(r"сервер|оплат|хостинг",text))
    if wants_all:
        selected=tasks
    elif mentions_homework != mentions_payment:
        selected=[
            task for task in tasks
            if (_plain_reminder_message(task) or "").startswith(
                "📚" if mentions_homework else "💳"
            )
        ]
    elif len(tasks) <= 2:
        # Plural "напоминалки" with two active tasks clearly refers to
        # the existing pair; never apply this to a large collection.
        selected=tasks
    else:
        selected=[]

    if not selected or len(selected)>2:
        return {"message":(
            f"🗓 Активных напоминаний: {len(tasks)}. Уточни, какие перевести "
            "в текстовый режим: название или ID. Пока ничего не изменено."
        ),"changed_ids":[]}

    changed=[]
    unchanged=[]
    skipped=[]
    for task in selected:
        name=str(task.get("title") or "Напоминание")
        if task.get("execution_mode")=="text":
            unchanged.append((name,str(task.get("instruction") or "")))
            continue
        literal=_plain_reminder_message(task)
        if literal is None:
            skipped.append(name)
            continue
        outcome=reminders._change_existing_sync(
            int(uid),str(task["id"]),
            expected_updated_at=int(task["updated_at"]),
            execution_mode="text",instruction=literal,
        )
        if outcome["ok"]:
            changed.append((name,literal,str(task["id"])))
        else:
            skipped.append(name)

    lines=[]
    if changed:
        lines.append(f"✅ Перевёл в текстовый режим: {len(changed)}.")
    if unchanged:
        lines.append(f"✅ Уже работают без ИИ: {len(unchanged)}.")
    if not changed and not unchanged:
        lines.append("⚠️ Ни одно напоминание не изменено.")
    for name,literal,*_ in changed+unchanged:
        lines.append(f"• {name}: {literal}")
    if skipped:
        lines.append(
            "⚠️ Не изменены (нужен точный текст или повторная попытка): "
            +", ".join(skipped)
        )
    lines.append("Расписания сохранены, новые карточки не создавались.")
    return {"message":"\n".join(lines),"changed_ids":[x[2] for x in changed]}
