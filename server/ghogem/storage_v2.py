"""GhoGemo V2 per-owner temporary stores with quotas and expiration.

Separated entirely from permanent chat/shared files. This module never selects
an owner: the caller supplies the uid from a verified session/SSO namespace.
"""
from __future__ import annotations

from contextlib import contextmanager
from io import BytesIO
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time

MIB = 1024 * 1024
AREA_CONFIG = {
    "media": {"free": 25*MIB, "premium": 60*MIB,
              "free_ttl": 3*86400, "premium_ttl": 10*86400},
    "buffer": {"free": 2*MIB, "premium": 10*MIB,
               "free_ttl": 86400, "premium_ttl": 86400},
}
IMAGE_TYPES = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}
AUDIO_TYPES = {".mp3", ".ogg", ".opus", ".m4a", ".wav", ".flac", ".aac", ".aiff"}
VIDEO_TYPES = {".mp4", ".webm", ".mov", ".mkv", ".avi", ".mpeg", ".mpg"}
MEDIA_TYPES = IMAGE_TYPES | AUDIO_TYPES | VIDEO_TYPES
MEDIA_MAX_UPLOAD = 60 * MIB

class StorageError(ValueError):
    pass

def category(filename: str) -> str:
    return Path(filename).suffix.casefold()

def is_media(filename: str) -> bool:
    return category(filename) in MEDIA_TYPES

def owner_root(users_root: str, uid: int) -> Path:
    base = Path(users_root).resolve()
    candidate = base / str(int(uid))
    if candidate.is_symlink():
        raise StorageError("Папка пользователя не может быть символической ссылкой.")
    root = candidate.resolve()
    if not root.is_relative_to(base) or root == base:
        raise StorageError("Недопустимая папка пользователя.")
    return root

def area_root(users_root: str, uid: int, area: str) -> Path:
    if area not in AREA_CONFIG:
        raise StorageError("Неизвестная область памяти.")
    root = owner_root(users_root, uid)
    folder = (root / area).resolve()
    if not folder.is_relative_to(root):
        raise StorageError("Путь выходит за границы пользовательской песочницы.")
    return folder

@contextmanager
def _lock(user_root: Path):
    user_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = user_root / ".temporary-storage.lock"
    with lock_path.open("a+b") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

def _manifest(user_root: Path) -> Path:
    return user_root / "temporary_storage_v2.json"

def _read_manifest(user_root: Path) -> dict:
    path = _manifest(user_root)
    if not path.is_file():
        return {"media": {}, "buffer": {}}
    if not path.resolve().is_relative_to(user_root):
        raise StorageError("Каталог метаданных вышел за песочницу.")
    try:
        obj = json.loads(path.read_text(encoding="utf8"))
        if isinstance(obj, dict) and all(isinstance(obj.get(k), dict) for k in AREA_CONFIG):
            return obj
    except (OSError, ValueError, UnicodeError):
        pass
    raise StorageError("Метаданные хранилища повреждены, запись остановлена во избежание потери данных.")

def _write_manifest(user_root: Path, metadata: dict) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".ghogem-index-", dir=user_root)
    try:
        with os.fdopen(fd, "w", encoding="utf8") as stream:
            json.dump(metadata, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, _manifest(user_root))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def _valid_entry_path(folder: Path, name: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,24}[.][A-Za-z0-9]{1,8}", name):
        raise StorageError("Некорректное имя временного файла.")
    path = (folder / name).resolve()
    if not path.is_relative_to(folder):
        raise StorageError("Недопустимый путь временного файла.")
    return path

def _prune(user_root: Path, metadata: dict, now: float) -> dict:
    deleted = {"media": 0, "buffer": 0}
    for area in AREA_CONFIG:
        folder = (user_root / area).resolve()
        if not folder.is_relative_to(user_root):
            raise StorageError("Недопустимый путь хранилища.")
        for name, info in list(metadata[area].items()):
            try:
                file_path = _valid_entry_path(folder, name)
                expired = float(info["expires_at"]) <= now
            except (StorageError, TypeError, ValueError, KeyError):
                expired = True
                file_path = None
            if expired and isinstance(info, dict) and float(info.get("lease_until", 0)) > now:
                # Processing already admitted files may complete after their
                # original expiry without a cleanup race.
                continue
            if expired:
                if file_path is not None and file_path.is_file():
                    file_path.unlink()
                    deleted[area] += 1
                metadata[area].pop(name, None)
            elif not file_path.is_file():
                metadata[area].pop(name, None)
    return deleted

def quota(area: str, premium: bool) -> int:
    return AREA_CONFIG[area]["premium" if premium else "free"]

