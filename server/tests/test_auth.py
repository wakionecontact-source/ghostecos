"""Тесты регистрации, логина, удаления аккаунта, age-18 cooldown."""


def test_register_requires_age_18(client):
    r = client.post("/api/soc/register", json={
        "username": "noage", "display_name": "No Age",
        "password": "password123",
        # age_18_confirm не передан → должно быть 422
    })
    assert r.status_code == 422
    assert "18" in r.text


def test_register_ok_with_age(client):
    r = client.post("/api/soc/register", json={
        "username": "user_a", "display_name": "User A",
        "password": "password123", "age_18_confirm": True,
    })
    assert r.status_code == 200
    d = r.json()
    assert d["username"] == "user_a"
    assert "token" in d
    assert "seed_phrase" in d  # seed показывается ровно один раз
    assert len(d["seed_phrase"]) == 16


def test_register_duplicate_username(client, reg_user):
    reg_user(username="dup")
    r = client.post("/api/soc/register", json={
        "username": "dup", "display_name": "Dup 2",
        "password": "password123", "age_18_confirm": True,
    })
    assert r.status_code == 409


def test_login_ok(client, reg_user):
    u = reg_user(username="loginu", password="strongpass")
    r = client.post("/api/soc/login", json={"username": "loginu", "password": "strongpass"})
    assert r.status_code == 200
    assert "token" in r.json()


def test_login_wrong_password(client, reg_user):
    reg_user(username="wrongpwd", password="rightpass1")
    r = client.post("/api/soc/login", json={"username": "wrongpwd", "password": "wrongpass1"})
    assert r.status_code == 401


def test_delete_account_requires_password(client, reg_user):
    u = reg_user(username="deluser", password="mypass1234")
    # Без пароля → 422
    r = client.request("DELETE", "/api/soc/me/account",
                       headers={"Authorization": f"Bearer {u['token']}"},
                       json={})
    assert r.status_code == 422
    # Неверный пароль → 401
    r = client.request("DELETE", "/api/soc/me/account",
                       headers={"Authorization": f"Bearer {u['token']}"},
                       json={"password": "wrong"})
    assert r.status_code == 401
    # Верный → 200
    r = client.request("DELETE", "/api/soc/me/account",
                       headers={"Authorization": f"Bearer {u['token']}"},
                       json={"password": "mypass1234"})
    assert r.status_code == 200
    assert r.json()["deleted"] is True
    assert r.json()["username_freed_in_days"] == 30


def test_username_30day_cooldown_after_delete(client, reg_user):
    u = reg_user(username="cdtest", password="pass12345")
    client.request("DELETE", "/api/soc/me/account",
                   headers={"Authorization": f"Bearer {u['token']}"},
                   json={"password": "pass12345"})
    # Повторная регистрация того же username → 409 с указанием дней
    r = client.post("/api/soc/register", json={
        "username": "cdtest", "display_name": "Re",
        "password": "newpass123", "age_18_confirm": True,
    })
    assert r.status_code == 409
    assert "освобод" in r.text.lower() or "дн" in r.text.lower()


def test_me_endpoint_returns_user(client, reg_user):
    u = reg_user(username="meuser")
    r = client.get("/api/soc/me", headers={"Authorization": f"Bearer {u['token']}"})
    assert r.status_code == 200
    d = r.json()
    assert d["username"] == "meuser"
    assert "is_admin" in d
    assert d["is_admin"] is False
