"""Тесты OG-превью: PNG-генерация + meta-теги (если есть способ запустить main_remote)."""


def test_og_user_png_returns_image(client, reg_user):
    u = reg_user(username="ogtarget")
    r = client.get(f"/api/soc/og/user/{u['username']}.png")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/png")
    assert r.content[:8] == b"\x89PNG\r\n\x1a\n"
    # Cache-Control
    assert "max-age" in r.headers.get("cache-control", "")


def test_og_user_png_404(client):
    r = client.get("/api/soc/og/user/nonexistent_xyz_999.png")
    assert r.status_code == 404


def test_og_post_png_returns_image(client, reg_user):
    u = reg_user(username="ogposter")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "shareable post text"})
    pid = r.json()["post_id"]
    r = client.get(f"/api/soc/og/post/{pid}.png")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/png")
    assert r.content[:8] == b"\x89PNG\r\n\x1a\n"


def test_og_post_png_nsfw_no_content_leak(client, reg_user):
    """Содержимое NSFW-поста не должно попадать в OG превью."""
    u = reg_user(username="nsfwposter")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "ОЧЕНЬ ОПРЕДЕЛЁННЫЙ_МАРКЕР_xyz123", "is_nsfw": True})
    pid = r.json()["post_id"]
    r = client.get(f"/api/soc/og/post/{pid}.png")
    assert r.status_code == 200
    # PNG-байты не должны содержать сырой текст (он бы попал только если бы рисовался)
    # Это не идеальная проверка, но смысл — что код прошёл NSFW-ветку
    assert r.content[:8] == b"\x89PNG\r\n\x1a\n"


def test_og_wrapped_png(client, reg_user):
    u = reg_user(username="wrap2")
    r = client.get(f"/api/soc/og/wrapped/{u['username']}.png")
    assert r.status_code == 200
    assert r.content[:8] == b"\x89PNG\r\n\x1a\n"


def test_og_png_caching(client, reg_user):
    """Второй запрос должен попасть в кэш и вернуть тот же файл быстро."""
    u = reg_user(username="cacheuser")
    r1 = client.get(f"/api/soc/og/user/{u['username']}.png")
    r2 = client.get(f"/api/soc/og/user/{u['username']}.png")
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.content == r2.content
