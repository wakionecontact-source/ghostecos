"""Загрузка и скачивание файлов (временное хранение, удаление после доставки)."""
from __future__ import annotations
import os, uuid, hashlib, time
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form, Request
from fastapi.responses import FileResponse

import config, database as db
from dependencies import get_current_user

router = APIRouter(prefix="/api", tags=["files"])

UPLOAD_DIR       = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "uploads")
FILE_MAX_BYTES   = 50 * 1024 * 1024   # 50 MB
FILE_EXPIRE_SECS = 1800                # 30 мин
FILE_QUOTA_BYTES = 500 * 1024 * 1024  # 500 MB на пользователя

os.makedirs(UPLOAD_DIR, exist_ok=True)


# ── Upload ────────────────────────────────────────────────────────────────────

@router.post("/files/upload")
async def upload_file(
    file:       UploadFile = File(...),
    to_username: str       = Form(""),
    channel_id:  str       = Form(""),
    enc_key:     str       = Form(""),
    msg_id:      str       = Form(""),
    username: str = Depends(get_current_user),
):
    if not to_username and not channel_id:
        raise HTTPException(400, "to_username or channel_id required")

    # Размер
    data = await file.read()
    if len(data) > FILE_MAX_BYTES:
        raise HTTPException(413, "File too large (max 50 MB)")

    # Квота пользователя
    quota_row = await db.fetchone(
        "SELECT COALESCE(SUM(file_size), 0) as used FROM pending_files WHERE from_username = ?",
        (username,)
    )
    if quota_row and quota_row["used"] + len(data) > FILE_QUOTA_BYTES:
        raise HTTPException(429, "Storage quota exceeded")

    sha256   = hashlib.sha256(data).hexdigest()
    file_id  = str(uuid.uuid4())
    ext      = os.path.splitext(file.filename or "")[1][:16]
    dst      = os.path.join(UPLOAD_DIR, f"{file_id}{ext}")

    with open(dst, "wb") as f:
        f.write(data)

    now     = db.now()
    expires = now + FILE_EXPIRE_SECS
    await db.execute(
        "INSERT INTO pending_files "
        "(file_id, from_username, to_username, channel_id, filename, mime_type, "
        "file_size, file_path, enc_key, msg_id, sha256, status, created_at, expires_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (file_id, username, to_username, channel_id,
         file.filename or "", file.content_type or "application/octet-stream",
         len(data), dst, enc_key, msg_id, sha256, "uploaded", now, expires)
    )
    return {"file_id": file_id, "sha256": sha256, "expires_at": expires}


# ── Download ──────────────────────────────────────────────────────────────────

@router.get("/files/{file_id}")
async def download_file(file_id: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT * FROM pending_files WHERE file_id = ?", (file_id,)
    )
    if not row:
        raise HTTPException(404, "File not found")
    if row["expires_at"] < db.now():
        await _cleanup_file(row)
        raise HTTPException(410, "File expired")
    # Проверить права: отправитель, получатель или участник канала
    allowed = (
        row["from_username"] == username
        or row["to_username"] == username
        or (row["channel_id"] and await db.fetchone(
            "SELECT 1 FROM channel_members WHERE channel_id = ? AND username = ?",
            (row["channel_id"], username)
        ))
    )
    if not allowed:
        raise HTTPException(403, "Access denied")
    if not os.path.exists(row["file_path"]):
        raise HTTPException(410, "File no longer available")
    return FileResponse(
        row["file_path"],
        media_type=row["mime_type"] or "application/octet-stream",
        filename=row["filename"] or file_id,
    )


# ── ACK (удалить после доставки) ─────────────────────────────────────────────

@router.post("/files/{file_id}/ack")
async def ack_file(file_id: str, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT * FROM pending_files WHERE file_id = ?", (file_id,)
    )
    if not row:
        return {"ok": True}
    if row["to_username"] != username and row["from_username"] != username:
        raise HTTPException(403, "Access denied")
    await _cleanup_file(row)
    return {"ok": True}


# ── Reupload (запрос повторной отправки) ──────────────────────────────────────

@router.post("/files/{file_id}/reupload_request")
async def reupload_request(file_id: str, body: dict, username: str = Depends(get_current_user)):
    row = await db.fetchone(
        "SELECT from_username, to_username FROM pending_files WHERE file_id = ?",
        (file_id,)
    )
    if not row:
        # Создать file_request
        from_user = body.get("from_username", "")
        if not from_user:
            raise HTTPException(400, "from_username required")
        await db.execute(
            "INSERT INTO file_requests (file_id, from_username, to_username, msg_id, status, created_at) "
            "VALUES (?,?,?,?,?,?)",
            (file_id, from_user, username, body.get("msg_id", ""), "pending", db.now())
        )
        return {"ok": True, "requested": True}
    return {"ok": True, "exists": True}


# ── Очистка истёкших файлов ───────────────────────────────────────────────────

async def cleanup_expired_files():
    """Вызывается фоновой задачей."""
    rows = await db.fetchall(
        "SELECT * FROM pending_files WHERE expires_at < ?", (db.now(),)
    )
    for row in rows:
        await _cleanup_file(row)


async def _cleanup_file(row: dict):
    try:
        if row.get("file_path") and os.path.exists(row["file_path"]):
            os.remove(row["file_path"])
    except OSError:
        pass
    await db.execute("DELETE FROM pending_files WHERE file_id = ?", (row["file_id"],))
