import os
import tempfile
import zipfile
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from starlette.concurrency import run_in_threadpool

from ecos_core.identity import auth

router = APIRouter()
PRIVATE_DIR = "/opt/ghostecos-core/private/waki-app"
APK_PATH = os.path.join(PRIVATE_DIR, "GhostEcos-smoke-test-arm64.apk")
NOT_FOUND_PATH = "/opt/ghostchat/site/404.html"
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
APK_MIME = "application/vnd.android.package-archive"

V2_STYLE = """<link rel="stylesheet" href="/ghostecos-ui.css?v=16e816f327c9">
<style>
html,body{min-height:100%;margin:0;overflow-x:hidden;overscroll-behavior-y:auto}
body{background:var(--bg);color:var(--text);font:16px/1.5 Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif}
.apk-app{min-height:100svh;background:var(--bg)}
.apk-screen.active{position:relative;inset:auto;min-height:100svh;min-height:100dvh;height:auto;overflow:visible;grid-template-rows:auto minmax(0,1fr) auto;padding:max(20px,env(safe-area-inset-top)) max(24px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(24px,env(safe-area-inset-left));opacity:1;transform:none;visibility:visible;pointer-events:auto}
.apk-screen .topbar,.apk-screen .bottom{width:min(100%,1120px)}
.apk-screen .button{text-decoration:none}
.apk-screen .body{width:min(100%,1080px);min-height:0;margin:auto;padding:32px 0}
.apk-status{display:grid;grid-template-columns:42px minmax(0,1fr);align-items:center;gap:12px;width:min(100%,560px);margin-top:24px;padding:16px;border-radius:16px;background:var(--panel);box-shadow:var(--label-depth)}
.apk-status-icon{display:grid;place-items:center;width:42px;height:42px;border-radius:12px;background:var(--mini-bg);color:var(--mini-ink)}
.apk-status-icon svg{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.apk-status-copy{display:grid;gap:4px;min-width:0}
.apk-status-copy strong{font-size:14px;font-weight:700}
.apk-status-copy span{color:var(--muted);font-size:13px;line-height:1.4}
.apk-form{display:grid;grid-template-columns:1fr 1fr;gap:9px;width:min(100%,560px);margin-top:16px}
.apk-form input[type=file]{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}
.apk-form .button{width:100%}
.apk-form .button:disabled{opacity:.42;cursor:not-allowed}
.apk-file-name{grid-column:1/-1;min-width:0;overflow:hidden;color:var(--muted);font-size:12px;text-overflow:ellipsis;white-space:nowrap}
.apk-message{width:min(100%,560px);min-height:20px;margin:10px 0 0;color:var(--lavender);font-size:13px}
.apk-note{width:min(100%,560px);margin:8px 0 0!important;color:var(--muted)!important;font-size:12px!important;line-height:1.45!important}
.apk-screen .bottom{gap:16px}
.apk-screen .controls{display:flex;justify-content:flex-end;gap:9px}
@media(max-width:720px){
  .apk-screen.active{padding:max(20px,env(safe-area-inset-top)) max(20px,env(safe-area-inset-right)) max(20px,env(safe-area-inset-bottom)) max(20px,env(safe-area-inset-left))}
  .apk-screen .body{width:100%;padding:34px 0 48px}
  .apk-status,.apk-form,.apk-message,.apk-note{width:100%}
  .apk-status{margin-top:20px;padding:13px;border-radius:15px}
  .apk-screen .bottom{align-items:stretch}
  .apk-screen .controls{display:grid;width:100%;grid-template-columns:1fr 1fr}
}
@media(prefers-reduced-motion:reduce){.apk-screen .enter{animation:none!important}}
</style>"""

THEME_HEAD = """<script>
(() => {
  let theme;
  try { theme = localStorage.getItem("ghostecos-theme"); } catch {}
  if (theme !== "dark" && theme !== "purple") {
    try { theme = (document.cookie.match(/(?:^|;\\s*)ghostecos-theme=(dark|purple)(?:;|$)/) || [])[1]; } catch {}
  }
  document.documentElement.dataset.theme = theme === "dark" ? "dark" : "purple";
  if (theme === "dark") document.querySelector('meta[name="theme-color"]').content = "#130d20";
})();
</script>"""

THEME_TOGGLE = """<script>
document.getElementById("theme-toggle").addEventListener("click", () => {
  const next = document.documentElement.dataset.theme === "dark" ? "purple" : "dark";
  document.documentElement.dataset.theme = next;
  document.querySelector('meta[name="theme-color"]').content = next === "dark" ? "#130d20" : "#351180";
  try { localStorage.setItem("ghostecos-theme", next); } catch {}
  document.cookie = "ghostecos-theme=" + next + "; Path=/; Max-Age=31536000; SameSite=Lax; Secure";
});
</script>"""

