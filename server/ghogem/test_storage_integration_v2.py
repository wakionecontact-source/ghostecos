"""Isolated integration tests: no real user data, network, or production writes."""
import asyncio
from io import BytesIO
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from PIL import Image
from fastapi import HTTPException
from starlette.datastructures import UploadFile

import ai
import storage_v2
import web_api

async def main():
    original_dir = ai.USERS_DIR
    old_chat = ai.get_current_chat
    old_limits = ai.storage_limits_for_user
    with TemporaryDirectory(prefix="ghogem-v2-qa-") as td:
        ai.USERS_DIR = td
        ai.get_current_chat = lambda uid: "1740000000000"
        ai.storage_limits_for_user = lambda uid: {
            "chat_limit": ai.FREE_CHAT_STORAGE_BYTES,
            "shared_limit": ai.FREE_SHARED_STORAGE_BYTES,
            "user_limit": ai.FREE_USER_STORAGE_BYTES,
        }
        uid, other = 987654123, 987654124
        ident = SimpleNamespace(uid=uid)
        img = Image.new("RGBA", (350, 350), (255, 0, 0, 0))
        img.putpixel((125, 125), (25, 100, 200, 100))
        data = BytesIO()
        img.save(data, format="PNG")
        try:
            # The same HTTP upload method as the GhostID-based frontend uses.
            pic = UploadFile(filename="transparent.png", file=BytesIO(data.getvalue()))
            uploaded = await web_api.files_upload(file=pic, ident=ident)
            assert uploaded["area"] == "media", uploaded
            assert uploaded["expires_at"] - __import__("time").time() > 2.9 * 86400
            assert uploaded["name"] != "transparent.png"
            assert ai.list_files(uid) == [], ai.list_files(uid)
            path = ai.resolve_user_upload(uid, ai.get_current_chat(uid), uploaded["name"])
            assert Path(path).is_file()
            from PIL import Image as Img
            with Img.open(path) as stored:
                assert stored.convert("RGBA").getpixel((125,125))[3] == 100
            indexed = web_api.files(ident=ident)
            assert any(i["name"] == uploaded["name"] and i["area"] == "media" for i in indexed["files"])
            assert web_api.files_raw(name=uploaded["name"], ident=ident).body
            print("PASS: web upload -> shared media -> compression transparency + list + raw + TTL")
            # A second account's resolved identity cannot access this media.
            try:
                web_api.files_raw(name=uploaded["name"], ident=SimpleNamespace(uid=other))
                raise AssertionError("cross-account file leak")
            except HTTPException as exc:
                assert exc.status_code == 404
            print("PASS: GhostID owner boundary for media GET")
            # Ordinary files are still stored in the chat directory.
            doc = UploadFile(filename="notes.txt", file=BytesIO(b"legacy-like document"))
            response = await web_api.files_upload(file=doc, ident=ident)
            assert response["area"] == "main", response
            assert "notes.txt" in ai.list_files(uid)
            assert web_api.files_raw(name="notes.txt", ident=ident).body == b"legacy-like document"
            print("PASS: ordinary documents stay in main; legacy URLs remain valid")
            # Explicit urgent buffer, visible from all the user's chats.
            urgent = UploadFile(filename="urgent.txt", file=BytesIO(b"critical assignment"))
            buffered = await web_api.files_upload(file=urgent, storage_area="buffer", urgent=True, ident=ident)
            assert buffered["area"] == "buffer"
            assert buffered["expires_at"] - __import__("time").time() < 86401
            assert Path(ai.resolve_user_upload(uid, "1740000000001", buffered["name"])).read_bytes() == b"critical assignment"
            status = web_api.storage_stats(ident=ident)
            assert len(status["media"]["files"]) == 1 and len(status["buffer"]["files"]) == 1
            print("PASS: emergency buffer 1-day TTL, cross-chat visibility and storage status")
            # Old user media files remain where they already were.
            old_path = Path(ai._safe_path(uid, ai.get_current_chat(uid), "old-image.png"))
            old_path.write_bytes(b"legacy-file")
            assert ai.resolve_user_upload(uid, ai.get_current_chat(uid), "old-image.png") == str(old_path)
            print("PASS: backwards compatibility with pre-V2 media in chat files")
            # Expired file cannot be retrieved, even before background cleanup.
            manifest = Path(td) / str(uid) / "temporary_storage_v2.json"
            metadata = json.loads(manifest.read_text())
            metadata["media"][uploaded["name"]]["expires_at"] = 1
            metadata["media"][uploaded["name"]]["lease_until"] = 0
            manifest.write_text(json.dumps(metadata))
            try:
                web_api.files_raw(name=uploaded["name"], ident=ident)
                raise AssertionError("expired media still readable")
            except HTTPException as exc:
                assert exc.status_code == 404
            assert storage_v2.cleanup_expired(td, uid)["media"] == 1
            print("PASS: expired media instantly denied and physically deleted on cleanup")
        finally:
            ai.USERS_DIR = original_dir
            ai.get_current_chat = old_chat
            ai.storage_limits_for_user = old_limits

asyncio.run(main())
