import os, tempfile, json, subprocess
import video_render

class DummyAI:
    MAX_CHAT_STORAGE_BYTES = 50 * 1024 * 1024
    def __init__(self, root):
        self.root=root
    def _safe_path(self, user_id, chat_id, name):
        p=os.path.join(self.root,name)
        os.makedirs(os.path.dirname(p),exist_ok=True)
        return p
    def _storage_write_bytes(self,user_id,chat_id,path,data,**kwargs):
        with open(path,"wb") as f: f.write(data)
        return None

svg1='''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360"><rect width="640" height="360" fill="#111"/><text x="320" y="190" text-anchor="middle" fill="white" font-size="54" font-family="sans-serif">Scene 1</text></svg>'''
svg2='''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360"><rect width="640" height="360" fill="#ddd"/><circle cx="320" cy="180" r="90" fill="#333"/><text x="320" y="195" text-anchor="middle" fill="white" font-size="42" font-family="sans-serif">Scene 2</text></svg>'''

with tempfile.TemporaryDirectory() as root:
    ai=DummyAI(root)
    out=video_render.generate_video(
        ai,1,"c",
        scenes=[
            {"svg":svg1,"duration":1.2},
            {"svg":svg2,"duration":1.2,"transition":"slideleft","transition_duration":0.3},
        ],
        filename="video_test",width=640,height=360,fps=24,
    )
    print(json.dumps(out,ensure_ascii=False))
    assert not out.get("error"), out
    mp4=os.path.join(root,out["name"])
    src=os.path.join(root,out["source_name"])
    assert os.path.isfile(mp4) and os.path.getsize(mp4)>1000
    assert os.path.isfile(src)
    probe=subprocess.check_output([
        "ffprobe","-v","error","-select_streams","v:0",
        "-show_entries","stream=codec_name,width,height,pix_fmt",
        "-show_entries","format=duration",
        "-of","json",mp4
    ],text=True)
    print(probe)
    data=json.loads(probe)
    assert data["streams"][0]["codec_name"]=="h264"
    assert data["streams"][0]["width"]==640
    assert data["streams"][0]["height"]==360
    print("PASS video renderer")
