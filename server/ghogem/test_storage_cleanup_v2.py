"""Offline functional tests: no real user files, no Telegram API calls."""
import asyncio
from io import BytesIO
from pathlib import Path
import tempfile
from types import SimpleNamespace
import json

import bot
import ai
import storage_v2

class FakeMessage:
    def __init__(self, chat_id=12345):
        self.chat=SimpleNamespace(id=chat_id)
        self.message_id=300
        self.replies=[]
    async def edit_text(self,text,reply_markup=None,parse_mode=None):
        self.replies.append((text,reply_markup))
    async def answer(self,text,reply_markup=None,parse_mode=None):
        self.replies.append((text,reply_markup))

class FakeQuery:
    def __init__(self,data,owner=12345,chat_id=12345):
        self.data=data
        self.from_user=SimpleNamespace(id=owner)
        self.message=FakeMessage(chat_id)
        self.acks=[]
    async def answer(self,text="",show_alert=False):
        self.acks.append((text,show_alert))

async def main():
    original_root=ai.USERS_DIR
    original_current=ai.get_current_chat
    original_limits=ai.storage_limits_for_user
    with tempfile.TemporaryDirectory(prefix="ghogem-clean-v2-") as root:
        ai.USERS_DIR=root
        ai.get_current_chat=lambda uid: "1740000000000"
        ai.storage_limits_for_user=lambda uid:{
            "chat_limit":ai.FREE_CHAT_STORAGE_BYTES,
            "shared_limit":ai.FREE_SHARED_STORAGE_BYTES,
            "user_limit":ai.FREE_USER_STORAGE_BYTES
        }
        try:
            uid=12345
            chat=ai.get_current_chat(uid)
            assert ai.save_user_file(uid,chat,"plan.txt",b"main task") is not None
            main=Path(ai._safe_path(uid,chat,"plan.txt"))
            image=__import__('PIL.Image',fromlist=['Image']).new("RGB",(8,8),"red")
            payload=BytesIO()
            image.save(payload,format="PNG")
            saved=storage_v2.save_temporary(
                root,uid,"photo.png",payload.getvalue(),
                area="buffer",premium=False,urgent=True,
            )
            # buffer arbitrary binary input is valid if named as a document
            assert Path(storage_v2.temp_path(root,uid,saved["name"],"buffer")).is_file()
            panel=bot.storage_overview(uid)
            assert "Управление памятью" in panel and "Постоянные файлы" in panel
            text,kb=bot._storage_list_panel(uid,uid,"main",0)
            assert len(kb.inline_keyboard)>=2
            askdata=kb.inline_keyboard[0][0].callback_data
            assert askdata.startswith("storage:ask:")
            token=askdata.rsplit(":",1)[-1]
            bad=FakeQuery(askdata,owner=87654)
            await bot.cb_storage_ask(bad)
            assert bad.acks[-1][1] is True
            assert main.exists()
            q=FakeQuery(askdata)
            await bot.cb_storage_ask(q)
            assert "Подтвердить удаление" in q.message.replies[-1][0]
            assert main.exists(), "ask must not delete"
            conf=FakeQuery("storage:confirm:"+token)
            await bot.cb_storage_confirm(conf)
            assert not main.exists()
            assert "Освобождено" in conf.message.replies[-1][0]
            again=FakeQuery("storage:confirm:"+token)
            await bot.cb_storage_confirm(again)
            assert again.acks[-1][1] is True
            print("PASS: owner-only two-click one-time confirmed main file delete")
            # Version binding: a new write to the same filename must not be
            # deleted with approval of the previous version.
            assert ai.save_user_file(uid,chat,"new-version.txt",b"VERSION 1")
            _,version_kb=bot._storage_list_panel(uid,uid,"main",0)
            version_tok=version_kb.inline_keyboard[0][0].callback_data.rsplit(":",1)[-1]
            version_path=Path(ai._safe_path(uid,chat,"new-version.txt"))
            version_path.write_bytes(b"VERSION 2")
            rejected=FakeQuery("storage:confirm:"+version_tok)
            await bot.cb_storage_confirm(rejected)
            assert version_path.read_bytes()==b"VERSION 2"
            assert "изменился" in rejected.message.replies[-1][0]
            print("PASS: modified/replaced permanent file cannot be deleted with stale approval")
            _,kb=bot._storage_list_panel(uid,uid,"buffer",0)
            tok=kb.inline_keyboard[0][0].callback_data.rsplit(":",1)[-1]
            buf_path=Path(storage_v2.temp_path(root,uid,saved["name"],"buffer"))
            assert buf_path.is_file()
            q=FakeQuery("storage:confirm:"+tok)
            await bot.cb_storage_confirm(q)
            assert not buf_path.exists()
            data=storage_v2.list_temporary(root,uid,area="buffer",premium=False)
            assert len(data["files"])==0
            print("PASS: temporary buffer deletion and quota reclamation")
            other_uid=87654
            otherlist=bot._storage_items(other_uid,"buffer")
            assert otherlist==[]
            print("PASS: deleting current user cannot affect another sandbox")
        finally:
            ai.USERS_DIR=original_root
            ai.get_current_chat=original_current
            ai.storage_limits_for_user=original_limits

asyncio.run(main())