def ttl(area: str, premium: bool) -> int:
    return AREA_CONFIG[area]["premium_ttl" if premium else "free_ttl"]

def _usage(folder: Path, entries: dict) -> int:
    size = 0
    for name in entries:
        try:
            path = _valid_entry_path(folder, name)
            if path.is_file():
                size += path.stat().st_size
        except (StorageError, OSError):
            continue
    return size

def _compress_image(content: bytes, ext: str) -> tuple[bytes, str, bool]:
    from PIL import Image, ImageOps
    try:
        with Image.open(BytesIO(content)) as initial:
            initial.verify()
        with Image.open(BytesIO(content)) as image:
            if getattr(image, "is_animated", False):
                return content, ext, False  # Never destroy animation.
            corrected = ImageOps.exif_transpose(image)
            if corrected.width * corrected.height > 32_000_000:
                raise StorageError("Изображение слишком велико по количеству пикселей.")
            if corrected.width > 3200 or corrected.height > 3200:
                corrected.thumbnail((3200, 3200), Image.Resampling.LANCZOS)
            # Preserve transparency; a white/black replacement background would
            # destroy important details in PNG screenshots and UI assets.
            has_alpha = ("A" in corrected.getbands()) or ("transparency" in image.info)
            picture = corrected.convert("RGBA" if has_alpha else "RGB")
            pixels = picture.getcolors(maxcolors=512)
            output = BytesIO()
            if has_alpha or pixels is not None:
                picture.save(output, "WEBP", lossless=True, method=0)
            else:
                picture.save(output, "WEBP", quality=88, method=0)
            compressed = output.getvalue()
        if len(compressed) < len(content):
            return compressed, ".webp", True
        return content, ext, False
    except StorageError:
        raise
    except Exception as exc:
        raise StorageError(f"Файл не является допустимым изображением: {type(exc).__name__}") from exc

def _compress_with_ffmpeg(content: bytes, ext: str, video: bool) -> tuple[bytes, str, bool]:
    # ffmpeg operates on temporary files with hard CPU / time / size limits.
    with tempfile.TemporaryDirectory(prefix="ghogem-compress-") as root:
        source = os.path.join(root, "input" + ext)
        target = os.path.join(root, "output.mp4" if video else "output.ogg")
        with open(source, "wb") as stream:
            stream.write(content)
        # Check media bytes rather than trusting the filename extension.
        try:
            check = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
                 "-of", "csv=p=0", source], capture_output=True, text=True, timeout=8,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise StorageError("Медиа не удалось проверить.") from exc
        stream = "video" if video else "audio"
        if check.returncode or stream not in check.stdout.splitlines():
            raise StorageError("Содержимое медиа не соответствует расширению файла.")
        if video:
            cmd = [
                "ffmpeg", "-nostdin", "-v", "error", "-y", "-threads", "1",
                "-i", source, "-map", "0:v:0", "-map", "0:a?",
                "-vf", "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "31",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k",
                "-movflags", "+faststart", target,
            ]
        else:
            cmd = [
                "ffmpeg", "-nostdin", "-v", "error", "-y", "-threads", "1",
                "-i", source, "-vn", "-c:a", "libopus",
                "-b:a", "64k", "-application", "audio", target,
            ]
        try:
            run = subprocess.run(cmd, capture_output=True, timeout=25)
            if run.returncode == 0 and os.path.isfile(target):
                with open(target, "rb") as stream:
                    candidate = stream.read(MEDIA_MAX_UPLOAD + 1)
                if len(candidate) < len(content):
                    return candidate, ".mp4" if video else ".ogg", True
        except (OSError, subprocess.TimeoutExpired):
            pass
    return content, ext, False

def compress_media(filename: str, content: bytes) -> tuple[bytes, str, bool]:
    ext = category(filename)
    if ext not in MEDIA_TYPES:
        raise StorageError("В медиахранилище допускаются только фото, аудио и видео.")
    if not content or len(content) > MEDIA_MAX_UPLOAD:
        raise StorageError("Недопустимый размер медиафайла.")
    if ext in IMAGE_TYPES:
        return _compress_image(content, ext)
    return _compress_with_ffmpeg(content, ext, video=ext in VIDEO_TYPES)

