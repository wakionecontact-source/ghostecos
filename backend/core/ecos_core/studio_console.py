"""Обзор личных приложений, ключей и проектов для GhostStudio."""
from datetime import datetime, timedelta, timezone
import time

from fastapi import APIRouter, Query, Request

from ecos_core import api_keys, studio_auth, studio_projects

router = APIRouter(prefix="/api/developer", tags=["GhostStudio"])
_MOSCOW = timezone(timedelta(hours=3))
_DAY = 86400


@router.get("/overview")
def overview(request: Request, days: int = Query(default=7, ge=7, le=30)):
    owner = studio_projects._owner(request)
    now = int(time.time())
    today = datetime.fromtimestamp(now, _MOSCOW).date()
    first = today - timedelta(days=days - 1)
    first_day = (int(datetime.combine(first, datetime.min.time(), _MOSCOW).timestamp()) + 10800) // _DAY
    series = [{"date": (first + timedelta(days=i)).isoformat(), "apps": 0, "keys": 0, "projects": 0} for i in range(days)]
    recent = []

    def daily(con, table, where, args, kind):
        rows = con.execute(
            f"SELECT CAST((created_at+10800)/86400 AS INTEGER) AS day,COUNT(*) AS count FROM {table} WHERE {where} AND created_at>=? AND created_at<=? GROUP BY day",
            (*args, first_day * _DAY - 10800, now),
        ).fetchall()
        for row in rows:
            index = row["day"] - first_day
            if 0 <= index < days:
                series[index][kind] = row["count"]

    with studio_auth._db() as con:
        where = "a.user_id=? AND c.owner_id=a.user_id"
        table = "studio_apps a JOIN clients c USING(client_id)"
        rows = con.execute(f"SELECT a.*,c.config,c.revision FROM {table} WHERE {where} ORDER BY a.created_at DESC", (owner,)).fetchall()
        apps = [studio_auth._public(row) for row in rows]
        app_counts = {"total": len(apps), **{state: sum(item["state"] == state for item in apps) for state in ("active", "pending", "disabled")}}
        # Берём даты только у приложений этого владельца.
        for item in apps:
            index = (item["created_at"] + 10800) // _DAY - first_day
            if 0 <= index < days and item["created_at"] <= now:
                series[index]["apps"] += 1
            recent.append({"kind": "apps", "name": item["name"], "action": "Приложение создано", "at": item["created_at"], "id": item["client_id"]})
            if item["verified_at"]:
                recent.append({"kind": "apps", "name": item["name"], "action": "Сайт подтверждён", "at": item["verified_at"], "id": item["client_id"]})

    with api_keys._db() as con:
        counts = con.execute("""SELECT COUNT(*) AS total,
            COALESCE(SUM(revoked_at IS NULL AND expires_at>?),0) AS active,
            COALESCE(SUM(revoked_at IS NULL AND expires_at<=?),0) AS expired,
            COALESCE(SUM(revoked_at IS NOT NULL),0) AS revoked
            FROM api_keys WHERE user_id=?""", (now, now, owner)).fetchone()
        key_counts = dict(counts)
        daily(con, "api_keys", "user_id=?", (owner,), "keys")
        rows = con.execute("""SELECT key_id,name,created_at,revoked_at,last_used_at FROM api_keys
            WHERE user_id=? ORDER BY MAX(created_at,COALESCE(revoked_at,0),COALESCE(last_used_at,0)) DESC LIMIT 8""", (owner,)).fetchall()
        for row in rows:
            at, action = row["created_at"], "Ключ создан"
            for candidate, label in ((row["last_used_at"], "Ключ использован"), (row["revoked_at"], "Ключ отозван")):
                if candidate and candidate >= at:
                    at, action = candidate, label
            recent.append({"kind": "keys", "name": row["name"], "action": action, "at": at, "id": row["key_id"]})

    with studio_projects._db() as con:
        counts = con.execute("""SELECT COUNT(*) AS total,COALESCE(SUM(state='draft'),0) AS draft,
            COALESCE(SUM(state='archived'),0) AS archived FROM studio_projects WHERE user_id=?""", (owner,)).fetchone()
        project_counts = dict(counts)
        daily(con, "studio_projects", "user_id=?", (owner,), "projects")
        rows = con.execute("SELECT project_id,name,state,created_at,updated_at FROM studio_projects WHERE user_id=? ORDER BY updated_at DESC LIMIT 8", (owner,)).fetchall()
        for row in rows:
            action = "Проект в архиве" if row["state"] == "archived" else "Проект обновлён" if row["updated_at"] > row["created_at"] else "Проект создан"
            recent.append({"kind": "projects", "name": row["name"], "action": action, "at": row["updated_at"], "id": row["project_id"]})

    return {"generated_at": now, "timezone": "Europe/Moscow", "days": days,
            "summary": {"apps": app_counts, "keys": key_counts, "projects": project_counts},
            "series": series, "apps": apps,
            "recent": sorted(recent, key=lambda item: (item["at"], item["id"]), reverse=True)[:8]}
