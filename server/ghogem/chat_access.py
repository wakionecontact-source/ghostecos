"""Owner-scoped, read-only chat retrieval for GhoGemo.

The caller may choose an existing chat id, but NEVER an owner id or filesystem
root. Every file path is resolved and confined under users/<authenticated uid>.
"""
from __future__ import annotations
from datetime import datetime
import json
import os
from pathlib import Path

MAX_CHATS = 200
MAX_HISTORY_BYTES = 3 * 1024 * 1024
MAX_FILE_READ_BYTES = 512 * 1024
SAFE_TEXT_EXTENSIONS = {
    ".txt", ".md", ".py", ".js", ".ts", ".jsx", ".tsx", ".html",
    ".css", ".json", ".jsonl", ".csv", ".xml", ".yaml", ".yml",
    ".log", ".ini", ".toml", ".sql", ".sh", ".java", ".c", ".cpp",
    ".h", ".rs", ".go", ".rb", ".php", ".env.example",
}

class AccessError(ValueError):
    pass

def _owner_root(users_root: str, uid: int) -> Path:
    base = Path(users_root).resolve()
    candidate = base / str(int(uid))
    if candidate.is_symlink():
        raise AccessError("Пользовательская папка не может быть ссылкой.")
    resolved = candidate.resolve()
    if not resolved.is_relative_to(base):
        raise AccessError("Некорректная корневая папка пользователя.")
    return resolved

def _inside(root: Path, candidate: Path) -> Path:
    path = candidate.resolve()
    if not path.is_relative_to(root):
        raise AccessError("Путь вышел за границы песочницы пользователя.")
    return path

def _chat_dir(users_root: str, uid: int, chat_id: str) -> Path:
    root = _owner_root(users_root, uid)
    identifier = str(chat_id)
    if not identifier.isascii() or not identifier.isdigit() or len(identifier) > 24:
        raise AccessError("Некорректный идентификатор чата.")
    candidate = _inside(root, root / "chats" / identifier)
    if not candidate.is_dir() or (root / "chats" / identifier).is_symlink():
        raise AccessError("Чат не найден среди чатов текущего пользователя.")
    return candidate

def _history(chat_dir: Path) -> list[dict]:
    path = _inside(chat_dir, chat_dir / "history.json")
    if not path.is_file() or path.stat().st_size > MAX_HISTORY_BYTES:
        return []
    try:
        with path.open(encoding="utf-8") as stream:
            data = json.load(stream)
        if not isinstance(data, list):
            return []
        return [
            entry for entry in data
            if isinstance(entry, dict) and entry.get("role") in ("user", "assistant")
        ]
    except (OSError, UnicodeError, ValueError):
        return []

def _iter_chats(users_root: str, uid: int):
    root = _owner_root(users_root, uid)
    folder = root / "chats"
    if not folder.is_dir() or not folder.resolve().is_relative_to(root):
        return
    candidates = sorted(folder.iterdir(), key=lambda p: p.name, reverse=True)
    count = 0
    for candidate in candidates:
        if count >= MAX_CHATS:
            break
        try:
            chat_dir = _chat_dir(users_root, uid, candidate.name)
        except (AccessError, OSError):
            continue
        count += 1
        yield candidate.name, chat_dir

def _chat_title(chat_dir: Path, history: list[dict]) -> str:
    try:
        path=_inside(chat_dir,chat_dir/"title.txt")
        if path.is_file():
            title=" ".join(path.read_text(encoding="utf-8",errors="replace").split()).strip()
            if title:
                return title[:40]
    except (AccessError,OSError,UnicodeError):
        pass
    first_user=next((
        " ".join(str(x.get("content","")).split()).strip()
        for x in history if x.get("role")=="user" and str(x.get("content","")).strip()
    ),"")
    return first_user[:40] or "Новый чат"


def _summary(chat_id: str, chat_dir: Path, history: list[dict]) -> dict:
    try:
        stamp = datetime.fromtimestamp(int(chat_id) / 1000).isoformat(timespec="minutes")
    except (ValueError, OSError, OverflowError):
        stamp = "неизвестно"
    last_user = next((str(x.get("content", "")) for x in reversed(history)
                      if x.get("role") == "user"), "")
    return {
        "chat_id": chat_id, "title": _chat_title(chat_dir,history), "date": stamp,
        "messages": len(history), "last_user_message": last_user[:140],
    }