def save_temporary(users_root: str, uid: int, filename: str, content: bytes, *,
                   area: str, premium: bool, urgent: bool = False,
                   main_full: bool = False) -> dict:
    if area not in AREA_CONFIG:
        raise StorageError("Неизвестный тип памяти.")
    ext = category(filename)
    if area == "media" and ext not in MEDIA_TYPES:
        raise StorageError("Медиахранилище принимает только медиафайлы.")
    if area == "buffer":
        if ext in AUDIO_TYPES | VIDEO_TYPES:
            raise StorageError("Буфер предназначен для файлов и фото, не для видео и аудио.")
        if not (urgent or main_full):
            raise StorageError("Буфер доступен для срочной задачи или переполненной основной памяти.")
    if not isinstance(content, bytes) or not content or len(content) > MEDIA_MAX_UPLOAD:
        raise StorageError("Некорректный размер файла.")
    raw, stored_ext, compressed = (
        compress_media(filename, content) if ext in MEDIA_TYPES
        else (content, ext if ext and re.fullmatch(r"\.[a-z0-9]{1,8}", ext) else ".bin", False)
    )
    user_root = owner_root(users_root, uid)
    destination = area_root(users_root, uid, area)
    now = time.time()
    with _lock(user_root):
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        meta = _read_manifest(user_root)
        _prune(user_root, meta, now)
        before = _usage(destination, meta[area])
        if before + len(raw) > quota(area, premium):
            raise StorageError(
                f"Недостаточно места в {area}: свободно {max(0, quota(area,premium)-before)//1024} КБ."
            )
        import shutil
        if shutil.disk_usage(destination).free - len(raw) < 1024 ** 3:
            raise StorageError("Недостаточно свободного места на сервере.")
        name = secrets.token_hex(8) + stored_ext
        path = _valid_entry_path(destination, name)
        fd, temporary = tempfile.mkstemp(prefix=".ghogem-write-", dir=destination)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            meta[area][name] = {
                "original_name": str(filename)[:160],
                "original_size": len(content),
                "created_at": int(now),
                "expires_at": int(now + ttl(area, premium)),
                "size": len(raw),
                "compressed": compressed,
            }
            try:
                _write_manifest(user_root, meta)
            except Exception:
                path.unlink(missing_ok=True)
                raise
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return {
            "name": name,
            "original_name": str(filename)[:160],
            "original_size": len(content),
            "area": area,
            "size": len(raw),
            "expires_at": int(now + ttl(area,premium)),
            "compressed": compressed,
        }

def list_temporary(users_root: str, uid: int, *, area: str, premium: bool) -> dict:
    user_root = owner_root(users_root, uid)
    folder = area_root(users_root, uid, area)
    with _lock(user_root):
        meta = _read_manifest(user_root)
        _prune(user_root, meta, time.time())
        _write_manifest(user_root, meta)
        records = [{**info, "name": name, "remaining_seconds":
                    max(0, int(float(info["expires_at"]) - time.time()))}
                   for name, info in meta[area].items()]
        records.sort(key=lambda x: x["expires_at"])
        return {"area": area, "used": _usage(folder, meta[area]),
                "limit": quota(area, premium), "files": records}

def temp_path(users_root: str, uid: int, name: str, area: str) -> str:
    user_root = owner_root(users_root, uid)
    folder = area_root(users_root, uid, area)
    with _lock(user_root):
        meta = _read_manifest(user_root)
        record = meta[area].get(name)
        if not isinstance(record, dict) or float(record.get("expires_at", 0)) <= time.time():
            raise StorageError("Временный файл не найден или срок хранения истёк.")
        path = _valid_entry_path(folder, name)
        if not path.is_file():
            raise StorageError("Временный файл не найден.")
        record["lease_until"] = int(time.time()) + 1800
        _write_manifest(user_root, meta)
        return str(path)

def cleanup_expired(users_root: str, uid: int) -> dict:
    user_root = owner_root(users_root, uid)
    with _lock(user_root):
        meta = _read_manifest(user_root)
        removed = _prune(user_root, meta, time.time())
        _write_manifest(user_root, meta)
        return removed


def delete_temporary(users_root: str, uid: int, *, area: str, name: str) -> int:
    """Delete one *owned* temporary file by its opaque stored name.

    The caller must already have explicit end-user confirmation. Unlike
    automatic expiry, an explicit owner deletion overrides a conservative
    read lease; an in-flight analysis may fail after such a deletion.
    Return actual bytes freed; no operation is performed on missing files.
    """
    user_root = owner_root(users_root, uid)
    folder = area_root(users_root, uid, area)
    with _lock(user_root):
        metadata = _read_manifest(user_root)
        info = metadata[area].get(name)
        if not isinstance(info, dict):
            raise StorageError("Файл не найден в твоём временном хранилище.")
        path = _valid_entry_path(folder, name)
        size = path.stat().st_size if path.is_file() else 0
        if path.is_file():
            path.unlink()
        metadata[area].pop(name)
        _write_manifest(user_root, metadata)
        return size
