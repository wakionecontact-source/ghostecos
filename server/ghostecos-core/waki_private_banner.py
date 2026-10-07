from pathlib import Path
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, FileResponse
from starlette.concurrency import run_in_threadpool
from ecos_core.identity import auth

router = APIRouter()
BASE = Path("/opt/ghostecos-core/private/wakiss-banner")
AVATAR = BASE / "avatar.webp"
NOT_FOUND = Path("/opt/ghostchat/site/404.html")

def _headers():
    return {
        "Cache-Control": "private, no-store, no-cache, max-age=0",
        "Pragma": "no-cache",
        "X-Robots-Tag": "noindex, nofollow,noarchive",
        "Content-Security-Policy": "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
    }

async def _owner(request: Request) -> bool:
    authorization = request.headers.get("authorization", "").strip()
    if not authorization:
        token = request.cookies.get("gs_token", "").strip()
        authorization = "Bearer " + token if token else ""
    if not authorization or len(authorization) > 8192:
        return False
    try:
        user = await run_in_threadpool(auth, authorization)
        return int(user.get("id") or 0) == 2 and not bool(user.get("is_guest"))
    except Exception:
        return False

def _404():
    try:
        html = NOT_FOUND.read_text(encoding="utf-8")
    except OSError:
        html = "<!doctype html><meta charset=utf-8><title>404</title><h1>404</h1>"
    return HTMLResponse(html, status_code=404, headers=_headers())