def list_chats(users_root: str, uid: int, limit: int = 20) -> str:
    maximum = min(max(int(limit), 1), 150)
    result = []
    for chat_id, folder in _iter_chats(users_root, uid):
        history=_history(folder)
        result.append(_summary(chat_id, folder, history))
        if len(result) == maximum:
            break
    return json.dumps({"chats": result}, ensure_ascii=False)

def search_chats(users_root: str, uid: int, query: str, limit: int = 12) -> str:
    needle = str(query or "").casefold().strip()[:160]
    if len(needle) < 2:
        return "❌ Укажи поисковую фразу хотя бы из двух символов."
    maximum = min(max(int(limit), 1), 30)
    results = []
    for chat_id, folder in _iter_chats(users_root, uid):
        history = _history(folder)
        for index in range(len(history) - 1, -1, -1):
            item = history[index]
            content = str(item.get("content", ""))
            position = content.casefold().find(needle)
            if position < 0:
                continue
            begin = max(0, position - 100)
            fragment = content[begin:begin + 320].replace("\n", " ")
            results.append({
                "chat_id": chat_id,
                "title": _chat_title(folder,history),
                "message_number": index + 1,
                "role": item["role"], "excerpt": fragment,
            })
            if len(results) == maximum:
                return json.dumps({"query": query, "results": results}, ensure_ascii=False)
    return json.dumps({"query": query, "results": results}, ensure_ascii=False)

def read_chat(users_root: str, uid: int, chat_id: str, offset: int = 0, limit: int = 12) -> str:
    folder = _chat_dir(users_root, uid, chat_id)
    history = _history(folder)
    count = min(max(int(limit), 1), 30)
    start = max(0, len(history) - count - max(0, int(offset)))
    segment = history[start:start + count]
    messages = [
        {"number": start + index + 1, "role": item["role"],
         "content": str(item.get("content", ""))[:1300]}
        for index, item in enumerate(segment)
    ]
    return json.dumps({
        "chat_id": chat_id,
        "title": _chat_title(folder,history),
        "total_messages": len(history),
        "messages": messages,
    }, ensure_ascii=False)

def _chat_file(users_root: str, uid: int, chat_id: str, filename: str) -> Path:
    folder = _chat_dir(users_root, uid, chat_id)
    root = _inside(folder, folder / "files")
    name = str(filename or "")
    if not name or os.path.isabs(name) or "\x00" in name:
        raise AccessError("Некорректное имя файла.")
    full = _inside(root, root / name)
    if not full.is_file():
        raise AccessError("Файл не найден в выбранном чате.")
    return full

def list_chat_files(users_root: str, uid: int, chat_id: str) -> str:
    folder = _chat_dir(users_root, uid, chat_id)
    root = _inside(folder, folder / "files")
    items = []
    if root.is_dir():
        for entry in sorted(root.iterdir(), key=lambda p: p.name):
            try:
                full = _inside(root, entry)
                if full.is_file() and not entry.name.startswith("."):
                    items.append({"name": entry.name, "bytes": full.stat().st_size})
            except (AccessError, OSError):
                continue
            if len(items) >= 100:
                break
    history=_history(folder)
    return json.dumps({
        "chat_id": chat_id,
        "title": _chat_title(folder,history),
        "files": items,
    }, ensure_ascii=False)

def read_chat_file(users_root: str, uid: int, chat_id: str, filename: str) -> str:
    path = _chat_file(users_root, uid, chat_id, filename)
    if path.suffix.lower() not in SAFE_TEXT_EXTENSIONS:
        return "❌ Не текстовый файл. Для анализа медиа/документа скопируй файл в текущий чат и вызови analyze_file."
    if path.stat().st_size > MAX_FILE_READ_BYTES:
        return "❌ Файл слишком велик для прямого чтения. Используй копирование и поэтапный анализ."
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return "❌ Не удалось декодировать текст файла."
    folder=_chat_dir(users_root,uid,chat_id)
    history=_history(folder)
    return json.dumps({
        "chat_id": chat_id,
        "title": _chat_title(folder,history),
        "filename": filename,
        "content": text[:13000],
        "truncated": len(text) > 13000,
    }, ensure_ascii=False)
