import asyncio, os, tempfile
from types import SimpleNamespace
from collections import deque
import bot as b

class FakeMessage:
    def __init__(self):
        self.chat=SimpleNamespace(id=321)
        self.edits=[]
    async def edit_text(self,text,**kwargs):
        self.edits.append((text,kwargs))

class FakeQuery:
    def __init__(self,data,uid):
        self.data=data
        self.from_user=SimpleNamespace(id=uid)
        self.message=FakeMessage()
        self.answers=[]
    async def answer(self,text=None,**kwargs):
        self.answers.append((text,kwargs))

async def main():
    uid=99887766
    old_db=b.model_ratings.DB_PATH
    old_submit=b.submit_prompt
    fd,path=tempfile.mkstemp(prefix="ratings-resume-",suffix=".db")
    os.close(fd)
    os.unlink(path)
    b.model_ratings.DB_PATH=path
    b.model_ratings._init()
    calls=[]
    async def fake_submit(user_id,chat_id,prompt,notify_message,*,attachment_name="",ai_chat_id_override=""):
        calls.append((user_id,chat_id,prompt,attachment_name,ai_chat_id_override))
    b.submit_prompt=fake_submit
    try:
        token=b.model_ratings.create_response(
            uid,321,"chat-a","ans-a","openrouter:space-bunny-alpha",True
        )
        b.rating_blocked_prompts[uid]=deque([
            b.QueuedRequest(uid,321,"второй промт",None,attachment_name="x.jpg",ai_chat_id="chat-a"),
        ])
        q=FakeQuery(f"rating:score:{token}:5",uid)
        await b.cb_rating_score(q)
        await asyncio.sleep(0.05)
        assert calls==[(uid,321,"второй промт","x.jpg","chat-a")],calls
        assert uid not in b.rating_blocked_prompts
        print("PASS blocked prompt resumes automatically after rating")
    finally:
        b.submit_prompt=old_submit
        b.model_ratings.DB_PATH=old_db
        b.rating_blocked_prompts.pop(uid,None)
        try: os.unlink(path)
        except OSError: pass

asyncio.run(main())
