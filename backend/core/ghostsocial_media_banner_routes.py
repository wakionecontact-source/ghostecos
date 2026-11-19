

# Баннер хранит ссылку на медиа уже опубликованного поста/миниски.
class MediaBannerBody(BaseModel):
    url: str = Field(..., max_length=2048)
    media_type: str = Field(..., pattern="^(image|video)$")
    position_x: float = Field(default=50, ge=0, le=100)
    position_y: float = Field(default=50, ge=0, le=100)
    zoom: float = Field(default=1, ge=1, le=3)
    overlay: float = Field(default=0, ge=0, le=1)
    blur: float = Field(default=0, ge=0, le=16)


def _gs_media_banner_column(c):
    cols = {r["name"] for r in c.execute("PRAGMA table_info(users)").fetchall()}
    if "media_banner" not in cols:
        c.execute("ALTER TABLE users ADD COLUMN media_banner TEXT")
        c.commit()


def _gs_media_banner_payload(raw):
    if not raw:
        return None
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
        return value if isinstance(value, dict) and value.get("url") else None
    except Exception:
        return None


@router.post("/media-banner")
def set_media_banner(body: MediaBannerBody, authorization: Optional[str] = Header(default=None)):
    user = auth_member(authorization)
    if int(user["id"]) != 2:
        raise HTTPException(403, "Недоступно")
    url = body.url.strip()
    if not url.startswith("/"):
        raise HTTPException(400, "Можно выбрать только опубликованное медиа GhostSocial")
    # Пускаем только локальные URL и только медиа, уже прикреплённое к посту/миниски.
    if not (url.startswith("/media/") or url.startswith("/social/media/") or url.startswith("/api/soc/media/")):
        raise HTTPException(400, "Недопустимая ссылка на медиа")
    c = db()
    _gs_media_banner_column(c)
    rows = c.execute("SELECT media FROM soc_posts WHERE media IS NOT NULL").fetchall()
    found = False
    target = url.split("?", 1)[0]
    target_name = os.path.basename(target)
    for row in rows:
        try:
            media = json.loads(row["media"]) if isinstance(row["media"], str) else row["media"]
        except Exception:
            continue
        stack = media if isinstance(media, list) else [media]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                candidate = item.get("url") or item.get("src") or item.get("path")
                if candidate and str(candidate).split("?", 1)[0] == target:
                    found = True
                    break
                stack.extend(v for v in item.values() if isinstance(v, (dict, list)))
            elif isinstance(item, list):
                stack.extend(item)
        if found:
            break
    if not found:
        raise HTTPException(400, "Медиа не найдено среди опубликованных постов")
    banner = {
        "url": url,
        "type": body.media_type,
        "position_x": round(float(body.position_x), 2),
        "position_y": round(float(body.position_y), 2),
        "zoom": round(float(body.zoom), 2),
        "overlay": round(float(body.overlay), 3),
        "blur": round(float(body.blur), 2),
    }
    c.execute("UPDATE users SET media_banner=? WHERE id=?", (json.dumps(banner, ensure_ascii=False), 2))
    c.commit()
    return {"ok": True, "media_banner": banner}


@router.delete("/media-banner")
def clear_media_banner(authorization: Optional[str] = Header(default=None)):
    user = auth_member(authorization)
    if int(user["id"]) != 2:
        raise HTTPException(403, "Недоступно")
    c = db()
    _gs_media_banner_column(c)
    c.execute("UPDATE users SET media_banner=NULL WHERE id=?", (2,))
    c.commit()
    return {"ok": True, "media_banner": None}
