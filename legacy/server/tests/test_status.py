"""Тесты ежедневного статуса."""


def test_status_must_set_for_new_user(client, reg_user):
    u = reg_user(username="stat1")
    r = client.get("/api/soc/status/my",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert d["must_set"] is True
    assert d["text"] is None


def test_status_set_and_get(client, reg_user):
    u = reg_user(username="stat2")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "пилю репосты"})
    assert r.status_code == 200
    d = r.json()
    assert d["text"] == "пилю репосты"
    assert d["expires_at"] > d["set_at"]

    # Теперь GET /my вернёт текст и must_set=False
    r = client.get("/api/soc/status/my",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.json()["must_set"] is False
    assert r.json()["text"] == "пилю репосты"


def test_status_public_get(client, reg_user):
    u = reg_user(username="stat3")
    client.post("/api/soc/status/set",
                headers={"Authorization": f"Bearer {u['token']}"},
                json={"text": "hello world"})
    # Публичный GET — без авторизации
    r = client.get(f"/api/soc/status/{u['username']}")
    assert r.status_code == 200
    assert r.json()["text"] == "hello world"


def test_status_empty_400(client, reg_user):
    u = reg_user(username="stat4")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "   "})
    assert r.status_code == 400


def test_status_too_long_400(client, reg_user):
    u = reg_user(username="stat5")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "x" * 200})
    assert r.status_code == 400


def test_status_in_profile(client, reg_user):
    u = reg_user(username="stat6")
    client.post("/api/soc/status/set",
                headers={"Authorization": f"Bearer {u['token']}"},
                json={"text": "тестовый статус"})
    r = client.get(f"/api/soc/prof/{u['username']}",
                   headers={"Authorization": f"Bearer {u['token']}"})
    assert r.json()["daily_status"] == "тестовый статус"


def test_status_strips_newlines(client, reg_user):
    u = reg_user(username="stat7")
    r = client.post("/api/soc/status/set",
                    headers={"Authorization": f"Bearer {u['token']}"},
                    json={"text": "line1\nline2"})
    assert r.status_code == 200
    assert "\n" not in r.json()["text"]
