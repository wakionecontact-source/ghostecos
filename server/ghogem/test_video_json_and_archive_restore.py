import os, json, tempfile
import ai

prompt="слушай, а сделай видео как будто еду по городу"
assert ai.user_explicitly_requests_video_generation(prompt)

svg1='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180"><rect width="320" height="180" fill="#111"/></svg>'
svg2='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180"><rect width="320" height="180" fill="#eee"/></svg>'
raw='''\```json
{"scenes":[{"svg":''' + json.dumps(svg1) + ''',"duration":1.0},{"svg":''' + json.dumps(svg2) + ''',"duration":1.0,"transition":"fade","transition_duration":0.2}],"width":320,"height":180,"fps":12}
\```'''
payload=ai._recover_generate_video_payload(raw)
assert payload and len(payload["scenes"])==2, payload
assert payload["width"]==320 and payload["height"]==180 and payload["fps"]==12
assert ai._recover_generate_video_payload('{"hello":"world"}') is None
print("PASS video JSON recovery")

old_users=ai.USERS_DIR
old_current=dict(ai.user_current_chat)
try:
    with tempfile.TemporaryDirectory() as root:
        ai.USERS_DIR=root
        uid=999991
        chats=os.path.join(root,str(uid),"chats")
        os.makedirs(chats)
        current="1791104000001"
        target="1791104000002"
        os.makedirs(os.path.join(chats,current))
        tdir=os.path.join(chats,target)
        os.makedirs(os.path.join(tdir,"files"))
        open(os.path.join(tdir,"title.txt"),"w").write("Тестовый чат")
        json.dump([{"role":"user","content":"hello"}],open(os.path.join(tdir,"history.json"),"w"))
        open(os.path.join(tdir,"files","a.txt"),"w").write("data")
        ai.user_current_chat[uid]=current
        assert ai.archive_chat(uid,target)=="archived"
        assert not os.path.isdir(tdir)
        archived=ai.list_archived_chats(uid)
        assert archived and archived[0]["id"]==target
        assert ai.restore_archived_chat(uid,target)=="restored"
        assert os.path.isfile(os.path.join(tdir,"history.json"))
        assert os.path.isfile(os.path.join(tdir,"files","a.txt"))
        assert not os.path.exists(os.path.join(tdir,".archive.json"))
        print("PASS archive restore")
finally:
    ai.USERS_DIR=old_users
    ai.user_current_chat.clear(); ai.user_current_chat.update(old_current)