OWNER_PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#351180"><meta name="robots" content="noindex,nofollow,noarchive">
<title>Личная сборка · GhostEcos</title>__THEME_HEAD____STYLE__</head>
<body>
__SPRITE__
<main class="app apk-app">
<section class="screen screen--welcome screen--apk active" aria-labelledby="apk-title">
<header class="topbar">
<div class="brand">Ghost<em>Ecos</em></div>
<span class="step-label">Закрытая сборка · @waki</span>
<button class="theme-toggle" id="theme-toggle" type="button" aria-label="Сменить тему" title="Сменить тему">
<svg class="theme-moon" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M20.5 14.4A8.5 8.5 0 0 1 9.6 3.5 8.5 8.5 0 1 0 20.5 14.4Z"/></svg>
<svg class="theme-sun" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.5 1.5m11.2 11.2 1.5 1.5M19.1 4.9l-1.5 1.5M6.4 17.6l-1.5 1.5"/></svg>
</button>
</header>
<div class="body">
<div class="welcome-layout">
<div>
<h1 class="enter" id="apk-title" style="--delay:.08s" tabindex="-1">Закрытая<br><em>сборка.</em></h1>
<p class="enter" style="--delay:.2s">Тестовое приложение GhostEcos для Android · arm64.</p>
<div class="apk-status enter" style="--delay:.28s">
<span class="apk-status-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="6" y="2.5" width="12" height="19" rx="2.4"/><path d="M10 5h4m-3 13h2"/></svg></span>
<div class="apk-status-copy"><strong>Текущая сборка</strong><span id="apk-state">__STATUS__</span></div>
</div>
<form class="apk-form enter" id="upload-form" style="--delay:.36s">
<input id="apk-file" type="file" accept=".apk,application/vnd.android.package-archive">
<label class="button ghost" for="apk-file">Выбрать APK</label>
<button id="upload-button" class="button primary" type="submit" disabled>Загрузить APK</button>
<span class="apk-file-name" id="file-name">Файл не выбран</span>
</form>
<p id="upload-status" class="apk-message" role="status" aria-live="polite"></p>
<p class="apk-note">Файл до 64 МБ. Новая загрузка заменит предыдущий APK.</p>
</div>
<div class="welcome-label enter" style="--delay:.28s" aria-hidden="true">
<span class="welcome-symbol"><svg viewBox="0 0 24 24"><path d="M12 1 14.4 9.6 23 12l-8.6 2.4L12 23l-2.4-8.6L1 12l8.6-2.4Z"/></svg></span>
<svg viewBox="352 322 832 918"><use href="#g-full"></use></svg>
</div>
</div>
</div>
<footer class="bottom">
<div class="controls">
<a class="button ghost" href="/home">На главную</a>
__DOWNLOAD__
</div>
</footer>
</section>
</main>
__THEME_TOGGLE__
<script>
const form=document.getElementById("upload-form"),input=document.getElementById("apk-file"),nameNode=document.getElementById("file-name"),statusNode=document.getElementById("upload-status"),button=document.getElementById("upload-button");
input.addEventListener("change",()=>{const file=input.files[0];nameNode.textContent=file?.name||"Файл не выбран";button.disabled=!file});
form.addEventListener("submit",async event=>{event.preventDefault();const file=input.files[0];if(!file){statusNode.textContent="Сначала выбери APK.";return}
if(!file.name.toLowerCase().endsWith(".apk")){statusNode.textContent="Нужен файл с расширением .apk.";return}
if(file.size>67108864){statusNode.textContent="Максимальный размер — 64 МБ.";return}
button.disabled=true;statusNode.textContent="Загружаю…";
try{const response=await fetch("/waki-app/upload",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/vnd.android.package-archive","X-Requested-With":"fetch"},body:file});
const result=await response.json().catch(()=>({detail:"Запрос отклонён"}));if(!response.ok)throw new Error(result.detail||"Не удалось загрузить APK");window.location.reload()
}catch(error){statusNode.textContent=error.message||"Ошибка загрузки"}finally{button.disabled=false}});
</script></body></html>"""

def _welcome_sprite() -> str:
    source_path = Path("/var/www/ghostecos-v2/index.html")
    try:
        source = source_path.read_text(encoding="utf-8")
        start = source.find('<svg class="sprite"')
        end = source.find("</svg>", start)
        if start >= 0 and end >= 0:
            return source[start:end + len("</svg>")]
    except OSError:
        pass
    return '<svg class="sprite" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><defs><path id="g-full" fill-rule="evenodd" d="M50 5C27 5 10 23 10 46v57l15-8 12 8 13-8 13 8 12-8 15 8V46C90 23 73 5 50 5Z M38 39a5 5 0 1 0 0 10 5 5 0 0 0 0-10Zm24 0a5 5 0 1 0 0 10 5 5 0 0 0 0-10Zm-21 22c5 8 13 8 18 0-5 3-13 3-18 0Z"/></defs></svg>'

def _render_owner_page(status: str, download: str) -> str:
    return (
        OWNER_PAGE.replace("__THEME_HEAD__", THEME_HEAD)
        .replace("__THEME_TOGGLE__", THEME_TOGGLE)
        .replace("__STYLE__", V2_STYLE)
        .replace("__SPRITE__", _welcome_sprite())
        .replace("__STATUS__", status)
        .replace("__DOWNLOAD__", download)
    )

def _private_headers() -> dict:
    return {
        "Cache-Control": "private, no-store, no-cache, max-age=0",
        "Pragma": "no-cache",
        "X-Robots-Tag": "noindex, nofollow, noarchive",
        "Content-Security-Policy": "default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    }

def _not_found_response() -> HTMLResponse:
    try:
        page = Path(NOT_FOUND_PATH).read_text(encoding="utf-8")
    except OSError:
        page = "<!doctype html><html lang='ru'><meta charset='utf-8'><title>404 · GhostEcos</title><body><h1>404</h1><p>Такой страницы нет.</p><a href='/v2'>GhostEcos</a></body></html>"
    return HTMLResponse(page, status_code=404, headers=_private_headers())

async def _is_owner(request: Request) -> bool:
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

@router.get("/waki-app", include_in_schema=False)
@router.get("/waki-app/", include_in_schema=False)
async def private_page(request: Request):
    if not await _is_owner(request):
        return _not_found_response()
    exists = os.path.isfile(APK_PATH)
    status = "APK уже загружен и готов к скачиванию." if exists else "APK пока не загружен на сервер. Выбери APK ниже."
    download = '<a class="button primary" href="/waki-app/download">Скачать APK →</a>' if exists else '<button class="button primary" type="button" disabled>APK пока не загружен</button>'
    return HTMLResponse(_render_owner_page(status, download), headers=_private_headers())

@router.get("/waki-app/download", include_in_schema=False)
async def private_download(request: Request):
    if not await _is_owner(request) or not os.path.isfile(APK_PATH):
        return _not_found_response()
    return FileResponse(
        APK_PATH,
        media_type=APK_MIME,
        filename="GhostEcos-smoke-test-arm64.apk",
        headers=_private_headers(),
    )

@router.post("/waki-app/upload", include_in_schema=False)
async def private_upload(request: Request):
    if not await _is_owner(request):
        return _not_found_response()
    if request.headers.get("origin") != "https://ghostecos.duckdns.org":
        return _not_found_response()
    if request.headers.get("sec-fetch-site", "same-origin") != "same-origin":
        return _not_found_response()
    if request.headers.get("x-requested-with") != "fetch":
        return _not_found_response()
    content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if content_type != APK_MIME:
        raise HTTPException(415, "Нужен APK-файл")
    try:
        declared_size = int(request.headers.get("content-length", "0"))
    except ValueError:
        raise HTTPException(400, "Некорректный размер файла")
    if declared_size > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "APK больше 64 МБ")

    os.makedirs(PRIVATE_DIR, mode=0o700, exist_ok=True)
    temp_path = None
    total = 0
    try:
        with tempfile.NamedTemporaryFile(prefix=".incoming-", dir=PRIVATE_DIR, delete=False) as target:
            temp_path = target.name
            async for chunk in request.stream():
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    raise HTTPException(413, "APK больше 64 МБ")
                target.write(chunk)
            target.flush()
            os.fsync(target.fileno())
        if total < 4096 or not zipfile.is_zipfile(temp_path):
            raise HTTPException(400, "Файл не похож на APK")
        with zipfile.ZipFile(temp_path) as archive:
            if "AndroidManifest.xml" not in archive.namelist():
                raise HTTPException(400, "В APK нет AndroidManifest.xml")
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, APK_PATH)
        temp_path = None
        return JSONResponse({"ok": True, "bytes": total}, headers=_private_headers())
    finally:
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)