PAGE = r"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#2d0b73">
<title>GhostEcos Banner · @waki</title>
<style>
*{box-sizing:border-box}html,body{margin:0;min-height:100%;font-family:Inter,Arial,sans-serif;background:#120822;color:#fff}
body{display:grid;place-items:center;padding:24px}
.app{width:min(1180px,100%);display:grid;gap:18px}
.top{display:flex;justify-content:space-between;align-items:end;gap:16px}
h1{margin:0;font-size:clamp(28px,5vw,54px);letter-spacing:-.05em}
.sub{color:#bca9ea;font-size:14px}
.stage{background:#201039;border:1px solid #ffffff14;border-radius:28px;padding:16px;box-shadow:0 24px 80px #0008}
canvas{display:block;width:100%;height:auto;aspect-ratio:8/3;border-radius:20px;background:#351180}
.controls{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
.control{background:#201039;border:1px solid #ffffff12;border-radius:18px;padding:12px 14px;display:grid;gap:8px}
label{font-size:12px;color:#bca9ea}input[type=range]{width:100%;accent-color:#a875ff}
.actions{display:flex;gap:10px;flex-wrap:wrap}
button,a.btn{border:0;border-radius:16px;padding:13px 18px;font-weight:800;font-size:14px;text-decoration:none;cursor:pointer}
.primary{background:#fff;color:#351180}.ghost{background:#ffffff10;color:#fff;border:1px solid #ffffff18}
@media(max-width:760px){body{padding:12px}.controls{grid-template-columns:1fr 1fr}.stage{border-radius:20px;padding:10px}}
</style></head><body>
<main class="app">
<div class="top"><div><div class="sub">Личный генератор баннера</div><h1>GhostEcos</h1></div><div class="sub">1600 × 600 PNG</div></div>
<div class="stage"><canvas id="c" width="1600" height="600"></canvas></div>
<div class="controls">
<div class="control"><label>Размер аватарки</label><input id="size" type="range" min="210" max="430" value="330"></div>
<div class="control"><label>Наклон</label><input id="rot" type="range" min="-18" max="18" value="-8"></div>
<div class="control"><label>Положение аватарки X</label><input id="ax" type="range" min="180" max="620" value="390"></div>
<div class="control"><label>Размер названия</label><input id="font" type="range" min="110" max="240" value="182"></div>
</div>
<div class="actions"><button id="download" class="primary">Скачать PNG</button><button id="reset" class="ghost">Сбросить</button><a class="btn ghost" href="/home">На главную</a></div>
</main>
<script>
const c=document.getElementById('c'),ctx=c.getContext('2d');
const img=new Image(),avatarCanvas=document.createElement('canvas'),avatarCtx=avatarCanvas.getContext('2d',{willReadFrequently:true});img.src='/wakiss/banner/avatar.webp';
const els={size:document.getElementById('size'),rot:document.getElementById('rot'),ax:document.getElementById('ax'),font:document.getElementById('font')};
const defaults={size:330,rot:-8,ax:390,font:182};
function rr(x,y,w,h,r){ctx.beginPath();ctx.roundRect(x,y,w,h,r)}
function prepareAvatar(){
 avatarCanvas.width=img.naturalWidth;avatarCanvas.height=img.naturalHeight;avatarCtx.drawImage(img,0,0);
 const d=avatarCtx.getImageData(0,0,avatarCanvas.width,avatarCanvas.height),p=d.data;
 for(let i=0;i<p.length;i+=4){
   const r=p[i],g=p[i+1],b=p[i+2];
   const whiteness=Math.max(0,Math.min(1,(Math.min(r,g,b)-105)/130));
   const neutral=1-Math.min(1,(Math.max(r,g,b)-Math.min(r,g,b))/95);
   const a=Math.pow(whiteness*neutral,.7);
   p[i]=255;p[i+1]=255;p[i+2]=255;p[i+3]=Math.round(a*255);
 }
 avatarCtx.putImageData(d,0,0);
}
function draw(){
 const W=c.width,H=c.height;
 const g=ctx.createLinearGradient(0,0,W,H);g.addColorStop(0,'#34117f');g.addColorStop(1,'#260766');ctx.fillStyle=g;ctx.fillRect(0,0,W,H);
 ctx.save();ctx.globalAlpha=.17;ctx.fillStyle='#d0adff';
 ctx.beginPath();ctx.moveTo(760,-80);
 ctx.bezierCurveTo(930,-45,1120,-95,1290,-20);
 ctx.bezierCurveTo(1510,78,1690,210,1685,375);
 ctx.bezierCurveTo(1680,535,1490,665,1280,650);
 ctx.bezierCurveTo(1090,638,930,572,845,455);
 ctx.bezierCurveTo(760,337,690,230,705,120);
 ctx.bezierCurveTo(715,44,728,-28,760,-80);ctx.closePath();ctx.fill();ctx.restore();
 ctx.save();ctx.globalAlpha=.055;ctx.fillStyle='#fff';ctx.beginPath();ctx.ellipse(1535,105,330,205,-.28,0,Math.PI*2);ctx.fill();ctx.restore();
 const s=+els.size.value,x=+els.ax.value,y=H/2;
 ctx.save();ctx.translate(x,y);ctx.rotate(+els.rot.value*Math.PI/180);
 ctx.shadowColor='#12002f66';ctx.shadowBlur=34;ctx.shadowOffsetY=18;ctx.drawImage(avatarCanvas,-s/2,-s/2,s,s);ctx.restore();
 const fs=+els.font.value;ctx.textBaseline='middle';ctx.font='900 '+fs+'px Inter,Arial,sans-serif';
 const tx=Math.max(690,x+s/2+120);ctx.fillStyle='#fff';ctx.fillText('Ghost',tx,H/2);
 const gw=ctx.measureText('Ghost').width;ctx.fillStyle='#c9a8ff';ctx.fillText('Ecos',tx+gw-2,H/2);
}
img.onload=()=>{prepareAvatar();draw()};Object.values(els).forEach(e=>e.addEventListener('input',draw));
document.getElementById('reset').onclick=()=>{for(const k in defaults)els[k].value=defaults[k];draw()};
document.getElementById('download').onclick=()=>{draw();const a=document.createElement('a');a.download='GhostEcos-banner.png';a.href=c.toDataURL('image/png');a.click()};
</script></body></html>"""

@router.get("/wakiss/banner", include_in_schema=False)
@router.get("/wakiss/banner/", include_in_schema=False)
async def banner_page(request: Request):
    if not await _owner(request):
        return _404()
    try:
        page = (BASE / "editor.html").read_text(encoding="utf-8")
    except OSError:
        return _404()
    return HTMLResponse(page, headers=_headers())

@router.get("/wakiss/banner/editor.css", include_in_schema=False)
async def banner_css(request: Request):
    path = BASE / "editor.css"
    if not await _owner(request) or not path.exists():
        return _404()
    return FileResponse(path, media_type="text/css", headers=_headers())

@router.get("/wakiss/banner/editor.js", include_in_schema=False)
async def banner_js(request: Request):
    path = BASE / "editor.js"
    if not await _owner(request) or not path.exists():
        return _404()
    return FileResponse(path, media_type="application/javascript", headers=_headers())

@router.get("/wakiss/banner/avatar.webp", include_in_schema=False)
async def banner_avatar(request: Request):
    if not await _owner(request) or not AVATAR.exists():
        return _404()
    return FileResponse(AVATAR, media_type="image/webp", headers=_headers())
