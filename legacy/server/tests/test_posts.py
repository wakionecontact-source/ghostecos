"""Тесты публикации постов, NSFW флага, редактирования, модераторских действий."""


def test_post_create_basic(client, reg_user):
    u = reg_user(username="poster1")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "hello world"})
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    pid = r.json()["post_id"]
    assert isinstance(pid, int) and pid > 0


def test_post_create_with_nsfw(client, reg_user):
    u = reg_user(username="nsfwuser")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "spicy content", "is_nsfw": True})
    assert r.status_code == 200
    pid = r.json()["post_id"]
    # GET /post/{id} — проверим что флаг сохранился
    r = client.get(f"/api/soc/post/{pid}",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert d["is_nsfw"] is True
    assert d["nsfw_set_by_admin"] is False  # автор сам пометил


def test_post_create_empty_400(client, reg_user):
    u = reg_user(username="emptyuser")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "   "})
    assert r.status_code == 400


def test_patch_post_nsfw_by_author(client, reg_user):
    u = reg_user(username="patchuser")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "regular post"})
    pid = r.json()["post_id"]
    # Автор помечает NSFW позже
    r = client.patch(f"/api/soc/post/{pid}",
                     headers={"Authorization": f"Bearer {u['token']}"},
                     json={"is_nsfw": True})
    assert r.status_code == 200
    # Проверяем
    r = client.get(f"/api/soc/post/{pid}",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.json()["is_nsfw"] is True
    # Автор снимает — должно работать (т.к. он сам пометил)
    r = client.patch(f"/api/soc/post/{pid}",
                     headers={"Authorization": f"Bearer {u['token']}"},
                     json={"is_nsfw": False})
    assert r.status_code == 200


def test_mod_set_nsfw_admin_decreases_reputation(client, reg_user):
    # testadmin → owner по env var GE_OWNER_USERNAME (см. conftest)
    admin = reg_user(username="testadmin")
    victim = reg_user(username="victim1")
    # Жертва пишет пост без NSFW
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {victim['token']}"},
                    json={"text": "controversial"})
    pid = r.json()["post_id"]
    # Админ ставит NSFW
    r = client.post(f"/api/soc/mod/post/{pid}/nsfw",
                    headers={"Authorization": f"Bearer {admin['token']}"},
                    json={"value": True})
    assert r.status_code == 200
    body = r.json()
    assert body["is_nsfw"] is True
    assert body["by_admin"] is True
    # Репутация автора снижена на 10 (со 100 до 90)
    assert body["author_reputation"] == 90
    # Идемпотентность: повторная пометка → unchanged
    r = client.post(f"/api/soc/mod/post/{pid}/nsfw",
                    headers={"Authorization": f"Bearer {admin['token']}"},
                    json={"value": True})
    assert r.status_code == 200
    assert r.json()["unchanged"] is True


def test_mod_set_nsfw_requires_admin_or_mod(client, reg_user):
    poster = reg_user(username="poster_x")
    other = reg_user(username="random_y")
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {poster['token']}"},
                    json={"text": "post text"})
    pid = r.json()["post_id"]
    # Обычный юзер не может ставить чужой NSFW
    r = client.post(f"/api/soc/mod/post/{pid}/nsfw",
                    headers={"Authorization": f"Bearer {other['token']}"},
                    json={"value": True})
    assert r.status_code == 403


def test_profile_returns_reputation(client, reg_user):
    u = reg_user(username="profuser")
    r = client.get(f"/api/soc/prof/{u['username']}",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert d["reputation_score"] == 100
    assert d["reputation_band"] == "good"


def test_wrapped_public(client, reg_user):
    u = reg_user(username="wrappeduser")
    # Wrapped публичный — без авторизации
    r = client.get(f"/api/soc/wrapped/{u['username']}")
    assert r.status_code == 200
    d = r.json()
    assert d["username"] == u["username"]
    assert d["display_name"] == u["display_name"]
    assert "reputation" in d
    assert "top_reactions" in d
    assert "balance" in d


def test_admin_stats_requires_admin(client, reg_user):
    plain = reg_user(username="plain_y")
    r = client.get("/api/soc/admin/stats",
                   headers={"Authorization": f"Bearer {plain['token']}"})
    assert r.status_code == 403
    # Админ
    admin = reg_user(username="testadmin")
    r = client.get("/api/soc/admin/stats",
                   headers={"Authorization": f"Bearer {admin['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert "users" in d and "activity" in d and "content" in d and "economy" in d
