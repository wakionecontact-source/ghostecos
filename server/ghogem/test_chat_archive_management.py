import asyncio, json, os, shutil
from types import SimpleNamespace

import ai
import bot as b

UID=999999981
TG=777001
root=os.path.join(ai.USERS_DIR,str(UID))
shutil.rmtree(root,ignore_errors=True)
os.makedirs(os.path.join(root,"chats"),exist_ok=True)
old_id="1702000000000"
current_id="1702000000001"
for cid in (old_id,current_id):
    os.makedirs(os.path.join(root,"chats",cid,"files"),exist_ok=True)
    with open(os.path.join(root,"chats",cid,"title.txt"),"w",encoding="utf-8") as f:
        f.write("Old chat" if cid==old_id else "Current chat")
ai.user_current_chat[UID]=current_id

class FakeBot:
    def __init__(self):
        self.sent=[]
    async def send_message(self,chat_id,text,**kwargs):
        msg=SimpleNamespace(message_id=900,chat=SimpleNamespace(id=chat_id),text=text)
        self.sent.append((chat_id,text,kwargs,msg))
        return msg

class FakeMessage:
    def __init__(self):
        self.chat=SimpleNamespace(id=TG)
        self.edits=[]
    async def edit_text(self,text,**kwargs):
        self.edits.append((text,kwargs))

class FakeQuery:
    def __init__(self,data,uid=UID):
        self.data=data
        self.from_user=SimpleNamespace(id=uid)
        self.message=FakeMessage()
        self.answers=[]
    async def answer(self,text=None,**kwargs):
        self.answers.append((text,kwargs))

async def main():
    original_bot=b.bot
    fake=FakeBot()
    b.bot=fake
    try:
        raw=await b.propose_ai_chat_management(
            UID,TG,current_id,
            {"action":"archive","location":"active","chat_id":old_id,"reason":"старый чат"},
        )
        data=json.loads(raw)
        assert data["status"]=="awaiting_user_confirmation"
        assert os.path.isdir(os.path.join(root,"chats",old_id))
        assert not os.path.isdir(os.path.join(root,"archive",old_id))
        token=next(reversed(b.chat_management_tokens))
        q=FakeQuery(f"ai_chat_manage:confirm:{token}")
        await b.cb_ai_chat_manage(q)
        assert not os.path.isdir(os.path.join(root,"chats",old_id))
        assert os.path.isdir(os.path.join(root,"archive",old_id))
        assert q.answers[-1][0]=="Готово"
        print("PASS AI chat management requires Telegram confirmation")
    finally:
        b.bot=original_bot

asyncio.run(main())
ai.user_current_chat.pop(UID,None)
shutil.rmtree(root,ignore_errors=True)
