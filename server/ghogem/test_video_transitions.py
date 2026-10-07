import os, tempfile
import video_render

class DummyAI:
    MAX_CHAT_STORAGE_BYTES=50*1024*1024
    def __init__(self,root): self.root=root
    def _safe_path(self,user_id,chat_id,name): return os.path.join(self.root,name)
    def _storage_write_bytes(self,user_id,chat_id,path,data,**kwargs):
        with open(path,"wb") as f: f.write(data)
        return None

a='<svg xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%" fill="#111"/></svg>'
b='<svg xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%" fill="#eee"/></svg>'
transitions=["fade","cut","dissolve","wipeleft","wiperight","wipeup","wipedown","slideleft","slideright","slideup","slidedown","zoomin","fadeblack","fadewhite"]
with tempfile.TemporaryDirectory() as root:
    ai=DummyAI(root)
    for t in transitions:
        out=video_render.generate_video(ai,1,"c",scenes=[
            {"svg":a,"duration":0.5},
            {"svg":b,"duration":0.5,"transition":t,"transition_duration":0.1},
        ],filename="t_"+t,width=320,height=180,fps=12)
        assert not out.get("error"), (t,out)
        print("ok",t,out["duration"])
print("PASS all video transitions")
