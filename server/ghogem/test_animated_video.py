import json, os, subprocess, tempfile
from PIL import Image, ImageChops
import video_render

class DummyAI:
    MAX_CHAT_STORAGE_BYTES=100*1024*1024
    def __init__(self,root): self.root=root
    def _safe_path(self,user_id,chat_id,name):
        return os.path.join(self.root,name)
    def _storage_write_bytes(self,user_id,chat_id,path,data,**kwargs):
        with open(path,"wb") as f: f.write(data)
        return None

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360">{body}</svg>'

far=svg(
    '<rect width="640" height="360" fill="none"/>'
    '<rect x="0" y="110" width="90" height="120" fill="#73808f"/>'
    '<rect x="130" y="80" width="130" height="150" fill="#65717f"/>'
    '<rect x="310" y="120" width="110" height="110" fill="#7d8794"/>'
    '<rect x="470" y="70" width="150" height="160" fill="#596675"/>'
)
near=svg(
    '<rect width="640" height="360" fill="none"/>'
    '<rect x="20" y="170" width="170" height="100" fill="#333"/>'
    '<rect x="270" y="145" width="190" height="125" fill="#292929"/>'
    '<rect x="540" y="160" width="100" height="110" fill="#3a3a3a"/>'
)
road=svg(
    '<rect y="260" width="640" height="100" fill="#353535"/>'
    '<rect x="0" y="310" width="85" height="8" fill="#fff"/>'
    '<rect x="170" y="310" width="85" height="8" fill="#fff"/>'
    '<rect x="340" y="310" width="85" height="8" fill="#fff"/>'
    '<rect x="510" y="310" width="85" height="8" fill="#fff"/>'
)
car=svg(
    '<rect width="640" height="360" fill="none"/>'
    '<rect x="430" y="270" width="100" height="35" rx="8" fill="#d33"/>'
    '<circle cx="450" cy="308" r="10" fill="#111"/>'
    '<circle cx="510" cy="308" r="10" fill="#111"/>'
)

layers=[
    {"name":"far","svg":far,"z":1,"motion":{"velocity_x":-35,"repeat_x":True}},
    {"name":"near","svg":near,"z":2,"motion":{"velocity_x":-95,"repeat_x":True}},
    {"name":"road","svg":road,"z":3,"motion":{"velocity_x":-180,"repeat_x":True}},
    {"name":"car","svg":car,"z":4,"motion":{"keyframes":[
        {"t":0,"x":120,"y":0},{"t":1.5,"x":-20,"y":-2,"easing":"ease_in_out"},{"t":3,"x":70,"y":1}
    ]}},
]

with tempfile.TemporaryDirectory() as root:
    ai=DummyAI(root)
    out=video_render.generate_video(
        ai,1,"c",mode="animated",layers=layers,duration=3,
        background="#87CEEB",camera={"shake":2.0,"shake_frequency":2.4},
        filename="animated_city",width=640,height=360,fps=12,
    )
    print(json.dumps(out,ensure_ascii=False))
    assert not out.get("error"), out
    assert out["mode"]=="animated" and out["layers"]==4
    mp4=os.path.join(root,out["name"])
    frames=os.path.join(root,"frames")
    os.makedirs(frames)
    subprocess.check_call([
        "ffmpeg","-hide_banner","-loglevel","error","-i",mp4,
        "-vf","select=eq(n\\,0)+eq(n\\,18)+eq(n\\,35)","-vsync","0",
        os.path.join(frames,"%02d.png"),
    ])
    files=sorted(os.listdir(frames))
    assert len(files)>=3, files
    ims=[Image.open(os.path.join(frames,f)).convert("RGB") for f in files[:3]]
    assert ImageChops.difference(ims[0],ims[1]).getbbox() is not None
    assert ImageChops.difference(ims[1],ims[2]).getbbox() is not None
    probe=json.loads(subprocess.check_output([
        "ffprobe","-v","error","-select_streams","v:0",
        "-show_entries","stream=codec_name,width,height,r_frame_rate",
        "-show_entries","format=duration","-of","json",mp4
    ],text=True))
    assert probe["streams"][0]["codec_name"]=="h264"
    print("PASS animated motion video",probe)

print("PASS intent", __import__("ai").user_explicitly_requests_continuous_video_motion(
    "сделай видео как будто еду по городу"
))
