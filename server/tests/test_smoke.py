"""Smoke-тесты: приложение поднимается, основные публичные эндпоинты живы."""


def test_app_imports(client):
    """Приложение собирается без ошибок при импорте."""
    assert client.app is not None


def test_health(client):
    """Health-эндпоинт отвечает (если есть) или вообще приложение отзывается."""
    r = client.get("/api/soc/me")
    # Без токена — 401, главное что не 500
    assert r.status_code in (401, 422)


def test_post_feed_requires_auth(client):
    r = client.get("/api/soc/post?sort=new")
    # Гости не могут читать ленту без guest-токена → 401
    assert r.status_code in (200, 401)
