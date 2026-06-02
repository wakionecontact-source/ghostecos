"""Тесты репостов."""


def _make_post(client, u, text="content"):
    r = client.post("/api/soc/post/new",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": text})
    return r.json()["post_id"]


def test_repost_basic(client, reg_user):
    a = reg_user(username="rep_author")
    b = reg_user(username="rep_user")
    pid = _make_post(client, a)
    r = client.post(f"/api/soc/post/{pid}/repost",
                    headers={"Authorization": f"Bearer {b['token']}"})
    assert r.status_code == 200
    assert r.json()["existing"] is False


def test_repost_own_post_400(client, reg_user):
    a = reg_user(username="rep_author2")
    pid = _make_post(client, a)
    r = client.post(f"/api/soc/post/{pid}/repost",
                    headers={"Authorization": f"Bearer {a['token']}"})
    assert r.status_code == 400


def test_repost_idempotent(client, reg_user):
    a = reg_user(username="rep_author3")
    b = reg_user(username="rep_user3")
    pid = _make_post(client, a)
    r1 = client.post(f"/api/soc/post/{pid}/repost",
                     headers={"Authorization": f"Bearer {b['token']}"})
    r2 = client.post(f"/api/soc/post/{pid}/repost",
                     headers={"Authorization": f"Bearer {b['token']}"})
    assert r1.status_code == 200 and r2.status_code == 200
    assert r2.json()["existing"] is True


def test_repost_unrepost(client, reg_user):
    a = reg_user(username="rep_author4")
    b = reg_user(username="rep_user4")
    pid = _make_post(client, a)
    client.post(f"/api/soc/post/{pid}/repost",
                headers={"Authorization": f"Bearer {b['token']}"})
    r = client.delete(f"/api/soc/post/{pid}/repost",
                      headers={"Authorization": f"Bearer {b['token']}"})
    assert r.status_code == 200
    # Снова можно репостнуть
    r = client.post(f"/api/soc/post/{pid}/repost",
                    headers={"Authorization": f"Bearer {b['token']}"})
    assert r.json()["existing"] is False


def test_reposters_list_public(client, reg_user):
    a = reg_user(username="rep_author5")
    b = reg_user(username="rep_user5")
    pid = _make_post(client, a)
    client.post(f"/api/soc/post/{pid}/repost",
                headers={"Authorization": f"Bearer {b['token']}"})
    # Публично — без auth
    r = client.get(f"/api/soc/post/{pid}/reposters")
    assert r.status_code == 200
    d = r.json()
    assert d["total"] == 1
    assert d["items"][0]["username"] == "rep_user5"


def test_reposters_contacts_filtered(client, reg_user):
    """Пилюля показывает только тех на кого я подписан."""
    me_user = reg_user(username="rep_me")
    a = reg_user(username="rep_author6")
    b1 = reg_user(username="rep_friend")    # подписан на него
    b2 = reg_user(username="rep_stranger")  # не подписан
    pid = _make_post(client, a)
    # b1 и b2 оба репостят
    client.post(f"/api/soc/post/{pid}/repost", headers={"Authorization": f"Bearer {b1['token']}"})
    client.post(f"/api/soc/post/{pid}/repost", headers={"Authorization": f"Bearer {b2['token']}"})
    # me подписывается только на b1
    client.post(f"/api/soc/follow/{b1['username']}", headers={"Authorization": f"Bearer {me_user['token']}"})
    # Запрос пилюли от имени me
    r = client.get(f"/api/soc/post/{pid}/reposters/contacts",
                   headers={"Authorization": f"Bearer {me_user['token']}"})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == 1
    assert items[0]["username"] == "rep_friend"


def test_my_reposts_ids(client, reg_user):
    a = reg_user(username="rep_author7")
    b = reg_user(username="rep_me7")
    pid = _make_post(client, a)
    client.post(f"/api/soc/post/{pid}/repost",
                headers={"Authorization": f"Bearer {b['token']}"})
    r = client.get("/api/soc/me/reposts/ids",
                   headers={"Authorization": f"Bearer {b['token']}"})
    assert r.status_code == 200
    assert pid in r.json()


def test_feed_combined_mixes_posts_and_reposts(client, reg_user):
    """Unified-лента возвращает свои посты + репосты в хронологии с пометкой kind."""
    me_user = reg_user(username="combined_me")
    a = reg_user(username="combined_a")
    # Я пишу пост 1
    pid1 = _make_post(client, me_user, "my-post-1")
    # Я репощу два чужих
    p_a1 = _make_post(client, a, "from-a-1")
    p_a2 = _make_post(client, a, "from-a-2")
    client.post(f"/api/soc/post/{p_a1}/repost", headers={"Authorization": f"Bearer {me_user['token']}"})
    client.post(f"/api/soc/post/{p_a2}/repost", headers={"Authorization": f"Bearer {me_user['token']}"})
    # Я пишу пост 2
    pid2 = _make_post(client, me_user, "my-post-2")
    # Лента: my-post-2, repost a2, repost a1, my-post-1
    r = client.get(f"/api/soc/user/{me_user['username']}/feed_combined",
                   headers={"Authorization": f"Bearer {me_user['token']}"})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == 4
    # Проверяем что kind правильно расставлен
    kinds = [it["kind"] for it in items]
    assert kinds.count("self") == 2
    assert kinds.count("repost") == 2


def test_user_reposts_returns_reposted_posts(client, reg_user):
    a = reg_user(username="rep_author8")
    b = reg_user(username="rep_me8")
    pid = _make_post(client, a, "interesting")
    client.post(f"/api/soc/post/{pid}/repost",
                headers={"Authorization": f"Bearer {b['token']}"})
    # GET /user/{b}/reposts
    r = client.get(f"/api/soc/user/{b['username']}/reposts",
                   headers={"Authorization": f"Bearer {b['token']}"})
    assert r.status_code == 200
    items = r.json()
    assert len(items) == 1
    assert items[0]["content"] == "interesting"
    assert items[0]["is_repost"] is True
    assert "reposted_at" in items[0]
