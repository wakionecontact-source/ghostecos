"""Личные проекты GhostStudio и доступ к ним по отдельным разрешениям API."""
from __future__ import annotations

import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ecos_core.shared import _rate_limit

router = APIRouter(prefix="/api/developer", tags=["GhostStudio projects"])
Kind = Literal["api", "extensions", "music", "social", "people", "communities"]
State = Literal["draft", "archived"]
_ID = re.compile(r"^[A-Za-z0-9_-]{16}$")


def _text(value: str, multiline: bool = False) -> str:
    value = value.strip()
    if any((ord(c) < 32 and not (multiline and c in "\n\t")) or 127 <= ord(c) <= 159 for c in value):
        raise ValueError("В тексте есть недопустимые управляющие символы")
    return value


class CreateProject(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=80)
    kind: Kind
    description: str = Field(default="", max_length=2000)

    @field_validator("name")
    @classmethod
    def name_text(cls, value):
        value = _text(value)
        if not value:
            raise ValueError("Укажи название проекта")
        return value

    @field_validator("description")
    @classmethod
    def description_text(cls, value):
        return _text(value, multiline=True)


class UpdateProject(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    name: str | None = Field(default=None, min_length=1, max_length=80)
    description: str | None = Field(default=None, max_length=2000)
    state: State | None = None

    @field_validator("name")
    @classmethod
    def name_text(cls, value):
        if value is None or not _text(value):
            raise ValueError("Укажи название проекта")
        return _text(value)

    @field_validator("description", "state")
    @classmethod
    def not_null(cls, value):
        if value is None:
            raise ValueError("Поле не может быть null")
        return value

    @field_validator("description")
    @classmethod
    def description_text(cls, value):
        return _text(value, multiline=True)

    @model_validator(mode="after")
    def has_changes(self):
        if not self.model_fields_set.intersection({"name", "description", "state"}):
            raise ValueError("Передай изменяемые поля проекта")
        return self


def _path():
    return Path(os.getenv("GE_STUDIO_DB_PATH", "/opt/ghostecos-core/private/studio.sqlite3"))


@contextmanager
def _db():
    path = _path()
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    con = sqlite3.connect(path, timeout=5)
    con.row_factory = sqlite3.Row
    os.chmod(path, 0o600)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=5000")
    con.executescript("""
        CREATE TABLE IF NOT EXISTS studio_projects (
            project_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
            name TEXT NOT NULL, kind TEXT NOT NULL, description TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'draft', revision INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS studio_projects_owner
            ON studio_projects(user_id, state, updated_at DESC, project_id);
    """)
    try:
        with con:
            yield con
    finally:
        con.close()


def _owner(request, api=False, write=False):
    from ecos_core import api_keys
    if api:
        user, scopes = api_keys._api_key_identity(request)
        needed = "projects:write" if write else "projects:read"
        if needed not in scopes:
            raise HTTPException(403, "Ключу не выдано разрешение " + needed)
    else:
        from ecos_core.service_sso import _issuer
        origin = request.headers.get("origin")
        if origin and origin != _issuer():
            raise HTTPException(403, "Запрос кабинета должен приходить с сайта GhostEcos")
        user = api_keys._account(request)
    owner = int(user["id"])
    _rate_limit("studio-projects:" + ("write:" if write else "read:") + str(owner),
                limit=60 if write else 120, window=60)
    return owner


def _public(row):
    return {name: row[name] for name in (
        "project_id", "name", "kind", "description", "state", "revision", "created_at", "updated_at")}


def _find(con, owner, project_id):
    if not _ID.fullmatch(project_id):
        raise HTTPException(404, "Проект не найден")
    row = con.execute("SELECT * FROM studio_projects WHERE user_id=? AND project_id=?",
                      (owner, project_id)).fetchone()
    if row is None:
        raise HTTPException(404, "Проект не найден")
    return row


def _list(owner, state, limit, offset):
    with _db() as con:
        clause = "user_id=?" + (" AND state=?" if state != "all" else "")
        args = (owner, state) if state != "all" else (owner,)
        total = con.execute("SELECT COUNT(*) FROM studio_projects WHERE " + clause, args).fetchone()[0]
        rows = con.execute("SELECT * FROM studio_projects WHERE " + clause +
                           " ORDER BY updated_at DESC,project_id LIMIT ? OFFSET ?",
                           (*args, limit, offset)).fetchall()
    return {"projects": [_public(row) for row in rows], "total": total, "limit": limit, "offset": offset}


def _create(owner, body):
    now = int(time.time())
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        if con.execute("SELECT COUNT(*) FROM studio_projects WHERE user_id=?", (owner,)).fetchone()[0] >= 200:
            raise HTTPException(409, "Можно сохранить не больше 200 проектов")
        project_id = secrets.token_urlsafe(12)
        con.execute("INSERT INTO studio_projects VALUES (?,?,?,?,?,'draft',1,?,?)",
                    (project_id, owner, body.name, body.kind, body.description, now, now))
        return {"project": _public(_find(con, owner, project_id))}


def _update(owner, project_id, body):
    with _db() as con:
        con.execute("BEGIN IMMEDIATE")
        row = _find(con, owner, project_id)
        if row["revision"] != body.expected_revision:
            raise HTTPException(409, "Проект уже изменён. Обнови его и повтори сохранение")
        changes = body.model_dump(exclude_unset=True, exclude={"expected_revision"})
        fields = ",".join(name + "=?" for name in changes)
        con.execute("UPDATE studio_projects SET " + fields + ",revision=revision+1,updated_at=? "
                    "WHERE user_id=? AND project_id=? AND revision=?",
                    (*changes.values(), int(time.time()), owner, project_id, body.expected_revision))
        return {"project": _public(_find(con, owner, project_id))}


@router.get("/projects")
@router.get("/v1/projects")
def list_projects(request: Request, state: Literal["draft", "archived", "all"] = "draft",
                  limit: int = Query(default=50, ge=1, le=100), offset: int = Query(default=0, ge=0, le=10000)):
    return _list(_owner(request, api="/v1/" in request.url.path), state, limit, offset)


@router.post("/projects", status_code=201)
@router.post("/v1/projects", status_code=201)
def create_project(request: Request, body: CreateProject):
    return _create(_owner(request, api="/v1/" in request.url.path, write=True), body)


@router.get("/projects/{project_id}")
@router.get("/v1/projects/{project_id}")
def get_project(project_id: str, request: Request):
    owner = _owner(request, api="/v1/" in request.url.path)
    with _db() as con:
        return {"project": _public(_find(con, owner, project_id))}


@router.patch("/projects/{project_id}")
@router.patch("/v1/projects/{project_id}")
def update_project(project_id: str, request: Request, body: UpdateProject):
    return _update(_owner(request, api="/v1/" in request.url.path, write=True), project_id, body)


def purge_for_user(user_id):
    if not _path().is_file():
        return 0
    with _db() as con:
        return con.execute("DELETE FROM studio_projects WHERE user_id=?", (int(user_id),)).rowcount
